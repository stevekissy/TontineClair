import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/coinpayments_service.dart';
import '../utils/app_colors.dart';

/// Module TC Admin — CoinPayments
/// Accès complet à la gestion crypto sans jamais exposer les clés API.
/// Toutes les communications passent par les Edge Functions Supabase.
class CoinPaymentsAdminScreen extends StatefulWidget {
  final String cleAdmin;
  const CoinPaymentsAdminScreen({super.key, required this.cleAdmin});

  @override
  State<CoinPaymentsAdminScreen> createState() =>
      _CoinPaymentsAdminScreenState();
}

class _CoinPaymentsAdminScreenState extends State<CoinPaymentsAdminScreen>
    with SingleTickerProviderStateMixin {

  late final TabController _tabCtrl;

  // ── Données tableau de bord ───────────────────────────────────────────────
  Map<String, dynamic>? _config;
  bool _configLoading = true;

  // ── Données transactions ──────────────────────────────────────────────────
  List<Map<String, dynamic>> _transactions = [];
  bool   _txLoading   = false;
  String _txStatut    = 'tous';
  String _txCrypto    = 'tous';
  String _txType      = 'tous';
  String _txTontine   = '';
  int    _txTotal     = 0;
  int    _txCredited  = 0;
  int    _txPending   = 0;
  int    _txFailed    = 0;
  int    _txXof       = 0;

  // ── Données audit log ─────────────────────────────────────────────────────
  List<Map<String, dynamic>> _auditLogs  = [];
  bool   _auditLoading = false;
  String _auditSource  = 'tous';

  // ── Données rapprochement ─────────────────────────────────────────────────
  List<Map<String, dynamic>> _anomalies      = [];
  bool   _reconcLoading = false;
  int    _confirmedNotCredited = 0;
  int    _pendingTooLong       = 0;
  String? _reconcAt;

  // ── Action en cours ───────────────────────────────────────────────────────
  final Map<String, bool> _actionLoading = {};

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 5, vsync: this);
    _tabCtrl.addListener(() { if (!_tabCtrl.indexIsChanging) _onTabChange(_tabCtrl.index); });
    _chargerConfig();
    _chargerTransactions();
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    super.dispose();
  }

  void _onTabChange(int i) {
    if (i == 0 && _config == null)           _chargerConfig();
    if (i == 1 && _transactions.isEmpty)     _chargerTransactions();
    if (i == 2 && _auditLogs.isEmpty)        _chargerAudit();
    if (i == 3 && _anomalies.isEmpty)        _chargerRapprochement();
  }

  // ── Chargements ────────────────────────────────────────────────────────────

  Future<void> _chargerConfig() async {
    setState(() => _configLoading = true);
    try {
      final r = await CoinPaymentsService.adminAction('admin_config_status', {});
      if (mounted) setState(() { _config = r; _configLoading = false; });
    } catch (_) {
      if (mounted) setState(() => _configLoading = false);
    }
  }

  Future<void> _chargerTransactions({bool reset = false}) async {
    if (_txLoading) return;
    setState(() => _txLoading = true);
    try {
      final payload = <String, dynamic>{'action': 'admin_transactions', 'limit': 100};
      if (_txStatut  != 'tous') payload['statut']         = _txStatut;
      if (_txCrypto  != 'tous') payload['currency2']      = _txCrypto;
      if (_txType    != 'tous') payload['type_operation'] = _txType;
      if (_txTontine.isNotEmpty) payload['tontine_code']  = _txTontine.toUpperCase();
      final r = await CoinPaymentsService.adminAction('admin_transactions', payload);
      if (!mounted) return;
      setState(() {
        _transactions = List<Map<String, dynamic>>.from(r['transactions'] as List? ?? []);
        _txTotal    = (r['total']    as num?)?.toInt() ?? 0;
        _txCredited = (r['credited'] as num?)?.toInt() ?? 0;
        _txPending  = (r['pending']  as num?)?.toInt() ?? 0;
        _txFailed   = (r['failed']   as num?)?.toInt() ?? 0;
        _txXof      = (r['totalXof'] as num?)?.toInt() ?? 0;
        _txLoading  = false;
      });
    } catch (_) {
      if (mounted) setState(() => _txLoading = false);
    }
  }

  Future<void> _chargerAudit() async {
    if (_auditLoading) return;
    setState(() => _auditLoading = true);
    try {
      final payload = <String, dynamic>{'limit': 200};
      if (_auditSource != 'tous') payload['source'] = _auditSource;
      final r = await CoinPaymentsService.adminAction('admin_audit_log', payload);
      if (!mounted) return;
      setState(() {
        _auditLogs   = List<Map<String, dynamic>>.from(r['logs'] as List? ?? []);
        _auditLoading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _auditLoading = false);
    }
  }

  Future<void> _chargerRapprochement() async {
    if (_reconcLoading) return;
    setState(() => _reconcLoading = true);
    try {
      final r = await CoinPaymentsService.adminAction('admin_reconciliation', {});
      if (!mounted) return;
      setState(() {
        _anomalies           = List<Map<String, dynamic>>.from(r['anomalies'] as List? ?? []);
        _confirmedNotCredited = (r['confirmedNotCredited'] as num?)?.toInt() ?? 0;
        _pendingTooLong      = (r['pendingTooLong']        as num?)?.toInt() ?? 0;
        _reconcAt            = r['checkedAt'] as String?;
        _reconcLoading       = false;
      });
    } catch (_) {
      if (mounted) setState(() => _reconcLoading = false);
    }
  }

  Future<void> _forcerVerif(String numcommande) async {
    if (_actionLoading[numcommande] == true) return;
    setState(() => _actionLoading[numcommande] = true);
    try {
      final r = await CoinPaymentsService.adminAction('admin_verifier_tx', {
        'numcommande': numcommande,
      });
      if (!mounted) return;
      final ok  = r['ok']      == true;
      final msg = r['message'] as String? ?? '';
      _toast(ok ? '✅ $msg' : '⚠️ $msg', ok ? AppColors.succes : AppColors.alerte);
      if (ok) {
        _chargerTransactions(reset: true);
        _chargerRapprochement();
      }
    } catch (e) {
      if (mounted) _toast('Erreur: $e', AppColors.alerte);
    } finally {
      if (mounted) setState(() => _actionLoading.remove(numcommande));
    }
  }

  void _toast(String msg, Color bg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: bg, duration: const Duration(seconds: 3)),
    );
  }

  // ── Build principal ────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // ── Header ──────────────────────────────────────────────────────────
        Container(
          color: AppColors.encre,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              const Icon(Icons.currency_bitcoin, color: Color(0xFFF7931A), size: 22),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'CoinPayments — Gestion Crypto',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15),
                ),
              ),
              if (_configLoading)
                const SizedBox(width: 18, height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white54)),
              if (!_configLoading)
                _StatusPuce(config: _config),
            ],
          ),
        ),
        // ── Tabs ─────────────────────────────────────────────────────────────
        Container(
          color: AppColors.encre,
          child: TabBar(
            controller: _tabCtrl,
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            indicatorColor: const Color(0xFFF7931A),
            labelColor: Colors.white,
            unselectedLabelColor: Colors.white54,
            labelStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            tabs: [
              _tab(Icons.dashboard_outlined,    'Tableau de bord'),
              _tab(Icons.list_alt_outlined,     'Transactions',
                  badge: _txPending > 0 ? _txPending : null),
              _tab(Icons.history_outlined,      'Journal IPN'),
              _tab(Icons.warning_amber_rounded, 'Rapprochement',
                  badge: _anomalies.isNotEmpty ? _anomalies.length : null),
              _tab(Icons.settings_outlined,     'Config'),
            ],
          ),
        ),
        Expanded(
          child: TabBarView(
            controller: _tabCtrl,
            children: [
              _TabDashboard(config: _config, loading: _configLoading, onRefresh: _chargerConfig),
              _TabTransactions(
                transactions: _transactions,
                loading: _txLoading,
                total: _txTotal, credited: _txCredited,
                pending: _txPending, failed: _txFailed, totalXof: _txXof,
                statut: _txStatut, crypto: _txCrypto,
                typeOp: _txType, tontine: _txTontine,
                onStatut:  (v) { setState(() => _txStatut = v); _chargerTransactions(reset: true); },
                onCrypto:  (v) { setState(() => _txCrypto = v); _chargerTransactions(reset: true); },
                onType:    (v) { setState(() => _txType   = v); _chargerTransactions(reset: true); },
                onTontine: (v) { setState(() => _txTontine = v); },
                onSearch:  ()  { _chargerTransactions(reset: true); },
                onRefresh: ()  { _chargerTransactions(reset: true); },
                onVerif:   _forcerVerif,
                actionLoading: _actionLoading,
              ),
              _TabAudit(
                logs: _auditLogs,
                loading: _auditLoading,
                source: _auditSource,
                onSource: (v) { setState(() => _auditSource = v); _chargerAudit(); },
                onRefresh: _chargerAudit,
              ),
              _TabRapprochement(
                anomalies: _anomalies,
                loading: _reconcLoading,
                confirmedNotCredited: _confirmedNotCredited,
                pendingTooLong: _pendingTooLong,
                checkedAt: _reconcAt,
                onRefresh: _chargerRapprochement,
                onVerif:   _forcerVerif,
                actionLoading: _actionLoading,
              ),
              _TabConfig(config: _config, loading: _configLoading, onRefresh: _chargerConfig),
            ],
          ),
        ),
      ],
    );
  }

  Tab _tab(IconData icon, String label, {int? badge}) {
    return Tab(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16),
          const SizedBox(width: 4),
          Text(label),
          if (badge != null) ...[
            const SizedBox(width: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: AppColors.alerte,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text('$badge', style: const TextStyle(fontSize: 10, color: Colors.white)),
            ),
          ],
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// Widget statut config (puce en-tête)
// ══════════════════════════════════════════════════════════════════════════════

class _StatusPuce extends StatelessWidget {
  final Map<String, dynamic>? config;
  const _StatusPuce({this.config});
  @override
  Widget build(BuildContext context) {
    if (config == null) return const SizedBox();
    final cfg = (config!['config'] as Map?)?.cast<String, dynamic>() ?? {};
    final ok  = cfg['publicKeySet'] == true && cfg['privateKeySet'] == true && cfg['supabaseOk'] == true;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: ok ? AppColors.succes : AppColors.alerte,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(ok ? Icons.check_circle : Icons.error, color: Colors.white, size: 12),
          const SizedBox(width: 4),
          Text(ok ? 'API OK' : 'Config ⚠️',
              style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// TAB 0 — Tableau de bord
// ══════════════════════════════════════════════════════════════════════════════

class _TabDashboard extends StatelessWidget {
  final Map<String, dynamic>? config;
  final bool loading;
  final VoidCallback onRefresh;
  const _TabDashboard({required this.config, required this.loading, required this.onRefresh});

  @override
  Widget build(BuildContext context) {
    if (loading) return const Center(child: CircularProgressIndicator());
    final cfg   = (config?['config'] as Map?)?.cast<String, dynamic>() ?? {};
    final stats = (config?['stats']  as Map?)?.cast<String, dynamic>() ?? {};
    final total   = (stats['totalTransactions'] as num?)?.toInt() ?? 0;
    final credited = (stats['credited'] as num?)?.toInt() ?? 0;
    final pending  = (stats['pending']  as num?)?.toInt() ?? 0;

    return RefreshIndicator(
      onRefresh: () async => onRefresh(),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ── Kpis ──────────────────────────────────────────────────────────
          _SectionTitle('Vue globale'),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: _KpiCard('Total', '$total', Icons.receipt_long, AppColors.encre)),
            const SizedBox(width: 8),
            Expanded(child: _KpiCard('Crédités', '$credited', Icons.check_circle, AppColors.succes)),
            const SizedBox(width: 8),
            Expanded(child: _KpiCard('En attente', '$pending', Icons.hourglass_bottom, AppColors.or)),
          ]),
          const SizedBox(height: 16),

          // ── Cryptos supportées ─────────────────────────────────────────────
          _SectionTitle('Cryptomonnaies disponibles'),
          const SizedBox(height: 8),
          _CryptoGrid(),
          const SizedBox(height: 16),

          // ── Status API ────────────────────────────────────────────────────
          _SectionTitle('État de la configuration'),
          const SizedBox(height: 8),
          _ConfigCard(cfg: cfg),
          const SizedBox(height: 16),

          // ── IPN URL ───────────────────────────────────────────────────────
          _SectionTitle('URL IPN (Webhook)'),
          const SizedBox(height: 8),
          _IpnCard(ipnUrl: cfg['ipnUrl'] as String? ?? ''),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _KpiCard extends StatelessWidget {
  final String label, value;
  final IconData icon;
  final Color color;
  const _KpiCard(this.label, this.value, this.icon, this.color);
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.carte,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.lignes),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(height: 6),
          Text(value, style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: color)),
          Text(label, style: const TextStyle(fontSize: 11, color: AppColors.texteDoux)),
        ],
      ),
    );
  }
}

