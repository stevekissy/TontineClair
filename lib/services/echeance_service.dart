// ─────────────────────────────────────────────────────────────────────────────
// EcheanceService — Calcul des échéances selon la périodicité
//
// Périodicités supportées :
//   • 'journalier'  → chaque jour
//   • 'hebdo'       → chaque semaine
//   • 'mensuel'     → chaque mois
//   • 'bimensuel'   → tous les 2 mois (si besoin futur)
//   • 'trimestriel' → tous les 3 mois (si besoin futur)
//
// Règles métier :
//   1. Si une échéance explicite est stockée dans data.echeance,
//      on la respecte en priorité.
//   2. Sinon, on calcule depuis `maintenant` selon la périodicité.
//   3. Lorsque l'échéance passée est détectée, on calcule la suivante.
// ─────────────────────────────────────────────────────────────────────────────

class EcheanceService {
  // ── Durée d'un cycle ───────────────────────────────────────────────────────

  /// Nombre de jours d'un cycle pour une périodicité donnée.
  static int joursCycle(String periode) {
    switch (periode) {
      case 'journalier':
        return 1;
      case 'hebdo':
        return 7;
      case 'mensuel':
        return 30;
      case 'bimensuel':
        return 60;
      case 'trimestriel':
        return 90;
      default:
        return 30; // fallback mensuel
    }
  }

  // ── Prochaine échéance ─────────────────────────────────────────────────────

  /// Calcule la prochaine échéance de cotisation.
  ///
  /// [echeanceStockee] : valeur ISO 8601 stockée dans Supabase (peut être null)
  /// [periode]        : périodicité de la tontine
  /// [reference]      : date de référence (par défaut : DateTime.now())
  ///
  /// Retourne la prochaine date d'échéance à afficher.
  static DateTime prochaineEcheance({
    String? echeanceStockee,
    required String periode,
    DateTime? reference,
  }) {
    final maintenant = reference ?? DateTime.now();

    // Cas 1 : échéance explicite stockée
    if (echeanceStockee != null && echeanceStockee.isNotEmpty) {
      final d = DateTime.tryParse(echeanceStockee);
      if (d != null) {
        // Si l'échéance n'est pas encore passée → on l'utilise telle quelle
        if (d.isAfter(maintenant)) return d;

        // L'échéance est passée → calculer la prochaine selon la périodicité
        return _prochaineDateDepuis(d, periode, maintenant);
      }
    }

    // Cas 2 : aucune échéance → calculer automatiquement depuis maintenant
    return _prochaineDateDepuis(maintenant, periode, maintenant);
  }

  /// Calcule la prochaine occurrence à partir d'une date de référence `depuis`,
  /// en avançant par incréments de [periode] jusqu'à dépasser [maintenant].
  static DateTime _prochaineDateDepuis(
    DateTime depuis,
    String periode,
    DateTime maintenant,
  ) {
    DateTime next = depuis;
    final nbJours = joursCycle(periode);

    // Pour les périodicités en mois, on utilise addMonths pour rester cohérent
    // avec les fins de mois (28/29/30/31 jours)
    if (periode == 'mensuel' || periode == 'bimensuel' || periode == 'trimestriel') {
      final nbMois = periode == 'mensuel' ? 1 : periode == 'bimensuel' ? 2 : 3;
      while (!next.isAfter(maintenant)) {
        next = _addMois(next, nbMois);
      }
    } else {
      // Journalier et hebdomadaire : ajout de jours fixes
      while (!next.isAfter(maintenant)) {
        next = next.add(Duration(days: nbJours));
      }
    }
    return next;
  }

  /// Additionne des mois en tenant compte des fins de mois.
  static DateTime _addMois(DateTime d, int nbMois) {
    var annee = d.year;
    var mois  = d.month + nbMois;
    while (mois > 12) {
      mois  -= 12;
      annee += 1;
    }
    final maxJour = _dernierJourDuMois(annee, mois);
    return DateTime(annee, mois, d.day.clamp(1, maxJour));
  }

  static int _dernierJourDuMois(int annee, int mois) {
    return DateTime(annee, mois + 1, 0).day;
  }

  // ── Statut de l'échéance ───────────────────────────────────────────────────

