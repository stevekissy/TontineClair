import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/tontine.dart';
import '../services/tontine_provider.dart';
import '../services/paydunya_service.dart';
import '../services/supabase_service.dart';
import '../services/locale_service.dart';
import '../utils/app_colors.dart';
import '../utils/formatters.dart';

/// Écran de paiement PayDunya — Mobile Money.
///
/// Workflow identique à PaiementCoinPaymentsScreen :
///   1. Sélection de l'opérateur Mobile Money (Orange Money par défaut)
///   2. creerInvoice → checkout_url + token PayDunya
///   3. Ouverture du checkout_url dans le navigateur (page PayDunya)
///   4. Polling toutes les 8s (max 15 min) pour détecter la confirmation
///   5. Dès status "completed" → confirmerEtCrediter → crédit Supabase
///   6. Affichage "Paiement confirmé"
///
/// Design : identique à PaiementCoinPaymentsScreen.
class PaiementPayDunyaScreen extends StatefulWidget {
  final String  code;
  final String  typeFlux;
  final Membre? membre;
  final int?    montant;
  final String  description;
  final String? membreId;
  final String? membreNom;
  final String? membreEmail;
  final String? telephone;
  final String? pretId;
  final int?    taux;
  final int?    dureesMois;
  final int?    numeroTour;

  const PaiementPayDunyaScreen({
    super.key,
    required this.code,
    required this.typeFlux,
    this.membre,
    this.montant,
    this.description = 'Paiement',
    this.membreId,
    this.membreNom,
    this.membreEmail,
    this.telephone,
    this.pretId,
    this.taux,
    this.dureesMois,
    this.numeroTour,
  });

  @override
  State<PaiementPayDunyaScreen> createState() =>
      _PaiementPayDunyaScreenState();
}

