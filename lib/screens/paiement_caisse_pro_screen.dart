import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../services/tontine_provider.dart';
import '../services/sycapay_service.dart';
import '../services/supabase_service.dart';
import '../services/locale_service.dart';
import '../utils/app_colors.dart';
import '../utils/formatters.dart';

/// Écran de paiement Mobile Money pour un apport de caisse Premium.
///
/// Workflow v4 — CRÉDIT SERVEUR-SIDE :
///   1.  Génère numCommande unique (TC_...) → référence pivot immuable
///   2.  [payer]              : Edge Fn → login + checkoutpay + persistance pending
///   3.  [confirmer_et_crediter] : Edge Fn polle SycaPay pendant 150s CÔTÉ SERVEUR
///       → dès confirmation, crédite la caisse via RPC crediter_caisse_sycapay
///       → retourne ok:true à Flutter (même si app a redémarré entre-temps)
///   4.  Flutter affiche « Paiement reçu avec succès. »
///   5.  Watchdog Flutter 180s : si Edge Fn ne répond pas → bouton Vérifier
///   6.  « Vérifier mon paiement » : appelle statut → si confirmed, crédite et OK
///
/// Garanties :
///   • Double crédit impossible : UNIQUE constraint + check creditée en DB
///   • Double clic impossible : _enTraitement flag
///   • Polling -1 transitoire toléré : Edge Fn traite -1 < 3min comme pending
///   • Crash app : le webhook SycaPay crédite automatiquement côté serveur
class PaiementCaisseProScreen extends StatefulWidget {
  final String code;
  final int    montant;
  final String description;

  const PaiementCaisseProScreen({
    super.key,
    required this.code,
    required this.montant,
    required this.description,
  });

  @override
  State<PaiementCaisseProScreen> createState() => _PaiementCaisseProScreenState();
}

class _PaiementCaisseProScreenState extends State<PaiementCaisseProScreen> {
  static const _couleurPro = Color(0xFF1A6B3C);

  // ── État ──────────────────────────────────────────────────────────────────
  String _operateur = 'moov';
  final _telCtrl    = TextEditingController();
  final _otpCtrl    = TextEditingController();

  _EtapeCaisse _etape                    = _EtapeCaisse.saisie;
  String?      _numCommande;             // référence pivot TC_...
  String?      _transactionId;           // ID SycaPay (optionnel)
  String?      _messageErreur;
  String?      _messageInfo;
  bool         _peutVerifierManuellement = false;
  bool         _enTraitement             = false; // anti double-clic
  Timer?       _watchdogTimer;           // 180s — sécurité côté Flutter

  @override
  void dispose() {
    _telCtrl.dispose();
    _otpCtrl.dispose();
    _watchdogTimer?.cancel();
    super.dispose();
  }

  // ── Validation ────────────────────────────────────────────────────────────

  bool get _saisieValide {
    final tel = _telCtrl.text.trim();
    if (tel.length < 8) return false;
    if (_operateur == 'orange' && _otpCtrl.text.trim().length < 4) return false;
    return true;
  }

  // ── Initier le paiement ───────────────────────────────────────────────────

