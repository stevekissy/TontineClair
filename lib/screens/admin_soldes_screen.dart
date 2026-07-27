// ═══════════════════════════════════════════════════════════════════════════════
// admin_soldes_screen.dart — TontineClair
//
// Écran Admin : Soldes de toutes les tontines synchronisés sur la blockchain.
// Affiche le solde XOF calculé depuis le journal blockchain (opérations
// enregistrées on-chain ou en SHA-256), avec synchronisation en temps réel
// vers le smart contract TontineVault.
//
// Architecture :
//   • Source de données : journal blockchain_journal (Supabase) via Edge Function
//   • Solde = Σ(cotisations + apports) − Σ(distributions + prêts + dépenses + pénalités)
//   • Sync blockchain : envoie un event OperationEnregistree(type=sync_balance) on-chain
//   • Temps réel : polling toutes les 30s + bouton refresh manuel
// ═══════════════════════════════════════════════════════════════════════════════

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/blockchain_service.dart';
import '../services/supabase_service.dart';
import '../utils/app_colors.dart';
import '../utils/formatters.dart';
import '../widgets/app_widgets.dart';

// ── Modèle solde par tontine ─────────────────────────────────────────────────

class SoldeTontine {
  final String code;
  final String nom;
  final int    soldeBrut;       // XOF calculé depuis journal blockchain
  final int    totalEntrees;    // cotisations + apports
  final int    totalSorties;    // distributions + prêts + dépenses
  final int    nbOps;           // nombre d'opérations total
  final int    nbOnChain;       // ops avec vraie TX Polygon
  final String? dernierTxHash;  // dernière TX on-chain
  final String? dernierStatut;  // 'confirmed' | 'pending' | null
  final DateTime? derniereOp;
  final bool   syncEnCours;
  final int?   soldeCaisseReel; // Solde réel depuis Supabase (comparaison)

  const SoldeTontine({
    required this.code,
    required this.nom,
    required this.soldeBrut,
    required this.totalEntrees,
    required this.totalSorties,
    required this.nbOps,
    required this.nbOnChain,
    this.dernierTxHash,
    this.dernierStatut,
    this.derniereOp,
    this.syncEnCours = false,
    this.soldeCaisseReel,
  });

  /// Écart entre solde blockchain et solde réel (en % absolu)
  double? get ecartPourcentage {
    if (soldeCaisseReel == null) return null;
    if (soldeCaisseReel == 0 && soldeBrut == 0) return 0;
    final base = soldeCaisseReel! != 0 ? soldeCaisseReel!.abs() : 1;
    return ((soldeBrut - soldeCaisseReel!).abs() / base * 100);
  }

  bool get diverge => (ecartPourcentage ?? 0) > 2; // alerte si >2% d'écart

  SoldeTontine copyWith({bool? syncEnCours, int? soldeCaisseReel}) => SoldeTontine(
    code            : code,
    nom             : nom,
    soldeBrut       : soldeBrut,
    totalEntrees    : totalEntrees,
    totalSorties    : totalSorties,
    nbOps           : nbOps,
    nbOnChain       : nbOnChain,
    dernierTxHash   : dernierTxHash,
    dernierStatut   : dernierStatut,
    derniereOp      : derniereOp,
    syncEnCours     : syncEnCours ?? this.syncEnCours,
    soldeCaisseReel : soldeCaisseReel ?? this.soldeCaisseReel,
  );

  // Types qui AUGMENTENT la caisse
  static const _entrees = {
    'cotisation', 'apport', 'remboursement', 'remboursement_pret',
    'annulation_pret', 'annulation_distribution',
  };
  // Types qui DIMINUENT la caisse
  static const _sorties = {
    'distribution', 'decaissement', 'pret', 'depense_caisse',
    'penalite', 'annulation_cotisation', 'retrait',
  };

