import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/tontine.dart';
import '../services/tontine_provider.dart';
import '../services/mandat_service.dart';
import '../utils/app_colors.dart';
import '../utils/formatters.dart' show Formatters;
import '../widgets/app_widgets.dart';

/// Écran de gestion du Mode Gestion (Libre ↔ Mandat).
///
/// Accessible uniquement aux gestionnaires depuis l'écran Détail.
class MandatScreen extends StatefulWidget {
  final String code;

  const MandatScreen({super.key, required this.code});

  @override
  State<MandatScreen> createState() => _MandatScreenState();
}

class _MandatScreenState extends State<MandatScreen> {
  bool _enChargement = false;

  // ── PIN dialog ─────────────────────────────────────────────────────────────

  Future<String?> _demanderPin() async {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Confirmer le PIN'),
        content: TextField(
          controller: ctrl,
          obscureText: true,
          keyboardType: TextInputType.number,
          maxLength: 6,
          decoration: const InputDecoration(
            hintText: 'PIN gestionnaire',
            counterText: '',
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Annuler'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Confirmer',
                style: TextStyle(fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }

  // ── Basculement de mode ─────────────────────────────────────────────────────

  Future<void> _basculer(String nouveauMode, TontineData data, String gestNom) async {
    // Confirmation explicite avant basculement
    final libelle = nouveauMode == 'mandat' ? 'Mode Mandat' : 'Mode Libre';
    final confirme = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Activer le $libelle ?'),
        content: nouveauMode == 'mandat'
            ? const Text(
                'En activant le Mode Mandat :\n\n'
                '• Une commission de 1% sera prélevée sur chaque décaissement\n'
                '• Un forfait de 1 500 FCFA/mois est dû\n'
                '• Les paiements réels seront activés\n\n'
                'Vous pouvez revenir au Mode Libre à tout moment.',
              )
            : const Text(
                'En revenant au Mode Libre :\n\n'
                '• Plus aucune commission sur les décaissements\n'
                '• Plus de forfait mensuel\n'
                '• Les paiements réels seront désactivés\n\n'
                'Vous pouvez repasser en Mode Mandat à tout moment.',
              ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: nouveauMode == 'mandat'
                  ? AppColors.or
                  : AppColors.encre,
            ),
            child: Text('Activer le $libelle'),
          ),
        ],
      ),
    );

    if (confirme != true || !mounted) return;

    final pin = await _demanderPin();
    if (pin == null || pin.isEmpty || !mounted) return;

    setState(() => _enChargement = true);

    final erreur = await MandatService.basculerMode(
      code:         widget.code,
      nom:          gestNom,
      pin:          pin,
      nouveauMode:  nouveauMode,
      data:         data,
    );

    if (!mounted) return;
    setState(() => _enChargement = false);

    if (erreur != null) {
      afficherToast(context, erreur, estErreur: true);
    } else {
      // Recharge la tontine pour mettre à jour l'état local
      await Provider.of<TontineProvider>(context, listen: false)
          .chargerTontine(widget.code);
      if (!mounted) return;
      afficherToast(
        context,
        nouveauMode == 'mandat'
            ? '✅ Mode Mandat activé'
            : '✅ Mode Libre activé',
      );
    }
  }

  // ── Build ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<TontineProvider>(context);
    final tontine  = provider.courante;
    if (tontine == null) return const SizedBox();

    final data       = tontine.data;
    final estMandat  = tontine.estSousMandat;
    final gestNom    = provider.gestActifNom ?? '';
    final estGest    = tontine.data.gestionnaires.any((g) => g.nom == gestNom);

    return Scaffold(
      backgroundColor: AppColors.fondPapier,
      appBar: AppBar(
        backgroundColor: AppColors.fondPapier,
        elevation: 0,
        title: const Text(
          'Mode Gestion',
          style: TextStyle(
            fontWeight: FontWeight.w700,
            color: AppColors.encre,
          ),
        ),
        iconTheme: const IconThemeData(color: AppColors.encre),
      ),
      body: _enChargement
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // ── Mode actuel ───────────────────────────────────────────
                  _CarteModeCourant(estMandat: estMandat),
                  const SizedBox(height: 24),

                  // ── Comparatif des deux modes ─────────────────────────────
                  _CarteComparatif(),
                  const SizedBox(height: 28),

                  // ── Bouton de basculement ─────────────────────────────────
                  if (estGest) ...[
                    if (estMandat) ...[
                      OutlinedButton.icon(
                        onPressed: () => _basculer('libre', data, gestNom),
                        icon: const Icon(Icons.lock_open_rounded),
                        label: const Text('Revenir au Mode Libre'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.encre,
                          side: const BorderSide(color: AppColors.encre),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                    ] else ...[
                      FilledButton.icon(
                        onPressed: () => _basculer('mandat', data, gestNom),
                        icon: const Icon(Icons.verified_rounded),
                        label: const Text('Activer le Mode Mandat'),
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.or,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    Text(
                      'Un PIN gestionnaire sera requis pour confirmer.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 12,
                        color: AppColors.texte.withValues(alpha: 0.6),
                      ),
                    ),
                  ],

                  // ── Section forfait mandat ────────────────────────────────
                  if (estMandat) ...[
                    const SizedBox(height: 28),
                    _CarteForfaitMandat(),
                  ],
                ],
              ),
            ),
    );
  }
}

