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
    // ── SCORE OVERRIDE : si un admin a forcé le score manuellement, ──────────
    // on l'utilise DIRECTEMENT sans recalculer depuis les stats.
    // Cela garantit que la modification manuelle persiste sur toutes les
    // interfaces (liste membres, fiche, classement, tableau de bord, IA).
    final membreOverride = data.membres.where((m) => m.id == membreId).firstOrNull;
    if (membreOverride != null && membreOverride.scoreOverride != null) {
      final overrideScore = membreOverride.scoreOverride!.clamp(0, 100);
      final niveau        = _niveauScore(overrideScore);
      return ScoreDetail(
        score: overrideScore,
        niveau: niveau,
        composantes: [
          ComposanteScore(
            label:  'Score modifié manuellement',
            impact: overrideScore - _Coeff.base,
            detail: 'Score forcé à $overrideScore/100 par '
                    '${membreOverride.adminOverride ?? "admin"}'
                    '${membreOverride.motifOverride != null ? " — ${membreOverride.motifOverride}" : ""}',
            type: overrideScore >= _Coeff.base
                ? TypeImpact.positif
                : TypeImpact.negatif,
          ),
        ],
        calculeLe: DateTime.now(),
      );
    }
    // ── FIN SCORE OVERRIDE ────────────────────────────────────────────────────

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
    List<Map<String, dynamic>> voixMembre, {
    String langueCode = 'fr',
  }) {
    // Helper traduction IA interne
    final _l = ['fr','en','es','pt','ar'].contains(langueCode) ? langueCode : 'fr';
    String _tr(Map<String,String> m) => m[_l] ?? m['fr'] ?? '';
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
          titre: _tr({'fr':'Membre très fiable','en':'Very reliable member','es':'Miembro muy fiable','pt':'Membro muito fiável','ar':'عضو موثوق جداً'}),
          message: _tr({
            'fr': '${membre.nom} a payé ${(taux*100).round()}% de ses cotisations ($toursPayes sur $toursTotal). Profil excellent, éligible à un prêt plus important si besoin.',
            'en': '${membre.nom} paid ${(taux*100).round()}% of contributions ($toursPayes out of $toursTotal). Excellent profile, eligible for a larger loan if needed.',
            'es': '${membre.nom} ha pagado el ${(taux*100).round()}% de sus cotizaciones ($toursPayes de $toursTotal). Perfil excelente, elegible para un préstamo mayor si es necesario.',
            'pt': '${membre.nom} pagou ${(taux*100).round()}% das contribuições ($toursPayes de $toursTotal). Perfil excelente, elegível para um empréstimo maior se necessário.',
            'ar': 'دفع ${membre.nom} ${(taux*100).round()}% من الاشتراكات ($toursPayes من $toursTotal). ملف ممتاز، مؤهل للحصول على قرض أكبر عند الحاجة.',
          }),
          priorite: 1,
          actionSuggeree: _tr({'fr':'Envisager un plafond de prêt plus élevé','en':'Consider a higher loan limit','es':'Considerar un límite de préstamo más alto','pt':'Considerar um limite de empréstimo mais alto','ar':'النظر في رفع سقف القرض'}),
        ));
      } else if (taux < 0.6 && retards >= 2) {
        recs.add(RecommandationIA(
          type: TypeRecommandation.alerte,
          titre: _tr({'fr':'Plusieurs retards de paiement','en':'Multiple payment delays','es':'Varios retrasos de pago','pt':'Vários atrasos de pagamento','ar':'تأخيرات متعددة في الدفع'}),
          message: _tr({
            'fr': '${membre.nom} présente $retards retard(s) avec un taux de cotisation de ${(taux*100).round()}% ($toursPayes payé(s) sur $toursTotal). Un suivi rapproché est recommandé.',
            'en': '${membre.nom} has $retards delay(s) with a contribution rate of ${(taux*100).round()}% ($toursPayes paid out of $toursTotal). Close monitoring is recommended.',
            'es': '${membre.nom} presenta $retards retraso(s) con una tasa de cotización del ${(taux*100).round()}% ($toursPayes pagado(s) de $toursTotal). Se recomienda un seguimiento cercano.',
            'pt': '${membre.nom} tem $retards atraso(s) com uma taxa de contribuição de ${(taux*100).round()}% ($toursPayes pago(s) de $toursTotal). Recomenda-se um acompanhamento próximo.',
            'ar': 'لدى ${membre.nom} $retards تأخير(ات) بمعدل اشتراك ${(taux*100).round()}% ($toursPayes مدفوع من $toursTotal). يُوصى بمتابعة دقيقة.',
          }),
          priorite: 1,
          actionSuggeree: _tr({'fr':'Envoyer une relance via WhatsApp','en':'Send a reminder via WhatsApp','es':'Enviar un recordatorio por WhatsApp','pt':'Enviar um lembrete via WhatsApp','ar':'إرسال تذكير عبر WhatsApp'}),
        ));
      } else if (taux == 1.0 && toursTotal >= 3) {
        recs.add(RecommandationIA(
          type: TypeRecommandation.positif,
          titre: _tr({'fr':'Régularité parfaite','en':'Perfect regularity','es':'Regularidad perfecta','pt':'Regularidade perfeita','ar':'انتظام مثالي'}),
          message: _tr({
            'fr': '${membre.nom} a payé $toursTotal cotisations sur $toursTotal à temps — aucun retard enregistré.',
            'en': '${membre.nom} paid $toursTotal out of $toursTotal contributions on time — no delays recorded.',
            'es': '${membre.nom} ha pagado $toursTotal de $toursTotal cotizaciones a tiempo — ningún retraso registrado.',
            'pt': '${membre.nom} pagou $toursTotal de $toursTotal contribuições a tempo — nenhum atraso registado.',
            'ar': 'دفع ${membre.nom} $toursTotal من $toursTotal اشتراكاً في الوقت المحدد — لا تأخيرات مسجلة.',
          }),
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
        titre: _tr({'fr':'Prêt(s) en retard de remboursement','en':'Overdue loan repayment(s)','es':'Préstamo(s) con reembolso atrasado','pt':'Empréstimo(s) com reembolso em atraso','ar':'قرض(روض) متأخر في السداد'}),
        message: _tr({
          'fr': '${membre.nom} a ${pretsRetard.length} prêt(s) avec des échéances dépassées non remboursées. Le recouvrement doit être prioritaire.',
          'en': '${membre.nom} has ${pretsRetard.length} loan(s) with overdue unpaid instalments. Recovery must be a priority.',
          'es': '${membre.nom} tiene ${pretsRetard.length} préstamo(s) con cuotas vencidas sin pagar. El cobro debe ser prioritario.',
          'pt': '${membre.nom} tem ${pretsRetard.length} empréstimo(s) com prestações vencidas não pagas. A cobrança deve ser prioritária.',
          'ar': 'لدى ${membre.nom} ${pretsRetard.length} قرض(قروض) بأقساط متأخرة غير مسددة. يجب إعطاء الأولوية للتحصيل.',
        }),
        priorite: 1,
        actionSuggeree: _tr({'fr':'Contacter le membre pour un plan de remboursement','en':'Contact the member for a repayment plan','es':'Contactar al miembro para un plan de reembolso','pt':'Contactar o membro para um plano de reembolso','ar':'التواصل مع العضو لوضع خطة سداد'}),
      ));
    }

    // ── Analyse prêts remboursés ───────────────────────────────────────────
    if (pretsRembourses >= 2) {
      recs.add(RecommandationIA(
        type: TypeRecommandation.positif,
        titre: _tr({'fr':'Excellent comportement de remboursement','en':'Excellent repayment behaviour','es':'Excelente comportamiento de reembolso','pt':'Excelente comportamento de reembolso','ar':'سلوك سداد ممتاز'}),
        message: _tr({
          'fr': '${membre.nom} a intégralement remboursé $pretsRembourses prêt(s). Ce membre démontre sa fiabilité financière.',
          'en': '${membre.nom} has fully repaid $pretsRembourses loan(s). This member demonstrates financial reliability.',
          'es': '${membre.nom} ha reembolsado íntegramente $pretsRembourses préstamo(s). Este miembro demuestra su fiabilidad financiera.',
          'pt': '${membre.nom} reembolsou integralmente $pretsRembourses empréstimo(s). Este membro demonstra fiabilidade financeira.',
          'ar': 'سدّد ${membre.nom} $pretsRembourses قرض(قروض) بالكامل. يُظهر هذا العضو موثوقيته المالية.',
        }),
        priorite: 3,
        actionSuggeree: null,
      ));
    } else if (pretsRembourses == 1) {
      recs.add(RecommandationIA(
        type: TypeRecommandation.positif,
        titre: _tr({'fr':'Prêt remboursé à temps','en':'Loan repaid on time','es':'Préstamo reembolsado a tiempo','pt':'Empréstimo reembolsado a tempo','ar':'تم سداد القرض في الوقت المحدد'}),
        message: _tr({
          'fr': '${membre.nom} a remboursé son prêt sans retard.',
          'en': '${membre.nom} repaid their loan without delay.',
          'es': '${membre.nom} reembolsó su préstamo sin retraso.',
          'pt': '${membre.nom} reembolsou o seu empréstimo sem atraso.',
          'ar': 'سدّد ${membre.nom} قرضه في الوقت المحدد دون تأخير.',
        }),
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
          titre: _tr({'fr':'Membre peu actif dans les votes','en':'Member rarely participates in votes','es':'Miembro poco activo en las votaciones','pt':'Membro pouco ativo nas votações','ar':'عضو قليل المشاركة في التصويت'}),
          message: _tr({
            'fr': '${membre.nom} n\'a participé qu\'à $nbParticipes vote(s) sur $votesEligibles scrutin(s) éligibles (${(taux*100).round()}%). La participation démocratique est essentielle au bon fonctionnement de la tontine.',
            'en': '${membre.nom} only participated in $nbParticipes vote(s) out of $votesEligibles eligible poll(s) (${(taux*100).round()}%). Democratic participation is essential to the tontine\'s proper functioning.',
            'es': '${membre.nom} solo participó en $nbParticipes votación(es) de $votesEligibles escrutinio(s) elegibles (${(taux*100).round()}%). La participación democrática es esencial para el buen funcionamiento de la tontina.',
            'pt': '${membre.nom} só participou em $nbParticipes voto(s) de $votesEligibles escrutínio(s) elegíveis (${(taux*100).round()}%). A participação democrática é essencial para o bom funcionamento da tontina.',
            'ar': 'شارك ${membre.nom} فقط في $nbParticipes تصويت(ات) من $votesEligibles تصويت(ات) مؤهلة (${(taux*100).round()}%). المشاركة الديمقراطية أساسية لحسن سير التنتين.',
          }),
          priorite: 2,
          actionSuggeree: _tr({'fr':'Rappeler l\'importance du vote lors de la prochaine réunion','en':'Remind about the importance of voting at the next meeting','es':'Recordar la importancia del voto en la próxima reunión','pt':'Lembrar a importância do voto na próxima reunião','ar':'تذكير بأهمية التصويت في الاجتماع القادم'}),
        ));
      } else if (taux >= 0.9) {
        recs.add(RecommandationIA(
          type: TypeRecommandation.positif,
          titre: _tr({'fr':'Participation citoyenne exemplaire','en':'Exemplary civic participation','es':'Participación ciudadana ejemplar','pt':'Participação cívica exemplar','ar':'مشاركة مدنية مثالية'}),
          message: _tr({
            'fr': '${membre.nom} a participé à ${(taux*100).round()}% des scrutins éligibles ($nbParticipes/$votesEligibles).',
            'en': '${membre.nom} participated in ${(taux*100).round()}% of eligible polls ($nbParticipes/$votesEligibles).',
            'es': '${membre.nom} participó en el ${(taux*100).round()}% de los escrutinios elegibles ($nbParticipes/$votesEligibles).',
            'pt': '${membre.nom} participou em ${(taux*100).round()}% dos escrutínios elegíveis ($nbParticipes/$votesEligibles).',
            'ar': 'شارك ${membre.nom} في ${(taux*100).round()}% من التصويتات المؤهلة ($nbParticipes/$votesEligibles).',
          }),
          priorite: 3,
          actionSuggeree: null,
        ));
      }
    }

    // ── Pénalités ──────────────────────────────────────────────────────────
    if (penalites > 0) {
      recs.add(RecommandationIA(
        type: TypeRecommandation.info,
        titre: _tr({'fr':'Pénalités enregistrées','en':'Penalties recorded','es':'Penalizaciones registradas','pt':'Penalidades registadas','ar':'عقوبات مسجلة'}),
        message: _tr({
          'fr': '${membre.nom} a reçu $penalites pénalité(s). La régularisation de ces pénalités améliorera le score.',
          'en': '${membre.nom} received $penalites penalty(ies). Settling these penalties will improve the score.',
          'es': '${membre.nom} ha recibido $penalites penalización(es). La regularización de estas penalizaciones mejorará la puntuación.',
          'pt': '${membre.nom} recebeu $penalites penalidade(s). A regularização destas penalidades melhorará a pontuação.',
          'ar': 'تلقّى ${membre.nom} $penalites عقوبة(عقوبات). تسوية هذه العقوبات ستحسّن النتيجة.',
        }),
        priorite: 2,
        actionSuggeree: _tr({'fr':'Vérifier les pénalités en suspens','en':'Check pending penalties','es':'Verificar las penalizaciones pendientes','pt':'Verificar as penalidades pendentes','ar':'مراجعة العقوبات المعلقة'}),
      ));
    }

    // ── Risque élevé → suggestion de vote ─────────────────────────────────
    if (score < 35) {
      recs.add(RecommandationIA(
        type: TypeRecommandation.risque,
        titre: _tr({'fr':'Risque élevé — Action collective recommandée','en':'High risk — Collective action recommended','es':'Riesgo alto — Acción colectiva recomendada','pt':'Risco elevado — Ação coletiva recomendada','ar':'خطر مرتفع — يُوصى باتخاذ إجراء جماعي'}),
        message: _tr({
          'fr': 'Le score de ${membre.nom} ($score/100) indique un risque sérieux pour la tontine. Les membres peuvent initier un vote de maintien ou de retrait selon le règlement intérieur.',
          'en': '${membre.nom}\'s score ($score/100) indicates a serious risk for the tontine. Members may initiate a vote to maintain or remove the member according to internal rules.',
          'es': 'La puntuación de ${membre.nom} ($score/100) indica un riesgo serio para la tontina. Los miembros pueden iniciar una votación de mantenimiento o retirada según el reglamento interno.',
          'pt': 'A pontuação de ${membre.nom} ($score/100) indica um risco sério para a tontina. Os membros podem iniciar uma votação de manutenção ou retirada de acordo com o regulamento interno.',
          'ar': 'تشير نتيجة ${membre.nom} ($score/100) إلى خطر جدي على التنتين. يمكن للأعضاء بدء تصويت للإبقاء أو الإقصاء وفقاً للنظام الداخلي.',
        }),
        priorite: 1,
        actionSuggeree: _tr({'fr':'Proposer un vote de maintien ou de retrait','en':'Propose a vote to maintain or remove the member','es':'Proponer una votación de mantenimiento o retirada','pt':'Propor uma votação de manutenção ou retirada','ar':'اقتراح تصويت للإبقاء أو الإقصاء'}),
      ));
    } else if (score < 50) {
      recs.add(RecommandationIA(
        type: TypeRecommandation.alerte,
        titre: _tr({'fr':'Profil à surveiller','en':'Profile to monitor','es':'Perfil a vigilar','pt':'Perfil a monitorizar','ar':'ملف يستدعي المراقبة'}),
        message: _tr({
          'fr': '${membre.nom} présente des signaux préoccupants (score $score/100). Un accompagnement préventif peut améliorer la situation.',
          'en': '${membre.nom} shows concerning signals (score $score/100). Preventive support can improve the situation.',
          'es': '${membre.nom} presenta señales preocupantes (puntuación $score/100). Un acompañamiento preventivo puede mejorar la situación.',
          'pt': '${membre.nom} apresenta sinais preocupantes (pontuação $score/100). Um acompanhamento preventivo pode melhorar a situação.',
          'ar': 'يُظهر ${membre.nom} إشارات مقلقة (النتيجة $score/100). المرافقة الوقائية يمكن أن تحسّن الوضع.',
        }),
        priorite: 2,
        actionSuggeree: _tr({'fr':'Planifier un entretien de suivi','en':'Schedule a follow-up interview','es':'Planificar una entrevista de seguimiento','pt':'Planear uma entrevista de acompanhamento','ar':'جدولة مقابلة متابعة'}),
      ));
    }

    // ── Conseils d'amélioration ────────────────────────────────────────────
    if (score < 70) {
      final conseils = _conseilsAmelioration(
        retards:       retards,
        penalites:     penalites,
        nbPretsRetard: pretsRetard.length,
        tauxVote:      votesEligibles > 0 ? nbParticipes / votesEligibles : 1.0,
        score:         score,
        langueCode:    _l,
      );
      if (conseils.isNotEmpty) {
        recs.add(RecommandationIA(
          type: TypeRecommandation.conseil,
          titre: _tr({'fr':'Comment améliorer le score','en':'How to improve the score','es':'Cómo mejorar la puntuación','pt':'Como melhorar a pontuação','ar':'كيفية تحسين النتيجة'}),
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
    String langueCode = 'fr',
  }) {
    final l = ['fr','en','es','pt','ar'].contains(langueCode) ? langueCode : 'fr';
    final items = <String>[];
    if (nbPretsRetard > 0) {
      items.add({
        'fr': '• Rembourser les échéances de prêt en attente (prioritaire)',
        'en': '• Repay pending loan instalments (priority)',
        'es': '• Reembolsar las cuotas de préstamo pendientes (prioritario)',
        'pt': '• Reembolsar as prestações de empréstimo pendentes (prioritário)',
        'ar': '• سداد أقساط القرض المعلقة (أولوية)',
      }[l]!);
    }
    if (retards > 0) {
      items.add({
        'fr': '• Payer les cotisations avant ou à la date d\'échéance',
        'en': '• Pay contributions before or on the due date',
        'es': '• Pagar las cotizaciones antes o en la fecha de vencimiento',
        'pt': '• Pagar as contribuições antes ou na data de vencimento',
        'ar': '• دفع الاشتراكات قبل أو في موعد الاستحقاق',
      }[l]!);
    }
    if (penalites > 0) {
      items.add({
        'fr': '• Régulariser les pénalités en suspens',
        'en': '• Settle pending penalties',
        'es': '• Regularizar las penalizaciones pendientes',
        'pt': '• Regularizar as penalidades pendentes',
        'ar': '• تسوية العقوبات المعلقة',
      }[l]!);
    }
    if (tauxVote < 0.7) {
      items.add({
        'fr': '• Participer activement aux votes de la tontine',
        'en': '• Actively participate in tontine votes',
        'es': '• Participar activamente en las votaciones de la tontina',
        'pt': '• Participar ativamente nas votações da tontina',
        'ar': '• المشاركة الفعالة في تصويتات التنتين',
      }[l]!);
    }
    if (score < 60) {
      items.add({
        'fr': '• La régularité sur les 3 prochains tours améliorera rapidement le score',
        'en': '• Regularity over the next 3 rounds will quickly improve the score',
        'es': '• La regularidad en las próximas 3 rondas mejorará rápidamente la puntuación',
        'pt': '• A regularidade nas próximas 3 rondas melhorará rapidamente a pontuação',
        'ar': '• الانتظام في الجولات الـ3 القادمة سيحسّن النتيجة بسرعة',
      }[l]!);
    }
    return items.join('\n');
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // ACCESSEURS PUBLICS (niveau, couleur, emoji)
  // Utilisables depuis n'importe quelle interface Flutter.
  // ═══════════════════════════════════════════════════════════════════════════

  static String labelNiveau(NiveauScore niveau, {String langueCode = 'fr'}) {
    final l = ['fr','en','es','pt','ar'].contains(langueCode) ? langueCode : 'fr';
    const _labels = {
      'tresFiable':  {'fr':'Très fiable',   'en':'Very reliable',  'es':'Muy fiable',    'pt':'Muito fiável',   'ar':'موثوق جداً'},
      'fiable':      {'fr':'Fiable',         'en':'Reliable',       'es':'Fiable',         'pt':'Fiável',         'ar':'موثوق'},
      'aSurveiller': {'fr':'À surveiller',   'en':'To monitor',     'es':'A vigilar',      'pt':'A monitorizar',  'ar':'يستدعي المراقبة'},
      'risque':      {'fr':'Risqué',         'en':'Risky',          'es':'Arriesgado',     'pt':'Arriscado',      'ar':'خطر'},
      'tresRisque':  {'fr':'Très risqué',    'en':'Very risky',     'es':'Muy arriesgado', 'pt':'Muito arriscado','ar':'خطر جداً'},
    };
    switch (niveau) {
      case NiveauScore.tresFiable:   return _labels['tresFiable']![l]!;
      case NiveauScore.fiable:       return _labels['fiable']![l]!;
      case NiveauScore.aSurveiller:  return _labels['aSurveiller']![l]!;
      case NiveauScore.risque:       return _labels['risque']![l]!;
      case NiveauScore.tresRisque:   return _labels['tresRisque']![l]!;
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
