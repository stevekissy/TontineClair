// ignore_for_file: avoid_print

/// Configuration centrale des droits Gratuit / Premium.
///
/// Source unique — toutes les pages utilisent FeatureGate, jamais de
/// conditions isPremium éparpillées.
class FeatureGate {
  FeatureGate._();

  // ─── Limites Gratuit ──────────────────────────────────────────────────────
  static const int maxTontinesGratuit      = 1;
  static const int maxMembresGratuit       = 5;

  // ─── Limites Premium (illimitées en pratique) ─────────────────────────────
  static const int maxTontinesPremium      = 999;
  static const int maxMembresPremium       = 999;

  // ─── Product IDs centralisés ──────────────────────────────────────────────
  // Google Play
  static const String googlePlayMonthly = 'tontineclair_premium_monthly';
  static const String googlePlayYearly  = 'tontineclair_premium_yearly';

  // Apple App Store
  static const String appleMonthly = 'tontineclair.premium.monthly';
  static const String appleYearly  = 'tontineclair.premium.yearly';

  // ─── Prix affichés (fallback si store indisponible) ──────────────────────
  static const int prixMensuelFCFA = 2500;
  static const int prixAnnuelFCFA  = 25000;

  // ─── Fonctionnalités par plan ────────────────────────────────────────────

  /// L'utilisateur peut-il créer une tontine de plus ?
  static bool peutCreerTontine({
    required bool isPremium,
    required int nbTontinesActuelles,
  }) {
    if (isPremium) return nbTontinesActuelles < maxTontinesPremium;
    return nbTontinesActuelles < maxTontinesGratuit;
  }

  /// L'utilisateur peut-il ajouter un membre de plus ?
  static bool peutAjouterMembre({
    required bool isPremium,
    required int nbMembresActuels,
  }) {
    if (isPremium) return nbMembresActuels < maxMembresPremium;
    return nbMembresActuels < maxMembresGratuit;
  }

  /// Fonctionnalités avancées (toutes nécessitent Premium)
  static bool get votesAvances        => false; // override par isPremium côté widget
  static bool get pretsInternes       => false;
  static bool get exportPdf           => false;
  static bool get scoreIA             => false;
  static bool get statistiquesAvancees => false;
  static bool get journalAudit        => false;
  static bool get relancesAuto        => false;

  /// Vérifie si une fonctionnalité avancée est accessible
  static bool fonctionnaliteAccesible({
    required bool isPremium,
    required AppFeature feature,
  }) {
    // Les fonctionnalités de base sont toujours accessibles
    if (_estFonctionBase(feature)) return true;
    return isPremium;
  }

  static bool _estFonctionBase(AppFeature f) {
    return f == AppFeature.creerTontine ||
        f == AppFeature.voirMembres ||
        f == AppFeature.cotisationsBase ||
        f == AppFeature.profil;
  }

  /// Message d'erreur standard quand une limite est atteinte
  static String messageLimite({
    required LimiteType limite,
    required int? actuel,
    required int? max,
  }) {
    switch (limite) {
      case LimiteType.tontines:
        return 'Votre formule gratuite autorise jusqu\'à $max tontines. '
            'Passez à Premium pour créer et gérer des tontines illimitées.';
      case LimiteType.membres:
        return 'La formule gratuite est limitée à $max membres. '
            'Passez à Premium pour ajouter davantage de membres.';
      case LimiteType.fonctionnalite:
        return 'Cette fonctionnalité est réservée aux membres Premium.';
    }
  }
}

/// Toutes les fonctionnalités de l'application
enum AppFeature {
  // ── Gratuit ────────────────────────────────────────────────────────────────
  creerTontine,
  voirMembres,
  cotisationsBase,
  profil,
  // ── Premium ────────────────────────────────────────────────────────────────
  tontinesMultiples,
  membresIllimites,
  votesAvances,
  pretsInternes,
  remboursements,
  distributions,
  recusPdf,
  relevesPdf,
  partageWhatsApp,
  relancesAuto,
  scoreIA,
  recommandationsIA,
  classement,
  historiqueComplet,
  journalAudit,
  statistiquesAvancees,
  notifications,
  sanctions,
  retraitParVote,
  exports,
  sauvegardes,
}

/// Types de limites pour les messages d'erreur
enum LimiteType { tontines, membres, fonctionnalite }

/// Données de la limite atteinte (pour la dialog)
class LimiteInfo {
  final LimiteType type;
  final String titre;
  final String message;
  final int? actuel;
  final int? max;

  const LimiteInfo({
    required this.type,
    required this.titre,
    required this.message,
    this.actuel,
    this.max,
  });
}
