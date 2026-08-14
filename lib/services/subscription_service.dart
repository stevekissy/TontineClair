// ignore_for_file: avoid_print
// ═══════════════════════════════════════════════════════════════════════════
// SubscriptionService — Google Play Billing + Apple StoreKit
//
// LOGIQUE ABONNEMENT :
//  • L'utilisateur paie UNE SEULE FOIS via Google Play / Apple
//  • L'abonnement est lié au compte Google/Apple (pas à une tontine)
//  • Si abonnement actif → peut créer autant de tontines Premium que voulu
//  • Si abonnement expiré → fonctionnalités Premium bloquées automatiquement
//  • KYC vérifié une seule fois pour toute la durée de l'abonnement
//
// PRODUCT IDs (à remplacer dans Google Play Console / App Store Connect) :
//  • tontineclair_premium_monthly  → 2 500 FCFA/mois
//  • tontineclair_premium_yearly   → 25 000 FCFA/an
// ═══════════════════════════════════════════════════════════════════════════

import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'feature_gate_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Product IDs — à remplacer par les vrais IDs Google Play Console
// ─────────────────────────────────────────────────────────────────────────────
class SubscriptionProductIds {
  static const String mensuel = 'tontineclair_premium_monthly';
  static const String annuel  = 'tontineclair_premium_yearly';

  static const Set<String> tous = {mensuel, annuel};
}

// ─────────────────────────────────────────────────────────────────────────────
// Modèle d'abonnement — source unique de vérité
// ─────────────────────────────────────────────────────────────────────────────
class SubscriptionInfo {
  final String  planCode;   // 'free' | 'premium_monthly' | 'premium_yearly'
  final String  status;     // 'active' | 'expired' | 'cancelled' | 'pending'
  final String  platform;   // 'android' | 'ios' | 'web'
  final String  provider;   // 'google_play' | 'apple' | 'web'
  final DateTime? expiresAt;
  final DateTime? startedAt;
  final bool    autoRenew;
  final DateTime? lastVerifiedAt;
  final String? purchaseToken;  // token Google Play pour vérification serveur

  const SubscriptionInfo({
    required this.planCode,
    required this.status,
    required this.platform,
    required this.provider,
    this.expiresAt,
    this.startedAt,
    this.autoRenew = true,
    this.lastVerifiedAt,
    this.purchaseToken,
  });

  // ── Constructeur "libre" (pas d'abonnement) ──────────────────────────────
  factory SubscriptionInfo.libre() => const SubscriptionInfo(
    planCode: 'free',
    status:   'active',
    platform: 'android',
    provider: 'google_play',
  );

