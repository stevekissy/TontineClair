// ═══════════════════════════════════════════════════════════════════════════
// TontineClair — Service KYC unifié
//
// Architecture :
//   KycService  →  utilise KycProvider (abstraction)
//                  ├── MockKycProvider        (mode simulation, activé par défaut)
//                  └── SmileIdKycProvider     (activé quand SMILE_ID_* disponibles)
//
// Basculer entre les deux : changer KycConfig.useMock = false
// ═══════════════════════════════════════════════════════════════════════════

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

import '../models/kyc_model.dart';
import 'supabase_service.dart';

// ─────────────────────────────────────────────────────────────────────────
// CONFIGURATION
// ─────────────────────────────────────────────────────────────────────────
class KycConfig {
  /// false = SmileIdKycProvider actif (production)
  /// true  = MockKycProvider (simulation locale — réservé aux tests unitaires)
  ///
  /// ⚠️ PRODUCTION : useMock = false — toute tontine Premium exige Smile ID.
  /// Le compte Gratuit n'est JAMAIS soumis au KYC.
  static bool useMock = false;

  /// URL de la Supabase Edge Function kyc-session
  static String edgeFunctionBaseUrl = '${SupabaseService.supabaseUrl}/functions/v1';

  /// Règle métier : KYC requis si et seulement si la tontine est Premium.
  /// Indépendant du montant ou de la devise.
  /// Compte Gratuit → jamais de KYC.
  static bool kycRequisPourPremium = true;

  /// Seuil montant (conservé pour compatibilité interne, non utilisé en logique principale)
  static const double kycThreshold = 0;
}

// ─────────────────────────────────────────────────────────────────────────
// INTERFACE ABSTRAITE — KycProvider
// ─────────────────────────────────────────────────────────────────────────
abstract class KycProvider {
  /// Récupère le statut KYC actuel de l'utilisateur
  Future<KycVerification> getStatus(String userId);

  /// Soumet une demande de vérification KYC
  Future<KycResult> submit({
    required String userId,
    required KycSubmissionData data,
  });

  /// Annule / réinitialise une demande en cours (si autorisé)
  Future<bool> reset(String userId);
}

// ─────────────────────────────────────────────────────────────────────────
// IMPLÉMENTATION 1 — MockKycProvider (simulation)
// ─────────────────────────────────────────────────────────────────────────
class MockKycProvider implements KycProvider {
  // Stockage en mémoire — remplace Supabase en mode simulation
  static final Map<String, KycVerification> _cache = {};