  static SoldeTontine depuisEntrees(
    String code,
    String nom,
    List<BlockchainEntry> entrees,
  ) {
    int entree = 0;
    int sortie = 0;
    int onChain = 0;
    String? dernierHash;
    String? dernierSt;
    DateTime? derniereDate;

    for (final e in entrees) {
      final m = e.montantXof ?? 0;
      final type = e.typeOperation.toLowerCase();

      if (_entrees.contains(type)) {
        entree += m;
      } else if (_sorties.contains(type)) {
        sortie += m;
      }

      if (e.txHash != null && e.txHash!.length == 66) {
        onChain++;
        // Garder la TX la plus récente
        if (derniereDate == null || e.createdAt.isAfter(derniereDate)) {
          dernierHash   = e.txHash;
          dernierSt     = e.statut;
          derniereDate  = e.createdAt;
        }
      } else if (derniereDate == null || e.createdAt.isAfter(derniereDate)) {
        derniereDate = e.createdAt;
      }
    }

    return SoldeTontine(
      code          : code,
      nom           : nom,
      soldeBrut     : entree - sortie,
      totalEntrees  : entree,
      totalSorties  : sortie,
      nbOps         : entrees.length,
      nbOnChain     : onChain,
      dernierTxHash : dernierHash,
      dernierStatut : dernierSt,
      derniereOp    : derniereDate,
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// ÉCRAN PRINCIPAL
// ═══════════════════════════════════════════════════════════════════════════════

class AdminSoldesScreen extends StatefulWidget {
  final String cleAdmin;
  const AdminSoldesScreen({super.key, required this.cleAdmin});

  @override
  State<AdminSoldesScreen> createState() => _AdminSoldesScreenState();
}

class _AdminSoldesScreenState extends State<AdminSoldesScreen> {
  List<SoldeTontine>      _soldes       = [];
  List<Map<String, dynamic>> _tontines  = [];
  Map<String, int>        _soldesReels  = {}; // soldes réels depuis Supabase
  bool                    _loading      = true;
  bool                    _refreshing   = false;
  String?                 _erreur;
  String                  _tri          = 'solde_desc'; // solde_desc | solde_asc | nom | ops
  String                  _recherche    = '';
  final _rechercheCtrl = TextEditingController();
  Timer?                  _timer;
  int                     _phase        = 1;
  Map<String, dynamic>?   _contractInfo;

  // Syncs en cours : code → true
  final Map<String, bool> _syncEnCours = {};
  // Syncs tous en cours
  bool _syncTousEnCours = false;

  @override
  void initState() {
    super.initState();
    _charger();
    // Polling toutes les 30s
    _timer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted && !_loading) _rafraichir();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _rechercheCtrl.dispose();
    super.dispose();
  }

  // ── Chargement initial ────────────────────────────────────────────────────

  Future<void> _charger() async {
    setState(() { _loading = true; _erreur = null; });
    try {
      await Future.wait([
        _chargerTontines(),
        _chargerContractInfo(),
      ]);
    } catch (e) {
      setState(() => _erreur = 'Erreur de chargement : $e');
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _chargerTontines() async {
    // Charger la liste des tontines ET les soldes réels en parallèle
    final results = await Future.wait([
      SupabaseService.adminListerTontines(widget.cleAdmin),
      SupabaseService.adminSoldesCaisses(widget.cleAdmin),
    ]);
    final tontines   = results[0] as List<Map<String, dynamic>>;
    final soldesReels = results[1] as Map<String, int>;
    _tontines  = tontines;
    _soldesReels = soldesReels;
    await _calculerSoldes(tontines);
  }

  Future<void> _chargerContractInfo() async {
    try {
      final info = await BlockchainService.contractInfo();
      if (mounted) {
        setState(() {
          _contractInfo = info;
          _phase = (info['phase'] as num?)?.toInt() ?? 1;
        });
      }
    } catch (_) {}
  }

  Future<void> _calculerSoldes(List<Map<String, dynamic>> tontines) async {
    final soldes = <SoldeTontine>[];

    // Requête unique : stats agrégées par tontine (stats_soldes)
    final stats = await BlockchainService.statsSoldes();
    final parTontine = stats['par_tontine'] as Map<String, dynamic>? ?? {};

    for (final t in tontines) {
      final code = t['code'] as String? ?? '';
      final nom  = (t['nom'] as String?)?.trim().isNotEmpty == true
          ? t['nom'] as String
          : 'Tontine $code';

      if (code.isEmpty) continue;

      // Solde réel depuis Supabase (pour détection divergence)
      final soldeCaisseReel = _soldesReels[code];

      // Utiliser les stats agrégées si disponibles
      if (parTontine.containsKey(code)) {
        final st = parTontine[code] as Map<String, dynamic>;
        soldes.add(SoldeTontine(
          code            : code,
          nom             : nom,
          soldeBrut       : (st['solde'] as num?)?.toInt() ?? 0,
          totalEntrees    : (st['entrees'] as num?)?.toInt() ?? 0,
          totalSorties    : (st['sorties'] as num?)?.toInt() ?? 0,
          nbOps           : (st['nb_ops'] as num?)?.toInt() ?? 0,
          nbOnChain       : (st['nb_on_chain'] as num?)?.toInt() ?? 0,
          dernierTxHash   : st['dernier_tx'] as String?,
          dernierStatut   : st['dernier_statut'] as String?,
          derniereOp      : st['derniere_op'] != null
              ? DateTime.tryParse(st['derniere_op'] as String)
              : null,
          soldeCaisseReel : soldeCaisseReel,
        ));
      } else {
        // Fallback : lire le journal de cette tontine individuellement
        final entrees = await BlockchainService.lireJournal(
          tontineCode: code,
          limit      : 200,
        );
        if (entrees.isNotEmpty) {
          final s = SoldeTontine.depuisEntrees(code, nom, entrees);
          soldes.add(s.copyWith(soldeCaisseReel: soldeCaisseReel));
        }
      }
    }

    if (mounted) setState(() => _soldes = soldes);
  }

  // ── Rafraîchissement silencieux ───────────────────────────────────────────

  Future<void> _rafraichir() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    try {
      await _chargerTontines();
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  // ── Synchronisation blockchain d'une tontine ──────────────────────────────

  Future<void> _syncUne(SoldeTontine s) async {
    if (_syncEnCours[s.code] == true) return;
    setState(() => _syncEnCours[s.code] = true);

    try {
      final res = await BlockchainService.syncBalanceTontine(
        tontineCode : s.code,
        soldeBrut   : s.soldeBrut,
        totalEntrees: s.totalEntrees,
        totalSorties: s.totalSorties,
        nbOps       : s.nbOps,
      );

      if (!mounted) return;
      if (res.ok) {
        final msg = _phase == 2
            ? '⛓ Solde synchronisé on-chain !\nTX: ${res.txHash?.substring(0, 18)}...'
            : '✅ Solde enregistré (SHA-256)';
        afficherToast(context, msg);
        await _rafraichir();
      } else {
        afficherToast(context, 'Erreur sync : ${res.erreur}', estErreur: true);
      }
    } catch (e) {
      if (mounted) afficherToast(context, 'Erreur : $e', estErreur: true);
    } finally {
      if (mounted) setState(() => _syncEnCours.remove(s.code));
    }
  }

  // ── Synchronisation de TOUTES les tontines ───────────────────────────────

  Future<void> _syncToutes() async {
    if (_syncTousEnCours) return;

    final confirmer = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.fondPapier,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Sync toutes les tontines',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
        content: Text(
          'Cela va envoyer ${_soldesFiltres.length} opérations de synchronisation '
          '${_phase == 2 ? "on-chain (Polygon Mainnet)" : "SHA-256"}.\n\n'
          'Continuer ?',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Annuler')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.encre),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Synchroniser',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    if (confirmer != true || !mounted) return;

    setState(() => _syncTousEnCours = true);
    int ok = 0; int err = 0;

    for (final s in _soldesFiltres) {
      try {
        final res = await BlockchainService.syncBalanceTontine(
          tontineCode : s.code,
          soldeBrut   : s.soldeBrut,
          totalEntrees: s.totalEntrees,
          totalSorties: s.totalSorties,
          nbOps       : s.nbOps,
        );
        if (res.ok) { ok++; } else { err++; }
      } catch (_) { err++; }
      // Délai entre chaque TX pour ne pas saturer le RPC
      await Future.delayed(const Duration(milliseconds: 500));
    }

    if (mounted) {
      setState(() => _syncTousEnCours = false);
      afficherToast(context,
          '$ok sync réussies${err > 0 ? ", $err erreurs" : ""}',
          estErreur: err > 0 && ok == 0);
      await _rafraichir();
    }
  }

  // ── Tri et filtre ─────────────────────────────────────────────────────────

  List<SoldeTontine> get _soldesFiltres {
    var liste = _soldes.where((s) {
      if (_recherche.isEmpty) return true;
      return s.code.toLowerCase().contains(_recherche.toLowerCase()) ||
             s.nom.toLowerCase().contains(_recherche.toLowerCase());
    }).toList();

    switch (_tri) {
      case 'solde_desc': { liste.sort((a, b) => b.soldeBrut.compareTo(a.soldeBrut)); }
      case 'solde_asc':  { liste.sort((a, b) => a.soldeBrut.compareTo(b.soldeBrut)); }
      case 'nom':        { liste.sort((a, b) => a.nom.compareTo(b.nom)); }
      case 'ops':        { liste.sort((a, b) => b.nbOps.compareTo(a.nbOps)); }
      case 'onchain':    { liste.sort((a, b) => b.nbOnChain.compareTo(a.nbOnChain)); }
    }
    return liste;
  }

  // ── Totaux ────────────────────────────────────────────────────────────────

  int get _totalSolde     => _soldes.fold(0, (s, e) => s + e.soldeBrut);
  int get _totalEntrees   => _soldes.fold(0, (s, e) => s + e.totalEntrees);
  int get _totalSorties   => _soldes.fold(0, (s, e) => s + e.totalSorties);
  int get _totalOnChain   => _soldes.fold(0, (s, e) => s + e.nbOnChain);
  int get _totalOps       => _soldes.fold(0, (s, e) => s + e.nbOps);
  int get _nbDivergences  => _soldes.where((s) => s.diverge).length;

  // ═══════════════════════════════════════════════════════════════════════════
  // BUILD
  // ═══════════════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _buildBandeauPhase(),
        _buildEnTete(),
        if (!_loading) _buildResume(),
        if (!_loading) _buildBarreOutils(),
        Expanded(child: _buildCorps()),
      ],
    );
  }

  // ── Bandeau Phase 1 / Phase 2 ────────────────────────────────────────────

  Widget _buildBandeauPhase() {
    final isPhase2 = _phase == 2;
    final contrat  = _contractInfo?['contract_address'] as String?;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: isPhase2
            ? const Color(0xFF0D3B26)
            : const Color(0xFF1C2447).withValues(alpha: 0.08),
        border: Border(
          bottom: BorderSide(
            color: isPhase2 ? const Color(0xFF00C853) : AppColors.lignes,
            width: 1,
          ),
        ),
      ),
      child: Row(
        children: [
          Icon(
            isPhase2 ? Icons.bolt_rounded : Icons.lock_outline,
            size: 14,
            color: isPhase2 ? const Color(0xFF00C853) : AppColors.texteDoux,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              isPhase2
                  ? 'Phase 2 — Polygon Mainnet · ${contrat != null ? "${contrat.substring(0, 8)}...${contrat.substring(contrat.length - 6)}" : "Contrat actif"}'
                  : 'Phase 1 — Preuves SHA-256 (secrets Supabase non configurés)',
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: isPhase2
                    ? const Color(0xFF00C853)
                    : AppColors.texteDoux,
                fontFamily: isPhase2 ? 'monospace' : null,
              ),
            ),
          ),
          if (_refreshing)
            const SizedBox(
              width: 12, height: 12,
              child: CircularProgressIndicator(
                strokeWidth: 1.5,
                color: AppColors.encreDoux,
              ),
            ),
        ],
      ),
    );
  }

  // ── En-tête ───────────────────────────────────────────────────────────────

  Widget _buildEnTete() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 8),
      child: Row(
        children: [
          const Icon(Icons.account_balance_wallet_rounded,
              size: 20, color: AppColors.encre),
          const SizedBox(width: 8),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Soldes & Blockchain',
                    style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 16,
                        color: AppColors.encre)),
                Text('Suivi des caisses synchronisées on-chain',
                    style: TextStyle(fontSize: 11.5, color: AppColors.texteDoux)),
              ],
            ),
          ),
          // Bouton refresh
          IconButton(
            onPressed: _loading ? null : _rafraichir,
            icon: const Icon(Icons.refresh_rounded, size: 20),
            color: AppColors.encreDoux,
            tooltip: 'Rafraîchir',
          ),
          // Bouton sync toutes
          if (_soldes.isNotEmpty)
            GestureDetector(
              onTap: _syncTousEnCours ? null : _syncToutes,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: _syncTousEnCours
                      ? AppColors.lignes
                      : AppColors.encre,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: _syncTousEnCours
                    ? const SizedBox(
                        width: 14, height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                      )
                    : const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.sync_rounded, size: 13, color: Colors.white),
                          SizedBox(width: 4),
                          Text('Sync tout',
                              style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white)),
                        ],
                      ),
              ),
            ),
        ],
      ),
    );
  }

  // ── Résumé global ─────────────────────────────────────────────────────────

  Widget _buildResume() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.encre,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text('Caisse totale consolidée',
                    style: TextStyle(
                        color: Colors.white70, fontSize: 11.5,
                        fontWeight: FontWeight.w500)),
                const Spacer(),
                Text('${_soldes.length} tontines',
                    style: const TextStyle(
                        color: Colors.white54, fontSize: 11)),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              Formatters.montant(_totalSolde, devise: 'XOF'),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.5,
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                _MiniStat(
                  icone: Icons.arrow_downward_rounded,
                  label: 'Entrées',
                  valeur: Formatters.montant(_totalEntrees, devise: 'XOF'),
                  couleur: const Color(0xFF4CAF50),
                ),
                const SizedBox(width: 12),
                _MiniStat(
                  icone: Icons.arrow_upward_rounded,
                  label: 'Sorties',
                  valeur: Formatters.montant(_totalSorties, devise: 'XOF'),
                  couleur: const Color(0xFFEF5350),
                ),
                const SizedBox(width: 12),
                _MiniStat(
                  icone: Icons.bolt_rounded,
                  label: 'On-chain',
                  valeur: '$_totalOnChain / $_totalOps',
                  couleur: const Color(0xFF00C853),
                ),
              ],
            ),
            // ── Alerte divergences globale ──────────────────────────────────
            if (_nbDivergences > 0) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                decoration: BoxDecoration(
                  color: const Color(0xFFE65100).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: const Color(0xFFFF9800).withValues(alpha: 0.6),
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.warning_amber_rounded,
                        size: 15, color: Color(0xFFFF9800)),
                    const SizedBox(width: 6),
                    Text(
                      '$_nbDivergences tontine${_nbDivergences > 1 ? "s" : ""} '
                      'avec divergence blockchain ≠ réel — Sync recommandée !',
                      style: const TextStyle(
                          fontSize: 11.5,
                          color: Color(0xFFFF9800),
                          fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ── Barre d'outils : recherche + tri ─────────────────────────────────────

  Widget _buildBarreOutils() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Row(
        children: [
          // Recherche
          Expanded(
            child: SizedBox(
              height: 36,
              child: TextField(
                controller: _rechercheCtrl,
                onChanged: (v) => setState(() => _recherche = v),
                style: const TextStyle(fontSize: 13),
                decoration: InputDecoration(
                  hintText: 'Rechercher une tontine...',
                  hintStyle: const TextStyle(fontSize: 13),
                  prefixIcon: const Icon(Icons.search_rounded,
                      size: 16, color: AppColors.texteDoux),
                  suffixIcon: _recherche.isNotEmpty
                      ? GestureDetector(
                          onTap: () {
                            _rechercheCtrl.clear();
                            setState(() => _recherche = '');
                          },
                          child: const Icon(Icons.clear_rounded,
                              size: 16, color: AppColors.texteDoux),
                        )
                      : null,
                  filled: true,
                  fillColor: Colors.white,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: AppColors.lignes),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: AppColors.lignes),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(
                        color: AppColors.encre.withValues(alpha: 0.4)),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          // Tri
          Container(
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.lignes),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: _tri,
                isDense: true,
                style: const TextStyle(
                    fontSize: 12.5,
                    color: AppColors.encre,
                    fontWeight: FontWeight.w600),
                items: const [
                  DropdownMenuItem(value: 'solde_desc',
                      child: Text('Solde ↓')),
                  DropdownMenuItem(value: 'solde_asc',
                      child: Text('Solde ↑')),
                  DropdownMenuItem(value: 'nom',
                      child: Text('Nom A→Z')),
                  DropdownMenuItem(value: 'ops',
                      child: Text('Nb ops')),
                  DropdownMenuItem(value: 'onchain',
                      child: Text('On-chain')),
                ],
                onChanged: (v) => setState(() => _tri = v!),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Corps principal ───────────────────────────────────────────────────────

  Widget _buildCorps() {
    if (_loading) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(color: AppColors.encre, strokeWidth: 2.5),
            SizedBox(height: 16),
            Text('Chargement des soldes...',
                style: TextStyle(color: AppColors.texteDoux, fontSize: 14)),
          ],
        ),
      );
    }

    if (_erreur != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline_rounded,
                size: 48, color: AppColors.alerte),
            const SizedBox(height: 12),
            Text(_erreur!,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: AppColors.texteDoux, fontSize: 14)),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: _charger,
              icon: const Icon(Icons.refresh_rounded, size: 16),
              label: const Text('Réessayer'),
              style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.encre,
                  foregroundColor: Colors.white),
            ),
          ],
        ),
      );
    }

    final liste = _soldesFiltres;

    if (liste.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.account_balance_wallet_outlined,
                size: 52,
                color: AppColors.texteDoux.withValues(alpha: 0.4)),
            const SizedBox(height: 12),
            Text(
              _tontines.isEmpty
                  ? 'Aucune tontine trouvée.'
                  : _recherche.isNotEmpty
                      ? 'Aucun résultat pour "$_recherche".'
                      : 'Aucune tontine avec des opérations blockchain.',
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: AppColors.texteDoux, fontSize: 15),
            ),
            if (_tontines.isNotEmpty && _recherche.isEmpty) ...[
              const SizedBox(height: 8),
              const Text(
                'Les soldes apparaissent dès qu\'une\nopération est enregistrée sur la blockchain.',
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: AppColors.texteDoux,
                    fontSize: 12.5),
              ),
            ],
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      itemCount: liste.length,
      itemBuilder: (_, i) => _CarteSolde(
        solde       : liste[i],
        phase       : _phase,
        syncEnCours : _syncEnCours[liste[i].code] == true,
        onSync      : () => _syncUne(liste[i]),
        onCopier    : (hash) {
          Clipboard.setData(ClipboardData(text: hash));
          afficherToast(context, 'TX copiée !');
        },
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// WIDGET CARTE SOLDE
// ═══════════════════════════════════════════════════════════════════════════════

class _CarteSolde extends StatelessWidget {
  final SoldeTontine solde;
  final int          phase;
  final bool         syncEnCours;
  final VoidCallback onSync;
  final void Function(String hash) onCopier;

  const _CarteSolde({
    required this.solde,
    required this.phase,
    required this.syncEnCours,
    required this.onSync,
    required this.onCopier,
  });

  @override
  Widget build(BuildContext context) {
    final isPositif  = solde.soldeBrut >= 0;
    final isZero     = solde.soldeBrut == 0 && solde.nbOps == 0;
    final hasOnChain = solde.nbOnChain > 0;
    final txCourt    = solde.dernierTxHash != null
        ? '${solde.dernierTxHash!.substring(0, 10)}...${solde.dernierTxHash!.substring(solde.dernierTxHash!.length - 6)}'
        : null;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: hasOnChain && phase == 2
              ? const Color(0xFF00C853).withValues(alpha: 0.3)
              : AppColors.lignes,
          width: hasOnChain && phase == 2 ? 1.5 : 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Ligne 1 : nom + solde ───────────────────────────────────────
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Indicateur couleur
                Container(
                  width: 4,
                  height: 48,
                  margin: const EdgeInsets.only(right: 10),
                  decoration: BoxDecoration(
                    color: isZero
                        ? AppColors.lignes
                        : isPositif
                            ? AppColors.succes
                            : AppColors.alerte,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        solde.nom,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                          color: AppColors.encre,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Text(
                            'Code : ${solde.code}',
                            style: const TextStyle(
                              fontSize: 11.5,
                              fontFamily: 'monospace',
                              color: AppColors.encreDoux,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(width: 8),
                          // Badge Phase
                          if (hasOnChain && phase == 2)
                            _BadgePetit(
                              label: '⚡ On-chain',
                              fond: const Color(0xFF0D3B26),
                              texte: const Color(0xFF00C853),
                            )
                          else
                            _BadgePetit(
                              label: '🔒 SHA-256',
                              fond: AppColors.fondSecondaire,
                              texte: AppColors.texteDoux,
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                // Solde
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      isZero ? '—' : Formatters.montant(solde.soldeBrut.abs(), devise: 'XOF'),
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                        color: isZero
                            ? AppColors.texteDoux
                            : isPositif
                                ? AppColors.succes
                                : AppColors.alerte,
                      ),
                    ),
                    if (!isZero)
                      Text(
                        isPositif ? 'en caisse' : 'déficit',
                        style: TextStyle(
                          fontSize: 10.5,
                          color: isPositif ? AppColors.succes : AppColors.alerte,
                        ),
                      ),
                  ],
                ),
              ],
            ),

            // ── Ligne 2 : entrées / sorties / ops ─────────────────────────
            if (!isZero) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  _InfoPetite(
                    icone: Icons.arrow_downward_rounded,
                    label: Formatters.montant(solde.totalEntrees, devise: 'XOF'),
                    couleur: const Color(0xFF4CAF50),
                  ),
                  const SizedBox(width: 12),
                  _InfoPetite(
                    icone: Icons.arrow_upward_rounded,
                    label: Formatters.montant(solde.totalSorties, devise: 'XOF'),
                    couleur: const Color(0xFFEF5350),
                  ),
                  const Spacer(),
                  Text(
                    '${solde.nbOps} op${solde.nbOps > 1 ? "s" : ""}',
                    style: const TextStyle(
                        fontSize: 11.5, color: AppColors.texteDoux),
                  ),
                  if (solde.nbOnChain > 0) ...[
                    const SizedBox(width: 6),
                    Text(
                      '· ${solde.nbOnChain} ⚡',
                      style: const TextStyle(
                          fontSize: 11.5, color: Color(0xFF00C853)),
                    ),
                  ],
                ],
              ),
            ],

            // ── Ligne 2b : alerte divergence blockchain vs réel ────────────
            if (solde.soldeCaisseReel != null && solde.diverge) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF3E0),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFFFF9800), width: 1),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.warning_amber_rounded,
                        size: 14, color: Color(0xFFE65100)),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Divergence détectée : blockchain ${Formatters.montant(solde.soldeBrut.abs(), devise: "XOF")} '
                        'vs réel ${Formatters.montant(solde.soldeCaisseReel!.abs(), devise: "XOF")} '
                        '(${solde.ecartPourcentage!.toStringAsFixed(1)}%). Synchroniser pour corriger.',
                        style: const TextStyle(
                            fontSize: 11,
                            color: Color(0xFFE65100),
                            fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              ),
            ],

            // ── Ligne 2c : solde réel Supabase (confirmé) ─────────────────
            if (solde.soldeCaisseReel != null && !solde.diverge && solde.soldeCaisseReel != 0) ...[
              const SizedBox(height: 6),
              Row(
                children: [
                  const Icon(Icons.verified_rounded, size: 12, color: Color(0xFF4CAF50)),
                  const SizedBox(width: 4),
                  Text(
                    'Solde Supabase confirmé : ${Formatters.montant(solde.soldeCaisseReel!.abs(), devise: "XOF")}',
                    style: const TextStyle(
                        fontSize: 11, color: Color(0xFF4CAF50),
                        fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ],

            // ── Ligne 3 : dernière TX hash ─────────────────────────────────
            if (txCourt != null) ...[
              const SizedBox(height: 8),
              GestureDetector(
                onTap: () => onCopier(solde.dernierTxHash!),
                child: Row(
                  children: [
                    const Icon(Icons.tag_rounded,
                        size: 12, color: AppColors.encreDoux),
                    const SizedBox(width: 4),
                    Text(
                      'TX : $txCourt',
                      style: const TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                        color: AppColors.encreDoux,
                        decoration: TextDecoration.underline,
                      ),
                    ),
                    const SizedBox(width: 4),
                    if (solde.dernierStatut == 'confirmed')
                      const Icon(Icons.check_circle_rounded,
                          size: 11, color: Color(0xFF00C853))
                    else
                      const Icon(Icons.hourglass_empty_rounded,
                          size: 11, color: AppColors.orFonce),
                  ],
                ),
              ),
            ],

            // ── Ligne 4 : dernière opération ───────────────────────────────
            if (solde.derniereOp != null) ...[
              const SizedBox(height: 2),
              Text(
                'Dernière op : ${Formatters.dateHeure(solde.derniereOp)}',
                style: const TextStyle(
                    fontSize: 11, color: AppColors.texteDoux),
              ),
            ],

            // ── Bouton Sync ────────────────────────────────────────────────
            const SizedBox(height: 10),
            const Divider(height: 1, color: AppColors.lignes),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: syncEnCours
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.symmetric(vertical: 6),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            SizedBox(
                              width: 14, height: 14,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: AppColors.encre,
                              ),
                            ),
                            SizedBox(width: 8),
                            Text('Synchronisation en cours...',
                                style: TextStyle(
                                    fontSize: 12.5,
                                    color: AppColors.texteDoux)),
                          ],
                        ),
                      ),
                    )
                  : OutlinedButton.icon(
                      onPressed: onSync,
                      icon: Icon(
                        phase == 2
                            ? Icons.bolt_rounded
                            : Icons.lock_outline_rounded,
                        size: 15,
                        color: phase == 2
                            ? const Color(0xFF00C853)
                            : AppColors.encreDoux,
                      ),
                      label: Text(
                        phase == 2
                            ? 'Synchroniser on-chain ⚡'
                            : 'Enregistrer preuve SHA-256',
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: phase == 2
                              ? const Color(0xFF00C853)
                              : AppColors.encreDoux,
                        ),
                      ),
                      style: OutlinedButton.styleFrom(
                        side: BorderSide(
                          color: phase == 2
                              ? const Color(0xFF00C853).withValues(alpha: 0.5)
                              : AppColors.lignes,
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8)),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// WIDGETS UTILITAIRES
// ═══════════════════════════════════════════════════════════════════════════════

