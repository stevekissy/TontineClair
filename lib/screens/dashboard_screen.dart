// ─────────────────────────────────────────────────────────────────────────────
// Module Tableau de bord — TontineClair
// Spécification : FICHE-MODULE-DASHBOARD-PARTAGE.pdf §1
// 8 indicateurs, 4 alertes, prochain bénéficiaire, export PDF
// ─────────────────────────────────────────────────────────────────────────────

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/tontine.dart';
import '../services/tontine_provider.dart';
import '../services/pdf_service.dart';
import '../utils/app_colors.dart';
import '../utils/formatters.dart';
import '../widgets/app_widgets.dart';

// ─── Constante seuil score faible ────────────────────────────────────────────
const int _seuilScoreFaible = 40;
const int _seuilJoursEcheancePret = 7;

class DashboardScreen extends StatelessWidget {
  final String code;

  const DashboardScreen({super.key, required this.code});

  // ── Calculs des 8 indicateurs ────────────────────────────────────────────

  /// Total cotisé depuis le début :
  /// somme des tours clôturés + cotisations reçues du tour en cours
  static int _totalCotise(TontineData data) {
    // Tours clôturés : historique
    int toursClos = 0;
    for (final h in data.historique) {
      final total = (h['totalRecu'] as num?)?.toInt()
          ?? (h['total'] as num?)?.toInt()
          ?? 0;
      // Si pas de totalRecu, on reconstitue : nbPayes × montant
      final nb = (h['nbPayes'] as num?)?.toInt();
      toursClos += total > 0 ? total : (nb ?? data.membres.length) * data.montant;
    }
    // Tour en cours : membres ayant payé
    final tourEnCours = data.membres.where((m) => m.paye).length * data.montant;
    return toursClos + tourEnCours;
  }

  /// Attendu sur le cycle complet : N × cotisation × N
  static int _attenduCycleComplet(TontineData data) {
    final n = data.membres.length;
    return n * data.montant * n;
  }

  /// Membres à jour ce tour : nombre de paiements reçus
  static int _membresAJour(TontineData data) =>
      data.membres.where((m) => m.paye).length;

  /// Membres en attente : N - membres à jour
  static int _membresEnAttente(TontineData data) =>
      data.membres.length - _membresAJour(data);

  /// Caisse disponible : solde net de tous les mouvements
  static int _caisseDisponible(TontineData data) => data.soldeCaisse;

  /// Pénalités collectées : somme des mouvements de type 'penalite'
  static int _penalites(TontineData data) {
    return data.caisse
        .where((m) => m.type == 'penalite')
        .fold(0, (sum, m) => sum + m.montant);
  }

  /// Prêts en cours : nombre + montant total restant dû
  static ({int nombre, int totalDu}) _pretsEnCours(TontineData data) {
    final actifs = data.prets
        .where((p) => p.statut != 'soldé' && p.statut != 'solde')
        .toList();
    final totalDu = actifs.fold(0, (sum, p) => sum + p.resteADu);
    return (nombre: actifs.length, totalDu: totalDu);
  }

  /// Votes ouverts : nombre de votes au statut 'ouvert'
  static int _votesOuverts(TontineData data) =>
      data.votes.where((v) => v.statut == 'ouvert').length;

  // ── Alertes ──────────────────────────────────────────────────────────────