class _CryptoGrid extends StatelessWidget {
  static const _cryptos = [
    ('USDT.TRC20', 'USDT TRC20', Color(0xFF26A17B)),
    ('USDT.ERC20', 'USDT ERC20', Color(0xFF3C9BFF)),
    ('BTC',        'Bitcoin',    Color(0xFFF7931A)),
    ('ETH',        'Ethereum',   Color(0xFF627EEA)),
    ('LTC',        'Litecoin',   Color(0xFF9DA2A6)),
  ];
  const _CryptoGrid();
  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8, runSpacing: 8,
      children: _cryptos.map((c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: c.$3.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: c.$3.withValues(alpha: 0.4)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 8, height: 8, decoration: BoxDecoration(color: c.$3, shape: BoxShape.circle)),
          const SizedBox(width: 5),
          Text(c.$2, style: TextStyle(fontSize: 12, color: c.$3, fontWeight: FontWeight.w600)),
          const SizedBox(width: 4),
          const Icon(Icons.check_circle, size: 12, color: AppColors.succes),
        ]),
      )).toList(),
    );
  }
}

class _ConfigCard extends StatelessWidget {
  final Map<String, dynamic> cfg;
  const _ConfigCard({required this.cfg});
  @override
  Widget build(BuildContext context) {
    final items = [
      ('Clé publique CoinPayments', cfg['publicKeySet'] == true, cfg['publicKeyHint'] as String?),
      ('Clé privée CoinPayments',   cfg['privateKeySet'] == true, null),
      ('Supabase (URL + service key)', cfg['supabaseOk'] == true, null),
      ('API CoinPayments joignable', cfg['apiReachable'] == true,
          cfg['apiError'] as String?),
    ];
    return Container(
      decoration: BoxDecoration(
        color: AppColors.carte,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.lignes),
      ),
      child: Column(
        children: items.asMap().entries.map((e) {
          final i = e.key; final item = e.value;
          final ok = item.$2;
          return Column(
            children: [
              if (i > 0) const Divider(height: 1, color: AppColors.lignes),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                child: Row(children: [
                  Icon(ok ? Icons.check_circle : Icons.cancel,
                      color: ok ? AppColors.succes : AppColors.alerte, size: 18),
                  const SizedBox(width: 10),
                  Expanded(child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(item.$1, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                      if (item.$3 != null && item.$3!.isNotEmpty)
                        Text(item.$3!, style: TextStyle(
                          fontSize: 11,
                          color: ok ? AppColors.texteDoux : AppColors.alerte,
                        )),
                    ],
                  )),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: ok ? AppColors.succesFond : AppColors.alerteFond,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(ok ? 'OK' : 'NOK',
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold,
                            color: ok ? AppColors.succes : AppColors.alerte)),
                  ),
                ]),
              ),
            ],
          );
        }).toList(),
      ),
    );
  }
}

