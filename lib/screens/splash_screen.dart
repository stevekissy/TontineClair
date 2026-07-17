import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../utils/app_colors.dart';
import 'accueil_screen.dart';

/// Splash screen animé TontineClair (~2.5 s)
/// Séquence : fond papier → logo fade+scale → shimmer doré → tagline → navigate
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with TickerProviderStateMixin {
  // ── Contrôleurs d'animation ───────────────────────────────────────────────

  /// Phase 1 : le logo entre en scène (scale + fade) — 0 → 600 ms
  late final AnimationController _logoCtrl;
  late final Animation<double> _logoScale;
  late final Animation<double> _logoFade;

  /// Phase 2 : shimmer doré sur "Clair" — 400 → 1200 ms
  late final AnimationController _shimmerCtrl;

  /// Phase 3 : tagline glisse depuis le bas + fade — 800 → 1400 ms
  late final AnimationController _taglineCtrl;
  late final Animation<double> _taglineFade;
  late final Animation<Offset> _taglineSlide;

  /// Phase 4 : point pulsant (loader) — 1200 → 2200 ms puis navigate
  late final AnimationController _dotCtrl;
  late final Animation<double> _dotScale;

  @override
  void initState() {
    super.initState();

    // ── Logo (scale 0.6→1.0, fade 0→1) ──────────────────────────────────
    _logoCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    _logoScale = CurvedAnimation(parent: _logoCtrl, curve: Curves.easeOutBack)
        .drive(Tween(begin: 0.55, end: 1.0));
    _logoFade = CurvedAnimation(parent: _logoCtrl, curve: Curves.easeIn)
        .drive(Tween(begin: 0.0, end: 1.0));

    // ── Shimmer (boucle infinie, démarre à 400 ms) ────────────────────────
    _shimmerCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );

    // ── Tagline (slide + fade, démarre à 750 ms) ──────────────────────────
    _taglineCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 550),
    );
    _taglineFade = CurvedAnimation(parent: _taglineCtrl, curve: Curves.easeIn)
        .drive(Tween(begin: 0.0, end: 1.0));
    _taglineSlide = CurvedAnimation(parent: _taglineCtrl, curve: Curves.easeOut)
        .drive(Tween(
          begin: const Offset(0, 0.5),
          end: Offset.zero,
        ));

    // ── Point pulsant (démarre à 1100 ms) ────────────────────────────────
    _dotCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    )..repeat(reverse: true);
    _dotScale = CurvedAnimation(parent: _dotCtrl, curve: Curves.easeInOut)
        .drive(Tween(begin: 0.5, end: 1.0));

    _lancerSequence();
  }

  Future<void> _lancerSequence() async {
    // Phase 1 — logo entre
    _logoCtrl.forward();

    // Phase 2 — shimmer démarre après 400 ms
    await Future.delayed(const Duration(milliseconds: 400));
    _shimmerCtrl.repeat();

    // Phase 3 — tagline
    await Future.delayed(const Duration(milliseconds: 350));
    _taglineCtrl.forward();

    // Phase 4 — on attend la fin de l'animation complète (~2.3 s total)
    await Future.delayed(const Duration(milliseconds: 1400));

    if (!mounted) return;
    // Navigation vers AccueilScreen (remplacement complet)
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => const AccueilScreen(),
        transitionsBuilder: (_, animation, __, child) => FadeTransition(
          opacity: animation,
          child: child,
        ),
        transitionDuration: const Duration(milliseconds: 400),
      ),
    );
  }

  @override
  void dispose() {
    _logoCtrl.dispose();
    _shimmerCtrl.dispose();
    _taglineCtrl.dispose();
    _dotCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.fondPapier,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // ── Logo animé ───────────────────────────────────────────────
            AnimatedBuilder(
              animation: _logoCtrl,
              builder: (_, __) => FadeTransition(
                opacity: _logoFade,
                child: ScaleTransition(
                  scale: _logoScale,
                  child: _LogoShimmer(shimmerCtrl: _shimmerCtrl),
                ),
              ),
            ),

            const SizedBox(height: 20),

            // ── Tagline ──────────────────────────────────────────────────
            SlideTransition(
              position: _taglineSlide,
              child: FadeTransition(
                opacity: _taglineFade,
                child: Text(
                  'La tontine, réinventée ✨',
                  style: GoogleFonts.bricolageGrotesque(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: AppColors.texteDoux,
                    letterSpacing: 0.2,
                  ),
                ),
              ),
            ),

            const SizedBox(height: 52),

            // ── Point pulsant (loader discret) ───────────────────────────
            FadeTransition(
              opacity: _taglineFade, // apparaît avec la tagline
              child: ScaleTransition(
                scale: _dotScale,
                child: Container(
                  width: 8,
                  height: 8,
                  decoration: const BoxDecoration(
                    color: AppColors.or,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Widget logo avec effet shimmer doré ─────────────────────────────────────

class _LogoShimmer extends StatelessWidget {
  final AnimationController shimmerCtrl;

  const _LogoShimmer({required this.shimmerCtrl});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: shimmerCtrl,
      builder: (_, __) {
        // Shimmer : gradient qui balaie "Clair" de gauche à droite
        final shimmerValue = shimmerCtrl.value;
        return ShaderMask(
          blendMode: BlendMode.srcIn,
          shaderCallback: (bounds) {
            // On découpe le logo en deux zones : "Tontine" à gauche reste encre,
            // "Clair" à droite reçoit le shimmer doré.
            // On applique le shader sur tout le texte, mais l'effet sur
            // la partie "Tontine" reste dans ses couleurs d'origine via
            // la gestion des couleurs ci-dessous.
            return LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: const [
                AppColors.encre,
                AppColors.encre,
                AppColors.or,
                Color(0xFFF7DC8A), // reflet clair
                AppColors.or,
                AppColors.orFonce,
              ],
              stops: [
                0.0,
                0.45,
                (0.45 + shimmerValue * 0.55).clamp(0.45, 0.95),
                (0.50 + shimmerValue * 0.55).clamp(0.50, 1.0),
                (0.60 + shimmerValue * 0.40).clamp(0.60, 1.0),
                1.0,
              ],
            ).createShader(bounds);
          },
          child: _LogoTexte(),
        );
      },
    );
  }
}

/// Texte "TontineClair" en grand, sans ShaderMask (reçoit le shader du parent)
class _LogoTexte extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    // On utilise un RichText classique ; le ShaderMask parent gère les couleurs
    return RichText(
      text: TextSpan(
        children: [
          TextSpan(
            text: 'Tontine',
            style: GoogleFonts.bricolageGrotesque(
              fontWeight: FontWeight.w800,
              fontSize: 42,
              color: AppColors.encre, // sera écrasé par le shader
              letterSpacing: -0.8,
            ),
          ),
          TextSpan(
            text: 'Clair',
            style: GoogleFonts.bricolageGrotesque(
              fontWeight: FontWeight.w800,
              fontSize: 42,
              color: AppColors.or, // sera écrasé par le shader
              letterSpacing: -0.8,
            ),
          ),
        ],
      ),
    );
  }
}