  Future<void> _initierPaiement() async {
    if (!_saisieValide || _enTraitement) return;
    _enTraitement = true;

    // Générer la référence pivot AVANT setState
    final numCmd = SycaPayService.genererNumCommande(
      widget.code,
      'CAISSE',
    );
    _numCommande = numCmd;

    setState(() {
      _etape                    = _EtapeCaisse.enCours;
      _messageErreur            = null;
      _messageInfo              = null;
      _peutVerifierManuellement = false;
    });

    // ── Watchdog Flutter 180s ─────────────────────────────────────────────
    // L'Edge Function peut prendre jusqu'à 150s (polling serveur).
    // Si Flutter ne reçoit pas de réponse en 180s → afficher bouton Vérifier.
    _watchdogTimer?.cancel();
    _watchdogTimer = Timer(const Duration(seconds: 180), () {
      if (!mounted || _etape != _EtapeCaisse.enCours) return;
      if (kDebugMode) debugPrint('[CaissePro] WATCHDOG 180s → $numCmd');
      _enTraitement = false;
      setState(() {
        _etape                    = _EtapeCaisse.saisie;
        _peutVerifierManuellement = true;
        _messageErreur =
            '⏱ La vérification prend trop de temps.\n'
            'Réf. : $numCmd';
        _messageInfo =
            'Si votre argent a été débité (vérifiez SMS), '
            'utilisez « Vérifier mon paiement » — ne relancez PAS un nouveau paiement.';
      });
    });

    try {
      // ── ÉTAPE 1 : initier le paiement (checkoutpay) ───────────────────────
      if (kDebugMode) debugPrint('[CaissePro] Étape 1 — initierPaiement $numCmd');
      final resultat = await SycaPayService.initierPaiement(
        telephone:     _telCtrl.text.trim(),
        montant:       widget.montant,
        numCommande:   numCmd,
        operateur:     _operateur,
        tontineCode:   widget.code,
        otp:           _operateur == 'orange' ? _otpCtrl.text.trim() : null,
        nomMembre:     'Apport',
        prenomMembre:  'Caisse',
        typeOperation: 'caisse',
        description:   widget.description.isNotEmpty ? widget.description : null,
      );

      if (kDebugMode) debugPrint('[CaissePro] initierPaiement → $resultat');
      _transactionId = resultat.transactionId;

      if (!mounted) return;

      // Idempotent : déjà traité → afficher succès
      if (resultat.dejaConfirme) {
        _watchdogTimer?.cancel();
        _enTraitement = false;
        setState(() => _etape = _EtapeCaisse.enregistrement);
        await _finaliserLocalement();
        return;
      }

      // Erreur réseau immédiate
      if (resultat.erreurReseau) {
        _watchdogTimer?.cancel();
        _enTraitement = false;
        setState(() {
          _etape                    = _EtapeCaisse.saisie;
          _messageErreur            = resultat.messageFr;
          _peutVerifierManuellement = true;
          _messageInfo = 'Si votre argent a été débité, utilisez « Vérifier mon paiement ».';
        });
        return;
      }

      // Échec définitif immédiat (solde insuf, OTP incorrect…)
      if (resultat.estEchec && !resultat.estEnAttente) {
        _watchdogTimer?.cancel();
        _enTraitement = false;
        setState(() {
          _etape         = _EtapeCaisse.saisie;
          _messageErreur = resultat.messageFr;
        });
        return;
      }

      // ── ÉTAPE 2 : demander à l'Edge Function de poller et créditer serveur ─
      // L'Edge Fn va poller SycaPay pendant jusqu'à 150s CÔTÉ SERVEUR.
      // Flutter attend la réponse (avec son watchdog 180s).
      // Pendant ce temps → vue "attente" pour l'utilisateur.
      if (!mounted) return;
      setState(() => _etape = _EtapeCaisse.attente);

      if (kDebugMode) debugPrint('[CaissePro] Étape 2 — confirmer_et_crediter serveur');
      final confirmation = await SycaPayService.confirmerEtCrediter(
        numCommande:   numCmd,
        transactionId: _transactionId,
        tontineCode:   widget.code,
        typeOperation: 'caisse',
        montant:       widget.montant,
        operateur:     _operateur,
        description:   widget.description.isNotEmpty ? widget.description : null,
      );

      _watchdogTimer?.cancel();
      _enTraitement = false;

      if (!mounted) return;
      if (kDebugMode) debugPrint('[CaissePro] confirmer_et_crediter → $confirmation');

      if (confirmation.ok) {
        // ✅ Serveur a confirmé ET crédité → Flutter recharge et affiche succès
        setState(() => _etape = _EtapeCaisse.enregistrement);
        await _rechargerEtSucces();
      } else if (confirmation.estEnAttente || confirmation.timeout) {
        // Timeout Edge Fn → bouton Vérifier (sans "échec")
        setState(() {
          _etape                    = _EtapeCaisse.saisie;
          _peutVerifierManuellement = true;
          _messageErreur =
              '⏳ Confirmation en attente.\nRéf. : $numCmd';
          _messageInfo =
              'Si votre Orange Money a été débité, utilisez '
              '« Vérifier mon paiement ». Ne relancez pas.';
        });
      } else {
        // Echec définitif confirmé par le serveur
        setState(() {
          _etape         = _EtapeCaisse.saisie;
          _messageErreur = confirmation.messageFr;
          // Permettre vérification manuelle seulement si incertain
          _peutVerifierManuellement = confirmation.statusNormalise == 'unknown';
        });
      }

    } catch (e) {
      _watchdogTimer?.cancel();
      _enTraitement = false;
      if (kDebugMode) debugPrint('[CaissePro] EXCEPTION: $e');
      if (!mounted) return;
      setState(() {
        _etape                    = _EtapeCaisse.saisie;
        _peutVerifierManuellement = true;
        _messageErreur =
            '⚠️ Erreur de connexion.\n'
            'Réf. : ${_numCommande ?? "—"}';
        _messageInfo =
            'Si votre argent a été débité (vérifiez SMS), '
            'utilisez « Vérifier mon paiement » avant de réessayer.';
      });
    }
  }

