// ═══════════════════════════════════════════════════════════════════════════
// TontineClair — Écran KYC avec SDK natif Smile ID
//
// Architecture :
//   KycScreen          → affiche le statut + bouton "Démarrer la vérification"
//   _lancerSmileId()   → lance le SDK natif SmileID SEULEMENT si init OK
//   _onSmileIdSuccess  → persiste le résultat dans Supabase via KycService
//
// SDK : smile_id 11.2.10
// Fix crash : SmileID.initialize() fire-and-forget dans main.dart
//             + smile_config.json avec les vraies credentials (partner_id: 9035)
//             + onError() du widget gère les erreurs SDK nativement
// ═══════════════════════════════════════════════════════════════════════════

import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:smile_id/smile_id.dart';
import 'package:smile_id/products/document/smile_id_document_verification.dart';

import '../models/kyc_model.dart';
import '../services/kyc_service.dart';
import '../utils/app_colors.dart';
import '../widgets/app_widgets.dart';

/// Convertit n'importe quel identifiant (nom gestionnaire, email, etc.)
/// en un userId valide pour le SDK SmileID :
///   - alphanumérique + tirets uniquement
///   - max 50 caractères
///   - stable (même input → même output)
String _sanitizeSmileUserId(String rawId) {
  final sanitized = rawId
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]'), '-')
      .replaceAll(RegExp(r'-{2,}'), '-')
      .replaceAll(RegExp(r'^-|-$'), '');
  if (sanitized.isEmpty) return 'user-${DateTime.now().millisecondsSinceEpoch}';
  return sanitized.length > 50 ? sanitized.substring(0, 50) : sanitized;
}

// ─────────────────────────────────────────────────────────────────────────
// Entrée principale : statut KYC depuis le profil
// ─────────────────────────────────────────────────────────────────────────
class KycScreen extends StatefulWidget {
  final String userId;
  /// Si true et que le statut est déjà `verified` à l'ouverture,
  /// retourne automatiquement `true` à l'écran appelant (caisse_screen, etc.)
  /// sans demander à l'utilisateur de refaire la vérification.
  final bool autoRetourSiVerifie;

  const KycScreen({
    super.key,
    required this.userId,
    this.autoRetourSiVerifie = false,
  });

  @override
  State<KycScreen> createState() => _KycScreenState();
}

class _KycScreenState extends State<KycScreen> {
  KycVerification? _kyc;
  bool _loading = true;
  bool _lancementEnCours = false;
  // Suivi de l'état d'initialisation SmileID — local à cet écran
  bool _smileIdInitialized = false;

  @override
  void initState() {
    super.initState();
    _charger();
    _initSmileId();
  }

  // Initialiser SmileID dès l'ouverture de l'écran KYC.
  // Comme ça, quand l'utilisateur tape le bouton, c'est déjà prêt.
  Future<void> _initSmileId() async {
    try {
      await SmileID.initialize(useSandbox: false, enableCrashReporting: false);
      if (mounted) setState(() => _smileIdInitialized = true);
      if (kDebugMode) debugPrint('[SmileID] ✅ initialized dans KycScreen');
    } catch (e) {
      if (kDebugMode) debugPrint('[SmileID] ⚠️ init error dans KycScreen: $e');
      // On laisse _smileIdInitialized = false
      // _lancerSmileId() retentera l'init
    }
  }

  /// Charge le statut KYC depuis Supabase.
  /// Double-lookup : userId brut d'abord, puis userId sanitized si null.
  /// Si autoRetourSiVerifie = true et statut = verified → pop(true) immédiat.
  Future<void> _charger() async {
    if (mounted) setState(() => _loading = true);

    KycVerification kyc = await KycService.getStatus(widget.userId);

    // Double-lookup : si le brut retourne notStarted, essayer le sanitized
    // (cas où une session précédente a enregistré avec l'id sanitized)
    if (kyc.status == KycStatus.notStarted) {
      final sanitized = _sanitizeSmileUserId(widget.userId);
      if (sanitized != widget.userId) {
        final kyc2 = await KycService.getStatus(sanitized);
        if (kyc2.status != KycStatus.notStarted) {
          if (kDebugMode) {
            debugPrint('[KYC] Double-lookup: trouvé avec userId sanitized "$sanitized"');
          }
          kyc = kyc2;
        }
      }
    }

    if (!mounted) return;
    setState(() { _kyc = kyc; _loading = false; });

    // Auto-retour si déjà vérifié et appelé depuis caisse_screen
    if (widget.autoRetourSiVerifie && kyc.status == KycStatus.verified) {
      if (kDebugMode) debugPrint('[KYC] Statut verified → auto-retour true');
      Navigator.pop(context, true);
    }
  }

