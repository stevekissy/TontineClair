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
import '../widgets/app_widgets.dart';

/// Écran de paiement Mobile Money pour une cotisation Pro.
///
/// Flux :
///   1. Membre sélectionne son opérateur (Orange / Moov / MTN / Wave)
///   2. Saisit son numéro de téléphone
///   3. Orange : saisit le code OTP (#144*8*2#)
///   4. Confirme → appel SycaPayService.initierPaiement()
///   5. Polling GetStatus toutes les 5s pendant 2 minutes
///   6. Succès → écriture cotisation dans Supabase + notification
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
  String _operateur = 'moov'; // 'orange' | 'moov' | 'mtn' | 'wave'
  final _telCtrl = TextEditingController();
  final _otpCtrl = TextEditingController();

  _Etape _etape = _Etape.saisie;
  String? _transactionId;
  String? _messageErreur;
  int      _pollingSecondes = 0;
  Timer?   _pollingTimer;
  Timer?   _watchdogTimer;          // ← protège contre le gel sur enCours
  DateTime? _debutEnregistrement;

  @override
  void dispose() {
    _telCtrl.dispose();
    _otpCtrl.dispose();
    _pollingTimer?.cancel();
    _watchdogTimer?.cancel();
    super.dispose();
  }

  // ── Valider saisie ────────────────────────────────────────────────────────

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

    setState(() {
      _etape         = _Etape.enCours;
      _messageErreur = null;
    });

    // ── Watchdog 60 s : force la sortie de enCours si tout explose ──────────
    _watchdogTimer?.cancel();
    _watchdogTimer = Timer(const Duration(seconds: 60), () {
      if (mounted && _etape == _Etape.enCours) {
        if (kDebugMode) debugPrint('[PaiementPro] WATCHDOG déclenché — forçage retour saisie');
        setState(() {
          _etape         = _Etape.saisie;
          _messageErreur =
              '⏱ Délai SycaPay dépassé (60 s). '
              'Si votre argent a été débité, notez la référence '
              'et contactez le gestionnaire. Vous pouvez réessayer.';
        });
      }
    });

    try {
      final numCommande = SycaPayService.genererNumCommande(
        widget.code,
        widget.membre.id,
      );

      final resultat = await SycaPayService.initierPaiement(
        telephone:    _telCtrl.text.trim(),
        montant:      montant,
        numCommande:  numCommande,
        operateur:    _operateur,
        otp:          _operateur == 'orange' ? _otpCtrl.text.trim() : null,
        nomMembre:    widget.membre.nom.split(' ').last,
        prenomMembre: widget.membre.nom.split(' ').first,
      );

      _watchdogTimer?.cancel();
      if (!mounted) return;

      if (resultat.erreurReseau) {
        setState(() {
          _etape         = _Etape.saisie;
          _messageErreur = resultat.messageFr;
        });
        return;
      }

      if (resultat.estEchec && !resultat.estEnAttente) {
        setState(() {
          _etape         = _Etape.saisie;
          _messageErreur = resultat.messageFr;
        });
        return;
      }

      _transactionId = resultat.transactionId;

      if (resultat.estSucces) {
        // Succès immédiat (Orange Money OTP) → état enregistrement visible
        setState(() => _etape = _Etape.enregistrement);
        await _validerCotisation(provider, montant);
      } else {
        // Pending → polling jusqu'à confirmation ou timeout 2 min
        setState(() => _etape = _Etape.attente);
        _demarrerPolling(provider, montant);
      }
    } catch (e) {
      // ── Catch universel : TimeoutException, SocketException, erreur parsing, etc.
      _watchdogTimer?.cancel();
      if (kDebugMode) debugPrint('[PaiementPro] _initierPaiement EXCEPTION: $e');
      if (!mounted) return;
      setState(() {
        _etape         = _Etape.saisie;
        _messageErreur =
            '⚠️ Erreur de connexion SycaPay. '
            'Si votre argent a été débité (vérifiez votre SMS), '
            'notez la référence et contactez le gestionnaire avant de réessayer.';
      });
    }
  }

  // ── Polling statut ────────────────────────────────────────────────────────

  void _demarrerPolling(TontineProvider provider, int montant) {
    _pollingSecondes = 0;
    _pollingTimer = Timer.periodic(const Duration(seconds: 5), (t) async {
      _pollingSecondes += 5;

      if (_pollingSecondes >= 120) {
        t.cancel();
        if (!mounted) return;
        setState(() {
          _etape         = _Etape.saisie;
          _messageErreur = 'Délai dépassé. Le paiement n\'a pas été confirmé. Vérifiez votre solde.';
        });
        return;
      }

      if (_transactionId == null) return;

      final statut = await SycaPayService.verifierStatut(_transactionId!);
      if (!mounted) return;

      if (statut.estSucces) {
        t.cancel();
        if (mounted) setState(() => _etape = _Etape.enregistrement);
        await _validerCotisation(provider, montant);
      } else if (statut.estEchec && statut.code != -200 && statut.code != -9) {
        t.cancel();
        setState(() {
          _etape         = _Etape.saisie;
          _messageErreur = statut.messageFr;
        });
      }
      // code -200 (pending) ou -9 (statut pas encore dispo) → continuer polling
    });
  }

  // ── Écrire la cotisation confirmée ────────────────────────────────────────

  Future<void> _validerCotisation(TontineProvider provider, int montant) async {
    _pollingTimer?.cancel();
    _debutEnregistrement = DateTime.now();

    final data    = provider.courante!.data;
    final newData = data.toJson();

    // Mettre à jour paiements{} — même structure que le mode Lite
    final paiements = Map<String, dynamic>.from(
      (newData['paiements'] as Map<String, dynamic>?) ?? {},
    );
    paiements[widget.membre.id] = {
      'montant':       montant,
      'date':          DateTime.now().toIso8601String(),
      'methode':       'sycapay',
      'transactionId': _transactionId,
      'operateur':     _operateur,
      'statut':        'confirmed',
    };
    newData['paiements'] = paiements;

    // Mettre à jour membres[].paye = true
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
      'quoi': 'Cotisation Pro payée via SycaPay (${_operateur.toUpperCase()}) — '
              '${Formatters.montant(montant, devise: data.devise)} — '
              '${widget.membre.nom}',
      'par':  widget.membre.nom,
      'le':   DateTime.now().millisecondsSinceEpoch,
      'ref':  _transactionId ?? '',
    });
    newData['journal'] = journal;

    // Écriture en base sans PIN avec timeout explicite de 30s
    bool ok = false;
    String? erreurDetail;
    try {
      ok = await SupabaseService.ecrireTontineSansPIN(
        code: widget.code,
        data: newData,
      ).timeout(const Duration(seconds: 30), onTimeout: () => false);
    } catch (e) {
      ok = false;
      erreurDetail = e.toString();
      if (kDebugMode) debugPrint('[PaiementPro] ecrireTontineSansPIN ERREUR: $e');
    }

    if (!mounted) return;

    if (ok) {
      // Recharger (non bloquant — timeout 15s)
      try {
        await provider.chargerTontine(widget.code)
            .timeout(const Duration(seconds: 15));
      } catch (_) {}
      if (!mounted) return;

      // Notification push (non bloquante)
      try {
        final lang = Provider.of<LocaleService>(context, listen: false).langue.code;
        final tNotif = SupabaseService.notifTexte(
          'cotisation_pro_confirmee',
          lang,
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
          (erreurDetail.contains('introuvable') || erreurDetail.contains('404'));
      setState(() {
        _etape = _Etape.saisie;
        _messageErreur = estErreurFonction
            ? '⚠️ Configuration Supabase incomplète. '
              'Exécutez supabase-fix-sycapay-sans-pin.sql dans Supabase SQL Editor. '
              'Réf. : ${_transactionId ?? "inconnue"}'
            : '⚠️ Paiement SycaPay reçu (${_operateur.toUpperCase()}) '
              'mais enregistrement échoué. '
              'Réf. : ${_transactionId ?? "inconnue"}. '
              'Retentez ou contactez le gestionnaire.';
      });
    }
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<TontineProvider>(context);
    final data     = provider.courante?.data;
    final montant  = data?.montant ?? 0;
    final devise   = data?.devise ?? 'XOF';

    return Scaffold(
      backgroundColor: AppColors.fondPapier,
      appBar: AppBar(
        backgroundColor: AppColors.fondPapier,
        elevation: 0,
        title: Text(
          'Cotisation Pro — ${widget.membre.nom}',
          style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.encre, fontSize: 16),
        ),
        iconTheme: const IconThemeData(color: AppColors.encre),
      ),
      body: switch (_etape) {
        _Etape.saisie          => _vueSaisie(montant, devise),
        _Etape.enCours         => _vueEnCours(),
        _Etape.enregistrement  => _vueEnregistrement(),
        _Etape.attente         => _vueAttente(),
        _Etape.succes          => _vueSucces(montant, devise),
      },
    );
  }

  // ── Vue : formulaire de saisie ─────────────────────────────────────────────

  Widget _vueSaisie(int montant, String devise) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Montant à payer
          _CarteMontant(montant: montant, devise: devise),
          const SizedBox(height: 24),

          // Sélection opérateur
          const Text('Opérateur Mobile Money', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: AppColors.encre)),
          const SizedBox(height: 10),
          _SelecteurOperateur(
            operateur: _operateur,
            onChange: (op) => setState(() { _operateur = op; _otpCtrl.clear(); }),
          ),
          const SizedBox(height: 20),

          // Numéro de téléphone
          const Text('Numéro de téléphone', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: AppColors.encre)),
          const SizedBox(height: 8),
          TextField(
            controller: _telCtrl,
            keyboardType: TextInputType.phone,
            maxLength: 10,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              hintText: '07 XX XX XX XX',
              counterText: '',
              prefixIcon: Icon(Icons.phone_rounded),
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),

          // OTP Orange
          if (_operateur == 'orange') ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.orange.shade50,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.orange.shade200),
              ),
              child: const Text(
                'Orange Money requiert un code OTP.\n'
                'Composez  #144*8*2#  sur votre téléphone pour le générer.',
                style: TextStyle(fontSize: 13, color: Colors.deepOrange, height: 1.5),
              ),
            ),
            const SizedBox(height: 12),
            const Text('Code OTP Orange', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: AppColors.encre)),
            const SizedBox(height: 8),
            TextField(
              controller: _otpCtrl,
              keyboardType: TextInputType.number,
              maxLength: 8,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                hintText: 'Code OTP (ex: 7908)',
                counterText: '',
                prefixIcon: Icon(Icons.lock_outline_rounded),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
          ],

          // Erreur
          if (_messageErreur != null) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.alerteFond,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  const Icon(Icons.error_outline_rounded, color: AppColors.alerte),
                  const SizedBox(width: 10),
                  Expanded(child: Text(_messageErreur!, style: const TextStyle(color: AppColors.alerte, fontSize: 13))),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],

          // Bouton payer
          FilledButton.icon(
            onPressed: _saisieValide ? _initierPaiement : null,
            icon: const Icon(Icons.payments_rounded),
            label: Text(
              'Payer ${Formatters.montant(montant, devise: devise)}',
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
            ),
            style: FilledButton.styleFrom(
              backgroundColor: _couleurPro,
              disabledBackgroundColor: AppColors.encre.withValues(alpha: 0.2),
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
          ),
        ],
      ),
    );
  }

  // ── Vue : en cours ─────────────────────────────────────────────────────────

  Widget _vueEnCours() {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircularProgressIndicator(color: Color(0xFF1A6B3C)),
          SizedBox(height: 24),
          Text('Connexion à SycaPay…', style: TextStyle(fontSize: 15, color: AppColors.texte)),
        ],
      ),
    );
  }

  // ── Vue : enregistrement (paiement confirmé, écriture Supabase en cours) ───

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
                  size: 44, color: Color(0xFF1A6B3C)),
            ),
            const SizedBox(height: 20),
            const Text(
              'Paiement confirmé !',
              style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  color: AppColors.encre),
            ),
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
                  strokeWidth: 3, color: Color(0xFF1A6B3C)),
            ),
          ],
        ),
      ),
    );
  }

  // ── Vue : en attente de confirmation ──────────────────────────────────────

  Widget _vueAttente() {
    final restant = 120 - _pollingSecondes;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(color: Color(0xFF1A6B3C)),
            const SizedBox(height: 24),
            const Icon(Icons.phone_android_rounded, size: 48, color: AppColors.texteDoux),
            const SizedBox(height: 16),
            const Text(
              'Confirmez le paiement\nsur votre téléphone',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: AppColors.encre),
            ),
            const SizedBox(height: 8),
            Text(
              'Vérification toutes les 5 secondes…\nExpire dans $restant s.',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: AppColors.texteDoux, height: 1.5),
            ),
            const SizedBox(height: 32),
            OutlinedButton(
              onPressed: () {
                _pollingTimer?.cancel();
                setState(() {
                  _etape         = _Etape.saisie;
                  _messageErreur = 'Paiement annulé.';
                });
              },
              child: const Text('Annuler'),
            ),
          ],
        ),
      ),
    );
  }

  // ── Vue : succès ───────────────────────────────────────────────────────────

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
              child: const Icon(Icons.check_circle_rounded, size: 50, color: Color(0xFF1A6B3C)),
            ),
            const SizedBox(height: 24),
            const Text('Paiement confirmé !', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: AppColors.encre)),
            const SizedBox(height: 8),
            Text(
              '${widget.membre.nom} a payé\n${Formatters.montant(montant, devise: devise)}',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 15, color: AppColors.texte, height: 1.5),
            ),
            if (_transactionId != null) ...[
              const SizedBox(height: 12),
              Text(
                'Réf. SycaPay : $_transactionId',
                style: const TextStyle(fontSize: 11, color: AppColors.texteDoux),
              ),
            ],
            const SizedBox(height: 40),
            FilledButton(
              onPressed: () => Navigator.pop(context),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF1A6B3C),
                padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              child: const Text('Retour', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
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
  final int montant;
  final String devise;

  const _CarteMontant({required this.montant, required this.devise});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFFEAF4EE),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF1A6B3C).withValues(alpha: 0.2)),
      ),
      child: Column(
        children: [
          const Text('Montant de la cotisation', style: TextStyle(fontSize: 13, color: AppColors.texteDoux)),
          const SizedBox(height: 6),
          Text(
            Formatters.montant(montant, devise: devise),
            style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800, color: Color(0xFF1A6B3C)),
          ),
          const SizedBox(height: 4),
          const Text('Paiement sécurisé via SycaPay', style: TextStyle(fontSize: 11, color: AppColors.texteDoux)),
        ],
      ),
    );
  }
}

// ── Widget : sélecteur d'opérateur ───────────────────────────────────────────

class _SelecteurOperateur extends StatelessWidget {
  final String operateur;
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
      spacing: 8,
      runSpacing: 8,
      children: _operateurs.map((op) {
        final (code, label, couleur) = op;
        final selectionne = operateur == code;
        return InkWell(
          onTap: () => onChange(code),
          borderRadius: BorderRadius.circular(10),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: selectionne ? couleur.withValues(alpha: 0.12) : AppColors.fondSecondaire,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: selectionne ? couleur.withValues(alpha: 0.6) : AppColors.lignes,
                width: selectionne ? 1.5 : 1,
              ),
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: selectionne ? FontWeight.w700 : FontWeight.w400,
                color: selectionne ? couleur : AppColors.texte,
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}