  /// Retourne le nombre de jours restants avant l'échéance (négatif si passée).
  static int joursRestants(DateTime echeance) {
    final now = DateTime.now();
    final diff = echeance.difference(DateTime(now.year, now.month, now.day));
    return diff.inDays;
  }

  /// Texte lisible du délai restant.
  static String texteDelai(DateTime echeance, {String periode = 'mensuel'}) {
    final jours = joursRestants(echeance);
    if (jours < 0) {
      final retard = -jours;
      if (periode == 'journalier') {
        return 'En retard de $retard jour${retard > 1 ? 's' : ''}';
      }
      return 'En retard de $retard jour${retard > 1 ? 's' : ''}';
    }
    if (jours == 0) return "Aujourd'hui";
    if (jours == 1) return 'Demain';
    if (jours < 7)  return 'Dans $jours jours';
    if (jours < 14) return 'Dans 1 semaine';
    if (jours < 31) return 'Dans ${(jours / 7).round()} semaines';
    return 'Dans ${(jours / 30).round()} mois';
  }

  /// Couleur sémantique selon l'urgence (retourne une chaîne de statut).
  /// 'alerte' | 'avertissement' | 'normal'
  static String statutEcheance(DateTime echeance, String periode) {
    final jours = joursRestants(echeance);
    if (jours < 0) return 'alerte';

    // Seuil d'avertissement selon la périodicité
    final seuil = periode == 'journalier' ? 0 :
                  periode == 'hebdo'      ? 2 :
                                            5; // mensuel+
    if (jours <= seuil) return 'avertissement';
    return 'normal';
  }

  // ── Mise à jour de l'échéance dans les données ─────────────────────────────

  /// Met à jour l'échéance dans un Map `data` (format toJson()) si :
  ///   - l'échéance stockée est passée, OU
  ///   - aucune échéance n'est définie.
  /// Retourne le Map modifié (ou l'original si aucun changement).
  static Map<String, dynamic> mettreAJourEcheance(
    Map<String, dynamic> data, {
    bool forcer = false,
  }) {
    final periode = data['periodicite'] as String? ?? data['periode'] as String? ?? 'mensuel';
    final echeanceActuelle = data['echeance'] as String?;

    bool doitMettreAJour = forcer;

    if (!doitMettreAJour) {
      if (echeanceActuelle == null || echeanceActuelle.isEmpty) {
        doitMettreAJour = true;
      } else {
        final d = DateTime.tryParse(echeanceActuelle);
        if (d != null && d.isBefore(DateTime.now())) {
          doitMettreAJour = true;
        }
      }
    }

    if (!doitMettreAJour) return data;

    final nouvelleEcheance = prochaineEcheance(
      echeanceStockee: echeanceActuelle,
      periode: periode,
    );

    return {
      ...data,
      'echeance': nouvelleEcheance.toIso8601String(),
    };
  }

  // ── Libellés ───────────────────────────────────────────────────────────────

  /// Libellé court de la périodicité.
  static String labelPeriode(String periode) {
    switch (periode) {
      case 'journalier': return 'Journalière';
      case 'hebdo':      return 'Hebdomadaire';
      case 'mensuel':    return 'Mensuelle';
      case 'bimensuel':  return 'Bimensuelle';
      case 'trimestriel':return 'Trimestrielle';
      default:           return periode;
    }
  }

  /// Libellé long de la périodicité.
  static String labelPeriodeLong(String periode) {
    switch (periode) {
      case 'journalier': return 'Tous les jours';
      case 'hebdo':      return 'Chaque semaine';
      case 'mensuel':    return 'Chaque mois';
      case 'bimensuel':  return 'Tous les 2 mois';
      case 'trimestriel':return 'Tous les 3 mois';
      default:           return periode;
    }
  }

  /// Liste des périodicités disponibles pour le sélecteur.
  static const Map<String, String> periodiciteOptions = {
    'journalier': 'Journalière (chaque jour)',
    'hebdo':      'Hebdomadaire (chaque semaine)',
    'mensuel':    'Mensuelle (chaque mois)',
    'trimestriel':'Trimestrielle (tous les 3 mois)',
  };
}
