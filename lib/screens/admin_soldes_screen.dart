// ═══════════════════════════════════════════════════════════════════════════════
// AdminSoldesScreen  —  TC Admin
// Suivi temps réel des soldes blockchain par tontine.
// Polling automatique toutes les 30 s.
// Phase 1 = SHA-256 / Phase 2 = TX Polygon Mainnet.
// ═══════════════════════════════════════════════════════════════════════════════

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/blockchain_service.dart';
import '../utils/app_colors.dart';

// ── Modèle solde tontine ──────────────────────────────────────────────────────
class SoldeTontine {
  final String code;
  final int    soldeBrut;
  final int    totalEntrees;
  final int    totalSorties;
  final int    nbOps;
  final String phase;
  final String? lastSync;
  final String? lastTxHash;

  const SoldeTontine({
    required this.code,
    required this.soldeBrut,
    required this.totalEntrees,
    required this.totalSorties,
    required this.nbOps,
    required this.phase,
    this.lastSync,
    this.lastTxHash,
  });

  factory SoldeTontine.fromJson(Map<String, dynamic> j) {
    return SoldeTontine(
      code          : j['code']           as String? ?? j['tontine_code'] as String? ?? '?',
      soldeBrut     : (j['solde_brut']    as num?)?.toInt() ?? 0,
      totalEntrees  : (j['total_entrees'] as num?)?.toInt() ?? 0,
      totalSorties  : (j['total_sorties'] as num?)?.toInt() ?? 0,
      nbOps         : (j['nb_ops']        as num?)?.toInt() ?? 0,
      phase         : j['phase']          as String? ?? 'phase1',
      lastSync      : j['last_sync']      as String?,
      lastTxHash    : j['last_tx_hash']   as String?,
    );
  }

