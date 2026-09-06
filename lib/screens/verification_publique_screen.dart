// ═══════════════════════════════════════════════════════════════════════════════
// VerificationPubliqueScreen  —  TontineClair Phase 3
//
// Écran public (sans login requis) permettant à n'importe qui de vérifier
// les opérations blockchain d'une tontine via son code.
// Accessible depuis le bouton "Vérifier" du badge blockchain dans DetailScreen.
// ═══════════════════════════════════════════════════════════════════════════════

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/blockchain_service.dart';
import '../services/supabase_service.dart';
import '../utils/app_colors.dart';
import '../utils/formatters.dart';
import 'certificat_blockchain_screen.dart';
import 'qr_tontine_screen.dart';

class VerificationPubliqueScreen extends StatefulWidget {
  /// Code tontine pré-rempli (optionnel — si null, l'utilisateur saisit)
  final String? codeTontine;
  /// Nom tontine affiché dans le titre (optionnel)
  final String? nomTontine;
  /// Solde de caisse réel. Si fourni, remplace le calcul du volume.
  final int? soldeCaisse;
  /// Devise réelle de la tontine (passée depuis DetailScreen).
  final String? devise;

  const VerificationPubliqueScreen({
    super.key,
    this.codeTontine,
    this.nomTontine,
    this.soldeCaisse,
    this.devise,
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
  String _devise = ''; // devise réelle de la tontine chargée

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

    // Devise déjà connue (passée par le parent) — évite un chargement inutile
    final deviseInitiale = widget.devise?.trim() ?? '';

    setState(() {
      _loading   = true;
      _recherche = true;
      _erreur    = null;
      _codeActif = code;
      _entrees   = [];
      _contrat   = {};
      if (deviseInitiale.isNotEmpty) _devise = deviseInitiale;
    });

    try {
      // Charger journal + contrat en parallèle
      // + devise si non déjà fournie (lireTontine est léger)
      final List<Future<dynamic>> futures = [
        BlockchainService.lireJournal(tontineCode: code, limit: 100),
        BlockchainService.contractInfo(),
        if (deviseInitiale.isEmpty)
          SupabaseService.lireTontine(code)
              .then((t) => t.data.devise)
              .catchError((_) => ''),
      ];
      final results = await Future.wait(futures);

      if (!mounted) return;

      final toutesEntrees = results[0] as List<BlockchainEntry>;
      final entreesFiltrees = toutesEntrees
          .where((e) => e.tontineCode.trim().toUpperCase() == code)
          .toList();

      // Devise : priorité au paramètre widget, sinon valeur chargée
      final deviseChargee = deviseInitiale.isNotEmpty
          ? deviseInitiale
          : (results.length > 2 ? (results[2] as String?) ?? '' : '');

      setState(() {
        _entrees = entreesFiltrees;
        _contrat = results[1] as Map<String, dynamic>;
        _devise  = deviseChargee;
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

  /// Comptage Phase-aware unifi\u00e9 :
  /// Phase 1 (SHA-256 local)  \u2192 toutes les entr\u00e9es avec un hash non-vide
  /// Phase 2 (TX Ethereum)    \u2192 uniquement les hash de 66 caract\u00e8res (0x\u2026)
  int get _countOnChain {
    if (_phase == 2) {
      return _entrees
          .where((e) => e.txHash != null && e.txHash!.length == 66)
          .length;
    } else {
      return _entrees
          .where((e) => e.txHash != null && e.txHash!.isNotEmpty)
          .length;
    }
  }

  int get _totalXof => _entrees
      .where((e) => e.montantXof != null)
      .fold(0, (s, e) => s + (e.montantXof ?? 0));

  // ── Phase du contrat ───────────────────────────────────────────────────────
  int get _phase => (_contrat['phase'] as num?)?.toInt() ?? 1;
  String? get _contratAddress =>
      _contrat['contract_address'] as String? ?? _contrat['address'] as String?;

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
            const Text('Journal Blockchain',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            if (widget.nomTontine != null && widget.nomTontine!.isNotEmpty)
              Text(
                widget.nomTontine!,
                style: const TextStyle(fontSize: 11, color: Colors.white70),
              ),
          ],
        ),
        actions: [
          // Bouton actualiser manuel dans l'AppBar
          if (_recherche)
            IconButton(
              icon: _loading
                  ? const SizedBox(
                      width: 18, height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.refresh_rounded),
              tooltip: 'Actualiser',
              onPressed: _loading ? null : _rechercher,
            ),
        ],
      ),
      body: Column(
        children: [
          // ── Barre de recherche ─────────────────────────────────────────────
          // Masquée quand le code est pré-rempli (ouverture depuis DetailScreen)
          if (widget.codeTontine == null || widget.codeTontine!.isEmpty)
            _BarreRecherche(ctrl: _ctrl, onRechercher: _rechercher),

          // ── Infos contrat ──────────────────────────────────────────────────
          if (_phase == 2 && _contratAddress != null)
            _BandeauContrat(
              address: _contratAddress!,
              onCopier: _copier,
            ),

            // ── Actions rapides Phase 4 ───────────────────────────────────
          if (_recherche && !_loading && _entrees.isNotEmpty)
            _BarreActionsPhase4(
              codeTontine: _codeActif,
              nomTontine : _codeActif,
              onCertificat: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => CertificatBlockchainScreen(
                    codeTontine: _codeActif,
                    nomTontine : _codeActif,
                  ),
                ),
              ),
              onQr: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => QrTontineScreen(
                    codeTontine: _codeActif,
                    nomTontine : _codeActif,
                  ),
                ),
              ),
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
                            code           : _codeActif,
                            entrees        : _entrees,
                            stats          : _stats,
                            countOnChain   : _countOnChain,
                            totalXof       : _totalXof,
                            soldeCaisse    : widget.soldeCaisse,
                            devise         : _devise,
                            contratAddress : _contratAddress,
                            onCopier       : _copier,
                            onRefresh      : _rechercher,
                          ),
          ),
        ],
      ),
    );
  }
}