class _IpnCard extends StatelessWidget {
  final String ipnUrl;
  const _IpnCard({required this.ipnUrl});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.fondCode,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.lignes),
      ),
      child: Row(children: [
        const Icon(Icons.webhook, color: AppColors.encreDoux, size: 18),
        const SizedBox(width: 8),
        Expanded(child: Text(ipnUrl, style: const TextStyle(fontSize: 11, fontFamily: 'monospace'))),
        IconButton(
          icon: const Icon(Icons.copy, size: 16),
          onPressed: () => Clipboard.setData(ClipboardData(text: ipnUrl)),
          tooltip: 'Copier',
          padding: EdgeInsets.zero, constraints: const BoxConstraints(),
        ),
      ]),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// TAB 1 — Transactions
// ══════════════════════════════════════════════════════════════════════════════

class _TabTransactions extends StatefulWidget {
  final List<Map<String, dynamic>> transactions;
  final bool loading;
  final int total, credited, pending, failed, totalXof;
  final String statut, crypto, typeOp, tontine;
  final ValueChanged<String> onStatut, onCrypto, onType;
  final ValueChanged<String> onTontine;
  final VoidCallback onSearch, onRefresh;
  final Future<void> Function(String) onVerif;
  final Map<String, bool> actionLoading;

  const _TabTransactions({
    required this.transactions, required this.loading,
    required this.total, required this.credited, required this.pending,
    required this.failed, required this.totalXof,
    required this.statut, required this.crypto, required this.typeOp,
    required this.tontine,
    required this.onStatut, required this.onCrypto, required this.onType,
    required this.onTontine, required this.onSearch, required this.onRefresh,
    required this.onVerif, required this.actionLoading,
  });

