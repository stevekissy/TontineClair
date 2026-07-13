// ─────────────────────────────────────────────────────────────────────────────
// ClassementScreen — Classement intelligent des membres par Score de Confiance
// TontineClair — Réservé aux gestionnaires
// ─────────────────────────────────────────────────────────────────────────────

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/score_modeles.dart';
import '../services/score_service.dart';
import '../services/supabase_service.dart';
import '../services/tontine_provider.dart';
import '../utils/app_colors.dart';
import 'score_membre_screen.dart';
import '../utils/app_localizations.dart';

Color _couleurScore(int score) {
  if (score >= 80) return const Color(0xFF2E7D5B);
  if (score >= 65) return const Color(0xFF35407A);
  if (score >= 50) return const Color(0xFFD99A2B);
  if (score >= 35) return const Color(0xFFE07A2F);
  return const Color(0xFFC4453C);
}

class ClassementScreen extends StatefulWidget {
  final String code;
  final bool estGestionnaire;

  const ClassementScreen({
    super.key,
    required this.code,
    required this.estGestionnaire,
  });

  @override
  State<ClassementScreen> createState() => _ClassementScreenState();
}

class _ClassementScreenState extends State<ClassementScreen> {
  bool _chargement = true;
  List<EntreeClassement> _classement = [];
  Map<String, List<Map<String, dynamic>>> _voixParMembre = {};
  String _filtre = 'tous'; // 'tous', 'alerte', 'fiable'
  String _tri = 'score';   // 'score', 'nom'

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _charger());
  }

  Future<void> _charger() async {
    setState(() => _chargement = true);
    try {
      final voixBrutes = await SupabaseService.lireVoix(widget.code);
      final voixMap = <String, List<Map<String, dynamic>>>{};
      for (final v in voixBrutes) {
        final mid = v['membre_id'] as String? ?? '';
        voixMap.putIfAbsent(mid, () => []).add(v);
      }

      if (!mounted) return;
      final data = context.read<TontineProvider>().courante!.data;
      final classement = ScoreService.classerMembres(data, voixMap);

      setState(() {
        _voixParMembre = voixMap;
        _classement = classement;
        _chargement = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _chargement = false);
    }
  }

  List<EntreeClassement> get _classementFiltre {
    var liste = List<EntreeClassement>.from(_classement);

    // Filtrer
    if (_filtre == 'alerte') {
      liste = liste
          .where((e) =>
              e.scoreDetail.niveau == NiveauScore.risque ||
              e.scoreDetail.niveau == NiveauScore.tresRisque ||
              e.scoreDetail.niveau == NiveauScore.aSurveiller)
          .toList();
    } else if (_filtre == 'fiable') {
      liste = liste
          .where((e) =>
              e.scoreDetail.niveau == NiveauScore.fiable ||
              e.scoreDetail.niveau == NiveauScore.tresFiable)
          .toList();
    }

    // Trier
    if (_tri == 'nom') {
      liste.sort((a, b) => a.membre.nom.compareTo(b.membre.nom));
    }
    // 'score' est déjà trié par défaut

    return liste;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.fondPapier,
      appBar: AppBar(
        backgroundColor: AppColors.fondPapier,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded,
              size: 18, color: AppColors.encre),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Classement des membres',
              style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: AppColors.encre),
            ),
            Text(
              'Scores de confiance · IA',
              style: TextStyle(fontSize: 11, color: AppColors.texteDoux),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded,
                size: 20, color: AppColors.encreDoux),
            onPressed: _charger,
            tooltip: 'Recalculer',
          ),
        ],
      ),
      body: _chargement
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                _BarreFiltres(),
                Expanded(
                  child: _classementFiltre.isEmpty
                      ? _VueVide(filtre: _filtre)
                      : _ListeClassement(
                          classement: _classementFiltre,
                          code: widget.code,
                          estGestionnaire: widget.estGestionnaire,
                          voixParMembre: _voixParMembre,
                        ),
                ),
              ],
            ),
    );
  }

  Widget _BarreFiltres() {
    return Container(
      color: AppColors.fondPapier,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Column(
        children: [
          // Résumé global
          if (_classement.isNotEmpty) ...[
            _ResumGlobal(classement: _classement),
            const SizedBox(height: 10),
          ],
          // Filtres
          Row(
            children: [
              _ChipFiltre(
                label: 'Tous (${_classement.length})',
                actif: _filtre == 'tous',
                onTap: () => setState(() => _filtre = 'tous'),
              ),
              const SizedBox(width: 6),
              _ChipFiltre(
                label:
                    '🟠 À risque (${_classement.where((e) => e.scoreDetail.score < 50).length})',
                actif: _filtre == 'alerte',
                onTap: () => setState(() => _filtre = 'alerte'),
                couleurActif: const Color(0xFFC4453C),
              ),
              const SizedBox(width: 6),
              _ChipFiltre(
                label:
                    '🟢 Fiables (${_classement.where((e) => e.scoreDetail.score >= 65).length})',
                actif: _filtre == 'fiable',
                onTap: () => setState(() => _filtre = 'fiable'),
                couleurActif: const Color(0xFF2E7D5B),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // Tri
          Row(
            children: [
              Text(
                'Trier par :',
                style: TextStyle(
                    fontSize: 11, color: AppColors.texteDoux),
              ),
              const SizedBox(width: 8),
              _ChipFiltre(
                label: context.tr('score'),
                actif: _tri == 'score',
                onTap: () => setState(() => _tri = 'score'),
              ),
              const SizedBox(width: 6),
              _ChipFiltre(
                label: context.tr('nom'),
                actif: _tri == 'nom',
                onTap: () => setState(() => _tri = 'nom'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ─── Résumé global ────────────────────────────────────────────────────────────
class _ResumGlobal extends StatelessWidget {
  final List<EntreeClassement> classement;

  const _ResumGlobal({required this.classement});

  @override
  Widget build(BuildContext context) {
    if (classement.isEmpty) return const SizedBox.shrink();

    final total = classement.length;
    final tresFiables =
        classement.where((e) => e.scoreDetail.score >= 80).length;
    final fiables = classement
        .where((e) =>
            e.scoreDetail.score >= 65 && e.scoreDetail.score < 80)
        .length;
    final surveiller = classement
        .where((e) =>
            e.scoreDetail.score >= 50 && e.scoreDetail.score < 65)
        .length;
    final risque = classement
        .where((e) => e.scoreDetail.score < 50)
        .length;

    final scoreMoyen = total > 0
        ? classement
                .map((e) => e.scoreDetail.score)
                .reduce((a, b) => a + b) ~/
            total
        : 0;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.fondCode,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.lignes),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Vue d\'ensemble',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: AppColors.encre),
              ),
              Text(
                'Score moyen : $scoreMoyen/100',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: _couleurScore(scoreMoyen),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // Barre de répartition
          Row(
            children: [
              _SegmentBarre(count: tresFiables, total: total, couleur: const Color(0xFF2E7D5B)),
              _SegmentBarre(count: fiables, total: total, couleur: const Color(0xFF35407A)),
              _SegmentBarre(count: surveiller, total: total, couleur: const Color(0xFFD99A2B)),
              _SegmentBarre(count: risque, total: total, couleur: const Color(0xFFC4453C)),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _LegendeBarre('🟢 $tresFiables Très fiable', const Color(0xFF2E7D5B)),
              _LegendeBarre('🔵 $fiables Fiable', const Color(0xFF35407A)),
              _LegendeBarre('🟡 $surveiller À surv.', const Color(0xFFD99A2B)),
              _LegendeBarre('🔴 $risque Risqué', const Color(0xFFC4453C)),
            ],
          ),
        ],
      ),
    );
  }
}

class _SegmentBarre extends StatelessWidget {
  final int count;
  final int total;
  final Color couleur;

  const _SegmentBarre(
      {required this.count, required this.total, required this.couleur});

  @override
  Widget build(BuildContext context) {
    if (total == 0 || count == 0) return const SizedBox.shrink();
    return Expanded(
      flex: count,
      child: Container(
        height: 6,
        color: couleur,
      ),
    );
  }
}

class _LegendeBarre extends StatelessWidget {
  final String label;
  final Color couleur;

  const _LegendeBarre(this.label, this.couleur);

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: TextStyle(fontSize: 9, color: couleur),
    );
  }
}

// ─── Chip filtre ──────────────────────────────────────────────────────────────
class _ChipFiltre extends StatelessWidget {
  final String label;
  final bool actif;
  final VoidCallback onTap;
  final Color? couleurActif;

  const _ChipFiltre({
    required this.label,
    required this.actif,
    required this.onTap,
    this.couleurActif,
  });

  @override
  Widget build(BuildContext context) {
    final c = couleurActif ?? AppColors.encreDoux;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: actif ? c.withValues(alpha: 0.12) : AppColors.fondCode,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: actif ? c : AppColors.lignes,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: actif ? FontWeight.w700 : FontWeight.w400,
            color: actif ? c : AppColors.texteDoux,
          ),
        ),
      ),
    );
  }
}

