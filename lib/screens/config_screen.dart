import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/supabase_service.dart';
import '../utils/app_colors.dart';
import '../widgets/app_widgets.dart';

/// Écran de configuration — DEV UNIQUEMENT.
/// Les credentials sont codés en dur dans SupabaseService.
/// Cet écran est accessible uniquement via le menu développeur (appui long sur le logo).
/// Il n'affiche que les infos actuelles — aucune modification possible.
class ConfigScreen extends StatelessWidget {
  final VoidCallback onConfigured;

  const ConfigScreen({super.key, required this.onConfigured});

  @override
  Widget build(BuildContext context) {
    final url = SupabaseService.supabaseUrl;
    final key = SupabaseService.supabaseAnonKey;
    final keyMasque = key.length > 20
        ? '${key.substring(0, 20)}…[masqué]'
        : key;

    return Scaffold(
      backgroundColor: AppColors.fondPapier,
      appBar: AppBar(
        backgroundColor: AppColors.fondPapier,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded, color: AppColors.encre),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text(
          'Infos connexion',
          style: TextStyle(
            color: AppColors.encre,
            fontWeight: FontWeight.w700,
            fontSize: 18,
          ),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Bandeau info ─────────────────────────────────────
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.blue.shade50,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.blue.shade200),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.info_outline_rounded,
                        color: Colors.blue.shade700, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Les credentials sont codés en dur dans l\'application. '
                        'Ils ne peuvent pas être modifiés par l\'utilisateur.',
                        style: TextStyle(
                          fontSize: 13.5,
                          color: Colors.blue.shade800,
                          height: 1.5,
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 24),

              // ── URL du projet ─────────────────────────────────────
              const ChampLabel(label: 'URL du projet Supabase'),
              CarteTC(
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        url,
                        style: const TextStyle(
                          fontSize: 13.5,
                          color: AppColors.texte,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.copy_rounded,
                          size: 18, color: AppColors.encreDoux),
                      tooltip: 'Copier',
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: url));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('URL copiée')),
                        );
                      },
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 16),

              // ── Clé anon ─────────────────────────────────────────
              const ChampLabel(label: 'Clé anon (public)'),
              CarteTC(
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        keyMasque,
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.texte,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.copy_rounded,
                          size: 18, color: AppColors.encreDoux),
                      tooltip: 'Copier la clé complète',
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: key));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Clé copiée')),
                        );
                      },
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 32),

              // ── Bouton fermer ─────────────────────────────────────
              BtnPrincipal(
                label: 'Fermer',
                onTap: () => Navigator.of(context).pop(),
                icon: Icons.check_rounded,
              ),

              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}
