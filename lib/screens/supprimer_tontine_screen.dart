import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/tontine_provider.dart';
import '../utils/app_colors.dart';
import '../widgets/app_widgets.dart';

/// Écran de suppression logique (soft delete) d'une tontine.
/// Accessible depuis detail_screen → Zone Dangereuse.
/// Conditions : gestionnaire actif + PIN + motif + confirmation du nom exact.
class SupprimerTontineScreen extends StatefulWidget {
  final String code;
  final String nomTontine;

  const SupprimerTontineScreen({
    super.key,
    required this.code,
    required this.nomTontine,
  });

  @override
  State<SupprimerTontineScreen> createState() => _SupprimerTontineScreenState();
}

class _SupprimerTontineScreenState extends State<SupprimerTontineScreen> {
  final _formKey        = GlobalKey<FormState>();
  final _ctrlMotif      = TextEditingController();
  final _ctrlPin        = TextEditingController();
  final _ctrlConfirm    = TextEditingController();

  bool _pinVisible      = false;
  bool _enCours         = false;
  String? _erreur;

  // Étapes : 0=avertissement, 1=formulaire, 2=succès
  int _etape = 0;

  @override
  void dispose() {
    _ctrlMotif.dispose();
    _ctrlPin.dispose();
    _ctrlConfirm.dispose();
    super.dispose();
  }