  @override
  Future<KycVerification> getStatus(String userId) async {
    // Simuler une latence réseau réaliste
    await Future.delayed(const Duration(milliseconds: 400));

    if (_cache.containsKey(userId)) return _cache[userId]!;

    // Récupérer depuis Supabase (table kyc_verifications)
    try {
      final row = await SupabaseService.kycGetStatus(userId);
      if (row != null) {
        final kyc = KycVerification.fromMap(row);
        _cache[userId] = kyc;
        return kyc;
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[KYC Mock] getStatus fallback: $e');
    }

    // Aucune entrée → retourner not_started
    final empty = KycVerification.empty(userId);
    _cache[userId] = empty;
    return empty;
  }

  @override
  Future<KycResult> submit({
    required String userId,
    required KycSubmissionData data,
  }) async {
    // Simuler le temps de traitement
    await Future.delayed(const Duration(seconds: 2));

    if (!data.consentGiven) {
      return KycResult.error('Le consentement est obligatoire avant la soumission.');
    }

    // Simuler un résultat aléatoire pour les tests :
    // 80% → pending, 15% → manual_review, 5% → rejected
    final rand = Random().nextDouble();
    final simulatedStatus = rand < 0.80
        ? KycStatus.pending
        : rand < 0.95
            ? KycStatus.manualReview
            : KycStatus.rejected;

    final now = DateTime.now();
    final kycEntry = KycVerification(
      userId:               userId,
      provider:             'mock',
      providerReference:    'MOCK-${DateTime.now().millisecondsSinceEpoch}',
      status:               simulatedStatus,
      documentType:         data.documentType,
      documentCountry:      data.country,
      documentNumberMasked: data.documentNumberMasked,
      rejectionReason:      simulatedStatus == KycStatus.rejected
                              ? '[SIMULATION] Photo du document illisible.'
                              : null,
      submittedAt:          now,
      updatedAt:            now,
    );

    // Persister dans Supabase
    try {
      await SupabaseService.kycUpsert(kycEntry, data);
    } catch (e) {
      if (kDebugMode) debugPrint('[KYC Mock] persist error: $e');
    }

    _cache[userId] = kycEntry;

    // Si pending → simuler passage à "verified" après 10s (pour test UX)
    if (simulatedStatus == KycStatus.pending) {
      _simulateVerification(userId, kycEntry);
    }

    return KycResult.ok(
      simulatedStatus == KycStatus.rejected
          ? '[SIMULATION] Vérification refusée (test).'
          : '[SIMULATION] Dossier soumis. En cours de traitement.',
      simulatedStatus,
    );
  }

  /// Simule le passage automatique à "verified" après 10 secondes (démo)
  void _simulateVerification(String userId, KycVerification entry) {
    Future.delayed(const Duration(seconds: 10), () async {
      final verified = KycVerification(
        id:                   entry.id,
        userId:               userId,
        provider:             'mock',
        providerReference:    entry.providerReference,
        status:               KycStatus.verified,
        documentType:         entry.documentType,
        documentCountry:      entry.documentCountry,
        documentNumberMasked: entry.documentNumberMasked,
        submittedAt:          entry.submittedAt,
        verifiedAt:           DateTime.now(),
        expiresAt:            DateTime.now().add(const Duration(days: 365)),
        updatedAt:            DateTime.now(),
      );
      _cache[userId] = verified;
      try {
        await SupabaseService.kycUpdateStatus(
          userId: userId,
          status: KycStatus.verified,
          verifiedAt: DateTime.now(),
          expiresAt: DateTime.now().add(const Duration(days: 365)),
          performedBy: 'mock-system',
        );
      } catch (e) {
        if (kDebugMode) debugPrint('[KYC Mock] auto-verify error: $e');
      }
    });
  }

  @override
  Future<bool> reset(String userId) async {
    _cache.remove(userId);
    try {
      return await SupabaseService.kycReset(userId);
    } catch (_) {
      return false;
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────
// IMPLÉMENTATION 2 — SmileIdKycProvider (production)
// ─────────────────────────────────────────────────────────────────────────
/// ⚠️ Ce provider est INACTIF tant que KycConfig.useMock = true
///
/// Les appels Smile ID transitent EXCLUSIVEMENT par la Supabase Edge Function
/// "kyc-session" — les clés ne sont JAMAIS dans l'app Flutter.
///
/// Variables d'environnement à renseigner dans Supabase Dashboard :
///   Supabase → Settings → Edge Functions → Secrets :
///   • SMILE_ID_PARTNER_ID   : votre Partner ID Smile ID
///   • SMILE_ID_API_KEY      : votre clé API Smile ID (RSA privée)
///   • SMILE_ID_SID_SERVER   : '0' (sandbox) ou '1' (production)
///   • SMILE_ID_ENVIRONMENT  : 'sandbox' ou 'production'
class SmileIdKycProvider implements KycProvider {
  @override
  Future<KycVerification> getStatus(String userId) async {
    // Récupère le statut depuis Supabase (mis à jour par le webhook)
    try {
      final row = await SupabaseService.kycGetStatus(userId);
      if (row != null) return KycVerification.fromMap(row);
    } catch (e) {
      if (kDebugMode) debugPrint('[SmileID] getStatus error: $e');
    }
    return KycVerification.empty(userId);
  }

  @override
  Future<KycResult> submit({
    required String userId,
    required KycSubmissionData data,
  }) async {
    if (!data.consentGiven) {
      return KycResult.error('Le consentement est obligatoire.');
    }

    try {
      // 1. Créer l'entrée en BDD avec statut pending
      final entry = KycVerification(
        userId:               userId,
        provider:             'smile_id',
        status:               KycStatus.pending,
        documentType:         data.documentType,
        documentCountry:      data.country,
        documentNumberMasked: data.documentNumberMasked,
        submittedAt:          DateTime.now(),
      );
      await SupabaseService.kycUpsert(entry, data);

      // 2. Appeler la Supabase Edge Function pour créer la session Smile ID
      final url = Uri.parse('${KycConfig.edgeFunctionBaseUrl}/kyc-session');
      final response = await http.post(
        url,
        headers: {
          'Content-Type':  'application/json',
          'Authorization': 'Bearer ${SupabaseService.supabaseAnonKey}',
        },
        body: jsonEncode({
          'user_id':       userId,
          'full_name':     data.fullName,
          'date_of_birth': data.dateOfBirth.toIso8601String().substring(0, 10),
          'country':       data.country,
          'document_type': data.documentType.toDbString(),
          'doc_front_b64': await _fileToBase64(data.docFrontPath),
          if (data.docBackPath != null)
            'doc_back_b64': await _fileToBase64(data.docBackPath!),
          'selfie_b64':    await _fileToBase64(data.selfiePath),
        }),
      ).timeout(const Duration(seconds: 60));

      if (response.statusCode == 200) {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        final providerRef = body['smile_job_id'] as String?;
        if (providerRef != null) {
          await SupabaseService.kycSetProviderReference(userId, providerRef);
        }
        return KycResult.ok(
          'Votre dossier a été soumis avec succès. Résultat sous 24–48h.',
          KycStatus.pending,
        );
      } else {
        final err = jsonDecode(response.body) as Map<String, dynamic>;
        return KycResult.error(err['message'] as String? ?? 'Erreur lors de la soumission.');
      }
    } on SocketException {
      return KycResult.error('Connexion réseau impossible. Vérifiez votre connexion.');
    } on TimeoutException {
      return KycResult.error('La connexion a expiré. Veuillez réessayer.');
    } catch (e) {
      if (kDebugMode) debugPrint('[SmileID] submit error: $e');
      return KycResult.error('Une erreur inattendue s\'est produite.');
    }
  }

  @override
  Future<bool> reset(String userId) async {
    return SupabaseService.kycReset(userId);
  }

  Future<String> _fileToBase64(String path) async {
    final file = File(path);
    final bytes = await file.readAsBytes();
    return base64Encode(bytes);
  }
}

// ─────────────────────────────────────────────────────────────────────────
// SERVICE FAÇADE — KycService
// Point d'entrée unique pour toute l'application
// ─────────────────────────────────────────────────────────────────────────
class KycService {
  static KycProvider? _provider;

  static KycProvider get _p {
    _provider ??= KycConfig.useMock ? MockKycProvider() : SmileIdKycProvider();
    return _provider!;
  }

  /// Réinitialiser le provider (ex: après changement de configuration)
  static void resetProvider() => _provider = null;

  // ── API publique ────────────────────────────────────────────────────────

  static Future<KycVerification> getStatus(String userId) =>
      _p.getStatus(userId);

  static Future<KycResult> submit({
    required String userId,
    required KycSubmissionData data,
  }) => _p.submit(userId: userId, data: data);

  static Future<bool> reset(String userId) => _p.reset(userId);

  // ── Règle métier Premium ────────────────────────────────────────────────

  /// Vérifie si un utilisateur Premium doit passer le KYC avant de continuer.
  /// Retourne true si le KYC est requis ET non encore validé.
  ///
  /// Règle :
  ///   • Compte Gratuit → false (jamais de KYC)
  ///   • Compte Premium → true si statut != verified
  static Future<bool> kycBloquantPourPremium(String userId) async {
    if (!KycConfig.kycRequisPourPremium) return false;
    final kyc = await getStatus(userId);
    if (kyc.status.isVerified) {
      // Vérifier expiration
      if (kyc.expiresAt == null || kyc.expiresAt!.isAfter(DateTime.now())) {
        return false; // KYC valide → pas bloquant
      }
    }
    return true; // non vérifié ou expiré → bloquant
  }

  /// Même chose mais synchrone depuis un statut déjà chargé.
  static bool kycBloquantDepuisStatut(KycVerification? kyc) {
    if (!KycConfig.kycRequisPourPremium) return false;
    if (kyc == null) return true;
    if (!kyc.status.isVerified) return true;
    if (kyc.expiresAt != null && kyc.expiresAt!.isBefore(DateTime.now())) return true;
    return false;
  }

  // ── Vérification avant action financière ────────────────────────────────
  /// Retourne si l'utilisateur est autorisé à réaliser une action financière.
  ///
  /// Actions qui déclenchent le KYC :
  ///   'withdrawal'      → retrait
  ///   'disbursement'    → décaissement tontine
  ///   'loan'            → prêt
  ///   'large_transfer'  → virement > seuil
  ///   'premium_create'  → création tontine Premium avec paiements réels
  static Future<FinancialActionResult> canPerformFinancialAction({
    required String userId,
    required String actionType,
    double amount = 0,
  }) async {
    final kyc = await getStatus(userId);

    // Toujours autorisé si KYC vérifié et non expiré
    if (kyc.status.isVerified) {
      if (kyc.expiresAt == null || kyc.expiresAt!.isAfter(DateTime.now())) {
        return FinancialActionResult(allowed: true, kycStatus: kyc.status);
      }
    }

    // Actions toujours bloquées sans KYC vérifié
    const alwaysBlocked = {'withdrawal', 'disbursement', 'loan', 'premium_create'};
    if (alwaysBlocked.contains(actionType)) {
      return FinancialActionResult(
        allowed:   false,
        kycStatus: kyc.status,
        reason:    kyc.status.description,
      );
    }

    // Vérification par montant pour les autres actions
    if (amount >= KycConfig.kycThreshold) {
      return FinancialActionResult(
        allowed:   false,
        kycStatus: kyc.status,
        reason:    'Votre identité doit être vérifiée pour les transactions '
                   'supérieures à ${KycConfig.kycThreshold.toStringAsFixed(0)} XOF.',
      );
    }

    // En dessous du seuil → autorisé
    return FinancialActionResult(allowed: true, kycStatus: kyc.status);
  }

  // ── Statistiques admin ──────────────────────────────────────────────────
  static Future<Map<String, dynamic>?> adminStats(String cleAdmin) =>
      SupabaseService.kycAdminStats(cleAdmin);

  static Future<List<Map<String, dynamic>>> adminList(
    String cleAdmin, {
    String status = 'tous',
    int limit = 50,
    int offset = 0,
  }) => SupabaseService.kycAdminList(cleAdmin, status: status, limit: limit, offset: offset);

  static Future<bool> adminRequestReset({
    required String cleAdmin,
    required String kycId,
    required String reason,
    required String adminNom,
  }) => SupabaseService.kycAdminRequestReset(
        cleAdmin: cleAdmin,
        kycId: kycId,
        reason: reason,
        adminNom: adminNom,
      );
}