  @override
  State<_TabTransactions> createState() => _TabTransactionsState();
}

class _TabTransactionsState extends State<_TabTransactions> {
  final _tontineCtrl = TextEditingController();

  @override
  void dispose() { _tontineCtrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      // ── Résumé ─────────────────────────────────────────────────────────────
      Container(
        color: AppColors.fondSecondaire,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(children: [
          _Badge('${widget.total}', 'Total', AppColors.encre),
          const SizedBox(width: 6),
          _Badge('${widget.credited}', 'Crédités', AppColors.succes),
          const SizedBox(width: 6),
          _Badge('${widget.pending}', 'Pending', AppColors.or),
          const SizedBox(width: 6),
          _Badge('${widget.failed}', 'Échoués', AppColors.alerte),
          const Spacer(),
          IconButton(icon: const Icon(Icons.refresh, size: 18),
              onPressed: widget.onRefresh, padding: EdgeInsets.zero,
              constraints: const BoxConstraints()),
        ]),
      ),
      // ── Filtres ──────────────────────────────────────────────────────────
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(children: [
          _FiltreChip('Statut', widget.statut,
              ['tous', 'pending', 'confirmed', 'credited', 'cancelled', 'failed'],
              widget.onStatut),
          const SizedBox(width: 6),
          _FiltreChip('Crypto', widget.crypto,
              ['tous', 'USDT.TRC20', 'USDT.ERC20', 'BTC', 'ETH', 'LTC'],
              widget.onCrypto),
          const SizedBox(width: 6),
          _FiltreChip('Type', widget.typeOp,
              ['tous', 'cotisation', 'caisse', 'penalite', 'remboursement_pret', 'pret_octroye'],
              widget.onType),
          const SizedBox(width: 6),
          SizedBox(
            width: 110,
            child: TextField(
              controller: _tontineCtrl,
              decoration: const InputDecoration(
                hintText: 'Code tontine',
                isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                border: OutlineInputBorder(),
              ),
              style: const TextStyle(fontSize: 12),
              textCapitalization: TextCapitalization.characters,
              onChanged: widget.onTontine,
              onSubmitted: (_) => widget.onSearch(),
            ),
          ),
          const SizedBox(width: 6),
          ElevatedButton.icon(
            onPressed: widget.onSearch,
            icon: const Icon(Icons.search, size: 15),
            label: const Text('Filtrer', style: TextStyle(fontSize: 12)),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.encre,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            ),
          ),
        ]),
      ),
      const Divider(height: 1, color: AppColors.lignes),
      // ── Liste ─────────────────────────────────────────────────────────────
      Expanded(
        child: widget.loading
            ? const Center(child: CircularProgressIndicator())
            : widget.transactions.isEmpty
                ? const Center(child: Text('Aucune transaction trouvée',
                    style: TextStyle(color: AppColors.texteDoux)))
                : ListView.separated(
                    itemCount: widget.transactions.length,
                    separatorBuilder: (_, __) => const Divider(height: 1, color: AppColors.lignes),
                    itemBuilder: (ctx, i) => _TxItem(
                      tx: widget.transactions[i],
                      onVerif: widget.onVerif,
                      actionLoading: widget.actionLoading,
                    ),
                  ),
      ),
    ]);
  }
}

class _Badge extends StatelessWidget {
  final String value, label;
  final Color color;
  const _Badge(this.value, this.label, this.color);
  @override
  Widget build(BuildContext context) {
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Text(value, style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: color)),
      Text(label, style: const TextStyle(fontSize: 10, color: AppColors.texteDoux)),
    ]);
  }
}

class _FiltreChip extends StatelessWidget {
  final String label, value;
  final List<String> options;
  final ValueChanged<String> onChanged;
  const _FiltreChip(this.label, this.value, this.options, this.onChanged);
  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: value != 'tous' ? AppColors.fondGestion : AppColors.fondSecondaire,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: value != 'tous' ? AppColors.encreDoux : AppColors.lignes,
          ),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text('$label: $value', style: const TextStyle(fontSize: 11)),
          const Icon(Icons.arrow_drop_down, size: 14),
        ]),
      ),
      onSelected: onChanged,
      itemBuilder: (_) => options.map((o) => PopupMenuItem(value: o, child: Text(o))).toList(),
    );
  }
}

