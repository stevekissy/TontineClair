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
import '../widgets/app_widgets.dart';

/// Écran de paiement Mobile Money pour un apport de caisse Pro.
///
/// Flux identique à PaiementProScreen mais finalisation = mouvement caisse
/// (pas une cotisation membre). Utilise ecrireTontineSansPIN après confirmation.
class PaiementCaisseProScreen extends StatefulWidget {
  final String code;
  final int montant;
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
  String _operateur = 'moov'; // 'orange' | 'moov' | 'mtn' | 'wave'
  final _telCtrl = TextEditingController();
  final _otpCtrl = TextEditingController();

  _EtapeCaisse _etape = _EtapeCaisse.saisie;
  String? _transactionId;
  String? _messageErreur;
  int _pollingSecondes = 0;
  Timer? _pollingTimer;
  DateTime? _debutEnregistrement;

  @override
  void dispose() {
    _telCtrl.dispose();
    _otpCtrl.dispose();
    _pollingTimer?.cancel();
    super.dispose();
  }

  // ── Validation saisie ─────────────────────────────────────────────────────

  bool get _saisieValide {
    final tel = _telCtrl.text.trim();
    if (tel.length < 8) return false;
    if (_operateur == 'orange' && _otpCtrl.text.trim().length < 4) return false;
    return true;
  }

  // ── Initier le paiement ───────────────────────────────────────────────────

  Future<void> _initierPaiement() async {
    if (!_saisieValide) return;

    setState(() {
      _etape = _EtapeCaisse.enCours;
      _messageErreur = null;
    });

    final numCommande = SycaPayService.genererNumCommande(
      widget.code,
      'CAISSE_${DateTime.now().millisecondsSinceEpoch}',
    );

    final resultat = await SycaPayService.initierPaiement(
      telephone: _telCtrl.text.trim(),
      montant: widget.montant,
      numCommande: numCommande,
      operateur: _operateur,
      otp: _operateur == 'orange' ? _otpCtrl.text.trim() : null,
      nomMembre: 'Apport',
      prenomMembre: 'Caisse',
    );

    if (!mounted) return;

    if (resultat.erreurReseau) {
      setState(() {
        _etape = _EtapeCaisse.saisie;
        _messageErreur = resultat.messageFr;
      });
      return;
    }

    if (resultat.estEchec && !resultat.estEnAttente) {
      setState(() {
        _etape = _EtapeCaisse.saisie;
        _messageErreur = resultat.messageFr;
      });
      return;
    }

    _transactionId = resultat.transactionId;

    if (resultat.estSucces) {
      // Succès immédiat (Orange Money OTP) → état enregistrement visible
      setState(() => _etape = _EtapeCaisse.enregistrement);
      await _validerApportCaisse();
    } else {
      // Pending → polling jusqu'à confirmation ou timeout 2 min
      setState(() => _etape = _EtapeCaisse.attente);
      _demarrerPolling();
    }
  }

  // ── Polling statut ────────────────────────────────────────────────────────

  void _demarrerPolling() {
    _pollingSecondes = 0;
    _pollingTimer = Timer.periodic(const Duration(seconds: 5), (t) async {
      _pollingSecondes += 5;

      if (_pollingSecondes >= 120) {
        t.cancel();
        if (!mounted) return;
        setState(() {
          _etape = _EtapeCaisse.saisie;
          _messageErreur =
              'Délai dépassé. Le paiement n\'a pas été confirmé. Vérifiez votre solde.';
        });
        return;
      }

      if (_transactionId == null) return;

      final statut = await SycaPayService.verifierStatut(_transactionId!);
      if (!mounted) return;

      if (statut.estSucces) {
        t.cancel();
        if (mounted) setState(() => _etape = _EtapeCaisse.enregistrement);
        await _validerApportCaisse();
      } else if (statut.estEchec && statut.code != -200 && statut.code != -9) {
        t.cancel();
        setState(() {
          _etape = _EtapeCaisse.saisie;
          _messageErreur = statut.messageFr;
        });
      }
      // code -200 (pending) ou -9 (statut pas encore dispo) → continuer polling
    });
  }

