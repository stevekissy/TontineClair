// ═══════════════════════════════════════════════════════════════════════════
// TontineClair — SecuriteScreen
// Paramètres > Sécurité : modifier le PIN depuis une session connectée
// Accessible depuis le menu de la tontine quand le gestionnaire est débloqué
// ═══════════════════════════════════════════════════════════════════════════

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/supabase_service.dart';
import '../services/email_service.dart';
import '../utils/app_colors.dart';
import '../widgets/app_widgets.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Écran Sécurité principal
// ─────────────────────────────────────────────────────────────────────────────
class SecuriteScreen extends StatelessWidget {
  final String tontineCode;
  final String gestNom;

  const SecuriteScreen({
    super.key,
    required this.tontineCode,
    required this.gestNom,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.fondPapier,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 18),
              // Header
              Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back_rounded, color: AppColors.encre),
                    onPressed: () => Navigator.of(context).pop(),
                    tooltip: 'Retour',
                  ),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Paramètres · Sécurité',
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 19,
                        color: AppColors.encre,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.only(left: 52),
                child: Text(
                  'Tontine $tontineCode · Gestionnaire : $gestNom',
                  style: const TextStyle(fontSize: 12, color: AppColors.texteDoux),
                ),
              ),
              const SizedBox(height: 24),

              // ── Section PIN ──────────────────────────────────────────────
              const _SectionTitre(
                icone: Icons.lock_outline_rounded,
                titre: 'PIN de gestion',
              ),
              const SizedBox(height: 12),

              // Carte "Modifier le PIN"
              _CarteOption(
                icone:       Icons.pin_outlined,
                couleurIcone: AppColors.encre,
                titre:       'Modifier le PIN de gestion',
                description: 'Changer votre PIN depuis cette session active.',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => ModifierPinScreen(
                      tontineCode: tontineCode,
                      gestNom:     gestNom,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 32),

              // ── Section Sécurité générale ────────────────────────────────
              const _SectionTitre(
                icone: Icons.security_rounded,
                titre: 'Informations de sécurité',
              ),
              const SizedBox(height: 12),
              CarteTC(
                child: Column(
                  children: [
                    for (final item in [
                      (Icons.lock_reset_rounded,    AppColors.or,     'Réinitialisation disponible',
                        'En cas d\'oubli, utilisez "PIN oublié" sur l\'écran de connexion.'),
                      (Icons.history_rounded,        AppColors.encre,  'Journal d\'audit',
                        'Toutes les modifications de PIN sont enregistrées avec date, heure et appareil.'),
                      (Icons.no_encryption_outlined, AppColors.alerte, 'Confidentialité',
                        'Votre PIN n\'est jamais stocké en clair ni transmis par e-mail.'),
                      (Icons.notifications_outlined, AppColors.succes, 'Alertes automatiques',
                        'Un e-mail de sécurité vous est envoyé à chaque modification de PIN.'),
                    ])
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              width: 36, height: 36,
                              decoration: BoxDecoration(
                                color: item.$2.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(9),
                              ),
                              child: Icon(item.$1, color: item.$2, size: 18),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(item.$3,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                      fontSize: 13,
                                      color: AppColors.encre,
                                    )),
                                  const SizedBox(height: 2),
                                  Text(item.$4,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: AppColors.texteDoux,
                                      height: 1.4,
                                    )),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// ModifierPinScreen — Modification du PIN depuis une session active
// ─────────────────────────────────────────────────────────────────────────────
class ModifierPinScreen extends StatefulWidget {
  final String tontineCode;
  final String gestNom;

  const ModifierPinScreen({
    super.key,
    required this.tontineCode,
    required this.gestNom,
  });

  @override
  State<ModifierPinScreen> createState() => _ModifierPinScreenState();
}

class _ModifierPinScreenState extends State<ModifierPinScreen> {
  final _ancienCtrl  = TextEditingController();
  final _nouveauCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  bool   _loading    = false;
  String? _erreur;
  bool   _ancienVis  = false;
  bool   _nouvVis    = false;
  bool   _confVis    = false;
  bool   _succes     = false;

  static const _pinsInterdits = {
    '0000','1111','2222','3333','4444','5555','6666','7777','8888','9999',
    '1234','4321','1212','0101','1010','0011','1100',
    '123456','654321','112233','000000','111111','999999',
  };

  @override
  void dispose() {
    _ancienCtrl.dispose();
    _nouveauCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  Future<void> _modifier() async {
    final ancien  = _ancienCtrl.text.trim();
    final nouveau = _nouveauCtrl.text.trim();
    final confirm = _confirmCtrl.text.trim();

    if (ancien.length < 4) {
      setState(() => _erreur = 'Saisissez votre ancien PIN (4 chiffres min.)');
      return;
    }
    if (nouveau.length < 4) {
      setState(() => _erreur = 'Le nouveau PIN doit comporter au moins 4 chiffres.');
      return;
    }
    if (_pinsInterdits.contains(nouveau)) {
      setState(() => _erreur = 'Ce PIN est trop simple. Choisissez-en un plus sécurisé.');
      return;
    }
    if (nouveau != confirm) {
      setState(() => _erreur = 'Les deux PIN ne correspondent pas.');
      return;
    }
    if (nouveau == ancien) {
      setState(() => _erreur = 'Le nouveau PIN doit être différent de l\'ancien.');
      return;
    }

    setState(() { _loading = true; _erreur = null; });

    try {
      final result = await SupabaseService.modifierPin(
        code:       widget.tontineCode,
        nom:        widget.gestNom,
        ancienPin:  ancien,
        nouveauPin: nouveau,
      );

      if (!mounted) return;

      if (result['ok'] == true) {
        setState(() => _succes = true);

        // Notification + e-mail de sécurité (non bloquants)
        SupabaseService.envoyerNotification(
          code:    widget.tontineCode,
          type:    'securite',
          titre:   '🔒 PIN modifié',
          message: 'Votre PIN de gestion TontineClair a été modifié. '
                   'Si vous n\'êtes pas à l\'origine de cette action, '
                   'contactez immédiatement le support.',
        );
        EmailService.envoyerPinChangeConfirme(
          destinataire: 'gestionnaire@email.com', // récupéré depuis contact en prod
          nom:          widget.gestNom,
          tontine:      widget.tontineCode,
          tontineCode:  widget.tontineCode,
        );
      } else {
        setState(() => _erreur = result['erreur'] as String? ?? 'Erreur. Réessayez.');
      }
    } catch (e) {
      if (mounted) setState(() => _erreur = 'Erreur réseau. Réessayez.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
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
              const SizedBox(height: 18),
              Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back_rounded, color: AppColors.encre),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  const Expanded(
                    child: Text(
                      'Modifier le PIN de gestion',
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 18,
                        color: AppColors.encre,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),

              if (_succes)
                _VueSucces(onRetour: () => Navigator.of(context).pop())
              else
                _FormulaireModification(
                  ancienCtrl:  _ancienCtrl,
                  nouveauCtrl: _nouveauCtrl,
                  confirmCtrl: _confirmCtrl,
                  ancienVis:   _ancienVis,
                  nouvVis:     _nouvVis,
                  confVis:     _confVis,
                  loading:     _loading,
                  erreur:      _erreur,
                  tontineCode: widget.tontineCode,
                  gestNom:     widget.gestNom,
                  onToggleAncien:  () => setState(() => _ancienVis = !_ancienVis),
                  onToggleNouv:    () => setState(() => _nouvVis = !_nouvVis),
                  onToggleConf:    () => setState(() => _confVis = !_confVis),
                  onModifier:      _modifier,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Formulaire de modification ────────────────────────────────────────────
class _FormulaireModification extends StatelessWidget {
  final TextEditingController ancienCtrl;
  final TextEditingController nouveauCtrl;
  final TextEditingController confirmCtrl;
  final bool ancienVis, nouvVis, confVis, loading;
  final String? erreur;
  final String tontineCode, gestNom;
  final VoidCallback onToggleAncien, onToggleNouv, onToggleConf, onModifier;

  const _FormulaireModification({
    required this.ancienCtrl, required this.nouveauCtrl, required this.confirmCtrl,
    required this.ancienVis, required this.nouvVis, required this.confVis,
    required this.loading, this.erreur,
    required this.tontineCode, required this.gestNom,
    required this.onToggleAncien, required this.onToggleNouv, required this.onToggleConf,
    required this.onModifier,
  });

  @override
  Widget build(BuildContext context) {
    return CarteTC(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Center(child: Text('🔐', style: TextStyle(fontSize: 36))),
          const SizedBox(height: 16),
          Center(
            child: Text(
              'Gestionnaire : $gestNom',
              style: const TextStyle(
                fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.texteDoux),
            ),
          ),
          const SizedBox(height: 24),

          // Ancien PIN
          const ChampLabel(label: 'Ancien PIN'),
          _ChampPin(
            ctrl:    ancienCtrl,
            visible: ancienVis,
            hint:    'Votre PIN actuel',
            onToggle: onToggleAncien,
          ),
          const SizedBox(height: 16),

          // Nouveau PIN
          const ChampLabel(label: 'Nouveau PIN'),
          _ChampPin(
            ctrl:    nouveauCtrl,
            visible: nouvVis,
            hint:    'Au moins 4 chiffres',
            onToggle: onToggleNouv,
          ),
          const SizedBox(height: 16),

          // Confirmation
          const ChampLabel(label: 'Confirmer le nouveau PIN'),
          _ChampPin(
            ctrl:    confirmCtrl,
            visible: confVis,
            hint:    'Répétez le nouveau PIN',
            onToggle: onToggleConf,
            onSubmit: onModifier,
          ),
          ChampErreur(texte: erreur),

          // Règles
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppColors.fondCode,
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Text(
              '• 4 à 6 chiffres requis\n'
              '• Interdit : 0000, 1111, 1234...\n'
              '• Différent de l\'ancien PIN\n'
              '• Ne partagez jamais votre PIN',
              style: TextStyle(fontSize: 12, color: AppColors.texteDoux, height: 1.6),
            ),
          ),

          const SizedBox(height: 20),
          BtnPrincipal(
            label:   'Enregistrer le nouveau PIN',
            icone:   Icons.lock_rounded,
            onTap:   onModifier,
            loading: loading,
          ),
        ],
      ),
    );
  }
}

// ─── Champ PIN réutilisable ────────────────────────────────────────────────
class _ChampPin extends StatelessWidget {
  final TextEditingController ctrl;
  final bool visible;
  final String hint;
  final VoidCallback onToggle;
  final VoidCallback? onSubmit;

  const _ChampPin({
    required this.ctrl,
    required this.visible,
    required this.hint,
    required this.onToggle,
    this.onSubmit,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: ctrl,
      keyboardType: TextInputType.number,
      obscureText: !visible,
      maxLength: 6,
      textAlign: TextAlign.center,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      decoration: InputDecoration(
        hintText: hint,
        counterText: '',
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        suffixIcon: IconButton(
          icon: Icon(
            visible ? Icons.visibility_off : Icons.visibility,
            color: AppColors.encreDoux, size: 18,
          ),
          onPressed: onToggle,
        ),
      ),
      style: const TextStyle(
        fontSize: 22, fontWeight: FontWeight.w700, letterSpacing: 6),
      onSubmitted: onSubmit != null ? (_) => onSubmit!() : null,
    );
  }
}

// ─── Vue de succès ─────────────────────────────────────────────────────────
class _VueSucces extends StatelessWidget {
  final VoidCallback onRetour;
  const _VueSucces({required this.onRetour});

  @override
  Widget build(BuildContext context) {
    return CarteTC(
      child: Column(
        children: [
          const SizedBox(height: 12),
          Container(
            width: 80, height: 80,
            decoration: const BoxDecoration(
              color: AppColors.succesFond, shape: BoxShape.circle),
            child: const Icon(Icons.check_circle_rounded,
                color: AppColors.succes, size: 46),
          ),
          const SizedBox(height: 20),
          const Text(
            'PIN modifié !',
            style: TextStyle(
              fontWeight: FontWeight.w800, fontSize: 24, color: AppColors.succes),
          ),
          const SizedBox(height: 12),
          const Text(
            'Votre nouveau PIN de gestion est actif.\n'
            'Un e-mail de confirmation vous a été envoyé.',
            style: TextStyle(
              fontSize: 14, color: AppColors.texteDoux, height: 1.6),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.alerteFond,
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Row(
              children: [
                Icon(Icons.info_outline, color: AppColors.alerte, size: 16),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Si vous n\'êtes pas à l\'origine de cette modification, '
                    'contactez le support immédiatement.',
                    style: TextStyle(fontSize: 12, color: AppColors.alerte, height: 1.4),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          BtnPrincipal(label: 'Retour', onTap: onRetour),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Widgets utilitaires
// ─────────────────────────────────────────────────────────────────────────────
class _SectionTitre extends StatelessWidget {
  final IconData icone;
  final String   titre;
  const _SectionTitre({required this.icone, required this.titre});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icone, size: 18, color: AppColors.encre),
        const SizedBox(width: 8),
        Text(titre,
          style: const TextStyle(
            fontWeight: FontWeight.w800, fontSize: 15, color: AppColors.encre)),
      ],
    );
  }
}

class _CarteOption extends StatelessWidget {
  final IconData icone;
  final Color    couleurIcone;
  final String   titre;
  final String   description;
  final VoidCallback onTap;

  const _CarteOption({
    required this.icone,
    required this.couleurIcone,
    required this.titre,
    required this.description,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: CarteTC(
        child: Row(
          children: [
            Container(
              width: 44, height: 44,
              decoration: BoxDecoration(
                color: couleurIcone.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icone, color: couleurIcone, size: 22),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(titre,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                      color: AppColors.encre,
                    )),
                  const SizedBox(height: 2),
                  Text(description,
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.texteDoux,
                      height: 1.4,
                    )),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded,
                color: AppColors.texteDoux, size: 20),
          ],
        ),
      ),
    );
  }
}