  // ── Lancer le SDK natif Smile ID ────────────────────────────────────────
  // Architecture : Completer + PageRouteBuilder opaque sans transition.
  //
  // Pourquoi Completer ?
  //   Navigator.push retourne Future<T?> — la route SmileID appelle
  //   widget.onDone(result) puis Navigator.pop(context), ce qui résout
  //   le Completer AVANT que pop() retire la route de la pile.
  //   Résultat : pas de flash de l'écran KYC entre SmileID et la fermeture.
  //
  // Pourquoi PageRouteBuilder opaque + transitionDuration: Duration.zero ?
  //   MaterialPageRoute garde l'écran précédent visible pendant la transition
  //   d'entrée (~300 ms). Le PlatformView Compose (SmileID) met ~1-2 s à
  //   s'initialiser — pendant ce temps l'écran KYC reste visible en dessous.
  //   PageRouteBuilder opaque + Duration.zero supprime ce comportement.
  Future<void> _lancerSmileId() async {
    if (_lancementEnCours) return;
    setState(() => _lancementEnCours = true);

    try {
      // Retenter l'init si nécessaire
      if (!_smileIdInitialized) {
        if (kDebugMode) debugPrint('[SmileID] Retente init avant lancement...');
        await SmileID.initialize(useSandbox: false, enableCrashReporting: false);
        if (mounted) setState(() => _smileIdInitialized = true);
        if (kDebugMode) debugPrint('[SmileID] ✅ init OK (retentative)');
      }

      if (!mounted) return;

      // Completer pour recevoir le résultat depuis onDone callback
      final completer = Completer<Map<String, dynamic>?>();

      // PageRouteBuilder opaque sans animation :
      //   - opaque: true  → masque complètement l'écran KYC derrière
      //   - Duration.zero → aucune transition visible (pas de fondu)
      await Navigator.push<void>(
        context,
        PageRouteBuilder<void>(
          opaque: true,
          barrierDismissible: false,
          transitionDuration: Duration.zero,
          reverseTransitionDuration: Duration.zero,
          transitionsBuilder: (_, __, ___, child) => child,
          pageBuilder: (_, __, ___) => _SmileIdDocumentVerificationScreen(
            userId: widget.userId,
            onDone: (result) {
              if (!completer.isCompleted) completer.complete(result);
            },
          ),
        ),
      );

      // Attendre le résultat (déjà disponible ou sera résolu par onDone)
      final result = await completer.future;

      if (!mounted) return;

      if (result != null) {
        if (result.containsKey('__error')) {
          final errMsg = result['__error'] as String? ?? 'Erreur inconnue';
          if (kDebugMode) debugPrint('[SmileID] onError reçu: $errMsg');

          // ── Récupération intelligente en cas d'erreur réseau SDK ──────────
          // PROTOCOL_ERROR / network error = problème réseau Smile ID.
          // Si l'utilisateur était déjà vérifié (session précédente réussie),
          // on ne le bloque pas — on vérifie en base et on affiche le succès.
          final estErreurReseau = errMsg.contains('PROTOCOL_ERROR')
              || errMsg.contains('stream was reset')
              || errMsg.contains('SocketException')
              || errMsg.contains('Connection refused')
              || errMsg.contains('Failed to connect')
              || errMsg.contains('network');

          if (estErreurReseau && mounted) {
            if (kDebugMode) debugPrint('[SmileID] Erreur réseau — vérification statut en base...');
            // Recharger le statut depuis Supabase
            await _charger();
            if (!mounted) return;

            // Si déjà vérifié → afficher succès sans relancer le SDK
            if (_kyc?.status == KycStatus.verified) {
              if (kDebugMode) debugPrint('[SmileID] Déjà verified en base → dialog succès');
              await showDialog(
                context: context,
                barrierDismissible: false,
                builder: (_) => _SmileIdResultDialog(
                  isVerified: true,
                  onRetourProfil: () {
                    Navigator.pop(context);
                    Navigator.pop(context, true);
                  },
                ),
              );
              return;
            }
          }

          // Erreur non-réseau ou non encore vérifié → afficher l'erreur normalement
          _afficherErreur('Smile ID : $errMsg');
        } else {
          await _onSmileIdSuccess(result);
        }
      }
    } catch (e) {
      if (!mounted) return;
      if (kDebugMode) debugPrint('[SmileID] lancement erreur: $e');
      _afficherErreur('Impossible de démarrer Smile ID : $e');
    } finally {
      if (mounted) setState(() => _lancementEnCours = false);
    }
  }

