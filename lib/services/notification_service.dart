import 'dart:convert';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'supabase_service.dart';
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
      // Enregistrer dans Supabase pour toutes les tontines connues
      final codes = prefs.getStringList('tontines_codes') ?? [];
      for (final code in codes) {
        await SupabaseService.sauvegarderTokenFCM(code: code, token: token);
      }
      if (kDebugMode) debugPrint('[FCM] Token enregistré: $token');
    } catch (_) {}
  }

  /// Appelée quand l'utilisateur rejoint ou crée une tontine.
  /// Associe son token FCM à ce code tontine dans Supabase.
  static Future<void> abonnerATontine(String code) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // Mémoriser le code localement
      final codes = prefs.getStringList('tontines_codes') ?? [];
      if (!codes.contains(code.toUpperCase())) {
        codes.add(code.toUpperCase());
        await prefs.setStringList('tontines_codes', codes);
      }
      // Envoyer le token à Supabase
      final token = prefs.getString('fcm_token');
      if (token != null) {
        await SupabaseService.sauvegarderTokenFCM(code: code, token: token);
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
}
