import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../models/tontine.dart';
import '../services/tontine_provider.dart';
import '../services/sycapay_service.dart';
import '../services/supabase_service.dart';
import '../services/locale_service.dart';
import '../utils/app_colors.dart';
import '../utils/formatters.dart';

/// Écran de paiement Mobile Money pour une cotisation Premium.
///
/// Workflow v4 — CRÉDIT SERVEUR-SIDE (identique à PaiementCaisseProScreen) :
///   1.  Génère numCommande unique (TC_...)
///   2.  [payer]                 : Edge Fn → login + checkoutpay + pending Supabase
///   3.  [confirmer_et_crediter] : Edge Fn polle SycaPay 150s côté SERVEUR
///       → dès confirmation, crédite la cotisation via crediter_cotisation_sycapay
///   4.  Flutter affiche « Paiement reçu avec succès. »
///   5.  Watchdog 180s côté Flutter
///   6.  « Vérifier mon paiement » disponible après timeout
class PaiementProScreen extends StatefulWidget {
  final String code;
  final Membre membre;

  const PaiementProScreen({
    super.key,
    required this.code,
    required this.membre,
  });

  @override
  State<PaiementProScreen> createState() => _PaiementProScreenState();
}

class _PaiementProScreenState extends State<PaiementProScreen> {
  static const _couleurPro = Color(0xFF1A6B3C);

  String _operateur = 'moov';
  final _telCtrl    = TextEditingController();
  final _otpCtrl    = TextEditingController();

  _Etape  _etape                    = _Etape.saisie;
  String? _numCommande;
  String? _transactionId;
  String? _messageErreur;
  String? _messageInfo;
  bool    _peutVerifierManuellement = false;
  bool    _enTraitement             = false;
  Timer?  _watchdogTimer;
  // Affichage progressif du bouton Vérifier pendant la phase attente (30s)
  bool    _boutonVerifierDansAttente = false;
  Timer?  _timerBoutonAttente;

  @override
  void dispose() {
    _telCtrl.dispose();
    _otpCtrl.dispose();
    _watchdogTimer?.cancel();
    _timerBoutonAttente?.cancel();
    super.dispose();
  }

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

    final provider = context.read<TontineProvider>();
    final data     = provider.courante!.data;
    final montant  = data.montant;

    final numCmd = SycaPayService.genererNumCommande(widget.code, widget.membre.id);
    _numCommande = numCmd;

    setState(() {
      _etape                    = _Etape.enCours;
      _messageErreur            = null;
      _messageInfo              = null;
      _peutVerifierManuellement = false;
    });

    // Watchdog Flutter 180s (Edge Fn peut prendre jusqu'à 150s)
    _watchdogTimer?.cancel();
    _watchdogTimer = Timer(const Duration(seconds: 180), () {
      if (!mounted || _etape != _Etape.enCours) return;
      _enTraitement = false;
      setState(() {
        _etape                    = _Etape.saisie;
        _peutVerifierManuellement = true;
        _messageErreur = '⏱ Vérification trop longue.\nRéf. : $numCmd';
        _messageInfo   = 'Si votre argent a été débité, utilisez '
                         '« Vérifier mon paiement ». Ne relancez pas.';
      });
    });

