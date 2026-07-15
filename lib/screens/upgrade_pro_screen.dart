import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/tontine.dart';
import '../services/tontine_provider.dart';
import '../services/supabase_service.dart';
import '../utils/app_colors.dart';
import '../utils/formatters.dart';
import '../widgets/app_widgets.dart';

/// Écran "Passer en Pro" — migration Lite → Pro IRRÉVERSIBLE.
///
/// Accessible uniquement aux gestionnaires.
/// Affiche un avertissement explicite, les conditions, puis demande
/// la confirmation PIN avant d'écrire tier='pro' en base.
class UpgradeProScreen extends StatefulWidget {
  final String code;

  const UpgradeProScreen({super.key, required this.code});

  @override
  State<UpgradeProScreen> createState() => _UpgradeProScreenState();
}

class _UpgradeProScreenState extends State<UpgradeProScreen> {
  bool _enChargement = false;
  bool _checkboxLu   = false;

  // ── Couleur Pro ─────────────────────────────────────────────────────────────
  static const _couleurPro = Color(0xFF1A6B3C); // vert foncé Pro

  // ── Confirmation + PIN ──────────────────────────────────────────────────────

  Future<String?> _demanderPin() async {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.fondPapier,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: const Text(
          '🔐 Confirmer le PIN',
          style: TextStyle(fontWeight: FontWeight.w700, color: AppColors.encre),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Cette action est irréversible.\nEntrez votre PIN gestionnaire pour confirmer.',
              style: TextStyle(color: AppColors.texte, fontSize: 13, height: 1.5),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: ctrl,
              obscureText: true,
              keyboardType: TextInputType.number,
              maxLength: 6,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: 'PIN gestionnaire',
                counterText: '',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            style: FilledButton.styleFrom(backgroundColor: _couleurPro),
            child: const Text('Passer en Pro'),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmerUpgrade(TontineProvider provider, String gestNom) async {
    final pin = await _demanderPin();
    if (pin == null || pin.isEmpty || !mounted) return;

    setState(() => _enChargement = true);

    // Préparer les données avec tier = 'pro'
    final data = provider.courante!.data;
    final newData = data.toJson();
    newData['tier'] = 'pro';

    // Journal
    final journal = List<Map<String, dynamic>>.from(
      (newData['journal'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ?? [],
    );
    journal.insert(0, {
      'quoi': '🚀 Tontine passée en version Pro — paiements réels activés via SycaPay',
      'par':  gestNom,
      'le':   DateTime.now().millisecondsSinceEpoch,
    });
    newData['journal'] = journal;

    final ok = await SupabaseService.ecrireTontine(
      code: widget.code,
      nom:  gestNom,
      pin:  pin,
      data: newData,
    );

    if (!mounted) return;
    setState(() => _enChargement = false);

    if (!ok) {
      afficherToast(context, 'PIN incorrect ou erreur réseau.', estErreur: true);
      return;
    }

    // Recharger + notification
    await provider.chargerTontine(widget.code);
    if (!mounted) return;

    // Notification push
    final tNotif = SupabaseService.notifTexte('passage_pro', 'fr');
    SupabaseService.envoyerNotification(
      code:    widget.code,
      type:    'passage_pro',
      titre:   tNotif['titre']!,
      message: tNotif['message']!,
    );

    afficherToast(context, '🚀 Tontine passée en version Pro !');
    if (mounted) Navigator.pop(context);
  }

  // ── Build ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<TontineProvider>(context);
    final tontine  = provider.courante;
    if (tontine == null) return const SizedBox();

    final gestNom = provider.gestActifNom ?? '';

    return Scaffold(
      backgroundColor: AppColors.fondPapier,
      appBar: AppBar(
        backgroundColor: AppColors.fondPapier,
        elevation: 0,
        title: const Text(
          'Passer en Pro',
          style: TextStyle(fontWeight: FontWeight.w700, color: AppColors.encre),
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
                  // ── Bandeau avertissement irréversibilité ──────────────
                  _BandeauAvertissement(),
                  const SizedBox(height: 24),

                  // ── Comparatif Lite / Pro ──────────────────────────────
                  _CarteComparatif(),
                  const SizedBox(height: 24),

                  // ── Ce qui change à partir du passage ─────────────────
                  _CarteChangements(),
                  const SizedBox(height: 24),

                  // ── Checkbox confirmation lecture ──────────────────────
                  _CheckboxConfirmation(
                    valeur: _checkboxLu,
                    onChange: (v) => setState(() => _checkboxLu = v ?? false),
                  ),
                  const SizedBox(height: 24),

                  // ── Bouton CTA ─────────────────────────────────────────
                  FilledButton.icon(
                    onPressed: _checkboxLu
                        ? () => _confirmerUpgrade(provider, gestNom)
                        : null,
                    icon: const Icon(Icons.rocket_launch_rounded),
                    label: const Text(
                      'Activer la version Pro',
                      style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                    ),
                    style: FilledButton.styleFrom(
                      backgroundColor: _couleurPro,
                      disabledBackgroundColor: AppColors.encre.withValues(alpha: 0.2),
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Un PIN gestionnaire sera requis pour confirmer.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.texte.withValues(alpha: 0.5),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

// ── Widgets internes ──────────────────────────────────────────────────────────

class _BandeauAvertissement extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.alerteFond,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.alerte.withValues(alpha: 0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, color: AppColors.alerte, size: 28),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Action irréversible',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 16,
                    color: AppColors.alerte,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Une fois passée en Pro, cette tontine ne peut JAMAIS revenir en Lite. '
                  'Cela est nécessaire pour garantir l\'intégrité des flux financiers réels.',
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.5,
                    color: AppColors.alerte.withValues(alpha: 0.85),
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

class _CarteComparatif extends StatelessWidget {
  static const _lignes = [
    ['Suivi cotisations',   '✅ Déclaratif',   '✅ Réel (SycaPay)'],
    ['Décaissement',        '✅ Déclaratif',   '✅ Demande validée'],
    ['Commission',          '❌ Aucune',        '✅ 1% (caisse)'],
    ['Paiement Mobile Money','❌',             '✅ Orange, Moov, MTN, Wave'],
    ['Historique conservé', '—',              '✅ Intégralement'],
    ['Retour en Lite',      '—',              '❌ Impossible'],
  ];

  const _CarteComparatif();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.lignes),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 6,
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
              color: AppColors.fondSecondaire,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(16),
                topRight: Radius.circular(16),
              ),
            ),
            child: Row(
              children: const [
                Expanded(flex: 3, child: Text('Fonctionnalité', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13))),
                Expanded(flex: 2, child: Center(child: Text('Lite', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppColors.texteDoux)))),
                Expanded(flex: 2, child: Center(child: Text('Pro', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: Color(0xFF1A6B3C))))),
              ],
            ),
          ),
          ..._lignes.map((l) => _LigneComp(label: l[0], lite: l[1], pro: l[2])),
        ],
      ),
    );
  }
}

