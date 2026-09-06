// ═══════════════════════════════════════════════════════════════════════════════
// blockchain_admin_screen.dart  —  TC Admin Module Blockchain
// Phase 1 : journal, stats, vérification TX, réseau Polygon Amoy
// ═══════════════════════════════════════════════════════════════════════════════

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/blockchain_service.dart';
import '../utils/app_colors.dart';
import '../utils/formatters.dart';

class BlockchainAdminScreen extends StatefulWidget {
  final String cleAdmin;
  const BlockchainAdminScreen({super.key, required this.cleAdmin});

  @override
  State<BlockchainAdminScreen> createState() => _BlockchainAdminScreenState();
}

class _BlockchainAdminScreenState extends State<BlockchainAdminScreen>
    with SingleTickerProviderStateMixin {

  late final TabController _tabs;

  // ── État dashboard ────────────────────────────────────────────────────────
  Map<String, dynamic> _stats     = {};
  bool _statsLoading               = true;
  String? _statsErreur;

  // ── État journal ──────────────────────────────────────────────────────────
  List<BlockchainEntry> _journal  = [];
  bool _journalLoading             = true;
  String? _journalErreur;
  String? _filtreStatut;
  String? _filtreType;

  // ── État vérification TX ──────────────────────────────────────────────────
  final _txCtrl = TextEditingController();
  Map<String, dynamic>? _verifyResult;
  bool _verifyLoading = false;

  // ── Taux USDT ─────────────────────────────────────────────────────────────
  Map<String, dynamic> _taux = {};

  // ── Info contrat Phase 2 ────────────────────────────────────────────────
  Map<String, dynamic> _contrat = {};
  bool _contratLoading = true;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this);
    _chargerStats();
    _chargerJournal();
    _chargerTaux();
    _chargerContrat();
  }

  @override
  void dispose() {
    _tabs.dispose();
    _txCtrl.dispose();
    super.dispose();
  }

  // ── Chargements ───────────────────────────────────────────────────────────
  Future<void> _chargerStats() async {
    setState(() { _statsLoading = true; _statsErreur = null; });
    try {
      final r = await BlockchainService.statsJournal();
      if (!mounted) return;
      setState(() { _stats = r; _statsLoading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _statsErreur = e.toString(); _statsLoading = false; });
    }
  }

  Future<void> _chargerJournal() async {
    setState(() { _journalLoading = true; _journalErreur = null; });
    try {
      final rows = await BlockchainService.lireJournal(
        statut       : _filtreStatut,
        typeOperation: _filtreType,
        limit        : 100,
      );
      if (!mounted) return;
      setState(() { _journal = rows; _journalLoading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _journalErreur = e.toString(); _journalLoading = false; });
    }
  }

  Future<void> _chargerTaux() async {
    try {
      final r = await BlockchainService.tauxUsdt();
      if (!mounted) return;
      setState(() => _taux = r);
    } catch (_) {}
  }

  Future<void> _chargerContrat() async {
    try {
      final r = await BlockchainService.contractInfo();
      if (!mounted) return;
      setState(() { _contrat = r; _contratLoading = false; });
    } catch (_) {
      if (!mounted) return;
      setState(() => _contratLoading = false);
    }
  }

  // Ouvre un lien PolygonScan dans le navigateur externe
  void _ouvrirUrl(String url) {
    if (url.isEmpty) return;
    // Copie l'URL dans le presse-papiers + feedback
    Clipboard.setData(ClipboardData(text: url));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Lien copié : ${url.length > 40 ? '${url.substring(0, 40)}...' : url}'),
      action: SnackBarAction(label: 'OK', onPressed: () {}),
      duration: const Duration(seconds: 3),
    ));
  }

  // Adresse Ethereum raccourcie : 0x1234...5678
  String _shortAddr(String addr) {
    if (addr.length < 12) return addr;
    return '${addr.substring(0, 8)}...${addr.substring(addr.length - 6)}';
  }

  Future<void> _verifierTx() async {
    final hash = _txCtrl.text.trim();
    if (hash.isEmpty) return;
    setState(() { _verifyLoading = true; _verifyResult = null; });
    try {
      final r = await BlockchainService.verifierTx(hash);
      if (!mounted) return;
      setState(() { _verifyResult = r; _verifyLoading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _verifyResult = {'ok': false, 'message': e.toString()};
        _verifyLoading = false;
      });
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Header
        Container(
          color: AppColors.fondPapier,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF8247E5).withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.hexagon_outlined, color: Color(0xFF8247E5), size: 20),
                ),
                const SizedBox(width: 10),
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('Blockchain Polygon',
                      style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15, color: AppColors.encre)),
                  Text('Réseau: Polygon Amoy (testnet)  •  Token: USDT',
                      style: TextStyle(fontSize: 11, color: AppColors.texteDoux)),
                ]),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.refresh_rounded, size: 20),
                  onPressed: () { _chargerStats(); _chargerJournal(); _chargerTaux(); _chargerContrat(); },
                  tooltip: 'Actualiser',
                ),
              ]),
              const SizedBox(height: 10),
              // Taux USDT
              if (_taux['taux'] != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: const Color(0xFF8247E5).withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(children: [
                    const Icon(Icons.swap_horiz_rounded, size: 14, color: Color(0xFF8247E5)),
                    const SizedBox(width: 6),
                    Text(
                      '1 USDT = ${(_taux['taux_inverse'] ?? 620).toStringAsFixed(0)} XOF  '
                      '•  1 XOF = ${_taux['taux']?.toStringAsFixed(6)} USDT',
                      style: const TextStyle(fontSize: 11, color: Color(0xFF8247E5), fontWeight: FontWeight.w600),
                    ),
                  ]),
                ),
              const SizedBox(height: 10),
              TabBar(
                controller: _tabs,
                labelColor: const Color(0xFF8247E5),
                unselectedLabelColor: AppColors.texteDoux,
                indicatorColor: const Color(0xFF8247E5),
                indicatorSize: TabBarIndicatorSize.label,
                labelStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                tabs: const [
                  Tab(text: 'Tableau de bord'),
                  Tab(text: 'Journal'),
                  Tab(text: 'Vérifier TX'),
                ],
              ),
            ],
          ),
        ),
        const Divider(height: 1, color: AppColors.lignes),
        Expanded(
          child: TabBarView(
            controller: _tabs,
            children: [
              _vueDashboard(),
              _vueJournal(),
              _vueVerifierTx(),
            ],
          ),
        ),
      ],
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // ONGLET 0 — TABLEAU DE BORD
  // ══════════════════════════════════════════════════════════════════════════
  Widget _vueDashboard() {
    if (_statsLoading) return const Center(child: CircularProgressIndicator(color: Color(0xFF8247E5)));
    if (_statsErreur != null) return _erreurWidget(_statsErreur!, _chargerStats);

    final total     = _stats['total_operations'] ?? 0;
    final confirmed = _stats['confirmed']         ?? 0;
    final pending   = _stats['pending']           ?? 0;
    final failed    = _stats['failed']            ?? 0;
    final block     = _stats['block_actuel']      ?? 0;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // ── Statut réseau ────────────────────────────────────────────────
        _carteReseau(block),
        const SizedBox(height: 16),

        // ── KPIs ─────────────────────────────────────────────────────────
        const Text('Opérations blockchain',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14, color: AppColors.encre)),
        const SizedBox(height: 10),
        GridView.count(
          crossAxisCount: 2,
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          childAspectRatio: 2.2,
          children: [
            _kpiCarte('Total', '$total', Icons.storage_rounded, AppColors.encreDoux),
            _kpiCarte('Confirmées', '$confirmed', Icons.check_circle_rounded, AppColors.succes),
            _kpiCarte('En attente', '$pending', Icons.hourglass_empty_rounded, AppColors.or),
            _kpiCarte('Échouées', '$failed', Icons.error_outline_rounded, AppColors.alerte),
          ],
        ),
        const SizedBox(height: 20),

        // ── Informations Phase 1 ─────────────────────────────────────────
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(0xFF8247E5).withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFF8247E5).withValues(alpha: 0.2)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                const Icon(Icons.info_outline_rounded, color: Color(0xFF8247E5), size: 18),
                const SizedBox(width: 8),
                const Text('Phase 1 — Journal blockchain actif',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: Color(0xFF8247E5))),
              ]),
              const SizedBox(height: 10),
              _infoLigne('Réseau actif', 'Polygon Amoy (testnet)'),
              _infoLigne('Token', 'USDT ERC-20'),
              _infoLigne('Ancrage', 'Preuve d\'existence SHA-256 + bloc Polygon'),
              if (_contratLoading)
                const Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: Text('Chargement contrat...', style: TextStyle(fontSize: 11, color: AppColors.texteDoux)),
                )
              else if (_contrat['phase'] == 2) ...[
                _infoLigne('Phase', '2 — TontineVault.sol déployé ✅'),
                _infoLigne('Contrat', _shortAddr(_contrat['contract_address'] as String? ?? '')),
                _infoLigne('Admin wallet', _shortAddr(_contrat['wallet_admin'] as String? ?? '')),
                GestureDetector(
                  onTap: () => _ouvrirUrl(_contrat['explorer'] as String? ?? ''),
                  child: const Padding(
                    padding: EdgeInsets.only(top: 2),
                    child: Text('Voir sur PolygonScan →',
                        style: TextStyle(fontSize: 11, color: Color(0xFF8247E5),
                            fontWeight: FontWeight.w700, decoration: TextDecoration.underline)),
                  ),
                ),
              ] else ...[
                _infoLigne('Phase 2', 'Smart Contract (déploiement en cours)'),
                _infoLigne('Phase 4', 'Migration Polygon Mainnet'),
              ],
              const SizedBox(height: 8),
              Text(
                _contrat['phase'] == 2
                  ? '⚡ Phase 2 active : chaque opération génère un vrai hash Ethereum '
                    'vérifiable sur PolygonScan Amoy via TontineVault.sol.'
                  : '🔒 Phase 1 active : preuve d\'existence SHA-256 ancrée sur Polygon. '
                    'Phase 2 (vraie TX on-chain) en cours de déploiement.',
                style: const TextStyle(fontSize: 11, color: AppColors.texteDoux, height: 1.5),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        // ── Opérations récentes ───────────────────────────────────────────
        const Text('Dernières opérations',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14, color: AppColors.encre)),
        const SizedBox(height: 10),
        if (_journalLoading)
          const Center(child: CircularProgressIndicator(color: Color(0xFF8247E5)))
        else
          ..._journal.take(5).map(_carteMiniEntry),
      ],
    );
  }

  Widget _carteReseau(int blockNumber) {
    final phase2 = _contrat['phase'] == 2;
    final contractAddr = _contrat['contract_address'] as String?;
    return GestureDetector(
      onTap: contractAddr != null
          ? () => _ouvrirUrl('https://amoy.polygonscan.com/address/$contractAddr')
          : null,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: phase2
                ? [const Color(0xFF8247E5), const Color(0xFF6B35C7)]
                : [const Color(0xFF546E7A), const Color(0xFF37474F)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Text('Polygon Amoy',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 15)),
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: phase2 ? const Color(0xFF00E676) : Colors.white30,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(phase2 ? 'Phase 2 ⚡' : 'Phase 1',
                    style: TextStyle(
                        color: phase2 ? Colors.black87 : Colors.white,
                        fontSize: 9, fontWeight: FontWeight.w800)),
              ),
            ]),
            Text(
              phase2 ? 'TontineVault.sol  •  ChainID 80002' : 'Testnet  •  ChainID 80002',
              style: const TextStyle(color: Colors.white70, fontSize: 11)),
            const SizedBox(height: 6),
            Row(children: [
              const Icon(Icons.circle, color: Color(0xFF00E676), size: 8),
              const SizedBox(width: 4),
              Text('Bloc #${_formatNumber(blockNumber)}',
                  style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
              if (phase2 && contractAddr != null) ...[
                const SizedBox(width: 8),
                Flexible(child: Text(_shortAddr(contractAddr),
                    style: const TextStyle(color: Colors.white60, fontSize: 10,
                        fontFamily: 'monospace'), overflow: TextOverflow.ellipsis)),
              ],
            ]),
          ])),
          const SizedBox(width: 8),
          Icon(phase2 ? Icons.receipt_long_rounded : Icons.hexagon,
              color: Colors.white30, size: 42),
        ]),
      ),
    );
  }

  Widget _kpiCarte(String label, String valeur, IconData icone, Color couleur) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: couleur.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: couleur.withValues(alpha: 0.2)),
      ),
      child: Row(children: [
        Icon(icone, color: couleur, size: 22),
        const SizedBox(width: 8),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(valeur, style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18, color: couleur)),
          Text(label, style: const TextStyle(fontSize: 10, color: AppColors.texteDoux)),
        ]),
      ]),
    );
  }

  Widget _infoLigne(String label, String valeur) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(children: [
        Text('$label : ', style: const TextStyle(fontSize: 11, color: AppColors.texteDoux)),
        Text(valeur, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.encre)),
      ]),
    );
  }

  Widget _carteMiniEntry(BlockchainEntry e) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.lignes),
      ),
      child: Row(children: [
        _iconType(e.typeOperation),
        const SizedBox(width: 10),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(e.typeLabel, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: AppColors.encre)),
          Text('${e.tontineCode}  •  ${e.membreNom ?? "—"}',
              style: const TextStyle(fontSize: 10, color: AppColors.texteDoux)),
        ])),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(e.montantXof != null ? Formatters.montant(e.montantXof!, devise: e.devise) : '—',
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 11, color: AppColors.encre)),
          _badgeStatut(e.statut),
        ]),
      ]),
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // ONGLET 1 — JOURNAL
  // ══════════════════════════════════════════════════════════════════════════
  Widget _vueJournal() {
    return Column(
      children: [
        // Filtres
        Container(
          color: AppColors.fondPapier,
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Row(children: [
            _dropdownFiltre(
              'Statut', _filtreStatut,
              ['confirmed', 'pending', 'failed'],
              (v) { setState(() => _filtreStatut = v); _chargerJournal(); },
            ),
            const SizedBox(width: 8),
            _dropdownFiltre(
              'Type', _filtreType,
              ['cotisation', 'distribution', 'pret', 'remboursement', 'vote', 'creation', 'apport'],
              (v) { setState(() => _filtreType = v); _chargerJournal(); },
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: () {
                setState(() { _filtreStatut = null; _filtreType = null; });
                _chargerJournal();
              },
              icon: const Icon(Icons.clear_rounded, size: 14),
              label: const Text('Reset', style: TextStyle(fontSize: 11)),
            ),
          ]),
        ),
        const Divider(height: 1, color: AppColors.lignes),
        // Liste
        Expanded(
          child: _journalLoading
              ? const Center(child: CircularProgressIndicator(color: Color(0xFF8247E5)))
              : _journalErreur != null
                  ? _erreurWidget(_journalErreur!, _chargerJournal)
                  : _journal.isEmpty
                      ? const Center(child: Text('Aucune entrée blockchain', style: TextStyle(color: AppColors.texteDoux)))
                      : RefreshIndicator(
                          onRefresh: _chargerJournal,
                          child: ListView.separated(
                            padding: const EdgeInsets.all(12),
                            itemCount: _journal.length,
                            separatorBuilder: (_, __) => const SizedBox(height: 8),
                            itemBuilder: (_, i) => _carteEntry(_journal[i]),
                          ),
                        ),
        ),
      ],
    );
  }

  Widget _carteEntry(BlockchainEntry e) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.lignes),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Header
        Row(children: [
          _iconType(e.typeOperation),
          const SizedBox(width: 8),
          Expanded(child: Text(e.typeLabel,
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: AppColors.encre))),
          _badgeStatut(e.statut),
        ]),
        const SizedBox(height: 8),
        // Infos
        _ligneInfo('Tontine', e.tontineCode),
        if (e.membreNom != null) _ligneInfo('Membre', e.membreNom!),
        if (e.montantXof != null) _ligneInfo('Montant',
            '${Formatters.montant(e.montantXof!, devise: e.devise)}'
            '${e.montantUsdt != null ? "  ≈  ${e.montantUsdt!.toStringAsFixed(4)} USDT" : ""}'),
        _ligneInfo('Bloc', e.blockNumber != null ? '#${_formatNumber(e.blockNumber!)}' : '—'),
        // TX Hash avec copie
        if (e.txHash != null)
          Row(children: [
            const Text('TX Hash : ', style: TextStyle(fontSize: 11, color: AppColors.texteDoux)),
            Expanded(child: Text(e.txHashCourt,
                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                    color: Color(0xFF8247E5), fontFamily: 'monospace'))),
            GestureDetector(
              onTap: () {
                Clipboard.setData(ClipboardData(text: e.txHash!));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Hash copié'), duration: Duration(seconds: 1)));
              },
              child: const Icon(Icons.copy_rounded, size: 14, color: AppColors.texteDoux),
            ),
            if (e.txHash!.length == 66) ...[
              const SizedBox(width: 6),
              GestureDetector(
                onTap: () => _ouvrirUrl(e.explorerUrl),
                child: const Icon(Icons.open_in_new_rounded, size: 14, color: Color(0xFF8247E5)),
              ),
            ],
          ]),
        if (e.txHash != null && e.txHash!.length == 66)
          Container(
            margin: const EdgeInsets.only(top: 4),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: const Color(0xFF8247E5).withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(4),
            ),
            child: const Text('⚡ TX on-chain Phase 2',
                style: TextStyle(fontSize: 9, color: Color(0xFF8247E5), fontWeight: FontWeight.w700)),
          ),
        if (e.signature != null)
          _ligneInfo('Signature', '${e.signature!.substring(0, 12)}…'),
        const SizedBox(height: 4),
        Text(
          _formatDate(e.createdAt),
          style: const TextStyle(fontSize: 10, color: AppColors.texteDoux),
        ),
      ]),
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // ONGLET 2 — VÉRIFIER TX
  // ══════════════════════════════════════════════════════════════════════════
  Widget _vueVerifierTx() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('Vérifier une transaction',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15, color: AppColors.encre)),
        const SizedBox(height: 4),
        const Text('Entrez un hash de transaction pour vérifier son statut on-chain.',
            style: TextStyle(fontSize: 12, color: AppColors.texteDoux)),
        const SizedBox(height: 16),
        TextField(
          controller: _txCtrl,
          style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
          decoration: InputDecoration(
            hintText: '0x1234abcd…',
            hintStyle: const TextStyle(color: AppColors.texteDoux),
            filled: true,
            fillColor: Colors.white,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: AppColors.lignes)),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: AppColors.lignes)),
            prefixIcon: const Icon(Icons.tag_rounded, size: 18, color: AppColors.texteDoux),
            suffixIcon: IconButton(
              icon: const Icon(Icons.clear_rounded, size: 16),
              onPressed: () => _txCtrl.clear(),
            ),
          ),
          onSubmitted: (_) => _verifierTx(),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF8247E5),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: _verifyLoading ? null : _verifierTx,
            icon: _verifyLoading
                ? const SizedBox(width: 16, height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.search_rounded),
            label: Text(_verifyLoading ? 'Vérification…' : 'Vérifier sur Polygon'),
          ),
        ),
        if (_verifyResult != null) ...[
          const SizedBox(height: 20),
          _carteVerifyResult(_verifyResult!),
        ],
        const SizedBox(height: 24),
        // Explication Phase 1
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppColors.fondPapier,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppColors.lignes),
          ),
          child: const Text(
            'ℹ️  Phase 1 : Les hash générés sont des preuves d\'existence SHA-256 '
            'ancrées au numéro de bloc Polygon actuel. '
            'En Phase 2, chaque opération sera une vraie transaction on-chain '
            'via le smart contract TontineVault.sol.',
            style: TextStyle(fontSize: 11, color: AppColors.texteDoux, height: 1.5),
          ),
        ),
      ],
    );
  }

  Widget _carteVerifyResult(Map<String, dynamic> r) {
    final ok = r['ok'] == true;
    final statut = r['statut'] as String? ?? '—';
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: ok ? AppColors.succes.withValues(alpha: 0.06) : AppColors.alerte.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: ok ? AppColors.succes : AppColors.alerte),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(ok ? Icons.check_circle_rounded : Icons.error_outline_rounded,
              color: ok ? AppColors.succes : AppColors.alerte, size: 20),
          const SizedBox(width: 8),
          Text(ok ? 'Transaction trouvée' : 'Transaction introuvable',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13,
                  color: ok ? AppColors.succes : AppColors.alerte)),
        ]),
        const SizedBox(height: 10),
        if (r['tontine_code'] != null) _ligneInfo('Tontine', r['tontine_code']),
        if (r['type_operation'] != null) _ligneInfo('Type', r['type_operation']),
        if (r['montant_xof'] != null) _ligneInfo('Montant', '${r['montant_xof']}'),
        _ligneInfo('Statut', statut),
        if (r['block_number'] != null) _ligneInfo('Bloc', '#${r['block_number']}'),
        if (r['confirmed_at'] != null) _ligneInfo('Confirmé le', r['confirmed_at']),
        if (r['signature'] != null)
          _ligneInfo('Signature', '${(r['signature'] as String).substring(0, 16)}…'),
      ]),
    );
  }

  // ── Widgets utilitaires ───────────────────────────────────────────────────
  Widget _iconType(String type) {
    // Résoudre les sélecteurs hex 0x… → type métier
    final resolu = BlockchainEntry.resoudreType(type);
    const map = {
      'cotisation'              : (Icons.savings_rounded,                Color(0xFF1976D2)),
      'annulation_cotisation'   : (Icons.undo_rounded,                   Color(0xFF64B5F6)),
      'depot'                   : (Icons.download_rounded,               Color(0xFF1565C0)),
      'apport'                  : (Icons.add_circle_rounded,             Color(0xFF009688)),
      'paiement'                : (Icons.payments_rounded,               Color(0xFF1E88E5)),
      'distribution'            : (Icons.account_balance_wallet_rounded, Color(0xFF2E7D5B)),
      'decaissement'            : (Icons.outbound_rounded,               Color(0xFFE53935)),
      'retrait'                 : (Icons.upload_rounded,                 Color(0xFFEF5350)),
      'retrait_propose'         : (Icons.upload_file_rounded,            Color(0xFFEF9A9A)),
      'depense_caisse'          : (Icons.shopping_bag_rounded,           Color(0xFFD32F2F)),
      'pret'                    : (Icons.account_balance_rounded,        Color(0xFFFF9800)),
      'remboursement'           : (Icons.price_check_rounded,            Color(0xFF9C27B0)),
      'annulation_remboursement': (Icons.cancel_rounded,                 Color(0xFFAB47BC)),
      'penalite'                : (Icons.warning_rounded,                Color(0xFFF44336)),
      'vote'                    : (Icons.how_to_vote_rounded,            Color(0xFF00BCD4)),
      'vote_cree'               : (Icons.ballot_rounded,                 Color(0xFF00ACC1)),
      'vote_clos'               : (Icons.check_circle_rounded,           Color(0xFF0097A7)),
      'ajout_membre'            : (Icons.person_add_rounded,             Color(0xFF388E3C)),
      'suppression_membre'      : (Icons.person_remove_rounded,          Color(0xFFC62828)),
      'creation'                : (Icons.add_business_rounded,           Color(0xFF8247E5)),
      'sync_balance'            : (Icons.sync_rounded,                   Color(0xFF26A69A)),
      'mise_a_jour'             : (Icons.tune_rounded,                   Color(0xFF546E7A)),
      'tirage_verrouille'       : (Icons.lock_rounded,                   Color(0xFF37474F)),
      'score_modifie'           : (Icons.star_rounded,                   Color(0xFFFBC02D)),
      'upgrade_pro'             : (Icons.rocket_launch_rounded,          Color(0xFFD4AC0D)),
      'nouveau_cycle'           : (Icons.replay_circle_filled,           Color(0xFF43A047)),
    };
    final (icon, color) = map[resolu] ?? (Icons.help_outline, AppColors.texteDoux);
    return Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(icon, color: color, size: 16),
    );
  }

  Widget _badgeStatut(String statut) {
    Color c;
    switch (statut) {
      case 'confirmed': c = AppColors.succes; break;
      case 'failed':    c = AppColors.alerte; break;
      default:          c = AppColors.or;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: c.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
      child: Text(statut, style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: c)),
    );
  }

  Widget _ligneInfo(String label, String valeur) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(children: [
        Text('$label : ', style: const TextStyle(fontSize: 11, color: AppColors.texteDoux)),
        Flexible(child: Text(valeur,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.encre),
            overflow: TextOverflow.ellipsis)),
      ]),
    );
  }

  Widget _dropdownFiltre(
    String hint, String? valeur, List<String> options, void Function(String?) onChanged,
  ) {
    return DropdownButton<String>(
      value: valeur,
      hint: Text(hint, style: const TextStyle(fontSize: 11, color: AppColors.texteDoux)),
      style: const TextStyle(fontSize: 11, color: AppColors.encre),
      underline: const SizedBox(),
      items: [
        DropdownMenuItem(value: null, child: Text('Tous ($hint)', style: const TextStyle(fontSize: 11))),
        ...options.map((o) => DropdownMenuItem(value: o, child: Text(o, style: const TextStyle(fontSize: 11)))),
      ],
      onChanged: onChanged,
    );
  }

  Widget _erreurWidget(String erreur, VoidCallback onRetry) {
    return Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      const Icon(Icons.error_outline_rounded, color: AppColors.alerte, size: 40),
      const SizedBox(height: 12),
      Text(erreur, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.texteDoux, fontSize: 12)),
      const SizedBox(height: 16),
      ElevatedButton(onPressed: onRetry, child: const Text('Réessayer')),
    ]));
  }

  String _formatNumber(num n) {
    final s = n.toInt().toString();
    final buf = StringBuffer();
    for (int i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(' ');
      buf.write(s[i]);
    }
    return buf.toString();
  }

  String _formatDate(DateTime d) {
    return '${d.day.toString().padLeft(2,'0')}/${d.month.toString().padLeft(2,'0')}/${d.year} '
           '${d.hour.toString().padLeft(2,'0')}:${d.minute.toString().padLeft(2,'0')}';
  }
}
