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

/// Écran de paiement Mobile Money pour un apport de caisse OU une pénalité Premium.
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
  /// 'caisse' | 'penalite' | 'remboursement_pret' | 'pret_octroye' | 'depense_caisse' | 'decaissement_cagnotte'
  final String typeOperation;
  /// ID du membre concerné
  final String? membreId;
  /// Nom du membre concerné
  final String? membreNom;
  /// ID du prêt (uniquement si typeOperation == 'remboursement_pret')
  final String? pretId;
  /// Numéro Mobile Money pré-rempli (dessaisissements)
  final String? telephone;
  /// Opérateur pré-sélectionné (dessaisissements)
  final String? operateur;
  /// Taux d’intérêt (prêt octroyé)
  final int? taux;
  /// Durée en mois (prêt octroyé)
  final int? dureesMois;
  /// Numéro du tour (décaissement cagnotte)
  final int? numeroTour;

  const PaiementCaisseProScreen({
    super.key,
    required this.code,
    required this.montant,
    required this.description,
    this.typeOperation = 'caisse',
    this.membreId,
    this.membreNom,
    this.pretId,
    this.telephone,
    this.operateur,
    this.taux,
    this.dureesMois,
    this.numeroTour,
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
  // Affichage progressif du bouton Vérifier pendant la phase attente (30s)
  bool         _boutonVerifierDansAttente = false;
  Timer?       _timerBoutonAttente;
  // ── Tracking tentatives (toutes, succès + échecs) ─────────────────────
  final List<TentativePaiement> _tentatives = [];

  @override
  void initState() {
    super.initState();
    // Pré-remplir depuis les paramètres optionnels (dessaisissements)
    if (widget.telephone != null && widget.telephone!.isNotEmpty) {
      _telCtrl.text = widget.telephone!;
    }
    if (widget.operateur != null && widget.operateur!.isNotEmpty) {
      _operateur = widget.operateur!;
    }
  }

  @override
  void dispose() {
    _telCtrl.dispose();
    _otpCtrl.dispose();
    _watchdogTimer?.cancel();
    _timerBoutonAttente?.cancel();
    super.dispose();
  }

  // ── Enregistrement d'une tentative ───────────────────────────────────────
  /// Ajoute une tentative à l'historique local.
  /// Appelé à chaque résultat final (succès, échec, timeout).
  void _enregistrerTentative(String statut, {String? message}) {
    if (_numCommande == null) return;
    _tentatives.add(TentativePaiement(
      numCommande:   _numCommande!,
      transactionId: _transactionId,
      montant:       widget.montant,
      typeOperation: widget.typeOperation,
      operateur:     _operateur,
      statut:        statut,
      message:       message,
      date:          DateTime.now(),
    ));
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
    final suffix = widget.typeOperation == 'penalite' ? 'PENAL'
        : widget.typeOperation == 'pret_octroye'           ? 'PRET'
        : widget.typeOperation == 'depense_caisse'         ? 'DEP'
        : widget.typeOperation == 'decaissement_cagnotte'  ? 'CAGNOTTE'
        : 'CAISSE';
    final numCmd = SycaPayService.genererNumCommande(
      widget.code,
      suffix,
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
        nomMembre:     widget.membreNom ?? 'Bénéficiaire',
        prenomMembre:  widget.typeOperation == 'penalite' ? 'Pénalité'
            : widget.typeOperation == 'pret_octroye'           ? 'Prêt'
            : widget.typeOperation == 'depense_caisse'         ? 'Dépense'
            : widget.typeOperation == 'decaissement_cagnotte'  ? 'Cagnotte'
            : 'Caisse',
        typeOperation: widget.typeOperation,
        membreId:      widget.membreId,
        membreNom:     widget.membreNom,
        pretId:        widget.pretId,
        description:   widget.description.isNotEmpty ? widget.description : null,
        taux:          widget.taux,
        dureesMois:    widget.dureesMois,
        numeroTour:    widget.numeroTour,
      );

      if (kDebugMode) debugPrint('[CaissePro] initierPaiement → $resultat');
      _transactionId = resultat.transactionId;

      if (!mounted) return;

      // Idempotent : déjà traité → afficher succès
      if (resultat.dejaConfirme) {
        _watchdogTimer?.cancel();
        _enTraitement = false;
        _enregistrerTentative('succes', message: 'Déjà crédité (idempotent)');
        setState(() => _etape = _EtapeCaisse.enregistrement);
        await _finaliserLocalement();
        return;
      }

      // Erreur réseau immédiate
      if (resultat.erreurReseau) {
        _watchdogTimer?.cancel();
        _enTraitement = false;
        _enregistrerTentative('echec', message: 'Erreur réseau: ${resultat.messageFr}');
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
        _enregistrerTentative('echec', message: resultat.messageFr);
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
      // Démarrer le timer qui rend visible le bouton Vérifier après 30s d'attente
      _boutonVerifierDansAttente = false;
      _timerBoutonAttente?.cancel();
      _timerBoutonAttente = Timer(const Duration(seconds: 30), () {
        if (!mounted || _etape != _EtapeCaisse.attente) return;
        setState(() => _boutonVerifierDansAttente = true);
      });
      setState(() => _etape = _EtapeCaisse.attente);

      if (kDebugMode) debugPrint('[CaissePro] Étape 2 — confirmer_et_crediter serveur');
      final confirmation = await SycaPayService.confirmerEtCrediter(
        numCommande:   numCmd,
        transactionId: _transactionId,
        tontineCode:   widget.code,
        typeOperation: widget.typeOperation,
        montant:       widget.montant,
        operateur:     _operateur,
        membreId:      widget.membreId,
        membreNom:     widget.membreNom,
        pretId:        widget.pretId,
        description:   widget.description.isNotEmpty ? widget.description : null,
        taux:          widget.taux,
        dureesMois:    widget.dureesMois,
        numeroTour:    widget.numeroTour,
      );

      _watchdogTimer?.cancel();
      _enTraitement = false;

      if (!mounted) return;
      if (kDebugMode) debugPrint('[CaissePro] confirmer_et_crediter → $confirmation');

      if (confirmation.ok) {
        // ✅ Serveur a confirmé ET crédité → Flutter recharge et affiche succès
        _enregistrerTentative('succes');
        setState(() => _etape = _EtapeCaisse.enregistrement);
        await _rechargerEtSucces();
      } else if (confirmation.estEnAttente || confirmation.timeout) {
        // Timeout Edge Fn → bouton Vérifier (sans "échec")
        _enregistrerTentative('attente', message: 'Confirmation en attente');
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
        _enregistrerTentative('echec', message: confirmation.messageFr);
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

      if (kDebugMode) debugPrint('[CaissePro] verif manuelle → $statut needsCredit=${statut.needsCredit}');

      // ⚠️ SÉCURITÉ v5 :
      // action:statut retourne ok:false TOUJOURS.
      // Si GetStatus a confirmé → needsCredit:true → appeler confirmerEtCrediter.
      // On N'effectue JAMAIS de crédit direct sur statut.estSucces.
      if (statut.needsCredit) {
        // GetStatus a confirmé — demander au serveur de créditer (vérification stricte)
        if (kDebugMode) debugPrint('[CaissePro] needsCredit=true → appel confirmerEtCrediter');
        _transactionId ??= statut.transactionId;
        setState(() {
          _etape       = _EtapeCaisse.attente;
          _messageInfo = '⏳ Confirmation en cours, ne fermez pas l\'écran…';
        });
        await _confirmerEtCrediterSecurise();
      } else if (statut.estEnAttente) {
        _enregistrerTentative('attente', message: 'Toujours en attente');
        setState(() {
          _etape                    = _EtapeCaisse.saisie;
          _peutVerifierManuellement = true;
          _messageInfo = '⏳ Paiement toujours en attente. Réessayez dans quelques instants.';
          _messageErreur = null;
        });
      } else {
        _enregistrerTentative('echec', message: statut.messageFr);
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

  /// Appelle confirmerEtCrediter côté serveur et gère la réponse.
  ///
  /// ⚠️ SÉCURITÉ v5 : SEULE méthode autorisant un crédit dans Flutter.
  /// Le crédit est effectué uniquement si l'Edge Function confirme GetStatus code=0.
  Future<void> _confirmerEtCrediterSecurise() async {
    if (_numCommande == null) return;
    final numCmd = _numCommande!;
    try {
      final confirmation = await SycaPayService.confirmerEtCrediter(
        numCommande:   numCmd,
        transactionId: _transactionId,
        tontineCode:   widget.code,
        typeOperation: widget.typeOperation,
        montant:       widget.montant,
        operateur:     _operateur,
        membreId:      widget.membreId,
        membreNom:     widget.membreNom,
        pretId:        widget.pretId,
        description:   widget.description.isNotEmpty ? widget.description : null,
        taux:          widget.taux,
        dureesMois:    widget.dureesMois,
        numeroTour:    widget.numeroTour,
      );

      _watchdogTimer?.cancel();
      _enTraitement = false;
      if (!mounted) return;

      if (kDebugMode) debugPrint('[CaissePro] confirmerEtCrediter → $confirmation');

      if (confirmation.ok) {
        _transactionId ??= confirmation.transactionId;
        _enregistrerTentative('succes', message: 'Crédité via confirmerEtCrediter');
        setState(() => _etape = _EtapeCaisse.enregistrement);
        await _rechargerEtSucces();
      } else if (confirmation.estEnAttente || confirmation.timeout) {
        _enregistrerTentative('attente', message: 'Confirmation en attente');
        setState(() {
          _etape                    = _EtapeCaisse.saisie;
          _peutVerifierManuellement = true;
          _messageErreur = '⏳ Confirmation en attente.\nRéf. : $numCmd';
          _messageInfo   = 'Utilisez « Vérifier mon paiement » pour finaliser. Ne relancez pas.';
        });
      } else {
        _enregistrerTentative('echec', message: confirmation.messageFr);
        setState(() {
          _etape                    = _EtapeCaisse.saisie;
          _messageErreur            = confirmation.messageFr;
          _peutVerifierManuellement = confirmation.statusNormalise == 'unknown';
        });
      }
    } catch (e) {
      _enTraitement = false;
      if (!mounted) return;
      setState(() {
        _etape                    = _EtapeCaisse.saisie;
        _peutVerifierManuellement = true;
        _messageErreur = '⚠️ Erreur de connexion.\nRéf. : ${_numCommande ?? "—"}';
        _messageInfo   = 'Si votre argent a été débité, utilisez « Vérifier mon paiement » avant de réessayer.';
      });
    }
  }

  // ── Recharger la tontine et afficher succès ───────────────────────────────
  // Le crédit a déjà été fait côté serveur.
  // Flutter recharge juste les données pour afficher la nouvelle balance.

  Future<void> _rechargerEtSucces() async {
    final provider = context.read<TontineProvider>();
    // FIX: retry robuste — 3 tentatives max, 8s chacune
    // Le crédit est déjà fait côté serveur, on doit juste lire les nouvelles données
    bool rechargementOk = false;
    for (int i = 0; i < 3; i++) {
      try {
        await provider.chargerTontine(widget.code).timeout(const Duration(seconds: 8));
        rechargementOk = true;
        break;
      } catch (_) {
        if (i < 2) await Future.delayed(const Duration(seconds: 2));
      }
    }
    if (kDebugMode) {
      debugPrint('[CaissePro] rechargement après crédit: $rechargementOk');
    }
    if (!mounted) return;

    // Notification push (non bloquante)
    try {
      final data   = provider.courante?.data;
      final devise = data?.devise ?? 'XOF';
      final lang   = Provider.of<LocaleService>(context, listen: false).langue.code; // ignore: use_build_context_synchronously
      final String notifType;
      final Map<String, String> notifVars;
      if (widget.typeOperation == 'penalite') {
        notifType = 'penalite';
        notifVars = {
          'montant': Formatters.montant(widget.montant, devise: devise),
          'nom':     widget.membreNom ?? '',
        };
      } else if (widget.typeOperation == 'pret_octroye') {
        notifType = 'pret_octroye';
        notifVars = {
          'montant': Formatters.montant(widget.montant, devise: devise),
          'nom':     widget.membreNom ?? '',
          'taux':    widget.taux?.toString() ?? '0',
          'duree':   widget.dureesMois?.toString() ?? '1',
        };
      } else if (widget.typeOperation == 'depense_caisse') {
        notifType = 'depense_caisse';
        notifVars = {
          'montant': Formatters.montant(widget.montant, devise: devise),
          'nom':     widget.membreNom ?? '',
          'desc':    widget.description.isNotEmpty ? widget.description : '-',
        };
      } else if (widget.typeOperation == 'decaissement_cagnotte') {
        notifType = 'decaissement_cagnotte';
        notifVars = {
          'montant': Formatters.montant(widget.montant, devise: devise),
          'nom':     widget.membreNom ?? '',
          'tour':    widget.numeroTour?.toString() ?? '-',
        };
      } else {
        notifType = 'caisse';
        notifVars = {
          'montant': Formatters.montant(widget.montant, devise: devise),
          'libelle': 'Apport caisse Premium',
          'nom':     widget.membreNom ?? '',
          'desc':    widget.description.isNotEmpty ? ' — ${widget.description}' : '',
        };
      }
      final t = SupabaseService.notifTexte(notifType, lang, vars: notifVars);
      SupabaseService.envoyerNotification(
        code:    widget.code,
        type:    notifType,
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
        title: Text(
          widget.typeOperation == 'penalite'            ? 'Pénalité Premium'
              : widget.typeOperation == 'pret_octroye'          ? 'Prêt automatisé'
              : widget.typeOperation == 'depense_caisse'        ? 'Dépense automatisée'
              : widget.typeOperation == 'decaissement_cagnotte' ? 'Décaissement automatisé'
              : widget.typeOperation == 'remboursement_pret'    ? 'Remboursement prêt'
              : 'Apport de caisse Premium',
          style: const TextStyle(
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
                // Badge membre pénalisé (uniquement pour pénalité)
                if (widget.membreNom != null && widget.membreNom!.isNotEmpty) ...[
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    margin: const EdgeInsets.only(bottom: 10),
                    decoration: BoxDecoration(
                      color: AppColors.orFonce.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: AppColors.orFonce.withValues(alpha: 0.35)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.person_rounded, size: 14, color: AppColors.orFonce),
                        const SizedBox(width: 6),
                        Text(
                          widget.typeOperation == 'remboursement_pret'   ? 'Emprunteur : ${widget.membreNom}'
                              : widget.typeOperation == 'pret_octroye'          ? 'Emprunteur : ${widget.membreNom}'
                              : widget.typeOperation == 'decaissement_cagnotte' ? 'Bénéficiaire : ${widget.membreNom}'
                              : widget.typeOperation == 'depense_caisse'        ? 'Bénéficiaire : ${widget.membreNom}'
                              : 'Pénalité pour : ${widget.membreNom}',
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: AppColors.orFonce,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                Text(
                  widget.typeOperation == 'penalite'              ? 'Montant de la pénalité'
                      : widget.typeOperation == 'remboursement_pret'    ? 'Montant du remboursement'
                      : widget.typeOperation == 'pret_octroye'          ? 'Montant du prêt'
                      : widget.typeOperation == 'depense_caisse'        ? 'Montant de la dépense'
                      : widget.typeOperation == 'decaissement_cagnotte' ? 'Montant du décaissement'
                      : 'Montant de l\'apport',
                  style: const TextStyle(fontSize: 13, color: AppColors.texteDoux),
                ),
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
                const Text('Paiement automatisé sécurisé',
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
              widget.typeOperation == 'penalite'
                  ? 'Payer pénalité ${Formatters.montant(widget.montant, devise: 'XOF')} via Mobile Money'
                  : widget.typeOperation == 'remboursement_pret'
                      ? 'Rembourser ${Formatters.montant(widget.montant, devise: 'XOF')} via Mobile Money'
                  : widget.typeOperation == 'pret_octroye'
                      ? 'Verser prêt ${Formatters.montant(widget.montant, devise: 'XOF')}'
                  : widget.typeOperation == 'depense_caisse'
                      ? 'Payer ${Formatters.montant(widget.montant, devise: 'XOF')}'
                  : widget.typeOperation == 'decaissement_cagnotte'
                      ? 'Décaisser ${Formatters.montant(widget.montant, devise: 'XOF')}'
                      : 'Verser ${Formatters.montant(widget.montant, devise: 'XOF')} via Mobile Money',
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
            const Text('Connexion en cours…',
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
            Text(
              widget.typeOperation == 'penalite'              ? 'Pénalité enregistrée !'
                  : widget.typeOperation == 'remboursement_pret'    ? 'Remboursement reçu !'
                  : widget.typeOperation == 'pret_octroye'          ? 'Prêt versé avec succès !'
                  : widget.typeOperation == 'depense_caisse'        ? 'Dépense effectuée !'
                  : widget.typeOperation == 'decaissement_cagnotte' ? 'Cagnotte décaissée !'
                  : 'Paiement reçu avec succès.',
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  color: AppColors.encre),
            ),
            const SizedBox(height: 8),
            Text(
              widget.typeOperation == 'penalite'
                  ? 'La pénalité de ${Formatters.montant(widget.montant, devise: devise)}'
                    '\na été appliquée à ${widget.membreNom ?? 'ce membre'}.'
                  : widget.typeOperation == 'pret_octroye'
                      ? '${Formatters.montant(widget.montant, devise: devise)} versés à ${widget.membreNom ?? 'l\'emprunteur'}. Paiement automatisé.'
                  : widget.typeOperation == 'depense_caisse'
                      ? 'Dépense de ${Formatters.montant(widget.montant, devise: devise)} enregistrée. Paiement automatisé.'
                  : widget.typeOperation == 'decaissement_cagnotte'
                      ? '${Formatters.montant(widget.montant, devise: devise)} décaissés pour ${widget.membreNom ?? 'le bénéficiaire'}. Paiement automatisé.'
                  : 'Votre apport de caisse a été enregistré.\n'
                    '${Formatters.montant(widget.montant, devise: devise)} versé dans la caisse.',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 15, color: AppColors.texte, height: 1.5),
            ),
            if (_transactionId != null) ...[
              const SizedBox(height: 8),
              Text('Réf. transaction : $_transactionId',
                  style: const TextStyle(fontSize: 11, color: AppColors.texteDoux)),
            ],
            if (_numCommande != null) ...[
              const SizedBox(height: 4),
              Text('Réf. interne : $_numCommande',
                  style: const TextStyle(fontSize: 10, color: AppColors.texteDoux)),
            ],
            const SizedBox(height: 40),
            FilledButton(
              onPressed: () => Navigator.pop(
                context,
                ResultatPaiementCaisse(succes: true, tentatives: _tentatives),
              ),
              style: FilledButton.styleFrom(
                backgroundColor: _couleurPro,
                padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
              child: Text(
                widget.typeOperation == 'penalite' ? 'Retour' : 'Retour à la caisse',
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Enum étapes ───────────────────────────────────────────────────────────────

enum _EtapeCaisse { saisie, enCours, enregistrement, attente, succes }

// ── Résultat de l'écran de paiement ──────────────────────────────────────────
/// Données retournées à la CaisseScreen lors du Navigator.pop()
class ResultatPaiementCaisse {
  final bool succes;
  final List<TentativePaiement> tentatives;

  const ResultatPaiementCaisse({
    required this.succes,
    required this.tentatives,
  });
}

/// Représente une tentative de paiement (succès ou échec) pour l'historique
class TentativePaiement {
  final String numCommande;
  final String? transactionId;
  final int montant;
  final String typeOperation;
  final String operateur;
  final String statut; // 'succes' | 'echec' | 'annule' | 'attente'
  final String? message;
  final DateTime date;

  const TentativePaiement({
    required this.numCommande,
    this.transactionId,
    required this.montant,
    required this.typeOperation,
    required this.operateur,
    required this.statut,
    this.message,
    required this.date,
  });

  String get statutLibelle {
    switch (statut) {
      case 'succes':  return '✅ Succès';
      case 'echec':   return '❌ Échec';
      case 'attente': return '⏳ En attente';
      case 'annule':  return '🚫 Annulé';
      default:        return statut;
    }
  }
}

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