  String get soldeFormate {
    final absVal = soldeBrut.abs();
    final sign   = soldeBrut < 0 ? '-' : '';
    final s      = absVal.toString();
    final buf    = StringBuffer();
    for (int i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(' ');
      buf.write(s[i]);
    }
    return '$sign${buf.toString()} XOF';
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Widget principal
// ═══════════════════════════════════════════════════════════════════════════════
class AdminSoldesScreen extends StatefulWidget {
  final String cleAdmin;
  const AdminSoldesScreen({super.key, required this.cleAdmin});

  @override
  State<AdminSoldesScreen> createState() => _AdminSoldesScreenState();
}

class _AdminSoldesScreenState extends State<AdminSoldesScreen> {
  List<SoldeTontine> _soldes      = [];
  bool               _loading     = true;
  String?            _erreur;
  bool               _phase2      = false;
  Timer?             _timer;
  String             _tri         = 'solde_desc';
  String             _recherche   = '';
  final Map<String, bool> _syncEnCours = {};

  // ── Lifecycle ──────────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    _charger();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _charger());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  // ── Chargement ─────────────────────────────────────────────────────────────
  Future<void> _charger() async {
    if (!mounted) return;
    try {
      final rep = await BlockchainService.statsSoldes();
      if (!mounted) return;

      final raw     = rep['tontines'] as List<dynamic>? ?? [];
      final soldes  = raw.map((e) => SoldeTontine.fromJson(e as Map<String, dynamic>)).toList();
      final phase2  = rep['phase2_active'] == true;

      setState(() {
        _soldes  = _trier(soldes);
        _phase2  = phase2;
        _loading = false;
        _erreur  = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _erreur  = 'Erreur de chargement : $e';
      });
    }
  }

  // ── Tri ────────────────────────────────────────────────────────────────────
  List<SoldeTontine> _trier(List<SoldeTontine> src) {
    final list = List<SoldeTontine>.from(src);
    switch (_tri) {
      case 'solde_desc':  list.sort((a, b) => b.soldeBrut.compareTo(a.soldeBrut));
      case 'solde_asc':   list.sort((a, b) => a.soldeBrut.compareTo(b.soldeBrut));
      case 'ops_desc':    list.sort((a, b) => b.nbOps.compareTo(a.nbOps));
      case 'code_asc':    list.sort((a, b) => a.code.compareTo(b.code));
    }
    return list;
  }

  List<SoldeTontine> get _soldesFiltres {
    final q = _recherche.trim().toLowerCase();
    final src = _trier(_soldes);
    if (q.isEmpty) return src;
    return src.where((s) => s.code.toLowerCase().contains(q)).toList();
  }

  // ── Sync individuelle ───────────────────────────────────────────────────────
  Future<void> _syncTontine(SoldeTontine s) async {
    setState(() => _syncEnCours[s.code] = true);
    try {
      final res = await BlockchainService.syncBalanceTontine(
        tontineCode  : s.code,
        soldeBrut    : s.soldeBrut,
        totalEntrees : s.totalEntrees,
        totalSorties : s.totalSorties,
        nbOps        : s.nbOps,
      );
      if (!mounted) return;
      if (res.ok) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('✅ ${s.code} synchronisé (${res.phase})'),
          backgroundColor: AppColors.succes,
          duration: const Duration(seconds: 3),
        ));
        await _charger();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('❌ Échec sync ${s.code} : ${res.erreur}'),
          backgroundColor: AppColors.alerte,
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Erreur : $e'),
          backgroundColor: AppColors.alerte,
        ));
      }
    } finally {
      if (mounted) setState(() => _syncEnCours.remove(s.code));
    }
  }

  // ── Sync tout ───────────────────────────────────────────────────────────────
  Future<void> _syncTout() async {
    final liste = _soldesFiltres;
    if (liste.isEmpty) return;
    int ok = 0; int echec = 0;
    for (final s in liste) {
      if (!mounted) break;
      setState(() => _syncEnCours[s.code] = true);
      try {
        final res = await BlockchainService.syncBalanceTontine(
          tontineCode  : s.code,
          soldeBrut    : s.soldeBrut,
          totalEntrees : s.totalEntrees,
          totalSorties : s.totalSorties,
          nbOps        : s.nbOps,
        );
        res.ok ? ok++ : echec++;
      } catch (_) {
        echec++;
      } finally {
        if (mounted) setState(() => _syncEnCours.remove(s.code));
      }
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Sync terminée : ✅ $ok  ❌ $echec'),
      backgroundColor: ok > 0 ? AppColors.succes : AppColors.alerte,
      duration: const Duration(seconds: 4),
    ));
    await _charger();
  }

  // ── Résumé global ──────────────────────────────────────────────────────────
  int get _soldeTotal    => _soldes.fold(0, (acc, s) => acc + s.soldeBrut);
  int get _entreesTotal  => _soldes.fold(0, (acc, s) => acc + s.totalEntrees);
  int get _sortiesTotal  => _soldes.fold(0, (acc, s) => acc + s.totalSorties);
  int get _opsTotal      => _soldes.fold(0, (acc, s) => acc + s.nbOps);

  // ── Build ──────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _BandeauPhase(phase2: _phase2),
        _BarreOutils(
          recherche : _recherche,
          tri       : _tri,
          loading   : _loading,
          onRecherche : (v) => setState(() => _recherche = v),
          onTri       : (v) => setState(() => _tri = v),
          onRefresh   : _charger,
          onSyncTout  : _syncTout,
        ),
        if (_erreur != null)
          _BandeauErreur(erreur: _erreur!, onRetry: _charger),
        if (!_loading && _soldes.isNotEmpty)
          _CarteResume(
            soldeTotal   : _soldeTotal,
            entreesTotal : _entreesTotal,
            sortiesTotal : _sortiesTotal,
            opsTotal     : _opsTotal,
            nbTontines   : _soldes.length,
          ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator(color: AppColors.encre))
              : _soldesFiltres.isEmpty
                  ? _VueVide(recherche: _recherche)
                  : RefreshIndicator(
                      onRefresh : _charger,
              color     : AppColors.encre,
              child     : ListView.builder(
                        padding     : const EdgeInsets.fromLTRB(12, 4, 12, 24),
                        itemCount   : _soldesFiltres.length,
                        itemBuilder : (ctx, i) {
                          final s = _soldesFiltres[i];
                          return _CarteSolde(
                            solde        : s,
                            syncEnCours  : _syncEnCours[s.code] == true,
                            onSync       : () => _syncTontine(s),
                          );
                        },
                      ),
                    ),
        ),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Widgets internes
