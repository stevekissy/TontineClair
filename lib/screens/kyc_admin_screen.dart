// ═══════════════════════════════════════════════════════════════════════════
// TontineClair — Interface Admin KYC
// Accessible depuis le tableau de bord admin
// ═══════════════════════════════════════════════════════════════════════════

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/kyc_model.dart';
import '../services/kyc_service.dart';
import '../utils/app_colors.dart';
import '../widgets/app_widgets.dart';

class KycAdminScreen extends StatefulWidget {
  final String cleAdmin;
  final String adminNom;
  /// true = intégré dans un onglet admin (pas de Scaffold propre, pas de bouton retour)
  final bool modeOnglet;

  const KycAdminScreen({
    super.key,
    required this.cleAdmin,
    this.adminNom = 'Admin TontineClair',
    this.modeOnglet = false,
  });

  @override
  State<KycAdminScreen> createState() => _KycAdminScreenState();
}

class _KycAdminScreenState extends State<KycAdminScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  Map<String, dynamic>? _stats;
  List<Map<String, dynamic>> _liste = [];
  bool _loading = true;
  String _filtreStatus = 'tous';

  static const _filtres = [
    ('tous',         'Tous'),
    ('pending',      'En attente'),
    ('processing',   'En analyse'),
    ('manual_review','Manuel'),
    ('rejected',     'Refusés'),
    ('verified',     'Vérifiés'),
  ];

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    _charger();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _charger() async {
    setState(() => _loading = true);
    final stats = await KycService.adminStats(widget.cleAdmin);
    final liste = await KycService.adminList(
      widget.cleAdmin,
      status: _filtreStatus,
    );
    if (mounted) {
      setState(() {
        _stats = stats;
        _liste = liste;
        _loading = false;
      });
    }
  }

  Future<void> _demanderReset(Map<String, dynamic> kyc) async {
    final raisonCtrl = TextEditingController();

    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Demander une nouvelle vérification',
          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Utilisateur : ${kyc['user_id']}',
              style: const TextStyle(fontSize: 13, color: AppColors.texteDoux)),
            const SizedBox(height: 16),
            const Text('Motif (obligatoire) :',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            TextFormField(
              controller: raisonCtrl,
              maxLines: 3,
              decoration: InputDecoration(
                hintText: 'Ex : Document illisible, photo floue...',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                contentPadding: const EdgeInsets.all(12),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Annuler',
              style: TextStyle(color: AppColors.texteDoux)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Confirmer',
              style: TextStyle(color: AppColors.alerte, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );

    if (confirm != true || raisonCtrl.text.trim().isEmpty) return;

    final ok = await KycService.adminRequestReset(
      cleAdmin: widget.cleAdmin,
      kycId:    kyc['id'] as String,
      reason:   raisonCtrl.text.trim(),
      adminNom: widget.adminNom,
    );

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok
        ? 'L\'utilisateur sera invité à recommencer son KYC.'
        : 'Erreur lors de la demande de réinitialisation.'),
      backgroundColor: ok ? AppColors.succes : AppColors.alerte,
    ));

    if (ok) _charger();
  }

  @override
  Widget build(BuildContext context) {
    final corps = _loading
        ? const Center(child: CircularProgressIndicator(color: AppColors.or))
        : TabBarView(
            controller: _tabs,
            children: [
              _DashboardTab(stats: _stats),
              _ListeTab(
                liste: _liste,
                filtreStatus: _filtreStatus,
                filtres: _filtres,
                onFiltreChanged: (f) {
                  setState(() => _filtreStatus = f);
                  _charger();
                },
                onDemanderReset: _demanderReset,
              ),
            ],
          );

    // ── Mode onglet : pas de Scaffold ni AppBar redondants ──────────────────
    if (widget.modeOnglet) {
      return Column(
        children: [
          // Entête compact
          Container(
            color: AppColors.fondPapier,
            padding: const EdgeInsets.fromLTRB(16, 12, 4, 0),
            child: Row(
              children: [
                const Icon(Icons.verified_user_outlined,
                    color: AppColors.encre, size: 20),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Vérification KYC Smile ID',
                    style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 16,
                        color: AppColors.encre),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.refresh_rounded, color: AppColors.encre),
                  onPressed: _charger,
                  tooltip: 'Actualiser',
                ),
              ],
            ),
          ),
          // Onglets dashboard / dossiers
          Material(
            color: AppColors.fondPapier,
            child: TabBar(
              controller: _tabs,
              labelColor: AppColors.or,
              unselectedLabelColor: AppColors.texteDoux,
              indicatorColor: AppColors.or,
              tabs: const [
                Tab(text: 'Tableau de bord'),
                Tab(text: 'Dossiers'),
              ],
            ),
          ),
          const Divider(height: 1, color: AppColors.lignes),
          Expanded(child: corps),
        ],
      );
    }

    // ── Mode plein écran (route push) ───────────────────────────────────────
    return Scaffold(
      backgroundColor: AppColors.fondPapier,
      appBar: AppBar(
        backgroundColor: AppColors.fondPapier,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded, color: AppColors.encre),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text(
          'Gestion KYC',
          style: TextStyle(
              color: AppColors.encre, fontWeight: FontWeight.w800, fontSize: 18),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded, color: AppColors.encre),
            onPressed: _charger,
          ),
        ],
        bottom: TabBar(
          controller: _tabs,
          labelColor: AppColors.or,
          unselectedLabelColor: AppColors.texteDoux,
          indicatorColor: AppColors.or,
          tabs: const [
            Tab(text: 'Tableau de bord'),
            Tab(text: 'Dossiers'),
          ],
        ),
      ),
      body: corps,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Onglet Tableau de bord
