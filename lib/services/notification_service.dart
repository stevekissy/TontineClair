import 'dart:convert';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'supabase_service.dart';
import 'storage_service.dart';
import 'rappel_service.dart';
import 'blockchain_service.dart' show BlockchainEntry;

// ─── Handler background (top-level, hors classe) ───────────────────────────
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  await NotificationService._afficherNotificationLocale(message);
}

// ─── Service principal ──────────────────────────────────────────────────────
class NotificationService {
  NotificationService._();

  static final FlutterLocalNotificationsPlugin _local =
      FlutterLocalNotificationsPlugin();

  static const AndroidNotificationChannel _canal = AndroidNotificationChannel(
    'tontineclair_mouvements',
    'Mouvements TontineClair',
    description: 'Cotisations, décaissements, votes et nouveaux membres',
    importance: Importance.high,
    playSound: true,
  );

  // ── Clé SharedPreferences : date du dernier ré-abonnement topics ──────────
  static const _kDernierReabonnement = 'fcm_dernier_reabonnement';

  // ── Initialisation complète ────────────────────────────────────────────────
  static Future<void> initialiser() async {
    // 1. Plugin local notifications
    const androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidSettings);
    await _local.initialize(
      initSettings,
      onDidReceiveNotificationResponse: _surTapNotification,
    );

    // 2. Créer le canal Android haute importance
    await _local
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(_canal);

