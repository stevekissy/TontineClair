// ─────────────────────────────────────────────────────────────────────────────
// LangueScreen — Sélection de la langue de l'application
//
// Affiche les 8 langues disponibles avec :
//   • Drapeau emoji
//   • Nom dans la langue elle-même (écriture native)
//   • Nom en français
//   • Devises associées à la zone géographique
//   • Indicateur visuel de la langue active
// ─────────────────────────────────────────────────────────────────────────────

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/locale_service.dart';
import '../utils/app_colors.dart';
import '../utils/app_localizations.dart';

class LangueScreen extends StatefulWidget {
  const LangueScreen({super.key});

  @override
  State<LangueScreen> createState() => _LangueScreenState();
}

class _LangueScreenState extends State<LangueScreen> {
  // Langue temporairement sélectionnée (avant confirmation)
  late AppLangue _selection;

  @override
  void initState() {
    super.initState();
    _selection = context.read<LocaleService>().langue;
  }

  // ── Confirmer et appliquer ────────────────────────────────────────────────
  Future<void> _appliquer() async {
    final ls = context.read<LocaleService>();
    await ls.changerLangue(_selection);

    if (!mounted) return;
    // Message de confirmation traduit dans la nouvelle langue
    final msg = AppLocalizations(_selection.code).get('langue_modifiee');
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Text(_selection.drapeau, style: const TextStyle(fontSize: 20)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                msg,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
            ),
          ],
        ),
        backgroundColor: AppColors.encre,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        duration: const Duration(seconds: 2),
      ),
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final ls = context.watch<LocaleService>();
    final langueActive = ls.langue;
    final aucunChangement = _selection.code == langueActive.code;

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
        centerTitle: false,
        actions: [
          // Bouton Appliquer — visible uniquement si changement
          AnimatedOpacity(
            opacity: aucunChangement ? 0.0 : 1.0,
            duration: const Duration(milliseconds: 200),
            child: Padding(
              padding: const EdgeInsets.only(right: 12),
              child: TextButton(
                onPressed: aucunChangement ? null : _appliquer,
                style: TextButton.styleFrom(
                  backgroundColor: AppColors.encre,
                  foregroundColor: Colors.white,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20)),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(
                  context.tr('appliquer'),
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Sous-titre ─────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            child: Text(
              context.tr('langues_disponibles'),
              style: const TextStyle(
                fontSize: 13.5,
                color: AppColors.texteDoux,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),

          // ── Séparateur ─────────────────────────────────────────────────
          const Divider(height: 1, color: AppColors.lignes),

          // ── Liste des langues ──────────────────────────────────────────
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: LocaleService.langues.length,
              separatorBuilder: (_, __) => const Divider(
                height: 1,
                indent: 20,
                endIndent: 20,
                color: AppColors.lignes,
              ),
              itemBuilder: (_, i) {
                final langue = LocaleService.langues[i];
                final estSelectionnee = _selection.code == langue.code;
                final estActive = langueActive.code == langue.code;

                return _CarteLangue(
                  langue: langue,
                  estSelectionnee: estSelectionnee,
                  estActive: estActive,
                  onTap: () => setState(() => _selection = langue),
                );
              },
            ),
          ),

          // ── Pied de page informatif ────────────────────────────────────
          _PiedLangues(langueActive: langueActive),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _CarteLangue — Carte individuelle pour chaque langue
// ─────────────────────────────────────────────────────────────────────────────

class _CarteLangue extends StatelessWidget {
  final AppLangue langue;
  final bool estSelectionnee;
  final bool estActive;
  final VoidCallback onTap;

  const _CarteLangue({
    required this.langue,
    required this.estSelectionnee,
    required this.estActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      splashColor: AppColors.encre.withValues(alpha: 0.05),
      highlightColor: AppColors.encre.withValues(alpha: 0.03),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        color: estSelectionnee
            ? AppColors.encre.withValues(alpha: 0.04)
            : Colors.transparent,
        child: Row(
          children: [
            // ── Drapeau ─────────────────────────────────────────────────
            Text(
              langue.drapeau,
              style: const TextStyle(fontSize: 30),
            ),
            const SizedBox(width: 14),

            // ── Textes ──────────────────────────────────────────────────
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Ligne 1 : nom natif + badge "Actuel"
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          langue.nom,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: estSelectionnee
                                ? AppColors.encre
                                : AppColors.texte,
                          ),
                        ),
                      ),
                      if (estActive)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: AppColors.encre.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            context.tr('langue_actuelle'),
                            style: const TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              color: AppColors.encre,
                              letterSpacing: 0.3,
                            ),
                          ),
                        ),
                    ],
                  ),

                  const SizedBox(height: 2),

                  // Ligne 2 : nom en français
                  Text(
                    langue.nomFr,
                    style: const TextStyle(
                      fontSize: 13,
                      color: AppColors.texteDoux,
                      fontWeight: FontWeight.w500,
                    ),
                  ),

                  const SizedBox(height: 5),

                  // Ligne 3 : devises associées
                  Row(
                    children: [
                      const Icon(
                        Icons.monetization_on_outlined,
                        size: 12,
                        color: AppColors.texteDoux,
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          langue.devises,
                          style: const TextStyle(
                            fontSize: 11.5,
                            color: AppColors.texteDoux,
                            fontWeight: FontWeight.w500,
                            letterSpacing: 0.2,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            const SizedBox(width: 12),

            // ── Indicateur sélection ─────────────────────────────────────
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: estSelectionnee ? AppColors.encre : Colors.transparent,
                border: Border.all(
                  color: estSelectionnee
                      ? AppColors.encre
                      : AppColors.lignes,
                  width: estSelectionnee ? 0 : 1.5,
                ),
              ),
              child: estSelectionnee
                  ? const Icon(Icons.check_rounded,
                      color: Colors.white, size: 14)
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _PiedLangues — Pied de page avec langue active résumée
// ─────────────────────────────────────────────────────────────────────────────

class _PiedLangues extends StatelessWidget {
  final AppLangue langueActive;

  const _PiedLangues({required this.langueActive});

  @override
  Widget build(BuildContext context) {
    final bottomPadding = MediaQuery.of(context).padding.bottom;

    return Container(
      decoration: BoxDecoration(
        color: AppColors.fondPapier,
        border: Border(
          top: BorderSide(color: AppColors.lignes, width: 1),
        ),
      ),
      padding: EdgeInsets.fromLTRB(20, 14, 20, 14 + bottomPadding),
      child: Row(
        children: [
          Text(
            langueActive.drapeau,
            style: const TextStyle(fontSize: 18),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${context.tr('langue_actuelle')} : ${langueActive.nom}',
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: AppColors.encre,
                  ),
                ),
                Text(
                  langueActive.devises,
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppColors.texteDoux,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