// ═══════════════════════════════════════════════════════════════════════════════

class _BandeauPhase extends StatelessWidget {
  final bool phase2;
  const _BandeauPhase({required this.phase2});

  @override
  Widget build(BuildContext context) {
    final couleur = phase2 ? const Color(0xFF1565C0) : const Color(0xFF6A1B9A);
    final label   = phase2 ? 'Phase 2 — TX Polygon Mainnet actives' : 'Phase 1 — Preuve SHA-256 (secrets Supabase non configurés)';
    final icone   = phase2 ? Icons.verified_rounded : Icons.shield_outlined;
    return Container(
      width: double.infinity,
      color: couleur.withValues(alpha: 0.10),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Icon(icone, size: 16, color: couleur),
          const SizedBox(width: 8),
          Expanded(child: Text(label,
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: couleur))),
        ],
      ),
    );
  }
}

class _BarreOutils extends StatelessWidget {
  final String   recherche;
  final String   tri;
  final bool     loading;
  final ValueChanged<String> onRecherche;
  final ValueChanged<String> onTri;
  final VoidCallback onRefresh;
  final VoidCallback onSyncTout;

  const _BarreOutils({
    required this.recherche,
    required this.tri,
    required this.loading,
    required this.onRecherche,
    required this.onTri,
    required this.onRefresh,
    required this.onSyncTout,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
      child: Column(
        children: [
          // Recherche
          TextField(
            decoration: InputDecoration(
              hintText    : 'Rechercher une tontine…',
              prefixIcon  : const Icon(Icons.search_rounded, size: 20),
              filled      : true,
              fillColor   : Colors.white,
              isDense     : true,
              border      : OutlineInputBorder(borderRadius: BorderRadius.circular(10),
                                borderSide: BorderSide.none),
              contentPadding: const EdgeInsets.symmetric(vertical: 10),
            ),
            onChanged: onRecherche,
          ),
          const SizedBox(height: 8),
          // Tri + boutons
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  initialValue : tri,
                  isDense      : true,
                  decoration   : InputDecoration(
                    filled     : true,
                    fillColor  : Colors.white,
                    isDense    : true,
                    border     : OutlineInputBorder(borderRadius: BorderRadius.circular(10),
                                    borderSide: BorderSide.none),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  ),
                  items: const [
                    DropdownMenuItem(value: 'solde_desc', child: Text('Solde ↓', style: TextStyle(fontSize: 13))),
                    DropdownMenuItem(value: 'solde_asc',  child: Text('Solde ↑', style: TextStyle(fontSize: 13))),
                    DropdownMenuItem(value: 'ops_desc',   child: Text('Opérations ↓', style: TextStyle(fontSize: 13))),
                    DropdownMenuItem(value: 'code_asc',   child: Text('Code A→Z', style: TextStyle(fontSize: 13))),
                  ],
                  onChanged: (v) { if (v != null) onTri(v); },
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                onPressed : loading ? null : onRefresh,
                icon      : loading
                    ? const SizedBox(width: 18, height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.refresh_rounded),
                tooltip   : 'Actualiser',
                style     : IconButton.styleFrom(
                  backgroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
              const SizedBox(width: 6),
              ElevatedButton.icon(
                onPressed : loading ? null : onSyncTout,
                icon      : const Icon(Icons.sync_rounded, size: 16),
                label     : const Text('Sync tout', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                style     : ElevatedButton.styleFrom(
                  backgroundColor: AppColors.encre,
                  foregroundColor: Colors.white,
                  elevation   : 0,
                  padding     : const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  shape       : RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _BandeauErreur extends StatelessWidget {
  final String erreur;
  final VoidCallback onRetry;
  const _BandeauErreur({required this.erreur, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin  : const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      padding : const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color        : AppColors.alerte.withValues(alpha: 0.08),
        border       : Border.all(color: AppColors.alerte.withValues(alpha: 0.3)),
        borderRadius : BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline_rounded, color: AppColors.alerte, size: 18),
          const SizedBox(width: 10),
          Expanded(child: Text(erreur, style: TextStyle(fontSize: 12, color: AppColors.alerte))),
          TextButton(onPressed: onRetry, child: const Text('Réessayer')),
        ],
      ),
    );
  }
}

class _CarteResume extends StatelessWidget {
  final int soldeTotal;
  final int entreesTotal;
  final int sortiesTotal;
  final int opsTotal;
  final int nbTontines;
  const _CarteResume({
    required this.soldeTotal,
    required this.entreesTotal,
    required this.sortiesTotal,
    required this.opsTotal,
    required this.nbTontines,
  });

  String _fmt(int v) {
    final s = v.abs().toString();
    final buf = StringBuffer();
    for (int i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(' ');
      buf.write(s[i]);
    }
    return '${v < 0 ? '-' : ''}${buf.toString()}';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin  : const EdgeInsets.fromLTRB(12, 0, 12, 8),
      padding : const EdgeInsets.all(14),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [AppColors.encre, AppColors.encre.withValues(alpha: 0.80)],
          begin: Alignment.topLeft, end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(color: AppColors.encre.withValues(alpha: 0.25),
              blurRadius: 12, offset: const Offset(0, 4)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.account_balance_wallet_rounded, color: Colors.white, size: 18),
              const SizedBox(width: 8),
              Text('Résumé global — $nbTontines tontine${nbTontines > 1 ? 's' : ''}',
                  style: const TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 10),
          Text('${_fmt(soldeTotal)} XOF',
              style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w900)),
          const SizedBox(height: 10),
          Row(children: [
            _StatChip(label: 'Entrées', valeur: '${_fmt(entreesTotal)} XOF', couleur: Colors.greenAccent),
            const SizedBox(width: 8),
            _StatChip(label: 'Sorties', valeur: '${_fmt(sortiesTotal)} XOF', couleur: Colors.redAccent),
            const SizedBox(width: 8),
            _StatChip(label: 'Ops', valeur: '$opsTotal', couleur: Colors.white70),
          ]),
        ],
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  final String label;
  final String valeur;
  final Color  couleur;
  const _StatChip({required this.label, required this.valeur, required this.couleur});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding : const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color        : Colors.white.withValues(alpha: 0.12),
          borderRadius : BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: TextStyle(fontSize: 10, color: couleur, fontWeight: FontWeight.w600)),
            const SizedBox(height: 2),
            Text(valeur, style: const TextStyle(fontSize: 11, color: Colors.white, fontWeight: FontWeight.w700),
                overflow: TextOverflow.ellipsis),
          ],
        ),
      ),
    );
  }
}

