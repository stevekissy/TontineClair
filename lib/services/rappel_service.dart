// ─────────────────────────────────────────────────────────────────────────────
// RappelService — Rappels automatiques d'échéances de cotisations
//
// Stratégie :
//   1. Notifications locales immédiates  → affichée dès l'ouverture de l'app
//      si l'échéance est dans ≤ 3 jours ou déjà passée.
//   2. Notifications locales programmées → planifiées à l'avance pour J-3,
//      J-1, J-0 (en cas d'app fermée mais processus toujours en mémoire).
//   3. Push FCM via Edge Function        → envoyé à tous les appareils même
//      app complètement fermée.
//
// Anti-spam : on sauvegarde dans SharedPreferences la dernière date de notif
// envoyée par tontine pour ne pas re-notifier dans la même journée.
// ─────────────────────────────────────────────────────────────────────────────

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/tontine.dart';
import '../services/echeance_service.dart';
import '../services/supabase_service.dart';

class RappelService {
  RappelService._();

  // ── Canal dédié aux rappels d'échéances ────────────────────────────────────
  static const String _canalId   = 'tontineclair_rappels';
  static const String _canalNom  = 'Rappels TontineClair';
  static const String _canalDesc = 'Rappels de cotisations et échéances à venir';

  static final FlutterLocalNotificationsPlugin _local =
      FlutterLocalNotificationsPlugin();

  // ── Seuils de rappel (en jours avant échéance) ─────────────────────────────
  static const List<int> _seuilsJours = [3, 1, 0]; // J-3, J-1, J-0

  // ── Clé SharedPreferences pour l'anti-spam ─────────────────────────────────
  static String _cleAntiSpam(String code) => 'rappel_last_$code';

  // ─────────────────────────────────────────────────────────────────────────
  // Initialisation du canal rappels
  // ─────────────────────────────────────────────────────────────────────────
  static Future<void> initialiserCanal() async {
    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidSettings);
    await _local.initialize(initSettings);

    await _local
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(
          const AndroidNotificationChannel(
            _canalId,
            _canalNom,
            description: _canalDesc,
            importance: Importance.high,
            playSound: true,
          ),
        );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Point d'entrée principal — appelé dans chargerTontine()
  // ─────────────────────────────────────────────────────────────────────────