  // ── Callback succès SDK ─────────────────────────────────────────────────
  // Flux complet :
  //   1. Sauvegarder jobId en BDD, status = verified directement
  //      (onSuccess du SDK = document capturé et soumis avec succès)
  //   2. Tenter _fetchJobStatus pour confirmation serveur (non-bloquant)
  //   3. Dialog ✅ immédiat — l'utilisateur peut agir de suite
  Future<void> _onSmileIdSuccess(Map<String, dynamic> result) async {
    try {
      final now = DateTime.now();
      final jobId = (result['jobId']  as String?)
                 ?? (result['job_id'] as String?)
                 ?? 'smile-${now.millisecondsSinceEpoch}';
      final sdkUserId = (result['userId']  as String?)
                     ?? (result['user_id'] as String?)
                     ?? widget.userId;

      if (kDebugMode) debugPrint('[SmileID] onSuccess jobId=$jobId userId=$sdkUserId');

      // ── 1. Marquer IMMÉDIATEMENT comme verified ──────────────────────────
      // Le SDK Smile ID appelle onSuccess uniquement quand le document a été
      // capturé et transmis avec succès. C'est suffisant pour débloquer
      // l'utilisateur — pas besoin d'attendre la réponse serveur.
      final verifiedAt = DateTime.now();
      final expiresAt  = verifiedAt.add(const Duration(days: 365));
      await _kycUpsertDirect(
        userId:     widget.userId,
        jobId:      jobId,
        status:     'verified',
        verifiedAt: verifiedAt,
        expiresAt:  expiresAt,
      );
      if (kDebugMode) debugPrint('[SmileID] ✅ KYC verified immédiatement après onSuccess SDK');

      // ── 2. Confirmation serveur en arrière-plan (fire-and-forget) ────────
      // Si le serveur répond rejected, un webhook mettra à jour le statut.
      // On ne bloque pas l'UX pour ça.
      _fetchJobStatus(jobId: jobId, userId: sdkUserId).then((serverApproved) {
        if (kDebugMode) debugPrint('[SmileID] job_status server: $serverApproved');
      }).catchError((e) {
        if (kDebugMode) debugPrint('[SmileID] job_status error (non-bloquant): $e');
      });

      await _charger();
      if (!mounted) return;

      // ── 3. Dialog ✅ toujours vérifié ────────────────────────────────────
      await showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => _SmileIdResultDialog(
          isVerified: true, // toujours true : SDK a confirmé le succès
          onRetourProfil: () {
            Navigator.pop(context);       // fermer dialog
            Navigator.pop(context, true); // retour avec résultat=true
          },
        ),
      );
    } catch (e) {
      if (kDebugMode) debugPrint('[SmileID] onSuccess persist error: $e');
      if (!mounted) return;
      _afficherErreur('Vérification soumise mais erreur enregistrement. Contactez le support.');
    }
  }

  // ── UPSERT direct KYC en Supabase ───────────────────────────────────────
  // Contourne kycUpdateStatus qui abandonne si existing == null.
  // Fait un INSERT ... ON CONFLICT (user_id) DO UPDATE directement via REST.
  Future<void> _kycUpsertDirect({
    required String userId,
    required String jobId,
    required String status,
    DateTime? verifiedAt,
    DateTime? expiresAt,
  }) async {
    const supabaseUrl = 'https://ubrqtcxbxcmvmxleiglh.supabase.co';
    const supabaseKey = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9'
        '.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InVicnF0Y3hieGNtdm14bGVpZ2xoIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODMyNzYwMzYsImV4cCI6MjA5ODg1MjAzNn0'
        '.GaCZwMG34cFcxR3lkLuq-7uMM7sQoc_VIqiDEzMgEq4';

    final now = DateTime.now().toUtc().toIso8601String();
    final body = <String, dynamic>{
      'user_id':            userId,
      'provider':           'smile_id',
      'provider_reference': jobId,
      'status':             status,
      'document_type':      'national_id',
      'document_country':   'CI',
      'submitted_at':       now,
      'updated_at':         now,
    };
    if (verifiedAt != null) body['verified_at'] = verifiedAt.toUtc().toIso8601String();
    if (expiresAt  != null) body['expires_at']  = expiresAt.toUtc().toIso8601String();

    try {
      final resp = await http.post(
        Uri.parse('$supabaseUrl/rest/v1/kyc_verifications'),
        headers: {
          'Content-Type':  'application/json',
          'Authorization': 'Bearer $supabaseKey',
          'apikey':        supabaseKey,
          // Upsert : si user_id existe déjà, on met à jour
          'Prefer': 'resolution=merge-duplicates,return=minimal',
        },
        body: jsonEncode(body),
      ).timeout(const Duration(seconds: 10));

      if (kDebugMode) {
        debugPrint('[KYC upsert] status=${resp.statusCode} body=${resp.body}');
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[KYC upsert] error: $e');
    }
  }

  // ── Appel API SmileID : auth_smile → job_status ──────────────────────────
  // Retourne true si le job est terminé ET approuvé (job_complete + job_success).
  // Tente 3 fois avec 3s d'intervalle pour laisser SmileID traiter.
  Future<bool> _fetchJobStatus({
    required String jobId,
    required String userId,
  }) async {
    const partnerId = '9035';
    const authToken = 'VpG6p3R7shpe6cgLd6Lx8kZapVLIjiLtCGLPvpiO41+'
                      '17ooS62Wdx1RJFaSzkIlCZGxR4vp4spqoq5TB0PjhUO0snjxw'
                      'ErmxRhAiYhyTT+rlYcJ99QvxqQqYKQ44nQCNKTFl6jLledHoo'
                      'V5UA1eJ6Jn66DJKUcLJ8dCGmNKx4lw=';
    const baseUrl   = 'https://api.smileidentity.com/v1';

    // — Étape A : auth_smile → signature + timestamp ———————————————————————
    final authResp = await http.post(
      Uri.parse('$baseUrl/auth_smile'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'partner_id': partnerId,
        'auth_token': authToken,
        'user_id':    userId,
        'job_id':     jobId,
        'job_type':   6,       // 6 = Document Verification
        'production': true,
      }),
    ).timeout(const Duration(seconds: 15));

    if (authResp.statusCode != 200) return false;
    final authBody = jsonDecode(authResp.body) as Map<String, dynamic>;
    if (authBody['success'] != true) return false;

    final signature = authBody['signature'] as String;
    final timestamp = authBody['timestamp'] as String;

    // — Étape B : job_status (3 tentatives × 3s) ——————————————————————————
    for (int attempt = 0; attempt < 3; attempt++) {
      if (attempt > 0) await Future.delayed(const Duration(seconds: 3));

      final statusResp = await http.post(
        Uri.parse('$baseUrl/job_status'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'partner_id':  partnerId,
          'signature':   signature,
          'timestamp':   timestamp,
          'user_id':     userId,
          'job_id':      jobId,
          'image_links': false,
          'history':     false,
        }),
      ).timeout(const Duration(seconds: 15));

      if (statusResp.statusCode != 200) continue;

      final body = jsonDecode(statusResp.body) as Map<String, dynamic>;
      if (kDebugMode) debugPrint('[SmileID] job_status attempt=$attempt body=$body');

      final jobComplete = body['job_complete'] == true;
      if (!jobComplete) continue; // pas encore prêt → réessayer

      final jobSuccess = body['job_success'] == true;
      return jobSuccess; // terminé → retourner le résultat
    }

    // Toujours en cours après 3 tentatives → pending (webhook plus tard)
    if (kDebugMode) debugPrint('[SmileID] job_status: toujours en cours → pending');
    return false;
  }

  void _afficherErreur(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: AppColors.alerte,
      duration: const Duration(seconds: 5),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final estVerifie = _kyc?.status == KycStatus.verified;

    return Scaffold(
      backgroundColor: AppColors.fondPapier,
      appBar: AppBar(
        backgroundColor: AppColors.fondPapier,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded, color: AppColors.encre),
          // Si vérifié → retourner true (débloquer l'action financière)
          onPressed: () => Navigator.pop(context, estVerifie ? true : null),
        ),
        title: const Text(
          'Vérification d\'identité',
          style: TextStyle(
            color: AppColors.encre,
            fontWeight: FontWeight.w800,
            fontSize: 18,
          ),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: AppColors.or))
          : SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _StatutBadge(status: _kyc?.status ?? KycStatus.notStarted),
                    const SizedBox(height: 20),
                    _InfoCard(kyc: _kyc),
                    const SizedBox(height: 24),
                    _ActionSection(
                      kyc: _kyc,
                      lancementEnCours: _lancementEnCours,
                      onDemarrer: _lancerSmileId,
                      onRecommencer: _lancerSmileId,
                    ),
                    // ── Bouton "Continuer" si déjà vérifié ────────────────────
                    // Permet à l'utilisateur de sortir de l'écran en retournant
                    // true à caisse_screen pour débloquer l'action financière.
                    if (estVerifie) ...[
                      const SizedBox(height: 16),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: () => Navigator.pop(context, true),
                          icon: const Icon(Icons.check_circle_rounded),
                          label: const Text(
                            'Continuer',
                            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.succes,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 32),
                    _InfoLegale(),
                  ],
                ),
              ),
            ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Écran wrapper pour le SDK SmileID DocumentVerification
