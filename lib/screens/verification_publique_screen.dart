// ═══════════════════════════════════════════════════════════════════════════════
// VerificationPubliqueScreen  —  TontineClair Phase 3
//
// Écran public (sans login requis) permettant à n'importe qui de vérifier
// les opérations blockchain d'une tontine via son code.
// Accessible depuis le bouton "Vérifier" du badge blockchain dans DetailScreen.
// ═══════════════════════════════════════════════════════════════════════════════

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/blockchain_service.dart';
import '../utils/app_colors.dart';

class VerificationPubliqueScreen extends StatefulWidget {
  /// Code tontine pré-rempli (optionnel — si null, l'utilisateur saisit)
  final String? codeTontine;
  /// Nom tontine affiché dans le titre (optionnel)
  final String? nomTontine;

  const VerificationPubliqueScreen({
    super.key,
    this.codeTontine,
    this.nomTontine,
  });

  @override
  State<VerificationPubliqueScreen> createState() =>
      _VerificationPubliqueScreenState();
}

class _VerificationPubliqueScreenState
    extends State<VerificationPubliqueScreen> {
  final _ctrl = TextEditingController();
  List<BlockchainEntry> _entrees = [];
  Map<String, dynamic> _contrat = {};
  bool _loading = false;
  bool _recherche = false;
  String? _erreur;
  String _codeActif = '';

  @override
  void initState() {
    super.initState();
    if (widget.codeTontine != null && widget.codeTontine!.isNotEmpty) {
      _ctrl.text = widget.codeTontine!;
      WidgetsBinding.instance.addPostFrameCallback((_) => _rechercher());
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  // ── Recherche ──────────────────────────────────────────────────────────────
  Future<void> _rechercher() async {
    final code = _ctrl.text.trim().toUpperCase();
    if (code.isEmpty) return;

    setState(() {
      _loading   = true;
      _recherche = true;
      _erreur    = null;
      _codeActif = code;
      _entrees   = [];
      _contrat   = {};
    });

    try {
      // Charger en parallèle : journal + infos contrat
      final results = await Future.wait([
        BlockchainService.lireJournal(tontineCode: code, limit: 100),
        BlockchainService.contractInfo(),
      ]);

      if (!mounted) return;
      setState(() {
        _entrees = results[0] as List<BlockchainEntry>;
        _contrat = results[1] as Map<String, dynamic>;
        _loading = false;
        if (_entrees.isEmpty) {
          _erreur = 'Aucune opération blockchain trouvée pour le code "$code".\n'
              'Vérifiez que le code est correct.';
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _erreur  = 'Erreur de connexion. Réessayez.';
      });
    }
  }

  // ── Copie dans le presse-papiers ───────────────────────────────────────────
  void _copier(String texte, String label) {
    Clipboard.setData(ClipboardData(text: texte));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$label copié'),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
        backgroundColor: AppColors.succes,
      ),
    );
  }

  // ── Statistiques rapides ───────────────────────────────────────────────────
  Map<String, int> get _stats {
    final map = <String, int>{};
    for (final e in _entrees) {
      map[e.typeOperation] = (map[e.typeOperation] ?? 0) + 1;
    }
    return map;
  }

  int get _countOnChain =>
      _entrees.where((e) => e.txHash != null && e.txHash!.length == 66).length;

  int get _totalXof => _entrees
      .where((e) => e.montantXof != null)
      .fold(0, (s, e) => s + (e.montantXof ?? 0));

  // ── Phase du contrat ───────────────────────────────────────────────────────
  int get _phase => (_contrat['phase'] as num?)?.toInt() ?? 1;
  String? get _contratAddress => _contrat['contract'] as String?;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.fondPapier,
      appBar: AppBar(
        backgroundColor: AppColors.encre,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Vérification Blockchain',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            Text(
              widget.nomTontine != null
                  ? widget.nomTontine!
                  : 'Polygon Amoy · TontineVault.sol',
              style: const TextStyle(fontSize: 11, color: Colors.white70),
            ),
          ],
        ),
        actions: [
          // Phase badge
          Container(
            margin: const EdgeInsets.only(right: 12),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: _phase == 2
                  ? const Color(0xFF00C853)
                  : Colors.orange.shade400,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              _phase == 2 ? '⚡ Phase 2' : '🔒 Phase 1',
              style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: Colors.white),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          // ── Barre de recherche ─────────────────────────────────────────────
          _BarreRecherche(ctrl: _ctrl, onRechercher: _rechercher),

          // ── Infos contrat ──────────────────────────────────────────────────
          if (_phase == 2 && _contratAddress != null)
            _BandeauContrat(
              address: _contratAddress!,
              onCopier: _copier,
            ),

          // ── Contenu ────────────────────────────────────────────────────────
          Expanded(
            child: _loading
                ? const Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        CircularProgressIndicator(color: AppColors.encre),
                        SizedBox(height: 16),
                        Text('Lecture du journal blockchain…',
                            style: TextStyle(color: AppColors.texteDoux)),
                      ],
                    ),
                  )
                : _erreur != null
                    ? _VueErreur(message: _erreur!, onRetry: _rechercher)
                    : !_recherche
                        ? const _VueAccueil()
                        : _VueResultats(
                            code       : _codeActif,
                            entrees    : _entrees,
                            stats      : _stats,
                            countOnChain: _countOnChain,
                            totalXof   : _totalXof,
                            onCopier   : _copier,
                          ),
          ),
        ],
      ),
    );
  }
}