class _TxItem extends StatelessWidget {
  final Map<String, dynamic> tx;
  final Future<void> Function(String) onVerif;
  final Map<String, bool> actionLoading;
  const _TxItem({required this.tx, required this.onVerif, required this.actionLoading});

  Color _statusColor(String s) {
    switch (s) {
      case 'credited':   return AppColors.succes;
      case 'confirmed':  return const Color(0xFF1565C0);
      case 'pending':    return AppColors.or;
      case 'cancelled':
      case 'failed':     return AppColors.alerte;
      default:           return AppColors.texteDoux;
    }
  }

  @override
  Widget build(BuildContext context) {
    final ref    = tx['internal_reference'] as String? ?? '—';
    final statut = tx['status']             as String? ?? 'unknown';
    final montant = (tx['amount'] as num?)?.toInt() ?? 0;
    final crypto  = tx['currency2']         as String? ?? '—';
    final tontine = tx['tontine_code']      as String? ?? '—';
    final membre  = tx['membre_nom']        as String? ?? '';
    final typeOp  = tx['type_operation']    as String? ?? '—';
    final createdAt = tx['created_at']      as String? ?? '';
    final txid    = tx['provider_transaction_id'] as String? ?? '';
    final loading = actionLoading[ref] == true;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(ref,
              style: const TextStyle(fontSize: 11, fontFamily: 'monospace', fontWeight: FontWeight.w600),
              overflow: TextOverflow.ellipsis)),
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: _statusColor(statut).withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(statut, style: TextStyle(fontSize: 11, color: _statusColor(statut), fontWeight: FontWeight.bold)),
          ),
        ]),
        const SizedBox(height: 4),
        Row(children: [
          Text('${_fmtXof(montant)} XOF', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: const Color(0xFF26A17B).withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(crypto, style: const TextStyle(fontSize: 10, color: Color(0xFF26A17B), fontWeight: FontWeight.bold)),
          ),
          const SizedBox(width: 8),
          Text(typeOp, style: const TextStyle(fontSize: 11, color: AppColors.texteDoux)),
        ]),
        const SizedBox(height: 2),
        Row(children: [
          const Icon(Icons.group, size: 12, color: AppColors.texteDoux),
          const SizedBox(width: 4),
          Text('$tontine${membre.isNotEmpty ? " · $membre" : ""}',
              style: const TextStyle(fontSize: 11, color: AppColors.texteDoux)),
          const Spacer(),
          Text(_fmtDate(createdAt), style: const TextStyle(fontSize: 10, color: AppColors.texteDoux)),
        ]),
        if (txid.isNotEmpty) ...[
          const SizedBox(height: 2),
          Row(children: [
            const Icon(Icons.tag, size: 11, color: AppColors.texteDoux),
            const SizedBox(width: 2),
            Expanded(child: Text(txid,
                style: const TextStyle(fontSize: 10, color: AppColors.texteDoux, fontFamily: 'monospace'),
                overflow: TextOverflow.ellipsis)),
          ]),
        ],
        // Bouton vérifier (si pas encore crédité)
        if (statut != 'credited') ...[
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerRight,
            child: loading
                ? const SizedBox(width: 16, height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : OutlinedButton.icon(
                    onPressed: () => onVerif(ref),
                    icon: const Icon(Icons.sync, size: 14),
                    label: const Text('Vérifier statut', style: TextStyle(fontSize: 11)),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      foregroundColor: AppColors.encreDoux,
                      side: const BorderSide(color: AppColors.encreDoux),
                    ),
                  ),
          ),
        ],
      ]),
    );
  }

  String _fmtXof(int v) {
    final s = v.toString();
    final b = StringBuffer();
    for (int i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) b.write(' ');
      b.write(s[i]);
    }
    return b.toString();
  }

  String _fmtDate(String iso) {
    if (iso.isEmpty) return '';
    try {
      final d = DateTime.parse(iso).toLocal();
      return '${d.day.toString().padLeft(2,'0')}/${d.month.toString().padLeft(2,'0')} '
             '${d.hour.toString().padLeft(2,'0')}:${d.minute.toString().padLeft(2,'0')}';
    } catch (_) { return iso.substring(0, 10); }
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// TAB 2 — Journal IPN / Audit
// ══════════════════════════════════════════════════════════════════════════════

class _TabAudit extends StatelessWidget {
  final List<Map<String, dynamic>> logs;
  final bool loading;
  final String source;
  final ValueChanged<String> onSource;
  final VoidCallback onRefresh;
  const _TabAudit({required this.logs, required this.loading,
      required this.source, required this.onSource, required this.onRefresh});

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      // ── Filtres ──────────────────────────────────────────────────────────
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(children: [
          _FiltreChip('Source', source,
              ['tous', 'CREATE', 'IPN', 'POLLING', 'MANUAL'],
              onSource),
          const Spacer(),
          Text('${logs.length} entrées', style: const TextStyle(fontSize: 11, color: AppColors.texteDoux)),
          const SizedBox(width: 8),
          IconButton(icon: const Icon(Icons.refresh, size: 18), onPressed: onRefresh,
              padding: EdgeInsets.zero, constraints: const BoxConstraints()),
        ]),
      ),
      const Divider(height: 1, color: AppColors.lignes),
      Expanded(
        child: loading
            ? const Center(child: CircularProgressIndicator())
            : logs.isEmpty
                ? const Center(child: Text('Aucun événement IPN/Audit',
                    style: TextStyle(color: AppColors.texteDoux)))
                : ListView.separated(
                    itemCount: logs.length,
                    separatorBuilder: (_, __) => const Divider(height: 1, color: AppColors.lignes),
                    itemBuilder: (_, i) => _AuditItem(log: logs[i]),
                  ),
      ),
    ]);
  }
}

