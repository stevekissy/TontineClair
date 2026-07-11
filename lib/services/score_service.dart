// ─────────────────────────────────────────────────────────────────────────────
// ScoreService — Système de Score de Confiance IA — TontineClair
// Calcul dynamique sur 100, recommandations IA, historique, retrait
// ─────────────────────────────────────────────────────────────────────────────

import 'dart:math' as math;
import '../models/tontine.dart';
import '../models/score_modeles.dart';

class ScoreService {
  // ═══════════════════════════════════════════════════════════════════════════
  // CALCUL DU SCORE (moteur IA local, sans API externe)
  // Base 50 points + bonifications/pénalités pondérées
  // ═══════════════════════════════════════════════════════════════════════════

  static ScoreDetail calculerScore(
    TontineData data,
    String membreId,
    List<Map<String, dynamic>> voixMembre,
  ) {
    int score = 50;
    final composantes = <ComposanteScore>[];

    // ── 1. Cotisations (max +30 / max -20) ───────────────────────────────────
    final statsRaw = data.stats[membreId];
    int toursTotal = 0;
    int toursPayes = 0;
    int retards = 0;
    int penalites = 0;
    int pretsRembourses = 0;
    DateTime? dateCreation;

    if (statsRaw is Map) {
      toursTotal = (statsRaw['toursTotal'] as num?)?.toInt() ?? 0;
      toursPayes = (statsRaw['toursPayes'] as num?)?.toInt() ?? 0;
      retards = (statsRaw['retards'] as num?)?.toInt() ?? 0;
      penalites = (statsRaw['penalites'] as num?)?.toInt() ?? 0;
      pretsRembourses = (statsRaw['pretsRembourses'] as num?)?.toInt() ?? 0;
      final creeLe = statsRaw['creeLe'];
      if (creeLe is int) {
        dateCreation = DateTime.fromMillisecondsSinceEpoch(creeLe);
      } else if (creeLe is String) {
        dateCreation = DateTime.tryParse(creeLe);
      }
    }

    if (toursTotal > 0) {
      final tauxCotisation = toursPayes / toursTotal;
      final bonusCotisation = (30 * tauxCotisation).round();
      score += bonusCotisation;
      composantes.add(ComposanteScore(
        label: 'Cotisations payées',
        impact: bonusCotisation,
        detail:
            '$toursPayes tours payés sur $toursTotal (${(tauxCotisation * 100).round()}%)',
        type: bonusCotisation >= 20
            ? TypeImpact.positif
            : bonusCotisation >= 10
                ? TypeImpact.neutre
                : TypeImpact.negatif,
      ));
    } else {
      composantes.add(ComposanteScore(
        label: 'Cotisations',
        impact: 0,
        detail: 'Aucun tour enregistré',
        type: TypeImpact.neutre,
      ));
    }

    // ── 2. Retards (max -20) ──────────────────────────────────────────────────
    if (retards > 0) {
      final malusRetard = math.min(20, retards * 4);
      score -= malusRetard;
      composantes.add(ComposanteScore(
        label: 'Retards de paiement',
        impact: -malusRetard,
        detail: '$retards retard(s) enregistré(s)',
        type: TypeImpact.negatif,
      ));
    }

    // ── 3. Pénalités (max -15) ────────────────────────────────────────────────
    if (penalites > 0) {
      final malusPenalite = math.min(15, penalites * 5);
      score -= malusPenalite;
      composantes.add(ComposanteScore(
        label: 'Pénalités appliquées',
        impact: -malusPenalite,
        detail: '$penalites pénalité(s) reçue(s)',
        type: TypeImpact.negatif,
      ));
    }

    // ── 4. Prêts remboursés (max +10) ─────────────────────────────────────────
    if (pretsRembourses > 0) {
      final bonusPrets = math.min(10, pretsRembourses * 5);
      score += bonusPrets;
      composantes.add(ComposanteScore(
        label: 'Prêts remboursés',
        impact: bonusPrets,
        detail: '$pretsRembourses prêt(s) intégralement remboursé(s)',
        type: TypeImpact.positif,
      ));
    }

    // ── 5. Prêts en retard (−15 chacun) ──────────────────────────────────────
    final maintenant = DateTime.now();
    int nbPretsRetard = 0;
    for (final p in data.prets) {
      if (p.emprunteurId != membreId) continue;
      if (p.statut == 'soldé' || p.statut == 'solde') continue;
      for (final ech in p.echeancier) {
        final dateEch = ech['date'] as String?;
        final paye = ech['paye'] as bool? ?? false;
        if (!paye && dateEch != null) {
          final d = DateTime.tryParse(dateEch);
          if (d != null && d.isBefore(maintenant)) {
            nbPretsRetard++;
            break;
          }
        }
      }
    }
    if (nbPretsRetard > 0) {
      final malusPret = math.min(30, nbPretsRetard * 15);
      score -= malusPret;
      composantes.add(ComposanteScore(
        label: 'Prêts en retard',
        impact: -malusPret,
        detail: '$nbPretsRetard prêt(s) avec échéance(s) dépassée(s)',
        type: TypeImpact.negatif,
      ));
    }

    // ── 6. Ancienneté (max +10) ───────────────────────────────────────────────
    if (dateCreation != null) {
      final moisAnciennete = maintenant.difference(dateCreation).inDays ~/ 30;
      final bonusAnciennete = math.min(10, moisAnciennete);
      if (bonusAnciennete > 0) {
        score += bonusAnciennete;
        composantes.add(ComposanteScore(
          label: 'Ancienneté',
          impact: bonusAnciennete,
          detail: '$moisAnciennete mois de présence dans la tontine',
          type: TypeImpact.positif,
        ));
      }
    }

    // ── 7. Participation aux votes (max +8 / -8) ──────────────────────────────
    final votesOuverts = data.votes.where((v) => v.clos).length;
    final votesParticipes = voixMembre.length;
    if (votesOuverts > 0) {
      final tauxVote = votesParticipes / votesOuverts;
      final impactVote = ((tauxVote - 0.5) * 8).round().clamp(-8, 8);
      score += impactVote;
      composantes.add(ComposanteScore(
        label: 'Participation aux votes',
        impact: impactVote,
        detail:
            '$votesParticipes vote(s) sur $votesOuverts scrutin(s) clos (${(tauxVote * 100).round()}%)',
        type: impactVote > 0
            ? TypeImpact.positif
            : impactVote < 0
                ? TypeImpact.negatif
                : TypeImpact.neutre,
      ));
    }

    // ── 8. Prêts en cours (neutre → légère pénalité -3 par prêt actif) ───────
    final pretsActifs = data.prets
        .where((p) =>
            p.emprunteurId == membreId &&
            p.statutCalcule != 'solde')
        .length;
    if (pretsActifs > 1) {
      final malusMultiPret = math.min(6, (pretsActifs - 1) * 3);
      score -= malusMultiPret;
      composantes.add(ComposanteScore(
        label: 'Prêts simultanés',
        impact: -malusMultiPret,
        detail: '$pretsActifs prêts actifs en même temps',
        type: TypeImpact.negatif,
      ));
    }

    final scoreFinal = score.clamp(0, 100);
    final niveau = _niveauScore(scoreFinal);

    return ScoreDetail(
      score: scoreFinal,
      niveau: niveau,
      composantes: composantes,
      calculeLe: maintenant,
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // RECOMMANDATIONS IA (analyse comportementale, jamais décisionnelle)
  // ═══════════════════════════════════════════════════════════════════════════

  static List<RecommandationIA> genererRecommandations(
    TontineData data,
    Membre membre,
    ScoreDetail scoreDetail,
    List<Map<String, dynamic>> voixMembre,
  ) {
    final recs = <RecommandationIA>[];
    final score = scoreDetail.score;
    final statsRaw = data.stats[membre.id];

    int toursTotal = 0;
    int toursPayes = 0;
    int retards = 0;
    int penalites = 0;
    int pretsRembourses = 0;

    if (statsRaw is Map) {
      toursTotal = (statsRaw['toursTotal'] as num?)?.toInt() ?? 0;
      toursPayes = (statsRaw['toursPayes'] as num?)?.toInt() ?? 0;
      retards = (statsRaw['retards'] as num?)?.toInt() ?? 0;
      penalites = (statsRaw['penalites'] as num?)?.toInt() ?? 0;
      pretsRembourses = (statsRaw['pretsRembourses'] as num?)?.toInt() ?? 0;
    }

    // ── Analyse cotisations ────────────────────────────────────────────────
    if (toursTotal > 0) {
      final taux = toursPayes / toursTotal;
      if (taux >= 0.95 && score >= 80) {
        recs.add(RecommandationIA(
          type: TypeRecommandation.positif,
          titre: 'Membre très fiable',
          message:
              '${membre.nom} a payé ${(taux * 100).round()}% de ses cotisations. '
              'Profil excellent, éligible à un prêt plus important si besoin.',
          priorite: 1,
          actionSuggeree: 'Envisager un plafond de prêt plus élevé',
        ));
      } else if (taux < 0.6 && retards >= 2) {
        recs.add(RecommandationIA(
          type: TypeRecommandation.alerte,
          titre: 'Plusieurs retards de paiement',
          message:
              '${membre.nom} présente $retards retard(s) et un taux de cotisation '
              'de ${(taux * 100).round()}%. Un suivi rapproché est recommandé.',
          priorite: 1,
          actionSuggeree: 'Envoyer une relance via WhatsApp',
        ));
      }
    }

    // ── Analyse participation votes ────────────────────────────────────────
    final votesOuverts = data.votes.where((v) => v.clos).length;
    if (votesOuverts >= 3) {
      final tauxVote = voixMembre.length / votesOuverts;
      if (tauxVote < 0.4) {
        recs.add(RecommandationIA(
          type: TypeRecommandation.info,
          titre: 'Membre peu actif dans les votes',
          message:
              '${membre.nom} n\'a participé qu\'à ${voixMembre.length} vote(s) '
              'sur $votesOuverts scrutin(s). La participation démocratique '
              'est essentielle au bon fonctionnement de la tontine.',
          priorite: 2,
          actionSuggeree: 'Rappeler l\'importance du vote lors de la prochaine réunion',
        ));
      }
    }

    // ── Analyse prêts en retard ────────────────────────────────────────────
    final maintenant = DateTime.now();
    final pretsRetard = <Pret>[];
    for (final p in data.prets) {
      if (p.emprunteurId != membre.id) continue;
      if (p.statut == 'soldé' || p.statut == 'solde') continue;
      for (final ech in p.echeancier) {
        final dateEch = ech['date'] as String?;
        final paye = ech['paye'] as bool? ?? false;
        if (!paye && dateEch != null) {
          final d = DateTime.tryParse(dateEch);
          if (d != null && d.isBefore(maintenant)) {
            pretsRetard.add(p);
            break;
          }
        }
      }
    }

    if (pretsRetard.isNotEmpty) {
      recs.add(RecommandationIA(
        type: TypeRecommandation.alerte,
        titre: 'Prêt(s) en retard de remboursement',
        message:
            '${membre.nom} a ${pretsRetard.length} prêt(s) avec des échéances '
            'dépassées. Le recouvrement doit être prioritaire.',
        priorite: 1,
        actionSuggeree: 'Contacter le membre pour un plan de remboursement',
      ));
    }

    // ── Prêts correctement remboursés ─────────────────────────────────────
    if (pretsRembourses >= 2) {
      recs.add(RecommandationIA(
        type: TypeRecommandation.positif,
        titre: 'Excellent comportement de remboursement',
        message:
            '${membre.nom} a intégralement remboursé $pretsRembourses prêt(s). '
            'Ce membre démontre sa fiabilité financière.',
        priorite: 3,
        actionSuggeree: null,
      ));
    }

    // ── Risque élevé → suggestion de vote ─────────────────────────────────
    if (score < 30) {
      recs.add(RecommandationIA(
        type: TypeRecommandation.risque,
        titre: 'Risque élevé — Action collective recommandée',
        message:
            'Le score de ${membre.nom} ($score/100) indique un risque sérieux '
            'pour la tontine. Les membres peuvent initier un vote de maintien '
            'ou de retrait selon le règlement intérieur.',
        priorite: 1,
        actionSuggeree: 'Proposer un vote de maintien ou de retrait de la tontine',
      ));
    } else if (score < 50) {
      recs.add(RecommandationIA(
        type: TypeRecommandation.alerte,
        titre: 'Profil à surveiller',
        message:
            '${membre.nom} présente des signaux préoccupants (score $score/100). '
            'Un accompagnement préventif peut améliorer la situation.',
        priorite: 2,
        actionSuggeree: 'Planifier un entretien de suivi',
      ));
    }

    // ── Suggestions amélioration score ────────────────────────────────────
    if (score < 70) {
      final suggestions = _suggestionsMieuxScore(
        score: score,
        retards: retards,
        penalites: penalites,
        nbPretsRetard: pretsRetard.length,
        tauxVote: votesOuverts > 0 ? voixMembre.length / votesOuverts : 1.0,
      );
      if (suggestions.isNotEmpty) {
        recs.add(RecommandationIA(
          type: TypeRecommandation.conseil,
          titre: 'Comment améliorer le score',
          message: suggestions,
          priorite: 3,
          actionSuggeree: null,
        ));
      }
    }

    // Trier par priorité
    recs.sort((a, b) => a.priorite.compareTo(b.priorite));
    return recs;
  }

  static String _suggestionsMieuxScore({
    required int score,
    required int retards,
    required int penalites,
    required int nbPretsRetard,
    required double tauxVote,
  }) {
    final items = <String>[];
    if (nbPretsRetard > 0) {
      items.add('• Rembourser les échéances de prêt en attente');
    }
    if (retards > 0) {
      items.add('• Payer les cotisations avant l\'échéance pour éviter les retards');
    }
    if (penalites > 0) {
      items.add('• Régulariser les pénalités en suspens');
    }
    if (tauxVote < 0.7) {
      items.add('• Participer activement aux votes de la tontine');
    }
    if (score < 60) {
      items.add('• La régularité sur les 3 prochains tours améliorera rapidement le score');
    }
    if (items.isEmpty) return '';
    return items.join('\n');
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // CLASSEMENT des membres par score
  // ═══════════════════════════════════════════════════════════════════════════

  static List<EntreeClassement> classerMembres(
    TontineData data,
    Map<String, List<Map<String, dynamic>>> voixParMembre,
  ) {
    final membres = data.membresActifs;
    final classement = <EntreeClassement>[];

    for (final m in membres) {
      final voix = voixParMembre[m.id] ?? [];
      final detail = calculerScore(data, m.id, voix);
      classement.add(EntreeClassement(
        membre: m,
        scoreDetail: detail,
      ));
    }

    classement.sort((a, b) => b.scoreDetail.score.compareTo(a.scoreDetail.score));

    // Assigner les rangs
    for (int i = 0; i < classement.length; i++) {
      classement[i] = classement[i].copyWithRang(i + 1);
    }

    return classement;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // RECALCUL AUTO — à appeler après chaque événement impactant le score
  // ═══════════════════════════════════════════════════════════════════════════

  /// Recalcule le score d'un membre et retourne le nouveau ScoreDetail.
  /// Exemples d'[evenement] : 'cotisation', 'retard', 'pret', 'remboursement',
  ///                          'vote', 'sanction', 'anciennete', 'retrait'
  static ScoreDetail recalcPourEnregistrement({
    required TontineData data,
    required String membreId,
    required List<Map<String, dynamic>> voixMembre,
    required int ancienScore,
    required String evenement,
    required String description,
  }) {
    return calculerScore(data, membreId, voixMembre);
  }

  /// Retourne true si l'évolution dépasse 2 points (mérite un enregistrement)
  static bool evolutionSignificative(int ancien, int nouveau) {
    return (nouveau - ancien).abs() >= 2;
  }

  /// Label humain de l'événement pour l'historique
  static String labelEvenement(String evt) {
    return switch (evt) {
      'cotisation'    => 'Cotisation payée',
      'retard'        => 'Retard de paiement',
      'pret'          => 'Nouveau prêt accordé',
      'remboursement' => 'Remboursement effectué',
      'vote'          => 'Participation au vote',
      'admin'         => 'Modification administrative',
      'sanction'      => 'Sanction appliquée',
      'retrait'       => 'Proposition de retrait',
      'anciennete'    => 'Ancienneté',
      _               => evt,
    };
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // HELPERS
  // ═══════════════════════════════════════════════════════════════════════════

  static NiveauScore _niveauScore(int score) {
    if (score >= 80) return NiveauScore.tresFiable;
    if (score >= 65) return NiveauScore.fiable;
    if (score >= 50) return NiveauScore.aSurveiller;
    if (score >= 35) return NiveauScore.risque;
    return NiveauScore.tresRisque;
  }

  static String labelNiveau(NiveauScore niveau) {
    switch (niveau) {
      case NiveauScore.tresFiable:
        return 'Très fiable';
      case NiveauScore.fiable:
        return 'Fiable';
      case NiveauScore.aSurveiller:
        return 'À surveiller';
      case NiveauScore.risque:
        return 'Risqué';
      case NiveauScore.tresRisque:
        return 'Très risqué';
    }
  }

  static String emojiNiveau(NiveauScore niveau) {
    switch (niveau) {
      case NiveauScore.tresFiable:
        return '🟢';
      case NiveauScore.fiable:
        return '🔵';
      case NiveauScore.aSurveiller:
        return '🟡';
      case NiveauScore.risque:
        return '🟠';
      case NiveauScore.tresRisque:
        return '🔴';
    }
  }
}
