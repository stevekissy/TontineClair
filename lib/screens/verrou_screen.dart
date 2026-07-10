import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/tontine_provider.dart';
import '../utils/app_colors.dart';
import '../widgets/app_widgets.dart';

class VerrouScreen extends StatefulWidget {
  const VerrouScreen({super.key});

  @override
  State<VerrouScreen> createState() => _VerrouScreenState();
}

class _VerrouScreenState extends State<VerrouScreen> {
  int _gestChoisi = 0;
  final _pinCtrl = TextEditingController();
  bool _loading = false;
  String? _erreur;

  @override
  void dispose() {
    _pinCtrl.dispose();
    super.dispose();
  }

  Future<void> _debloqur() async {
    final provider = context.read<TontineProvider>();
    final tontine = provider.courante;
    if (tontine == null) return;

    final gests = tontine.data.gestionnaires;
    if (gests.isEmpty) return;

    final gest = gests[_gestChoisi];
    final pin = _pinCtrl.text.trim();

    if (pin.length < 4) {
      setState(() => _erreur = 'PIN trop court (4 chiffres min.)');
      return;
    }

    setState(() {
      _loading = true;
      _erreur = null;
    });

    final ok = await provider.verifierEtDebloqur(nom: gest.nom, pin: pin);

    if (!mounted) return;
    setState(() => _loading = false);

    if (ok) {
      Navigator.of(context).pop();
      afficherToast(context, 'Accès gestionnaire activé · ${gest.nom}');
    } else {
      setState(() => _erreur = 'PIN incorrect. Réessayez.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<TontineProvider>();
    final tontine = provider.courante;
    if (tontine == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final gests = tontine.data.gestionnaires;

    return Scaffold(
      backgroundColor: AppColors.fondPapier,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            children: [
              const SizedBox(height: 18),
              Row(
                children: [
                  const LogoTontineClair(),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.arrow_back, size: 16),
                    label: const Text('Retour'),
                    style: TextButton.styleFrom(
                      foregroundColor: AppColors.encre,
                      textStyle: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              CarteTC(
                child: Column(
                  children: [
                    const Text(
                      '🔐',
                      style: TextStyle(fontSize: 40),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Accès gestionnaire',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 22,
                        color: AppColors.encre,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${tontine.data.nom} — identifie-toi pour modifier.',
                      style: const TextStyle(
                        fontSize: 13.5,
                        color: AppColors.texteDoux,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 20),
                    // Choix gestionnaire
                    if (gests.length > 1) ...[
                      const Align(
                        alignment: Alignment.centerLeft,
                        child: ChampLabel(label: 'Qui es-tu ?'),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: gests.asMap().entries.map((e) {
                          final selected = e.key == _gestChoisi;
                          return GestureDetector(
                            onTap: () => setState(() => _gestChoisi = e.key),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 10),
                              decoration: BoxDecoration(
                                color: selected
                                    ? AppColors.encre
                                    : AppColors.fondCode,
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: selected
                                      ? AppColors.encre
                                      : AppColors.lignes,
                                ),
                              ),
                              child: Text(
                                e.value.nom,
                                style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 14,
                                  color:
                                      selected ? Colors.white : AppColors.encre,
                                ),
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                      const SizedBox(height: 16),
                    ] else if (gests.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 10),
                        decoration: BoxDecoration(
                          color: AppColors.encre,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          gests[0].nom,
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                            color: Colors.white,
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: ChampLabel(label: 'Ton PIN personnel'),
                    ),
                    TextField(
                      controller: _pinCtrl,
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
                          borderSide: const BorderSide(
                              color: AppColors.lignes, width: 1.5),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(
                              color: AppColors.lignes, width: 1.5),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(
                              color: AppColors.encre, width: 1.5),
                        ),
                      ),
                      style: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.4,
                        color: AppColors.texte,
                      ),
                      onSubmitted: (_) => _debloqur(),
                    ),
                    ChampErreur(texte: _erreur),
                    const SizedBox(height: 16),
                    BtnPrincipal(
                      label: 'Accéder',
                      onTap: _debloqur,
                      loading: _loading,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