// ── Barre de recherche ─────────────────────────────────────────────────────────
// IMPORTANT: StatefulWidget requis pour que le FocusNode fonctionne correctement
// sur Android (clavier ne sortait pas avec StatelessWidget sans FocusNode).
class _BarreRecherche extends StatefulWidget {
  final TextEditingController ctrl;
  final VoidCallback onRechercher;

  const _BarreRecherche({required this.ctrl, required this.onRechercher});

  @override
  State<_BarreRecherche> createState() => _BarreRechercheState();
}

class _BarreRechercheState extends State<_BarreRecherche> {
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode();
    // Auto-focus uniquement si champ vide (pas de code pré-rempli).
    // Délai 300ms pour laisser le widget s'installer complètement dans l'arbre
    // avant de demander le focus — évite les races conditions sur Android.
    if (widget.ctrl.text.isEmpty) {
      Future.delayed(const Duration(milliseconds: 300), () {
        if (mounted) {
          _focusNode.requestFocus();
          // Force l'affichage du clavier même si le focus était déjà là
          // (bug Samsung/Android : focus sans clavier visible)
          SystemChannels.textInput.invokeMethod<void>('TextInput.show');
        }
      });
    }
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  /// Force l'ouverture du clavier — même si le focus est déjà accordé.
  /// Sur certains Samsung Android, requestFocus() place le curseur
  /// mais le clavier reste caché. invokeMethod('TextInput.show') le force.
  void _ouvrirClavier() {
    _focusNode.requestFocus();
    SystemChannels.textInput.invokeMethod<void>('TextInput.show');
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.encre,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: widget.ctrl,
              focusNode: _focusNode,
              autofocus: false, // géré via _ouvrirClavier() pour mieux contrôler le timing
              keyboardType: TextInputType.text,
              textCapitalization: TextCapitalization.characters,
              textInputAction: TextInputAction.search,
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
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(
                      color: Colors.white.withValues(alpha: 0.4), width: 1.5),
                ),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                prefixIcon: const Icon(Icons.search, color: Colors.white60),
              ),
              onSubmitted: (_) => widget.onRechercher(),
              onTap: _ouvrirClavier,
            ),
          ),
          const SizedBox(width: 10),
          ElevatedButton(
            onPressed: widget.onRechercher,
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
                'Smart contract : $_court · Polygon Mainnet ✅',
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
  final int? soldeCaisse;
  final String? contratAddress;
  final String devise; // devise réelle de la tontine
  final void Function(String, String) onCopier;
  final Future<void> Function() onRefresh;

  const _VueResultats({
    required this.code,
    required this.entrees,
    required this.stats,
    required this.countOnChain,
    required this.totalXof,
    this.soldeCaisse,
    this.contratAddress,
    this.devise = '',
    required this.onCopier,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: onRefresh,
      color: AppColors.encre,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: [
          // En-tête résultats
          _CarteResume(
            code           : code,
            totalEntrees   : entrees.length,
            countOnChain   : countOnChain,
            totalXof       : totalXof,
            soldeCaisse    : soldeCaisse,
            stats          : stats,
            contratAddress : contratAddress,
            devise         : devise,
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

          ...entrees.map((e) => _CarteEntree(
            entree         : e,
            onCopier       : onCopier,
            contratAddress : contratAddress,
          )),

          // Petit hint pull-to-refresh en bas de liste
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 20),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.arrow_upward, size: 12, color: AppColors.texteDoux),
                SizedBox(width: 6),
                Text(
                  'Glisser vers le bas pour actualiser',
                  style: TextStyle(fontSize: 11, color: AppColors.texteDoux),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Carte résumé ──────────────────────────────────────────────────────────────
class _CarteResume extends StatelessWidget {
  final String code;
  final int totalEntrees;
  final int countOnChain;
  final int totalXof;
  final int? soldeCaisse;
  final Map<String, int> stats;
  final String? contratAddress;
  final String devise; // devise réelle de la tontine

  const _CarteResume({
    required this.code,
    required this.totalEntrees,
    required this.countOnChain,
    required this.totalXof,
    this.soldeCaisse,
    required this.stats,
    this.contratAddress,
    this.devise = '',
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
                label: 'Solde caisse',
                valeur: _formatXof(soldeCaisse ?? totalXof),
                icone: Icons.account_balance_wallet_outlined,
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
            // Lien contrat cliquable (visible même en Phase 1)
            if (contratAddress != null) ...[
              const SizedBox(height: 10),
              GestureDetector(
                onTap: () async {
                  final url = Uri.parse(
                    'https://polygonscan.com/address/$contratAddress',
                  );
                  if (await canLaunchUrl(url)) {
                    await launchUrl(url, mode: LaunchMode.externalApplication);
                  }
                },
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.open_in_new,
                        size: 11, color: Color(0xFF00C853)),
                    const SizedBox(width: 5),
                    Text(
                      'Voir le contrat sur PolygonScan',
                      style: TextStyle(
                        fontSize: 11,
                        color: const Color(0xFF00C853).withValues(alpha: 0.9),
                        fontWeight: FontWeight.w600,
                        decoration: TextDecoration.underline,
                        decorationColor:
                            const Color(0xFF00C853).withValues(alpha: 0.6),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }

  // Formate un montant avec la vraie devise de la tontine
  String _formatXof(int xof) {
    return Formatters.montant(xof, devise: devise);
  }

  // Traduit un type_operation (y compris sélecteurs hex 0x…) → label lisible.
  // Crée une BlockchainEntry temporaire pour réutiliser le mapping complet.
  String _typeLabel(String type) {
    // Sélecteurs hex 4 bytes → type métier → label (TontineVaultV3 complet)
    const selectorVersType = <String, String>{
      // V3 — 18 fonctions métier
      '0xa3980ee2': 'cotisation',
      '0x7948515e': 'decaissement',
      '0x5ee35c39': 'distribution',
      '0xe8309f9d': 'apport',
      '0x3a34a193': 'depot',
      '0x566519de': 'retrait',
      '0x49b4279e': 'retrait_propose',
      '0x1d00f9ce': 'penalite',
      '0x3bfe5ba7': 'pret',
      '0x673efd5f': 'remboursement',
      '0xace3c9ee': 'vote',
      '0x05797094': 'vote_cree',
      '0xf4ef3be9': 'vote_clos',
      '0x69d1a0f8': 'creation',
      '0x54ce7c65': 'sync_balance',
      '0x89808c56': 'score_modifie',
      '0x0496be90': 'upgrade_pro',
      '0x19c2cd10': 'nouveau_cycle',
      // V3 — fonctions système
      '0xb38ff71f': 'mise_a_jour',
      '0xf851a440': 'mise_a_jour',
      '0x54fd4d50': 'mise_a_jour',
      '0x5a9b0b89': 'sync_balance',
      '0xed232029': 'sync_balance',
      // V1/V2 — rétrocompatibilité
      '0xbaa62d66': 'cotisation',
      '0xd3795e53': 'vote',
      '0x68054f4e': 'creation',
      '0x60c06040': 'cotisation',
      '0xa9059cbb': 'remboursement',
      '0x23b872dd': 'distribution',
    };
    const metierLabels = <String, String>{
      'cotisation'              : '💰 Cotisation',
      'decaissement'            : '💸 Décaissement',
      'distribution'            : '🎁 Distribution',
      'apport'                  : '🤝 Apport',
      'depot'                   : '📥 Dépôt',
      'retrait'                 : '📤 Retrait',
      'retrait_propose'         : '📤 Retrait proposé',
      'paiement'                : '💳 Paiement',
      'penalite'                : '⚠️ Pénalité',
      'pret'                    : '🏦 Prêt',
      'remboursement'           : '💵 Remboursement',
      'ajout_membre'            : '👤 Ajout membre',
      'suppression_membre'      : '❌ Suppression membre',
      'mise_a_jour'             : '⚙️ Mise à jour',
      'vote'                    : '🗳️ Vote',
      'vote_cree'               : '🗳️ Vote créé',
      'vote_clos'               : '🗳️ Vote clôturé',
      'creation'                : '🏦 Création tontine',
      'sync_balance'            : '🔄 Synchronisation',
      'depense_caisse'          : '💸 Dépense caisse',
      'annulation_cotisation'   : '↩️ Annulation cotisation',
      'annulation_remboursement': '↩️ Annulation remboursement',
      'tirage_verrouille'       : '🔒 Tirage verrouillé',
      'score_modifie'           : '⭐ Score modifié',
      'upgrade_pro'             : '🚀 Passage Pro',
      'nouveau_cycle'           : '🔁 Nouveau cycle',
    };

    // Si c'est un sélecteur hex, le résoudre d'abord
    final resolu = type.startsWith('0x') && type.length <= 10
        ? (selectorVersType[type.toLowerCase()] ?? type)
        : type;

    return metierLabels[resolu]
        ?? (resolu.startsWith('0x') ? '❓ Action inconnue' : resolu.replaceAll('_', ' '));
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
  /// Adresse du contrat TontineVault — transmise depuis l'état parent.
  /// Phase 1 : ouvre PolygonScan sur l'adresse du contrat (les TX y sont listées).
  /// Phase 2 : ouvre directement la TX individuelle.
  final String? contratAddress;

  const _CarteEntree({
    required this.entree,
    required this.onCopier,
    this.contratAddress,
  });

  /// true = vraie TX confirmée sur Polygon (phase 2)
  /// false = preuve SHA-256 locale (phase 1) — hash n'existe PAS sur PolygonScan
  bool get _estOnChain => entree.statut == 'confirmed';

  Color get _couleurType {
    // Résoudre d'abord les sélecteurs hex 0x… → type métier
    switch (entree.typeOperationResolu) {
      // ── Finances — bleus ────────────────────────────────────
      case 'cotisation':              return const Color(0xFF1976D2); // bleu principal
      case 'annulation_cotisation':   return const Color(0xFF64B5F6); // bleu clair
      case 'depot':                   return const Color(0xFF1565C0); // bleu foncé
      case 'apport':                  return const Color(0xFF2196F3); // bleu vif
      case 'paiement':                return const Color(0xFF1E88E5); // bleu moyen
      // ── Sorties — rouges/oranges ─────────────────────────────
      case 'decaissement':            return const Color(0xFFE53935); // rouge
      case 'retrait':                 return const Color(0xFFEF5350); // rouge clair
      case 'retrait_propose':         return const Color(0xFFEF9A9A); // rose-rouge
      case 'depense_caisse':          return const Color(0xFFD32F2F); // rouge foncé
      // ── Distribution — verts ─────────────────────────────────
      case 'distribution':            return const Color(0xFF2E7D5B); // vert tontine
      case 'nouveau_cycle':           return const Color(0xFF43A047); // vert cycle
      case 'sync_balance':            return const Color(0xFF26A69A); // teal
      // ── Prêt / Remboursement — violets ───────────────────────
      case 'pret':                    return const Color(0xFFF57C00); // orange
      case 'remboursement':           return const Color(0xFF7B1FA2); // violet
      case 'annulation_remboursement':return const Color(0xFFAB47BC); // violet clair
      // ── Pénalité — ambre ────────────────────────────────────
      case 'penalite':                return const Color(0xFFFF8F00); // ambre
      // ── Votes — cyan ────────────────────────────────────────
      case 'vote':                    return const Color(0xFF00838F); // cyan foncé
      case 'vote_cree':               return const Color(0xFF00ACC1); // cyan
      case 'vote_clos':               return const Color(0xFF0097A7); // cyan moyen
      // ── Membres ─────────────────────────────────────────────
      case 'ajout_membre':            return const Color(0xFF388E3C); // vert membre
      case 'suppression_membre':      return const Color(0xFFC62828); // rouge suppression
      // ── Paramètres / Système ────────────────────────────────
      case 'mise_a_jour':             return const Color(0xFF546E7A); // gris-bleu
      case 'creation':                return AppColors.encre;          // encre tontine
      case 'tirage_verrouille':       return const Color(0xFF37474F); // ardoise
      case 'score_modifie':           return const Color(0xFFFBC02D); // jaune
      case 'upgrade_pro':             return const Color(0xFFD4AC0D); // or
      // ── Fallback : sélecteur hex non mappé ──────────────────
      default:                        return AppColors.texteDoux;
    }
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
                                'On-chain',
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
                      // Description métier enrichie (ex: "Cotisation mensuelle", "Décaissement vers Koffi")
                      Text(
                        entree.descriptionMetier,
                        style: const TextStyle(
                            fontSize: 12, color: AppColors.texteDoux),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      // Membre si différent de la description
                      if (entree.membreNom != null && entree.membreNom!.isNotEmpty)
                        Text(
                          entree.membreNom!,
                          style: TextStyle(
                              fontSize: 11,
                              color: AppColors.texteDoux.withValues(alpha: 0.7)),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
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
                        _formatXof(entree.montantXof!),
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
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                children: [
                  // ── Hash TX / Proof cliquable ──────────────────────────────
                  // • Phase 2 (TX on-chain confirmée)  → ouvre TX directement
                  // • Phase 1 (Proof SHA-256) + contrat → ouvre adresse contrat
                  // • Phase 1 (Proof SHA-256) sans contrat → copie le hash
                  GestureDetector(
                    onTap: () async {
                      if (_estOnChain) {
                        // Phase 2 : ouvre la TX directement sur PolygonScan
                        final url = Uri.parse(
                          'https://polygonscan.com/tx/${entree.txHash}',
                        );
                        if (await canLaunchUrl(url)) {
                          await launchUrl(url, mode: LaunchMode.externalApplication);
                        }
                      } else if (contratAddress != null) {
                        // Phase 1 : preuve locale — ouvre les TX du contrat
                        final url = Uri.parse(
                          'https://polygonscan.com/address/$contratAddress',
                        );
                        if (await canLaunchUrl(url)) {
                          await launchUrl(url, mode: LaunchMode.externalApplication);
                        }
                      } else {
                        // Phase 1 sans contrat connu : copier le proof SHA-256
                        onCopier(entree.txHash!, 'Proof');
                      }
                    },
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _estOnChain
                              ? Icons.open_in_new
                              : (contratAddress != null
                                  ? Icons.link
                                  : Icons.fingerprint),
                          size: 14,
                          color: _estOnChain
                              ? const Color(0xFF00C853)
                              : (contratAddress != null
                                  ? AppColors.encreDoux
                                  : AppColors.texteDoux),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          _estOnChain
                              ? 'TX: ${entree.txHashCourt}'
                              : 'Proof: ${entree.txHashCourt}',
                          style: TextStyle(
                            fontSize: 11,
                            fontFamily: 'monospace',
                            color: _estOnChain
                                ? const Color(0xFF00C853)
                                : (contratAddress != null
                                    ? AppColors.encreDoux
                                    : AppColors.texteDoux),
                            fontWeight: FontWeight.w600,
                            // Souligné si cliquable (Phase 2 ou Phase 1 avec contrat)
                            decoration: (_estOnChain || contratAddress != null)
                                ? TextDecoration.underline
                                : TextDecoration.none,
                            decorationColor: _estOnChain
                                ? const Color(0xFF00C853)
                                : AppColors.encreDoux,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Icon(
                          _estOnChain
                              ? Icons.open_in_new
                              : (contratAddress != null
                                  ? Icons.open_in_new
                                  : Icons.copy),
                          size: 13,
                          color: _estOnChain
                              ? const Color(0xFF00C853)
                              : (contratAddress != null
                                  ? AppColors.encreDoux
                                  : AppColors.texteDoux),
                        ),
                      ],
                    ),
                  ),
                  const Spacer(),
                  // ── Bouton PolygonScan à droite ────────────────────────────
                  // Phase 2 → TX directe  |  Phase 1 → adresse contrat
                  if (_estOnChain || contratAddress != null)
                    GestureDetector(
                      onTap: () async {
                        final urlStr = _estOnChain
                            ? 'https://polygonscan.com/tx/${entree.txHash}'
                            : 'https://polygonscan.com/address/$contratAddress';
                        final url = Uri.parse(urlStr);
                        if (await canLaunchUrl(url)) {
                          await launchUrl(url, mode: LaunchMode.externalApplication);
                        }
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          color: _estOnChain
                              ? const Color(0xFF00C853).withValues(alpha: 0.12)
                              : AppColors.encreDoux.withValues(alpha: 0.10),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: _estOnChain
                                ? const Color(0xFF00C853).withValues(alpha: 0.3)
                                : AppColors.encreDoux.withValues(alpha: 0.25),
                            width: 0.8,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.open_in_new,
                              size: 11,
                              color: _estOnChain
                                  ? const Color(0xFF00C853)
                                  : AppColors.encreDoux,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              _estOnChain ? 'PolygonScan' : 'Contrat',
                              style: TextStyle(
                                fontSize: 11,
                                color: _estOnChain
                                    ? const Color(0xFF00C853)
                                    : AppColors.encreDoux,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  IconData get _iconeType {
    // Résoudre d'abord les sélecteurs hex 0x… → type métier
    switch (entree.typeOperationResolu) {
      // ── Finances entrants ────────────────────────────────────
      case 'cotisation':              return Icons.savings_outlined;
      case 'annulation_cotisation':   return Icons.undo_outlined;
      case 'depot':                   return Icons.download_outlined;
      case 'apport':                  return Icons.add_box_outlined;
      case 'paiement':                return Icons.credit_card_outlined;
      // ── Finances sortants ────────────────────────────────────
      case 'decaissement':            return Icons.outbound_outlined;
      case 'retrait':                 return Icons.upload_outlined;
      case 'retrait_propose':         return Icons.upload_file_outlined;
      case 'depense_caisse':          return Icons.shopping_bag_outlined;
      // ── Distribution / Cycle ─────────────────────────────────
      case 'distribution':            return Icons.account_balance_wallet_outlined;
      case 'nouveau_cycle':           return Icons.replay_circle_filled;
      case 'sync_balance':            return Icons.sync_outlined;
      // ── Prêt / Remboursement ─────────────────────────────────
      case 'pret':                    return Icons.handshake_outlined;
      case 'remboursement':           return Icons.price_check_outlined;
      case 'annulation_remboursement':return Icons.cancel_outlined;
      // ── Pénalité ────────────────────────────────────────────
      case 'penalite':                return Icons.warning_amber_outlined;
      // ── Votes ───────────────────────────────────────────────
      case 'vote':                    return Icons.how_to_vote_outlined;
      case 'vote_cree':               return Icons.ballot_outlined;
      case 'vote_clos':               return Icons.check_circle_outline;
      // ── Membres ─────────────────────────────────────────────
      case 'ajout_membre':            return Icons.person_add_outlined;
      case 'suppression_membre':      return Icons.person_remove_outlined;
      // ── Paramètres / Système ────────────────────────────────
      case 'mise_a_jour':             return Icons.tune_outlined;
      case 'creation':                return Icons.add_circle_outline;
      case 'tirage_verrouille':       return Icons.lock_outline;
      case 'score_modifie':           return Icons.star_border_outlined;
      case 'upgrade_pro':             return Icons.rocket_launch_outlined;
      // ── Fallback : sélecteur hex non mappé ❓ ───────────────
      default:                        return Icons.help_outline;
    }
  }

  // Formate un montant — la devise est portée par la carte parente (non dispo ici)
  // → utilise Formatters.montant sans devise (numérique neutre)
  String _formatXof(int xof) {
    return Formatters.montant(xof);
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

// ═══════════════════════════════════════════════════════════════════════════════
// Barre d'actions Phase 4 — Certificat PDF + QR Code
// ═══════════════════════════════════════════════════════════════════════════════
class _BarreActionsPhase4 extends StatelessWidget {
  final String codeTontine;
  final String nomTontine;
  final VoidCallback onCertificat;
  final VoidCallback onQr;

  const _BarreActionsPhase4({
    required this.codeTontine,
    required this.nomTontine,
    required this.onCertificat,
    required this.onQr,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.carte,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: onCertificat,
              icon: const Icon(Icons.workspace_premium, size: 16),
              label: const Text('Certificat PDF',
                  style: TextStyle(fontSize: 12)),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.encre,
                side: const BorderSide(color: AppColors.encre),
                padding: const EdgeInsets.symmetric(vertical: 10),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: onQr,
              icon: const Icon(Icons.qr_code, size: 16),
              label: const Text('QR Code',
                  style: TextStyle(fontSize: 12)),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.whatsapp,
                side: const BorderSide(color: AppColors.whatsapp),
                padding: const EdgeInsets.symmetric(vertical: 10),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
