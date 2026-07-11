import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../utils/app_colors.dart';

// ============================================================
// BOUTONS
// ============================================================

class BtnPrincipal extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  final bool loading;
  final IconData? icon;
  final IconData? icone; // alias pour icon
  final Color? couleur;  // couleur de fond personnalisée

  const BtnPrincipal({
    super.key,
    required this.label,
    this.onTap,
    this.loading = false,
    this.icon,
    this.icone,
    this.couleur,
  });

  @override
  Widget build(BuildContext context) {
    final bgColor = couleur ?? AppColors.encre;
    final effectiveIcon = icon ?? icone;
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: ElevatedButton(
        onPressed: loading ? null : onTap,
        style: ElevatedButton.styleFrom(
          backgroundColor: bgColor,
          foregroundColor: Colors.white,
          disabledBackgroundColor: bgColor.withValues(alpha: 0.45),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
        child: loading
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (effectiveIcon != null) ...[
                    Icon(effectiveIcon, size: 18),
                    const SizedBox(width: 8),
                  ],
                  Text(
                    label,
                    style: GoogleFonts.inter(
                      fontWeight: FontWeight.w700,
                      fontSize: 15.5,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

class BtnKola extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  final bool loading;
  final IconData? icon;

  const BtnKola({
    super.key,
    required this.label,
    this.onTap,
    this.loading = false,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: ElevatedButton(
        onPressed: loading ? null : onTap,
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.or,
          foregroundColor: const Color(0xFF2A1E05),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
        child: loading
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF2A1E05)),
              )
            : Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (icon != null) ...[
                    Icon(icon, size: 18),
                    const SizedBox(width: 8),
                  ],
                  Text(
                    label,
                    style: GoogleFonts.inter(
                      fontWeight: FontWeight.w700,
                      fontSize: 15.5,
                      color: const Color(0xFF2A1E05),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

class BtnSecondaire extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;

  const BtnSecondaire({super.key, required this.label, this.onTap});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: ElevatedButton(
        onPressed: onTap,
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.fondSecondaire,
          foregroundColor: AppColors.encre,
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
        child: Text(
          label,
          style: GoogleFonts.inter(
            fontWeight: FontWeight.w700,
            fontSize: 15.5,
            color: AppColors.encre,
          ),
        ),
      ),
    );
  }
}

class BtnWhatsApp extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;

  const BtnWhatsApp({super.key, required this.label, this.onTap});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: ElevatedButton(
        onPressed: onTap,
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.whatsapp,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.chat, size: 19),
            const SizedBox(width: 9),
            Text(
              label,
              style: GoogleFonts.inter(
                fontWeight: FontWeight.w700,
                fontSize: 15.5,
                color: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// CARTES
// ============================================================

class CarteTC extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final VoidCallback? onTap;

  const CarteTC({super.key, required this.child, this.padding, this.onTap});

  @override
  Widget build(BuildContext context) {
    final carte = Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: AppColors.carte,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.lignes, width: 1),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF1C2447).withValues(alpha: 0.05),
            blurRadius: 3,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: Padding(
        padding: padding ?? const EdgeInsets.all(18),
        child: child,
      ),
    );

    if (onTap != null) {
      return GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          child: carte,
        ),
      );
    }
    return carte;
  }
}

// ============================================================
// LABELS / BADGES
// ============================================================

class CodePuce extends StatelessWidget {
  final String code;

  const CodePuce({super.key, required this.code});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.fondCode,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        code,
        style: GoogleFonts.bricolageGrotesque(
          fontWeight: FontWeight.w700,
          fontSize: 12.5,
          color: AppColors.encre,
          letterSpacing: 0.08,
        ),
      ),
    );
  }
}

class BadgePlan extends StatelessWidget {
  final bool isPremium;

  const BadgePlan({super.key, required this.isPremium});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: isPremium ? AppColors.or : AppColors.fondCode,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        isPremium ? '★ Premium' : 'Gratuit',
        style: GoogleFonts.inter(
          fontWeight: FontWeight.w700,
          fontSize: 12,
          color: isPremium ? const Color(0xFF2A1E05) : AppColors.encreDoux,
        ),
      ),
    );
  }
}

class BadgeStatut extends StatelessWidget {
  final String statut;

  const BadgeStatut({super.key, required this.statut});

  @override
  Widget build(BuildContext context) {
    Color bg, fg;
    String label;
    switch (statut) {
      case 'solde':
        bg = AppColors.succesFond;
        fg = AppColors.succes;
        label = 'Soldé';
        break;
      case 'retard':
        bg = AppColors.alerteFond;
        fg = AppColors.alerte;
        label = 'En retard';
        break;
      case 'partiel':
        bg = const Color(0xFFFDF3E2);
        fg = AppColors.orFonce;
        label = 'Partiel';
        break;
      default:
        bg = AppColors.fondCode;
        fg = AppColors.encreDoux;
        label = 'En cours';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: GoogleFonts.inter(
          fontWeight: FontWeight.w700,
          fontSize: 12,
          color: fg,
        ),
      ),
    );
  }
}