  // ── Vérification manuelle (bouton) ────────────────────────────────────────

  Future<void> _verifierPaiementManuellement() async {
    if (_numCommande == null || _enTraitement) return;
    _enTraitement = true;

    setState(() {
      _etape         = _EtapeCaisse.enCours;
      _messageErreur = null;
      _messageInfo   = null;
    });

    _watchdogTimer?.cancel();
    _watchdogTimer = Timer(const Duration(seconds: 45), () {
      if (!mounted || _etape != _EtapeCaisse.enCours) return;
      _enTraitement = false;
      setState(() {
        _etape                    = _EtapeCaisse.saisie;
        _messageErreur            = '⏱ Vérification impossible. Réseau lent.';
        _peutVerifierManuellement = true;
      });
    });

    try {
      // Appeler statut (l'Edge Fn crédite si confirmé)
      final statut = await SycaPayService.verifierStatut(
        _numCommande!,
        transactionId: _transactionId,
        tontineCode:   widget.code,
      );

      _watchdogTimer?.cancel();
      _enTraitement = false;
      if (!mounted) return;

      if (kDebugMode) debugPrint('[CaissePro] verif manuelle → $statut');

      if (statut.estSucces || statut.statusNormalise == 'credited') {
        // L'Edge Function a crédité côté serveur → juste recharger
        setState(() => _etape = _EtapeCaisse.enregistrement);
        _transactionId ??= statut.transactionId;
        await _rechargerEtSucces();
      } else if (statut.estEnAttente) {
        setState(() {
          _etape                    = _EtapeCaisse.saisie;
          _peutVerifierManuellement = true;
          _messageInfo = '⏳ Paiement toujours en attente. Réessayez dans quelques instants.';
          _messageErreur = null;
        });
      } else {
        setState(() {
          _etape                    = _EtapeCaisse.saisie;
          _messageErreur            = statut.messageFr;
          _peutVerifierManuellement = statut.estExpire || statut.statusNormalise == 'unknown';
        });
      }
    } catch (e) {
      _watchdogTimer?.cancel();
      _enTraitement = false;
      if (!mounted) return;
      setState(() {
        _etape                    = _EtapeCaisse.saisie;
        _messageErreur            = 'Vérification échouée: $e';
        _peutVerifierManuellement = true;
      });
    }
  }

  // ── Recharger la tontine et afficher succès ───────────────────────────────
  // Le crédit a déjà été fait côté serveur.
  // Flutter recharge juste les données pour afficher la nouvelle balance.