class _AuditItem extends StatelessWidget {
  final Map<String, dynamic> log;
  const _AuditItem({required this.log});

  Color _sourceColor(String s) {
    switch (s) {
      case 'IPN':     return const Color(0xFF1565C0);
      case 'CREATE':  return AppColors.succes;
      case 'POLLING': return AppColors.or;
      default:        return AppColors.texteDoux;
    }
  }

  @override
  Widget build(BuildContext context) {
    final ref       = log['internal_reference'] as String? ?? '—';
    final source    = log['source']             as String? ?? '—';
    final ancien    = log['ancien_statut']       as String? ?? '';
    final nouveau   = log['nouveau_statut']      as String? ?? '';
    final erreur    = log['erreur']              as String?;
    final createdAt = log['created_at']          as String? ?? '';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 6, height: 6, margin: const EdgeInsets.only(top: 5),
          decoration: BoxDecoration(color: _sourceColor(source), shape: BoxShape.circle),
        ),
        const SizedBox(width: 8),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: _sourceColor(source).withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(source, style: TextStyle(fontSize: 10, color: _sourceColor(source), fontWeight: FontWeight.bold)),
            ),
            const SizedBox(width: 6),
            if (ancien.isNotEmpty) ...[
              Text(ancien, style: const TextStyle(fontSize: 11, color: AppColors.texteDoux)),
              const Icon(Icons.arrow_forward, size: 11, color: AppColors.texteDoux),
            ],
            Text(nouveau, style: TextStyle(
              fontSize: 11, fontWeight: FontWeight.bold,
              color: nouveau.contains('credited') ? AppColors.succes
                   : nouveau.contains('error') ? AppColors.alerte
                   : AppColors.encre,
            )),
          ]),
          const SizedBox(height: 2),
          Text(ref, style: const TextStyle(fontSize: 10, color: AppColors.texteDoux, fontFamily: 'monospace'),
              overflow: TextOverflow.ellipsis),
          if (erreur != null && erreur.isNotEmpty)
            Text('⚠️ $erreur', style: const TextStyle(fontSize: 10, color: AppColors.alerte)),
        ])),
        const SizedBox(width: 8),
        Text(_fmtDate(createdAt), style: const TextStyle(fontSize: 10, color: AppColors.texteDoux)),
      ]),
    );
  }

  String _fmtDate(String iso) {
    if (iso.isEmpty) return '';
    try {
      final d = DateTime.parse(iso).toLocal();
      return '${d.day.toString().padLeft(2,'0')}/${d.month.toString().padLeft(2,'0')}\n'
             '${d.hour.toString().padLeft(2,'0')}:${d.minute.toString().padLeft(2,'0')}';
    } catch (_) { return iso.substring(0, 10); }
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// TAB 3 — Rapprochement / Anomalies
// ══════════════════════════════════════════════════════════════════════════════

class _TabRapprochement extends StatelessWidget {
  final List<Map<String, dynamic>> anomalies;
  final bool loading;
  final int confirmedNotCredited, pendingTooLong;
  final String? checkedAt;
  final VoidCallback onRefresh;
  final Future<void> Function(String) onVerif;
  final Map<String, bool> actionLoading;

  const _TabRapprochement({
    required this.anomalies, required this.loading,
    required this.confirmedNotCredited, required this.pendingTooLong,
    required this.checkedAt, required this.onRefresh,
    required this.onVerif, required this.actionLoading,
  });

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: () async => onRefresh(),
      child: loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.all(12), children: [
              // ── Résumé anomalies ─────────────────────────────────────────────
              Row(children: [
                Expanded(child: _AnomalieCard(
                  'Confirmés\nnon crédités', '$confirmedNotCredited',
                  Icons.error_outline, AppColors.alerte,
                )),
                const SizedBox(width: 8),
                Expanded(child: _AnomalieCard(
                  'Pending\n> 30 min', '$pendingTooLong',
                  Icons.hourglass_bottom, AppColors.or,
                )),
              ]),
              const SizedBox(height: 8),
              if (checkedAt != null)
                Center(child: Text(
                  'Dernière vérification : ${_fmtDate(checkedAt!)}',
                  style: const TextStyle(fontSize: 11, color: AppColors.texteDoux),
                )),
              const SizedBox(height: 12),
              if (anomalies.isEmpty)
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: AppColors.succesFond,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Icon(Icons.check_circle, color: AppColors.succes),
                    SizedBox(width: 8),
                    Text('Aucune anomalie détectée !',
                        style: TextStyle(color: AppColors.succes, fontWeight: FontWeight.bold)),
                  ]),
                )
              else ...[
                _SectionTitle('Anomalies détectées (${anomalies.length})'),
                const SizedBox(height: 8),
                ...anomalies.map((a) => _AnomalieItem(
                  anomalie: a, onVerif: onVerif, actionLoading: actionLoading,
                )),
              ],
            ]),
    );
  }

  String _fmtDate(String iso) {
    try {
      final d = DateTime.parse(iso).toLocal();
      return '${d.day.toString().padLeft(2,'0')}/${d.month.toString().padLeft(2,'0')}/${d.year} '
             '${d.hour.toString().padLeft(2,'0')}:${d.minute.toString().padLeft(2,'0')}';
    } catch (_) { return iso; }
  }
}