class _PaiementPayDunyaScreenState
    extends State<PaiementPayDunyaScreen>
    with WidgetsBindingObserver {

  // ── Couleur Mobile Money (vert PayDunya) ──────────────────────────────────
  static const _couleurMM  = Color(0xFF1AA259);   // vert PayDunya
  static const _couleurFond = Color(0xFFF2FBF6);

  // ── Opérateurs Mobile Money CI ────────────────────────────────────────────
  static const _operateurs = [
    ('orange-money-ci', 'Orange Money',  Color(0xFFFF6600)),
    ('wave-ci',         'Wave',          Color(0xFF1A73E8)),
    ('mtn-ci',          'MTN MoMo',      Color(0xFFFFCC00)),
    ('moov-ci',         'Moov Money',    Color(0xFF00A0DC)),
    ('djamo-ci',        'Djamo',         Color(0xFF6C63FF)),
  ];

  // ── État ─────────────────────────────────────────────────────────────────
  String        _operateur        = 'orange-money-ci';
  _EtapeMM      _etape            = _EtapeMM.saisie;
  String?       _pdToken;
  String?       _checkoutUrl;
  String?       _numCommande;
  String?       _messageErreur;
  String?       _messageInfo;
  bool          _enTraitement     = false;
  bool          _checkoutOuvert   = false;
  bool          _peutVerifier     = false;
  String?       _operateurConfirme;
  Timer?        _pollTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Retour foreground après paiement → vérification immédiate
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed && _checkoutOuvert) {
      _checkoutOuvert = false;
      if (_etape == _EtapeMM.attenteCheckout && _pdToken != null) {
        if (kDebugMode) debugPrint('[PayDunya] Retour foreground → vérif immédiate');
        _verifierStatutImmediatement();
      }
    }
  }

  // ── Montant ───────────────────────────────────────────────────────────────

  int get _montant {
    if (widget.typeFlux == 'cotisation') {
      final provider = context.read<TontineProvider>();
      return provider.courante?.data.montant ?? widget.montant ?? 0;
    }
    return widget.montant ?? 0;
  }

  String get _membreId  => widget.membreId  ?? widget.membre?.id  ?? '';
  String get _membreNom => widget.membreNom ?? widget.membre?.nom ?? '';

  String get _titreEcran {
    switch (widget.typeFlux) {
      case 'cotisation':         return 'Cotisation — Mobile Money';
      case 'caisse':             return 'Apport caisse — Mobile Money';
      case 'penalite':           return 'Pénalité — Mobile Money';
      case 'remboursement_pret': return 'Remboursement — Mobile Money';
      default:                   return 'Paiement Mobile Money';
    }
  }

  // ── Créer l'invoice PayDunya ──────────────────────────────────────────────

  Future<void> _creerInvoice() async {
    if (_enTraitement) return;
    _enTraitement = true;

    final montant = _montant;

    setState(() {
      _etape         = _EtapeMM.creation;
      _messageErreur = null;
      _messageInfo   = null;
      _peutVerifier  = false;
    });

    try {
      if (kDebugMode) debugPrint('[PayDunya] creerInvoice operateur=$_operateur');

      final resultat = await PayDunyaService.creerInvoice(
        tontineCode:    widget.code,
        typeOperation:  widget.typeFlux,
        montantXof:     montant,
        description:    widget.description,
        membreId:       _membreId.isNotEmpty ? _membreId : null,
        membreNom:      _membreNom.isNotEmpty ? _membreNom : null,
        membreEmail:    widget.membreEmail,
        telephone:      widget.telephone ?? widget.membre?.tel,
        pretId:         widget.pretId,
      );

      _enTraitement = false;
      if (!mounted) return;

      if (kDebugMode) {
        debugPrint('[PayDunya] Invoice créée token=${resultat.token}');
        debugPrint('[PayDunya] Ref: ${resultat.numCommande}');
      }

      _pdToken      = resultat.token;
      _checkoutUrl  = resultat.checkoutUrl;
      _numCommande  = resultat.numCommande;

      // Ouvrir directement la page PayDunya
      await _ouvrirCheckout();

    } on PayDunyaException catch (e) {
      _enTraitement = false;
      if (!mounted) return;
      setState(() {
        _etape         = _EtapeMM.saisie;
        _messageErreur = e.message;
      });
    } catch (e) {
      _enTraitement = false;
      if (!mounted) return;
      final errMsg = e.toString().replaceAll('Exception: ', '').replaceAll('ClientException: ', '');
      setState(() {
        _etape         = _EtapeMM.saisie;
        _messageErreur = '⚠️ $errMsg';
      });
    }
  }

  // ── Ouvrir la page PayDunya ───────────────────────────────────────────────

  Future<void> _ouvrirCheckout() async {
    if (_checkoutUrl == null) return;
    final uri = Uri.tryParse(_checkoutUrl!);
    if (uri == null) return;

    setState(() {
      _etape         = _EtapeMM.attenteCheckout;
      _checkoutOuvert = true;
    });

    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      if (mounted) setState(() => _checkoutOuvert = false);
    }

    // Lancer le polling auto
    _lancerPollingAuto();
  }

  // ── Polling automatique ───────────────────────────────────────────────────

  void _lancerPollingAuto() {
    _pollTimer?.cancel();
    const intervalle = Duration(seconds: 8);
    const maxTentatives = 112; // 15 min

    int tentatives = 0;
    _pollTimer = Timer.periodic(intervalle, (t) async {
      tentatives++;
      if (tentatives > maxTentatives) {
        t.cancel();
        if (mounted && _etape == _EtapeMM.attenteCheckout) {
          setState(() {
            _messageInfo = 'Délai dépassé. Si vous avez payé, le crédit sera automatique.';
          });
        }
        return;
      }
      if (_etape != _EtapeMM.attenteCheckout) {
        t.cancel();
        return;
      }
      try {
        final statut = await PayDunyaService.verifierStatut(
          token:       _pdToken,
          numCommande: _numCommande,
        );
        if (!mounted) { t.cancel(); return; }
        if (statut.ok || statut.needsCredit) {
          t.cancel();
          await _confirmerEtCrediter(_montant, _numCommande!);
        } else if (statut.annule || statut.echoue) {
          t.cancel();
          setState(() {
            _etape         = _EtapeMM.saisie;
            _peutVerifier  = true;
            _messageErreur = 'Paiement ${statut.status}.';
          });
        }
      } catch (_) {
        // Erreurs réseau transitoires ignorées — polling continue
      }
    });
  }

  // ── Vérification immédiate (retour foreground ou bouton manuel) ────────────

  Future<void> _verifierStatutImmediatement() async {
    if (_pdToken == null || _numCommande == null) return;
    if (_enTraitement) return;
    _enTraitement = true;

    final montant = _montant;

    setState(() {
      _etape         = _EtapeMM.verification;
      _messageErreur = null;
    });

    try {
      final statut = await PayDunyaService.verifierStatut(
        token:       _pdToken!,
        numCommande: _numCommande!,
      );

      _enTraitement = false;
      if (!mounted) return;

      if (kDebugMode) debugPrint('[PayDunya] verif immédiate → ${statut.status}');

      if (statut.ok || statut.needsCredit) {
        _pollTimer?.cancel();
        setState(() => _etape = _EtapeMM.confirmation);
        await _confirmerEtCrediter(montant, _numCommande!);
      } else if (statut.enAttente) {
        setState(() {
          _etape       = _EtapeMM.attenteCheckout;
          _messageInfo = '⏳ Paiement en attente de confirmation. Patientez…';
        });
      } else {
        setState(() {
          _etape         = _EtapeMM.saisie;
          _messageErreur = 'Statut: ${statut.status}';
          _peutVerifier  = true;
        });
      }
    } catch (e) {
      _enTraitement = false;
      if (!mounted) return;
      setState(() {
        _etape         = _EtapeMM.attenteCheckout;
        _messageErreur = 'Vérification échouée : $e';
        _peutVerifier  = true;
      });
    }
  }

  // ── Confirmer et créditer ─────────────────────────────────────────────────

  Future<void> _confirmerEtCrediter(int montant, String numCmd) async {
    try {
      if (kDebugMode) debugPrint('[PayDunya] confirmerEtCrediter → $numCmd');

      final confirmation = await PayDunyaService.confirmerEtCrediter(
        numCommande:   numCmd,
        tontineCode:   widget.code,
        typeOperation: widget.typeFlux,
        montantXof:    montant,
        membreId:      _membreId.isNotEmpty ? _membreId : null,
        membreNom:     _membreNom.isNotEmpty ? _membreNom : null,
        pretId:        widget.pretId,
      );

      if (!mounted) return;

      if (kDebugMode) debugPrint('[PayDunya] confirmerEtCrediter → ok=${confirmation.ok}');

      if (confirmation.ok) {
        _operateurConfirme = confirmation.operateur;
        setState(() => _etape = _EtapeMM.enregistrement);
        await _rechargerEtSucces(montant);
      } else if (confirmation.enAttente) {
        setState(() {
          _etape         = _EtapeMM.saisie;
          _peutVerifier  = true;
          _messageErreur = '⏳ Confirmation en attente.\nRéf. : $numCmd';
          _messageInfo   = 'Utilisez "Vérifier" quand le paiement est terminé.';
        });
      } else {
        setState(() {
          _etape         = _EtapeMM.saisie;
          _messageErreur = 'Paiement non confirmé. Réessayez.';
          _peutVerifier  = true;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _etape         = _EtapeMM.saisie;
        _peutVerifier  = true;
        _messageErreur = '⚠️ Erreur de connexion.\nRéf. : ${_numCommande ?? "—"}';
        _messageInfo   = 'Si vous avez payé, utilisez "Vérifier" pour finaliser.';
      });
    }
  }

  // ── Recharger et succès ───────────────────────────────────────────────────

  Future<void> _rechargerEtSucces(int montant) async {
    final provider = context.read<TontineProvider>();
    try {
      await provider.chargerTontine(widget.code).timeout(const Duration(seconds: 15));
    } catch (_) {}
    if (!mounted) return;

    try {
      final data   = provider.courante?.data;
      final devise = data?.devise ?? 'XOF';
      final lang   = Provider.of<LocaleService>(context, listen: false).langue.code; // ignore: use_build_context_synchronously
      final t      = SupabaseService.notifTexte(widget.typeFlux, lang, vars: {
        'montant': Formatters.montant(montant, devise: devise),
        'nom':     _membreNom,
        'libelle': 'PayDunya Mobile Money',
        'desc':    '',
      });
      SupabaseService.envoyerNotification(
        code:    widget.code,
        type:    'cotisation_mm_confirmee',
        titre:   t['titre'] ?? 'Paiement confirmé',
        message: t['message'] ?? 'Paiement PayDunya Mobile Money confirmé.',
        donneesExtra: {
          'membre':    _membreNom,
          'token':     _pdToken ?? '',
          'operateur': _operateurConfirme ?? _operateur,
        },
      );
    } catch (_) {}

    if (!mounted) return;
    setState(() => _etape = _EtapeMM.succes);
  }

  // ── BUILD ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<TontineProvider>(context);
    final data     = provider.courante?.data;
    final montant  = widget.typeFlux == 'cotisation'
        ? (data?.montant ?? widget.montant ?? 0)
        : (widget.montant ?? 0);
    final devise   = data?.devise ?? 'XOF';

    return Scaffold(
      backgroundColor: AppColors.fondPapier,
      appBar: AppBar(
        backgroundColor: AppColors.fondPapier,
        elevation: 0,
        title: Text(
          _titreEcran,
          style: const TextStyle(
            fontWeight: FontWeight.w700,
            color:      AppColors.encre,
            fontSize:   16,
          ),
        ),
        iconTheme: const IconThemeData(color: AppColors.encre),
      ),
      body: switch (_etape) {
        _EtapeMM.saisie          => _vueSaisie(montant, devise),
        _EtapeMM.creation        => _vueChargement('Création de la facture Mobile Money…'),
        _EtapeMM.attenteCheckout => _vueAttenteCheckout(montant, devise),
        _EtapeMM.verification    => _vueChargement('Vérification du paiement…'),
        _EtapeMM.confirmation    => _vueChargement('Confirmation en cours…'),
        _EtapeMM.enregistrement  => _vueEnregistrement(),
        _EtapeMM.succes          => _vueSucces(montant, devise),
      },
    );
  }

  // ── Vue saisie ────────────────────────────────────────────────────────────

  Widget _vueSaisie(int montant, String devise) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Carte montant
          _CarteMontantMM(montant: montant, devise: devise),
          const SizedBox(height: 24),

          // Sélecteur opérateur
          const Text(
            'Opérateur Mobile Money',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize:   14,
              color:      AppColors.encre,
            ),
          ),
          const SizedBox(height: 10),
          _SelecteurOperateur(
            selected:  _operateur,
            onChanged: (v) => setState(() => _operateur = v),
          ),
          const SizedBox(height: 16),

          // Info opérateur sélectionné
          _InfoOperateur(operateur: _operateur),
          const SizedBox(height: 20),

          // Message erreur / info
          if (_messageErreur != null || _messageInfo != null) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _messageErreur != null
                    ? AppColors.alerteFond
                    : const Color(0xFFF2FBF6),
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
                            color: AppColors.alerte, size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _messageErreur!,
                            style: const TextStyle(
                                color: AppColors.alerte, fontSize: 13),
                          ),
                        ),
                      ],
                    ),
                  if (_messageInfo != null) ...[
                    if (_messageErreur != null) const SizedBox(height: 6),
                    Text(
                      _messageInfo!,
                      style: TextStyle(
                        fontSize:  12,
                        color:     _messageErreur != null
                            ? AppColors.alerte
                            : AppColors.succes,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],

          // Bouton principal
          FilledButton.icon(
            onPressed: _enTraitement ? null : _creerInvoice,
            icon:  const Icon(Icons.phone_android_rounded),
            label: Text(
              'Payer ${Formatters.montant(montant, devise: devise)} par Mobile Money',
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
            ),
            style: FilledButton.styleFrom(
              backgroundColor:         _couleurMM,
              disabledBackgroundColor: AppColors.encre.withValues(alpha: 0.2),
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
            ),
          ),

          // Bouton vérifier (si invoice déjà créée)
          if (_peutVerifier && _pdToken != null) ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _enTraitement ? null : _verifierStatutImmediatement,
              icon: const Icon(Icons.search_rounded, color: _couleurMM),
              label: const Text('Vérifier mon paiement',
                  style: TextStyle(
                      color: _couleurMM, fontWeight: FontWeight.w600)),
              style: OutlinedButton.styleFrom(
                side:    const BorderSide(color: _couleurMM),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape:   RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
            ),
            if (_numCommande != null) ...[
              const SizedBox(height: 4),
              Text(
                'Réf. : $_numCommande',
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 10, color: AppColors.texteDoux),
              ),
            ],
          ],
        ],
      ),
    );
  }

  // ── Vue attente checkout ──────────────────────────────────────────────────

  Widget _vueAttenteCheckout(int montant, String devise) {
    final opInfo = _operateurs.firstWhere(
      (o) => o.$1 == _operateur,
      orElse: () => _operateurs.first,
    );

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const SizedBox(height: 8),

          // En-tête opérateur
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color:        _couleurFond,
              borderRadius: BorderRadius.circular(16),
              border:       Border.all(
                  color: opInfo.$3.withValues(alpha: 0.4)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.phone_android_rounded,
                    color: opInfo.$3, size: 28),
                const SizedBox(width: 10),
                Text(
                  'Paiement ${opInfo.$2}',
                  style: TextStyle(
                    fontSize:   18,
                    fontWeight: FontWeight.w700,
                    color:      opInfo.$3,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),

          const Text(
            'Montant à régler',
            style: TextStyle(fontSize: 13, color: AppColors.texteDoux),
          ),
          const SizedBox(height: 4),
          Text(
            Formatters.montant(montant, devise: devise),
            style: const TextStyle(
              fontSize:   26,
              fontWeight: FontWeight.w800,
              color:      AppColors.encre,
            ),
          ),
          const SizedBox(height: 20),

          const Text(
            'La page de paiement PayDunya a été ouverte dans votre navigateur.',
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 15, color: AppColors.encre, height: 1.5),
          ),
          const SizedBox(height: 8),
          Text(
            'Sélectionnez ${opInfo.$2} sur la page PayDunya\n'
            'et validez le paiement depuis votre téléphone.',
            textAlign: TextAlign.center,
            style: const TextStyle(
                fontSize: 12, color: AppColors.texteDoux, height: 1.5),
          ),
          const SizedBox(height: 24),

          // Bouton ré-ouvrir checkout
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _ouvrirCheckout,
              icon:  const Icon(Icons.open_in_browser_rounded, size: 20),
              label: const Text(
                'Ouvrir la page de paiement',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: _couleurMM,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Indicateur polling
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: const [
              SizedBox(
                width: 14, height: 14,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: _couleurMM),
              ),
              SizedBox(width: 10),
              Text(
                'Détection automatique en cours…',
                style: TextStyle(fontSize: 12, color: AppColors.texteDoux),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            'Ne relancez PAS un nouveau paiement.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize:  11,
              color:     AppColors.alerte,
              fontStyle: FontStyle.italic,
            ),
          ),

          if (_messageInfo != null) ...[
            const SizedBox(height: 12),
            Text(
              _messageInfo!,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize:  12,
                  color:     AppColors.succes,
                  fontStyle: FontStyle.italic),
            ),
          ],

          if (_numCommande != null) ...[
            const SizedBox(height: 12),
            Text(
              'Réf. : $_numCommande',
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 10, color: AppColors.texteDoux),
            ),
          ],

          const SizedBox(height: 24),

          // Bouton vérification manuelle
          OutlinedButton.icon(
            onPressed: _verifierStatutImmediatement,
            icon: const Icon(Icons.search_rounded,
                color: _couleurMM, size: 18),
            label: const Text(
              'Vérifier manuellement',
              style: TextStyle(
                  color: _couleurMM, fontWeight: FontWeight.w600),
            ),
            style: OutlinedButton.styleFrom(
              side:    const BorderSide(color: _couleurMM),
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
              shape:   RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ],
      ),
    );
  }

  // ── Vue chargement ────────────────────────────────────────────────────────

  Widget _vueChargement(String message) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(color: _couleurMM),
            const SizedBox(height: 24),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 15, color: AppColors.texte),
            ),
            const SizedBox(height: 8),
            const Text(
              'Ne fermez pas l\'application.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: AppColors.texteDoux),
            ),
          ],
        ),
      ),
    );
  }

  // ── Vue enregistrement ────────────────────────────────────────────────────

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
                color: _couleurFond,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.check_circle_outline_rounded,
                  size: 44, color: _couleurMM),
            ),
            const SizedBox(height: 20),
            const Text(
              'Paiement Mobile Money confirmé !',
              style: TextStyle(
                fontSize:   20,
                fontWeight: FontWeight.w800,
                color:      AppColors.encre,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Enregistrement en cours…',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: AppColors.texteDoux),
            ),
            const SizedBox(height: 24),
            const SizedBox(
              width: 28, height: 28,
              child: CircularProgressIndicator(
                  strokeWidth: 3, color: _couleurMM),
            ),
          ],
        ),
      ),
    );
  }

  // ── Vue succès ────────────────────────────────────────────────────────────

  Widget _vueSucces(int montant, String devise) {
    final opInfo = _operateurs.firstWhere(
      (o) => o.$1 == (_operateurConfirme ?? _operateur),
      orElse: () => _operateurs.first,
    );

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 80, height: 80,
              decoration: const BoxDecoration(
                color: _couleurFond,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.check_circle_rounded,
                  size: 50, color: _couleurMM),
            ),
            const SizedBox(height: 24),
            const Text(
              'Paiement reçu avec succès.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize:   22,
                fontWeight: FontWeight.w800,
                color:      AppColors.encre,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '${_membreNom.isNotEmpty ? "$_membreNom — " : ""}'
              '${Formatters.montant(montant, devise: devise)}\n'
              'Payé via ${opInfo.$2} (PayDunya).',
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 15, color: AppColors.texte, height: 1.5),
            ),
            if (_numCommande != null) ...[
              const SizedBox(height: 8),
              Text(
                'Réf. : $_numCommande',
                style: const TextStyle(
                    fontSize: 11, color: AppColors.texteDoux),
              ),
            ],
            const SizedBox(height: 40),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              style: FilledButton.styleFrom(
                backgroundColor: _couleurMM,
                padding: const EdgeInsets.symmetric(
                    horizontal: 32, vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
              child: const Text(
                'Retour',
                style: TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Enum étapes ───────────────────────────────────────────────────────────────

enum _EtapeMM {
  saisie,
  creation,
  attenteCheckout,
  verification,
  confirmation,
  enregistrement,
  succes,
}

// ── Widget carte montant ──────────────────────────────────────────────────────

class _CarteMontantMM extends StatelessWidget {
  final int    montant;
  final String devise;
  const _CarteMontantMM({required this.montant, required this.devise});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color:        const Color(0xFFF2FBF6),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
            color: const Color(0xFF1AA259).withValues(alpha: 0.25)),
      ),
      child: Column(
        children: [
          const Text(
            'Montant à payer',
            style: TextStyle(fontSize: 13, color: AppColors.texteDoux),
          ),
          const SizedBox(height: 6),
          Text(
            Formatters.montant(montant, devise: devise),
            style: const TextStyle(
              fontSize:   28,
              fontWeight: FontWeight.w800,
              color:      Color(0xFF1AA259),
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Paiement Mobile Money sécurisé — PayDunya',
            style: TextStyle(fontSize: 11, color: AppColors.texteDoux),
          ),
        ],
      ),
    );
  }
}

