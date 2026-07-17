import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import '../utils/app_colors.dart';
import '../services/platform_service.dart';
import '../services/feature_gate_service.dart';
import '../services/supabase_service.dart';

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

/// Badge doré "Premium" affiché sur les tontines Premium.
class BadgePremium extends StatelessWidget {
  const BadgePremium({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0xFFF59E0B),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.star_rounded, size: 11, color: Colors.white),
          const SizedBox(width: 4),
          Text(
            'Premium',
            style: GoogleFonts.inter(
              fontWeight: FontWeight.w700,
              fontSize: 11.5,
              color: Colors.white,
              letterSpacing: 0.2,
            ),
          ),
        ],
      ),
    );
  }
}

/// Alias rétrocompat — utiliser BadgePremium à la place.
typedef BadgePro = BadgePremium;

/// Badge vert "Pro" — affiché à côté du badge Premium dans les détails.
class BadgeProVert extends StatelessWidget {
  const BadgeProVert({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0xFF0D8A4E),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.rocket_launch_rounded, size: 11, color: Colors.white),
          const SizedBox(width: 4),
          Text(
            'Pro',
            style: GoogleFonts.inter(
              fontWeight: FontWeight.w700,
              fontSize: 11.5,
              color: Colors.white,
              letterSpacing: 0.2,
            ),
          ),
        ],
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

// ============================================================
// DIALOG UPGRADE PREMIUM — source unique
// Affiche automatiquement le bon parcours selon la plateforme
// ============================================================

/// Affiche la dialog de mise à niveau Premium.
/// [onUpgrade] est appelé quand l'utilisateur tape "Passer à Premium".
/// La navigation vers l'écran d'abonnement est gérée à l'extérieur.
Future<void> afficherDialogUpgrade(
  BuildContext context, {
  required LimiteInfo limiteInfo,
  required VoidCallback onUpgrade,
}) {
  return showDialog(
    context: context,
    builder: (ctx) => _UpgradeDialog(
      limiteInfo: limiteInfo,
      onUpgrade: onUpgrade,
    ),
  );
}

class _UpgradeDialog extends StatelessWidget {
  final LimiteInfo limiteInfo;
  final VoidCallback onUpgrade;

  const _UpgradeDialog({
    required this.limiteInfo,
    required this.onUpgrade,
  });

  @override
  Widget build(BuildContext context) {
    final platformLabel = PlatformService.isAndroid
        ? 'Google Play'
        : PlatformService.isIOS
            ? 'App Store'
            : 'paiement web';

    return Dialog(
      backgroundColor: AppColors.fondPapier,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ── Icône ─────────────────────────────────────────────────────
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: AppColors.fondConsultation,
                borderRadius: BorderRadius.circular(18),
              ),
              child: const Icon(
                Icons.workspace_premium,
                size: 36,
                color: AppColors.orFonce,
              ),
            ),
            const SizedBox(height: 18),

