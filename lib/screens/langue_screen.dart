// ─────────────────────────────────────────────────────────────────────────────
// LangueScreen — Sélection de la langue de l'application
//
// Tap sur une langue → changement immédiat des textes de l'UI.
// Les données (tontines, montants, devises) ne sont jamais affectées.
// ─────────────────────────────────────────────────────────────────────────────

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/locale_service.dart';
import '../utils/app_colors.dart';
import '../utils/app_localizations.dart';

class LangueScreen extends StatelessWidget {
  const LangueScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final ls = context.watch<LocaleService>();

    return Scaffold(
      backgroundColor: AppColors.fondPapier,
      appBar: AppBar(
        backgroundColor: AppColors.fondPapier,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded,
              color: AppColors.encre, size: 20),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          context.tr('choisir_langue'),
          style: const TextStyle(
            fontWeight: FontWeight.w800,
            fontSize: 18,
            color: AppColors.encre,
          ),
        ),
      ),
      body: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 12),
        itemCount: LocaleService.langues.length,
        separatorBuilder: (_, __) => const Divider(
          height: 1,
          indent: 72,
          endIndent: 20,
          color: AppColors.lignes,
        ),
        itemBuilder: (_, i) {
          final langue = LocaleService.langues[i];
          final estActive = ls.langue.code == langue.code;

          return _LigneLangue(
            langue: langue,
            estActive: estActive,
            onTap: () async {
              // Changement immédiat — notifyListeners() rebuilde context.tr()
              await context.read<LocaleService>().changerLangue(langue);
              if (context.mounted) Navigator.of(context).pop();
            },
          );
        },
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _LigneLangue
// ─────────────────────────────────────────────────────────────────────────────

class _LigneLangue extends StatelessWidget {
  final AppLangue langue;
  final bool estActive;
  final VoidCallback onTap;

  const _LigneLangue({
    required this.langue,
    required this.estActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      splashColor: AppColors.encre.withValues(alpha: 0.05),
      highlightColor: AppColors.encre.withValues(alpha: 0.03),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(
          children: [
            // ── Drapeau ──────────────────────────────────────────────────
            SizedBox(
              width: 36,
              child: Text(
                langue.drapeau,
                style: const TextStyle(fontSize: 26),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(width: 16),

            // ── Nom natif + nom en français ───────────────────────────────
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    langue.nom,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: estActive ? AppColors.encre : AppColors.texte,
                    ),
                  ),
                  if (langue.nomFr != langue.nom) ...[
                    const SizedBox(height: 2),
                    Text(
                      langue.nomFr,
                      style: const TextStyle(
                        fontSize: 12.5,
                        color: AppColors.texteDoux,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                  ],
                ],
              ),
            ),

            // ── Indicateur actif ──────────────────────────────────────────
            if (estActive)
              Container(
                width: 22,
                height: 22,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.encre,
                ),
                child: const Icon(
                  Icons.check_rounded,
                  color: Colors.white,
                  size: 14,
                ),
              )
            else
              Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: AppColors.lignes, width: 1.5),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