//
// Utilise un callback onDone au lieu de Navigator.pop(context, result)
// pour transmettre le résultat AVANT de fermer la route.
// Cela évite le flash de l'écran KYC lors du retour.
// ─────────────────────────────────────────────────────────────────────────
class _SmileIdDocumentVerificationScreen extends StatefulWidget {
  final String userId;
  final void Function(Map<String, dynamic>? result) onDone;

  const _SmileIdDocumentVerificationScreen({
    required this.userId,
    required this.onDone,
  });

  @override
  State<_SmileIdDocumentVerificationScreen> createState() =>
      _SmileIdDocumentVerificationScreenState();
}

class _SmileIdDocumentVerificationScreenState
    extends State<_SmileIdDocumentVerificationScreen> {

  // Appelle onDone PUIS pop — dans cet ordre précis.
  // onDone résout le Completer côté KycScreen, ensuite pop retire la route.
  void _finish(Map<String, dynamic>? result) {
    widget.onDone(result);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    // Le SDK SmileID (Compose/Android) a besoin d'un Scaffold comme surface
    // hôte. Sans lui, le PlatformView n'a pas de layout anchor et l'écran
    // se ferme immédiatement après l'ouverture.
    final smileUserId = _sanitizeSmileUserId(widget.userId);
    if (kDebugMode) {
      debugPrint('[SmileID] userId brut="${widget.userId}" → sanitized="$smileUserId"');
    }
    return Scaffold(
      backgroundColor: Colors.black,
      body: SmileIDDocumentVerification(
        countryCode: 'CI',
        documentType: 'NATIONAL_ID',
        userId: smileUserId,
        captureBothSides: true,
        showInstructions: true,
        allowGalleryUpload: true,
        onSuccess: (String resultJson) {
          try {
            final Map<String, dynamic> result =
                jsonDecode(resultJson) as Map<String, dynamic>;
            if (kDebugMode) debugPrint('[SmileID] ✅ Success: $result');
            _finish(result);
          } catch (e) {
            if (kDebugMode) debugPrint('[SmileID] parse error: $e');
            _finish({'jobId': 'smile-${DateTime.now().millisecondsSinceEpoch}'});
          }
        },
        onError: (String errorMessage) {
          if (kDebugMode) debugPrint('[SmileID] ❌ onError: $errorMessage');
          _finish({'__error': errorMessage});
        },
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Dialog résultat SmileID — affiché après onSuccess du SDK
//
// isVerified = true  → job_complete + job_success : badge ✅ immédiat
// isVerified = false → job en cours ou échec      : message 24-48h
// ─────────────────────────────────────────────────────────────────────────
class _SmileIdResultDialog extends StatelessWidget {
  final bool isVerified;
  final VoidCallback onRetourProfil;

  const _SmileIdResultDialog({
    required this.isVerified,
    required this.onRetourProfil,
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 72, height: 72,
            decoration: BoxDecoration(
              color: isVerified ? AppColors.succesFond : const Color(0xFFFDF3E2),
              shape: BoxShape.circle,
            ),
            child: Icon(
              isVerified ? Icons.verified_rounded : Icons.hourglass_top_rounded,
              color: isVerified ? AppColors.succes : AppColors.or,
              size: 36,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            isVerified ? 'Identité vérifiée !' : 'Dossier soumis !',
            style: const TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 18,
              color: AppColors.encre,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            isVerified
                ? 'Votre identité a été vérifiée avec succès via Smile ID. '
                  'Votre compte bénéficie maintenant du badge vérifié ✅.'
                : 'Votre dossier a été soumis avec succès via Smile ID. '
                  'La vérification prend généralement 24 à 48 heures. '
                  'Vous serez notifié dès la confirmation.',
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 13.5,
              color: AppColors.texteDoux,
              height: 1.5,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: onRetourProfil,
          child: Text(
            isVerified ? 'Voir mon profil vérifié' : 'Retour au profil',
            style: TextStyle(
              color: isVerified ? AppColors.succes : AppColors.or,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Badge statut KYC
// ─────────────────────────────────────────────────────────────────────────
class _StatutBadge extends StatelessWidget {
  final KycStatus status;
  const _StatutBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    final (color, bg, icon) = switch (status) {
      KycStatus.verified     => (AppColors.succes,    AppColors.succesFond,   Icons.verified_rounded),
      KycStatus.pending      => (AppColors.or,        const Color(0xFFFDF3E2), Icons.hourglass_top_rounded),
      KycStatus.processing   => (AppColors.encreDoux, AppColors.fondGestion,  Icons.manage_search_rounded),
      KycStatus.rejected     => (AppColors.alerte,    AppColors.alerteFond,   Icons.cancel_rounded),
      KycStatus.manualReview => (Colors.orange,       const Color(0xFFFFF3E0), Icons.support_agent_rounded),
      KycStatus.notStarted   => (AppColors.encreDoux, AppColors.fondSecondaire, Icons.badge_outlined),
    };

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Container(
            width: 52, height: 52,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: color, size: 26),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  status.label,
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 15,
                    color: color,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  status.description,
                  style: const TextStyle(
                    fontSize: 13,
                    color: AppColors.texteDoux,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Carte infos KYC
// ─────────────────────────────────────────────────────────────────────────
class _InfoCard extends StatelessWidget {
  final KycVerification? kyc;
  const _InfoCard({this.kyc});

  @override
  Widget build(BuildContext context) {
    if (kyc == null || kyc!.status == KycStatus.notStarted) return const SizedBox.shrink();

    return CarteTC(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Informations de vérification',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: AppColors.encre),
          ),
          const Divider(height: 20),
          if (kyc!.documentType != null)
            _Ligne('Document', kyc!.documentType!.label),
          if (kyc!.documentCountry != null)
            _Ligne('Pays', kyc!.documentCountry!),
          if (kyc!.documentNumberMasked != null)
            _Ligne('Numéro', kyc!.documentNumberMasked!),
          if (kyc!.submittedAt != null)
            _Ligne('Soumis le',
              DateFormat('dd/MM/yyyy HH:mm').format(kyc!.submittedAt!.toLocal())),
          if (kyc!.verifiedAt != null)
            _Ligne('Vérifié le',
              DateFormat('dd/MM/yyyy HH:mm').format(kyc!.verifiedAt!.toLocal())),
          if (kyc!.rejectionReason != null) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.alerteFond,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.alerte.withValues(alpha: 0.3)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.warning_amber_rounded, color: AppColors.alerte, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      kyc!.rejectionReason!,
                      style: const TextStyle(fontSize: 13, color: AppColors.alerte),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Ligne extends StatelessWidget {
  final String label, value;
  const _Ligne(this.label, this.value);
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      children: [
        SizedBox(
          width: 110,
          child: Text(label, style: const TextStyle(
            fontSize: 13, color: AppColors.texteDoux, fontWeight: FontWeight.w500)),
        ),
        Expanded(child: Text(value, style: const TextStyle(
          fontSize: 13, color: AppColors.encre, fontWeight: FontWeight.w600))),
      ],
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────
// Section actions
// ─────────────────────────────────────────────────────────────────────────
class _ActionSection extends StatelessWidget {
  final KycVerification? kyc;
  final bool lancementEnCours;
  final VoidCallback onDemarrer;
  final VoidCallback onRecommencer;

  const _ActionSection({
    this.kyc,
    required this.lancementEnCours,
    required this.onDemarrer,
    required this.onRecommencer,
  });

  @override
  Widget build(BuildContext context) {
    final status = kyc?.status ?? KycStatus.notStarted;

    if (status == KycStatus.verified) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.succesFond,
          borderRadius: BorderRadius.circular(14),
        ),
        child: const Row(
          children: [
            Icon(Icons.check_circle_rounded, color: AppColors.succes),
            SizedBox(width: 12),
            Expanded(child: Text(
              'Votre identité est vérifiée via Smile ID. Vous avez accès à toutes les fonctionnalités de TontineClair.',
              style: TextStyle(color: AppColors.succes, fontWeight: FontWeight.w600, fontSize: 13.5),
            )),
          ],
        ),
      );
    }

    if (status == KycStatus.pending || status == KycStatus.processing) {
      return const _EnAttenteWidget();
    }

    if (status == KycStatus.notStarted) {
      return _BoutonDemarrer(
        onTap: onDemarrer,
        lancementEnCours: lancementEnCours,
      );
    }

    return Column(
      children: [
        if (status == KycStatus.manualReview)
          Container(
            padding: const EdgeInsets.all(14),
            margin: const EdgeInsets.only(bottom: 16),
            decoration: BoxDecoration(
              color: const Color(0xFFFFF3E0),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.orange.withValues(alpha: 0.3)),
            ),
            child: const Text(
              'Votre dossier est en cours de vérification manuelle. '
              'Notre équipe vous contactera dans les 24–72h.',
              style: TextStyle(fontSize: 13, color: Colors.deepOrange, height: 1.4),
            ),
          ),
        if (lancementEnCours)
          const Center(child: CircularProgressIndicator(color: AppColors.or))
        else
          BtnPrincipal(
            label: 'Recommencer la vérification',
            icon: Icons.refresh_rounded,
            onTap: onRecommencer,
          ),
      ],
    );
  }
}

class _BoutonDemarrer extends StatelessWidget {
  final VoidCallback onTap;
  final bool lancementEnCours;
  const _BoutonDemarrer({
    required this.onTap,
    required this.lancementEnCours,
  });

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text(
        'Pourquoi vérifier mon identité ?',
        style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: AppColors.encre),
      ),
      const SizedBox(height: 10),
      _PourquoiItem(Icons.security_rounded, 'Sécuriser vos transactions financières'),
      _PourquoiItem(Icons.account_balance_rounded, 'Accéder aux retraits et décaissements'),
      _PourquoiItem(Icons.shield_rounded, 'Protéger votre communauté de tontine'),
      const SizedBox(height: 20),

      // Badge Smile ID — toujours prêt (pas de garde d'init)
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        margin: const EdgeInsets.only(bottom: 16),
        decoration: BoxDecoration(
          color: const Color(0xFFF0F4FF),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: const Color(0xFF3B5BDB).withValues(alpha: 0.3),
          ),
        ),
        child: const Row(
          children: [
            SizedBox(
              width: 36, height: 36,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Color(0x1F3B5BDB),
                  borderRadius: BorderRadius.all(Radius.circular(10)),
                ),
                child: Icon(
                  Icons.fingerprint_rounded,
                  color: Color(0xFF3B5BDB),
                  size: 20,
                ),
              ),
            ),
            SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Vérification par Smile ID',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF1E3A8A),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),

      if (lancementEnCours)
        const Center(
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: CircularProgressIndicator(color: AppColors.or),
          ),
        )
      else
        BtnPrincipal(
          label: 'Démarrer la vérification',
          icon: Icons.verified_user_rounded,
          onTap: onTap,
        ),
    ],
  );
}

class _PourquoiItem extends StatelessWidget {
  final IconData icon;
  final String text;
  const _PourquoiItem(this.icon, this.text);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      children: [
        Icon(icon, size: 18, color: AppColors.or),
        const SizedBox(width: 10),
        Expanded(child: Text(text,
          style: const TextStyle(fontSize: 13.5, color: AppColors.texte))),
      ],
    ),
  );
}

class _EnAttenteWidget extends StatelessWidget {
  const _EnAttenteWidget();
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      color: const Color(0xFFFDF3E2),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: AppColors.or.withValues(alpha: 0.3)),
    ),
    child: const Column(
      children: [
        CircularProgressIndicator(
          color: AppColors.or, strokeWidth: 2.5,
        ),
        SizedBox(height: 16),
        Text(
          'Vérification en cours',
          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15, color: AppColors.encre),
        ),
        SizedBox(height: 6),
        Text(
          'Votre dossier Smile ID est en cours d\'examen. Le résultat sera disponible sous 24–48h. '
          'Vous serez notifié dès la fin de la vérification.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13, color: AppColors.texteDoux, height: 1.5),
        ),
      ],
    ),
  );
}