// ── Carte par tontine ─────────────────────────────────────────────────────────
class _CarteSolde extends StatelessWidget {
  final SoldeTontine solde;
  final bool         syncEnCours;
  final VoidCallback onSync;

  const _CarteSolde({
    required this.solde,
    required this.syncEnCours,
    required this.onSync,
  });

  Color get _couleurSolde {
    if (solde.soldeBrut > 0)  return const Color(0xFF2E7D32);
    if (solde.soldeBrut < 0)  return AppColors.alerte;
    return AppColors.texteDoux;
  }

  @override
  Widget build(BuildContext context) {
    final isPhase2 = solde.phase == 'phase2';
    return Card(
      margin       : const EdgeInsets.only(bottom: 10),
      elevation    : 0,
      shape        : RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side        : BorderSide(color: AppColors.lignes, width: 1),
      ),
      color: Colors.white,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Ligne 1 : code + badge phase + bouton sync ────────────────────
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color        : AppColors.encre.withValues(alpha: 0.08),
                    borderRadius : BorderRadius.circular(8),
                  ),
                  child: Text(solde.code,
                      style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14,
                          color: AppColors.encre)),
                ),
                const SizedBox(width: 8),
                _BadgePhase(phase: solde.phase),
                const Spacer(),
                syncEnCours
                    ? const SizedBox(width: 20, height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2,
                            color: AppColors.encre))
                    : IconButton(
                        onPressed : onSync,
                        icon      : const Icon(Icons.sync_rounded, size: 18,
                            color: AppColors.encre),
                        tooltip   : 'Synchroniser ce solde on-chain',
                        style     : IconButton.styleFrom(
                          backgroundColor: AppColors.encre.withValues(alpha: 0.08),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          minimumSize: const Size(36, 36),
                        ),
                      ),
              ],
            ),
            const SizedBox(height: 10),
            // ── Solde ─────────────────────────────────────────────────────────
            Text(solde.soldeFormate,
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900,
                    color: _couleurSolde)),
            const SizedBox(height: 8),
            // ── Stats ─────────────────────────────────────────────────────────
            Row(children: [
              _MiniStat(label: 'Entrées', valeur: '${solde.totalEntrees} XOF',
                  couleur: const Color(0xFF2E7D32)),
              const SizedBox(width: 8),
              _MiniStat(label: 'Sorties', valeur: '${solde.totalSorties} XOF',
                  couleur: AppColors.alerte),
              const SizedBox(width: 8),
              _MiniStat(label: 'Ops', valeur: '${solde.nbOps}',
                  couleur: AppColors.texteDoux),
            ]),
            // ── Dernière TX Phase 2 : libellé métier + bouton détails ─────────
            if (isPhase2 && solde.lastTxHash != null) ...[
              const SizedBox(height: 8),
              Row(children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1565C0).withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Row(children: [
                    Text('⚡', style: TextStyle(fontSize: 11)),
                    SizedBox(width: 4),
                    Text('🔄  Sync on-chain confirmée',
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                            color: Color(0xFF1565C0))),
                  ]),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: () => _voirDetailsTxSolde(context, solde),
                  icon: const Icon(Icons.code_rounded, size: 12),
                  label: const Text('Détails TX', style: TextStyle(fontSize: 11)),
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFF1565C0),
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ]),
            ],
            // ── Dernière sync ────────────────────────────────────────────────
            if (solde.lastSync != null) ...[
              const SizedBox(height: 4),
              Text('Dernière sync : ${_formaterDate(solde.lastSync!)}',
                  style: const TextStyle(fontSize: 10, color: AppColors.texteDoux)),
            ],
          ],
        ),
      ),
    );
  }

  String _formaterDate(String iso) {
    try {
      final d = DateTime.parse(iso).toLocal();
      return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year} '
             '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    } catch (_) { return iso; }
  }

  // ── Bottom sheet détails TX du solde ────────────────────────────────────
  static void _voirDetailsTxSolde(BuildContext context, SoldeTontine solde) {
    final hash = solde.lastTxHash!;
    final estRealTx = hash.length == 66;
    final hashCourt = hash.length > 18
        ? '${hash.substring(0, 10)}…${hash.substring(hash.length - 6)}'
        : hash;
    final polygonUrl = estRealTx ? 'https://polygonscan.com/tx/$hash' : '';

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Poignée
            Center(
              child: Container(
                margin: const EdgeInsets.only(bottom: 12),
                width: 36, height: 4,
                decoration: BoxDecoration(
                  color: AppColors.lignes,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            // En-tête
            Row(children: [
              const Text('🔄', style: TextStyle(fontSize: 22)),
              const SizedBox(width: 10),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Synchronisation on-chain',
                    style: TextStyle(fontWeight: FontWeight.w800,
                        fontSize: 14, color: AppColors.encre)),
                Text('Groupe ${solde.code}  •  ${solde.nbOps} opérations',
                    style: const TextStyle(fontSize: 11, color: AppColors.texteDoux)),
              ])),
              if (estRealTx)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1565C0).withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Text('⚡ Phase 2',
                      style: TextStyle(fontSize: 10, color: Color(0xFF1565C0),
                          fontWeight: FontWeight.w700)),
                ),
            ]),
            const Divider(height: 20, color: AppColors.lignes),
            // TX Hash
            const Text('TX Hash (Dernière synchronisation)',
                style: TextStyle(fontSize: 11, color: AppColors.texteDoux,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: SelectableText(
                hash,
                style: const TextStyle(fontSize: 10, fontFamily: 'monospace',
                    color: Color(0xFF1565C0)),
              )),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: () {
                  Clipboard.setData(ClipboardData(text: hash));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Hash TX copié'),
                        duration: Duration(seconds: 1)));
                },
                child: const Icon(Icons.copy_rounded, size: 16, color: AppColors.texteDoux),
              ),
            ]),
            if (solde.lastSync != null) ...[
              const SizedBox(height: 10),
              Text('Dernière sync : ${solde.lastSync}',
                  style: const TextStyle(fontSize: 11, color: AppColors.texteDoux)),
            ],
            // Bouton PolygonScan
            if (estRealTx) ...[
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () {
                    Navigator.pop(context);
                    Clipboard.setData(ClipboardData(text: polygonUrl));
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text('URL PolygonScan copiée : $hashCourt'),
                      duration: const Duration(seconds: 3),
                    ));
                  },
                  icon: const Icon(Icons.open_in_new_rounded, size: 16),
                  label: const Text('Ouvrir sur PolygonScan',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF1565C0),
                    side: const BorderSide(color: Color(0xFF1565C0)),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _BadgePhase extends StatelessWidget {
  final String phase;
  const _BadgePhase({required this.phase});

  @override
  Widget build(BuildContext context) {
    final isP2   = phase == 'phase2';
    final couleur = isP2 ? const Color(0xFF1565C0) : const Color(0xFF6A1B9A);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color        : couleur.withValues(alpha: 0.10),
        borderRadius : BorderRadius.circular(6),
        border       : Border.all(color: couleur.withValues(alpha: 0.3)),
      ),
      child: Text(isP2 ? 'Phase 2' : 'Phase 1',
          style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: couleur)),
    );
  }
}

class _MiniStat extends StatelessWidget {
  final String label;
  final String valeur;
  final Color  couleur;
  const _MiniStat({required this.label, required this.valeur, required this.couleur});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding : const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color        : couleur.withValues(alpha: 0.06),
          borderRadius : BorderRadius.circular(8),
          border       : Border.all(color: couleur.withValues(alpha: 0.15)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: TextStyle(fontSize: 10, color: couleur, fontWeight: FontWeight.w600)),
            const SizedBox(height: 2),
            Text(valeur, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700,
                color: AppColors.encre), overflow: TextOverflow.ellipsis),
          ],
        ),
      ),
    );
  }
}

class _VueVide extends StatelessWidget {
  final String recherche;
  const _VueVide({required this.recherche});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.account_balance_wallet_outlined, size: 52,
              color: AppColors.texteDoux.withValues(alpha: 0.4)),
          const SizedBox(height: 12),
          Text(
            recherche.isNotEmpty
                ? 'Aucune tontine ne correspond à "$recherche"'
                : 'Aucun solde disponible.\nVérifiez que le journal blockchain contient des opérations.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: AppColors.texteDoux.withValues(alpha: 0.7)),
          ),
        ],
      ),
    );
  }
}