// ── Barre de recherche ─────────────────────────────────────────────────────────
class _BarreRecherche extends StatelessWidget {
  final TextEditingController ctrl;
  final VoidCallback onRechercher;

  const _BarreRecherche({required this.ctrl, required this.onRechercher});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.encre,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: ctrl,
              textCapitalization: TextCapitalization.characters,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: 16,
                letterSpacing: 2,
              ),
              decoration: InputDecoration(
                hintText: 'Code tontine (ex: ABC123)',
                hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.5),
                    fontSize: 14, letterSpacing: 0),
                filled: true,
                fillColor: Colors.white.withValues(alpha: 0.1),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                prefixIcon: const Icon(Icons.search, color: Colors.white60),
              ),
              onSubmitted: (_) => onRechercher(),
            ),
          ),
          const SizedBox(width: 10),
          ElevatedButton(
            onPressed: onRechercher,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.or,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
              elevation: 0,
            ),
            child: const Text('Vérifier',
                style: TextStyle(fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }
}

// ── Bandeau contrat Phase 2 ────────────────────────────────────────────────────
class _BandeauContrat extends StatelessWidget {
  final String address;
  final void Function(String, String) onCopier;

  const _BandeauContrat({required this.address, required this.onCopier});

  String get _court =>
      '${address.substring(0, 8)}…${address.substring(address.length - 6)}';

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => onCopier(address, 'Adresse contrat'),
      child: Container(
        color: const Color(0xFF00C853).withValues(alpha: 0.1),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            const Icon(Icons.verified_outlined,
                size: 16, color: Color(0xFF00C853)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Smart contract : $_court · Polygon Amoy',
                style: const TextStyle(
                  fontSize: 12,
                  color: Color(0xFF00C853),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const Icon(Icons.copy, size: 14, color: Color(0xFF00C853)),
          ],
        ),
      ),
    );
  }
}

// ── Vue accueil (avant toute recherche) ───────────────────────────────────────
class _VueAccueil extends StatelessWidget {
  const _VueAccueil();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: AppColors.fondCode,
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Icon(Icons.verified_user_outlined,
                  size: 40, color: AppColors.encre),
            ),
            const SizedBox(height: 24),
            const Text(
              'Vérification publique',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w800,
                color: AppColors.encre,
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'Entrez le code d\'une tontine pour consulter toutes ses opérations enregistrées sur la blockchain Polygon.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: AppColors.texteDoux, height: 1.5),
            ),
            const SizedBox(height: 32),
            _InfoPuce(
              icone: Icons.lock_outline,
              texte: 'Données immuables — personne ne peut les modifier',
            ),
            const SizedBox(height: 12),
            _InfoPuce(
              icone: Icons.public,
              texte: 'Vérifiable par n\'importe qui, n\'importe quand',
            ),
            const SizedBox(height: 12),
            _InfoPuce(
              icone: Icons.link,
              texte: 'Chaque TX vérifiable sur PolygonScan',
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoPuce extends StatelessWidget {
  final IconData icone;
  final String texte;
  const _InfoPuce({required this.icone, required this.texte});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icone, size: 18, color: AppColors.encre),
        const SizedBox(width: 12),
        Expanded(
          child: Text(texte,
              style: const TextStyle(
                  fontSize: 13, color: AppColors.texte, height: 1.4)),
        ),
      ],
    );
  }
}