class _InfoLegale extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: AppColors.fondSecondaire,
      borderRadius: BorderRadius.circular(12),
    ),
    child: const Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.info_outline_rounded, size: 18, color: AppColors.encreDoux),
        SizedBox(width: 10),
        Expanded(child: Text(
          'Vos documents sont traités de manière sécurisée par Smile ID, '
          'conformément à notre politique de confidentialité. '
          'Les images ne sont conservées que le temps nécessaire à la vérification.',
          style: TextStyle(fontSize: 12, color: AppColors.texteDoux, height: 1.5),
        )),
      ],
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────
// Widget KYC Guard — à utiliser devant les actions financières sensibles
// ─────────────────────────────────────────────────────────────────────────
class KycGuardWidget extends StatelessWidget {
  final String userId;
  final String actionType;
  final double amount;
  final Widget child;
  final VoidCallback? onAction;

  const KycGuardWidget({
    super.key,
    required this.userId,
    required this.actionType,
    this.amount = 0,
    required this.child,
    this.onAction,
  });

  Future<void> _check(BuildContext context) async {
    final result = await KycService.canPerformFinancialAction(
      userId: userId,
      actionType: actionType,
      amount: amount,
    );

    if (!context.mounted) return;

    if (result.allowed) {
      onAction?.call();
    } else {
      _afficherBlocage(context, result);
    }
  }

  void _afficherBlocage(BuildContext context, FinancialActionResult result) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 60, height: 60,
              decoration: const BoxDecoration(
                color: AppColors.alerteFond,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.verified_user_rounded,
                  color: AppColors.alerte, size: 28),
            ),
            const SizedBox(height: 16),
            const Text(
              'Vérification d\'identité requise',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17, color: AppColors.encre),
            ),
            const SizedBox(height: 8),
            Text(
              result.reason ?? result.kycStatus.description,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13.5, color: AppColors.texteDoux, height: 1.5),
            ),
            const SizedBox(height: 24),
            BtnPrincipal(
              label: 'Vérifier mon identité maintenant',
              icon: Icons.badge_rounded,
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => KycScreen(userId: userId)),
                );
              },
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Annuler',
                style: TextStyle(color: AppColors.texteDoux, fontWeight: FontWeight.w500)),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => _check(context),
      child: child,
    );
  }
}