    try {
      // Étape 1 : checkoutpay
      if (kDebugMode) debugPrint('[PaiementPro] Étape 1 — initierPaiement $numCmd');
      final resultat = await SycaPayService.initierPaiement(
        telephone:     _telCtrl.text.trim(),
        montant:       montant,
        numCommande:   numCmd,
        operateur:     _operateur,
        tontineCode:   widget.code,
        otp:           _operateur == 'orange' ? _otpCtrl.text.trim() : null,
        nomMembre:     widget.membre.nom.split(' ').last,
        prenomMembre:  widget.membre.nom.split(' ').first,
        typeOperation: 'cotisation',
        membreId:      widget.membre.id,
      );

      if (kDebugMode) debugPrint('[PaiementPro] initierPaiement → $resultat');
      _transactionId = resultat.transactionId;
      if (!mounted) return;

      if (resultat.dejaConfirme) {
        _watchdogTimer?.cancel();
        _enTraitement = false;
        setState(() => _etape = _Etape.enregistrement);
        await _rechargerEtSucces(montant);
        return;
      }

      if (resultat.erreurReseau) {
        _watchdogTimer?.cancel();
        _enTraitement = false;
        setState(() {
          _etape                    = _Etape.saisie;
          _messageErreur            = resultat.messageFr;
          _peutVerifierManuellement = true;
          _messageInfo = 'Si votre argent a été débité, utilisez « Vérifier mon paiement ».';
        });
        return;
      }

      if (resultat.estEchec && !resultat.estEnAttente) {
        _watchdogTimer?.cancel();
        _enTraitement = false;
        setState(() {
          _etape         = _Etape.saisie;
          _messageErreur = resultat.messageFr;
        });
        return;
      }

      // Étape 2 : polling + crédit serveur-side
      if (!mounted) return;
      // Démarrer le timer qui rend visible le bouton Vérifier après 30s d'attente
      _boutonVerifierDansAttente = false;
      _timerBoutonAttente?.cancel();
      _timerBoutonAttente = Timer(const Duration(seconds: 30), () {
        if (!mounted || _etape != _Etape.attente) return;
        setState(() => _boutonVerifierDansAttente = true);
      });
      setState(() => _etape = _Etape.attente);

      if (kDebugMode) debugPrint('[PaiementPro] Étape 2 — confirmer_et_crediter');
      final confirmation = await SycaPayService.confirmerEtCrediter(
        numCommande:   numCmd,
        transactionId: _transactionId,
        tontineCode:   widget.code,
        typeOperation: 'cotisation',
        montant:       montant,
        operateur:     _operateur,
        membreId:      widget.membre.id,
      );

      _watchdogTimer?.cancel();
      _enTraitement = false;
      if (!mounted) return;

      if (kDebugMode) debugPrint('[PaiementPro] confirmer_et_crediter → $confirmation');

      if (confirmation.ok) {
        setState(() => _etape = _Etape.enregistrement);
        await _rechargerEtSucces(montant);
      } else if (confirmation.estEnAttente || confirmation.timeout) {
        setState(() {
          _etape                    = _Etape.saisie;
          _peutVerifierManuellement = true;
          _messageErreur = '⏳ Confirmation en attente.\nRéf. : $numCmd';
          _messageInfo   = 'Si Orange Money vous a débité, utilisez '
                           '« Vérifier mon paiement ». Ne relancez pas.';
        });
      } else {
        setState(() {
          _etape         = _Etape.saisie;
          _messageErreur = confirmation.messageFr;
          _peutVerifierManuellement = confirmation.statusNormalise == 'unknown';
        });
      }

    } catch (e) {
      _watchdogTimer?.cancel();
      _enTraitement = false;
      if (kDebugMode) debugPrint('[PaiementPro] EXCEPTION: $e');
      if (!mounted) return;
      setState(() {
        _etape                    = _Etape.saisie;
        _peutVerifierManuellement = true;
        _messageErreur = '⚠️ Erreur de connexion.\nRéf. : ${_numCommande ?? "—"}';
        _messageInfo   = 'Si votre argent a été débité, utilisez '
                         '« Vérifier mon paiement » avant de réessayer.';
      });
    }
  }

  // ── Vérification manuelle ─────────────────────────────────────────────────

  Future<void> _verifierPaiementManuellement() async {
    if (_numCommande == null || _enTraitement) return;
    _enTraitement = true;
    final provider = context.read<TontineProvider>();
    final montant  = provider.courante?.data.montant ?? 0;

    setState(() {
      _etape         = _Etape.enCours;
      _messageErreur = null;
      _messageInfo   = null;
    });

    _watchdogTimer?.cancel();
    _watchdogTimer = Timer(const Duration(seconds: 45), () {
      if (!mounted || _etape != _Etape.enCours) return;
      _enTraitement = false;
      setState(() {
        _etape                    = _Etape.saisie;
        _messageErreur            = '⏱ Vérification impossible. Réseau lent.';
        _peutVerifierManuellement = true;
      });
    });

    try {
      final statut = await SycaPayService.verifierStatut(
        _numCommande!,
        transactionId: _transactionId,
        tontineCode:   widget.code,
      );

      _watchdogTimer?.cancel();
      _enTraitement = false;
      if (!mounted) return;

      if (kDebugMode) debugPrint('[PaiementPro] verif manuelle → $statut');

      if (statut.estSucces || statut.statusNormalise == 'credited') {
        setState(() => _etape = _Etape.enregistrement);
        _transactionId ??= statut.transactionId;
        await _rechargerEtSucces(montant);
      } else if (statut.estEnAttente) {
        setState(() {
          _etape                    = _Etape.saisie;
          _peutVerifierManuellement = true;
          _messageInfo  = '⏳ Paiement toujours en attente. Réessayez dans quelques instants.';
          _messageErreur = null;
        });
      } else {
        setState(() {
          _etape                    = _Etape.saisie;
          _messageErreur            = statut.messageFr;
          _peutVerifierManuellement = statut.estExpire || statut.statusNormalise == 'unknown';
        });
      }
    } catch (e) {
      _watchdogTimer?.cancel();
      _enTraitement = false;
      if (!mounted) return;
      setState(() {
        _etape                    = _Etape.saisie;
        _messageErreur            = 'Vérification échouée: $e';
        _peutVerifierManuellement = true;
      });
    }
  }

  // ── Recharger et afficher succès ──────────────────────────────────────────

  Future<void> _rechargerEtSucces(int montant) async {
    final provider = context.read<TontineProvider>();
    try {
      await provider.chargerTontine(widget.code).timeout(const Duration(seconds: 15));
    } catch (_) {}
    if (!mounted) return;

    try {
      final data  = provider.courante?.data;
      final devise = data?.devise ?? 'XOF';
      final lang   = Provider.of<LocaleService>(context, listen: false).langue.code; // ignore: use_build_context_synchronously
      final t      = SupabaseService.notifTexte('cotisation', lang, vars: {
        'montant': Formatters.montant(montant, devise: devise),
        'nom':     widget.membre.nom,
        'libelle': 'Cotisation Premium SycaPay',
        'desc':    '',
      });
      SupabaseService.envoyerNotification(
        code:    widget.code,
        type:    'cotisation_pro_confirmee',
        titre:   t['titre']!,
        message: t['message']!,
        donneesExtra: {
          'membre':        widget.membre.nom,
          'transactionId': _transactionId ?? '',
        },
      );
    } catch (_) {}

    setState(() => _etape = _Etape.succes);
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<TontineProvider>(context);
    final data     = provider.courante?.data;
    final montant  = data?.montant ?? 0;
    final devise   = data?.devise  ?? 'XOF';

    return Scaffold(
      backgroundColor: AppColors.fondPapier,
      appBar: AppBar(
        backgroundColor: AppColors.fondPapier,
        elevation: 0,
        title: Text(
          'Cotisation Premium — ${widget.membre.nom}',
          style: const TextStyle(
              fontWeight: FontWeight.w700,
              color:      AppColors.encre,
              fontSize:   16),
        ),
        iconTheme: const IconThemeData(color: AppColors.encre),
      ),
      body: switch (_etape) {
        _Etape.saisie         => _vueSaisie(montant, devise),
        _Etape.enCours        => _vueEnCours(),
        _Etape.enregistrement => _vueEnregistrement(),
        _Etape.attente        => _vueAttente(),
        _Etape.succes         => _vueSucces(montant, devise),
      },
    );
  }

  // ── Vues ───────────────────────────────────────────────────────────────────

  Widget _vueSaisie(int montant, String devise) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _CarteMontant(montant: montant, devise: devise),
          const SizedBox(height: 24),

          const Text('Opérateur Mobile Money',
              style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                  color: AppColors.encre)),
          const SizedBox(height: 10),
          _SelecteurOperateur(
            operateur: _operateur,
            onChange: (op) => setState(() { _operateur = op; _otpCtrl.clear(); }),
          ),
          const SizedBox(height: 20),

          const Text('Numéro de téléphone',
              style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                  color: AppColors.encre)),
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
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                    color: AppColors.encre)),
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

          if (_messageErreur != null || _messageInfo != null) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _messageErreur != null
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
                    if (_messageErreur != null) const SizedBox(height: 6),
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

          FilledButton.icon(
            onPressed: (_saisieValide && !_enTraitement) ? _initierPaiement : null,
            icon:  const Icon(Icons.payments_rounded),
            label: Text(
              'Payer ${Formatters.montant(montant, devise: devise)}',
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
            const SizedBox(height: 4),
            Text('Réf. : $_numCommande',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 10, color: AppColors.texteDoux)),
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
              'Paiement en cours.\nNe fermez pas l\'application.',
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
            const Icon(Icons.phone_android_rounded,
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
              'Vérification automatique (jusqu\'à 2 min).\n'
              'Ne fermez pas l\'application.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: AppColors.texteDoux, height: 1.5),
            ),
            const SizedBox(height: 32),
            if (_numCommande != null)
              Text('Réf. : $_numCommande',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 10, color: AppColors.texteDoux)),
            // Bouton Vérifier — visible après 30s si confirmation tarde
            if (_boutonVerifierDansAttente && _numCommande != null) ...[
              const SizedBox(height: 20),
              const Divider(),
              const SizedBox(height: 12),
              const Text(
                'La confirmation tarde ?',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: AppColors.texteDoux),
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: () {
                  _timerBoutonAttente?.cancel();
                  _boutonVerifierDansAttente = false;
                  _verifierPaiementManuellement();
                },
                icon:  const Icon(Icons.search_rounded, color: _couleurPro),
                label: const Text(
                  'Vérifier le paiement',
                  style: TextStyle(color: _couleurPro, fontWeight: FontWeight.w600),
                ),
                style: OutlinedButton.styleFrom(
                  side:    const BorderSide(color: _couleurPro),
                  padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 20),
                  shape:   RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                'Ne relancez PAS un nouveau paiement.',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 11,
                    color: AppColors.alerte,
                    fontStyle: FontStyle.italic),
              ),
            ],
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
              'Enregistrement de la cotisation…',
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

  Widget _vueSucces(int montant, String devise) {
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
              '${widget.membre.nom} — ${Formatters.montant(montant, devise: devise)}',
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
              child: const Text('Retour',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Enum ──────────────────────────────────────────────────────────────────────

enum _Etape { saisie, enCours, enregistrement, attente, succes }

// ── Widgets partagés ─────────────────────────────────────────────────────────

class _CarteMontant extends StatelessWidget {
  final int    montant;
  final String devise;
  const _CarteMontant({required this.montant, required this.devise});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color:        const Color(0xFFEAF4EE),
        borderRadius: BorderRadius.circular(16),
        border:       Border.all(color: const Color(0xFF1A6B3C).withValues(alpha: 0.2)),
      ),
      child: Column(
        children: [
          const Text('Montant de la cotisation',
              style: TextStyle(fontSize: 13, color: AppColors.texteDoux)),
          const SizedBox(height: 6),
          Text(
            Formatters.montant(montant, devise: devise),
            style: const TextStyle(
                fontSize: 28, fontWeight: FontWeight.w800, color: Color(0xFF1A6B3C)),
          ),
          const SizedBox(height: 4),
          const Text('Paiement sécurisé via SycaPay',
              style: TextStyle(fontSize: 11, color: AppColors.texteDoux)),
        ],
      ),
    );
  }
}

class _SelecteurOperateur extends StatelessWidget {
  final String               operateur;
  final ValueChanged<String> onChange;
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