  Future<void> _rechargerEtSucces() async {
    final provider = context.read<TontineProvider>();
    try {
      await provider.chargerTontine(widget.code).timeout(const Duration(seconds: 15));
    } catch (_) {}
    if (!mounted) return;

    // Notification push (non bloquante)
    try {
      final data  = provider.courante?.data;
      final devise = data?.devise ?? 'XOF';
      final lang   = Provider.of<LocaleService>(context, listen: false).langue.code; // ignore: use_build_context_synchronously
      final t      = SupabaseService.notifTexte('caisse', lang, vars: {
        'montant': Formatters.montant(widget.montant, devise: devise),
        'libelle': 'Apport caisse Premium SycaPay',
        'nom':     '',
        'desc':    widget.description.isNotEmpty ? ' — ${widget.description}' : '',
      });
      SupabaseService.envoyerNotification(
        code:    widget.code,
        type:    'caisse',
        titre:   t['titre']!,
        message: t['message']!,
      );
    } catch (_) {}

    setState(() => _etape = _EtapeCaisse.succes);
  }

  // ── Finalisation locale (cas idempotent) ──────────────────────────────────
  // Appelé uniquement si l'Edge Fn répond "déjà traité" (idempotent: true).
  // Dans ce cas, la caisse est déjà créditée → juste recharger.

  Future<void> _finaliserLocalement() async {
    await _rechargerEtSucces();
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<TontineProvider>(context);
    final data     = provider.courante?.data;
    final devise   = data?.devise ?? 'XOF';

    return Scaffold(
      backgroundColor: AppColors.fondPapier,
      appBar: AppBar(
        backgroundColor: AppColors.fondPapier,
        elevation:       0,
        title: const Text(
          'Apport de caisse Premium',
          style: TextStyle(
            fontWeight: FontWeight.w700,
            color:      AppColors.encre,
            fontSize:   16,
          ),
        ),
        iconTheme: const IconThemeData(color: AppColors.encre),
      ),
      body: switch (_etape) {
        _EtapeCaisse.saisie         => _vueSaisie(devise),
        _EtapeCaisse.enCours        => _vueEnCours(),
        _EtapeCaisse.enregistrement => _vueEnregistrement(),
        _EtapeCaisse.attente        => _vueAttente(),
        _EtapeCaisse.succes         => _vueSucces(devise),
      },
    );
  }

  // ── Vues ───────────────────────────────────────────────────────────────────