// ─────────────────────────────────────────────────────────────────────────
class _DashboardTab extends StatelessWidget {
  final Map<String, dynamic>? stats;
  const _DashboardTab({this.stats});

  @override
  Widget build(BuildContext context) {
    if (stats == null) {
      return const Center(
        child: Text('Impossible de charger les statistiques.',
          style: TextStyle(color: AppColors.texteDoux)),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Statistiques KYC',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18, color: AppColors.encre)),
          const SizedBox(height: 16),
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            childAspectRatio: 1.4,
            children: [
              _StatCard('Total', '${stats!['total'] ?? 0}',
                Icons.people_rounded, AppColors.encreDoux),
              _StatCard('Non vérifiés', '${stats!['not_started'] ?? 0}',
                Icons.badge_outlined, AppColors.texteDoux),
              _StatCard('En attente', '${(stats!['pending'] ?? 0) + (stats!['processing'] ?? 0)}',
                Icons.hourglass_top_rounded, AppColors.or),
              _StatCard('Vérifiés', '${stats!['verified'] ?? 0}',
                Icons.verified_rounded, AppColors.succes),
              _StatCard('Refusés', '${stats!['rejected'] ?? 0}',
                Icons.cancel_rounded, AppColors.alerte),
              _StatCard('Revue manuelle', '${stats!['manual_review'] ?? 0}',
                Icons.support_agent_rounded, Colors.orange),
            ],
          ),
          const SizedBox(height: 24),

          CarteTC(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Information importante',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: AppColors.encre)),
                const SizedBox(height: 10),
                const Text(
                  '⚠️ Les administrateurs ne peuvent pas marquer manuellement un utilisateur comme "Vérifié" sans passage par le système de vérification Smile ID.\n\n'
                  '✓ Toute action manuelle (demande de recommencer, etc.) est enregistrée dans le journal d\'audit avec l\'identifiant de l\'administrateur responsable.\n\n'
                  '🔒 Vous ne voyez ici que le statut et les métadonnées — jamais les images des documents.',
                  style: TextStyle(fontSize: 13, color: AppColors.texteDoux, height: 1.6),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  final String label, value;
  final IconData icon;
  final Color color;
  const _StatCard(this.label, this.value, this.icon, this.color);

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(14),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.04),
          blurRadius: 8, offset: const Offset(0, 2),
        ),
      ],
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, color: color, size: 22),
        const SizedBox(height: 8),
        Text(value,
          style: TextStyle(
            fontWeight: FontWeight.w900, fontSize: 26, color: color)),
        Text(label,
          style: const TextStyle(
            fontSize: 12, color: AppColors.texteDoux, fontWeight: FontWeight.w500)),
      ],
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────
// Onglet Liste des dossiers
// ─────────────────────────────────────────────────────────────────────────
class _ListeTab extends StatelessWidget {
  final List<Map<String, dynamic>> liste;
  final String filtreStatus;
  final List<(String, String)> filtres;
  final ValueChanged<String> onFiltreChanged;
  final ValueChanged<Map<String, dynamic>> onDemanderReset;