  Future<void> _confirmerSuppression() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() { _enCours = true; _erreur = null; });

    final provider = context.read<TontineProvider>();
    final result = await provider.supprimerTontine(
      pin:             _ctrlPin.text.trim(),
      raison:          _ctrlMotif.text.trim(),
      nomConfirmation: _ctrlConfirm.text.trim(),
    );

    if (!mounted) return;

    if (result['ok'] == true) {
      setState(() { _etape = 2; _enCours = false; });
    } else {
      setState(() {
        _erreur = result['erreur'] as String?
            ?? result['message'] as String?
            ?? 'Une erreur est survenue.';
        _enCours = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.fondPapier,
      appBar: AppBar(
        backgroundColor: AppColors.fondPapier,
        elevation: 0,
        leading: _etape == 2
            ? const SizedBox.shrink()
            : IconButton(
                icon: const Icon(Icons.arrow_back_rounded, color: AppColors.encre),
                onPressed: () => Navigator.of(context).pop(),
              ),
        title: const Text(
          'Supprimer la tontine',
          style: TextStyle(
            color: AppColors.encre,
            fontWeight: FontWeight.w700,
            fontSize: 17,
          ),
        ),
      ),
      body: SafeArea(
        child: _etape == 0
            ? _VueAvertissement()
            : _etape == 1
                ? _VueFormulaire()
                : _VueSucces(),
      ),
    );
  }

  // ─── Étape 0 : Avertissement ─────────────────────────────────────────────

  Widget _VueAvertissement() {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Badge zone dangereuse
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.alerte.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.alerte.withValues(alpha: 0.4), width: 1.5),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: AppColors.alerte,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Text(
                        '⚠️  Zone dangereuse',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Text(
                  'Supprimer « ${widget.nomTontine} »',
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    color: AppColors.encre,
                  ),
                ),
                const SizedBox(height: 10),
                const Text(
                  'Cette action rendra la tontine inaccessible à tous les membres. '
                  'Le code d\'invitation sera désactivé et aucune nouvelle opération '
                  'ne sera possible.\n\n'
                  'L\'historique restera conservé dans l\'espace administrateur.',
                  style: TextStyle(
                    fontSize: 14,
                    color: AppColors.texte,
                    height: 1.6,
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 20),

          // Ce qui va se passer
          const Text(
            'Ce qui va se passer :',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: AppColors.encre,
            ),
          ),
          const SizedBox(height: 10),
          ...[
            'La tontine disparaîtra immédiatement de la liste des membres',
            'Le code d\'invitation sera immédiatement invalidé',
            'Aucune cotisation, distribution ou prêt ne sera plus possible',
            'Les sessions actives seront redirigées vers l\'accueil',
            'L\'historique financier et le journal d\'audit seront conservés',
            'Seul un Super Administrateur peut restaurer la tontine',
          ].map((item) => Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.circle, size: 7, color: AppColors.alerte),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    item,
                    style: const TextStyle(
                      fontSize: 13.5,
                      color: AppColors.texte,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          )),

          const SizedBox(height: 28),

          // Boutons
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () => setState(() => _etape = 1),
              icon: const Icon(Icons.delete_forever_rounded, size: 18),
              label: const Text(
                'Continuer vers la suppression',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.alerte,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: () => Navigator.of(context).pop(),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 13),
                side: const BorderSide(color: AppColors.lignes),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text(
                'Annuler',
                style: TextStyle(color: AppColors.encre, fontWeight: FontWeight.w600),
              ),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  // ─── Étape 1 : Formulaire ────────────────────────────────────────────────

  Widget _VueFormulaire() {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Erreur globale
            if (_erreur != null) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.alerteFond,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppColors.alerte.withValues(alpha: 0.4)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.error_outline_rounded,
                        color: AppColors.alerte, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _erreur!,
                        style: const TextStyle(
                          color: AppColors.alerte, fontSize: 13.5,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],

            // ── 1. Motif ──────────────────────────────────────────────
            const ChampLabel(label: 'Motif de suppression *'),
            TextFormField(
              controller: _ctrlMotif,
              maxLines: 3,
              decoration: InputDecoration(
                hintText: 'Ex : Tontine terminée, dissolution du groupe…',
                hintStyle: const TextStyle(color: AppColors.texteDoux, fontSize: 13),
                filled: true,
                fillColor: Colors.white,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: AppColors.lignes),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: AppColors.lignes),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: AppColors.encre, width: 1.5),
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              ),
              validator: (v) {
                if (v == null || v.trim().length < 5) {
                  return 'Le motif est obligatoire (minimum 5 caractères).';
                }
                return null;
              },
            ),
            const SizedBox(height: 16),

            // ── 2. PIN gestionnaire ──────────────────────────────────
            const ChampLabel(label: 'PIN gestionnaire *'),
            TextFormField(
              controller: _ctrlPin,
              obscureText: !_pinVisible,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                hintText: 'Votre PIN',
                hintStyle: const TextStyle(color: AppColors.texteDoux, fontSize: 13),
                filled: true,
                fillColor: Colors.white,
                suffixIcon: IconButton(
                  icon: Icon(
                    _pinVisible ? Icons.visibility_off_rounded : Icons.visibility_rounded,
                    color: AppColors.encreDoux,
                  ),
                  onPressed: () => setState(() => _pinVisible = !_pinVisible),
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: AppColors.lignes),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: AppColors.lignes),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: AppColors.encre, width: 1.5),
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              ),
              validator: (v) {
                if (v == null || v.trim().length < 4) {
                  return 'PIN invalide (minimum 4 chiffres).';
                }
                return null;
              },
            ),
            const SizedBox(height: 16),

            // ── 3. Confirmation du nom ───────────────────────────────
            ChampLabel(label: 'Tapez le nom exact : « ${widget.nomTontine} » *'),
            TextFormField(
              controller: _ctrlConfirm,
              decoration: InputDecoration(
                hintText: widget.nomTontine,
                hintStyle: const TextStyle(color: AppColors.texteDoux, fontSize: 13),
                filled: true,
                fillColor: Colors.white,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: AppColors.lignes),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: AppColors.lignes),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: AppColors.alerte, width: 1.5),
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              ),
              validator: (v) {
                if (v == null || v.trim().isEmpty) {
                  return 'Ce champ est obligatoire.';
                }
                if (v.trim().toLowerCase() != widget.nomTontine.toLowerCase()) {
                  return 'Le nom saisi ne correspond pas. Vérifiez la casse.';
                }
                return null;
              },
            ),
            const SizedBox(height: 28),

            // Bouton confirmer
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _enCours ? null : _confirmerSuppression,
                icon: _enCours
                    ? const SizedBox(
                        width: 16, height: 16,
                        child: CircularProgressIndicator(
                          color: Colors.white, strokeWidth: 2,
                        ),
                      )
                    : const Icon(Icons.delete_forever_rounded, size: 18),
                label: Text(
                  _enCours ? 'Suppression en cours…' : 'Confirmer la suppression',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.alerte,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: AppColors.alerte.withValues(alpha: 0.5),
                  disabledForegroundColor: Colors.white.withValues(alpha: 0.7),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: _enCours ? null : () => Navigator.of(context).pop(),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  side: const BorderSide(color: AppColors.lignes),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: const Text(
                  'Annuler',
                  style: TextStyle(color: AppColors.encre, fontWeight: FontWeight.w600),
                ),
              ),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  // ─── Étape 2 : Succès ────────────────────────────────────────────────────

  Widget _VueSucces() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: AppColors.succesFond,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.check_circle_outline_rounded,
                size: 44,
                color: AppColors.succes,
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              'Tontine supprimée',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w800,
                color: AppColors.encre,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            const Text(
              'La tontine a été supprimée avec succès.\n'
              'Son code d\'invitation est désormais invalide.\n\n'
              'Elle n\'apparaît plus dans la liste des membres.\n'
              'L\'historique reste conservé dans l\'espace administrateur.',
              style: TextStyle(
                fontSize: 14.5,
                color: AppColors.texte,
                height: 1.6,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () {
                  // Retourner jusqu'à l'accueil (pop toutes les routes empilées)
                  Navigator.of(context).popUntil((route) => route.isFirst);
                },
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.encre,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: const Text(
                  'Retour à l\'accueil',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
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
