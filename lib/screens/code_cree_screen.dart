import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../utils/app_colors.dart';
import '../widgets/app_widgets.dart';
import 'detail_screen.dart';
import '../utils/app_localizations.dart';

class CodeCreerScreen extends StatelessWidget {
  final String code;
  final String nom;

  const CodeCreerScreen({super.key, required this.code, required this.nom});

  void _inviter() {
    final msg = Uri.encodeComponent(
      'Rejoins notre tontine "$nom" sur TontineClair !\n'
      'Code : $code\n'
      'Télécharge l\'app ou ouvre tontineclair.app et entre ce code pour tout suivre en direct.',
    );
    launchUrl(
      Uri.parse('https://wa.me/?text=$msg'),
      mode: LaunchMode.externalApplication,
    );
  }

  void _copierCode(BuildContext context) {
    Clipboard.setData(ClipboardData(text: code));
    afficherToast(context, 'Code copié !');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.fondPapier,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            children: [
              const SizedBox(height: 30),
              Container(
                width: 74,
                height: 74,
                decoration: const BoxDecoration(
                  color: AppColors.succes,
                  shape: BoxShape.circle,
                ),
                child: const Center(
                  child: Text(
                    '✓',
                    style: TextStyle(
                      fontSize: 34,
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                '$nom est en ligne !',
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 22,
                  color: AppColors.encre,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              // Bloc code
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: AppColors.fondCode,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: AppColors.lignes),
                ),
                child: Column(
                  children: [
                    const Text(
                      'Code de la tontine',
                      style: TextStyle(
                        fontSize: 14,
                        color: AppColors.texteDoux,
                      ),
                    ),
                    const SizedBox(height: 8),
                    GestureDetector(
                      onTap: () => _copierCode(context),
                      child: Text(
                        code,
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 48,
                          color: AppColors.encre,
                          letterSpacing: 0.3,
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.copy, size: 14, color: AppColors.texteDoux),
                        const SizedBox(width: 4),
                        TextButton(
                          onPressed: () => _copierCode(context),
                          child: const Text(
                            'Appuyer pour copier',
                            style: TextStyle(
                              fontSize: 12.5,
                              color: AppColors.texteDoux,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Les membres entrent ce code dans « Rejoindre une tontine » pour tout suivre en direct.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 13.5,
                        color: AppColors.texteDoux,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              BtnWhatsApp(
                label: 'Inviter les membres sur WhatsApp',
                onTap: _inviter,
              ),
              const SizedBox(height: 10),
              BtnPrincipal(
                label: context.tr('ouvrir_tontine'),
                onTap: () => Navigator.of(context).pushReplacement(
                  MaterialPageRoute(
                    builder: (_) => DetailScreen(code: code),
                  ),
                ),
              ),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }
}
