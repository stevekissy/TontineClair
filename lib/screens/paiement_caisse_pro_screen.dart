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
/// Workflow robuste :
///   1. Génère une numCommande unique (référence pivot)
///   2. Appelle l'Edge Function → login + checkoutpay + persistance Supabase
///   3. Si succès immédiat (Orange OTP) → crédite directement
///   4. Si pending → polling GetStatus toutes les 5s (max 2 min)
///      Le webhook SycaPay met aussi à jour Supabase en parallèle
///   5. Sur confirmation → ecrireTontineSansPIN → marquerCredite (anti double)
///   6. Sur timeout → affiche message + bouton "Vérifier le paiement"
///
/// Anti-gel : watchdog 65s + try/catch universel + never stuck on enCours
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
  final _telCtrl  = TextEditingController();
  final _otpCtrl  = TextEditingController();

  _EtapeCaisse _etape          = _EtapeCaisse.saisie;
  String?      _numCommande;        // référence pivot (TC_...)
  String?      _transactionId;     // ID SycaPay (optionnel, fallback)
  String?      _messageErreur;
  String?      _messageInfo;        // message informatif (ex: "paiement peut-être effectué")
  bool         _peutVerifierManuellement = false;
  int          _pollingSecondes   = 0;
  Timer?       _pollingTimer;
  Timer?       _watchdogTimer;     // anti-gel absolu (65s)

  @override
  void dispose() {
    _telCtrl.dispose();
    _otpCtrl.dispose();
    _pollingTimer?.cancel();
    _watchdogTimer?.cancel();
    super.dispose();
  }

  // ── Validation ────────────────────────────────────────────────────────────

  bool get _saisieValide {
    final tel = _telCtrl.text.trim();
    if (tel.length < 8)                                    return false;
    if (_operateur == 'orange' && _otpCtrl.text.trim().length < 4) return false;
    return true;
  }

  // ── Initier le paiement ───────────────────────────────────────────────────

  Future<void> _initierPaiement() async {
    if (!_saisieValide) return;

    // Générer la référence pivot AVANT setState (pour la garder même en cas d'erreur)
    final numCmd = SycaPayService.genererNumCommande(
      widget.code,
      'CAISSE${DateTime.now().millisecondsSinceEpoch ~/ 1000}',
    );
    _numCommande = numCmd;

    setState(() {
      _etape                     = _EtapeCaisse.enCours;
      _messageErreur             = null;
      _messageInfo               = null;
      _peutVerifierManuellement  = false;
    });

    // ── Watchdog 65s : anti-gel absolu ──────────────────────────────────────
    _watchdogTimer?.cancel();
    _watchdogTimer = Timer(const Duration(seconds: 65), () {
      if (!mounted || _etape != _EtapeCaisse.enCours) return;
      if (kDebugMode) debugPrint('[CaissePro] WATCHDOG 65s déclenché pour $numCmd');
      setState(() {
        _etape                    = _EtapeCaisse.saisie;
        _peutVerifierManuellement = true;
        _messageErreur            =
            '⏱ La connexion à SycaPay prend trop de temps.\n'
            'Réf. interne : $numCmd';
        _messageInfo              =
            'Si votre argent a été débité (vérifiez votre SMS), '
            'utilisez le bouton "Vérifier le paiement" ci-dessous '
            'au lieu de relancer un nouveau paiement.';
      });
    });

    try {
      // ── Appel Edge Function (login + checkoutpay + persistance Supabase) ──
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

      _watchdogTimer?.cancel();
      _transactionId = resultat.transactionId;

      if (!mounted) return;

      if (kDebugMode) {
        debugPrint('[CaissePro] initierPaiement → $resultat');
      }

      // ── Idempotent : déjà traité ──────────────────────────────────────────
      if (resultat.dejaConfirme) {
        setState(() => _etape = _EtapeCaisse.enregistrement);
        await _crediterCaisse();
        return;
      }

      // ── Erreur réseau ─────────────────────────────────────────────────────
      if (resultat.erreurReseau) {
        setState(() {
          _etape         = _EtapeCaisse.saisie;
          _messageErreur = resultat.messageFr;
          _peutVerifierManuellement = true;
          _messageInfo   = 'Si votre argent a été débité, utilisez "Vérifier le paiement".';
        });
        return;
      }

      // ── Échec immédiat (solde insuffisant, OTP incorrect, etc.) ───────────
      if (resultat.estEchec) {
        setState(() {
          _etape         = _EtapeCaisse.saisie;
          _messageErreur = resultat.messageFr;
        });
        return;
      }

      // ── Succès immédiat (Orange Money OTP validé) ─────────────────────────
      if (resultat.estSucces) {
        if (kDebugMode) debugPrint('[CaissePro] Succès immédiat → crédit direct');
        setState(() => _etape = _EtapeCaisse.enregistrement);
        await _crediterCaisse();
        return;
      }

      // ── En attente (Moov, MTN, Wave → confirmation USSD côté téléphone) ───
      if (resultat.estEnAttente || resultat.estExpire == false) {
        setState(() => _etape = _EtapeCaisse.attente);
        _lancerPolling();
        return;
      }

      // ── Cas inattendu ─────────────────────────────────────────────────────
      if (kDebugMode) debugPrint('[CaissePro] Statut inattendu: $resultat');
      setState(() => _etape = _EtapeCaisse.attente);
      _lancerPolling();

    } catch (e) {
      // ── Catch universel (TimeoutException, SocketException, parse error…) ─
      _watchdogTimer?.cancel();
      if (kDebugMode) debugPrint('[CaissePro] _initierPaiement EXCEPTION: $e');
      if (!mounted) return;
      setState(() {
        _etape                    = _EtapeCaisse.saisie;
        _peutVerifierManuellement = true;
        _messageErreur =
            '⚠️ Erreur de connexion à SycaPay.\n'
            'Réf. interne : ${_numCommande ?? "—"}';
        _messageInfo =
            'Si votre argent a été débité (vérifiez votre SMS), '
            'utilisez "Vérifier le paiement" avant de réessayer.';
      });
    }
  }

  // ── Polling statut (Moov / MTN / Wave) ───────────────────────────────────

  void _lancerPolling() {
    _pollingSecondes = 0;
    _pollingTimer?.cancel();

    _pollingTimer = Timer.periodic(const Duration(seconds: 5), (t) async {
      _pollingSecondes += 5;

      // Timeout global 2 minutes
      if (_pollingSecondes >= 120) {
        t.cancel();
        _watchdogTimer?.cancel();
        if (!mounted) return;
        setState(() {
          _etape                    = _EtapeCaisse.saisie;
          _peutVerifierManuellement = true;
          _messageErreur =
              '⏱ Délai de confirmation dépassé (2 min).\n'
              'Réf. : ${_numCommande ?? "—"}';
          _messageInfo =
              'Le paiement a peut-être été effectué. '
              'Vérifiez votre SMS, puis utilisez "Vérifier le paiement" '
              'sans relancer un nouveau paiement.';
        });
        return;
      }

      if (_numCommande == null) return;

      try {
        final statut = await SycaPayService.verifierStatut(
          _numCommande!,
          transactionId: _transactionId,
          tontineCode: widget.code,
        );

        if (!mounted) return;
        if (kDebugMode) {
          debugPrint('[CaissePro] Polling ${_pollingSecondes}s → $statut');
        }

        if (statut.estSucces) {
          t.cancel();
          _watchdogTimer?.cancel();
          setState(() => _etape = _EtapeCaisse.enregistrement);
          await _crediterCaisse();

        } else if (statut.estEchec) {
          t.cancel();
          _watchdogTimer?.cancel();
          setState(() {
            _etape         = _EtapeCaisse.saisie;
            _messageErreur = statut.messageFr;
          });

        } else if (statut.estExpire) {
          t.cancel();
          _watchdogTimer?.cancel();
          setState(() {
            _etape         = _EtapeCaisse.saisie;
            _messageErreur = 'Session SycaPay expirée. Veuillez réessayer.';
          });
        }
        // Sinon pending/unknown → continuer polling

      } catch (e) {
        if (kDebugMode) debugPrint('[CaissePro] Polling erreur: $e');
        // Continuer polling (erreur réseau temporaire)
      }
    });
  }

  // ── Vérification manuelle (bouton) ────────────────────────────────────────

  Future<void> _verifierPaiementManuellement() async {
    if (_numCommande == null) return;

    setState(() {
      _etape         = _EtapeCaisse.enCours;
      _messageErreur = null;
      _messageInfo   = null;
    });

    // Watchdog pour la vérification manuelle
    _watchdogTimer?.cancel();
    _watchdogTimer = Timer(const Duration(seconds: 30), () {
      if (!mounted || _etape != _EtapeCaisse.enCours) return;
      setState(() {
        _etape         = _EtapeCaisse.saisie;
        _messageErreur = 'Vérification impossible. Réseau lent.';
        _peutVerifierManuellement = true;
      });
    });

    try {
      // 1. Chercher dans Supabase (source de vérité)
      final refSupa = await SycaPayService.verifierReferenceSupabase(_numCommande!);
      _watchdogTimer?.cancel();

      if (!mounted) return;

      if (refSupa != null && refSupa.estSucces) {
        // Déjà confirmé dans Supabase → créditer
        setState(() => _etape = _EtapeCaisse.enregistrement);
        await _crediterCaisse();
        return;
      }

      // 2. Demander à SycaPay directement
      final statut = await SycaPayService.verifierStatut(
        _numCommande!,
        transactionId: _transactionId,
        tontineCode: widget.code,
      );

      if (!mounted) return;

      if (statut.estSucces) {
        setState(() => _etape = _EtapeCaisse.enregistrement);
        await _crediterCaisse();
      } else if (statut.estEnAttente) {
        // Relancer le polling
        setState(() {
          _etape     = _EtapeCaisse.attente;
          _messageInfo = 'Paiement toujours en attente. Vérification en cours…';
        });
        _lancerPolling();
      } else {
        setState(() {
          _etape         = _EtapeCaisse.saisie;
          _messageErreur = statut.messageFr;
          _peutVerifierManuellement = statut.estExpire;
          _messageInfo   = statut.estExpire
              ? 'Le paiement n\'a pas abouti. Vous pouvez réessayer.'
              : null;
        });
      }
    } catch (e) {
      _watchdogTimer?.cancel();
      if (!mounted) return;
      setState(() {
        _etape         = _EtapeCaisse.saisie;
        _messageErreur = 'Vérification échouée: $e';
        _peutVerifierManuellement = true;
      });
    }
  }

  // ── Créditer la caisse (après confirmation SycaPay) ───────────────────────

  Future<void> _crediterCaisse() async {
    _pollingTimer?.cancel();
    _watchdogTimer?.cancel();

    // ── GARDE ANTI-DOUBLE-CRÉDIT ───────────────────────────────────────────
    // L'Edge Function vérifie aussi, mais on vérifie localement en premier
    if (_numCommande != null) {
      try {
        final refSupa = await SycaPayService.verifierReferenceSupabase(_numCommande!);
        if (refSupa != null) {
          final rawStatus = refSupa.statusNormalise;
          if (rawStatus == 'credited') {
            if (!mounted) return;
            if (kDebugMode) debugPrint('[CaissePro] Déjà crédité en DB → succes sans ré-écriture');
            setState(() => _etape = _EtapeCaisse.succes);
            return;
          }
        }
      } catch (_) {
        // Non bloquant
      }
    }

    final provider = context.read<TontineProvider>();
    final data     = provider.courante!.data;
    final newData  = data.toJson();

    final ref = _transactionId ?? _numCommande ?? Formatters.genererReference();
    final now = DateTime.now().toIso8601String();

    // ── Construire le mouvement caisse ─────────────────────────────────────
    final caisseMap = newData['caisse'];
    final caisse = List<Map<String, dynamic>>.from(
      caisseMap is Map<String, dynamic>
          ? ((caisseMap['mouvements'] as List<dynamic>?)
                  ?.cast<Map<String, dynamic>>() ?? [])
          : caisseMap is List
              ? (caisseMap as List<dynamic>).cast<Map<String, dynamic>>()
              : [],
    );

    caisse.add({
      'id':            ref,
      'type':          'apport',
      'montant':       widget.montant,
      'description':   widget.description.isNotEmpty
          ? widget.description
          : 'Apport Premium via SycaPay (${_operateur.toUpperCase()})',
      'gestionnaire':  provider.gestActifNom ?? '',
      'date':          now,
      'reference':     ref,
      'methode':       'sycapay',
      'operateur':     _operateur,
      'transactionId': _transactionId,
      'numCommande':   _numCommande,
    });
    newData['caisse'] = {'mouvements': caisse};

    // ── Journal ────────────────────────────────────────────────────────────
    final journal = List<Map<String, dynamic>>.from(
      (newData['journal'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ?? [],
    );
    journal.insert(0, {
      'quoi': 'APPORT CAISSE Premium via SycaPay (${_operateur.toUpperCase()}) — '
              '${Formatters.montant(widget.montant, devise: data.devise)}'
              '${widget.description.isNotEmpty ? " — ${widget.description}" : ""}',
      'par':  provider.gestActifNom ?? '',
      'le':   DateTime.now().millisecondsSinceEpoch,
      'ref':  ref,
    });
    newData['journal'] = journal;

    // ── Écriture Supabase (30s timeout) ───────────────────────────────────
    bool   ok            = false;
    String? erreurDetail;

    try {
      ok = await SupabaseService.ecrireTontineSansPIN(
        code: widget.code,
        data: newData,
      ).timeout(const Duration(seconds: 30), onTimeout: () => false);
    } catch (e) {
      ok           = false;
      erreurDetail = e.toString();
      if (kDebugMode) debugPrint('[CaissePro] ecrireTontineSansPIN ERREUR: $e');
    }

    if (!mounted) return;

    if (ok) {
      // ── Marquer crédité dans Supabase (anti double-crédit) ────────────────
      if (_numCommande != null) {
        SycaPayService.marquerCredite(_numCommande!).catchError((e) {
          if (kDebugMode) debugPrint('[CaissePro] marquerCredite non critique: $e');
          return false;
        });
      }

      // Recharger la tontine (non bloquant)
      try {
        await provider
            .chargerTontine(widget.code)
            .timeout(const Duration(seconds: 15));
      } catch (_) {}
      if (!mounted) return;

      // Notification push (non bloquante)
      try {
        final lang  = Provider.of<LocaleService>(context, listen: false).langue.code; // ignore: use_build_context_synchronously
        final t     = SupabaseService.notifTexte('caisse', lang, vars: {
          'montant': Formatters.montant(widget.montant, devise: data.devise),
          'libelle': 'Apport caisse Premium',
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

    } else {
      // ── Écriture Supabase échouée — paiement OK mais caisse non créditée ─
      final estErreurFonction = erreurDetail != null &&
          (erreurDetail!.contains('introuvable') || erreurDetail!.contains('404') ||
           erreurDetail!.contains('PGRST'));

      setState(() {
        _etape         = _EtapeCaisse.saisie;
        _peutVerifierManuellement = true;
        _messageErreur = estErreurFonction
            ? '⚠️ Configuration Supabase incomplète (SQL manquant).\n'
              'Exécutez supabase-sycapay-transactions.sql + '
              'supabase-fix-sycapay-sans-pin.sql dans Supabase SQL Editor.\n'
              'Réf. paiement : ${_numCommande ?? ref}'
            : '⚠️ Paiement SycaPay confirmé mais enregistrement échoué.\n'
              'Réf. : ${_numCommande ?? ref}\n'
              'Votre caisse sera créditée manuellement.';
        _messageInfo = 'Notez la référence ci-dessus et contactez le gestionnaire.';
      });
    }
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
        elevation: 0,
        title: const Text(
          'Apport de caisse Premium',
          style: TextStyle(
            fontWeight: FontWeight.w700,
            color: AppColors.encre,
            fontSize: 16,
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
              color: const Color(0xFFEAF4EE),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: _couleurPro.withValues(alpha: 0.2)),
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
              hintText:   '07 XX XX XX XX',
              counterText: '',
              prefixIcon: Icon(Icons.phone_rounded),
              border:     OutlineInputBorder(),
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
                hintText:   'Code OTP (ex: 7908)',
                counterText: '',
                prefixIcon: Icon(Icons.lock_outline_rounded),
                border:     OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
          ],

          // Message erreur
          if (_messageErreur != null) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color:        AppColors.alerteFond,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
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
                    const SizedBox(height: 8),
                    Text(_messageInfo!,
                        style: const TextStyle(
                            color: AppColors.alerte,
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
            onPressed: _saisieValide ? _initierPaiement : null,
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

          // Bouton vérifier paiement (après timeout)
          if (_peutVerifierManuellement && _numCommande != null) ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _verifierPaiementManuellement,
              icon:  const Icon(Icons.search_rounded, color: _couleurPro),
              label: const Text('Vérifier le paiement',
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
              'Réf. : $_numCommande',
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
              'Enregistrement de l\'apport en cours…',
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

  Widget _vueAttente() {
    final restant = 120 - _pollingSecondes;
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
              'Confirmez l\'apport\nsur votre téléphone',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: AppColors.encre),
            ),
            const SizedBox(height: 8),
            Text(
              'Vérification toutes les 5 secondes…\nExpire dans ${restant > 0 ? restant : 0} s.',
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 13, color: AppColors.texteDoux, height: 1.5),
            ),
            const SizedBox(height: 32),
            OutlinedButton(
              onPressed: () {
                _pollingTimer?.cancel();
                _watchdogTimer?.cancel();
                setState(() {
                  _etape                    = _EtapeCaisse.saisie;
                  _peutVerifierManuellement = true;
                  _messageErreur            = 'Paiement annulé par l\'utilisateur.';
                  _messageInfo              =
                      'Si votre argent a été débité, utilisez "Vérifier le paiement".';
                });
              },
              child: const Text('Annuler'),
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
            const Text('Apport enregistré !',
                style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    color: AppColors.encre)),
            const SizedBox(height: 8),
            Text(
              '${Formatters.montant(widget.montant, devise: devise)} versé dans la caisse',
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
                shape:   RoundedRectangleBorder(
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