class _AnomalieCard extends StatelessWidget {
  final String label, value;
  final IconData icon;
  final Color color;
  const _AnomalieCard(this.label, this.value, this.icon, this.color);
  @override
  Widget build(BuildContext context) {
    final isOk = value == '0';
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isOk ? AppColors.succesFond : color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: isOk ? AppColors.succes : color, width: 1.5),
      ),
      child: Column(children: [
        Icon(isOk ? Icons.check_circle : icon, color: isOk ? AppColors.succes : color, size: 24),
        const SizedBox(height: 4),
        Text(value, style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold,
            color: isOk ? AppColors.succes : color)),
        Text(label, style: TextStyle(fontSize: 10, color: isOk ? AppColors.succes : color),
            textAlign: TextAlign.center),
      ]),
    );
  }
}

class _AnomalieItem extends StatelessWidget {
  final Map<String, dynamic> anomalie;
  final Future<void> Function(String) onVerif;
  final Map<String, bool> actionLoading;
  const _AnomalieItem({required this.anomalie, required this.onVerif, required this.actionLoading});

  @override
  Widget build(BuildContext context) {
    final type   = anomalie['type']        as String? ?? '';
    final ref    = anomalie['numcommande'] as String? ?? '—';
    final montant = (anomalie['amount'] as num?)?.toInt() ?? 0;
    final crypto = anomalie['currency2']   as String? ?? '—';
    final tontine = anomalie['tontine']    as String? ?? '—';
    final membre  = anomalie['membre']     as String? ?? '';
    final action  = anomalie['action']     as String? ?? '';
    final since   = anomalie['since']      as String? ?? '';
    final isError = type == 'confirmed_not_credited';
    final loading = actionLoading[ref] == true;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.carte,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: isError ? AppColors.alerte : AppColors.or),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 4)],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(isError ? Icons.error : Icons.hourglass_bottom,
              color: isError ? AppColors.alerte : AppColors.or, size: 16),
          const SizedBox(width: 6),
          Expanded(child: Text(
            isError ? 'Confirmé non crédité' : 'En attente trop longtemps',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold,
                color: isError ? AppColors.alerte : AppColors.or),
          )),
          Text(_fmtDate(since), style: const TextStyle(fontSize: 10, color: AppColors.texteDoux)),
        ]),
        const SizedBox(height: 6),
        Text(ref, style: const TextStyle(fontSize: 11, fontFamily: 'monospace', color: AppColors.encre)),
        const SizedBox(height: 2),
        Row(children: [
          Text('$montant XOF · $crypto', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
          const SizedBox(width: 8),
          Text('$tontine${membre.isNotEmpty ? " · $membre" : ""}',
              style: const TextStyle(fontSize: 11, color: AppColors.texteDoux)),
        ]),
        const SizedBox(height: 6),
        Row(children: [
          Expanded(child: Text('→ $action', style: const TextStyle(fontSize: 11, color: AppColors.encreDoux))),
          loading
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : ElevatedButton.icon(
                  onPressed: () => onVerif(ref),
                  icon: const Icon(Icons.sync, size: 13),
                  label: const Text('Corriger', style: TextStyle(fontSize: 11)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: isError ? AppColors.alerte : AppColors.or,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  ),
                ),
        ]),
      ]),
    );
  }

  String _fmtDate(String iso) {
    if (iso.isEmpty) return '';
    try {
      final d = DateTime.parse(iso).toLocal();
      return '${d.day.toString().padLeft(2,'0')}/${d.month.toString().padLeft(2,'0')}';
    } catch (_) { return ''; }
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// TAB 4 — Configuration (lecture seule)
// ══════════════════════════════════════════════════════════════════════════════

class _TabConfig extends StatelessWidget {
  final Map<String, dynamic>? config;
  final bool loading;
  final VoidCallback onRefresh;
  const _TabConfig({required this.config, required this.loading, required this.onRefresh});

  @override
  Widget build(BuildContext context) {
    if (loading) return const Center(child: CircularProgressIndicator());
    final cfg   = (config?['config'] as Map?)?.cast<String, dynamic>() ?? {};
    final stats = (config?['stats']  as Map?)?.cast<String, dynamic>() ?? {};

    return RefreshIndicator(
      onRefresh: () async => onRefresh(),
      child: ListView(padding: const EdgeInsets.all(16), children: [
        // ── Sécurité ───────────────────────────────────────────────────────
        _SectionTitle('Sécurité des clés API'),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.fondGestion,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.encreDoux.withValues(alpha: 0.3)),
          ),
          child: const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(Icons.lock, color: AppColors.encreDoux, size: 16),
              SizedBox(width: 6),
              Text('Clés protégées dans Supabase Secrets',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
            ]),
            SizedBox(height: 8),
            _SecurityItem('Les clés CoinPayments ne transitent jamais dans Flutter'),
            _SecurityItem('Toutes les requêtes API passent par les Edge Functions Supabase'),
            _SecurityItem('Aucune validation de paiement n\'est effectuée côté client'),
            _SecurityItem('Le crédit n\'est déclenché qu\'après IPN ou vérification API (status=100)'),
            _SecurityItem('Protection anti-double crédit par traitement idempotent (status=credited)'),
          ]),
        ),
        const SizedBox(height: 16),

        // ── Paramètres actifs ─────────────────────────────────────────────
        _SectionTitle('Paramètres actifs (lecture seule)'),
        const SizedBox(height: 8),
        _ParamTable(entries: [
          ('API Version',         'v1',),
          ('Currency source',     'XOF',),
          ('Clé publique',        cfg['publicKeyHint'] ?? '—',),
          ('API joignable',       cfg['apiReachable'] == true ? '✅ Oui' : '❌ Non',),
          ('Supabase URL',        'ubrqtcxbxcmvmxleiglh.supabase.co',),
          ('IPN handler',         'coinpayments-ipn (Edge Function)',),
          ('Total transactions',  '${stats['totalTransactions'] ?? 0}',),
          ('Transactions créditées', '${stats['credited'] ?? 0}',),
          ('Transactions pending',   '${stats['pending'] ?? 0}',),
        ]),
        const SizedBox(height: 16),

        // ── Flux de paiement ──────────────────────────────────────────────
        _SectionTitle('Flux sécurisé de paiement'),
        const SizedBox(height: 8),
        _FluxCard(),
        const SizedBox(height: 16),

        // ── IPN URL ───────────────────────────────────────────────────────
        _SectionTitle('Configuration IPN CoinPayments'),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppColors.fondCode,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppColors.lignes),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('URL IPN à configurer dans CoinPayments :',
                style: TextStyle(fontSize: 12, color: AppColors.texteDoux)),
            const SizedBox(height: 6),
            SelectableText(
              cfg['ipnUrl'] as String? ?? '—',
              style: const TextStyle(fontSize: 11, fontFamily: 'monospace', color: AppColors.encre),
            ),
            const SizedBox(height: 8),
            const Text('Cette URL est injectée automatiquement dans chaque transaction (per-transaction IPN).',
                style: TextStyle(fontSize: 11, color: AppColors.texteDoux)),
          ]),
        ),
      ]),
    );
  }
}