// ── Vue erreur ────────────────────────────────────────────────────────────────
class _VueErreur extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _VueErreur({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.search_off, size: 56, color: AppColors.texteDoux),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 14, color: AppColors.texteDoux, height: 1.5),
            ),
            const SizedBox(height: 24),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Réessayer'),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Vue résultats ─────────────────────────────────────────────────────────────
class _VueResultats extends StatelessWidget {
  final String code;
  final List<BlockchainEntry> entrees;
  final Map<String, int> stats;
  final int countOnChain;
  final int totalXof;
  final void Function(String, String) onCopier;

  const _VueResultats({
    required this.code,
    required this.entrees,
    required this.stats,
    required this.countOnChain,
    required this.totalXof,
    required this.onCopier,
  });

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // En-tête résultats
        _CarteResume(
          code        : code,
          totalEntrees: entrees.length,
          countOnChain: countOnChain,
          totalXof    : totalXof,
          stats       : stats,
        ),
        const SizedBox(height: 16),

        // Timeline des opérations
        const Text(
          'Journal des opérations',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: AppColors.encre,
          ),
        ),
        const SizedBox(height: 12),

        ...entrees.map((e) => _CarteEntree(entree: e, onCopier: onCopier)),
      ],
    );
  }
}

// ── Carte résumé ──────────────────────────────────────────────────────────────
class _CarteResume extends StatelessWidget {
  final String code;
  final int totalEntrees;
  final int countOnChain;
  final int totalXof;
  final Map<String, int> stats;

  const _CarteResume({
    required this.code,
    required this.totalEntrees,
    required this.countOnChain,
    required this.totalXof,
    required this.stats,
  });

  @override
  Widget build(BuildContext context) {
    final tauxOnChain = totalEntrees > 0
        ? (countOnChain / totalEntrees * 100).round()
        : 0;

    return Container(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [AppColors.encre, AppColors.encreDoux],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.verified_outlined, color: Colors.white, size: 20),
              const SizedBox(width: 8),
              Text(
                'Tontine · $code',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                  fontSize: 18,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '$countOnChain/$totalEntrees opérations on-chain ($tauxOnChain%)',
            style: TextStyle(
                color: Colors.white.withValues(alpha: 0.8), fontSize: 12),
          ),
          const SizedBox(height: 16),

          // Métriques
          Row(
            children: [
              _MetriqueChip(
                label: 'Opérations',
                valeur: '$totalEntrees',
                icone: Icons.list_alt,
              ),
              const SizedBox(width: 8),
              _MetriqueChip(
                label: 'On-chain ⚡',
                valeur: '$countOnChain',
                icone: Icons.bolt,
                couleur: const Color(0xFF00C853),
              ),
              const SizedBox(width: 8),
              _MetriqueChip(
                label: 'Volume XOF',
                valeur: _formatXof(totalXof),
                icone: Icons.attach_money,
              ),
            ],
          ),

          // Répartition par type
          if (stats.isNotEmpty) ...[
            const SizedBox(height: 16),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: stats.entries.map((e) {
                return Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    '${_typeLabel(e.key)} · ${e.value}',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w600),
                  ),
                );
              }).toList(),
            ),
          ],
        ],
      ),
    );
  }

  String _formatXof(int xof) {
    if (xof >= 1000000) return '${(xof / 1000000).toStringAsFixed(1)}M';
    if (xof >= 1000) return '${(xof / 1000).toStringAsFixed(0)}k';
    return '$xof';
  }

  String _typeLabel(String type) {
    const map = {
      'cotisation'  : 'Cotis.',
      'distribution': 'Distrib.',
      'pret'        : 'Prêt',
      'remboursement': 'Rembours.',
      'vote'        : 'Vote',
      'creation'    : 'Création',
      'apport'      : 'Apport',
    };
    return map[type] ?? type;
  }
}

class _MetriqueChip extends StatelessWidget {
  final String label;
  final String valeur;
  final IconData icone;
  final Color couleur;

  const _MetriqueChip({
    required this.label,
    required this.valeur,
    required this.icone,
    this.couleur = Colors.white,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icone, size: 16, color: couleur),
            const SizedBox(height: 4),
            Text(valeur,
                style: TextStyle(
                    color: couleur,
                    fontWeight: FontWeight.w800,
                    fontSize: 16)),
            Text(label,
                style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.7), fontSize: 10)),
          ],
        ),
      ),
    );
  }
}