// ============================================================
// CHAMPS DE FORMULAIRE
// ============================================================

class ChampLabel extends StatelessWidget {
  final String label;

  const ChampLabel({super.key, required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 6),
      child: Text(
        label,
        style: GoogleFonts.inter(
          fontWeight: FontWeight.w600,
          fontSize: 13.5,
          color: AppColors.encre,
        ),
      ),
    );
  }
}

class ChampAide extends StatelessWidget {
  final String texte;

  const ChampAide({super.key, required this.texte});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 5),
      child: Text(
        texte,
        style: GoogleFonts.inter(
          fontSize: 12.5,
          color: AppColors.texteDoux,
        ),
      ),
    );
  }
}

class ChampErreur extends StatelessWidget {
  final String? texte;

  const ChampErreur({super.key, this.texte});

  @override
  Widget build(BuildContext context) {
    if (texte == null || texte!.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Text(
        texte!,
        style: GoogleFonts.inter(
          fontWeight: FontWeight.w600,
          fontSize: 13.5,
          color: AppColors.alerte,
        ),
      ),
    );
  }
}

// ============================================================
// LOGO
// ============================================================

class LogoTontineClair extends StatelessWidget {
  final double fontSize;

  const LogoTontineClair({super.key, this.fontSize = 22});

  @override
  Widget build(BuildContext context) {
    return RichText(
      text: TextSpan(
        children: [
          TextSpan(
            text: 'Tontine',
            style: GoogleFonts.bricolageGrotesque(
              fontWeight: FontWeight.w800,
              fontSize: fontSize,
              color: AppColors.encre,
              letterSpacing: -0.4,
            ),
          ),
          TextSpan(
            text: 'Clair',
            style: GoogleFonts.bricolageGrotesque(
              fontWeight: FontWeight.w800,
              fontSize: fontSize,
              color: AppColors.or,
              letterSpacing: -0.4,
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================
// ÉTATS VIDES
// ============================================================

class EtatVide extends StatelessWidget {
  final String emoji;
  final String titre;
  final String sousTitre;
  final Widget? action;

  const EtatVide({
    super.key,
    this.emoji = 'T',
    required this.titre,
    required this.sousTitre,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 74,
              height: 74,
              decoration: const BoxDecoration(
                color: AppColors.encre,
                shape: BoxShape.circle,
              ),
              child: Center(
                child: Text(
                  emoji,
                  style: GoogleFonts.bricolageGrotesque(
                    fontWeight: FontWeight.w800,
                    fontSize: 34,
                    color: AppColors.or,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              titre,
              style: GoogleFonts.bricolageGrotesque(
                fontWeight: FontWeight.w700,
                fontSize: 21,
                color: AppColors.encre,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              sousTitre,
              style: GoogleFonts.inter(
                fontSize: 14,
                color: AppColors.texteDoux,
              ),
              textAlign: TextAlign.center,
            ),
            if (action != null) ...[
              const SizedBox(height: 24),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

// ============================================================
// MODALE PIN
// ============================================================

/// Ligne individuelle dans le tableau récapitulatif d'une ModalePin.
/// Exemple : (label: 'Montant', valeur: '15 000 FCFA')
typedef LigneRecap = ({String label, String valeur});

/// Tableau récapitulatif affiché entre le sous-titre et le champ PIN.
/// [lignes] est une liste de paires label/valeur.
class _TableauRecap extends StatelessWidget {
  final List<LigneRecap> lignes;

  const _TableauRecap({required this.lignes});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 14, bottom: 4),
      decoration: BoxDecoration(
        color: AppColors.fondSecondaire,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.lignes, width: 1),
      ),
      child: Column(
        children: List.generate(lignes.length, (i) {
          final ligne = lignes[i];
          final estDerniere = i == lignes.length - 1;
          return Container(
            decoration: BoxDecoration(
              border: estDerniere
                  ? null
                  : Border(
                      bottom: BorderSide(color: AppColors.lignes, width: 1),
                    ),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  ligne.label,
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    color: AppColors.texteDoux,
                  ),
                ),
                const SizedBox(width: 12),
                Flexible(
                  child: Text(
                    ligne.valeur,
                    style: GoogleFonts.inter(
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                      color: AppColors.encre,
                    ),
                    textAlign: TextAlign.end,
                    overflow: TextOverflow.ellipsis,
                    maxLines: 2,
                  ),
                ),
              ],
            ),
          );
        }),
      ),
    );
  }
}

class ModalePin extends StatefulWidget {
  final String titre;
  final String sousTitre;
  final Future<bool> Function(String pin) onValider;
  final String labelValider;
  /// Lignes du tableau récapitulatif (optionnel).
  /// Affiché entre le sous-titre et le champ PIN.
  final List<LigneRecap>? recap;

  const ModalePin({
    super.key,
    required this.titre,
    required this.sousTitre,
    required this.onValider,
    this.labelValider = 'Confirmer',
    this.recap,
  });

  @override
  State<ModalePin> createState() => _ModalePinState();
}

class _ModalePinState extends State<ModalePin> {
  final _ctrl = TextEditingController();
  bool _loading = false;
  String? _erreur;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _valider() async {
    if (_ctrl.text.length < 4) {
      setState(() => _erreur = 'PIN trop court (4 chiffres min.)');
      return;
    }
    setState(() {
      _loading = true;
      _erreur = null;
    });
    final ok = await widget.onValider(_ctrl.text.trim());
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _loading = false;
        _erreur = 'PIN incorrect. Réessayez.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.lignes,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 20),
          Text(
            widget.titre,
            style: GoogleFonts.bricolageGrotesque(
              fontWeight: FontWeight.w700,
              fontSize: 20,
              color: AppColors.encre,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            widget.sousTitre,
            style: GoogleFonts.inter(
              fontSize: 13.5,
              color: AppColors.texteDoux,
            ),
          ),
          if (widget.recap != null && widget.recap!.isNotEmpty)
            _TableauRecap(lignes: widget.recap!),
          const SizedBox(height: 16),
          TextField(
            controller: _ctrl,
            keyboardType: TextInputType.number,
            obscureText: true,
            maxLength: 6,
            textAlign: TextAlign.center,
            autofocus: true,
            decoration: InputDecoration(
              hintText: '••••',
              counterText: '',
              filled: true,
              fillColor: Colors.white,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: AppColors.lignes, width: 1.5),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: AppColors.lignes, width: 1.5),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: AppColors.encre, width: 1.5),
              ),
            ),
            style: const TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.4,
              color: AppColors.texte,
            ),
            onSubmitted: (_) => _valider(),
          ),
          ChampErreur(texte: _erreur),
          const SizedBox(height: 16),
          BtnPrincipal(
            label: widget.labelValider,
            onTap: _valider,
            loading: _loading,
          ),
          const SizedBox(height: 8),
          BtnSecondaire(
            label: 'Annuler',
            onTap: () => Navigator.of(context).pop(false),
          ),
        ],
      ),
    );
  }
}