class _LigneComp extends StatelessWidget {
  final String label, lite, pro;
  const _LigneComp({required this.label, required this.lite, required this.pro});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.lignes)),
      ),
      child: Row(
        children: [
          Expanded(flex: 3, child: Text(label, style: const TextStyle(fontSize: 13, color: AppColors.texte))),
          Expanded(
            flex: 2,
            child: Center(
              child: Text(lite, style: TextStyle(fontSize: 12, color: lite == '❌' ? AppColors.alerte : AppColors.texteDoux)),
            ),
          ),
          Expanded(
            flex: 2,
            child: Center(
              child: Text(pro, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF1A6B3C))),
            ),
          ),
        ],
      ),
    );
  }
}

class _CarteChangements extends StatelessWidget {
  const _CarteChangements();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFFEAF4EE),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF1A6B3C).withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.info_outline_rounded, color: Color(0xFF1A6B3C), size: 20),
              SizedBox(width: 8),
              Text('Ce qui change dès l\'activation', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: Color(0xFF1A6B3C))),
            ],
          ),
          const SizedBox(height: 12),
          ...[
            'Les membres paient leurs cotisations via Mobile Money directement dans l\'app.',
            'Le bénéficiaire de chaque tour reçoit 100% du pool — la commission de 1% est débitée séparément de la caisse.',
            'Le gestionnaire soumet une demande de décaissement. L\'admin TontineClair valide manuellement.',
            'L\'historique existant (membres, tours, votes) est intégralement conservé.',
          ].map((t) => Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('• ', style: TextStyle(color: Color(0xFF1A6B3C), fontWeight: FontWeight.w700)),
                Expanded(child: Text(t, style: const TextStyle(fontSize: 13, color: AppColors.texte, height: 1.5))),
              ],
            ),
          )),
        ],
      ),
    );
  }
}

class _CheckboxConfirmation extends StatelessWidget {
  final bool valeur;
  final ValueChanged<bool?> onChange;

  const _CheckboxConfirmation({required this.valeur, required this.onChange});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => onChange(!valeur),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: valeur ? const Color(0xFFEAF4EE) : AppColors.fondSecondaire,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: valeur
                ? const Color(0xFF1A6B3C).withValues(alpha: 0.4)
                : AppColors.lignes,
          ),
        ),
        child: Row(
          children: [
            Checkbox(
              value: valeur,
              onChanged: onChange,
              activeColor: const Color(0xFF1A6B3C),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
            ),
            const SizedBox(width: 8),
            const Expanded(
              child: Text(
                'J\'ai compris que cette action est irréversible. '
                'La tontine ne pourra jamais revenir en version Lite.',
                style: TextStyle(fontSize: 13, height: 1.4, color: AppColors.texte),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
