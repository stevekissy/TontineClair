// ─────────────────────────────────────────────────────────────────────────────
// ScoreService — Système de Score de Confiance IA — TontineClair
//
// SOURCE UNIQUE DE VÉRITÉ : toute l'application appelle ScoreService.calculerScore().
// Aucun autre fichier ne doit recalculer le score de manière indépendante.
//
// FORMULE DOCUMENTÉE (coefficients centralisés dans _Coeff) :
//   Base              :  50 pts (fix)
//   Ancienneté        :  max +10 (1 pt / mois, plafonné à 10 mois)
//   Cotisations       :  max +25 (taux * 25, arrondi)
//   Prêts remboursés  :  max +15 (5 pts / prêt soldé, plafonné)
//   Participation votes:  max +10 (taux votes * 10, 0 si aucun vote éligible)
//   Retards cotis.    :  max -20 (4 pts / retard, plafonné)
//   Pénalités         :  max -15 (5 pts / pénalité, plafonné)
//   Prêts en retard   :  max -20 (10 pts / prêt en retard, plafonné)
//   Prêts actifs mult.:  max  -5 (3 pts / prêt actif au-delà du 1er, plafonné)
//   Score final limité entre 0 et 100.
//
// Pour modifier les coefficients : éditez uniquement la classe _Coeff ci-dessous.
// ─────────────────────────────────────────────────────────────────────────────

import 'dart:math' as math;
import '../models/tontine.dart';
import '../models/score_modeles.dart';

// ─── Configuration centralisée des coefficients ──────────────────────────────
// Modifier ICI uniquement — ces valeurs s'appliquent partout uniformément.
class _Coeff {
  // Base de départ
  static const int base = 50;

  // Bonus
  static const int ancienneteMax    = 10;  // +1 pt par mois, max 10
  static const int cotisationsMax   = 25;  // taux de paiement × 25
  static const int pretsRemboursMax = 15;  // 5 pts par prêt soldé, max 15
  static const int votesMax         = 10;  // taux participation × 10

  // Malus
  static const int retardParUnite   = 4;   // −4 pts par retard de cotisation
  static const int retardsMax       = 20;  // plafond malus retards cotisation
  static const int penaliteParUnite = 5;   // −5 pts par pénalité appliquée
  static const int penalitesMax     = 15;  // plafond malus pénalités
  static const int pretRetardParUnite = 10; // −10 pts par prêt en retard
  static const int pretsRetardMax   = 20;  // plafond malus prêts en retard
  static const int pretActifSupp    = 3;   // −3 pts par prêt actif au-delà du 1er
  static const int pretsActifsMax   = 5;   // plafond malus prêts multiples
}

// ─────────────────────────────────────────────────────────────────────────────

class ScoreService {
  // ═══════════════════════════════════════════════════════════════════════════
  // CALCUL DU SCORE — SOURCE UNIQUE
  //
  // Cette méthode est la SEULE source de calcul dans toute l'application.
  // Elle est appelée par :
  //   • membres_screen.dart (liste des membres)
  //   • score_membre_screen.dart (fiche détaillée)
  //   • classement_screen.dart (classement)
  //   • votes_screen.dart (après clôture de vote)
  //   • cotisations_screen.dart (après paiement)
  //   • prets_screen.dart (après remboursement)
  //
  // Paramètres :
  //   data        : données complètes de la tontine (Supabase)
  //   membreId    : identifiant du membre à évaluer
  //   voixMembre  : votes exprimés par ce membre (depuis table voix Supabase)
  //                 Format : [{vote_id, membre_id, choix, quand, ...}]
  //
  // Retourne : ScoreDetail avec score (0-100), niveau, composantes détaillées
  // ═══════════════════════════════════════════════════════════════════════════

