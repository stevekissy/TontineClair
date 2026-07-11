// ignore_for_file: avoid_print
import 'package:flutter/foundation.dart';
import 'supabase_service.dart';
import 'platform_service.dart';
import 'feature_gate_service.dart';

/// Modèle d'abonnement — source unique de vérité.
class SubscriptionInfo {
  final String planCode;         // 'free' | 'premium_monthly' | 'premium_yearly'
  final String status;           // 'active' | 'expired' | 'cancelled' | 'pending' | 'grace_period'
  final String platform;         // 'web' | 'android' | 'ios'
  final String provider;         // 'web' | 'google_play' | 'apple'
  final DateTime? expiresAt;
  final DateTime? startedAt;
  final bool autoRenew;
  final DateTime? lastVerifiedAt;

  const SubscriptionInfo({
    required this.planCode,
    required this.status,
    required this.platform,
    required this.provider,
    this.expiresAt,
    this.startedAt,
    this.autoRenew = false,
    this.lastVerifiedAt,
  });

  factory SubscriptionInfo.libre() => const SubscriptionInfo(
        planCode: 'free',
        status: 'active',
        platform: 'web',
        provider: 'web',
        autoRenew: false,
      );

  factory SubscriptionInfo.fromJson(Map<String, dynamic> j) {
    DateTime? parseDate(dynamic v) =>
        v == null ? null : DateTime.tryParse(v.toString());

    return SubscriptionInfo(
      planCode:        (j['plan']      as String?) ?? 'free',
      status:          (j['status']    as String?) ?? 'active',
      platform:        (j['platform']  as String?) ?? 'web',
      provider:        (j['provider']  as String?) ?? 'web',
      expiresAt:       parseDate(j['expires_at']),
      startedAt:       parseDate(j['started_at']),
      autoRenew:       (j['auto_renew'] as bool?) ?? false,
      lastVerifiedAt:  parseDate(j['last_verified_at']),
    );
  }

  /// Premium actif = plan premium + status actif/grace_period + non expiré
  bool get isPremium {
    if (planCode == 'free') return false;
    if (status != 'active' && status != 'grace_period') return false;
    if (expiresAt != null && expiresAt!.isBefore(DateTime.now())) return false;
    return true;
  }

  bool get isGracePeriod => status == 'grace_period';
  bool get isMensuel     => planCode == 'premium_monthly';
  bool get isAnnuel      => planCode == 'premium_yearly';

  String get planLabel {
    switch (planCode) {
      case 'premium_monthly': return 'Premium Mensuel';
      case 'premium_yearly':  return 'Premium Annuel';
      default:                return 'Gratuit';
    }
  }

  String get statusLabel {
    switch (status) {
      case 'active':       return 'Actif';
      case 'expired':      return 'Expiré';
      case 'cancelled':    return 'Annulé';
      case 'pending':      return 'En attente';
      case 'grace_period': return 'Période de grâce';
      default:             return status;
    }
  }
}

/// Service centralisé de gestion des abonnements.
/// Toutes les pages passent par ce service — jamais de logique plan
/// éparpillée dans les widgets.
class SubscriptionService {
  SubscriptionService._();

  static SubscriptionInfo _cache = SubscriptionInfo.libre();
  static DateTime? _derniereVerif;
  static const _cacheDuree = Duration(minutes: 5);

  static SubscriptionInfo get info => _cache;
  static bool get isPremium => _cache.isPremium;

  /// Charge l'abonnement depuis Supabase pour un code de tontine donné.
  /// Compatible avec l'architecture actuelle (plan stocké dans tontines.plan).
  static Future<SubscriptionInfo> charger(String codeTontine) async {
    // Cache valide ?
    if (_derniereVerif != null &&
        DateTime.now().difference(_derniereVerif!) < _cacheDuree) {
      return _cache;
    }

    try {
      // 1. Essayer la nouvelle table subscriptions (après migration v7)
      final subResult = await SupabaseService.rpc(
        'lire_abonnement_tontine',
        {'p_code': codeTontine.toUpperCase()},
      );

      if (subResult != null && subResult is Map<String, dynamic>) {
        _cache = SubscriptionInfo.fromJson(subResult);
        _derniereVerif = DateTime.now();
        return _cache;
      }
    } catch (e) {
      // Table subscriptions pas encore créée → fallback lire_plan
      debugPrint('[SubscriptionService] lire_abonnement_tontine absent, fallback lire_plan');
    }

    // 2. Fallback : lire_plan (architecture actuelle v5/v6)
    try {
      final planResult = await SupabaseService.rpc(
        'lire_plan',
        {'p_code': codeTontine.toUpperCase()},
      );

      if (planResult is Map<String, dynamic>) {
        final plan    = (planResult['plan'] as String?) ?? 'free';
        final expire  = planResult['expire'] != null
            ? DateTime.tryParse(planResult['expire'].toString())
            : null;
        final isPrem  = plan == 'premium' &&
            (expire == null || expire.isAfter(DateTime.now()));

        _cache = SubscriptionInfo(
          planCode:  isPrem ? 'premium_monthly' : 'free',
          status:    isPrem ? 'active' : 'active',
          platform:  PlatformService.label,
          provider:  'web',
          expiresAt: expire,
          startedAt: null,
          autoRenew: false,
        );
        _derniereVerif = DateTime.now();
        return _cache;
      }
    } catch (e) {
      debugPrint('[SubscriptionService] erreur lire_plan: $e');
    }

    _cache = SubscriptionInfo.libre();
    _derniereVerif = DateTime.now();
    return _cache;
  }

  /// Invalide le cache (après achat, activation admin, etc.)
  static void invaliderCache() {
    _derniereVerif = null;
    _cache = SubscriptionInfo.libre();
  }

  /// Vérifie si l'utilisateur peut créer une tontine de plus.
  static bool peutCreerTontine(int nbTontinesActuelles) {
    return FeatureGate.peutCreerTontine(
      isPremium: isPremium,
      nbTontinesActuelles: nbTontinesActuelles,
    );
  }

  /// Vérifie si l'utilisateur peut ajouter un membre de plus.
  static bool peutAjouterMembre(int nbMembresActuels) {
    return FeatureGate.peutAjouterMembre(
      isPremium: isPremium,
      nbMembresActuels: nbMembresActuels,
    );
  }

  /// Vérifie si une fonctionnalité avancée est accessible.
  static bool peutUtiliser(AppFeature feature) {
    return FeatureGate.fonctionnaliteAccesible(
      isPremium: isPremium,
      feature: feature,
    );
  }
}
