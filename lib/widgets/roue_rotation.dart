import 'dart:math';
import 'package:flutter/material.dart';
import '../models/tontine.dart';
import '../utils/app_colors.dart';
import '../utils/formatters.dart';

class RoueRotation extends StatelessWidget {
  final TontineData data;

  const RoueRotation({super.key, required this.data});

  @override
  Widget build(BuildContext context) {
    final membres = data.membres;
    // tourActuel = index 0-based dans ordre[]
    // numerTour = tourActuel + 1 (affichage humain)
    final montant = data.montant * (data.ordre.isNotEmpty ? data.ordre.length : membres.length);
    final beneficiaire = data.beneficiaire; // null si cycle terminé
    final cycleTermine = data.cycleTermine;

    return Container(
      decoration: BoxDecoration(
        color: AppColors.encre,
        borderRadius: BorderRadius.circular(22),
      ),
      padding: const EdgeInsets.fromLTRB(18, 26, 18, 22),
      child: Column(
        children: [
          const Text(
            'ORDRE DE PASSAGE',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 11.5,
              letterSpacing: 0.14,
              color: AppColors.or,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            cycleTermine
                ? 'Cycle terminé ✔'
                : 'Tour ${data.numerTour} sur ${data.ordre.length}',
            style: const TextStyle(
              fontSize: 13,
              color: Colors.white70,
            ),
          ),
          const SizedBox(height: 10),
          // Roue Canvas — le montant total est affiché au centre géométrique
          SizedBox(
            width: 250,
            height: 250,
            child: _RoueCanvas(
              membres: membres,
              ordre: data.ordre,
              tourActuel: data.tourActuel,
              cycleTermine: cycleTermine,
              montantTotal: montant,
              devise: data.devise,
            ),
          ),
          const SizedBox(height: 12),
          // Sous la roue : nom du bénéficiaire uniquement
          if (!cycleTermine && beneficiaire != null) ...[
            Text(
              '${beneficiaire.nom} — bénéficiaire du tour',
              style: const TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 15,
                color: Colors.white,
              ),
              textAlign: TextAlign.center,
            ),
          ],
          if (cycleTermine) ...[
            const Text(
              'Tous les membres ont été servis !',
              style: TextStyle(
                fontSize: 15,
                color: Colors.white70,
              ),
              textAlign: TextAlign.center,
            ),
          ],
          // Statistiques cotisations
          const SizedBox(height: 16),
          _StatsCotisations(data: data),
        ],
      ),
    );
  }
}

class _RoueCanvas extends StatelessWidget {
  final List<Membre> membres;
  final List<String> ordre;
  final int tourActuel; // index 0-based
  final bool cycleTermine;
  final int montantTotal;
  final String devise;

  const _RoueCanvas({
    required this.membres,
    required this.ordre,
    required this.tourActuel,
    required this.cycleTermine,
    required this.montantTotal,
    required this.devise,
  });

  @override
  Widget build(BuildContext context) {
    if (membres.isEmpty) return const SizedBox.shrink();

    return CustomPaint(
      painter: _RouePainter(
        membres: membres,
        ordre: ordre,
        tourActuel: tourActuel,
        cycleTermine: cycleTermine,
        montantTotal: montantTotal,
        devise: devise,
      ),
      child: Container(),
    );
  }
}

class _RouePainter extends CustomPainter {
  final List<Membre> membres;
  final List<String> ordre;     // IDs dans l'ordre de passage
  final int tourActuel;          // index 0-based dans ordre[]
  final bool cycleTermine;
  final int montantTotal;        // montant × nb membres — affiché au centre
  final String devise;           // code devise ISO pour le formatage

