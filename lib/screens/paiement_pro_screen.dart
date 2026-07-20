import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/tontine.dart';
import '../services/tontine_provider.dart';
import '../services/sycapay_service.dart';
import '../services/supabase_service.dart';
import '../services/locale_service.dart';
import '../services/pdf_service.dart';
import '../utils/app_colors.dart';
import '../utils/app_localizations.dart';
import '../utils/formatters.dart';
import '../widgets/app_widgets.dart';

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

class _PaiementProScreenState extends State<PaiementProScreen>
    with WidgetsBindingObserver {
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
  // Wave QR/URL
  String? _waveUrl;
  String? _waveImg;
  Timer?  _timerPollWave;
  // Suivi retour foreground Wave
  bool    _waveOuvert             = false; // true = l'app Wave a été ouverte
  String? _waveNumCmd;                     // numCommande en cours pour Wave
  int?    _waveMontant;                    // montant en cours pour Wave

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  /// Détecte le retour au foreground après paiement Wave
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed && _waveOuvert) {
      _waveOuvert = false; // reset
      if (_etape == _Etape.attenteWave && _waveNumCmd != null) {
        if (kDebugMode) debugPrint('[Wave] Retour foreground → vérification immédiate');
        // Vérification immédiate au retour de Wave (n'attend pas les 5s du polling)
        _verifierWaveImmediatement(_waveNumCmd!, _waveMontant ?? 0);
      }
    }
  }

  /// Vérification immédiate Wave au retour de l'app (foreground) :
  /// → appelle d'abord GetStatus, si confirmé → confirmerEtCrediter pour créditer.
  Future<void> _verifierWaveImmediatement(String numCmd, int montant) async {
    if (!mounted || _etape != _Etape.attenteWave) return;
    try {
      // Étape 1 : vérifier le statut chez SycaPay
      final statut = await SycaPayService.verifierStatut(
        numCmd,
        transactionId: _transactionId,
        tontineCode:   widget.code,
      );
      if (!mounted) return;
      if (kDebugMode) debugPrint('[Wave] verifierImmediat → ${statut.statusNormalise} code=${statut.code}');

      // ⚠️ SÉCURITÉ v5 : on N'utilise plus statut.estSucces ni code==0 pour créditer.
      // verifierStatut retourne ok:false TOUJOURS. needsCredit:true = GetStatus a confirmé.
      if (statut.needsCredit || statut.statusNormalise == 'confirmed') {
        // GetStatus a confirmé → demander crédit côté serveur (confirmerEtCrediter)
        _timerPollWave?.cancel();
        setState(() => _etape = _Etape.attente);
        await _crediterWaveConfirme(numCmd, montant);
      } else if (statut.estEchec) {
        _timerPollWave?.cancel();
        setState(() {
          _etape         = _Etape.saisie;
          _messageErreur = statut.messageFr;
        });
      }
      // pending → le polling continue
    } catch (_) { /* réseau → polling continue */ }
  }

  /// Crédite un paiement Wave confirmé via confirmerEtCrediter (crédit côté serveur).
  ///
  /// ⚠️ SÉCURITÉ v5 : NE PLUS appeler verifierStatut pour créditer.
  /// verifierStatut retourne ok:false toujours — uniquement confirmerEtCrediter crédite.
  Future<void> _crediterWaveConfirme(String numCmd, int montant) async {
    try {
      if (kDebugMode) debugPrint('[Wave] _crediterWaveConfirme → confirmerEtCrediter (sécurisé)');
      _numCommande = numCmd;
      await _confirmerEtCrediterSecurise(montant);
    } catch (e) {
      if (!mounted) return;
      if (kDebugMode) debugPrint('[Wave] _crediterWaveConfirme erreur: $e');
      setState(() {
        _etape                    = _Etape.saisie;
        _peutVerifierManuellement = true;
        _messageErreur = '\u26a0\ufe0f Paiement Wave reçu, vérification en cours.\nRéf. : $numCmd';
        _messageInfo   = 'Utilisez « Vérifier mon paiement » pour finaliser.';
      });
    }
  }

  /// Appelle confirmerEtCrediter côté serveur et gère la réponse.
  ///
  /// ⚠️ SÉCURITÉ v5 : SEULE méthode autorisant un crédit dans Flutter.
  /// Le crédit est effectué uniquement si l'Edge Function confirme GetStatus code=0.
  Future<void> _confirmerEtCrediterSecurise(int montant) async {
    if (_numCommande == null) return;
    final numCmd = _numCommande!;
    try {
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

      if (kDebugMode) debugPrint('[PaiementPro] confirmerEtCrediter → $confirmation');

      if (confirmation.ok) {
        _transactionId ??= confirmation.transactionId;
        setState(() => _etape = _Etape.enregistrement);
        await _rechargerEtSucces(montant);
      } else if (confirmation.estEnAttente || confirmation.timeout) {
        setState(() {
          _etape                    = _Etape.saisie;
          _peutVerifierManuellement = true;
          _messageErreur = '⏳ Confirmation en attente.\nRéf. : $numCmd';
          _messageInfo   = 'Utilisez « Vérifier mon paiement » pour finaliser. Ne relancez pas.';
        });
      } else {
        setState(() {
          _etape                    = _Etape.saisie;
          _messageErreur            = confirmation.messageFr;
          _peutVerifierManuellement = confirmation.statusNormalise == 'unknown';
        });
      }
    } catch (e) {
      _enTraitement = false;
      if (!mounted) return;
      setState(() {
        _etape                    = _Etape.saisie;
        _peutVerifierManuellement = true;
        _messageErreur = '⚠️ Erreur de connexion.\nRéf. : ${_numCommande ?? "—"}';
        _messageInfo   = 'Si votre argent a été débité, utilisez « Vérifier mon paiement » avant de réessayer.';
      });
    }
  }

  @override
  void dispose() {
    _telCtrl.dispose();
    _otpCtrl.dispose();
    _watchdogTimer?.cancel();
    _timerBoutonAttente?.cancel();
    _timerPollWave?.cancel();
    WidgetsBinding.instance.removeObserver(this);
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

      // ── CAS WAVE : QR généré, utilisateur doit scanner/ouvrir l'URL ──────────
      if (resultat.estPendingWave) {
        _watchdogTimer?.cancel();
        _enTraitement = false;
        _waveUrl = resultat.waveUrl;
        _waveImg = resultat.waveImg;
        setState(() => _etape = _Etape.attenteWave);
        // Lancer le polling toutes les 5 secondes (max 3 min)
        _lancerPollWave(numCmd, montant);
        return;
      }

      // Étape 2 : polling + crédit serveur-side (Orange/Moov/MTN)
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

      if (kDebugMode) debugPrint('[PaiementPro] verif manuelle → $statut needsCredit=${statut.needsCredit}');

      // ⚠️ SÉCURITÉ v5 :
      // action:statut retourne ok:false TOUJOURS.
      // Si le backend a confirmé via GetStatus → needsCredit:true.
      // On appelle alors confirmerEtCrediter() côté serveur pour le crédit réel.
      // On N'effectue JAMAIS de crédit direct sur statut.estSucces.
      if (statut.needsCredit) {
        // GetStatus a confirmé — demander au serveur de créditer (vérification stricte)
        if (kDebugMode) debugPrint('[PaiementPro] needsCredit=true → appel confirmerEtCrediter');
        _transactionId ??= statut.transactionId;
        setState(() {
          _etape       = _Etape.attente;
          _messageInfo = '⏳ Confirmation en cours, ne fermez pas l’écran…';
        });
        await _confirmerEtCrediterSecurise(montant);
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

  // ── Polling Wave : vérifier toutes les 5s si l'utilisateur a payé ──────────

  void _lancerPollWave(String numCmd, int montant) {
    // Sauvegarder pour WidgetsBindingObserver
    _waveNumCmd  = numCmd;
    _waveMontant = montant;

    const dureeMax     = Duration(minutes: 3);
    const intervalle   = Duration(seconds: 5);
    final debut        = DateTime.now();
    _timerPollWave?.cancel();

    _timerPollWave = Timer.periodic(intervalle, (timer) async {
      if (!mounted) { timer.cancel(); return; }
      if (_etape != _Etape.attenteWave) { timer.cancel(); return; }

      // Timeout 3 min
      if (DateTime.now().difference(debut) > dureeMax) {
        timer.cancel();
        if (!mounted) return;
        setState(() {
          _etape                    = _Etape.saisie;
          _peutVerifierManuellement = true;
          _messageErreur = '⏱ Paiement Wave non détecté après 3 min.\nRéf. : $numCmd';
          _messageInfo   = 'Si Wave vous a débité, utilisez « Vérifier mon paiement ».';
        });
        return;
      }

      try {
        final statut = await SycaPayService.verifierStatut(
          numCmd,
          transactionId: _transactionId,
          tontineCode:   widget.code,
        );

        if (!mounted) { timer.cancel(); return; }
        if (kDebugMode) debugPrint('[Wave poll] statut=${statut.statusNormalise} code=${statut.code}');

        // ⚠️ SÉCURITÉ v5 : on N'utilise plus statut.estSucces ni code==0.
        // verifierStatut retourne ok:false toujours. needsCredit:true = GetStatus confirmé.
        if (statut.needsCredit || statut.statusNormalise == 'confirmed') {
          // GetStatus a confirmé → demander crédit côté serveur (confirmerEtCrediter)
          timer.cancel();
          setState(() => _etape = _Etape.attente);
          await _crediterWaveConfirme(numCmd, montant);
        } else if (statut.estEchec) {
          timer.cancel();
          setState(() {
            _etape         = _Etape.saisie;
            _messageErreur = statut.messageFr;
          });
        }
        // pending → continuer le polling
      } catch (_) {
        // Erreur réseau → continuer le polling silencieusement
      }
    });
  }

  // ── Recharger et afficher succès ──────────────────────────────────────────

  Future<void> _rechargerEtSucces(int montant) async {
    final provider = context.read<TontineProvider>();
    try {
      await provider.chargerTontine(widget.code).timeout(const Duration(seconds: 15));
    } catch (_) {}
    if (!mounted) return;

    // ── Notification push ─────────────────────────────────────────────────
    try {
      final data   = provider.courante?.data;
      final devise = data?.devise ?? 'XOF';
      final lang   = Provider.of<LocaleService>(context, listen: false).langue.code; // ignore: use_build_context_synchronously
      final t      = SupabaseService.notifTexte('cotisation', lang, vars: {
        'montant': Formatters.montant(montant, devise: devise),
        'nom':     widget.membre.nom,
        'libelle': 'Cotisation Premium',
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

    // ── Proposer le reçu avec les données SycaPay ─────────────────────────
    // Après rechargement, extraire les détails réels depuis paiements{}
    try {
      final tontine = provider.courante;
      if (tontine != null && mounted) {
        final paiements = (tontine.data.toJson()['paiements'] as Map<String, dynamic>?) ?? {};
        final paiementData = paiements[widget.membre.id] as Map<String, dynamic>?;

        // Construire référence, méthode et date à partir des données SycaPay
        final ref      = (paiementData?['reference']   as String?) ?? _numCommande ?? '—';
        final methode  = (paiementData?['methode']     as String?) ?? 'sycapay';
        final dateStr  = (paiementData?['date']        as String?) ?? DateTime.now().toIso8601String();

        // Construire un Membre actualisé avec toutes les infos de paiement
        final membreActualise = Membre(
          id:                widget.membre.id,
          nom:               widget.membre.nom,
          tel:               widget.membre.tel,
          role:              widget.membre.role,
          paye:              true,
          datePaiement:      dateStr,
          methodePaiement:   methode,
          referencePaiement: ref,
          score:             widget.membre.score,
        );

        if (mounted) { // ignore: use_build_context_synchronously
          await _proposerRecuSycaPay(context, tontine, membreActualise, ref, methode, dateStr);
        }
      }
    } catch (_) {}

    if (!mounted) return;
    setState(() => _etape = _Etape.succes);
  }

  // ── Reçu SycaPay : dialog WhatsApp / PDF / Ignorer ───────────────────────

  Future<void> _proposerRecuSycaPay(
    BuildContext ctx,
    dynamic tontine,
    Membre membre,
    String ref,
    String methode,
    String dateStr,
  ) async {
    if (!ctx.mounted) return;
    await showDialog<void>(
      context: ctx,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: AppColors.fondPapier,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: const Text(
          '📲 Envoyer le reçu ?',
          style: TextStyle(fontWeight: FontWeight.w700, color: AppColors.encre),
        ),
        content: Text(
          'Cotisation de ${membre.nom} enregistrée '
          '(${Formatters.montant(tontine.data.montant, devise: tontine.data.devise)}).\n\nComment souhaitez-vous partager le reçu ?',
          style: const TextStyle(color: AppColors.texte),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: Text(ctx.tr('ignorer')),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(dialogCtx);
              if (ctx.mounted) {
                await _genererRecuPdfSycaPay(ctx, tontine, membre, ref, methode, dateStr);
              }
            },
            child: const Text(
              '📄 PDF',
              style: TextStyle(color: AppColors.encre, fontWeight: FontWeight.w700),
            ),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(dialogCtx);
              if (ctx.mounted) {
                _envoyerRecuWhatsApp(ctx, tontine, membre, ref, methode, dateStr);
              }
            },
            child: const Text(
              'WhatsApp',
              style: TextStyle(color: AppColors.whatsapp, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }

  void _envoyerRecuWhatsApp(
    BuildContext ctx,
    dynamic tontine,
    Membre membre,
    String ref,
    String methode,
    String dateStr,
  ) {
    final data = tontine.data;
    final lignes = [
      '✅ Reçu de cotisation — TontineClair',
      'Tontine : ${data.nom}',
      'Membre : ${membre.nom}',
      'Montant : ${Formatters.montant(data.montant, devise: data.devise)}',
      'Tour : ${data.numerTour}',
      'Date : ${Formatters.dateHeure(DateTime.tryParse(dateStr))}',
      'Méthode : ${Formatters.methodePaiement(methode)}',
      'Réf. : $ref',
      'Code tontine : ${tontine.code}',
    ];
    final msg = Uri.encodeComponent(lignes.join('\n'));
    final tel = (membre.tel ?? '').replaceAll(RegExp(r'[^0-9+]'), '');
    final url = tel.isNotEmpty
        ? Uri.parse('https://wa.me/$tel?text=$msg')
        : Uri.parse('https://wa.me/?text=$msg');
    launchUrl(url, mode: LaunchMode.externalApplication);
  }

  Future<void> _genererRecuPdfSycaPay(
    BuildContext ctx,
    dynamic tontine,
    Membre membre,
    String ref,
    String methode,
    String dateStr,
  ) async {
    try {
      await PdfService.exporterRecuCotisation(
        tontine:     tontine,
        membre:      membre,
        ref:         ref,
        methode:     methode,
        dateStr:     dateStr,
        langueCode:  Provider.of<LocaleService>(ctx, listen: false).langue.code,
      );
    } catch (e) {
      if (ctx.mounted) {
        afficherToast(ctx, 'Erreur PDF : $e', estErreur: true);
      }
    }
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
        _Etape.attenteWave    => _vueAttenteWave(montant),
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
            const Text('Connexion en cours…',
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

  // ── Vue Wave : affiche le bouton + QR pour scanner ────────────────────────

  Widget _vueAttenteWave(int montant) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const SizedBox(height: 16),
          // En-tête Wave
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.lightBlue.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.lightBlue.withValues(alpha: 0.4)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: const [
                Icon(Icons.waves_rounded, color: Colors.lightBlue, size: 28),
                SizedBox(width: 10),
                Text('Paiement Wave',
                    style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: Colors.lightBlue)),
              ],
            ),
          ),
          const SizedBox(height: 20),
          const Text(
            'Appuyez sur le bouton ci-dessous pour\nfinaliser votre paiement sur Wave.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 15, color: AppColors.encre, height: 1.5),
          ),
          const SizedBox(height: 8),
          const Text(
            'Votre paiement sera automatiquement détecté\naprès validation sur Wave.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: AppColors.texteDoux, height: 1.5),
          ),
          const SizedBox(height: 24),

          // Bouton principal : ouvrir URL Wave
          if (_waveUrl != null && _waveUrl!.isNotEmpty)
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () async {
                  final waveUrlStr = _waveUrl!;
                  final uri = Uri.tryParse(waveUrlStr);
                  if (uri == null) return;

                  // Marquer que Wave a été ouvert → WidgetsBindingObserver
                  // déclenchera une vérification immédiate au retour
                  setState(() => _waveOuvert = true);
                  bool ouvert = false;

                  // Stratégie 1 : essayer scheme wave:// (deep link natif)
                  // pay.wave.com/c/xxx → wave://pay/c/xxx
                  try {
                    final wavePath = waveUrlStr.replaceFirst('https://pay.wave.com', 'wave://');
                    final waveUri  = Uri.tryParse(wavePath);
                    if (waveUri != null) {
                      ouvert = await launchUrl(waveUri, mode: LaunchMode.externalApplication);
                      if (kDebugMode) debugPrint('[Wave] scheme wave:// → ouvert=$ouvert');
                    }
                  } catch (_) {}

                  // Stratégie 2 : externalNonBrowserApplication sur URL https
                  if (!ouvert) {
                    try {
                      ouvert = await launchUrl(uri,
                          mode: LaunchMode.externalNonBrowserApplication);
                      if (kDebugMode) debugPrint('[Wave] externalNonBrowserApplication → ouvert=$ouvert');
                    } catch (_) {}
                  }

                  // Stratégie 3 : externalApplication (Android choisit Wave si installé)
                  if (!ouvert) {
                    try {
                      ouvert = await launchUrl(uri, mode: LaunchMode.externalApplication);
                      if (kDebugMode) debugPrint('[Wave] externalApplication → ouvert=$ouvert');
                    } catch (_) {
                      if (mounted) setState(() => _waveOuvert = false);
                    }
                  }

                  // Si toujours pas ouvert → Chrome en dernier recours
                  if (!ouvert) {
                    try {
                      await launchUrl(uri, mode: LaunchMode.platformDefault);
                    } catch (_) {
                      if (mounted) setState(() => _waveOuvert = false);
                    }
                  }
                },
                icon:  const Icon(Icons.waves_rounded, size: 20),
                label: const Text('Ouvrir Wave pour payer',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.lightBlue,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
              ),
            ),

          const SizedBox(height: 20),

          // QR Code à scanner
          if (_waveImg != null && _waveImg!.isNotEmpty) ...[
            const Text('Ou scannez ce QR code :',
                style: TextStyle(fontSize: 13, color: AppColors.texteDoux)),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.memory(
                Uri.parse(_waveImg!).data!.contentAsBytes(),
                width:  180,
                height: 180,
                fit:    BoxFit.contain,
              ),
            ),
          ],

          const SizedBox(height: 24),
          // Indicateur polling
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: const [
              SizedBox(
                width: 16, height: 16,
                child: CircularProgressIndicator(strokeWidth: 2, color: _couleurPro),
              ),
              SizedBox(width: 10),
              Text('Détection automatique en cours…',
                  style: TextStyle(fontSize: 12, color: AppColors.texteDoux)),
            ],
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
          const SizedBox(height: 16),
          if (_numCommande != null)
            Text('Réf. : $_numCommande',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 10, color: AppColors.texteDoux)),
          const SizedBox(height: 16),
          // Bouton vérification manuelle
          OutlinedButton.icon(
            onPressed: () {
              _timerPollWave?.cancel();
              _verifierPaiementManuellement();
            },
            icon:  const Icon(Icons.search_rounded, color: _couleurPro, size: 18),
            label: const Text('Vérifier le paiement',
                style: TextStyle(color: _couleurPro, fontWeight: FontWeight.w600)),
            style: OutlinedButton.styleFrom(
              side:    const BorderSide(color: _couleurPro),
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
              shape:   RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ],
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

enum _Etape { saisie, enCours, enregistrement, attente, attenteWave, succes }

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
          const Text('Paiement automatisé sécurisé',
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