class _MiniStat extends StatelessWidget {
  final IconData icone;
  final String   label;
  final String   valeur;
  final Color    couleur;
  const _MiniStat({
    required this.icone,
    required this.label,
    required this.valeur,
    required this.couleur,
  });

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(children: [
        Icon(icone, size: 11, color: couleur),
        const SizedBox(width: 3),
        Text(label,
            style: TextStyle(
                fontSize: 10, color: couleur, fontWeight: FontWeight.w600)),
      ]),
      Text(valeur,
          style: const TextStyle(
              fontSize: 11.5, color: Colors.white70,
              fontWeight: FontWeight.w700)),
    ],
  );
}

class _InfoPetite extends StatelessWidget {
  final IconData icone;
  final String   label;
  final Color    couleur;
  const _InfoPetite({
    required this.icone,
    required this.label,
    required this.couleur,
  });

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icone, size: 12, color: couleur),
      const SizedBox(width: 3),
      Text(label,
          style: TextStyle(
              fontSize: 11.5,
              color: couleur,
              fontWeight: FontWeight.w600)),
    ],
  );
}

class _BadgePetit extends StatelessWidget {
  final String label;
  final Color  fond;
  final Color  texte;
  const _BadgePetit({required this.label, required this.fond, required this.texte});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: fond,
      borderRadius: BorderRadius.circular(4),
    ),
    child: Text(label,
        style: TextStyle(
            fontSize: 10, fontWeight: FontWeight.w700, color: texte)),
  );
}