  _RouePainter({
    required this.membres,
    required this.ordre,
    required this.tourActuel,
    required this.cycleTermine,
    required this.montantTotal,
    required this.devise,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 28;
    final n = ordre.isNotEmpty ? ordre.length : membres.length;
    if (n == 0) return;

    // Construire la map id -> Membre pour résoudre les noms
    final membreParId = {for (final m in membres) m.id: m};

    // Cercle pointillé
    final paintCercle = Paint()
      ..color = Colors.white.withValues(alpha: 0.25)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;

    const dashLength = 6.0;
    const dashSpace = 4.0;
    final circumference = 2 * pi * radius;
    final totalDashes = (circumference / (dashLength + dashSpace)).floor();
    for (int i = 0; i < totalDashes; i++) {
      final startAngle = (i * (dashLength + dashSpace)) / radius;
      final sweepAngle = dashLength / radius;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        startAngle,
        sweepAngle,
        false,
        paintCercle,
      );
    }

    // Points dans l'ordre de passage (ordre[])
    for (int i = 0; i < n; i++) {
      final id = ordre.length > i ? ordre[i] : '';
      final membre = membreParId[id];

      final angle = (2 * pi * i / n) - pi / 2;
      final x = center.dx + radius * cos(angle);
      final y = center.dy + radius * sin(angle);
      final pos = Offset(x, y);

      // Aligné sur index.html :
      //   'courant' si i == tourActuel
      //   'servi'   si i < tourActuel OU cycleTermine
      //   ''        sinon
      final isCourant = !cycleTermine && i == tourActuel;
      final isServi = cycleTermine || i < tourActuel;

      final paintFond = Paint()
        ..color = isCourant
            ? AppColors.or
            : isServi
                ? Colors.white.withValues(alpha: 0.12)
                : AppColors.encreDoux
        ..style = PaintingStyle.fill;

      final paintBord = Paint()
        ..color = isCourant
            ? Colors.white
            : isServi
                ? Colors.white.withValues(alpha: 0.15)
                : Colors.white.withValues(alpha: 0.3)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2;

      final r = isCourant ? 27.0 : 22.0;
      canvas.drawCircle(pos, r, paintFond);
      canvas.drawCircle(pos, r, paintBord);

      // Initiales ou numéro
      final label = membre != null
          ? _initiales(membre.nom)
          : '${i + 1}';
      final textPainter = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(
            color: isCourant
                ? const Color(0xFF2A1E05)
                : isServi
                    ? Colors.white.withValues(alpha: 0.45)
                    : Colors.white,
            fontWeight: FontWeight.w700,
            fontSize: isCourant ? 15 : 13,
          ),
        ),
        textDirection: TextDirection.ltr,
      );
      textPainter.layout();
      textPainter.paint(
        canvas,
        Offset(pos.dx - textPainter.width / 2, pos.dy - textPainter.height / 2),
      );
    }

    // ── Centre de la roue : montant total (spec §4 — jamais tronqué) ─────────
    if (!cycleTermine && montantTotal > 0) {
      // Formater le montant avec la devise de la tontine
      final montantStr = Formatters.montant(montantTotal, devise: devise);
      // Deux lignes : libellé + montant
      final labelPainter = TextPainter(
        text: const TextSpan(
          text: 'Cagnotte',
          style: TextStyle(
            color: Color(0xFFD99A2B), // AppColors.or
            fontWeight: FontWeight.w600,
            fontSize: 10,
          ),
        ),
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.center,
      )..layout(maxWidth: radius * 1.2);

      final montantPainter = TextPainter(
        text: TextSpan(
          text: montantStr,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w800,
            fontSize: 13,
          ),
        ),
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.center,
      )..layout(maxWidth: radius * 1.2);

      final totalH = labelPainter.height + 2 + montantPainter.height;
      final startY = center.dy - totalH / 2;

      labelPainter.paint(
        canvas,
        Offset(center.dx - labelPainter.width / 2, startY),
      );
      montantPainter.paint(
        canvas,
        Offset(center.dx - montantPainter.width / 2, startY + labelPainter.height + 2),
      );
    } else if (cycleTermine) {
      // Cycle terminé : afficher ✔ au centre
      final checkPainter = TextPainter(
        text: const TextSpan(
          text: '✔',
          style: TextStyle(
            color: Color(0xFFD99A2B),
            fontSize: 28,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      checkPainter.paint(
        canvas,
        Offset(center.dx - checkPainter.width / 2, center.dy - checkPainter.height / 2),
      );
    }
  }

  // _formatMontant supprimé — remplacé par Formatters.montant() pour respect de la devise

  String _initiales(String nom) {
    final parts = nom.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts[0].substring(0, parts[0].length.clamp(0, 2)).toUpperCase();
    return (parts[0][0] + parts[1][0]).toUpperCase();
  }

  @override
  bool shouldRepaint(covariant _RouePainter oldDelegate) =>
      oldDelegate.tourActuel != tourActuel ||
      oldDelegate.cycleTermine != cycleTermine ||
      oldDelegate.ordre.length != ordre.length ||
      oldDelegate.montantTotal != montantTotal ||
      oldDelegate.devise != devise;
}

class _StatsCotisations extends StatelessWidget {
  final TontineData data;

  const _StatsCotisations({required this.data});

  @override
  Widget build(BuildContext context) {
    final membres = data.membres;
    final payes = membres.where((m) => m.paye).length;
    final total = membres.length;
    final nonPayes = total - payes;

    return Row(
      children: [
        Expanded(
          child: _StatPuce(
            label: 'Payé',
            valeur: payes.toString(),
            couleur: AppColors.succes,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _StatPuce(
            label: 'Restant',
            valeur: nonPayes.toString(),
            couleur: nonPayes > 0 ? AppColors.alerte : AppColors.succes,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _StatPuce(
            label: 'Collecté',
            valeur:
                '${(payes * data.montant / 1000).toStringAsFixed(payes * data.montant % 1000 == 0 ? 0 : 1)}k',
            couleur: AppColors.or,
          ),
        ),
      ],
    );
  }
}

class _StatPuce extends StatelessWidget {
  final String label;
  final String valeur;
  final Color couleur;

  const _StatPuce({
    required this.label,
    required this.valeur,
    required this.couleur,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        children: [
          Text(
            valeur,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 20,
              color: couleur,
            ),
          ),
          Text(
            label,
            style: const TextStyle(
              fontSize: 11,
              color: Colors.white70,
            ),
          ),
        ],
      ),
    );
  }
}