            // ── Titre ─────────────────────────────────────────────────────
            Text(
              'Fonctionnalité Premium',
              style: GoogleFonts.bricolageGrotesque(
                fontWeight: FontWeight.w800,
                fontSize: 20,
                color: AppColors.encre,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 10),

            // ── Message de limite ─────────────────────────────────────────
            Text(
              limiteInfo.message,
              style: GoogleFonts.inter(
                fontSize: 14,
                color: AppColors.texteDoux,
                height: 1.5,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 18),

            // ── Tarifs ───────────────────────────────────────────────────
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.fondCode,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(
                children: [
                  _LigneTarif(
                    label: 'Mensuel',
                    prix: '2 500 FCFA / mois',
                    badge: null,
                  ),
                  const SizedBox(height: 8),
                  _LigneTarif(
                    label: 'Annuel',
                    prix: '25 000 FCFA / an',
                    badge: '2 mois offerts',
                  ),
                ],
              ),
            ),
            const SizedBox(height: 6),

            // ── Info plateforme ───────────────────────────────────────────
            Text(
              'Paiement via $platformLabel',
              style: GoogleFonts.inter(
                fontSize: 11.5,
                color: AppColors.texteDoux,
              ),
            ),
            const SizedBox(height: 18),

            // ── Boutons ───────────────────────────────────────────────────
            SizedBox(
              width: double.infinity,
              child: BtnPrincipal(
                label: 'Passer à Premium',
                icone: Icons.workspace_premium,
                couleur: AppColors.orFonce,
                onTap: () {
                  Navigator.of(context).pop();
                  onUpgrade();
                },
              ),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(
                'Plus tard',
                style: GoogleFonts.inter(
                  fontSize: 13,
                  color: AppColors.texteDoux,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LigneTarif extends StatelessWidget {
  final String label;
  final String prix;
  final String? badge;

  const _LigneTarif({
    required this.label,
    required this.prix,
    this.badge,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Icon(Icons.star, size: 14, color: AppColors.orFonce),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            '$label — $prix',
            style: GoogleFonts.inter(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AppColors.encre,
            ),
          ),
        ),
        if (badge != null)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: AppColors.orFonce,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              badge!,
              style: GoogleFonts.inter(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
          ),
      ],
    );
  }
}

// ── Widget cadenas pour fonctionnalité verrouillée ──────────────────────────

class FeatureLock extends StatelessWidget {
  final String titre;
  final String detail;
  final VoidCallback onUpgrade;

  const FeatureLock({
    super.key,
    required this.titre,
    required this.detail,
    required this.onUpgrade,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onUpgrade,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.fondSecondaire,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.lignes, width: 1),
        ),
        child: Row(
          children: [
            const Icon(Icons.lock_outline, size: 20, color: AppColors.texteDoux),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    titre,
                    style: GoogleFonts.inter(
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                      color: AppColors.encre,
                    ),
                  ),
                  Text(
                    detail,
                    style: GoogleFonts.inter(
                      fontSize: 12.5,
                      color: AppColors.texteDoux,
                    ),
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: AppColors.fondConsultation,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                'Premium',
                style: GoogleFonts.inter(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: AppColors.orFonce,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// KYC — BANNIÈRE + MODALE DE SOUMISSION
// Utilisées dans upgrade_premium_screen et nouveau_cycle_screen.
// Réservées aux tontines Premium (kycRequis = isPremium && cagnotte >= 200 000 XOF).
// ============================================================

enum _KycStatut { absent, pending, valide, rejete }

_KycStatut _parseKycStatut(String? s) {
  switch (s) {
    case 'pending': return _KycStatut.pending;
    case 'valide':  return _KycStatut.valide;
    case 'rejete':  return _KycStatut.rejete;
    default:        return _KycStatut.absent;
  }
}

/// Bannière d'état KYC affichée dans les écrans Premium.
class BanniereKyc extends StatelessWidget {
  final String? kycStatut;
  final int     montantCagnotte;
  final String  gestNom;
  final String  code;
  final Future<void> Function() onSoumis;

  const BanniereKyc({
    super.key,
    required this.kycStatut,
    required this.montantCagnotte,
    required this.gestNom,
    required this.code,
    required this.onSoumis,
  });

  static const int _seuil = 200000;

  @override
  Widget build(BuildContext context) {
    final statut  = _parseKycStatut(kycStatut);
    final depasse = montantCagnotte >= _seuil;

    if (!depasse && statut == _KycStatut.absent) return const SizedBox.shrink();

    Color  fond, bordure, couleurTexte;
    String emoji, titre, sousTitre;
    bool   montrerBouton = false;
    String labelBouton   = '';

    switch (statut) {
      case _KycStatut.valide:
        fond          = const Color(0xFFECFDF5);
        bordure       = const Color(0xFF34D399);
        couleurTexte  = const Color(0xFF065F46);
        emoji         = '✅';
        titre         = 'KYC validé';
        sousTitre     = 'Votre identité a été vérifiée par TontineClair.';
      case _KycStatut.pending:
        fond          = const Color(0xFFFFFBEB);
        bordure       = const Color(0xFFF59E0B);
        couleurTexte  = const Color(0xFF92400E);
        emoji         = '⏳';
        titre         = 'KYC en attente de validation';
        sousTitre     = 'Votre dossier est en cours de vérification.';
      case _KycStatut.rejete:
        fond          = const Color(0xFFFEF2F2);
        bordure       = const Color(0xFFF87171);
        couleurTexte  = const Color(0xFF991B1B);
        emoji         = '❌';
        titre         = 'KYC rejeté — action requise';
        sousTitre     = 'Votre dossier a été rejeté. Soumettez à nouveau vos documents.';
        montrerBouton = true;
        labelBouton   = '📋 Re-soumettre le KYC';
      case _KycStatut.absent:
        fond          = depasse ? const Color(0xFFFEF2F2) : const Color(0xFFFFFBEB);
        bordure       = depasse ? const Color(0xFFF87171) : const Color(0xFFF59E0B);
        couleurTexte  = depasse ? const Color(0xFF991B1B) : const Color(0xFF92400E);
        emoji         = depasse ? '🚨' : '📋';
        titre         = depasse
            ? 'KYC obligatoire — Cagnotte ≥ 200 000 XOF'
            : 'KYC recommandé (cagnotte < 200 000 XOF)';
        sousTitre     = depasse
            ? 'La cagnotte dépasse 200 000 XOF. Le KYC est requis pour continuer.'
            : 'Le KYC sera obligatoire si la cagnotte dépasse 200 000 XOF.';
        montrerBouton = true;
        labelBouton   = '📋 Soumettre le KYC';
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: fond,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: bordure),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(emoji, style: const TextStyle(fontSize: 18)),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(titre,
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 13.5,
                          color: couleurTexte,
                        )),
                    const SizedBox(height: 3),
                    Text(sousTitre,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: couleurTexte,
                          height: 1.4,
                        )),
                  ],
                ),
              ),
            ],
          ),
          if (montrerBouton) ...[
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: () async {
                  final ok = await showModalBottomSheet<bool>(
                    context: context,
                    isScrollControlled: true,
                    backgroundColor: Colors.transparent,
                    builder: (_) => ModaleKyc(code: code, gestNom: gestNom),
                  );
                  if (ok == true) await onSoumis();
                },
                style: OutlinedButton.styleFrom(
                  foregroundColor: couleurTexte,
                  side: BorderSide(color: bordure),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                child: Text(labelBouton,
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Modale de saisie KYC.  Retourne true si soumission réussie.
class ModaleKyc extends StatefulWidget {
  final String code;
  final String gestNom;

  const ModaleKyc({super.key, required this.code, required this.gestNom});

  @override
  State<ModaleKyc> createState() => _ModaleKycState();
}

class _ModaleKycState extends State<ModaleKyc> {
  final _nomCtrl  = TextEditingController();
  final _numCtrl  = TextEditingController();
  final _picker   = ImagePicker();

  String  _pieceType  = 'cni';
  bool    _loading    = false;
  String? _erreur;

  // Photos capturées via la caméra
  File? _photoRecto;
  File? _photoVerso;

  static const _pieceTypes = [
    ('cni',       "Carte Nationale d'Identité"),
    ('passeport', 'Passeport'),
    ('sejour',    'Titre de séjour'),
  ];

  @override
  void initState() {
    super.initState();
    _nomCtrl.text = widget.gestNom;
  }

  @override
  void dispose() {
    _nomCtrl.dispose();
    _numCtrl.dispose();
    super.dispose();
  }

  // ── Prise de photo (caméra uniquement) ────────────────────────────────────
  Future<void> _prendrePhoto({required bool estRecto}) async {
    try {
      final xfile = await _picker.pickImage(
        source: ImageSource.camera,
        imageQuality: 85,
        maxWidth: 1920,
        maxHeight: 1080,
        preferredCameraDevice: CameraDevice.rear,
      );
      if (xfile == null) return;
      setState(() {
        if (estRecto) {
          _photoRecto = File(xfile.path);
        } else {
          _photoVerso = File(xfile.path);
        }
        _erreur = null;
      });
    } catch (_) {
      if (mounted) {
        setState(() => _erreur = 'Impossible d\'accéder à la caméra. Vérifiez les permissions.');
      }
    }
  }

  Future<void> _soumettre() async {
    final nom    = _nomCtrl.text.trim();
    final numero = _numCtrl.text.trim();
    if (nom.isEmpty) {
      setState(() => _erreur = 'Veuillez saisir votre nom complet.');
      return;
    }
    if (numero.isEmpty) {
      setState(() => _erreur = 'Veuillez saisir le numéro de la pièce.');
      return;
    }
    if (_photoRecto == null) {
      setState(() => _erreur = 'Photo recto obligatoire — prenez une photo de votre pièce.');
      return;
    }
    if (_photoVerso == null) {
      setState(() => _erreur = 'Photo verso obligatoire — prenez une photo du verso de votre pièce.');
      return;
    }

    setState(() { _loading = true; _erreur = null; });
    final ok = await SupabaseService.soumettreKyc(
      code:         widget.code,
      gestionnaire: widget.gestNom,
      nom:          nom,
      pieceType:    _pieceType,
      pieceNumero:  numero,
    );
    if (!mounted) return;
    setState(() => _loading = false);
    if (ok) {
      Navigator.of(context).pop(true);
    } else {
      setState(() => _erreur = 'Erreur lors de la soumission. Réessayez.');
    }
  }

  // ── Widget photo recto ou verso ───────────────────────────────────────────
  Widget _cartePhoto({
    required bool estRecto,
    required File? photo,
  }) {
    final label  = estRecto ? 'Recto' : 'Verso';
    final icone  = estRecto ? Icons.credit_card_rounded : Icons.flip_rounded;
    final couleur = photo != null ? AppColors.succes : AppColors.encre;

    return GestureDetector(
      onTap: () => _prendrePhoto(estRecto: estRecto),
      child: Container(
        height: 110,
        decoration: BoxDecoration(
          color: photo != null
              ? AppColors.succes.withValues(alpha: .06)
              : AppColors.fondCode,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: photo != null
                ? AppColors.succes.withValues(alpha: .4)
                : AppColors.lignes,
            width: 1.5,
          ),
        ),
        child: photo != null
            ? Stack(
                fit: StackFit.expand,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(11),
                    child: Image.file(photo, fit: BoxFit.cover),
                  ),
                  // Badge ✓
                  Positioned(
                    top: 6, right: 6,
                    child: Container(
                      width: 26, height: 26,
                      decoration: BoxDecoration(
                        color: AppColors.succes,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.check_rounded, color: Colors.white, size: 15),
                    ),
                  ),
                  // Tap pour refaire
                  Positioned(
                    bottom: 0, left: 0, right: 0,
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 5),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: .45),
                        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(11)),
                      ),
                      child: const Text(
                        'Appuyer pour reprendre',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                ],
              )
            : Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 38, height: 38,
                    decoration: BoxDecoration(
                      color: couleur.withValues(alpha: .10),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(icone, size: 20, color: couleur),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Photo $label',
                    style: TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w700, color: couleur),
                  ),
                  const SizedBox(height: 2),
                  const Text(
                    'Caméra uniquement',
                    style: TextStyle(fontSize: 10.5, color: AppColors.texteDoux),
                  ),
                ],
              ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.fondPapier,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── En-tête ─────────────────────────────────────────────────────
            Row(
              children: [
                Container(
                  width: 40, height: 40,
                  decoration: BoxDecoration(
                    color: const Color(0xFFFEF3C7),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Center(child: Text('🪪', style: TextStyle(fontSize: 20))),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Vérification d\'identité (KYC)',
                          style: TextStyle(
                            fontWeight: FontWeight.w800, fontSize: 15, color: AppColors.encre)),
                      Text('Cagnotte ≥ 200 000 XOF · Photos obligatoires',
                          style: TextStyle(fontSize: 11.5, color: AppColors.texteDoux)),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded, size: 20),
                  onPressed: () => Navigator.of(context).pop(false),
                  color: AppColors.texteDoux,
                ),
              ],
            ),
            const SizedBox(height: 6),
            const Divider(height: 1, color: AppColors.lignes),
            const SizedBox(height: 14),

            // ── Bandeau info ─────────────────────────────────────────────────
            Container(
              padding: const EdgeInsets.all(11),
              decoration: BoxDecoration(
                color: const Color(0xFFEFF6FF),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFF93C5FD)),
              ),
              child: const Text(
                '📷  Prenez une photo de votre pièce d\'identité '
                'avec l\'appareil photo de votre téléphone. '
                'Les photos sont transmises à TontineClair pour vérification.',
                style: TextStyle(fontSize: 12, color: Color(0xFF1E40AF), height: 1.4),
              ),
            ),
            const SizedBox(height: 14),

            // ── Nom gestionnaire ─────────────────────────────────────────────
            const Text('Nom complet du gestionnaire *',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.encre)),
            const SizedBox(height: 6),
            TextField(
              controller: _nomCtrl,
              textCapitalization: TextCapitalization.words,
              decoration: InputDecoration(
                hintText: 'Ex : Kouassi Ama Bernadette',
                filled: true,
                fillColor: Colors.white,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: AppColors.lignes),
                ),
                prefixIcon: const Icon(Icons.person_outline_rounded, size: 18),
              ),
            ),
            const SizedBox(height: 12),

            // ── Type pièce ───────────────────────────────────────────────────
            const Text('Type de pièce d\'identité *',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.encre)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: _pieceTypes.map((pt) {
                final selected = _pieceType == pt.$1;
                return ChoiceChip(
                  label: Text(pt.$2,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: selected ? Colors.white : AppColors.encre,
                      )),
                  selected: selected,
                  selectedColor: AppColors.encre,
                  backgroundColor: AppColors.fondPapier,
                  side: BorderSide(color: selected ? AppColors.encre : AppColors.lignes),
                  onSelected: (_) => setState(() => _pieceType = pt.$1),
                );
              }).toList(),
            ),
            const SizedBox(height: 12),

            // ── Numéro pièce ─────────────────────────────────────────────────
            const Text('Numéro de la pièce *',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.encre)),
            const SizedBox(height: 6),
            TextField(
              controller: _numCtrl,
              textCapitalization: TextCapitalization.characters,
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9\-]'))],
              decoration: InputDecoration(
                hintText: 'Ex : CI-AB-12345678-2024',
                filled: true,
                fillColor: Colors.white,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: AppColors.lignes),
                ),
                prefixIcon: const Icon(Icons.badge_outlined, size: 18),
              ),
            ),
            const SizedBox(height: 16),

            // ── Photos recto / verso ─────────────────────────────────────────
            const Text('Photos de la pièce *',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.encre)),
            const SizedBox(height: 4),
            const Text(
              'Prenez chaque côté avec la caméra de votre téléphone.',
              style: TextStyle(fontSize: 11.5, color: AppColors.texteDoux),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(child: _cartePhoto(estRecto: true,  photo: _photoRecto)),
                const SizedBox(width: 10),
                Expanded(child: _cartePhoto(estRecto: false, photo: _photoVerso)),
              ],
            ),

            // ── Erreur ───────────────────────────────────────────────────────
            if (_erreur != null) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.alerte.withValues(alpha: .08),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppColors.alerte.withValues(alpha: .3)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.warning_amber_rounded, size: 16, color: AppColors.alerte),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(_erreur!,
                          style: const TextStyle(fontSize: 12.5, color: AppColors.alerte)),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 16),

            // ── Bouton soumettre ─────────────────────────────────────────────
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _loading ? null : _soumettre,
                icon: _loading
                    ? const SizedBox(
                        width: 16, height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.send_rounded, size: 18),
                label: Text(
                  _loading ? 'Envoi en cours…' : 'Soumettre le dossier KYC',
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                ),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.encre,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Après soumission, TontineClair validera votre dossier sous 24–48h.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11.5, color: AppColors.texteDoux),
            ),
          ],
        ),
      ),
    );
  }
}
