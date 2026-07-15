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
/// Workflow robuste (identique à PaiementCaisseProScreen) :
///   1. Génère numCommande unique (référence pivot) — jamais réutilisée
///   2. Edge Function : login + checkoutpay + persistance Supabase
///   3. Succès immédiat (Orange OTP) → crédit direct
///   4. Pending → polling GetStatus/5s + webhook SycaPay en parallèle
///   5. Confirmation → ecrireTontineSansPIN → marquerCredite (anti double)
///   6. Timeout → bouton "Vérifier le paiement" (jamais de loader infini)
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

  // ── État ──────────────────────────────────────────────────────────────────
  String _operateur = 'moov';
  final _telCtrl    = TextEditingController();
  final _otpCtrl    = TextEditingController();

  _Etape  _etape                    = _Etape.saisie;
  String? _numCommande;              // référence pivot TC_...
  String? _transactionId;
  String? _messageErreur;
  String? _messageInfo;
  bool    _peutVerifierManuellement = false;
  int     _pollingSecondes          = 0;
  Timer?  _pollingTimer;
  Timer?  _watchdogTimer;

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
    if (tel.length < 8) return false;
    if (_operateur == 'orange' && _otpCtrl.text.trim().length < 4) return false;
    return true;
  }

  // ── Initier le paiement ───────────────────────────────────────────────────

  Future<void> _initierPaiement() async {
    if (!_saisieValide) return;

    final provider = context.read<TontineProvider>();
    final data     = provider.courante!.data;
    final montant  = data.montant;

    // Générer la référence pivot (safe suffix = id membre alphanumerique)
    final numCmd = SycaPayService.genererNumCommande(
      widget.code,
      widget.membre.id,
    );
    _numCommande = numCmd;

    setState(() {
      _etape                    = _Etape.enCours;
      _messageErreur            = null;
      _messageInfo              = null;
      _peutVerifierManuellement = false;
    });

    // ── Watchdog 65s anti-gel absolu ────────────────────────────────────────
    _watchdogTimer?.cancel();
    _watchdogTimer = Timer(const Duration(seconds: 65), () {
      if (!mounted || _etape != _Etape.enCours) return;
      if (kDebugMode) debugPrint('[PaiementPro] WATCHDOG 65s → $numCmd');
      setState(() {
        _etape                    = _Etape.saisie;
        _peutVerifierManuellement = true;
        _messageErreur =
            '⏱ La connexion à SycaPay prend trop de temps.\n'
            'Réf. : $numCmd';
        _messageInfo =
            'Si votre argent a été débité, utilisez '
            '"Vérifier le paiement" sans relancer.';
      });
    });

    try {
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

      _watchdogTimer?.cancel();
      _transactionId = resultat.transactionId;

      if (!mounted) return;

      if (kDebugMode) debugPrint('[PaiementPro] initierPaiement → $resultat');

      // Idempotent : déjà traité
      if (resultat.dejaConfirme) {
        setState(() => _etape = _Etape.enregistrement);
        await _validerCotisation(provider, montant);
        return;
      }

      if (resultat.erreurReseau) {
        setState(() {
          _etape                    = _Etape.saisie;
          _messageErreur            = resultat.messageFr;
          _peutVerifierManuellement = true;
          _messageInfo = 'Si votre argent a été débité, utilisez "Vérifier le paiement".';
        });
        return;
      }

      if (resultat.estEchec) {
        setState(() {
          _etape         = _Etape.saisie;
          _messageErreur = resultat.messageFr;
        });
        return;
      }

      if (resultat.estSucces) {
        setState(() => _etape = _Etape.enregistrement);
        await _validerCotisation(provider, montant);
        return;
      }

      // Pending → polling
      setState(() => _etape = _Etape.attente);
      _lancerPolling(provider, montant);

    } catch (e) {
      _watchdogTimer?.cancel();
      if (kDebugMode) debugPrint('[PaiementPro] _initierPaiement EXCEPTION: $e');
      if (!mounted) return;
      setState(() {
        _etape                    = _Etape.saisie;
        _peutVerifierManuellement = true;
        _messageErreur =
            '⚠️ Erreur de connexion à SycaPay.\n'
            'Réf. : ${_numCommande ?? "—"}';
        _messageInfo =
            'Si votre argent a été débité, utilisez "Vérifier le paiement".';
      });
    }
  }

  // ── Polling ────────────────────────────────────────────────────────────────

  void _lancerPolling(TontineProvider provider, int montant) {
    _pollingSecondes = 0;
    _pollingTimer?.cancel();

    _pollingTimer = Timer.periodic(const Duration(seconds: 5), (t) async {
      _pollingSecondes += 5;

      if (_pollingSecondes >= 120) {
        t.cancel();
        _watchdogTimer?.cancel();
        if (!mounted) return;
        setState(() {
          _etape                    = _Etape.saisie;
          _peutVerifierManuellement = true;
          _messageErreur =
              '⏱ Délai de confirmation dépassé (2 min).\n'
              'Réf. : ${_numCommande ?? "—"}';
          _messageInfo =
              'Le paiement a peut-être été effectué. '
              'Vérifiez votre SMS, puis utilisez "Vérifier le paiement".';
        });
        return;
      }

      if (_numCommande == null) return;

      try {
        final statut = await SycaPayService.verifierStatut(
          _numCommande!,
          transactionId: _transactionId,
          tontineCode:   widget.code,
        );

        if (!mounted) return;
        if (kDebugMode) debugPrint('[PaiementPro] Polling ${_pollingSecondes}s → $statut');

        if (statut.estSucces) {
          t.cancel();
          _watchdogTimer?.cancel();
          setState(() => _etape = _Etape.enregistrement);
          await _validerCotisation(provider, montant);

        } else if (statut.estEchec) {
          t.cancel();
          _watchdogTimer?.cancel();
          setState(() {
            _etape         = _Etape.saisie;
            _messageErreur = statut.messageFr;
          });

        } else if (statut.estExpire) {
          t.cancel();
          _watchdogTimer?.cancel();
          setState(() {
            _etape         = _Etape.saisie;
            _messageErreur = 'Session SycaPay expirée. Veuillez réessayer.';
          });
        }
      } catch (e) {
        if (kDebugMode) debugPrint('[PaiementPro] Polling erreur: $e');
      }
    });
  }

  // ── Vérification manuelle ─────────────────────────────────────────────────

  Future<void> _verifierPaiementManuellement() async {
    if (_numCommande == null) return;

    final provider = context.read<TontineProvider>();
    final montant  = provider.courante?.data.montant ?? 0;

    setState(() {
      _etape         = _Etape.enCours;
      _messageErreur = null;
      _messageInfo   = null;
    });

    _watchdogTimer?.cancel();
    _watchdogTimer = Timer(const Duration(seconds: 30), () {
      if (!mounted || _etape != _Etape.enCours) return;
      setState(() {
        _etape                    = _Etape.saisie;
        _messageErreur            = 'Vérification impossible. Réseau lent.';
        _peutVerifierManuellement = true;
      });
    });

    try {
      // Chercher dans Supabase en premier
      final refSupa = await SycaPayService.verifierReferenceSupabase(_numCommande!);
      _watchdogTimer?.cancel();

      if (!mounted) return;

      if (refSupa != null && refSupa.estSucces) {
        setState(() => _etape = _Etape.enregistrement);
        await _validerCotisation(provider, montant);
        return;
      }

      // Sinon vérifier SycaPay directement
      final statut = await SycaPayService.verifierStatut(
        _numCommande!,
        transactionId: _transactionId,
        tontineCode:   widget.code,
      );
      if (!mounted) return;

      if (statut.estSucces) {
        setState(() => _etape = _Etape.enregistrement);
        await _validerCotisation(provider, montant);
      } else if (statut.estEnAttente) {
        setState(() {
          _etape       = _Etape.attente;
          _messageInfo = 'Toujours en attente. Nouvelle vérification en cours…';
        });
        _lancerPolling(provider, montant);
      } else {
        setState(() {
          _etape                    = _Etape.saisie;
          _messageErreur            = statut.messageFr;
          _peutVerifierManuellement = statut.estExpire;
        });
      }
    } catch (e) {
      _watchdogTimer?.cancel();
      if (!mounted) return;
      setState(() {
        _etape                    = _Etape.saisie;
        _messageErreur            = 'Vérification échouée: $e';
        _peutVerifierManuellement = true;
      });
    }
  }

  // ── Valider la cotisation (écriture Supabase + anti double-crédit) ─────────

  Future<void> _validerCotisation(TontineProvider provider, int montant) async {
    _pollingTimer?.cancel();
    _watchdogTimer?.cancel();

    // Garde anti-double-crédit
    if (_numCommande != null) {
      try {
        final refSupa = await SycaPayService.verifierReferenceSupabase(_numCommande!);
        if (refSupa != null && refSupa.statusNormalise == 'credited') {
          if (!mounted) return;
          if (kDebugMode) debugPrint('[PaiementPro] Déjà crédité → succes');
          setState(() => _etape = _Etape.succes);
          return;
        }
      } catch (_) {}
    }

    final data    = provider.courante!.data;
    final newData = data.toJson();
    final ref     = _transactionId ?? _numCommande ?? Formatters.genererReference();

    // Mettre à jour paiements{}
    final paiements = Map<String, dynamic>.from(
      (newData['paiements'] as Map<String, dynamic>?) ?? {},
    );
    paiements[widget.membre.id] = {
      'montant':        montant,
      'date':           DateTime.now().toIso8601String(),
      'methode':        'sycapay',
      'transactionId':  _transactionId,
      'numCommande':    _numCommande,
      'operateur':      _operateur,
      'statut':         'confirmed',
    };
    newData['paiements'] = paiements;

    // membres[].paye = true
    final membres = List<Map<String, dynamic>>.from(
      (newData['membres'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ?? [],
    );
    final idx = membres.indexWhere((m) => m['id'] == widget.membre.id);
    if (idx != -1) membres[idx]['paye'] = true;
    newData['membres'] = membres;

    // Journal
    final journal = List<Map<String, dynamic>>.from(
      (newData['journal'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ?? [],
    );
    journal.insert(0, {
      'quoi': 'Cotisation Premium payée via SycaPay (${_operateur.toUpperCase()}) — '
              '${Formatters.montant(montant, devise: data.devise)} — '
              '${widget.membre.nom}',
      'par':  widget.membre.nom,
      'le':   DateTime.now().millisecondsSinceEpoch,
      'ref':  ref,
    });
    newData['journal'] = journal;

    bool    ok           = false;
    String? erreurDetail;

    try {
      ok = await SupabaseService.ecrireTontineSansPIN(
        code: widget.code,
        data: newData,
      ).timeout(const Duration(seconds: 30), onTimeout: () => false);
    } catch (e) {
      ok           = false;
      erreurDetail = e.toString();
      if (kDebugMode) debugPrint('[PaiementPro] ecrireTontineSansPIN ERREUR: $e');
    }

    if (!mounted) return;

    if (ok) {
      // Marquer crédité (non bloquant)
      if (_numCommande != null) {
        SycaPayService.marquerCredite(_numCommande!).catchError((e) {
          if (kDebugMode) debugPrint('[PaiementPro] marquerCredite: $e');
          return false;
        });
      }

      // Recharger (non bloquant)
      try {
        await provider
            .chargerTontine(widget.code)
            .timeout(const Duration(seconds: 15));
      } catch (_) {}
      if (!mounted) return;

      // Notification (non bloquante)
      try {
        final lang   = Provider.of<LocaleService>(context, listen: false).langue.code;
        final tNotif = SupabaseService.notifTexte(
          'cotisation_pro_confirmee', lang,
          vars: {
            'nom':  widget.membre.nom,
            'tour': provider.courante!.data.numerTour.toString(),
          },
        );
        SupabaseService.envoyerNotification(
          code:    widget.code,
          type:    'cotisation_pro_confirmee',
          titre:   tNotif['titre']!,
          message: tNotif['message']!,
          donneesExtra: {
            'membre':        widget.membre.nom,
            'transactionId': _transactionId ?? '',
          },
        );
      } catch (_) {}

      setState(() => _etape = _Etape.succes);

    } else {
      final estErreurFonction = erreurDetail != null &&
          (erreurDetail!.contains('introuvable') || erreurDetail!.contains('404') ||
           erreurDetail!.contains('PGRST'));

      setState(() {
        _etape                    = _Etape.saisie;
        _peutVerifierManuellement = true;
        _messageErreur = estErreurFonction
            ? '⚠️ Configuration Supabase incomplète.\n'
              'Exécutez les SQL manquants dans Supabase SQL Editor.\n'
              'Réf. paiement : ${_numCommande ?? ref}'
            : '⚠️ Paiement SycaPay confirmé mais enregistrement échoué.\n'
              'Réf. : ${_numCommande ?? ref}';
        _messageInfo = 'Notez la référence et contactez le gestionnaire.';
      });
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
              color: AppColors.encre,
              fontSize: 16),
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
              hintText:   '07 XX XX XX XX',
              counterText: '',
              prefixIcon: Icon(Icons.phone_rounded),
              border:     OutlineInputBorder(),
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
                style: TextStyle(
                    fontSize: 13, color: Colors.deepOrange, height: 1.5),
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
                hintText:   'Code OTP (ex: 7908)',
                counterText: '',
                prefixIcon: Icon(Icons.lock_outline_rounded),
                border:     OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
          ],

          // Message erreur + info
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
                    const SizedBox(height: 6),
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

          // Bouton vérification manuelle
          if (_peutVerifierManuellement && _numCommande != null) ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _verifierPaiementManuellement,
              icon:  const Icon(Icons.search_rounded, color: _couleurPro),
              label: const Text('Vérifier le paiement',
                  style: TextStyle(
                      color: _couleurPro, fontWeight: FontWeight.w600)),
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
                style: const TextStyle(
                    fontSize: 10, color: AppColors.texteDoux)),
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
              style: TextStyle(
                  fontSize: 12,
                  color: AppColors.texteDoux,
                  height: 1.5),
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
              'Enregistrement de la cotisation en cours…',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: AppColors.texteDoux),
            ),
            const SizedBox(height: 24),
            const SizedBox(
              width: 28, height: 28,
              child: CircularProgressIndicator(
                  strokeWidth: 3, color: _couleurPro),
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
            const Icon(Icons.phone_android_rounded,
                size: 48, color: AppColors.texteDoux),
            const SizedBox(height: 16),
            const Text(
              'Confirmez le paiement\nsur votre téléphone',
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
                  _etape                    = _Etape.saisie;
                  _peutVerifierManuellement = true;
                  _messageErreur            = 'Annulé par l\'utilisateur.';
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
            const Text('Paiement confirmé !',
                style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    color: AppColors.encre)),
            const SizedBox(height: 8),
            Text(
              '${widget.membre.nom} a payé\n${Formatters.montant(montant, devise: devise)}',
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 15, color: AppColors.texte, height: 1.5),
            ),
            if (_transactionId != null) ...[
              const SizedBox(height: 8),
              Text('Réf. SycaPay : $_transactionId',
                  style: const TextStyle(
                      fontSize: 11, color: AppColors.texteDoux)),
            ],
            if (_numCommande != null) ...[
              const SizedBox(height: 4),
              Text('Réf. interne : $_numCommande',
                  style: const TextStyle(
                      fontSize: 10, color: AppColors.texteDoux)),
            ],
            const SizedBox(height: 40),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              style: FilledButton.styleFrom(
                backgroundColor: _couleurPro,
                padding: const EdgeInsets.symmetric(
                    horizontal: 32, vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
              child: const Text('Retour',
                  style: TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w700)),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Enum étapes ───────────────────────────────────────────────────────────────

enum _Etape { saisie, enCours, enregistrement, attente, succes }

// ── Widget : carte montant ────────────────────────────────────────────────────

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
        border:
            Border.all(color: const Color(0xFF1A6B3C).withValues(alpha: 0.2)),
      ),
      child: Column(
        children: [
          const Text('Montant de la cotisation',
              style: TextStyle(fontSize: 13, color: AppColors.texteDoux)),
          const SizedBox(height: 6),
          Text(
            Formatters.montant(montant, devise: devise),
            style: const TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.w800,
                color: Color(0xFF1A6B3C)),
          ),
          const SizedBox(height: 4),
          const Text('Paiement sécurisé via SycaPay',
              style: TextStyle(fontSize: 11, color: AppColors.texteDoux)),
        ],
      ),
    );
  }
}

// ── Widget : sélecteur d'opérateur ───────────────────────────────────────────

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