  Widget _vueSaisie(String devise) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Carte montant
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color:        const Color(0xFFEAF4EE),
              borderRadius: BorderRadius.circular(16),
              border:       Border.all(color: _couleurPro.withValues(alpha: 0.2)),
            ),
            child: Column(
              children: [
                const Text('Montant de l\'apport',
                    style: TextStyle(fontSize: 13, color: AppColors.texteDoux)),
                const SizedBox(height: 6),
                Text(
                  Formatters.montant(widget.montant, devise: devise),
                  style: const TextStyle(
                      fontSize: 28, fontWeight: FontWeight.w800, color: _couleurPro),
                ),
                if (widget.description.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(widget.description,
                      style: const TextStyle(fontSize: 12, color: AppColors.texteDoux)),
                ],
                const SizedBox(height: 4),
                const Text('Paiement sécurisé via SycaPay',
                    style: TextStyle(fontSize: 11, color: AppColors.texteDoux)),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // Opérateur
          const Text('Opérateur Mobile Money',
              style: TextStyle(
                  fontWeight: FontWeight.w700, fontSize: 14, color: AppColors.encre)),
          const SizedBox(height: 10),
          _SelecteurOperateur(
            operateur: _operateur,
            onChange:  (op) => setState(() { _operateur = op; _otpCtrl.clear(); }),
          ),
          const SizedBox(height: 20),

          // Téléphone
          const Text('Numéro de téléphone',
              style: TextStyle(
                  fontWeight: FontWeight.w700, fontSize: 14, color: AppColors.encre)),
          const SizedBox(height: 8),
          TextField(
            controller:      _telCtrl,
            keyboardType:    TextInputType.phone,
            maxLength:       10,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            onChanged:       (_) => setState(() {}),
            decoration: const InputDecoration(
              hintText:    '07 XX XX XX XX',
              counterText: '',
              prefixIcon:  Icon(Icons.phone_rounded),
              border:      OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),

          // OTP Orange
          if (_operateur == 'orange') ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color:        Colors.orange.shade50,
                borderRadius: BorderRadius.circular(10),
                border:       Border.all(color: Colors.orange.shade200),
              ),
              child: const Text(
                'Orange Money requiert un code OTP.\n'
                'Composez  #144*8*2#  sur votre téléphone pour le générer.',
                style: TextStyle(fontSize: 13, color: Colors.deepOrange, height: 1.5),
              ),
            ),
            const SizedBox(height: 12),
            const Text('Code OTP Orange',
                style: TextStyle(
                    fontWeight: FontWeight.w700, fontSize: 14, color: AppColors.encre)),
            const SizedBox(height: 8),
            TextField(
              controller:      _otpCtrl,
              keyboardType:    TextInputType.number,
              maxLength:       8,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              onChanged:       (_) => setState(() {}),
              decoration: const InputDecoration(
                hintText:    'Code OTP (ex: 7908)',
                counterText: '',
                prefixIcon:  Icon(Icons.lock_outline_rounded),
                border:      OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
          ],

          // Message erreur / info
          if (_messageErreur != null || _messageInfo != null) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color:        _messageErreur != null
                    ? AppColors.alerteFond
                    : const Color(0xFFE8F5E9),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_messageErreur != null)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.error_outline_rounded,
                            color: AppColors.alerte, size: 20),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(_messageErreur!,
                              style: const TextStyle(
                                  color: AppColors.alerte, fontSize: 13)),
                        ),
                      ],
                    ),
                  if (_messageInfo != null) ...[
                    if (_messageErreur != null) const SizedBox(height: 8),
                    Text(_messageInfo!,
                        style: TextStyle(
                            color: _messageErreur != null
                                ? AppColors.alerte
                                : _couleurPro,
                            fontSize: 12,
                            fontStyle: FontStyle.italic)),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],

          // Bouton principal
          FilledButton.icon(
            onPressed: (_saisieValide && !_enTraitement) ? _initierPaiement : null,
            icon:  const Icon(Icons.account_balance_wallet_rounded),
            label: Text(
              'Verser ${Formatters.montant(widget.montant, devise: 'XOF')} via Mobile Money',
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
            ),
            style: FilledButton.styleFrom(
              backgroundColor:         _couleurPro,
              disabledBackgroundColor: AppColors.encre.withValues(alpha: 0.2),
              padding:                 const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
            ),
          ),

          // Bouton « Vérifier mon paiement »
          if (_peutVerifierManuellement && _numCommande != null) ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _enTraitement ? null : _verifierPaiementManuellement,
              icon:  const Icon(Icons.search_rounded, color: _couleurPro),
              label: const Text('Vérifier mon paiement',
                  style: TextStyle(color: _couleurPro, fontWeight: FontWeight.w600)),
              style: OutlinedButton.styleFrom(
                side:    const BorderSide(color: _couleurPro),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape:   RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Réf. interne : $_numCommande',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 10, color: AppColors.texteDoux),
            ),
          ],
        ],
      ),
    );
  }

  Widget _vueEnCours() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(color: _couleurPro),
            const SizedBox(height: 24),
            const Text('Connexion à SycaPay…',
                style: TextStyle(fontSize: 15, color: AppColors.texte)),
            const SizedBox(height: 8),
            const Text(
              'Envoi du paiement en cours.\nNe fermez pas l\'application.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: AppColors.texteDoux, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }

  Widget _vueAttente() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(color: _couleurPro),
            const SizedBox(height: 24),
            const Icon(Icons.account_balance_wallet_rounded,
                size: 48, color: AppColors.texteDoux),
            const SizedBox(height: 16),
            const Text(
              'Vérification du paiement…',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: AppColors.encre),
            ),
            const SizedBox(height: 8),
            const Text(
              'Confirmez sur votre téléphone si demandé.\n'
              'La vérification est automatique (jusqu\'à 2 min).\n'
              'Ne fermez pas l\'application.',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 13, color: AppColors.texteDoux, height: 1.5),
            ),
            const SizedBox(height: 32),
            if (_numCommande != null)
              Text(
                'Réf. : $_numCommande',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 10, color: AppColors.texteDoux),
              ),
          ],
        ),
      ),
    );
  }

  Widget _vueEnregistrement() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 72, height: 72,
              decoration: const BoxDecoration(
                color: Color(0xFFEAF4EE),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.check_circle_outline_rounded,
                  size: 44, color: _couleurPro),
            ),
            const SizedBox(height: 20),
            const Text('Paiement confirmé !',
                style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: AppColors.encre)),
            const SizedBox(height: 8),
            const Text(
              'Enregistrement en cours…',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: AppColors.texteDoux),
            ),
            const SizedBox(height: 24),
            const SizedBox(
              width: 28, height: 28,
              child: CircularProgressIndicator(strokeWidth: 3, color: _couleurPro),
            ),
          ],
        ),
      ),
    );
  }

  Widget _vueSucces(String devise) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 80, height: 80,
              decoration: const BoxDecoration(
                color: Color(0xFFEAF4EE),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.check_circle_rounded,
                  size: 50, color: _couleurPro),
            ),
            const SizedBox(height: 24),
            const Text('Paiement reçu avec succès.',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    color: AppColors.encre)),
            const SizedBox(height: 8),
            Text(
              'Votre apport de caisse a été enregistré.\n'
              '${Formatters.montant(widget.montant, devise: devise)} versé dans la caisse.',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 15, color: AppColors.texte, height: 1.5),
            ),
            if (_transactionId != null) ...[
              const SizedBox(height: 8),
              Text('Réf. SycaPay : $_transactionId',
                  style: const TextStyle(fontSize: 11, color: AppColors.texteDoux)),
            ],
            if (_numCommande != null) ...[
              const SizedBox(height: 4),
              Text('Réf. interne : $_numCommande',
                  style: const TextStyle(fontSize: 10, color: AppColors.texteDoux)),
            ],
            const SizedBox(height: 40),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              style: FilledButton.styleFrom(
                backgroundColor: _couleurPro,
                padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
              child: const Text('Retour à la caisse',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Enum étapes ───────────────────────────────────────────────────────────────

enum _EtapeCaisse { saisie, enCours, enregistrement, attente, succes }

// ── Sélecteur opérateur ───────────────────────────────────────────────────────

class _SelecteurOperateur extends StatelessWidget {
  final String                operateur;
  final ValueChanged<String>  onChange;

  static const _operateurs = [
    ('orange', 'Orange Money', Colors.deepOrange),
    ('moov',   'Moov Money',   Colors.blue),
    ('mtn',    'MTN MoMo',     Colors.yellow),
    ('wave',   'Wave',         Colors.lightBlue),
  ];

  const _SelecteurOperateur({required this.operateur, required this.onChange});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8, runSpacing: 8,
      children: _operateurs.map((op) {
        final (code, label, couleur) = op;
        final selectionne = operateur == code;
        return InkWell(
          onTap:        () => onChange(code),
          borderRadius: BorderRadius.circular(10),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: selectionne
                  ? couleur.withValues(alpha: 0.12)
                  : AppColors.fondSecondaire,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: selectionne
                    ? couleur.withValues(alpha: 0.6)
                    : AppColors.lignes,
                width: selectionne ? 1.5 : 1,
              ),
            ),
            child: Text(label,
                style: TextStyle(
                  fontSize:   13,
                  fontWeight: selectionne ? FontWeight.w700 : FontWeight.w400,
                  color:      selectionne ? couleur : AppColors.texte,
                )),
          ),
        );
      }).toList(),
    );
  }
}