// ── Info opérateur sélectionné ────────────────────────────────────────────────

class _InfoOperateur extends StatelessWidget {
  final String operateur;
  const _InfoOperateur({required this.operateur});

  static const _infos = <String, (String, Color)>{
    'orange-money-ci': ('Orange Money CI : paiement instantané, confirmation immédiate.', Color(0xFFFF6600)),
    'wave-ci':         ('Wave CI : frais zéro, confirmation instantanée.', Color(0xFF1A73E8)),
    'mtn-ci':          ('MTN MoMo CI : paiement rapide via MTN Mobile Money.', Color(0xFFFFCC00)),
    'moov-ci':         ('Moov Money CI : paiement simple et rapide via Moov Africa.', Color(0xFF00A0DC)),
    'djamo-ci':        ('Djamo CI : paiement via votre carte ou compte Djamo.', Color(0xFF6C63FF)),
  };

  @override
  Widget build(BuildContext context) {
    final (msg, color) = _infos[operateur]
        ?? ('Sélectionnez votre opérateur Mobile Money.', const Color(0xFF1AA259));
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color:        color.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(10),
        border:       Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline_rounded, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              msg,
              style: const TextStyle(
                  fontSize: 12, color: AppColors.texte, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Sélecteur d'opérateur ─────────────────────────────────────────────────────

class _SelecteurOperateur extends StatelessWidget {
  final String               selected;
  final ValueChanged<String> onChanged;

  static const _items = [
    ('orange-money-ci', 'Orange Money',  Color(0xFFFF6600)),
    ('wave-ci',         'Wave',          Color(0xFF1A73E8)),
    ('mtn-ci',          'MTN MoMo',      Color(0xFFFFCC00)),
    ('moov-ci',         'Moov Money',    Color(0xFF00A0DC)),
    ('djamo-ci',        'Djamo',         Color(0xFF6C63FF)),
  ];

  const _SelecteurOperateur({
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: _items.map((item) {
        final (code, label, color) = item;
        final sel = selected == code;
        return GestureDetector(
          onTap: () => onChanged(code),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: sel
                  ? color.withValues(alpha: 0.12)
                  : AppColors.fondSecondaire,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: sel
                    ? color.withValues(alpha: 0.6)
                    : AppColors.lignes,
                width: sel ? 1.5 : 1.0,
              ),
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize:   13,
                fontWeight: sel ? FontWeight.w700 : FontWeight.w400,
                color:      sel ? color : AppColors.texte,
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}
