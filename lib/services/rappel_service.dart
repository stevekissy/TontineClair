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
import '../services/storage_service.dart';
import '../services/supabase_service.dart';
import '../utils/formatters.dart';

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
    // Initialisation du canal de rappels — ne doit jamais bloquer l'app.
    // Sur iOS, flutter_local_notifications nécessite DarwinInitializationSettings
    // sinon lève une PlatformException qui remonte et crashe le démarrage.
    try {
      const androidSettings =
          AndroidInitializationSettings('@mipmap/ic_launcher');
      const iosSettings = DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      );
      const initSettings = InitializationSettings(
        android: androidSettings,
        iOS: iosSettings,
      );
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
    } catch (e, st) {
      // Échec non-fatal : les rappels seront indisponibles mais l'app démarre.
      if (kDebugMode) {
        debugPrint('[RappelService] ⚠️ initialiserCanal error: $e');
        debugPrintStack(stackTrace: st);
      }
    }
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

      // Lire la langue depuis SharedPreferences (pas de BuildContext disponible)
      final prefs = await SharedPreferences.getInstance();
      final langueCode = prefs.getString('app_langue_code') ?? 'fr';

      // Construire les textes selon la situation
      final textes = _construireTextes(
        nomTontine: data.nom,
        joursRestants: joursRestants,
        montant: data.montant,
        devise: data.devise,
        periode: data.periode,
        nbMembresNonPayes: _compterNonPayes(data),
        langueCode: langueCode,
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
  ///
  /// SOURCE PRIMAIRE : StorageService.getListe() (tontines_liste) — fiable
  /// après toute réinstallation ou changement d'appareil.
  /// SOURCE SECONDAIRE : tontines_codes (ancienne clé SharedPrefs) — filet
  /// de sécurité rétrocompatible pour les tontines pas encore en StorageService.
  static Future<void> verifierToutesAuDemarrage() async {
    try {
      // Source 1 : StorageService — source de vérité locale principale
      final tontinesStockees = await StorageService.getListe();
      final codesStorage = tontinesStockees.map((t) => t.code.toUpperCase()).toList();

      // Source 2 : ancienne clé tontines_codes (rétrocompabilité)
      final prefs = await SharedPreferences.getInstance();
      final codesAnciens = prefs.getStringList('tontines_codes') ?? [];

      // Union des deux sources → aucune tontine ratée
      final tousLesCodes = <String>{...codesStorage, ...codesAnciens};

      if (tousLesCodes.isEmpty) {
        if (kDebugMode) debugPrint('[Rappel] Aucune tontine connue au démarrage — vérification ignorée');
        return;
      }

      if (kDebugMode) {
        debugPrint('[Rappel] Vérification démarrage: ${tousLesCodes.length} tontine(s) — $tousLesCodes');
      }

      for (final code in tousLesCodes) {
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
    String langueCode = 'fr',
  }) {
    final lang = ['fr', 'en', 'es', 'pt', 'ar'].contains(langueCode) ? langueCode : 'fr';
    final montantFormate = _formaterMontant(montant, devise);
    final retard = (-joursRestants);

    // Suffixe membres non payés (traduit)
    final suffixes = {
      'fr': nbMembresNonPayes > 0
          ? ' — $nbMembresNonPayes membre${nbMembresNonPayes > 1 ? 's' : ''} n\'${nbMembresNonPayes > 1 ? 'ont' : 'a'} pas encore payé'
          : '',
      'en': nbMembresNonPayes > 0
          ? ' — $nbMembresNonPayes member${nbMembresNonPayes > 1 ? 's' : ''} ha${nbMembresNonPayes > 1 ? 've' : 's'} not paid yet'
          : '',
      'es': nbMembresNonPayes > 0
          ? ' — $nbMembresNonPayes miembro${nbMembresNonPayes > 1 ? 's' : ''} aún no ha${nbMembresNonPayes > 1 ? 'n' : ''} pagado'
          : '',
      'pt': nbMembresNonPayes > 0
          ? ' — $nbMembresNonPayes membro${nbMembresNonPayes > 1 ? 's' : ''} ainda não pago${nbMembresNonPayes > 1 ? 'u' : ''}'
          : '',
      'ar': nbMembresNonPayes > 0
          ? ' — $nbMembresNonPayes عضو لم يدفع بعد'
          : '',
    };
    final suffixe = suffixes[lang] ?? '';

    if (joursRestants < 0) {
      const titres = {
        'fr': '❗ Cotisation en retard',
        'en': '❗ Late contribution',
        'es': '❗ Cotización atrasada',
        'pt': '❗ Contribuição em atraso',
        'ar': '❗ اشتراك متأخر',
      };
      final corps = {
        'fr': 'La cotisation de $montantFormate est en retard de $retard jour${retard > 1 ? 's' : ''}.$suffixe',
        'en': 'The contribution of $montantFormate is $retard day${retard > 1 ? 's' : ''} late.$suffixe',
        'es': 'La cotización de $montantFormate lleva $retard día${retard > 1 ? 's' : ''} de retraso.$suffixe',
        'pt': 'A contribuição de $montantFormate está $retard dia${retard > 1 ? 's' : ''} atrasada.$suffixe',
        'ar': 'اشتراك $montantFormate متأخر بـ $retard يوم.$suffixe',
      };
      return {
        'titre': '${titres[lang]!} — $nomTontine',
        'corps': corps[lang]!,
      };
    }
    if (joursRestants == 0) {
      const titres = {
        'fr': '🔴 Cotisation aujourd\'hui',
        'en': '🔴 Contribution due today',
        'es': '🔴 Cotización hoy',
        'pt': '🔴 Contribuição hoje',
        'ar': '🔴 الاشتراك اليوم',
      };
      final corps = {
        'fr': 'La cotisation de $montantFormate est à payer aujourd\'hui.$suffixe',
        'en': 'The contribution of $montantFormate is due today.$suffixe',
        'es': 'La cotización de $montantFormate debe pagarse hoy.$suffixe',
        'pt': 'A contribuição de $montantFormate deve ser paga hoje.$suffixe',
        'ar': 'يجب دفع اشتراك $montantFormate اليوم.$suffixe',
      };
      return {
        'titre': '${titres[lang]!} — $nomTontine',
        'corps': corps[lang]!,
      };
    }
    if (joursRestants == 1) {
      const titres = {
        'fr': '⚠️ Cotisation demain',
        'en': '⚠️ Contribution tomorrow',
        'es': '⚠️ Cotización mañana',
        'pt': '⚠️ Contribuição amanhã',
        'ar': '⚠️ الاشتراك غداً',
      };
      final corps = {
        'fr': 'Rappel : la cotisation de $montantFormate est à payer demain.$suffixe',
        'en': 'Reminder: the contribution of $montantFormate is due tomorrow.$suffixe',
        'es': 'Recordatorio: la cotización de $montantFormate vence mañana.$suffixe',
        'pt': 'Lembrete: a contribuição de $montantFormate vence amanhã.$suffixe',
        'ar': 'تذكير: يجب دفع اشتراك $montantFormate غداً.$suffixe',
      };
      return {
        'titre': '${titres[lang]!} — $nomTontine',
        'corps': corps[lang]!,
      };
    }
    // J-3
    const titres3 = {
      'fr': '⏰ Cotisation dans',
      'en': '⏰ Contribution in',
      'es': '⏰ Cotización en',
      'pt': '⏰ Contribuição em',
      'ar': '⏰ الاشتراك خلال',
    };
    final jours3 = {
      'fr': '$joursRestants jours',
      'en': '$joursRestants days',
      'es': '$joursRestants días',
      'pt': '$joursRestants dias',
      'ar': '$joursRestants أيام',
    };
    final corps3 = {
      'fr': 'Rappel : la cotisation de $montantFormate est à payer dans $joursRestants jours.$suffixe',
      'en': 'Reminder: the contribution of $montantFormate is due in $joursRestants days.$suffixe',
      'es': 'Recordatorio: la cotización de $montantFormate vence en $joursRestants días.$suffixe',
      'pt': 'Lembrete: a contribuição de $montantFormate vence em $joursRestants dias.$suffixe',
      'ar': 'تذكير: يجب دفع اشتراك $montantFormate خلال $joursRestants أيام.$suffixe',
    };
    return {
      'titre': '${titres3[lang]!} ${jours3[lang]!} — $nomTontine',
      'corps': corps3[lang]!,
    };
  }

  /// Compte les membres qui n'ont pas encore payé ce tour.
  static int _compterNonPayes(TontineData data) {
    return data.membres.where((m) => !m.paye).length;
  }

  /// Formate un montant avec la vraie devise de la tontine.
  static String _formaterMontant(int montant, String devise) {
    // Délègue à Formatters.montant qui gère toutes les devises
    return Formatters.montant(montant, devise: devise);
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