// ── Carte entrée journal ───────────────────────────────────────────────────────
class _CarteEntree extends StatelessWidget {
  final BlockchainEntry entree;
  final void Function(String, String) onCopier;

  const _CarteEntree({required this.entree, required this.onCopier});

  bool get _estOnChain =>
      entree.txHash != null && entree.txHash!.length == 66;

  Color get _couleurType {
    const map = {
      'cotisation'   : Color(0xFF1976D2),
      'distribution' : Color(0xFF2E7D5B),
      'pret'         : Color(0xFFF57C00),
      'remboursement': Color(0xFF7B1FA2),
      'vote'         : Color(0xFF00838F),
      'creation'     : AppColors.encre,
      'apport'       : Color(0xFF558B2F),
    };
    return map[entree.typeOperation] ?? AppColors.texteDoux;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: AppColors.carte,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: _estOnChain
              ? const Color(0xFF00C853).withValues(alpha: 0.3)
              : AppColors.lignes,
        ),
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
          // En-tête entrée
          Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                // Icône type
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: _couleurType.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(_iconeType, size: 20, color: _couleurType),
                ),
                const SizedBox(width: 12),

                // Info principale
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            entree.typeLabel,
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 14,
                              color: _couleurType,
                            ),
                          ),
                          if (_estOnChain) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: const Color(0xFF00C853)
                                    .withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: const Text(
                                '⚡ On-chain',
                                style: TextStyle(
                                  fontSize: 10,
                                  color: Color(0xFF00C853),
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        entree.membreNom ?? entree.membreId ?? '—',
                        style: const TextStyle(
                            fontSize: 12, color: AppColors.texteDoux),
                      ),
                    ],
                  ),
                ),

                // Montant + date
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    if (entree.montantXof != null)
                      Text(
                        '${_formatXof(entree.montantXof!)} XOF',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 14,
                          color: _couleurType,
                        ),
                      ),
                    Text(
                      _formatDate(entree.createdAt),
                      style: const TextStyle(
                          fontSize: 11, color: AppColors.texteDoux),
                    ),
                  ],
                ),
              ],
            ),
          ),

          // TX Hash (si présent)
          if (entree.txHash != null) ...[
            const Divider(height: 1, color: AppColors.lignes),
            GestureDetector(
              onTap: () => onCopier(entree.txHash!, 'TX Hash'),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                child: Row(
                  children: [
                    Icon(
                      _estOnChain ? Icons.link : Icons.fingerprint,
                      size: 14,
                      color: _estOnChain
                          ? const Color(0xFF00C853)
                          : AppColors.texteDoux,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _estOnChain
                            ? 'TX: ${entree.txHashCourt}'
                            : 'Proof: ${entree.txHashCourt}',
                        style: TextStyle(
                          fontSize: 11,
                          fontFamily: 'monospace',
                          color: _estOnChain
                              ? const Color(0xFF00C853)
                              : AppColors.texteDoux,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (_estOnChain)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: const Color(0xFF00C853).withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.open_in_new,
                                size: 10, color: Color(0xFF00C853)),
                            SizedBox(width: 3),
                            Text(
                              'PolygonScan',
                              style: TextStyle(
                                fontSize: 10,
                                color: Color(0xFF00C853),
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                    const SizedBox(width: 4),
                    const Icon(Icons.copy, size: 14, color: AppColors.texteDoux),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  IconData get _iconeType {
    const map = {
      'cotisation'   : Icons.savings_outlined,
      'distribution' : Icons.account_balance_wallet_outlined,
      'pret'         : Icons.handshake_outlined,
      'remboursement': Icons.undo_outlined,
      'vote'         : Icons.how_to_vote_outlined,
      'creation'     : Icons.add_circle_outline,
      'apport'       : Icons.add_box_outlined,
    };
    return map[entree.typeOperation] ?? Icons.receipt_outlined;
  }

  String _formatXof(int xof) {
    if (xof >= 1000000) return '${(xof / 1000000).toStringAsFixed(1)}M';
    if (xof >= 1000) return '${(xof / 1000).toStringAsFixed(0)} k';
    return '$xof';
  }

  String _formatDate(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inDays == 0) {
      return "Aujourd'hui ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}";
    }
    if (diff.inDays == 1) return 'Hier';
    if (diff.inDays < 7) return 'Il y a ${diff.inDays} j';
    return '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}/${dt.year}';
  }
}