class _SecurityItem extends StatelessWidget {
  final String text;
  const _SecurityItem(this.text);
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Icon(Icons.shield, size: 13, color: AppColors.succes),
        const SizedBox(width: 6),
        Expanded(child: Text(text, style: const TextStyle(fontSize: 12, color: AppColors.encre))),
      ]),
    );
  }
}

class _ParamTable extends StatelessWidget {
  final List<(String, String)> entries;
  const _ParamTable({required this.entries});
  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.carte,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.lignes),
      ),
      child: Column(
        children: entries.asMap().entries.map((e) => Column(children: [
          if (e.key > 0) const Divider(height: 1, color: AppColors.lignes),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            child: Row(children: [
              SizedBox(width: 150,
                  child: Text(e.value.$1, style: const TextStyle(fontSize: 12, color: AppColors.texteDoux))),
              Expanded(child: Text(e.value.$2,
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.encre),
                  textAlign: TextAlign.right)),
            ]),
          ),
        ])).toList(),
      ),
    );
  }
}

class _FluxCard extends StatelessWidget {
  const _FluxCard();
  @override
  Widget build(BuildContext context) {
    final steps = [
      ('Flutter (UI)', 'Crée la transaction via Edge Function', Icons.phone_android),
      ('coinpayments-payment', 'Appelle l\'API CoinPayments avec HMAC', Icons.cloud_outlined),
      ('CoinPayments', 'Génère adresse wallet + txid', Icons.currency_bitcoin),
      ('Utilisateur', 'Envoie les cryptos à l\'adresse', Icons.account_balance_wallet),
      ('CoinPayments IPN', 'Envoie IPN à coinpayments-ipn', Icons.webhook),
      ('coinpayments-ipn', 'Vérifie IPN + re-vérifie via get_tx_info', Icons.verified_user),
      ('Supabase DB', 'Crédite uniquement si status=100 (idempotent)', Icons.check_circle),
    ];
    return Container(
      decoration: BoxDecoration(
        color: AppColors.carte,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.lignes),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        children: steps.asMap().entries.map((e) => _FluxStep(
          step: e.key + 1, label: e.value.$1, desc: e.value.$2, icon: e.value.$3,
          isLast: e.key == steps.length - 1,
        )).toList(),
      ),
    );
  }
}

class _FluxStep extends StatelessWidget {
  final int step;
  final String label, desc;
  final IconData icon;
  final bool isLast;
  const _FluxStep({required this.step, required this.label, required this.desc,
      required this.icon, required this.isLast});
  @override
  Widget build(BuildContext context) {
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Column(children: [
        Container(
          width: 28, height: 28,
          decoration: BoxDecoration(color: AppColors.encre, shape: BoxShape.circle),
          child: Center(child: Text('$step', style: const TextStyle(color: Colors.white, fontSize: 11))),
        ),
        if (!isLast) Container(width: 2, height: 28, color: AppColors.lignes),
      ]),
      const SizedBox(width: 10),
      Expanded(child: Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(icon, size: 14, color: AppColors.encreDoux),
            const SizedBox(width: 4),
            Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
          ]),
          Text(desc, style: const TextStyle(fontSize: 11, color: AppColors.texteDoux)),
        ]),
      )),
    ]);
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// Helpers partagés
// ══════════════════════════════════════════════════════════════════════════════

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);
  @override
  Widget build(BuildContext context) => Text(text,
      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: AppColors.encre));
}