  // ── Écrire l'apport de caisse confirmé ───────────────────────────────────

  Future<void> _validerApportCaisse() async {
    _pollingTimer?.cancel();
    _debutEnregistrement = DateTime.now();

    final provider = context.read<TontineProvider>();
    final data = provider.courante!.data;
    final newData = data.toJson();

    final ref = _transactionId ?? Formatters.genererReference();
    final now = DateTime.now().toIso8601String();

    // Ajouter le mouvement caisse
    final caisseMap = newData['caisse'];
    final caisse = List<Map<String, dynamic>>.from(
      caisseMap is Map<String, dynamic>
          ? ((caisseMap['mouvements'] as List<dynamic>?)
                  ?.cast<Map<String, dynamic>>() ??
              [])
          : caisseMap is List
              ? (caisseMap as List<dynamic>).cast<Map<String, dynamic>>()
              : [],
    );
    caisse.add({
      'id': ref,
      'type': 'apport',
      'montant': widget.montant,
      'description': widget.description.isNotEmpty
          ? widget.description
          : 'Apport Pro via SycaPay (${_operateur.toUpperCase()})',
      'gestionnaire': provider.gestActifNom ?? '',
      'date': now,
      'reference': ref,
      'methode': 'sycapay',
      'operateur': _operateur,
      'transactionId': _transactionId,
    });
    newData['caisse'] = {'mouvements': caisse};

    // Journal
    final journal = List<Map<String, dynamic>>.from(
      (newData['journal'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ?? [],
    );
    journal.insert(0, {
      'quoi': 'APPORT CAISSE Pro via SycaPay (${_operateur.toUpperCase()}) — '
          '${Formatters.montant(widget.montant, devise: data.devise)}'
          '${widget.description.isNotEmpty ? ' — ${widget.description}' : ''}',
      'par': provider.gestActifNom ?? '',
      'le': DateTime.now().millisecondsSinceEpoch,
      'ref': ref,
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
      if (kDebugMode) debugPrint('[CaissePro] ecrireTontineSansPIN ERREUR: $e');
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
        final t = SupabaseService.notifTexte('caisse', lang, vars: {
          'montant': Formatters.montant(widget.montant, devise: data.devise),
          'libelle': 'Apport caisse',
          'nom': '',
          'desc': widget.description.isNotEmpty ? ' — ${widget.description}' : '',
        });
        SupabaseService.envoyerNotification(
          code: widget.code,
          type: 'caisse',
          titre: t['titre']!,
          message: t['message']!,
        );
      } catch (_) {}

      setState(() => _etape = _EtapeCaisse.succes);
    } else {
      // Distinguer erreur SQL manquante vs autres erreurs réseau
      final estErreurFonction = erreurDetail != null &&
          (erreurDetail.contains('introuvable') || erreurDetail.contains('404'));
      setState(() {
        _etape = _EtapeCaisse.saisie;
        _messageErreur = estErreurFonction
            ? '⚠️ Configuration Supabase incomplète. '
              'Exécutez supabase-fix-sycapay-sans-pin.sql dans Supabase SQL Editor. '
              'Réf. paiement : ${_transactionId ?? "inconnue"}'
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
    final data = provider.courante?.data;
    final devise = data?.devise ?? 'XOF';

    return Scaffold(
      backgroundColor: AppColors.fondPapier,
      appBar: AppBar(
        backgroundColor: AppColors.fondPapier,
        elevation: 0,
        title: const Text(
          'Apport de caisse Pro',
          style: TextStyle(
              fontWeight: FontWeight.w700, color: AppColors.encre, fontSize: 16),
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

  // ── Vue : formulaire de saisie ─────────────────────────────────────────────

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
              border: Border.all(
                  color: const Color(0xFF1A6B3C).withValues(alpha: 0.2)),
            ),
            child: Column(
              children: [
                const Text('Montant de l\'apport',
                    style: TextStyle(fontSize: 13, color: AppColors.texteDoux)),
                const SizedBox(height: 6),
                Text(
                  Formatters.montant(widget.montant, devise: devise),
                  style: const TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF1A6B3C)),
                ),
                if (widget.description.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(widget.description,
                      style: const TextStyle(
                          fontSize: 12, color: AppColors.texteDoux)),
                ],
                const SizedBox(height: 4),
                const Text('Paiement sécurisé via SycaPay',
                    style:
                        TextStyle(fontSize: 11, color: AppColors.texteDoux)),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // Sélection opérateur
          const Text('Opérateur Mobile Money',
              style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                  color: AppColors.encre)),
          const SizedBox(height: 10),
          _SelecteurOperateur(
            operateur: _operateur,
            onChange: (op) =>
                setState(() {
                  _operateur = op;
                  _otpCtrl.clear();
                }),
          ),
          const SizedBox(height: 20),

          // Numéro de téléphone
          const Text('Numéro de téléphone',
              style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                  color: AppColors.encre)),
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
                  const Icon(Icons.error_outline_rounded,
                      color: AppColors.alerte),
                  const SizedBox(width: 10),
                  Expanded(
                      child: Text(_messageErreur!,
                          style: const TextStyle(
                              color: AppColors.alerte, fontSize: 13))),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],

          // Bouton payer
          FilledButton.icon(
            onPressed: _saisieValide ? _initierPaiement : null,
            icon: const Icon(Icons.account_balance_wallet_rounded),
            label: Text(
              'Verser ${Formatters.montant(widget.montant, devise: 'XOF')} via Mobile Money',
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
            ),
            style: FilledButton.styleFrom(
              backgroundColor: _couleurPro,
              disabledBackgroundColor: AppColors.encre.withValues(alpha: 0.2),
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
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
          Text('Connexion à SycaPay…',
              style: TextStyle(fontSize: 15, color: AppColors.texte)),
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
              decoration: BoxDecoration(
                color: const Color(0xFFEAF4EE),
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
              'Enregistrement de l\'apport en cours…',
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
              'Vérification toutes les 5 secondes…\nExpire dans $restant s.',
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 13, color: AppColors.texteDoux, height: 1.5),
            ),
            const SizedBox(height: 32),
            OutlinedButton(
              onPressed: () {
                _pollingTimer?.cancel();
                setState(() {
                  _etape = _EtapeCaisse.saisie;
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

  Widget _vueSucces(String devise) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: const BoxDecoration(
                color: Color(0xFFEAF4EE),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.check_circle_rounded,
                  size: 50, color: Color(0xFF1A6B3C)),
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
              style: const TextStyle(
                  fontSize: 15, color: AppColors.texte, height: 1.5),
            ),
            if (_transactionId != null) ...[
              const SizedBox(height: 12),
              Text(
                'Réf. SycaPay : $_transactionId',
                style:
                    const TextStyle(fontSize: 11, color: AppColors.texteDoux),
              ),
            ],
            const SizedBox(height: 40),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF1A6B3C),
                padding: const EdgeInsets.symmetric(
                    horizontal: 32, vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
              child: const Text('Retour à la caisse',
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

enum _EtapeCaisse { saisie, enCours, enregistrement, attente, succes }

// ── Sélecteur opérateur (identique à PaiementProScreen) ──────────────────────

class _SelecteurOperateur extends StatelessWidget {
  final String operateur;
  final ValueChanged<String> onChange;

  static const _operateurs = [
    ('orange', 'Orange Money', Colors.deepOrange),
    ('moov', 'Moov Money', Colors.blue),
    ('mtn', 'MTN MoMo', Colors.yellow),
    ('wave', 'Wave', Colors.lightBlue),
  ];

  const _SelecteurOperateur(
      {required this.operateur, required this.onChange});

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
            padding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
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
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight:
                    selectionne ? FontWeight.w700 : FontWeight.w400,
                color: selectionne ? couleur : AppColors.texte,
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}