  static List<_Alerte> _calculerAlertes(TontineData data) {
    final alertes = <_Alerte>[];
    final maintenant = DateTime.now();

    // 1. Échéance de cotisation dépassée + retardataires
    if (data.echeance != null) {
      final ech = DateTime.tryParse(data.echeance!);
      if (ech != null && ech.isBefore(maintenant)) {
        final nb = _membresEnAttente(data);
        if (nb > 0) {
          alertes.add(_Alerte(
            emoji: '⚠️',
            message: 'Échéance dépassée : $nb membre${nb > 1 ? 's' : ''} n\'ont pas cotisé.',
            couleur: AppColors.alerte,
            fond: AppColors.alerteFond,
          ));
        }
      }
    }

    // 2. Prêts en retard (montant dû cumulé > montant remboursé)
    for (final p in data.prets) {
      if (p.statut == 'soldé' || p.statut == 'solde') continue;
      if (p.resteADu <= 0) continue;
      // Vérifier si des échéances sont dépassées et non payées
      bool enRetard = false;
      for (final ech in p.echeancier) {
        // BUG FIX : ech['date'] peut être int (ms) ou String ISO
        final dateRaw = ech['date'];
        final paye = ech['paye'] as bool? ?? false;
        if (!paye && dateRaw != null) {
          DateTime? d;
          if (dateRaw is int) d = DateTime.fromMillisecondsSinceEpoch(dateRaw);
          else if (dateRaw is String) d = DateTime.tryParse(dateRaw);
          if (d != null && d.isBefore(maintenant)) {
            enRetard = true;
            break;
          }
        }
      }
      if (enRetard) {
        final nom = p.emprunteurNom.isNotEmpty
            ? p.emprunteurNom
            : data.membres
                .where((m) => m.id == p.emprunteurId)
                .map((m) => m.nom)
                .firstOrNull ?? p.emprunteurId;
        alertes.add(_Alerte(
          emoji: '🔴',
          message: 'Prêt en retard : $nom doit ${Formatters.montantFCFA(p.resteADu)} de retard sur son échéancier.',
          couleur: AppColors.alerte,
          fond: AppColors.alerteFond,
        ));
      }
    }

    // 3. Échéance de prêt proche (0 à 7 jours)
    for (final p in data.prets) {
      if (p.statut == 'soldé' || p.statut == 'solde') continue;
      for (final ech in p.echeancier) {
        // BUG FIX : ech['date'] peut être int (ms) ou String ISO
        final dateRaw = ech['date'];
        final paye = ech['paye'] as bool? ?? false;
        if (paye || dateRaw == null) continue;
        DateTime? d;
        if (dateRaw is int) d = DateTime.fromMillisecondsSinceEpoch(dateRaw);
        else if (dateRaw is String) d = DateTime.tryParse(dateRaw);
        if (d == null) continue;
        final diff = d.difference(maintenant).inDays;
        if (diff >= 0 && diff <= _seuilJoursEcheancePret) {
          final montantEch = (ech['montant'] as num?)?.toInt() ?? 0;
          final nom = p.emprunteurNom.isNotEmpty
              ? p.emprunteurNom
              : data.membres
                  .where((m) => m.id == p.emprunteurId)
                  .map((m) => m.nom)
                  .firstOrNull ?? p.emprunteurId;
          final delai = diff == 0 ? "aujourd'hui" : "dans $diff j.";
          alertes.add(_Alerte(
            emoji: '📅',
            message: 'Échéance de prêt proche : $nom — ${Formatters.montantFCFA(montantEch)} attendu $delai.',
            couleur: AppColors.or,
            fond: AppColors.fondConsultation,
          ));
        }
      }
    }

    // 4. Score de confiance faible (< 40)
    // On recalcule depuis les stats (même logique que membres_screen)
    for (final m in data.membres) {
      final statsRaw = data.stats[m.id];
      if (statsRaw is! Map) continue;
      // Score simplifié (sans ancienneté pour alerte rapide)
      int score = 50;
      final toursTotal = (statsRaw['toursTotal'] as num?)?.toInt() ?? 0;
      final toursPayes = (statsRaw['toursPayes'] as num?)?.toInt() ?? 0;
      final retards = (statsRaw['retards'] as num?)?.toInt() ?? 0;
      final penalites = (statsRaw['penalites'] as num?)?.toInt() ?? 0;
      final pretsRembourses = (statsRaw['pretsRembourses'] as num?)?.toInt() ?? 0;
      if (toursTotal > 0) {
        score += (30 * toursPayes / toursTotal).round();
        score -= retards * 4 < 20 ? retards * 4 : 20;
      }
      score -= penalites * 5 < 15 ? penalites * 5 : 15;
      score += pretsRembourses * 5 < 10 ? pretsRembourses * 5 : 10;
      score = score.clamp(0, 100);
      if (score < _seuilScoreFaible) {
        alertes.add(_Alerte(
          emoji: '⚡',
          message: 'Score de confiance faible : ${m.nom} ($score/100).',
          couleur: AppColors.alerte,
          fond: AppColors.alerteFond,
        ));
      }
    }

    return alertes;
  }