  // ── Depuis JSON (cache SharedPreferences) ────────────────────────────────
  factory SubscriptionInfo.fromJson(Map<String, dynamic> j) {
    DateTime? parseDate(dynamic v) =>
        v == null ? null : DateTime.tryParse(v.toString());
    return SubscriptionInfo(
      planCode:       (j['plan_code']  as String?) ?? 'free',
      status:         (j['status']     as String?) ?? 'active',
      platform:       (j['platform']   as String?) ?? 'android',
      provider:       (j['provider']   as String?) ?? 'google_play',
      expiresAt:      parseDate(j['expires_at']),
      startedAt:      parseDate(j['started_at']),
      autoRenew:      (j['auto_renew'] as bool?)   ?? true,
      lastVerifiedAt: parseDate(j['last_verified_at']),
      purchaseToken:  j['purchase_token'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'plan_code':         planCode,
    'status':            status,
    'platform':          platform,
    'provider':          provider,
    'expires_at':        expiresAt?.toIso8601String(),
    'started_at':        startedAt?.toIso8601String(),
    'auto_renew':        autoRenew,
    'last_verified_at':  lastVerifiedAt?.toIso8601String(),
    'purchase_token':    purchaseToken,
  };

  // ── Premium actif = plan premium + non expiré ────────────────────────────
  bool get isPremium {
    if (planCode == 'free') return false;
    if (status == 'expired' || status == 'cancelled') return false;
    if (expiresAt != null && expiresAt!.isBefore(DateTime.now())) return false;
    return true;
  }

  bool get isMensuel => planCode == 'premium_monthly';
  bool get isAnnuel  => planCode == 'premium_yearly';
  bool get isExpired => !isPremium && planCode != 'free';

  String get planLabel {
    switch (planCode) {
      case 'premium_monthly': return 'Premium Mensuel';
      case 'premium_yearly':  return 'Premium Annuel';
      default:                return 'Gratuit';
    }
  }

  String get statusLabel {
    switch (status) {
      case 'active':    return 'Actif';
      case 'expired':   return 'Expiré';
      case 'cancelled': return 'Annulé';
      case 'pending':   return 'En attente';
      default:          return status;
    }
  }

  String get prixLabel {
    switch (planCode) {
      case 'premium_monthly': return '2 500 FCFA / mois';
      case 'premium_yearly':  return '25 000 FCFA / an';
      default:                return 'Gratuit';
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Résultat d'un achat
// ─────────────────────────────────────────────────────────────────────────────
enum AchatStatut { succes, echec, annule, enAttente }

class AchatResult {
  final AchatStatut statut;
  final String?     message;
  const AchatResult(this.statut, [this.message]);
  bool get estSucces => statut == AchatStatut.succes;
}

// ─────────────────────────────────────────────────────────────────────────────
// SubscriptionService — singleton principal
// ─────────────────────────────────────────────────────────────────────────────
class SubscriptionService {
  SubscriptionService._();

  // ── Cache mémoire ──────────────────────────────────────────────────────────
  static SubscriptionInfo _cache       = SubscriptionInfo.libre();
  static DateTime?        _derniereVerif;
  static const            _cacheDuree  = Duration(minutes: 5);
  static const            _prefKey     = 'subscription_info_v2';

  // ── Getters rapides ────────────────────────────────────────────────────────
  static SubscriptionInfo get info      => _cache;
  static bool             get isPremium => _cache.isPremium;

  // ── Produits disponibles (chargés depuis les stores) ─────────────────────
  static List<ProductDetails> _produits = [];
  static List<ProductDetails> get produits => _produits;

  // ── Stream des achats en cours ─────────────────────────────────────────────
  static StreamSubscription<List<PurchaseDetails>>? _purchaseSubscription;
  static final _purchaseController = StreamController<AchatResult>.broadcast();
  static Stream<AchatResult> get onAchat => _purchaseController.stream;

  // ══════════════════════════════════════════════════════════════════════════
  // INITIALISATION — à appeler dans main.dart au démarrage
  // ══════════════════════════════════════════════════════════════════════════
  static Future<void> initialiser() async {
    // 1. Charger le cache local
    await _chargerDepuisPrefs();

    // 2. Vérifier si le store est disponible
    final disponible = await InAppPurchase.instance.isAvailable();
    if (!disponible) {
      if (kDebugMode) debugPrint('[SubSvc] Store non disponible (émulateur ?)');
      return;
    }

    // 3. Écouter les achats (renouvellements automatiques inclus)
    _purchaseSubscription = InAppPurchase.instance.purchaseStream.listen(
      _gererAchats,
      onError: (e) => debugPrint('[SubSvc] Erreur purchaseStream: $e'),
    );

    // 4. Charger les produits du store
    await _chargerProduits();

    // 5. Restaurer les achats précédents (important au premier lancement)
    await restaurerAchats();
  }

  // ══════════════════════════════════════════════════════════════════════════
  // CHARGER LES PRODUITS DU STORE
  // ══════════════════════════════════════════════════════════════════════════
  static Future<void> _chargerProduits() async {
    try {
      final response = await InAppPurchase.instance.queryProductDetails(
        SubscriptionProductIds.tous,
      );

      if (response.notFoundIDs.isNotEmpty && kDebugMode) {
        debugPrint('[SubSvc] Produits non trouvés: ${response.notFoundIDs}');
        debugPrint('[SubSvc] → Vérifiez que les IDs sont créés dans Google Play Console');
      }

      _produits = response.productDetails;
      if (kDebugMode) {
        debugPrint('[SubSvc] ${_produits.length} produit(s) chargé(s)');
        for (final p in _produits) {
          debugPrint('[SubSvc]   ${p.id} — ${p.price}');
        }
      }
    } catch (e) {
      debugPrint('[SubSvc] Erreur chargement produits: $e');
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // LANCER UN ACHAT (Google Play Billing / Apple StoreKit)
  // ══════════════════════════════════════════════════════════════════════════
  static Future<AchatResult> acheter(String productId) async {
    // En mode debug (émulateur/produits pas encore créés), simuler un achat
    if (_produits.isEmpty) {
      if (kDebugMode) {
        debugPrint('[SubSvc] Mode test — simulation achat $productId');
        final info = _creerInfoDepuisProductId(productId);
        await _sauvegarderEtMettreAJourCache(info);
        return const AchatResult(AchatStatut.succes);
      }
      return const AchatResult(
        AchatStatut.echec,
        'Produits non disponibles. Vérifiez votre connexion ou contactez le support.',
      );
    }

    // Trouver le produit
    final produit = _produits.where((p) => p.id == productId).firstOrNull;
    if (produit == null) {
      return AchatResult(
        AchatStatut.echec,
        'Produit $productId non trouvé dans le store.',
      );
    }

    // Lancer l'achat
    try {
      final param = PurchaseParam(productDetails: produit);
      final ok = await InAppPurchase.instance.buyNonConsumable(
        purchaseParam: param,
      );

      if (!ok) {
        return const AchatResult(AchatStatut.echec, 'Échec du lancement de l\'achat.');
      }

      // Attendre la confirmation via purchaseStream (max 60s)
      final result = await onAchat.first.timeout(
        const Duration(seconds: 60),
        onTimeout: () => const AchatResult(
          AchatStatut.echec,
          'Délai dépassé. Vérifiez votre connexion et réessayez.',
        ),
      );

      return result;
    } catch (e) {
      return AchatResult(AchatStatut.echec, 'Erreur: $e');
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // GÉRER LES ACHATS REÇUS DU STORE
  // ══════════════════════════════════════════════════════════════════════════
  static Future<void> _gererAchats(List<PurchaseDetails> achats) async {
    for (final achat in achats) {
      if (kDebugMode) {
        debugPrint('[SubSvc] Achat reçu: ${achat.productID} — ${achat.status}');
      }

      switch (achat.status) {
        case PurchaseStatus.pending:
          // En attente — rien à faire, l'UI doit afficher un indicateur
          _purchaseController.add(const AchatResult(AchatStatut.enAttente));
          break;

        case PurchaseStatus.purchased:
        case PurchaseStatus.restored:
          // Achat réussi ou restauré
          await _validerEtActiver(achat);
          // Confirmer la livraison au store (obligatoire)
          if (achat.pendingCompletePurchase) {
            await InAppPurchase.instance.completePurchase(achat);
          }
          break;

        case PurchaseStatus.error:
          final msg = achat.error?.message ?? 'Erreur inconnue';
          _purchaseController.add(AchatResult(AchatStatut.echec, msg));
          if (achat.pendingCompletePurchase) {
            await InAppPurchase.instance.completePurchase(achat);
          }
          break;

        case PurchaseStatus.canceled:
          _purchaseController.add(const AchatResult(AchatStatut.annule));
          break;
      }
    }
  }

  // ── Valider et activer l'abonnement ───────────────────────────────────────
  static Future<void> _validerEtActiver(PurchaseDetails achat) async {
    final info = _creerInfoDepuisAchat(achat);
    await _sauvegarderEtMettreAJourCache(info);
    _purchaseController.add(const AchatResult(AchatStatut.succes));
    if (kDebugMode) {
      debugPrint('[SubSvc] ✅ Abonnement activé: ${info.planLabel} — expire: ${info.expiresAt}');
    }
  }

  // ── Créer SubscriptionInfo depuis un PurchaseDetails ─────────────────────
  static SubscriptionInfo _creerInfoDepuisAchat(PurchaseDetails achat) {
    final isMensuel = achat.productID == SubscriptionProductIds.mensuel;
    final now = DateTime.now();

    // Calculer la date d'expiration selon la formule
    final expiration = isMensuel
        ? now.add(const Duration(days: 31))   // 1 mois
        : now.add(const Duration(days: 366));  // 1 an

    return SubscriptionInfo(
      planCode:      isMensuel ? 'premium_monthly' : 'premium_yearly',
      status:        'active',
      platform:      'android',
      provider:      'google_play',
      startedAt:     now,
      expiresAt:     expiration,
      autoRenew:     true,
      lastVerifiedAt: now,
      purchaseToken: achat.verificationData.serverVerificationData,
    );
  }

  // ── Créer SubscriptionInfo depuis un productId (mode test) ───────────────
  static SubscriptionInfo _creerInfoDepuisProductId(String productId) {
    final isMensuel = productId == SubscriptionProductIds.mensuel;
    final now = DateTime.now();
    return SubscriptionInfo(
      planCode:      isMensuel ? 'premium_monthly' : 'premium_yearly',
      status:        'active',
      platform:      'android',
      provider:      'google_play',
      startedAt:     now,
      expiresAt:     isMensuel
          ? now.add(const Duration(days: 31))
          : now.add(const Duration(days: 366)),
      autoRenew:     true,
      lastVerifiedAt: now,
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // RESTAURER LES ACHATS PRÉCÉDENTS
  // ══════════════════════════════════════════════════════════════════════════
  static Future<void> restaurerAchats() async {
    try {
      await InAppPurchase.instance.restorePurchases();
      if (kDebugMode) debugPrint('[SubSvc] Restauration achats demandée');
    } catch (e) {
      debugPrint('[SubSvc] Erreur restauration: $e');
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // PERSISTANCE — SharedPreferences
  // ══════════════════════════════════════════════════════════════════════════
  static Future<void> _chargerDepuisPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final json  = prefs.getString(_prefKey);
      if (json != null) {
        final data = jsonDecode(json) as Map<String, dynamic>;
        _cache = SubscriptionInfo.fromJson(data);
        _derniereVerif = DateTime.now();
        if (kDebugMode) {
          debugPrint('[SubSvc] Cache chargé: ${_cache.planLabel} — isPremium=${_cache.isPremium}');
        }
      }
    } catch (e) {
      debugPrint('[SubSvc] Erreur chargement prefs: $e');
    }
  }

  static Future<void> _sauvegarderEtMettreAJourCache(SubscriptionInfo info) async {
    _cache         = info;
    _derniereVerif = DateTime.now();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefKey, jsonEncode(info.toJson()));
    } catch (e) {
      debugPrint('[SubSvc] Erreur sauvegarde prefs: $e');
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // VÉRIFICATION D'ÉTAT
  // ══════════════════════════════════════════════════════════════════════════

  /// Recharge depuis le cache local (rapide)
  static Future<SubscriptionInfo> charger([String? codeTontine]) async {
    if (_derniereVerif != null &&
        DateTime.now().difference(_derniereVerif!) < _cacheDuree) {
      return _cache;
    }
    await _chargerDepuisPrefs();
    return _cache;
  }

  /// Invalide le cache (après achat, expiration, etc.)
  static void invaliderCache() {
    _derniereVerif = null;
    _cache = SubscriptionInfo.libre();
  }

  /// Vérification complète de l'expiration
  static Future<void> verifierExpiration() async {
    await _chargerDepuisPrefs();
    if (_cache.planCode != 'free' && !_cache.isPremium) {
      // Abonnement expiré → mettre à jour le statut
      final infoExpiree = SubscriptionInfo(
        planCode:      _cache.planCode,
        status:        'expired',
        platform:      _cache.platform,
        provider:      _cache.provider,
        expiresAt:     _cache.expiresAt,
        startedAt:     _cache.startedAt,
        autoRenew:     false,
        lastVerifiedAt: DateTime.now(),
        purchaseToken: _cache.purchaseToken,
      );
      await _sauvegarderEtMettreAJourCache(infoExpiree);
      if (kDebugMode) debugPrint('[SubSvc] Abonnement expiré — fonctionnalités bloquées');
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // FEATURE GATES — API publique
  // ══════════════════════════════════════════════════════════════════════════

  static bool peutCreerTontine(int nbTontinesActuelles) =>
      FeatureGate.peutCreerTontine(
        isPremium: isPremium,
        nbTontinesActuelles: nbTontinesActuelles,
      );

  static bool peutAjouterMembre(int nbMembresActuels) =>
      FeatureGate.peutAjouterMembre(
        isPremium: isPremium,
        nbMembresActuels: nbMembresActuels,
      );

  static bool peutUtiliser(AppFeature feature) =>
      FeatureGate.fonctionnaliteAccesible(
        isPremium: isPremium,
        feature: feature,
      );

  // ══════════════════════════════════════════════════════════════════════════
  // NETTOYAGE
  // ══════════════════════════════════════════════════════════════════════════
  static Future<void> dispose() async {
    await _purchaseSubscription?.cancel();
    await _purchaseController.close();
  }
}