// ─── Liste du classement ──────────────────────────────────────────────────────
class _ListeClassement extends StatelessWidget {
  final List<EntreeClassement> classement;
  final String code;
  final bool estGestionnaire;
  final Map<String, List<Map<String, dynamic>>> voixParMembre;

  const _ListeClassement({
    required this.classement,
    required this.code,
    required this.estGestionnaire,
    required this.voixParMembre,
  });

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      itemCount: classement.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (ctx, i) => _CarteClassement(
        entree: classement[i],
        code: code,
        estGestionnaire: estGestionnaire,
      ),
    );
  }
}

// ─── Carte d'une entrée du classement ────────────────────────────────────────
class _CarteClassement extends StatelessWidget {
  final EntreeClassement entree;
  final String code;
  final bool estGestionnaire;

  const _CarteClassement({
    required this.entree,
    required this.code,
    required this.estGestionnaire,
  });

  @override
  Widget build(BuildContext context) {
    final score = entree.scoreDetail.score;
    final couleur = _couleurScore(score);
    final membre = entree.membre;
    final niveau = ScoreService.labelNiveau(entree.scoreDetail.niveau);
    final emoji = ScoreService.emojiNiveau(entree.scoreDetail.niveau);

    // Médaille pour les 3 premiers
    final medalles = ['🥇', '🥈', '🥉'];
    final medaille = entree.rang <= 3 ? medalles[entree.rang - 1] : null;

    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ScoreMembreScreen(
            code: code,
            membre: membre,
            estGestionnaire: estGestionnaire,
          ),
        ),
      ),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: couleur.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: score < 35
                ? couleur.withValues(alpha: 0.5)
                : AppColors.lignes,
          ),
        ),
        child: Row(
          children: [
            // Rang
            SizedBox(
              width: 28,
              child: Text(
                medaille ?? '#${entree.rang}',
                style: TextStyle(
                  fontSize: medaille != null ? 18 : 12,
                  fontWeight: FontWeight.w700,
                  color: medaille != null
                      ? null
                      : AppColors.texteDoux,
                ),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(width: 10),

            // Cercle score
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: couleur.withValues(alpha: 0.12),
                border: Border.all(color: couleur, width: 2),
              ),
              child: Center(
                child: Text(
                  '$score',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w900,
                    color: couleur,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),

            // Infos membre
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    membre.nom,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: AppColors.encre,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Text(
                        '$emoji $niveau',
                        style: TextStyle(
                          fontSize: 11,
                          color: couleur,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (membre.role != null) ...[
                        const SizedBox(width: 6),
                        Text(
                          '· ${membre.role}',
                          style: const TextStyle(
                              fontSize: 10,
                              color: AppColors.texteDoux),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  // Barre mini
                  ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: score / 100,
                      backgroundColor: AppColors.fondCode,
                      valueColor:
                          AlwaysStoppedAnimation<Color>(couleur),
                      minHeight: 3,
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(width: 8),
            // Flèche
            Icon(Icons.chevron_right_rounded,
                size: 18, color: AppColors.texteDoux),
          ],
        ),
      ),
    );
  }
}

// ─── Vue vide ─────────────────────────────────────────────────────────────────
class _VueVide extends StatelessWidget {
  final String filtre;

  const _VueVide({required this.filtre});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            filtre == 'alerte'
                ? Icons.check_circle_outline_rounded
                : Icons.people_outline_rounded,
            size: 48,
            color: AppColors.texteDoux,
          ),
          const SizedBox(height: 12),
          Text(
            filtre == 'alerte'
                ? 'Aucun membre à risque 🎉'
                : filtre == 'fiable'
                    ? 'Aucun membre fiable trouvé'
                    : 'Aucun membre',
            style: const TextStyle(
                color: AppColors.texteDoux, fontSize: 14),
          ),
        ],
      ),
    );
  }
}
