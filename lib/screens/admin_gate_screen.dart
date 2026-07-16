// ─────────────────────────────────────────────────────────────────────────────
// admin_gate_screen.dart
//
// Route sécurisée vers l'espace administration.
// Accessible UNIQUEMENT via une URL / route interne dédiée, jamais depuis
// l'interface utilisateur publique.
//
// Comportement :
//   • Affiche un écran "Accès non autorisé" si la clé admin n'est pas fournie
//     à la construction (navigation directe non autorisée).
//   • Redirige automatiquement vers AccueilScreen après 3 secondes.
//   • Si la clé est fournie (usage interne admin_app uniquement), ouvre
//     directement AdminScreen sans écran intermédiaire.
//
// Usage correct (depuis admin_app uniquement) :
//   Navigator.push(ctx, MaterialPageRoute(
//     builder: (_) => AdminGateScreen(cleAdmin: 'MA_CLE_SECRETE'),
//   ));
//
// Toute tentative de navigation sans clé → "Accès non autorisé".
// ─────────────────────────────────────────────────────────────────────────────

import 'package:flutter/material.dart';
import '../utils/app_colors.dart';
import 'accueil_screen.dart';
import 'admin_screen.dart';

class AdminGateScreen extends StatefulWidget {
  /// Clé admin fournie programmatiquement (jamais saisie dans l'UI client).
  /// Si null ou vide → accès refusé, redirection vers AccueilScreen.
  final String? cleAdmin;

  const AdminGateScreen({super.key, this.cleAdmin});

  @override
  State<AdminGateScreen> createState() => _AdminGateScreenState();
}

class _AdminGateScreenState extends State<AdminGateScreen> {
  @override
  void initState() {
    super.initState();
    _evaluerAcces();
  }

  void _evaluerAcces() {
    final cle = widget.cleAdmin?.trim() ?? '';

    if (cle.isNotEmpty) {
      // Clé fournie → remplacer cette route par AdminScreen directement
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const AdminScreen()),
        );
      });
    } else {
      // Aucune clé → rediriger vers l'accueil après 3 secondes
      Future.delayed(const Duration(seconds: 3), () {
        if (!mounted) return;
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const AccueilScreen()),
          (route) => false,
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // Si la clé est fournie, on affiche un loader pendant la redirection
    final cle = widget.cleAdmin?.trim() ?? '';
    if (cle.isNotEmpty) {
      return const Scaffold(
        backgroundColor: Colors.white,
        body: Center(child: CircularProgressIndicator()),
      );
    }

    // Accès non autorisé
    return Scaffold(
      backgroundColor: AppColors.fondPapier,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Icône cadenas
                Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFF3F3),
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: const Icon(
                    Icons.lock_person_rounded,
                    size: 40,
                    color: Color(0xFFD32F2F),
                  ),
                ),
                const SizedBox(height: 24),

                // Titre
                Text(
                  'Accès non autorisé',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    color: AppColors.encre,
                  ),
                ),
                const SizedBox(height: 12),

                // Message
                Text(
                  'Vous n\'avez pas les droits nécessaires\npour accéder à cet espace.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 15,
                    color: AppColors.encre.withValues(alpha: 0.60),
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 32),

                // Indicateur de redirection
                _RedirectionTimer(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Widget : compte à rebours de redirection ────────────────────────────────
class _RedirectionTimer extends StatefulWidget {
  @override
  State<_RedirectionTimer> createState() => _RedirectionTimerState();
}

class _RedirectionTimerState extends State<_RedirectionTimer> {
  int _secondes = 3;

  @override
  void initState() {
    super.initState();
    _demarrerCompte();
  }

  void _demarrerCompte() {
    Future.doWhile(() async {
      await Future.delayed(const Duration(seconds: 1));
      if (!mounted) return false;
      setState(() => _secondes--);
      return _secondes > 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SizedBox(
          width: 36,
          height: 36,
          child: CircularProgressIndicator(
            value: _secondes / 3,
            strokeWidth: 3,
            color: AppColors.or,
            backgroundColor: AppColors.encre.withValues(alpha: 0.10),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'Redirection dans $_secondes s…',
          style: TextStyle(
            fontSize: 13,
            color: AppColors.encre.withValues(alpha: 0.45),
          ),
        ),
      ],
    );
  }
}