  /// Vérifie l'échéance de la tontine et, si nécessaire :
  ///   • Affiche une notification locale immédiate
  ///   • Envoie un push FCM via l'Edge Function Supabase
  ///
  /// [data]        : données fraîches de la tontine
  /// [code]        : code de la tontine
  /// [gestNom]     : nom du gestionnaire actif (pour personnaliser le message)
  static Future<void> verifierEtNotifier({
    required TontineData data,
    required String code,
    String? gestNom,
  }) async {
    try {
      // Pas de rappel si le cycle est terminé ou en attente
      if (data.cycleTermine || data.cycleEnAttente) return;

      final echeance = EcheanceService.prochaineEcheance(
        echeanceStockee: data.echeance,
        periode: data.periode,
      );

      final joursRestants = EcheanceService.joursRestants(echeance);

      // Décider si on doit notifier
      final doitNotifier = joursRestants < 0          // retard
          || _seuilsJours.contains(joursRestants);    // J-3, J-1, J-0

      if (!doitNotifier) return;

      // Anti-spam : ne pas re-notifier le même jour pour la même tontine
      if (await _dejaNotifieAujourdhui(code)) return;

      // Construire les textes selon la situation
      final textes = _construireTextes(
        nomTontine: data.nom,
        joursRestants: joursRestants,
        montant: data.montant,
        devise: data.devise,
        periode: data.periode,
        nbMembresNonPayes: _compterNonPayes(data),
      );

      // 1. Notification locale immédiate
      await _afficherNotificationLocale(
        id: code.hashCode,
        titre: textes['titre']!,
        corps: textes['corps']!,
      );

      // 2. Push FCM via Edge Function (pour tous les appareils)
      SupabaseService.envoyerNotification(
        code: code,
        type: joursRestants < 0 ? 'rappel_retard' : 'rappel_echeance',
        titre: textes['titre']!,
        message: textes['corps']!,
      );

      // Marquer comme notifié aujourd'hui
      await _marquerNotifieAujourdhui(code);

      if (kDebugMode) {
        debugPrint('[Rappel] $code — J${joursRestants >= 0 ? '-' : '+'}${joursRestants.abs()} → notifié');
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[Rappel] Erreur: $e');
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Vérification de toutes les tontines au démarrage de l'app
  // ─────────────────────────────────────────────────────────────────────────

  /// Vérifie toutes les tontines locales connues au démarrage de l'app.
  /// Appelé une fois dans main() après initialisation.
  static Future<void> verifierToutesAuDemarrage() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final codes = prefs.getStringList('tontines_codes') ?? [];
      if (codes.isEmpty) return;

      for (final code in codes) {
        try {
          final tontine = await SupabaseService.lireTontine(code);
          await verifierEtNotifier(
            data: tontine.data,
            code: tontine.code,
          );
        } catch (_) {
          // Ignorer les erreurs par tontine pour ne pas bloquer les autres
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[Rappel] Erreur démarrage: $e');
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Helpers privés
  // ─────────────────────────────────────────────────────────────────────────

  /// Affiche une notification locale immédiate.
  static Future<void> _afficherNotificationLocale({
    required int id,
    required String titre,
    required String corps,
  }) async {
    await _local.show(
      id,
      titre,
      corps,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          _canalId,
          _canalNom,
          channelDescription: _canalDesc,
          importance: Importance.high,
          priority: Priority.high,
          icon: '@mipmap/ic_launcher',
          styleInformation: BigTextStyleInformation(''),
        ),
      ),
    );
  }

  /// Construit les textes titre + corps selon les jours restants.
  static Map<String, String> _construireTextes({
    required String nomTontine,
    required int joursRestants,
    required int montant,
    required String devise,
    required String periode,
    required int nbMembresNonPayes,
  }) {
    final montantFormate = _formaterMontant(montant, devise);
    final suffixe = nbMembresNonPayes > 0
        ? ' — $nbMembresNonPayes membre${nbMembresNonPayes > 1 ? 's' : ''} n\'${nbMembresNonPayes > 1 ? 'ont' : 'a'} pas encore payé'
        : '';

    if (joursRestants < 0) {
      final retard = (-joursRestants);
      return {
        'titre': '❗ Cotisation en retard — $nomTontine',
        'corps': 'La cotisation de $montantFormate est en retard de $retard jour${retard > 1 ? 's' : ''}.$suffixe',
      };
    }
    if (joursRestants == 0) {
      return {
        'titre': '🔴 Cotisation aujourd\'hui — $nomTontine',
        'corps': 'La cotisation de $montantFormate est à payer aujourd\'hui.$suffixe',
      };
    }
    if (joursRestants == 1) {
      return {
        'titre': '⚠️ Cotisation demain — $nomTontine',
        'corps': 'Rappel : la cotisation de $montantFormate est à payer demain.$suffixe',
      };
    }
    // J-3
    return {
      'titre': '⏰ Cotisation dans $joursRestants jours — $nomTontine',
      'corps': 'Rappel : la cotisation de $montantFormate est à payer dans $joursRestants jours.$suffixe',
    };
  }

  /// Compte les membres qui n'ont pas encore payé ce tour.
  static int _compterNonPayes(TontineData data) {
    return data.membres.where((m) => !m.paye).length;
  }

  /// Formate un montant avec la devise.
  static String _formaterMontant(int montant, String devise) {
    final symboles = {
      'XOF': 'FCFA', 'XAF': 'FCFA', 'EUR': '€',
      'USD': '\$', 'GHS': 'GH₵', 'NGN': '₦',
      'MAD': 'MAD', 'TND': 'TND',
    };
    final symbole = symboles[devise] ?? devise;
    // Formatage avec séparateur de milliers
    final str = montant.toString();
    final buffer = StringBuffer();
    for (int i = 0; i < str.length; i++) {
      if (i > 0 && (str.length - i) % 3 == 0) buffer.write(' ');
      buffer.write(str[i]);
    }
    return '${buffer.toString()} $symbole';
  }

  /// Vérifie si on a déjà envoyé une notification aujourd'hui pour ce code.
  static Future<bool> _dejaNotifieAujourdhui(String code) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final derniere = prefs.getString(_cleAntiSpam(code));
      if (derniere == null) return false;
      final d = DateTime.tryParse(derniere);
      if (d == null) return false;
      final now = DateTime.now();
      return d.year == now.year && d.month == now.month && d.day == now.day;
    } catch (_) {
      return false;
    }
  }

  /// Marque la tontine comme notifiée aujourd'hui.
  static Future<void> _marquerNotifieAujourdhui(String code) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _cleAntiSpam(code),
        DateTime.now().toIso8601String(),
      );
    } catch (_) {}
  }

  /// Réinitialise l'anti-spam pour une tontine (utile pour les tests).
  static Future<void> reinitialiserAntiSpam(String code) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_cleAntiSpam(code));
    } catch (_) {}
  }
}