  // ── Prochain bénéficiaire ─────────────────────────────────────────────────
  static ({String? nom, int montant, bool cycleTermine}) _prochainBeneficiaire(
      TontineData data) {
    if (data.cycleTermine || data.ordre.isEmpty) {
      return (nom: null, montant: 0, cycleTermine: true);
    }
    // beneficiaire = membres[ ordre[tourActuel] ] (tourActuel = index 0-based)
    final beneficiaire = data.beneficiaire;
    // Montant qu'il recevra = N cotisations (tout le monde cotise, bénéficiaire inclus)
    final n = data.ordre.length;
    final montantRecu = n * data.montant;
    return (nom: beneficiaire?.nom, montant: montantRecu, cycleTermine: false);
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<TontineProvider>();
    final tontine = provider.courante;
    if (tontine == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final data = tontine.data;
    final membres = data.membres;
    final aJour = _membresAJour(data);
    final enAttente = _membresEnAttente(data);
    final caisse = _caisseDisponible(data);
    final penalites = _penalites(data);
    final pretsInfo = _pretsEnCours(data);
    final votesOuverts = _votesOuverts(data);
    final totalCotise = _totalCotise(data);
    final attenduCycle = _attenduCycleComplet(data);
    final alertes = _calculerAlertes(data);
    final benefInfo = _prochainBeneficiaire(data);
    final estGest = provider.estDebloque;

    return Scaffold(
      backgroundColor: AppColors.fondPapier,
      body: SafeArea(
        child: Column(
          children: [
            // ── En-tête ──
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
              child: Row(
                children: [
                  const LogoTontineClair(),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.arrow_back, size: 16),
                    label: const Text('Retour'),
                    style: TextButton.styleFrom(
                      foregroundColor: AppColors.encre,
                      textStyle: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // ── Corps ──
            Expanded(
              child: RefreshIndicator(
                onRefresh: () => provider.chargerTontine(code),
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                  children: [
                    // Titre
                    Text(
                      'Tableau de bord',
                      style: GoogleFonts.bricolageGrotesque(
                        fontWeight: FontWeight.w800,
                        fontSize: 26,
                        color: AppColors.encre,
                      ),
                    ),
                    Text(
                      data.nom,
                      style: GoogleFonts.inter(
                        fontSize: 13.5,
                        color: AppColors.texteDoux,
                      ),
                    ),
                    const SizedBox(height: 16),

                    // ── Alertes (avant les indicateurs) ──────────────────
                    if (alertes.isNotEmpty) ...[
                      ...alertes.map((a) => _CarteAlerte(alerte: a)),
                      const SizedBox(height: 8),
                    ],

                    // ── Prochain bénéficiaire ─────────────────────────────
                    _CarteBeneficiaire(info: benefInfo),
                    const SizedBox(height: 16),

                    // ── Grille 8 indicateurs (2 colonnes) ────────────────
                    Text(
                      'Indicateurs',
                      style: GoogleFonts.inter(
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                        color: AppColors.encre,
                      ),
                    ),
                    const SizedBox(height: 10),
                    GridView.count(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      crossAxisCount: 2,
                      childAspectRatio: 1.5,
                      crossAxisSpacing: 10,
                      mainAxisSpacing: 10,
                      children: [
                        _CarteIndicateur(
                          titre: 'Total cotisé',
                          sousTitre: 'depuis le début',
                          valeur: Formatters.montantFCFA(totalCotise),
                          couleur: AppColors.succes,
                          icone: Icons.savings_outlined,
                        ),
                        _CarteIndicateur(
                          titre: 'Attendu',
                          sousTitre: 'cycle complet',
                          valeur: Formatters.montantFCFA(attenduCycle),
                          couleur: AppColors.encreDoux,
                          icone: Icons.account_balance_outlined,
                        ),
                        _CarteIndicateur(
                          titre: 'Membres à jour',
                          sousTitre: 'ce tour',
                          valeur: '$aJour / ${membres.length}',
                          couleur: AppColors.succes,
                          icone: Icons.check_circle_outline,
                        ),
                        _CarteIndicateur(
                          titre: 'En attente',
                          sousTitre: 'non payés',
                          valeur: '$enAttente',
                          couleur: enAttente > 0 ? AppColors.alerte : AppColors.succes,
                          icone: enAttente > 0 ? Icons.warning_amber_outlined : Icons.check_circle_outline,
                        ),
                        _CarteIndicateur(
                          titre: 'Caisse',
                          sousTitre: 'disponible',
                          valeur: Formatters.montantFCFA(caisse),
                          couleur: caisse >= 0 ? AppColors.succes : AppColors.alerte,
                          icone: Icons.account_balance_wallet_outlined,
                        ),
                        _CarteIndicateur(
                          titre: 'Pénalités',
                          sousTitre: 'collectées',
                          valeur: Formatters.montantFCFA(penalites),
                          couleur: AppColors.or,
                          icone: Icons.gavel_outlined,
                        ),
                        _CarteIndicateur(
                          titre: 'Prêts en cours',
                          sousTitre: pretsInfo.nombre > 0
                              ? '${Formatters.montantFCFA(pretsInfo.totalDu)} restant dû'
                              : 'aucun prêt actif',
                          valeur: '${pretsInfo.nombre}',
                          couleur: pretsInfo.nombre > 0 ? AppColors.or : AppColors.succes,
                          icone: Icons.handshake_outlined,
                        ),
                        _CarteIndicateur(
                          titre: 'Votes ouverts',
                          sousTitre: 'en cours',
                          valeur: '$votesOuverts',
                          couleur: votesOuverts > 0 ? AppColors.encreDoux : AppColors.texteDoux,
                          icone: Icons.how_to_vote_outlined,
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),

                    // ── Bouton export PDF ─────────────────────────────────
                    if (estGest) ...[
                      _BoutonExportPdf(tontine: tontine, provider: provider),
                      const SizedBox(height: 10),
                    ],

                    // ── Bouton partager récap WhatsApp ────────────────────
                    _BoutonPartagerRecap(tontine: tontine),
                    const SizedBox(height: 10),

                    // ── Bouton inviter un membre ──────────────────────────
                    _BoutonInviter(tontine: tontine),
                    const SizedBox(height: 16),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Carte Alerte ─────────────────────────────────────────────────────────────
class _Alerte {
  final String emoji;
  final String message;
  final Color couleur;
  final Color fond;

  const _Alerte({
    required this.emoji,
    required this.message,
    required this.couleur,
    required this.fond,
  });
}

class _CarteAlerte extends StatelessWidget {
  final _Alerte alerte;

  const _CarteAlerte({required this.alerte});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: alerte.fond,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: alerte.couleur.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(alerte.emoji, style: const TextStyle(fontSize: 15)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              alerte.message,
              style: GoogleFonts.inter(
                fontWeight: FontWeight.w600,
                fontSize: 13,
                color: alerte.couleur,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Carte Prochain bénéficiaire ──────────────────────────────────────────────
class _CarteBeneficiaire extends StatelessWidget {
  final ({String? nom, int montant, bool cycleTermine}) info;

  const _CarteBeneficiaire({required this.info});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.encre,
        borderRadius: BorderRadius.circular(16),
      ),
      child: info.cycleTermine
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '🎉 Cycle terminé !',
                  style: GoogleFonts.bricolageGrotesque(
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                    color: AppColors.or,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Chaque membre a été servi. Relancez un nouveau cycle depuis la gestion.',
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    color: Colors.white.withValues(alpha: 0.8),
                  ),
                ),
              ],
            )
          : Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: AppColors.or.withValues(alpha: 0.2),
                    shape: BoxShape.circle,
                  ),
                  child: const Center(
                    child: Text('🏆', style: TextStyle(fontSize: 22)),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Prochain bénéficiaire',
                        style: GoogleFonts.inter(
                          fontSize: 12,
                          color: Colors.white.withValues(alpha: 0.65),
                        ),
                      ),
                      Text(
                        info.nom ?? '—',
                        style: GoogleFonts.bricolageGrotesque(
                          fontWeight: FontWeight.w700,
                          fontSize: 18,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      'Recevra',
                      style: GoogleFonts.inter(
                        fontSize: 11,
                        color: Colors.white.withValues(alpha: 0.65),
                      ),
                    ),
                    Text(
                      Formatters.montantFCFA(info.montant),
                      style: GoogleFonts.bricolageGrotesque(
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                        color: AppColors.or,
                      ),
                    ),
                  ],
                ),
              ],
            ),
    );
  }
}

// ─── Carte indicateur ─────────────────────────────────────────────────────────
class _CarteIndicateur extends StatelessWidget {
  final String titre;
  final String sousTitre;
  final String valeur;
  final Color couleur;
  final IconData icone;

  const _CarteIndicateur({
    required this.titre,
    required this.sousTitre,
    required this.valeur,
    required this.couleur,
    required this.icone,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.carte,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.lignes),
        boxShadow: [
          BoxShadow(
            color: AppColors.encre.withValues(alpha: 0.04),
            blurRadius: 3,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Icon(icone, size: 16, color: couleur),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  titre,
                  style: GoogleFonts.inter(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: AppColors.texteDoux,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            valeur,
            style: GoogleFonts.bricolageGrotesque(
              fontWeight: FontWeight.w800,
              fontSize: 17,
              color: couleur,
            ),
            overflow: TextOverflow.ellipsis,
          ),
          Text(
            sousTitre,
            style: GoogleFonts.inter(
              fontSize: 10.5,
              color: AppColors.texteDoux,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

// ─── Bouton Export PDF ────────────────────────────────────────────────────────
class _BoutonExportPdf extends StatefulWidget {
  final Tontine tontine;
  final TontineProvider provider;

  const _BoutonExportPdf({required this.tontine, required this.provider});

  @override
  State<_BoutonExportPdf> createState() => _BoutonExportPdfState();
}

class _BoutonExportPdfState extends State<_BoutonExportPdf> {
  bool _loading = false;

  @override
  Widget build(BuildContext context) {
    return BtnPrincipal(
      label: '📄 Exporter le relevé complet (PDF)',
      icon: Icons.picture_as_pdf_outlined,
      loading: _loading,
      onTap: () async {
        setState(() => _loading = true);
        try {
          await PdfService.exporterReleve(
            tontine: widget.tontine,
            nomGestionnaire: widget.provider.gestActifNom ?? '',
          );
        } catch (e) {
          if (context.mounted) {
            afficherToast(context, 'Erreur export PDF : $e', estErreur: true);
          }
        } finally {
          if (mounted) setState(() => _loading = false);
        }
      },
    );
  }
}

// ─── Bouton Partager récap WhatsApp ──────────────────────────────────────────
class _BoutonPartagerRecap extends StatelessWidget {
  final Tontine tontine;

  const _BoutonPartagerRecap({required this.tontine});

  String _construireMessage() {
    final data = tontine.data;
    final membres = data.membres;
    final n = data.ordre.isNotEmpty ? data.ordre.length : membres.length;

    if (data.cycleTermine) {
      // Cas 2 : cycle terminé
      final buf = StringBuffer();
      buf.writeln('✅ Cycle terminé ! Chaque membre a été servi.\n');
      buf.writeln('🏦 TONTINE — ${data.nom}');
      for (final h in data.historique) {
        final tour = (h['tour'] as num?)?.toInt() ?? '?';
        final benef = h['beneficiaire'] as String? ?? h['membre'] as String? ?? '?';
        final montant = (h['totalRecu'] as num?)?.toInt()
            ?? (h['total'] as num?)?.toInt()
            ?? n * data.montant;
        final dateRaw = h['date'];
        DateTime? dateD;
        if (dateRaw is int) dateD = DateTime.fromMillisecondsSinceEpoch(dateRaw);
        else if (dateRaw is String) dateD = DateTime.tryParse(dateRaw);
        buf.writeln('• Tour $tour → $benef — ${Formatters.montantFCFA(montant)}'
            '${dateD != null ? ' (${Formatters.dateFormatee(dateD)})' : ''}');
      }
      return buf.toString().trim();
    }

    // Cas 1 : cycle en cours
    // beneficiaire = membres[ ordre[tourActuel] ] (tourActuel = 0-based index)
    final beneficiaire = data.beneficiaire;
    final montantTotal = membres.where((m) => m.paye).length * data.montant;
    final totalAttendu = n * data.montant;
    final payes = membres.where((m) => m.paye).toList();
    final nonPayes = membres.where((m) => !m.paye).toList();

    final buf = StringBuffer();
    buf.writeln('🏦 TONTINE — ${data.nom}');
    buf.writeln('Tour ${data.numerTour}/$n · ${Formatters.montantFCFA(data.montant)} par membre');
    if (data.echeance != null) {
      final echD = DateTime.tryParse(data.echeance!);
      if (echD != null) buf.writeln('📅 Échéance : ${Formatters.dateFormatee(echD)}');
    }
    if (beneficiaire != null) {
      buf.writeln('🏆 Bénéficiaire du tour : ${beneficiaire.nom} — reçoit ${Formatters.montantFCFA(totalAttendu)}');
    }
    buf.writeln('');
    buf.writeln('✅ Ont cotisé (${payes.length}/$n)');
    for (final m in payes) {
      buf.writeln('  ✓ ${m.nom}');
    }
    if (nonPayes.isNotEmpty) {
      buf.writeln('');
      buf.writeln('⏳ En attente (${nonPayes.length}/$n)');
      for (final m in nonPayes) {
        buf.writeln('  · ${m.nom}');
      }
    }
    buf.writeln('');
    buf.writeln('💰 Cagnotte : ${Formatters.montantFCFA(montantTotal)} / ${Formatters.montantFCFA(totalAttendu)}');
    buf.writeln('');
    buf.writeln('Suivi en direct sur TontineClair — code ${tontine.code}');

    return buf.toString().trim();
  }

  @override
  Widget build(BuildContext context) {
    return BtnWhatsApp(
      label: 'Partager le récap sur WhatsApp',
      onTap: () async {
        final msg = Uri.encodeComponent(_construireMessage());
        final url = Uri.parse('https://wa.me/?text=$msg');
        if (await canLaunchUrl(url)) {
          await launchUrl(url, mode: LaunchMode.externalApplication);
        } else {
          if (context.mounted) {
            afficherToast(context, 'Impossible d\'ouvrir WhatsApp.', estErreur: true);
          }
        }
      },
    );
  }
}

// ─── Bouton Inviter un membre ─────────────────────────────────────────────────
class _BoutonInviter extends StatelessWidget {
  final Tontine tontine;

  const _BoutonInviter({required this.tontine});

  String _construireMessageInvitation() {
    final data = tontine.data;
    return '🤝 ${data.nom} est maintenant sur TontineClair !\n'
        'Pour suivre les cotisations en direct :\n'
        '1. Ouvre l\'application TontineClair\n'
        '2. Touche « Rejoindre une tontine »\n'
        '3. Entre le code : ${tontine.code}\n\n'
        'Tu verras qui a cotisé, qui reçoit, et tout l\'historique. En toute transparence 🔒';
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: OutlinedButton.icon(
        onPressed: () async {
          final msg = Uri.encodeComponent(_construireMessageInvitation());
          final url = Uri.parse('https://wa.me/?text=$msg');
          if (await canLaunchUrl(url)) {
            await launchUrl(url, mode: LaunchMode.externalApplication);
          } else {
            if (context.mounted) {
              afficherToast(context, 'Impossible d\'ouvrir WhatsApp.', estErreur: true);
            }
          }
        },
        icon: const Icon(Icons.person_add_outlined, size: 18),
        label: Text(
          '✉️ Inviter un membre (code ${tontine.code})',
          style: GoogleFonts.inter(
            fontWeight: FontWeight.w600,
            fontSize: 14,
          ),
        ),
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.encre,
          side: const BorderSide(color: AppColors.encreDoux),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
    );
  }
}