Future<bool?> afficherModalePin(
  BuildContext context, {
  required String titre,
  required String sousTitre,
  required Future<bool> Function(String pin) onValider,
  String labelValider = 'Confirmer',
  /// Lignes du tableau récapitulatif (optionnel).
  /// Exemple : [(label: 'Montant', valeur: '15 000 FCFA')]
  List<LigneRecap>? recap,
}) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.fondPapier,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => ModalePin(
      titre: titre,
      sousTitre: sousTitre,
      onValider: onValider,
      labelValider: labelValider,
      recap: recap,
    ),
  );
}

// ============================================================
// TOAST / SNACKBAR
// ============================================================

void afficherToast(BuildContext context, String message,
    {bool estErreur = false}) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        message,
        style: GoogleFonts.inter(fontWeight: FontWeight.w600),
      ),
      backgroundColor: estErreur ? AppColors.alerte : AppColors.succes,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      margin: const EdgeInsets.all(16),
    ),
  );
}

// ============================================================
// SCORE DE CONFIANCE
// ============================================================

class ScoreConfiance extends StatelessWidget {
  final int score;
  final String nom;

  const ScoreConfiance({super.key, required this.score, required this.nom});

  Color get _couleur {
    if (score >= 75) return AppColors.succes;
    if (score >= 50) return AppColors.or;
    return AppColors.alerte;
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: _couleur.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Center(
            child: Text(
              '$score',
              style: GoogleFonts.bricolageGrotesque(
                fontWeight: FontWeight.w700,
                fontSize: 13,
                color: _couleur,
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                nom,
                style: GoogleFonts.inter(
                  fontWeight: FontWeight.w600,
                  fontSize: 13.5,
                  color: AppColors.texte,
                ),
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              LinearProgressIndicator(
                value: score / 100,
                backgroundColor: AppColors.lignes,
                valueColor: AlwaysStoppedAnimation<Color>(_couleur),
                borderRadius: BorderRadius.circular(4),
                minHeight: 4,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ============================================================
// RESPONSIVE — Enveloppe pour adaptation ordinateur/tablette
// ============================================================
//
// Sur mobile  (< 600 px) : l'enfant prend toute la largeur.
// Sur tablette/desktop (≥ 600 px) : l'enfant est centré dans
// une colonne de largeur max 480 px, avec un fond neutre sur
// les côtés pour ne pas "étirer" l'interface mobile.
//
// Usage : PageResponsive(child: Scaffold(...))
//         ou directement autour du body d'un Scaffold existant.

class PageResponsive extends StatelessWidget {
  final Widget child;
  const PageResponsive({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 600) {
          // Mobile : plein écran, pas de changement
          return child;
        }
        // Tablette / ordinateur : centrer dans 480 px max
        return Container(
          color: AppColors.fondPapier,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: child,
            ),
          ),
        );
      },
    );
  }
}