    // 3. Demander la permission (Android 13+)
    final messaging = FirebaseMessaging.instance;
    await messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );

    // 4. Handler background
    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

    // 5. Notification reçue quand app au premier plan
    FirebaseMessaging.onMessage.listen((message) {
      _afficherNotificationLocale(message);
    });

    // 6. App ouverte depuis une notification (arrière-plan)
    FirebaseMessaging.onMessageOpenedApp.listen((message) {
      _traiterDonnees(message.data);
    });

    // 7. App lancée depuis une notification (complètement fermée)
    final initial = await messaging.getInitialMessage();
    if (initial != null) {
      _traiterDonnees(initial.data);
    }

    // 8. Initialiser le canal des rappels d'échéances
    await RappelService.initialiserCanal();

    // 9. Sauvegarder le token FCM
    await _sauvegarderToken();
    messaging.onTokenRefresh.listen(_enregistrerToken);

    // 10. Ré-abonner aux topics FCM de TOUTES les tontines au démarrage
    //     Garanti même si l'app a été réinstallée ou le token FCM a changé.
    //     Fait en background — non-bloquant.
    _reabonnerTousTopic();

    if (kDebugMode) {
      final token = await messaging.getToken();
      debugPrint('[FCM] Token: $token');
    }
  }

  // ── Ré-abonner aux topics de toutes les tontines connues ──────────────────
  // Appelé au démarrage de l'app. Garantit que le topic est actif même après
  // réinstallation, changement d'appareil ou expiration du token FCM.
  static Future<void> _reabonnerTousTopic() async {
    try {
      final prefs        = await SharedPreferences.getInstance();
      final maintenant   = DateTime.now();
      final dernierStr   = prefs.getString(_kDernierReabonnement);
      final dernier      = dernierStr != null ? DateTime.tryParse(dernierStr) : null;

      // Ré-abonner max 1 fois par 24h pour éviter les appels FCM excessifs
      // SAUF si jamais fait (première installation)
      if (dernier != null &&
          maintenant.difference(dernier).inHours < 24) {
        if (kDebugMode) debugPrint('[FCM] Ré-abonnement topics déjà fait il y a < 24h — ignoré');
        return;
      }

      // Récupérer tous les codes de tontines connus
      final tontinesStockees = await StorageService.getListe();
      final codesStorage     = tontinesStockees.map((t) => t.code.toUpperCase()).toList();
      final codesPrefs       = prefs.getStringList('tontines_codes') ?? [];
      final tousLesCodes     = <String>{...codesStorage, ...codesPrefs};

      if (tousLesCodes.isEmpty) {
        if (kDebugMode) debugPrint('[FCM] Aucune tontine connue — ré-abonnement ignoré');
        return;
      }

      if (kDebugMode) debugPrint('[FCM] Ré-abonnement topics pour ${tousLesCodes.length} tontine(s): $tousLesCodes');

      int ok = 0;
      for (final code in tousLesCodes) {
        try {
          final topic = 'tontine_$code';
          await FirebaseMessaging.instance.subscribeToTopic(topic);
          ok++;
          if (kDebugMode) debugPrint('[FCM] ✅ Re-subscribed: $topic');
        } catch (e) {
          if (kDebugMode) debugPrint('[FCM] ⚠️ Erreur ré-abonnement $code: $e');
        }
      }

      // Mémoriser la date du dernier ré-abonnement réussi
      await prefs.setString(_kDernierReabonnement, maintenant.toIso8601String());
      if (kDebugMode) debugPrint('[FCM] ✅ Ré-abonnement terminé: $ok/${tousLesCodes.length} topics OK');

    } catch (e) {
      if (kDebugMode) debugPrint('[FCM] ❌ _reabonnerTousTopic erreur: $e');
    }
  }

  // ── Afficher une notification locale ──────────────────────────────────────
  static Future<void> _afficherNotificationLocale(RemoteMessage message) async {
    final notification = message.notification;
    final android = message.notification?.android;
    if (notification == null) return;

    await _local.show(
      notification.hashCode,
      notification.title ?? 'TontineClair',
      notification.body ?? '',
      NotificationDetails(
        android: AndroidNotificationDetails(
          _canal.id,
          _canal.name,
          channelDescription: _canal.description,
          importance: Importance.high,
          priority: Priority.high,
          icon: android?.smallIcon ?? '@mipmap/ic_launcher',
          styleInformation: BigTextStyleInformation(
            notification.body ?? '',
          ),
        ),
      ),
      payload: jsonEncode(message.data),
    );
  }

  // ── Tap sur notification ───────────────────────────────────────────────────
  static void _surTapNotification(NotificationResponse response) {
    if (response.payload != null) {
      try {
        final data = jsonDecode(response.payload!) as Map<String, dynamic>;
        _traiterDonnees(data);
      } catch (_) {}
    }
  }

  // ── Traiter les données de la notification (navigation future) ─────────────
  static void _traiterDonnees(Map<String, dynamic> data) {
    // Prévu pour navigation vers la tontine concernée
    // data['code'] → code de la tontine
    // data['type'] → 'cotisation' | 'vote' | 'membre' | 'decaissement'
    if (kDebugMode) {
      debugPrint('[FCM] Données notification: $data');
    }
  }

  // ── Sauvegarder le token FCM ───────────────────────────────────────────────
  static Future<void> _sauvegarderToken() async {
    try {
      final token = await FirebaseMessaging.instance.getToken();
      if (token != null) await _enregistrerToken(token);
    } catch (_) {}
  }



  static Future<void> _enregistrerToken(String token) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // Sauvegarder localement
      await prefs.setString('fcm_token', token);
      await prefs.setString('fcm_token_ts', DateTime.now().toIso8601String());

      // Source de vérité 1 : StorageService (tontines_liste) — persisté entre MAJ
      final tontinesStockees = await StorageService.getListe();
      final codesStorageService = tontinesStockees.map((t) => t.code.toUpperCase()).toList();

      // Source de vérité 2 : tontines_codes (ancienne clé, filet de sécurité)
      final codesAnciens = prefs.getStringList('tontines_codes') ?? [];

      // Union des deux sources pour ne rater aucune tontine
      final tousLesCodes = <String>{...codesStorageService, ...codesAnciens};

      // Synchroniser tontines_codes avec StorageService (correction des incohérences)
      if (codesStorageService.isNotEmpty) {
        await prefs.setStringList('tontines_codes', codesStorageService);
      }

      // Enregistrer le token dans Supabase pour TOUTES les tontines
      for (final code in tousLesCodes) {
        await SupabaseService.sauvegarderTokenFCM(code: code, token: token);
      }

      if (kDebugMode) {
        debugPrint('[FCM] ✅ Token enregistré pour ${tousLesCodes.length} tontine(s): $tousLesCodes');
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[FCM] ❌ _enregistrerToken erreur: $e');
    }
  }

  /// Force un ré-abonnement immédiat à tous les topics (ex: après login).
  /// Utile si l'utilisateur vient de se connecter sur un nouvel appareil.
  static Future<void> reabonnerImmediatement() async {
    try {
      // Réinitialiser la date pour forcer le ré-abonnement
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kDernierReabonnement);
      await _reabonnerTousTopic();
    } catch (e) {
      if (kDebugMode) debugPrint('[FCM] ❌ reabonnerImmediatement erreur: $e');
    }
  }

  /// Abonne cet appareil aux notifications d'une tontine.
  ///
  /// DOUBLE MÉCANISME (robuste) :
  ///   1. FCM TOPIC  → subscribeToTopic("tontine_CODE")
  ///      Garantit que l'appareil reçoit le broadcast même si son token
  ///      individuel change ou n'est pas encore en base Supabase.
  ///      C'est LA solution fiable pour notifier TOUS les membres.
  ///
  ///   2. Token individuel dans fcm_tokens (conservé en fallback)
  ///      Nécessaire pour les actions admin et la purge des tokens invalides.
  static Future<void> abonnerATontine(String code) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final codeUp = code.toUpperCase();

      // Mémoriser le code dans tontines_codes (rétro-compat)
      final codes = prefs.getStringList('tontines_codes') ?? [];
      if (!codes.contains(codeUp)) {
        codes.add(codeUp);
        await prefs.setStringList('tontines_codes', codes);
      }

      // ── MÉCANISME 1 : FCM TOPIC (broadcast garanti) ───────────────────────
      // "tontine_49LJP3" → TOUS les membres abonnés reçoivent les notifications
      // même si leur token individuel n'est pas en base ou a changé.
      final topic = 'tontine_$codeUp';
      await FirebaseMessaging.instance.subscribeToTopic(topic);
      if (kDebugMode) debugPrint('[FCM] ✅ Abonné au topic: $topic');

      // ── MÉCANISME 2 : Token individuel (fallback + admin) ─────────────────
      String? token = await FirebaseMessaging.instance.getToken();
      if (token != null) {
        await prefs.setString('fcm_token', token);
        await prefs.setString('fcm_token_ts', DateTime.now().toIso8601String());
        await SupabaseService.sauvegarderTokenFCM(code: codeUp, token: token);
        if (kDebugMode) debugPrint('[FCM] ✅ Token individuel enregistré pour $codeUp: ${token.substring(0,20)}...');
      } else {
        // Fallback cache
        token = prefs.getString('fcm_token');
        if (token != null && token.isNotEmpty) {
          await SupabaseService.sauvegarderTokenFCM(code: codeUp, token: token);
        } else {
          if (kDebugMode) debugPrint('[FCM] ⚠️ Impossible d\'obtenir le token FCM pour $codeUp');
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[FCM] ❌ abonnerATontine erreur: $e');
    }
  }

  /// Se désabonne du topic FCM d'une tontine (ex: quitter une tontine).
  static Future<void> desabonnerDeTontine(String code) async {
    try {
      final codeUp = code.toUpperCase();
      final topic = 'tontine_$codeUp';
      await FirebaseMessaging.instance.unsubscribeFromTopic(topic);
      if (kDebugMode) debugPrint('[FCM] 🚪 Désabonné du topic: $topic');
    } catch (e) {
      if (kDebugMode) debugPrint('[FCM] ❌ desabonnerDeTontine erreur: $e');
    }
  }

  // ── Récupérer le token FCM sauvegardé ─────────────────────────────────────
  static Future<String?> getToken() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString('fcm_token');
    } catch (_) {
      return null;
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // PHASE 4 — Option Y : Notifications blockchain on-chain
  // Appelée après chaque opération blockchain confirmée (phase 1 ou 2)
  // ═══════════════════════════════════════════════════════════════════════════

  /// Notifie TOUS les membres d'une tontine après une opération blockchain.
  ///
  /// ARCHITECTURE BROADCAST :
  ///   1. Appelle l'Edge Function `envoyer_notification` → FCM → TOUS les appareils
  ///      membres de cette tontine (tokens en base Supabase).
  ///   2. Affiche AUSSI une notif locale sur l'appareil émetteur (feedback immédiat).
  ///
  /// L'étape 1 est le vrai broadcast. Sans elle, seul l'émetteur reçoit la notif.
  static Future<void> notifierOperationBlockchain({
    required String tontineCode,
    required String nomTontine,
    required String typeOperation,
    required int    phase,
    String?  txHash,
    int?     montantXof,
    String?  membreNom,
  }) async {
    try {
      // Résoudre le type (y compris sélecteurs hex 0x…)
      final typeResolu  = BlockchainEntry.resoudreType(typeOperation);
      final typeLabel   = _typeLabel(typeResolu);
      final montantStr  = montantXof != null ? ' · ${_formatXof(montantXof)} XOF' : '';
      final phaseLabel  = phase == 2 ? '⚡ On-chain' : '🔒 Signé';
      final titre       = '$phaseLabel — $typeLabel$montantStr';
      final corps       = _buildCorpsNotif(
        tontineCode  : tontineCode,
        nomTontine   : nomTontine,
        typeOperation: typeResolu,
        phase        : phase,
        txHash       : txHash,
        membreNom    : membreNom,
      );

      // ── ÉTAPE 1 : BROADCAST FCM via Edge Function ───────────────────────────
      // Envoie la notification à TOUS les tokens enregistrés pour cette tontine.
      // C'est cette étape qui notifie les autres membres.
      SupabaseService.envoyerNotification(
        code   : tontineCode,
        type   : typeResolu,
        titre  : titre,
        message: corps,
        donneesExtra: {
          'type'  : typeResolu,
          'phase' : '$phase',
          if (membreNom != null && membreNom.isNotEmpty) 'membre': membreNom,
          if (montantXof != null) 'montant': '$montantXof',
        },
      ); // unawaited — non-bloquant

      if (kDebugMode) {
        debugPrint('[Notif Broadcast] $typeLabel → tontine $tontineCode phase=$phase '
            'tx=${txHash != null ? txHash.substring(0, 10) : "N/A"}...');
      }

      // ── ÉTAPE 2 : Notification locale (feedback immédiat pour l'émetteur) ───
      // Affichée uniquement sur l'appareil courant, sans attendre FCM.
      await _local.show(
        DateTime.now().millisecondsSinceEpoch ~/ 1000,
        titre,
        corps,
        NotificationDetails(
          android: AndroidNotificationDetails(
            _canal.id,
            _canal.name,
            channelDescription: _canal.description,
            importance: Importance.defaultImportance,
            priority: Priority.defaultPriority,
            icon: '@mipmap/ic_launcher',
            styleInformation: BigTextStyleInformation(corps),
            color: phase == 2
                ? const Color(0xFF00C853)
                : const Color(0xFF1C2447),
          ),
        ),
        payload: '{"code":"$tontineCode","type":"$typeResolu","phase":$phase}',
      );

    } catch (e) {
      if (kDebugMode) debugPrint('[Notif Broadcast] ERREUR: $e');
    }
  }

  static String _buildCorpsNotif({
    required String tontineCode,
    required String nomTontine,
    required String typeOperation,
    required int    phase,
    String?  txHash,
    String?  membreNom,
  }) {
    final sb = StringBuffer();
    sb.write('Tontine $nomTontine ($tontineCode)\n');

    if (membreNom != null && membreNom.isNotEmpty) {
      sb.write('Membre : $membreNom\n');
    }

    if (phase == 2 && txHash != null && txHash.length == 66) {
      final court = '${txHash.substring(0, 8)}…${txHash.substring(txHash.length - 6)}';
      sb.write('TX Ethereum : $court\n');
      sb.write('✅ Vérifiable sur PolygonScan');
    } else {
      sb.write('🔒 Preuve cryptographique enregistrée');
    }
    return sb.toString();
  }

  static String _typeLabel(String type) {
    const map = {
      'cotisation'   : 'Cotisation enregistrée',
      'distribution' : 'Distribution enregistrée',
      'pret'         : 'Prêt enregistré',
      'remboursement': 'Remboursement enregistré',
      'vote'         : 'Vote enregistré',
      'creation'     : 'Création de tontine',
      'apport'       : 'Apport enregistré',
      'penalite'     : 'Pénalité enregistrée',
    };
    return map[type] ?? type.toUpperCase();
  }

  static String _formatXof(int xof) {
    if (xof >= 1000000) return '${(xof / 1000000).toStringAsFixed(1)}M';
    if (xof >= 1000) return '${(xof / 1000).toStringAsFixed(0)}k';
    return '$xof';
  }
}
