// ─────────────────────────────────────────────────────────────────────────────
// Modèles du Système de Score de Confiance IA — TontineClair
// ─────────────────────────────────────────────────────────────────────────────

import '../models/tontine.dart';

// ─── Niveaux de score ─────────────────────────────────────────────────────────
enum NiveauScore {
  tresFiable,   // ≥ 80
  fiable,       // ≥ 65
  aSurveiller,  // ≥ 50
  risque,       // ≥ 35
  tresRisque,   // < 35
}

// ─── Type d'impact sur le score ───────────────────────────────────────────────
enum TypeImpact { positif, negatif, neutre }

// ─── Type de recommandation IA ────────────────────────────────────────────────
enum TypeRecommandation {
  positif,   // Bonne nouvelle
  conseil,   // Suggestion d'amélioration
  info,      // Information neutre
  alerte,    // Problème détecté
  risque,    // Risque sérieux
}

// ─── Composante du score (explication ligne par ligne) ────────────────────────
class ComposanteScore {
  final String label;
  final int impact;
  final String detail;
  final TypeImpact type;

  const ComposanteScore({
    required this.label,
    required this.impact,
    required this.detail,
    required this.type,
  });
}

// ─── Détail complet du score calculé ─────────────────────────────────────────
class ScoreDetail {
  final int score;
  final NiveauScore niveau;
  final List<ComposanteScore> composantes;
  final DateTime calculeLe;

  const ScoreDetail({
    required this.score,
    required this.niveau,
    required this.composantes,
    required this.calculeLe,
  });
}

// ─── Entrée d'historique du score ─────────────────────────────────────────────
class HistoriqueScore {
  final int score;
  final int scorePrecedent;
  final String evenement;   // 'cotisation', 'pret', 'retard', 'vote', 'admin', etc.
  final String description;
  final DateTime quand;
  final String? gestionnaire; // Null si calcul auto, nom si modif manuelle

  const HistoriqueScore({
    required this.score,
    required this.scorePrecedent,
    required this.evenement,
    required this.description,
    required this.quand,
    this.gestionnaire,
  });

  int get evolution => score - scorePrecedent;

  factory HistoriqueScore.fromJson(Map<String, dynamic> json) {
    return HistoriqueScore(
      score: (json['score'] as num?)?.toInt() ?? 50,
      scorePrecedent: (json['scorePrecedent'] as num?)?.toInt() ?? 50,
      evenement: json['evenement'] as String? ?? '',
      description: json['description'] as String? ?? '',
      quand: DateTime.tryParse(json['quand'] as String? ?? '') ?? DateTime.now(),
      gestionnaire: json['gestionnaire'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'score': score,
        'scorePrecedent': scorePrecedent,
        'evenement': evenement,
        'description': description,
        'quand': quand.toIso8601String(),
        if (gestionnaire != null) 'gestionnaire': gestionnaire,
      };
}

// ─── Recommandation IA ────────────────────────────────────────────────────────
class RecommandationIA {
  final TypeRecommandation type;
  final String titre;
  final String message;
  final int priorite; // 1 = haute, 2 = moyenne, 3 = basse
  final String? actionSuggeree;

  const RecommandationIA({
    required this.type,
    required this.titre,
    required this.message,
    required this.priorite,
    this.actionSuggeree,
  });
}

// ─── Entrée du classement ─────────────────────────────────────────────────────
class EntreeClassement {
  final Membre membre;
  final ScoreDetail scoreDetail;
  final int rang;

  const EntreeClassement({
    required this.membre,
    required this.scoreDetail,
    this.rang = 0,
  });

  EntreeClassement copyWithRang(int r) => EntreeClassement(
        membre: membre,
        scoreDetail: scoreDetail,
        rang: r,
      );
}

// ─── Proposition de retrait ───────────────────────────────────────────────────
class PropositionRetrait {
  final String membreId;
  final String membreNom;
  final int scoreAuMoment;
  final String motif;
  final String proposePar;
  final DateTime quand;
  final String? voteId; // ID du vote créé automatiquement
  final String statut; // 'en_attente', 'vote_ouvert', 'accepte', 'refuse'

  const PropositionRetrait({
    required this.membreId,
    required this.membreNom,
    required this.scoreAuMoment,
    required this.motif,
    required this.proposePar,
    required this.quand,
    this.voteId,
    this.statut = 'en_attente',
  });

  factory PropositionRetrait.fromJson(Map<String, dynamic> json) {
    return PropositionRetrait(
      membreId: json['membreId'] as String? ?? '',
      membreNom: json['membreNom'] as String? ?? '',
      scoreAuMoment: (json['scoreAuMoment'] as num?)?.toInt() ?? 0,
      motif: json['motif'] as String? ?? '',
      proposePar: json['proposePar'] as String? ?? '',
      quand: DateTime.tryParse(json['quand'] as String? ?? '') ?? DateTime.now(),
      voteId: json['voteId'] as String?,
      statut: json['statut'] as String? ?? 'en_attente',
    );
  }

  Map<String, dynamic> toJson() => {
        'membreId': membreId,
        'membreNom': membreNom,
        'scoreAuMoment': scoreAuMoment,
        'motif': motif,
        'proposePar': proposePar,
        'quand': quand.toIso8601String(),
        if (voteId != null) 'voteId': voteId,
        'statut': statut,
      };
}
