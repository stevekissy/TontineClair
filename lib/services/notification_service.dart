import 'package:flutter/foundation.dart';

// ─── Stub NotificationService pour TC Admin ────────────────────────────────
// L'app admin n'intègre pas Firebase Messaging ni flutter_local_notifications.
// Ce stub expose les méthodes attendues par blockchain_service.dart
// sous forme de no-op silencieux pour éviter les erreurs de compilation.
// ───────────────────────────────────────────────────────────────────────────

class NotificationService {
  NotificationService._();

  /// Initialisation (no-op dans l'app admin)
  static Future<void> initialiser() async {
    if (kDebugMode) debugPrint('[NotificationService] Admin stub — aucune init requise');
  }

  /// Notifie une opération blockchain confirmée (no-op dans l'app admin)
  static Future<void> notifierOperationBlockchain({
    required String tontineCode,
    required String nomTontine,
    required String typeOperation,
    required int    phase,
    String?  txHash,
    int?     montantXof,
    String?  membreNom,
  }) async {
    if (kDebugMode) {
      debugPrint('[NotificationService] Admin stub — opération blockchain: '
          '$typeOperation | phase $phase | code: $tontineCode');
    }
    // No-op intentionnel : l'admin reçoit les notifications via FCM côté serveur
  }
}