  const _ListeTab({
    required this.liste,
    required this.filtreStatus,
    required this.filtres,
    required this.onFiltreChanged,
    required this.onDemanderReset,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Filtres
        SizedBox(
          height: 48,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            itemCount: filtres.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (_, i) {
              final (code, label) = filtres[i];
              final selected = filtreStatus == code;
              return GestureDetector(
                onTap: () => onFiltreChanged(code),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  decoration: BoxDecoration(
                    color: selected ? AppColors.or : Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: selected ? AppColors.or : AppColors.lignes),
                  ),
                  child: Text(label,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: selected ? Colors.white : AppColors.encre,
                    )),
                ),
              );
            },
          ),
        ),

        Expanded(
          child: liste.isEmpty
              ? const Center(child: Text('Aucun dossier trouvé.',
                  style: TextStyle(color: AppColors.texteDoux)))
              : ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: liste.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (_, i) => _KycDossierCard(
                    kyc: liste[i],
                    onDemanderReset: () => onDemanderReset(liste[i]),
                  ),
                ),
        ),
      ],
    );
  }
}

class _KycDossierCard extends StatelessWidget {
  final Map<String, dynamic> kyc;
  final VoidCallback onDemanderReset;
  const _KycDossierCard({required this.kyc, required this.onDemanderReset});

  @override
  Widget build(BuildContext context) {
    final status  = KycStatus.fromString(kyc['status'] as String?);
    final userId  = kyc['user_id'] as String? ?? '—';
    final docType = kyc['document_type'] != null
        ? KycDocumentType.fromString(kyc['document_type'] as String).label
        : '—';
    final country  = kyc['document_country'] as String? ?? '—';
    final updated  = kyc['updated_at'] != null
        ? DateFormat('dd/MM/yyyy HH:mm')
            .format(DateTime.parse(kyc['updated_at'] as String).toLocal())
        : '—';
    final reason = kyc['rejection_reason'] as String?;

    final (statusColor, statusBg) = switch (status) {
      KycStatus.verified     => (AppColors.succes,    AppColors.succesFond),
      KycStatus.rejected     => (AppColors.alerte,    AppColors.alerteFond),
      KycStatus.pending      => (AppColors.or,        const Color(0xFFFDF3E2)),
      KycStatus.processing   => (AppColors.encreDoux, AppColors.fondGestion),
      KycStatus.manualReview => (Colors.orange,       const Color(0xFFFFF3E0)),
      KycStatus.notStarted   => (AppColors.texteDoux, AppColors.fondSecondaire),
    };

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 8, offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(userId,
                    style: const TextStyle(
                      fontWeight: FontWeight.w800, fontSize: 15, color: AppColors.encre)),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: statusBg,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(status.label,
                    style: TextStyle(
                      fontSize: 11, fontWeight: FontWeight.w700, color: statusColor)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(children: [
              _Chip(Icons.badge_outlined, docType),
              const SizedBox(width: 8),
              _Chip(Icons.flag_outlined, country),
              const SizedBox(width: 8),
              _Chip(Icons.schedule_rounded, updated),
            ]),

            if (reason != null) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.alerteFond,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.warning_amber_rounded,
                        size: 14, color: AppColors.alerte),
                    const SizedBox(width: 6),
                    Expanded(child: Text(reason,
                      style: const TextStyle(fontSize: 12, color: AppColors.alerte))),
                  ],
                ),
              ),
            ],

            // Actions admin
            if (status != KycStatus.verified && status != KycStatus.notStarted) ...[
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  OutlinedButton.icon(
                    onPressed: onDemanderReset,
                    icon: const Icon(Icons.refresh_rounded, size: 14),
                    label: const Text('Demander recommencer',
                      style: TextStyle(fontSize: 12)),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.alerte,
                      side: const BorderSide(color: AppColors.alerte),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final IconData icon;
  final String text;
  const _Chip(this.icon, this.text);
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 12, color: AppColors.texteDoux),
      const SizedBox(width: 3),
      Text(text, style: const TextStyle(fontSize: 11, color: AppColors.texteDoux)),
    ],
  );
}
