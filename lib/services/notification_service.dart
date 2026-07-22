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

    if (kDebugMode) {
      final token = await messaging.getToken();
      debugPrint('[FCM] Token: $token');
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
        debugPrint('[FCM] Token enregistré pour ${tousLesCodes.length} tontine(s): $tousLesCodes');
      }
    } catch (_) {}
  }

  /// Appelée quand l'utilisateur rejoint ou crée une tontine, et à chaque
  /// chargement de tontine (chargerTontine) pour garantir la re-synchro après MAJ.
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

      // Envoyer le token actuel à Supabase
      // Utiliser le token frais de FCM en priorité, fallback sur celui en cache
      String? token = prefs.getString('fcm_token');
      if (token == null) {
        // Token absent du cache — le demander directement à FCM
        token = await FirebaseMessaging.instance.getToken();
        if (token != null) {
          await prefs.setString('fcm_token', token);
        }
      }
      if (token != null) {
        await SupabaseService.sauvegarderTokenFCM(code: codeUp, token: token);
        if (kDebugMode) debugPrint('[FCM] Abonné à $codeUp');
      }
    } catch (_) {}
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

  /// Affiche une notification locale quand une opération blockchain est confirmée.
  /// Appelée depuis BlockchainService._enregistrer() après succès.
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
      // Construire le titre selon le type d'opération
      final typeLabel = _typeLabel(typeOperation);
      final montantStr = montantXof != null
          ? ' · ${_formatXof(montantXof)} XOF'
          : '';
      final phaseLabel = phase == 2 ? '⚡ On-chain' : '🔒 Signé';

      final titre = '$phaseLabel — $typeLabel$montantStr';
      final corps = _buildCorpsNotif(
        tontineCode : tontineCode,
        nomTontine  : nomTontine,
        typeOperation: typeOperation,
        phase       : phase,
        txHash      : txHash,
        membreNom   : membreNom,
      );

      await _local.show(
        // ID unique basé sur timestamp pour ne pas écraser les notifs précédentes
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
            // Couleur selon phase
            color: phase == 2
                ? const Color(0xFF00C853)
                : const Color(0xFF1C2447),
          ),
        ),
        payload: '{"code":"$tontineCode","type":"$typeOperation","phase":$phase}',
      );

      if (kDebugMode) {
        debugPrint('[Notif Blockchain] $typeLabel phase=$phase tx=${txHash?.substring(0, 10)}...');
      }
    } catch (e) {
      // Non-bloquant — ne jamais faire échouer une opération pour une notif
      if (kDebugMode) debugPrint('[Notif Blockchain] ERREUR: $e');
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