  static ScoreDetail calculerScore(
    TontineData data,
    String membreId,
    List<Map<String, dynamic>> voixMembre,
  ) {
    int score = _Coeff.base;
    final composantes = <ComposanteScore>[];
    final maintenant = DateTime.now();

    // ── Lire les stats du membre depuis data.stats[membreId] ─────────────────
    // data.stats est un Map<String,dynamic> stocké dans le JSONB Supabase.
    // Clés attendues : toursTotal, toursPayes, retards, penalites,
    //                  pretsRembourses, creeLe
    final statsRaw = data.stats[membreId];
    int toursTotal       = 0;
    int toursPayes       = 0;
    int retards          = 0;
    int penalites        = 0;
    int pretsRembourses  = 0;
    DateTime? dateEntree;

    if (statsRaw is Map) {
      toursTotal      = (statsRaw['toursTotal']      as num?)?.toInt() ?? 0;
      toursPayes      = (statsRaw['toursPayes']      as num?)?.toInt() ?? 0;
      retards         = (statsRaw['retards']         as num?)?.toInt() ?? 0;
      penalites       = (statsRaw['penalites']       as num?)?.toInt() ?? 0;
      pretsRembourses = (statsRaw['pretsRembourses'] as num?)?.toInt() ?? 0;

      // Date d'entrée du membre dans la tontine (pour ancienneté)
      final creeLe = statsRaw['creeLe'];
      if (creeLe is int) {
        dateEntree = DateTime.fromMillisecondsSinceEpoch(creeLe);
      } else if (creeLe is String) {
        dateEntree = DateTime.tryParse(creeLe);
      }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // COMPOSANTE 1 : Ancienneté (max +10)
    // Critère : mois de présence depuis la date d'entrée (creeLe dans stats).
    // Aucun bonus si dateEntree inconnue ou membre récent.
    // ─────────────────────────────────────────────────────────────────────────
    if (dateEntree != null) {
      final moisPresence = maintenant.difference(dateEntree).inDays ~/ 30;
      final bonus = math.min(_Coeff.ancienneteMax, moisPresence);
      if (bonus > 0) {
        score += bonus;
        composantes.add(ComposanteScore(
          label: 'Ancienneté',
          impact: bonus,
          detail: '$moisPresence mois de présence dans la tontine',
          type: TypeImpact.positif,
        ));
      } else {
        composantes.add(ComposanteScore(
          label: 'Ancienneté',
          impact: 0,
          detail: 'Membre récent — ancienneté insuffisante pour bonus',
          type: TypeImpact.neutre,
        ));
      }
    } else {
      composantes.add(ComposanteScore(
        label: 'Ancienneté',
        impact: 0,
        detail: 'Date d\'entrée non renseignée',
        type: TypeImpact.neutre,
      ));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // COMPOSANTE 2 : Cotisations payées à temps (max +25)
    // Critère : toursPayes / toursTotal — bonus proportionnel au taux.
    // Si aucun tour enregistré : neutre (ni bonus ni malus).
    // ─────────────────────────────────────────────────────────────────────────
    if (toursTotal > 0) {
      final taux = toursPayes / toursTotal;
      final bonus = (taux * _Coeff.cotisationsMax).round();
      score += bonus;
      final tauxPct = (taux * 100).round();
      composantes.add(ComposanteScore(
        label: 'Cotisations payées',
        impact: bonus,
        detail: '$toursPayes tour(s) payé(s) sur $toursTotal ($tauxPct%)',
        type: bonus >= 20
            ? TypeImpact.positif
            : bonus >= 12
                ? TypeImpact.neutre
                : TypeImpact.negatif,
      ));
    } else {
      composantes.add(ComposanteScore(
        label: 'Cotisations',
        impact: 0,
        detail: 'Aucun tour enregistré à ce jour',
        type: TypeImpact.neutre,
      ));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // COMPOSANTE 3 : Retards de cotisation (max -20)
    // Critère : nombre de retards dans data.stats[membreId].retards
    // Pénalité : 4 pts par retard, plafonnée à 20.
    // ─────────────────────────────────────────────────────────────────────────
    if (retards > 0) {
      final malus = math.min(_Coeff.retardsMax, retards * _Coeff.retardParUnite);
      score -= malus;
      composantes.add(ComposanteScore(
        label: 'Retards de cotisation',
        impact: -malus,
        detail: '$retards retard(s) de paiement enregistré(s)',
        type: TypeImpact.negatif,
      ));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // COMPOSANTE 4 : Pénalités reçues (max -15)
    // Critère : nombre de pénalités dans data.stats[membreId].penalites
    // Pénalité : 5 pts par sanction, plafonnée à 15.
    // ─────────────────────────────────────────────────────────────────────────
    if (penalites > 0) {
      final malus = math.min(_Coeff.penalitesMax, penalites * _Coeff.penaliteParUnite);
      score -= malus;
      composantes.add(ComposanteScore(
        label: 'Pénalités appliquées',
        impact: -malus,
        detail: '$penalites pénalité(s) reçue(s)',
        type: TypeImpact.negatif,
      ));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // COMPOSANTE 5 : Prêts intégralement remboursés (max +15)
    // Critère : pretsRembourses depuis stats (prêts soldés)
    // Bonus : 5 pts par prêt soldé, plafonné à 15.
    // ─────────────────────────────────────────────────────────────────────────
    if (pretsRembourses > 0) {
      final bonus = math.min(_Coeff.pretsRemboursMax, pretsRembourses * 5);
      score += bonus;
      composantes.add(ComposanteScore(
        label: 'Prêts remboursés',
        impact: bonus,
        detail: '$pretsRembourses prêt(s) intégralement remboursé(s)',
        type: TypeImpact.positif,
      ));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // COMPOSANTE 6 : Prêts avec échéances en retard (max -20)
    // Critère : prêts actifs dont au moins une échéance non payée est dépassée.
    // Pénalité : 10 pts par prêt en retard, plafonnée à 20.
    // NOTA : seuls les prêts non soldés sont considérés.
    // ─────────────────────────────────────────────────────────────────────────
    int nbPretsEnRetard = 0;
    for (final p in data.prets) {
      if (p.emprunteurId != membreId) continue;
      if (p.statut == 'soldé' || p.statut == 'solde') continue;
      // Vérifier si au moins une échéance est dépassée et non payée
      for (final ech in p.echeancier) {
        final dateEch = ech['date'] as String?;
        final paye    = ech['paye']  as bool? ?? false;
        if (!paye && dateEch != null) {
          final d = DateTime.tryParse(dateEch);
          if (d != null && d.isBefore(maintenant)) {
            nbPretsEnRetard++;
            break; // Un seul retard suffit pour ce prêt
          }
        }
      }
    }
    if (nbPretsEnRetard > 0) {
      final malus = math.min(
        _Coeff.pretsRetardMax,
        nbPretsEnRetard * _Coeff.pretRetardParUnite,
      );
      score -= malus;
      composantes.add(ComposanteScore(
        label: 'Prêts en retard',
        impact: -malus,
        detail: '$nbPretsEnRetard prêt(s) avec échéance(s) dépassée(s) non payée(s)',
        type: TypeImpact.negatif,
      ));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // COMPOSANTE 7 : Participation aux votes (max +10)
    // Critère : votes auxquels le membre ÉTAIT ÉLIGIBLE (votes créés après son
    //           entrée dans la tontine) vs votes exprimés depuis la table voix.
    //
    // RÈGLE D'ÉLIGIBILITÉ : un vote est éligible si sa date de création est
    // postérieure à la date d'entrée du membre (dateEntree).
    // Si dateEntree inconnue → tous les votes clos sont éligibles (conservatif).
    //
    // Impact : taux × votesMax, centré sur 50% de participation.
    //   taux = 100% → +10
    //   taux =  50% →   0
    //   taux =   0% → -10 (si ≥3 votes éligibles, sinon neutre)
    // ─────────────────────────────────────────────────────────────────────────
    final votesEligibles = data.votes.where((v) {
      if (!v.clos) return false; // Seuls les votes clos comptent
      if (dateEntree == null) return true;
      // Le vote est éligible si sa date est >= date d'entrée du membre
      final dv = DateTime.tryParse(v.dateCreation);
      if (dv == null) return true;
      return !dv.isBefore(dateEntree);
    }).toList();

    final nbEligibles   = votesEligibles.length;
    final nbParticipes  = voixMembre.length;

    if (nbEligibles > 0) {
      final taux = nbParticipes / nbEligibles;
      // Impact centré : -10 si 0%, 0 si 50%, +10 si 100%
      final impact = ((taux - 0.5) * _Coeff.votesMax * 2).round()
          .clamp(-_Coeff.votesMax, _Coeff.votesMax);
      // Pénalisation uniquement si ≥3 votes éligibles (éviter faux malus)
      final impactFinal = nbEligibles >= 3 ? impact : impact.clamp(0, _Coeff.votesMax);
      score += impactFinal;
      composantes.add(ComposanteScore(
        label: 'Participation aux votes',
        impact: impactFinal,
        detail: '$nbParticipes vote(s) exprimé(s) sur '
            '$nbEligibles scrutin(s) éligible(s) '
            '(${(taux * 100).round()}%)',
        type: impactFinal > 0
            ? TypeImpact.positif
            : impactFinal < 0
                ? TypeImpact.negatif
                : TypeImpact.neutre,
      ));
    } else {
      composantes.add(ComposanteScore(
        label: 'Participation aux votes',
        impact: 0,
        detail: 'Aucun scrutin éligible pour ce membre à ce jour',
        type: TypeImpact.neutre,
      ));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // COMPOSANTE 8 : Prêts actifs simultanés (max -5)
    // Critère : plus d'un prêt non soldé en même temps.
    // Pénalité légère : 3 pts par prêt supplémentaire, plafonnée à 5.
    // ─────────────────────────────────────────────────────────────────────────
    final nbPretsActifs = data.prets
        .where((p) =>
            p.emprunteurId == membreId && p.statutCalcule != 'solde')
        .length;
    if (nbPretsActifs > 1) {
      final malus = math.min(
        _Coeff.pretsActifsMax,
        (nbPretsActifs - 1) * _Coeff.pretActifSupp,
      );
      score -= malus;
      composantes.add(ComposanteScore(
        label: 'Prêts simultanés',
        impact: -malus,
        detail: '$nbPretsActifs prêts actifs en simultané',
        type: TypeImpact.negatif,
      ));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Score final : limité entre 0 et 100
    // ─────────────────────────────────────────────────────────────────────────
    final scoreFinal = score.clamp(0, 100);
    final niveau     = _niveauScore(scoreFinal);

    return ScoreDetail(
      score:      scoreFinal,
      niveau:     niveau,
      composantes: composantes,
      calculeLe:  maintenant,
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // RECOMMANDATIONS IA
  // Analyse comportementale uniquement — jamais décisionnelle.
  // Utilise exactement les mêmes données que calculerScore().
  // ═══════════════════════════════════════════════════════════════════════════

  static List<RecommandationIA> genererRecommandations(
    TontineData data,
    Membre membre,
    ScoreDetail scoreDetail,
    List<Map<String, dynamic>> voixMembre,
  ) {
    final recs    = <RecommandationIA>[];
    final score   = scoreDetail.score;
    final statsRaw = data.stats[membre.id];

    int toursTotal      = 0;
    int toursPayes      = 0;
    int retards         = 0;
    int penalites       = 0;
    int pretsRembourses = 0;
    DateTime? dateEntree;

    if (statsRaw is Map) {
      toursTotal      = (statsRaw['toursTotal']      as num?)?.toInt() ?? 0;
      toursPayes      = (statsRaw['toursPayes']      as num?)?.toInt() ?? 0;
      retards         = (statsRaw['retards']         as num?)?.toInt() ?? 0;
      penalites       = (statsRaw['penalites']       as num?)?.toInt() ?? 0;
      pretsRembourses = (statsRaw['pretsRembourses'] as num?)?.toInt() ?? 0;
      final creeLe = statsRaw['creeLe'];
      if (creeLe is int) {
        dateEntree = DateTime.fromMillisecondsSinceEpoch(creeLe);
      } else if (creeLe is String) {
        dateEntree = DateTime.tryParse(creeLe);
      }
    }

    final maintenant = DateTime.now();

    // Votes éligibles (même logique que calculerScore)
    final votesEligibles = data.votes.where((v) {
      if (!v.clos) return false;
      if (dateEntree == null) return true;
      final dv = DateTime.tryParse(v.dateCreation);
      if (dv == null) return true;
      return !dv.isBefore(dateEntree);
    }).length;

    final nbParticipes = voixMembre.length;

    // ── Analyse cotisations ────────────────────────────────────────────────
    if (toursTotal > 0) {
      final taux = toursPayes / toursTotal;
      if (taux >= 0.95 && score >= 75) {
        recs.add(RecommandationIA(
          type: TypeRecommandation.positif,
          titre: 'Membre très fiable',
          message: '${membre.nom} a payé ${(taux * 100).round()}% de ses '
              'cotisations ($toursPayes sur $toursTotal). Profil excellent, '
              'éligible à un prêt plus important si besoin.',
          priorite: 1,
          actionSuggeree: 'Envisager un plafond de prêt plus élevé',
        ));
      } else if (taux < 0.6 && retards >= 2) {
        recs.add(RecommandationIA(
          type: TypeRecommandation.alerte,
          titre: 'Plusieurs retards de paiement',
          message: '${membre.nom} présente $retards retard(s) avec un taux '
              'de cotisation de ${(taux * 100).round()}% '
              '($toursPayes payé(s) sur $toursTotal). '
              'Un suivi rapproché est recommandé.',
          priorite: 1,
          actionSuggeree: 'Envoyer une relance via WhatsApp',
        ));
      } else if (taux == 1.0 && toursTotal >= 3) {
        recs.add(RecommandationIA(
          type: TypeRecommandation.positif,
          titre: 'Régularité parfaite',
          message: '${membre.nom} a payé $toursTotal cotisations sur '
              '$toursTotal à temps — aucun retard enregistré.',
          priorite: 2,
          actionSuggeree: null,
        ));
      }
    }

    // ── Analyse prêts en retard ────────────────────────────────────────────
    final pretsRetard = <Pret>[];
    for (final p in data.prets) {
      if (p.emprunteurId != membre.id) continue;
      if (p.statut == 'soldé' || p.statut == 'solde') continue;
      for (final ech in p.echeancier) {
        final dateEch = ech['date'] as String?;
        final paye    = ech['paye']  as bool? ?? false;
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
        message: '${membre.nom} a ${pretsRetard.length} prêt(s) avec des '
            'échéances dépassées non remboursées. '
            'Le recouvrement doit être prioritaire.',
        priorite: 1,
        actionSuggeree: 'Contacter le membre pour un plan de remboursement',
      ));
    }

    // ── Analyse prêts remboursés ───────────────────────────────────────────
    if (pretsRembourses >= 2) {
      recs.add(RecommandationIA(
        type: TypeRecommandation.positif,
        titre: 'Excellent comportement de remboursement',
        message: '${membre.nom} a intégralement remboursé $pretsRembourses '
            'prêt(s). Ce membre démontre sa fiabilité financière.',
        priorite: 3,
        actionSuggeree: null,
      ));
    } else if (pretsRembourses == 1) {
      recs.add(RecommandationIA(
        type: TypeRecommandation.positif,
        titre: 'Prêt remboursé à temps',
        message: '${membre.nom} a remboursé son prêt sans retard.',
        priorite: 3,
        actionSuggeree: null,
      ));
    }

    // ── Analyse participation aux votes ────────────────────────────────────
    if (votesEligibles >= 3) {
      final taux = nbParticipes / votesEligibles;
      if (taux < 0.4) {
        recs.add(RecommandationIA(
          type: TypeRecommandation.info,
          titre: 'Membre peu actif dans les votes',
          message: '${membre.nom} n\'a participé qu\'à $nbParticipes vote(s) '
              'sur $votesEligibles scrutin(s) éligibles '
              '(${(taux * 100).round()}%). La participation démocratique '
              'est essentielle au bon fonctionnement de la tontine.',
          priorite: 2,
          actionSuggeree: 'Rappeler l\'importance du vote lors de la prochaine réunion',
        ));
      } else if (taux >= 0.9) {
        recs.add(RecommandationIA(
          type: TypeRecommandation.positif,
          titre: 'Participation citoyenne exemplaire',
          message: '${membre.nom} a participé à ${(taux * 100).round()}% '
              'des scrutins éligibles ($nbParticipes/$votesEligibles).',
          priorite: 3,
          actionSuggeree: null,
        ));
      }
    }

    // ── Pénalités ──────────────────────────────────────────────────────────
    if (penalites > 0) {
      recs.add(RecommandationIA(
        type: TypeRecommandation.info,
        titre: 'Pénalités enregistrées',
        message: '${membre.nom} a reçu $penalites pénalité(s). '
            'La régularisation de ces pénalités améliorera le score.',
        priorite: 2,
        actionSuggeree: 'Vérifier les pénalités en suspens',
      ));
    }

    // ── Risque élevé → suggestion de vote ─────────────────────────────────
    if (score < 35) {
      recs.add(RecommandationIA(
        type: TypeRecommandation.risque,
        titre: 'Risque élevé — Action collective recommandée',
        message: 'Le score de ${membre.nom} ($score/100) indique un risque '
            'sérieux pour la tontine. Les membres peuvent initier un vote '
            'de maintien ou de retrait selon le règlement intérieur.',
        priorite: 1,
        actionSuggeree: 'Proposer un vote de maintien ou de retrait',
      ));
    } else if (score < 50) {
      recs.add(RecommandationIA(
        type: TypeRecommandation.alerte,
        titre: 'Profil à surveiller',
        message: '${membre.nom} présente des signaux préoccupants '
            '(score $score/100). Un accompagnement préventif peut '
            'améliorer la situation.',
        priorite: 2,
        actionSuggeree: 'Planifier un entretien de suivi',
      ));
    }

    // ── Conseils d'amélioration ────────────────────────────────────────────
    if (score < 70) {
      final conseils = _conseilsAmelioration(
        retards:      retards,
        penalites:    penalites,
        nbPretsRetard: pretsRetard.length,
        tauxVote:     votesEligibles > 0 ? nbParticipes / votesEligibles : 1.0,
        score:        score,
      );
      if (conseils.isNotEmpty) {
        recs.add(RecommandationIA(
          type: TypeRecommandation.conseil,
          titre: 'Comment améliorer le score',
          message: conseils,
          priorite: 3,
          actionSuggeree: null,
        ));
      }
    }

    recs.sort((a, b) => a.priorite.compareTo(b.priorite));
    return recs;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // CLASSEMENT des membres par score (gestionnaires uniquement)
  // ═══════════════════════════════════════════════════════════════════════════

  static List<EntreeClassement> classerMembres(
    TontineData data,
    Map<String, List<Map<String, dynamic>>> voixParMembre,
  ) {
    final membres    = data.membresActifs;
    final classement = <EntreeClassement>[];

    for (final m in membres) {
      final voix   = voixParMembre[m.id] ?? [];
      final detail = calculerScore(data, m.id, voix);
      classement.add(EntreeClassement(membre: m, scoreDetail: detail));
    }

    classement.sort((a, b) => b.scoreDetail.score.compareTo(a.scoreDetail.score));

    for (int i = 0; i < classement.length; i++) {
      classement[i] = classement[i].copyWithRang(i + 1);
    }

    return classement;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // RECALCUL APRÈS ÉVÉNEMENT
  // Appeler après cotisation, retard, prêt, vote, sanction, etc.
  // Retourne le nouveau ScoreDetail (identique à calculerScore).
  // ═══════════════════════════════════════════════════════════════════════════

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

  /// true si l'écart entre ancien et nouveau score est significatif (≥2 pts)
  static bool evolutionSignificative(int ancien, int nouveau) {
    return (nouveau - ancien).abs() >= 2;
  }

  /// Label humain pour un type d'événement de score
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
  // HELPERS PRIVÉS
  // ═══════════════════════════════════════════════════════════════════════════

  static NiveauScore _niveauScore(int score) {
    if (score >= 80) return NiveauScore.tresFiable;
    if (score >= 65) return NiveauScore.fiable;
    if (score >= 50) return NiveauScore.aSurveiller;
    if (score >= 35) return NiveauScore.risque;
    return NiveauScore.tresRisque;
  }

  static String _conseilsAmelioration({
    required int retards,
    required int penalites,
    required int nbPretsRetard,
    required double tauxVote,
    required int score,
  }) {
    final items = <String>[];
    if (nbPretsRetard > 0) {
      items.add('• Rembourser les échéances de prêt en attente (prioritaire)');
    }
    if (retards > 0) {
      items.add('• Payer les cotisations avant ou à la date d\'échéance');
    }
    if (penalites > 0) {
      items.add('• Régulariser les pénalités en suspens');
    }
    if (tauxVote < 0.7) {
      items.add('• Participer activement aux votes de la tontine');
    }
    if (score < 60) {
      items.add(
          '• La régularité sur les 3 prochains tours améliorera rapidement le score');
    }
    return items.join('\n');
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // ACCESSEURS PUBLICS (niveau, couleur, emoji)
  // Utilisables depuis n'importe quelle interface Flutter.
  // ═══════════════════════════════════════════════════════════════════════════

  static String labelNiveau(NiveauScore niveau) {
    switch (niveau) {
      case NiveauScore.tresFiable:   return 'Très fiable';
      case NiveauScore.fiable:       return 'Fiable';
      case NiveauScore.aSurveiller:  return 'À surveiller';
      case NiveauScore.risque:       return 'Risqué';
      case NiveauScore.tresRisque:   return 'Très risqué';
    }
  }

  static String emojiNiveau(NiveauScore niveau) {
    switch (niveau) {
      case NiveauScore.tresFiable:   return '🟢';
      case NiveauScore.fiable:       return '🔵';
      case NiveauScore.aSurveiller:  return '🟡';
      case NiveauScore.risque:       return '🟠';
      case NiveauScore.tresRisque:   return '🔴';
    }
  }
}