// ── Widget : carte mode courant ────────────────────────────────────────────────

class _CarteModeCourant extends StatelessWidget {
  final bool estMandat;
  const _CarteModeCourant({required this.estMandat});

  @override
  Widget build(BuildContext context) {
    final couleur = estMandat ? AppColors.or : AppColors.succes;
    final icone   = estMandat ? Icons.verified_rounded : Icons.lock_open_rounded;
    final label   = estMandat ? 'Gestion sous Mandat' : 'Gestion Libre';
    final desc    = estMandat
        ? 'Paiements réels activés — commission 1% sur décaissements'
        : 'Mode gratuit — sans commission ni forfait mensuel';

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: couleur.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: couleur.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: couleur.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icone, color: couleur, size: 28),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Text(
                      'Mode actuel',
                      style: TextStyle(
                        fontSize: 12,
                        color: AppColors.texte,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: couleur,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        estMandat ? 'MANDAT' : 'LIBRE',
                        style: const TextStyle(
                          fontSize: 10,
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: AppColors.encre,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  desc,
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.texte.withValues(alpha: 0.7),
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

// ── Widget : comparatif des deux modes ────────────────────────────────────────

class _CarteComparatif extends StatelessWidget {
  const _CarteComparatif();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.encre.withValues(alpha: 0.1)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        children: [
          // En-têtes
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: AppColors.encre.withValues(alpha: 0.04),
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(16),
                topRight: Radius.circular(16),
              ),
            ),
            child: Row(
              children: [
                const Expanded(
                  flex: 3,
                  child: Text('Fonctionnalité',
                      style: TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 13)),
                ),
                Expanded(
                  flex: 2,
                  child: Center(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.lock_open_rounded,
                            size: 14,
                            color:
                                AppColors.succes),
                        const SizedBox(width: 4),
                        const Text('Libre',
                            style: TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 13)),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: Center(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.verified_rounded,
                            size: 14, color: AppColors.or),
                        const SizedBox(width: 4),
                        const Text('Mandat',
                            style: TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 13)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Lignes comparatif
          ..._lignes.map(
            (l) => _LigneComparatif(
              label:   l[0],
              libre:   l[1],
              mandat:  l[2],
              isCheck: l[3] == 'check',
            ),
          ),
        ],
      ),
    );
  }

  static const List<List<String>> _lignes = [
    ['Toutes fonctionnalités',   '✅', '✅',               'check'],
    ['Paiement réel',            '❌', '✅',               'check'],
    ['Commission décaissements', '0%', '1%',               'text'],
    ['Forfait mensuel',          'Gratuit', '1 500 FCFA',  'text'],
    ['Basculement libre',        'N/A', '✅ Réversible',   'check'],
  ];
}

class _LigneComparatif extends StatelessWidget {
  final String label;
  final String libre;
  final String mandat;
  final bool isCheck;

  const _LigneComparatif({
    required this.label,
    required this.libre,
    required this.mandat,
    required this.isCheck,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
              color: AppColors.encre.withValues(alpha: 0.06)),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Text(
              label,
              style: const TextStyle(fontSize: 13, color: AppColors.texte),
            ),
          ),
          Expanded(
            flex: 2,
            child: Center(
              child: Text(
                libre,
                style: TextStyle(
                  fontSize: 13,
                  color: libre == '❌'
                      ? Colors.red.shade400
                      : AppColors.encre,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
          Expanded(
            flex: 2,
            child: Center(
              child: Text(
                mandat,
                style: TextStyle(
                  fontSize: 13,
                  color: mandat.startsWith('✅')
                      ? AppColors.succes
                      : AppColors.or,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Widget : carte forfait mandat ──────────────────────────────────────────────

class _CarteForfaitMandat extends StatelessWidget {
  const _CarteForfaitMandat();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            AppColors.or.withValues(alpha: 0.12),
            AppColors.or.withValues(alpha: 0.05),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.or.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.receipt_long_rounded,
                  color: AppColors.or, size: 20),
              const SizedBox(width: 8),
              const Text(
                'Forfait Mandat',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: AppColors.encre,
                  fontSize: 15,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Forfait mensuel',
                style: TextStyle(color: AppColors.texte, fontSize: 14),
              ),
              Text(
                Formatters.montant(MandatService.forfaitMensuelFCFA, devise: 'XOF'),
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 16,
                  color: AppColors.or,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: const [
              Text(
                'Commission sur décaissements',
                style: TextStyle(color: AppColors.texte, fontSize: 14),
              ),
              Text(
                '1%',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 16,
                  color: AppColors.or,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () {
                // Navigation vers AbonnementScreen pour payer le forfait
                Navigator.pushNamed(context, '/abonnement');
              },
              icon: const Icon(Icons.payment_rounded, size: 18),
              label: const Text('Payer le forfait'),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.or,
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
