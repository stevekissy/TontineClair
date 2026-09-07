// ignore_for_file: avoid_print
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../services/supabase_service.dart';
import '../utils/app_colors.dart';
import '../utils/formatters.dart';
import '../widgets/app_widgets.dart';
import '../utils/app_localizations.dart';

// ─────────────────────────────────────────────────────────────────────────────
// MODÈLES LOCAUX — Dashboard Admin
// ─────────────────────────────────────────────────────────────────────────────

class _StatsGlobales {
  final int totalTontines;
  final int premiumActives;
  final int premiumExpires;
  final int gratuites;
  final int totalMembres;
  final int abonnementsActifs;
  final int montantMensuelFcfa;
  final int montantAnnuelFcfa;
  final int encaisseCeMois;
  final int encaisseAnnee;
  final int revenuMensuelEstime;
  final int revenuAnnuelEstime;
  final int alertes;

  const _StatsGlobales({
    required this.totalTontines,
    required this.premiumActives,
    required this.premiumExpires,
    required this.gratuites,
    required this.totalMembres,
    required this.abonnementsActifs,
    required this.montantMensuelFcfa,
    required this.montantAnnuelFcfa,
    required this.encaisseCeMois,
    required this.encaisseAnnee,
    required this.revenuMensuelEstime,
    required this.revenuAnnuelEstime,
    required this.alertes,
  });

  factory _StatsGlobales.vide() => const _StatsGlobales(
        totalTontines: 0,
        premiumActives: 0,
        premiumExpires: 0,
        gratuites: 0,
        totalMembres: 0,
        abonnementsActifs: 0,
        montantMensuelFcfa: 0,
        montantAnnuelFcfa: 0,
        encaisseCeMois: 0,
        encaisseAnnee: 0,
        revenuMensuelEstime: 0,
        revenuAnnuelEstime: 0,
        alertes: 0,
      );

  factory _StatsGlobales.fromJson(Map<String, dynamic> j) => _StatsGlobales(
        totalTontines: _int(j['total_tontines']),
        premiumActives: _int(j['premium_actives']),
        premiumExpires: _int(j['premium_expires']),
        gratuites: _int(j['gratuites']),
        totalMembres: _int(j['total_membres']),
        abonnementsActifs: _int(j['abonnements_actifs']),
        montantMensuelFcfa: _int(j['montant_mensuel_fcfa']),
        montantAnnuelFcfa: _int(j['montant_annuel_fcfa']),
        encaisseCeMois: _int(j['encaisse_ce_mois']),
        encaisseAnnee: _int(j['encaisse_annee']),
        revenuMensuelEstime: _int(j['revenu_mensuel_estime']),
        revenuAnnuelEstime: _int(j['revenu_annuel_estime']),
        alertes: _int(j['alertes']),
      );

  static int _int(dynamic v) {
    if (v == null) return 0;
    if (v is int) return v;
    if (v is double) return v.toInt();
    return int.tryParse(v.toString()) ?? 0;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// ÉCRAN PRINCIPAL — AdminDashboardScreen
// ─────────────────────────────────────────────────────────────────────────────

class AdminDashboardScreen extends StatefulWidget {
  final String cle;

  const AdminDashboardScreen({super.key, required this.cle});

  @override
  State<AdminDashboardScreen> createState() => _AdminDashboardScreenState();
}

class _AdminDashboardScreenState extends State<AdminDashboardScreen>
    with SingleTickerProviderStateMixin {
  // ─── Données ───────────────────────────────────────────────────────────────
  _StatsGlobales _stats = _StatsGlobales.vide();
  List<Map<String, dynamic>> _tontines = [];
  List<Map<String, dynamic>> _tontinesFiltrees = [];
  List<Map<String, dynamic>> _abonnements = [];
  List<Map<String, dynamic>> _alertes = [];
  List<Map<String, dynamic>> _mensuel = [];
  List<Map<String, dynamic>> _top10 = [];

  // ─── UI state ──────────────────────────────────────────────────────────────
  bool _loading = true;
  String? _erreur;
  String _filtreTontine = 'toutes';
  int _onglet = 0; // 0=KPI, 1=Tontines, 2=Abonnements, 3=Graphiques, 4=Alertes
  final _searchCtrl = TextEditingController();
  Timer? _debounce;

  // ─── Onglet abonnements ─────────────────────────────────────────────────────
  String _filtreAbonnement = 'tous';

  @override
  void initState() {
    super.initState();
    _charger();
    _searchCtrl.addListener(_onSearch);
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  // ─── Chargement ────────────────────────────────────────────────────────────
  // FIX v1.2 : chargements indépendants avec catchError
  // → si un seul RPC échoue, le dashboard reste fonctionnel
  // → les données disponibles s'affichent, les autres restent vides

  Future<void> _charger() async {
    setState(() {
      _loading = true;
      _erreur  = null;
    });

    // Erreurs collectées par RPC (affichage en console, pas écran blanc)
    final erreurs = <String>[];

    // ── RPC 1 : stats globales (KPI) ─────────────────────────────────────
    Map<String, dynamic> statsJson = {};
    try {
      statsJson = await SupabaseService.adminStatsGlobales(widget.cle);
    } catch (e) {
      erreurs.add('stats_globales: $e');
    }

    // ── RPC 2 : liste tontines ────────────────────────────────────────────
    List<Map<String, dynamic>> tontines = [];
    try {
      tontines = await SupabaseService.adminDashboardTontines(
        widget.cle, filtre: 'toutes', limit: 200,
      );
    } catch (e) {
      erreurs.add('dashboard_tontines: $e');
    }

    // ── RPC 3 : abonnements ───────────────────────────────────────────────
    List<Map<String, dynamic>> abos = [];
    try {
      abos = await SupabaseService.adminListerAbonnements(
        widget.cle, statut: 'tous', limit: 100,
      );
    } catch (e) {
      erreurs.add('lister_abonnements: $e');
    }

    // ── RPC 4 : alertes (était le RPC qui faisait tout échouer) ──────────
    List<Map<String, dynamic>> alertes = [];
    try {
      alertes = await SupabaseService.adminAlertes(widget.cle);
    } catch (e) {
      // Échec toléré — alertes affichées vides, dashboard reste accessible
      erreurs.add('admin_alertes: $e');
    }

    // ── RPC 5 : stats mensuelles (graphiques) ─────────────────────────────
    List<Map<String, dynamic>> mensuel = [];
    try {
      mensuel = await SupabaseService.adminStatsMensuelles(widget.cle);
    } catch (e) {
      erreurs.add('stats_mensuelles: $e');
    }

    // ── RPC 6 : top tontines ─────────────────────────────────────────────
    List<Map<String, dynamic>> top10 = [];
    try {
      top10 = await SupabaseService.adminTopTontines(widget.cle);
    } catch (e) {
      erreurs.add('top_tontines: $e');
    }

    // Logger les erreurs partielles en console (sans bloquer l'UI)
    if (erreurs.isNotEmpty) {
      for (final err in erreurs) {
        debugPrint('[AdminDashboard] RPC partiel: $err');
      }
    }

    // Si TOUS les RPCs ont échoué et que statsJson est vide → erreur totale
    final echecTotal = statsJson.isEmpty && tontines.isEmpty &&
        abos.isEmpty && mensuel.isEmpty && top10.isEmpty;

    setState(() {
      if (echecTotal && erreurs.isNotEmpty) {
        // Afficher seulement si tout est vide (pas d'écran blanc pour erreur partielle)
        _erreur = 'Impossible de charger le dashboard.\n'
            'Vérifiez votre clé admin et que les RPCs Supabase sont déployés.\n'
            '(${erreurs.first})';
      }
      _stats            = statsJson.isNotEmpty
          ? _StatsGlobales.fromJson(statsJson)
          : _StatsGlobales.vide();
      _tontines         = tontines;
      _tontinesFiltrees = tontines;
      _abonnements      = abos;
      _alertes          = alertes;
      _mensuel          = mensuel;
      _top10            = top10;
      _loading          = false;
    });
  }

  Future<void> _recharger() => _charger();

  // ─── Filtres ───────────────────────────────────────────────────────────────

  void _appliquerFiltre(String filtre) async {
    setState(() => _filtreTontine = filtre);
    final query = _searchCtrl.text.trim().toLowerCase();
    if (filtre == 'toutes' && query.isEmpty) {
      setState(() => _tontinesFiltrees = _tontines);
      return;
    }
    // Re-fetch from Supabase for server-side filter, then apply local search
    try {
      final serveur = await SupabaseService.adminDashboardTontines(
        widget.cle,
        filtre: filtre,
        limit: 200,
      );
      setState(() {
        _tontines = filtre == 'toutes' ? serveur : _tontines;
        _tontinesFiltrees = query.isEmpty
            ? serveur
            : serveur.where((t) => _matchRecherche(t, query)).toList();
      });
    } catch (_) {
      // Fallback to client-side filter
      _filtrerLocalement(filtre, query);
    }
  }

  void _filtrerLocalement(String filtre, String query) {
    List<Map<String, dynamic>> base = _tontines;
    if (filtre == 'premium') {
      base = base.where((t) {
        final plan = t['plan'] as String? ?? '';
        final expire = t['plan_expire'] != null
            ? DateTime.tryParse(t['plan_expire'] as String)
            : null;
        return plan == 'premium' &&
            (expire == null || expire.isAfter(DateTime.now()));
      }).toList();
    } else if (filtre == 'gratuites') {
      base = base.where((t) => (t['plan'] as String? ?? '') != 'premium').toList();
    } else if (filtre == 'expires') {
      base = base.where((t) {
        final plan = t['plan'] as String? ?? '';
        final expire = t['plan_expire'] != null
            ? DateTime.tryParse(t['plan_expire'] as String)
            : null;
        return plan == 'premium' &&
            expire != null &&
            expire.isBefore(DateTime.now());
      }).toList();
    }
    if (query.isNotEmpty) {
      base = base.where((t) => _matchRecherche(t, query)).toList();
    }
    setState(() => _tontinesFiltrees = base);
  }

  bool _matchRecherche(Map<String, dynamic> t, String q) {
    final nom   = (t['nom']          as String? ?? '').toLowerCase();
    final code  = (t['code']         as String? ?? '').toLowerCase();
    final pres  = (t['premier_gest'] as String? ?? '').toLowerCase();
    return nom.contains(q) || code.contains(q) || pres.contains(q);
  }

  void _onSearch() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      final q = _searchCtrl.text.trim().toLowerCase();
      _filtrerLocalement(_filtreTontine, q);
    });
  }

  // ─────────────────────────────────────────────────────────────────────────
  // BUILD
  // ─────────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(color: AppColors.encre, strokeWidth: 2),
            SizedBox(height: 16),
            Text(
              context.tr('chargement_dashboard'),
              style: TextStyle(color: AppColors.texteDoux, fontSize: 14),
            ),
          ],
        ),
      );
    }

    if (_erreur != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.cloud_off, size: 48, color: AppColors.alerte),
              SizedBox(height: 16),
              Text(
                _erreur!,
                style: TextStyle(color: AppColors.alerte, fontSize: 13),
                textAlign: TextAlign.center,
              ),
              SizedBox(height: 20),
              SizedBox(
                width: 180,
                child: BtnPrincipal(
                  label: context.tr('reessayer'),
                  onTap: _recharger,
                  icone: Icons.refresh,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      children: [
        _buildBarreOnglets(),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _recharger,
            color: AppColors.encre,
            child: _buildContenuOnglet(),
          ),
        ),
      ],
    );
  }

  // ─── Barre d'onglets ───────────────────────────────────────────────────────

  Widget _buildBarreOnglets() {
    final onglets = [
      (Icons.dashboard_outlined,  'Vue d\'ensemble'),
      (Icons.account_balance_wallet_outlined, 'Tontines'),
      (Icons.receipt_long_outlined, 'Abonnements'),
      (Icons.bar_chart_outlined,  'Graphiques'),
      (Icons.notifications_outlined, 'Alertes ${_alertes.isNotEmpty ? "(${_alertes.length})" : ""}'),
    ];
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.carte,
        border: Border(bottom: BorderSide(color: AppColors.lignes, width: 1)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          children: List.generate(onglets.length, (i) {
            final (icon, label) = onglets[i];
            final selected = _onglet == i;
            return Padding(
              padding: const EdgeInsets.only(right: 6),
              child: GestureDetector(
                onTap: () => setState(() => _onglet = i),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: selected ? AppColors.encre : Colors.transparent,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        icon,
                        size: 15,
                        color: selected ? Colors.white : AppColors.texteDoux,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        label,
                        style: GoogleFonts.inter(
                          fontSize: 12.5,
                          fontWeight: selected
                              ? FontWeight.w700
                              : FontWeight.w500,
                          color: selected
                              ? Colors.white
                              : AppColors.texteDoux,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }),
        ),
      ),
    );
  }

  Widget _buildContenuOnglet() {
    switch (_onglet) {
      case 0: return _buildVueEnsemble();
      case 1: return _buildOngletTontines();
      case 2: return _buildOngletAbonnements();
      case 3: return _buildOngletGraphiques();
      case 4: return _buildOngletAlertes();
      default: return _buildVueEnsemble();
    }
  }

  // ════════════════════════════════════════════════════════════════════════════
  // ONGLET 0 — VUE D'ENSEMBLE (KPI CARDS)
  // ════════════════════════════════════════════════════════════════════════════

  Widget _buildVueEnsemble() {
    return SingleChildScrollView(
      padding: EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionTitre(titre: 'Vue d\'ensemble', icone: Icons.dashboard_outlined),
          SizedBox(height: 4),
          Text(
            context.tr('donnees_temps_reel'),
            style: GoogleFonts.inter(
                fontSize: 12.5, color: AppColors.texteDoux),
          ),
          const SizedBox(height: 18),

          // ── Grille KPI ──────────────────────────────────────────────────
          _GridKPI(stats: _stats),

          const SizedBox(height: 24),
          _SectionTitre(
              titre: 'Top 5 tontines actives', icone: Icons.emoji_events_outlined),
          const SizedBox(height: 12),
          ..._top10.take(5).map((t) => _LigneTontineCompacte(
                tontine: t,
                onTap: () => _ouvrirFiche(t),
              )),
          if (_top10.isEmpty)
            const _EtatVideSection(
                texte: 'Aucune donnée disponible — déployez supabase-admin.sql'),

          const SizedBox(height: 24),
          _SectionTitre(
              titre: 'Alertes récentes', icone: Icons.notifications_active_outlined),
          const SizedBox(height: 12),
          ..._alertes.take(3).map((a) => _CarteAlerte(alerte: a)),
          if (_alertes.isEmpty)
            const _EtatVideSection(texte: 'Aucune alerte active', vert: true),
        ],
      ),
    );
  }

  // ════════════════════════════════════════════════════════════════════════════
  // ONGLET 1 — TONTINES
  // ════════════════════════════════════════════════════════════════════════════

  Widget _buildOngletTontines() {
    return Column(
      children: [
        // ── Barre de recherche ────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
          child: TextField(
            controller: _searchCtrl,
            decoration: InputDecoration(
              hintText: 'Rechercher par nom, code, président…',
              hintStyle: const TextStyle(
                  color: AppColors.texteDoux, fontSize: 13.5),
              prefixIcon: const Icon(Icons.search,
                  color: AppColors.texteDoux, size: 20),
              suffixIcon: _searchCtrl.text.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear,
                          size: 18, color: AppColors.texteDoux),
                      onPressed: () {
                        _searchCtrl.clear();
                        _filtrerLocalement(_filtreTontine, '');
                      },
                    )
                  : null,
              filled: true,
              fillColor: AppColors.carte,
              contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14, vertical: 10),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide:
                    const BorderSide(color: AppColors.lignes, width: 1),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide:
                    const BorderSide(color: AppColors.lignes, width: 1),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide:
                    const BorderSide(color: AppColors.encre, width: 1.5),
              ),
            ),
          ),
        ),

        // ── Filtres chips ─────────────────────────────────────────────────
        _BarreFiltresTontines(
          filtre: _filtreTontine,
          onFiltre: _appliquerFiltre,
          stats: _stats,
        ),

        // ── Compteur ─────────────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Row(
            children: [
              Text(
                '${_tontinesFiltrees.length} tontine${_tontinesFiltrees.length > 1 ? 's' : ''}',
                style: GoogleFonts.inter(
                    fontSize: 12, color: AppColors.texteDoux),
              ),
              const Spacer(),
              GestureDetector(
                onTap: _recharger,
                child: const Icon(Icons.refresh,
                    size: 18, color: AppColors.texteDoux),
              ),
            ],
          ),
        ),

        // ── Liste ─────────────────────────────────────────────────────────
        Expanded(
          child: _tontinesFiltrees.isEmpty
              ? const _EtatVideSection(
                  texte: 'Aucune tontine correspondant aux critères',
                  centrer: true,
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 8),
                  itemCount: _tontinesFiltrees.length,
                  itemBuilder: (_, i) => _CarteTontineAdmin(
                    tontine: _tontinesFiltrees[i],
                    cle: widget.cle,
                    onActiver: _activerPremium,
                    onDesactiver: _desactiverPremium,
                    onVoirFiche: () => _ouvrirFiche(_tontinesFiltrees[i]),
                  ),
                ),
        ),
      ],
    );
  }

  Future<void> _activerPremium(String code) async {
    final ok = await SupabaseService.adminActiverPremium(
      cle: widget.cle,
      code: code,
      mois: 1,
    );
    if (!mounted) return;
    if (ok) {
      // Enregistrer aussi dans la table abonnements
      await SupabaseService.adminEnregistrerAbonnement(
        cle: widget.cle,
        code: code,
        formule: 'mensuel',
        montant: 2500,
      );
      if (!mounted) return;
      afficherToast(context, 'Premium activé pour $code !');
      await _recharger();
    } else {
      if (!mounted) return;
      afficherToast(context, 'Erreur lors de l\'activation.', estErreur: true);
    }
  }

  Future<void> _desactiverPremium(String code) async {
    final ok = await SupabaseService.adminDesactiverPremium(
      cle: widget.cle,
      code: code,
    );
    if (!mounted) return;
    if (ok) {
      afficherToast(context, 'Premium désactivé pour $code.');
      await _recharger();
    } else {
      afficherToast(context, 'Erreur lors de la désactivation.', estErreur: true);
    }
  }

  void _ouvrirFiche(Map<String, dynamic> tontine) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.fondPapier,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => _FicheTontine(
        tontine: tontine,
        cle: widget.cle,
        onActiver: _activerPremium,
        onDesactiver: _desactiverPremium,
      ),
    );
  }

  // ════════════════════════════════════════════════════════════════════════════
  // ONGLET 2 — ABONNEMENTS
  // ════════════════════════════════════════════════════════════════════════════

  Widget _buildOngletAbonnements() {
    // Filtrage local
    final abosFiltres = _filtreAbonnement == 'tous'
        ? _abonnements
        : _abonnements
            .where((a) => (a['statut'] as String? ?? '') == _filtreAbonnement)
            .toList();

    // Compteurs
    final actifs    = _abonnements.where((a) => a['statut'] == 'actif').length;
    final expires   = _abonnements.where((a) => a['statut'] == 'expire').length;
    final attente   = _abonnements.where((a) => a['statut'] == 'en_attente').length;
    final mensuelActif = _abonnements.where((a) =>
        a['statut'] == 'actif' && a['formule'] == 'mensuel').length;
    final annuelActif = _abonnements.where((a) =>
        a['statut'] == 'actif' && a['formule'] == 'annuel').length;
    final totalEncaisse = _abonnements
        .where((a) => a['statut'] == 'actif')
        .fold<int>(0, (sum, a) => sum + _StatsGlobales._int(a['montant']));

    return SingleChildScrollView(
      padding: EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionTitre(
              titre: context.tr('suivi_abonnements'),
              icone: Icons.receipt_long_outlined),
          SizedBox(height: 14),

          // ── Cartes résumé ─────────────────────────────────────────────
          Row(children: [
            Expanded(
              child: _MiniKPI(
                label: context.tr('actif'),
                valeur: '$actifs',
                icone: Icons.check_circle_outline,
                couleur: AppColors.succes,
                fond: AppColors.succesFond,
              ),
            ),
            SizedBox(width: 10),
            Expanded(
              child: _MiniKPI(
                label: context.tr('expire'),
                valeur: '$expires',
                icone: Icons.cancel_outlined,
                couleur: AppColors.alerte,
                fond: AppColors.alerteFond,
              ),
            ),
            SizedBox(width: 10),
            Expanded(
              child: _MiniKPI(
                label: context.tr('en_attente'),
                valeur: '$attente',
                icone: Icons.hourglass_empty,
                couleur: AppColors.or,
                fond: AppColors.fondConsultation,
              ),
            ),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: _MiniKPI(
                label: 'Mensuel (2 500/m)',
                valeur: '$mensuelActif actifs',
                icone: Icons.calendar_month_outlined,
                couleur: AppColors.encreDoux,
                fond: AppColors.fondCode,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _MiniKPI(
                label: 'Annuel (25 000/an)',
                valeur: '$annuelActif actifs',
                icone: Icons.calendar_today_outlined,
                couleur: AppColors.encre,
                fond: AppColors.fondGestion,
              ),
            ),
          ]),
          SizedBox(height: 10),
          CarteTC(
            padding: EdgeInsets.all(16),
            child: Row(
              children: [
                Icon(Icons.account_balance_outlined,
                    color: AppColors.succes, size: 22),
                SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        context.tr('montant_total_actif'),
                        style: GoogleFonts.inter(
                            fontSize: 12, color: AppColors.texteDoux),
                      ),
                      Text(
                        Formatters.montantFCFA(totalEncaisse),
                        style: GoogleFonts.bricolageGrotesque(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          color: AppColors.succes,
                        ),
                      ),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      context.tr('estime_ce_mois'),
                      style: GoogleFonts.inter(
                          fontSize: 11, color: AppColors.texteDoux),
                    ),
                    Text(
                      Formatters.montantFCFA(_stats.encaisseCeMois),
                      style: GoogleFonts.inter(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: AppColors.encre,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),
          // ── Filtres abonnements ───────────────────────────────────────
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: ['tous', 'actif', 'expire', 'en_attente']
                  .map((f) => Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: _ChipFiltre(
                          label: _labelFiltreAbo(f),
                          selected: _filtreAbonnement == f,
                          onTap: () =>
                              setState(() => _filtreAbonnement = f),
                        ),
                      ))
                  .toList(),
            ),
          ),
          SizedBox(height: 12),

          // ── Liste abonnements ─────────────────────────────────────────
          ...abosFiltres.map((a) => _CarteAbonnement(abonnement: a)),
          if (abosFiltres.isEmpty)
            _EtatVideSection(
                texte: 'Aucun abonnement — déployez supabase-admin.sql'),
        ],
      ),
    );
  }

  String _labelFiltreAbo(String f) {
    switch (f) {
      case 'actif':      return context.tr('actif');
      case 'expire':     return context.tr('expire');
      case 'en_attente': return context.tr('en_attente_statut');
      default:           return 'Tous';
    }
  }

  // ════════════════════════════════════════════════════════════════════════════
  // ONGLET 3 — GRAPHIQUES
  // ════════════════════════════════════════════════════════════════════════════

  Widget _buildOngletGraphiques() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionTitre(titre: 'Graphiques', icone: Icons.bar_chart_outlined),
          const SizedBox(height: 16),

          // ── Premium vs Gratuit ─────────────────────────────────────────
          _GrafiqueDonut(
            titre: 'Répartition Premium / Gratuit',
            valeurA: _stats.premiumActives,
            valeurB: _stats.gratuites,
            labelA: 'Premium',
            labelB: 'Gratuit',
            couleurA: AppColors.or,
            couleurB: AppColors.fondCode,
          ),
          const SizedBox(height: 16),

          // ── Nouvelles tontines par mois ────────────────────────────────
          if (_mensuel.isNotEmpty) ...[
            _GrafiqueBarres(
              titre: 'Nouvelles tontines / mois',
              donnees: _mensuel
                  .map((m) => _PointDonnee(
                        label: (m['mois_label'] as String? ?? '')
                            .replaceAll(' ', '\n'),
                        valeur: _StatsGlobales._int(m['nouvelles_tontines']),
                        couleur: AppColors.encreDoux,
                      ))
                  .toList(),
            ),
            const SizedBox(height: 16),

            // ── Revenus par mois ─────────────────────────────────────────
            _GrafiqueBarres(
              titre: 'Revenus abonnements / mois (FCFA)',
              donnees: _mensuel
                  .map((m) => _PointDonnee(
                        label: (m['mois_label'] as String? ?? '')
                            .replaceAll(' ', '\n'),
                        valeur: _StatsGlobales._int(m['revenu_fcfa']),
                        couleur: AppColors.succes,
                      ))
                  .toList(),
              formatValeur: (v) => v >= 1000
                  ? '${(v / 1000).toStringAsFixed(0)}k'
                  : '$v',
            ),
            const SizedBox(height: 16),
          ],

          // ── Top 10 tontines ────────────────────────────────────────────
          if (_top10.isNotEmpty) ...[
            _SectionTitre(
                titre: 'Top 10 par membres', icone: Icons.emoji_events_outlined),
            const SizedBox(height: 12),
            _GrafiqueBarresHorizontales(donnees: _top10),
          ],

          if (_mensuel.isEmpty && _top10.isEmpty)
            const _EtatVideSection(
                texte: 'Graphiques disponibles après déploiement de supabase-admin.sql'),
        ],
      ),
    );
  }

  // ════════════════════════════════════════════════════════════════════════════
  // ONGLET 4 — ALERTES
  // ════════════════════════════════════════════════════════════════════════════

  Widget _buildOngletAlertes() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionTitre(
              titre: 'Alertes administrateur',
              icone: Icons.notifications_active_outlined),
          const SizedBox(height: 4),
          Text(
            '${_alertes.length} alerte${_alertes.length > 1 ? 's' : ''} active${_alertes.length > 1 ? 's' : ''}',
            style: GoogleFonts.inter(fontSize: 12.5, color: AppColors.texteDoux),
          ),
          const SizedBox(height: 16),
          ..._alertes.map((a) => _CarteAlerte(alerte: a, detail: true)),
          if (_alertes.isEmpty)
            CarteTC(
              child: Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: AppColors.succesFond,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.check_circle,
                        color: AppColors.succes, size: 24),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Aucune alerte active',
                          style: GoogleFonts.inter(
                            fontWeight: FontWeight.w700,
                            fontSize: 14.5,
                            color: AppColors.succes,
                          ),
                        ),
                        Text(
                          'Tous les abonnements sont à jour.',
                          style: GoogleFonts.inter(
                              fontSize: 12.5, color: AppColors.texteDoux),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

          const SizedBox(height: 24),
          // ── Abonnements expirant bientôt (depuis les tontines)
          _SectionTitre(
              titre: 'Expirations prochaines (7 jours)',
              icone: Icons.timer_outlined),
          const SizedBox(height: 12),
          ..._tontines
              .where((t) => t['expire_bientot'] == true)
              .map((t) => _CarteTontineAlerte(tontine: t)),
          if (_tontines.where((t) => t['expire_bientot'] == true).isEmpty)
            const _EtatVideSection(texte: 'Aucune expiration dans les 7 jours', vert: true),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// WIDGETS RÉUTILISABLES
// ─────────────────────────────────────────────────────────────────────────────

// ── Titre de section ──────────────────────────────────────────────────────────

class _SectionTitre extends StatelessWidget {
  final String titre;
  final IconData icone;

  const _SectionTitre({required this.titre, required this.icone});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icone, size: 16, color: AppColors.encre),
        const SizedBox(width: 8),
        Text(
          titre,
          style: GoogleFonts.bricolageGrotesque(
            fontWeight: FontWeight.w700,
            fontSize: 17,
            color: AppColors.encre,
          ),
        ),
      ],
    );
  }
}

// ── État vide ──────────────────────────────────────────────────────────────────

class _EtatVideSection extends StatelessWidget {
  final String texte;
  final bool vert;
  final bool centrer;

  const _EtatVideSection({
    required this.texte,
    this.vert = false,
    this.centrer = false,
  });

  @override
  Widget build(BuildContext context) {
    final widget = Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: vert ? AppColors.succesFond : AppColors.fondSecondaire,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(
            vert ? Icons.check_circle_outline : Icons.info_outline,
            size: 18,
            color: vert ? AppColors.succes : AppColors.texteDoux,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              texte,
              style: GoogleFonts.inter(
                fontSize: 13,
                color: vert ? AppColors.succes : AppColors.texteDoux,
              ),
            ),
          ),
        ],
      ),
    );
    if (centrer) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.search_off,
                size: 48,
                color: AppColors.texteDoux.withValues(alpha: 0.4),
              ),
              const SizedBox(height: 16),
              Text(
                texte,
                style: GoogleFonts.inter(
                    fontSize: 14, color: AppColors.texteDoux),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }
    return widget;
  }
}

// ── Chip filtre ───────────────────────────────────────────────────────────────

class _ChipFiltre extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _ChipFiltre({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? AppColors.encre : AppColors.carte,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected ? AppColors.encre : AppColors.lignes,
            width: 1.2,
          ),
        ),
        child: Text(
          label,
          style: GoogleFonts.inter(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: selected ? Colors.white : AppColors.encre,
          ),
        ),
      ),
    );
  }
}

// ── Barre filtres tontines ────────────────────────────────────────────────────

class _BarreFiltresTontines extends StatelessWidget {
  final String filtre;
  final ValueChanged<String> onFiltre;
  final _StatsGlobales stats;

  const _BarreFiltresTontines({
    required this.filtre,
    required this.onFiltre,
    required this.stats,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          _ChipFiltre(
            label: 'Toutes (${stats.totalTontines})',
            selected: filtre == 'toutes',
            onTap: () => onFiltre('toutes'),
          ),
          const SizedBox(width: 8),
          _ChipFiltre(
            label: '★ Premium (${stats.premiumActives})',
            selected: filtre == 'premium',
            onTap: () => onFiltre('premium'),
          ),
          const SizedBox(width: 8),
          _ChipFiltre(
            label: 'Gratuites (${stats.gratuites})',
            selected: filtre == 'gratuites',
            onTap: () => onFiltre('gratuites'),
          ),
          const SizedBox(width: 8),
          _ChipFiltre(
            label: 'Expirées (${stats.premiumExpires})',
            selected: filtre == 'expires',
            onTap: () => onFiltre('expires'),
          ),
        ],
      ),
    );
  }
}

// ── Grille KPI ────────────────────────────────────────────────────────────────

class _GridKPI extends StatelessWidget {
  final _StatsGlobales stats;

  const _GridKPI({required this.stats});

  @override
  Widget build(BuildContext context) {
    final items = [
      _KPIItem(
        label: 'Tontines',
        valeur: '${stats.totalTontines}',
        icone: Icons.groups_outlined,
        couleur: AppColors.encre,
        fond: AppColors.fondCode,
      ),
      _KPIItem(
        label: 'Membres',
        valeur: '${stats.totalMembres}',
        icone: Icons.person_outline,
        couleur: AppColors.encreDoux,
        fond: AppColors.fondGestion,
      ),
      _KPIItem(
        label: 'Premium actives',
        valeur: '${stats.premiumActives}',
        icone: Icons.star_outlined,
        couleur: AppColors.orFonce,
        fond: AppColors.fondConsultation,
      ),
      _KPIItem(
        label: 'Gratuites',
        valeur: '${stats.gratuites}',
        icone: Icons.lock_open_outlined,
        couleur: AppColors.texteDoux,
        fond: AppColors.fondSecondaire,
      ),
      _KPIItem(
        label: 'Abonnements actifs',
        valeur: '${stats.abonnementsActifs}',
        icone: Icons.check_circle_outline,
        couleur: AppColors.succes,
        fond: AppColors.succesFond,
      ),
      _KPIItem(
        label: 'Expirés',
        valeur: '${stats.premiumExpires}',
        icone: Icons.cancel_outlined,
        couleur: AppColors.alerte,
        fond: AppColors.alerteFond,
      ),
      _KPIItem(
        label: 'Encaissé ce mois',
        valeur: Formatters.montantFCFA(stats.encaisseCeMois),
        icone: Icons.trending_up,
        couleur: AppColors.succes,
        fond: AppColors.succesFond,
        petit: true,
      ),
      _KPIItem(
        label: 'Encaissé cette année',
        valeur: Formatters.montantFCFA(stats.encaisseAnnee),
        icone: Icons.account_balance_outlined,
        couleur: AppColors.encre,
        fond: AppColors.fondCode,
        petit: true,
      ),
      _KPIItem(
        label: 'Revenu mensuel estimé',
        valeur: Formatters.montantFCFA(stats.revenuMensuelEstime),
        icone: Icons.calculate_outlined,
        couleur: AppColors.orFonce,
        fond: AppColors.fondConsultation,
        petit: true,
      ),
      _KPIItem(
        label: 'Revenu annuel estimé',
        valeur: Formatters.montantFCFA(stats.revenuAnnuelEstime),
        icone: Icons.savings_outlined,
        couleur: AppColors.encreDoux,
        fond: AppColors.fondGestion,
        petit: true,
      ),
    ];

    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: items.map((item) => _CarteKPI(item: item)).toList(),
    );
  }
}

class _KPIItem {
  final String label;
  final String valeur;
  final IconData icone;
  final Color couleur;
  final Color fond;
  final bool petit;

  const _KPIItem({
    required this.label,
    required this.valeur,
    required this.icone,
    required this.couleur,
    required this.fond,
    this.petit = false,
  });
}

class _CarteKPI extends StatelessWidget {
  final _KPIItem item;

  const _CarteKPI({required this.item});

  @override
  Widget build(BuildContext context) {
    final w = (MediaQuery.of(context).size.width - 42) / 2;
    return Container(
      width: w,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.carte,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.lignes, width: 1),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF1C2447).withValues(alpha: 0.04),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: item.fond,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(item.icone, size: 18, color: item.couleur),
          ),
          const SizedBox(height: 10),
          Text(
            item.valeur,
            style: GoogleFonts.bricolageGrotesque(
              fontWeight: FontWeight.w800,
              fontSize: item.petit ? 14 : 22,
              color: item.couleur,
              height: 1.1,
            ),
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
          ),
          const SizedBox(height: 3),
          Text(
            item.label,
            style: GoogleFonts.inter(
              fontSize: 11.5,
              color: AppColors.texteDoux,
              height: 1.2,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Mini KPI ──────────────────────────────────────────────────────────────────

class _MiniKPI extends StatelessWidget {
  final String label;
  final String valeur;
  final IconData icone;
  final Color couleur;
  final Color fond;

  const _MiniKPI({
    required this.label,
    required this.valeur,
    required this.icone,
    required this.couleur,
    required this.fond,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.carte,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.lignes, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icone, size: 14, color: couleur),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  label,
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    color: AppColors.texteDoux,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            valeur,
            style: GoogleFonts.bricolageGrotesque(
              fontWeight: FontWeight.w800,
              fontSize: 16,
              color: couleur,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Carte tontine admin ───────────────────────────────────────────────────────

class _CarteTontineAdmin extends StatelessWidget {
  final Map<String, dynamic> tontine;
  final String cle;
  final Future<void> Function(String) onActiver;
  final Future<void> Function(String) onDesactiver;
  final VoidCallback onVoirFiche;

  const _CarteTontineAdmin({
    required this.tontine,
    required this.cle,
    required this.onActiver,
    required this.onDesactiver,
    required this.onVoirFiche,
  });

  @override
  Widget build(BuildContext context) {
    final code     = tontine['code'] as String? ?? '';
    final nom      = tontine['nom']  as String? ?? code;
    final plan     = tontine['plan'] as String? ?? 'free';
    final isPrem   = plan == 'premium';
    final nbM      = _StatsGlobales._int(tontine['nb_membres']);
    final president = tontine['premier_gest'] as String? ?? '—';
    final creeStr  = tontine['cree'] as String?;
    final cree     = creeStr != null ? DateTime.tryParse(creeStr) : null;
    final expireStr = tontine['plan_expire'] as String?;
    final expire   = expireStr != null ? DateTime.tryParse(expireStr) : null;
    final estActif = tontine['est_actif'] as bool? ?? false;
    final expireBientot = tontine['expire_bientot'] as bool? ?? false;

    return CarteTC(
      onTap: onVoirFiche,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      nom,
                      style: GoogleFonts.bricolageGrotesque(
                        fontWeight: FontWeight.w700,
                        fontSize: 15.5,
                        color: AppColors.encre,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        CodePuce(code: code),
                        const SizedBox(width: 6),
                        const Icon(Icons.person_outline,
                            size: 13, color: AppColors.texteDoux),
                        const SizedBox(width: 2),
                        Expanded(
                          child: Text(
                            president,
                            style: GoogleFonts.inter(
                              fontSize: 12,
                              color: AppColors.texteDoux,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  _BadgeStatutTontine(
                    isPremium: isPrem,
                    estActif: estActif,
                    expireBientot: expireBientot,
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _PuceInfo(
                icone: Icons.people_outline,
                texte: '$nbM membres',
              ),
              const SizedBox(width: 12),
              _PuceInfo(
                icone: Icons.calendar_today_outlined,
                texte: 'Créé ${Formatters.dateFormatee(cree)}',
              ),
              if (expire != null) ...[
                const SizedBox(width: 12),
                _PuceInfo(
                  icone: Icons.timer_outlined,
                  texte: expire.isBefore(DateTime.now())
                      ? 'Expiré ${Formatters.dateFormatee(expire)}'
                      : 'Exp. ${Formatters.dateFormatee(expire)}',
                  couleur: expire.isBefore(DateTime.now())
                      ? AppColors.alerte
                      : (expireBientot ? AppColors.or : null),
                ),
              ],
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              if (!isPrem)
                Expanded(
                  child: _BtnAction(
                    label: 'Activer Premium',
                    icone: Icons.star_outline,
                    couleur: AppColors.or,
                    fond: AppColors.fondConsultation,
                    onTap: () => onActiver(code),
                  ),
                )
              else
                Expanded(
                  child: _BtnAction(
                    label: 'Désactiver',
                    icone: Icons.cancel_outlined,
                    couleur: AppColors.alerte,
                    fond: AppColors.alerteFond,
                    onTap: () => onDesactiver(code),
                  ),
                ),
              const SizedBox(width: 8),
              _BtnAction(
                label: 'Voir',
                icone: Icons.open_in_new,
                couleur: AppColors.encre,
                fond: AppColors.fondCode,
                onTap: onVoirFiche,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ── Ligne tontine compacte (Top 5 vue d'ensemble) ─────────────────────────────

class _LigneTontineCompacte extends StatelessWidget {
  final Map<String, dynamic> tontine;
  final VoidCallback onTap;

  const _LigneTontineCompacte({required this.tontine, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final nom  = tontine['nom']  as String? ?? tontine['code'] as String? ?? '—';
    final plan = tontine['plan'] as String? ?? 'free';
    final nb   = _StatsGlobales._int(tontine['nb_membres']);

    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: AppColors.carte,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.lignes, width: 1),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                nom,
                style: GoogleFonts.inter(
                  fontWeight: FontWeight.w600,
                  fontSize: 13.5,
                  color: AppColors.encre,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            BadgePlan(isPremium: plan == 'premium'),
            const SizedBox(width: 10),
            Text(
              '$nb membres',
              style: GoogleFonts.inter(
                  fontSize: 12, color: AppColors.texteDoux),
            ),
            const SizedBox(width: 6),
            const Icon(Icons.chevron_right,
                size: 16, color: AppColors.texteDoux),
          ],
        ),
      ),
    );
  }
}

// ── Carte alerte ──────────────────────────────────────────────────────────────

class _CarteAlerte extends StatelessWidget {
  final Map<String, dynamic> alerte;
  final bool detail;

  const _CarteAlerte({required this.alerte, this.detail = false});

  @override
  Widget build(BuildContext context) {
    final titre   = alerte['titre']  as String? ?? '';
    final detailT = alerte['detail'] as String? ?? '';
    final niveau  = alerte['niveau'] as String? ?? 'info';
    final nb      = _StatsGlobales._int(alerte['nb']);

    final couleur = niveau == 'alerte' ? AppColors.alerte : AppColors.or;
    final fond    = niveau == 'alerte' ? AppColors.alerteFond : AppColors.fondConsultation;
    final icone   = niveau == 'alerte' ? Icons.warning_amber_outlined : Icons.info_outline;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: fond,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: couleur.withValues(alpha: 0.3), width: 1),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: couleur.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icone, size: 18, color: couleur),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  titre,
                  style: GoogleFonts.inter(
                    fontWeight: FontWeight.w700,
                    fontSize: 13.5,
                    color: couleur,
                  ),
                ),
                if (detail && detailT.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    detailT,
                    style: GoogleFonts.inter(
                      fontSize: 12.5,
                      color: AppColors.texteDoux,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (nb > 0)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: couleur,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                '$nb',
                style: GoogleFonts.inter(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ── Carte tontine alerte (expiration) ─────────────────────────────────────────

class _CarteTontineAlerte extends StatelessWidget {
  final Map<String, dynamic> tontine;

  const _CarteTontineAlerte({required this.tontine});

  @override
  Widget build(BuildContext context) {
    final code     = tontine['code'] as String? ?? '';
    final nom      = tontine['nom']  as String? ?? code;
    final expireStr = tontine['plan_expire'] as String?;
    final expire   = expireStr != null ? DateTime.tryParse(expireStr) : null;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.fondConsultation,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: AppColors.or.withValues(alpha: 0.4), width: 1),
      ),
      child: Row(
        children: [
          const Icon(Icons.timer, size: 18, color: AppColors.or),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  nom,
                  style: GoogleFonts.inter(
                    fontWeight: FontWeight.w600,
                    fontSize: 13.5,
                    color: AppColors.encre,
                  ),
                ),
                Text(
                  'Expire le ${Formatters.dateFormatee(expire)}',
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    color: AppColors.orFonce,
                  ),
                ),
              ],
            ),
          ),
          CodePuce(code: code),
        ],
      ),
    );
  }
}

// ── Carte abonnement ──────────────────────────────────────────────────────────

class _CarteAbonnement extends StatelessWidget {
  final Map<String, dynamic> abonnement;

  const _CarteAbonnement({required this.abonnement});

  @override
  Widget build(BuildContext context) {
    final code      = abonnement['code']         as String? ?? '';
    final nom       = abonnement['nom_tontine']  as String? ?? code;
    final formule   = abonnement['formule']      as String? ?? 'mensuel';
    final montant   = _StatsGlobales._int(abonnement['montant']);
    final statut    = abonnement['statut']       as String? ?? '';
    final moyen     = abonnement['moyen_paiement'] as String?;
    final ref       = abonnement['reference']    as String?;
    final debutStr  = abonnement['date_debut']   as String?;
    final finStr    = abonnement['date_fin']      as String?;
    final debut     = debutStr != null ? DateTime.tryParse(debutStr) : null;
    final fin       = finStr   != null ? DateTime.tryParse(finStr)   : null;

    final isActif = statut == 'actif';
    final isExp   = statut == 'expire';
    final couleur = isActif ? AppColors.succes : (isExp ? AppColors.alerte : AppColors.or);
    final fond    = isActif ? AppColors.succesFond : (isExp ? AppColors.alerteFond : AppColors.fondConsultation);

    return CarteTC(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      nom,
                      style: GoogleFonts.inter(
                        fontWeight: FontWeight.w700,
                        fontSize: 14.5,
                        color: AppColors.encre,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    Row(
                      children: [
                        CodePuce(code: code),
                        const SizedBox(width: 6),
                        Text(
                          formule == 'annuel'
                              ? '★ Annuel'
                              : '· Mensuel',
                          style: GoogleFonts.inter(
                            fontSize: 11.5,
                            color: AppColors.texteDoux,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: fond,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      _labelStatutAbo(statut),
                      style: GoogleFonts.inter(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: couleur,
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    Formatters.montantFCFA(montant),
                    style: GoogleFonts.bricolageGrotesque(
                      fontWeight: FontWeight.w800,
                      fontSize: 16,
                      color: AppColors.encre,
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 12,
            runSpacing: 4,
            children: [
              if (debut != null)
                _PuceInfo(
                  icone: Icons.play_circle_outline,
                  texte: 'Début ${Formatters.dateFormatee(debut)}',
                ),
              if (fin != null)
                _PuceInfo(
                  icone: Icons.stop_circle_outlined,
                  texte: 'Fin ${Formatters.dateFormatee(fin)}',
                  couleur: fin.isBefore(DateTime.now())
                      ? AppColors.alerte
                      : null,
                ),
              if (moyen != null)
                _PuceInfo(
                    icone: Icons.payment_outlined,
                    texte: Formatters.methodePaiement(moyen)),
              if (ref != null)
                _PuceInfo(
                    icone: Icons.receipt_outlined,
                    texte: ref),
            ],
          ),
        ],
      ),
    );
  }

  String _labelStatutAbo(String s) {
    switch (s) {
      case 'actif':      return 'Actif';
      case 'expire':     return 'Expiré';
      case 'en_attente': return 'En attente';
      case 'annule':     return 'Annulé';
      default:           return s;
    }
  }
}

// ── Puce info ─────────────────────────────────────────────────────────────────

class _PuceInfo extends StatelessWidget {
  final IconData icone;
  final String texte;
  final Color? couleur;

  const _PuceInfo({required this.icone, required this.texte, this.couleur});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icone,
            size: 12,
            color: couleur ?? AppColors.texteDoux),
        const SizedBox(width: 3),
        Text(
          texte,
          style: GoogleFonts.inter(
            fontSize: 11.5,
            color: couleur ?? AppColors.texteDoux,
          ),
        ),
      ],
    );
  }
}

// ── Badge statut tontine ──────────────────────────────────────────────────────

class _BadgeStatutTontine extends StatelessWidget {
  final bool isPremium;
  final bool estActif;
  final bool expireBientot;

  const _BadgeStatutTontine({
    required this.isPremium,
    required this.estActif,
    required this.expireBientot,
  });

  @override
  Widget build(BuildContext context) {
    if (expireBientot) {
      return _badge('Expire bientôt', AppColors.orFonce, AppColors.fondConsultation);
    }
    if (isPremium && estActif) {
      return _badge('★ Premium', AppColors.orFonce, AppColors.fondConsultation);
    }
    if (isPremium && !estActif) {
      return _badge('Expiré', AppColors.alerte, AppColors.alerteFond);
    }
    return _badge('Gratuit', AppColors.texteDoux, AppColors.fondSecondaire);
  }

  Widget _badge(String label, Color fg, Color bg) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: GoogleFonts.inter(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: fg,
        ),
      ),
    );
  }
}

// ── Bouton action compact ─────────────────────────────────────────────────────

class _BtnAction extends StatelessWidget {
  final String label;
  final IconData icone;
  final Color couleur;
  final Color fond;
  final VoidCallback onTap;

  const _BtnAction({
    required this.label,
    required this.icone,
    required this.couleur,
    required this.fond,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: fond,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
              color: couleur.withValues(alpha: 0.25), width: 1),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icone, size: 14, color: couleur),
            const SizedBox(width: 5),
            Text(
              label,
              style: GoogleFonts.inter(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: couleur,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// FICHE DÉTAILLÉE D'UNE TONTINE (BottomSheet)
// ─────────────────────────────────────────────────────────────────────────────

class _FicheTontine extends StatelessWidget {
  final Map<String, dynamic> tontine;
  final String cle;
  final Future<void> Function(String) onActiver;
  final Future<void> Function(String) onDesactiver;

  const _FicheTontine({
    required this.tontine,
    required this.cle,
    required this.onActiver,
    required this.onDesactiver,
  });

  @override
  Widget build(BuildContext context) {
    final code       = tontine['code']         as String? ?? '';
    final nom        = tontine['nom']           as String? ?? code;
    final plan       = tontine['plan']          as String? ?? 'free';
    final isPrem     = plan == 'premium';
    final president  = tontine['premier_gest']  as String? ?? '—';
    final nbM        = _StatsGlobales._int(tontine['nb_membres']);
    final nbVotes    = _StatsGlobales._int(tontine['nb_votes']);
    final nbPrets    = _StatsGlobales._int(tontine['nb_prets']);
    final montant    = _StatsGlobales._int(tontine['montant_cotis']);
    final perio      = tontine['periodicite']   as String? ?? '—';
    final creeStr    = tontine['cree']          as String?;
    final expireStr  = tontine['plan_expire']   as String?;
    final cree       = creeStr   != null ? DateTime.tryParse(creeStr)   : null;
    final expire     = expireStr != null ? DateTime.tryParse(expireStr) : null;
    final dernierAbo = tontine['dernier_abonnement'] as Map<String, dynamic>?;

    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (_, ctrl) => SingleChildScrollView(
        controller: ctrl,
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Handle ──────────────────────────────────────────────────
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.lignes,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 20),

            // ── En-tête ──────────────────────────────────────────────────
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        nom,
                        style: GoogleFonts.bricolageGrotesque(
                          fontWeight: FontWeight.w800,
                          fontSize: 22,
                          color: AppColors.encre,
                        ),
                      ),
                      Row(
                        children: [
                          CodePuce(code: code),
                          const SizedBox(width: 8),
                          BadgePlan(isPremium: isPrem),
                        ],
                      ),
                    ],
                  ),
                ),
                GestureDetector(
                  onTap: () => Navigator.pop(context),
                  child: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: AppColors.fondSecondaire,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.close,
                        size: 18, color: AppColors.encre),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),

            // ── Infos principales ─────────────────────────────────────────
            _LigneDetail(
                icone: Icons.person_outline,
                label: 'Président',
                valeur: president),
            _LigneDetail(
                icone: Icons.people_outline,
                label: 'Membres',
                valeur: '$nbM'),
            _LigneDetail(
                icone: Icons.how_to_vote_outlined,
                label: 'Votes',
                valeur: '$nbVotes'),
            _LigneDetail(
                icone: Icons.savings_outlined,
                label: 'Prêts',
                valeur: '$nbPrets'),
            _LigneDetail(
                icone: Icons.payments_outlined,
                label: 'Cotisation',
                valeur: montant > 0
                    ? '${Formatters.montantFCFA(montant)} · ${Formatters.periodicite(perio)}'
                    : '—'),
            _LigneDetail(
                icone: Icons.calendar_today_outlined,
                label: 'Créée le',
                valeur: Formatters.dateFormatee(cree)),
            if (expire != null)
              _LigneDetail(
                icone: Icons.timer_outlined,
                label: expire.isBefore(DateTime.now())
                    ? 'Premium expiré le'
                    : 'Premium expire le',
                valeur: Formatters.dateFormatee(expire),
                couleur: expire.isBefore(DateTime.now())
                    ? AppColors.alerte
                    : null,
              ),

            // ── Dernier abonnement ─────────────────────────────────────
            if (dernierAbo != null) ...[
              const SizedBox(height: 16),
              Text(
                'Dernier abonnement',
                style: GoogleFonts.bricolageGrotesque(
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                  color: AppColors.encre,
                ),
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppColors.fondConsultation,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                      color: AppColors.or.withValues(alpha: 0.3), width: 1),
                ),
                child: Column(
                  children: [
                    _LigneDetailPlat(
                        label: 'Formule',
                        valeur: dernierAbo['formule'] as String? ?? '—'),
                    _LigneDetailPlat(
                        label: 'Montant',
                        valeur: Formatters.montantFCFA(
                            _StatsGlobales._int(dernierAbo['montant']))),
                    _LigneDetailPlat(
                        label: 'Paiement',
                        valeur: dernierAbo['moyen_paiement'] as String? ?? '—'),
                    _LigneDetailPlat(
                        label: 'Référence',
                        valeur: dernierAbo['reference'] as String? ?? '—'),
                    _LigneDetailPlat(
                        label: 'Statut',
                        valeur: dernierAbo['statut'] as String? ?? '—'),
                  ],
                ),
              ),
            ],

            const SizedBox(height: 20),
            // ── Actions ────────────────────────────────────────────────
            if (!isPrem)
              BtnPrincipal(
                label: '★ Activer Premium (1 mois — 7,99 €)',
                onTap: () {
                  Navigator.pop(context);
                  onActiver(code);
                },
                couleur: AppColors.or,
              )
            else
              BtnPrincipal(
                label: 'Désactiver Premium',
                onTap: () {
                  Navigator.pop(context);
                  onDesactiver(code);
                },
                couleur: AppColors.alerte,
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

class _LigneDetail extends StatelessWidget {
  final IconData icone;
  final String label;
  final String valeur;
  final Color? couleur;

  const _LigneDetail({
    required this.icone,
    required this.label,
    required this.valeur,
    this.couleur,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icone, size: 16, color: AppColors.texteDoux),
          const SizedBox(width: 10),
          Text(
            '$label :',
            style: GoogleFonts.inter(
                fontSize: 13.5, color: AppColors.texteDoux),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              valeur,
              style: GoogleFonts.inter(
                fontWeight: FontWeight.w700,
                fontSize: 13.5,
                color: couleur ?? AppColors.encre,
              ),
              textAlign: TextAlign.end,
            ),
          ),
        ],
      ),
    );
  }
}

class _LigneDetailPlat extends StatelessWidget {
  final String label;
  final String valeur;

  const _LigneDetailPlat({required this.label, required this.valeur});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Text(
            '$label :',
            style: GoogleFonts.inter(
                fontSize: 12.5, color: AppColors.texteDoux),
          ),
          const Spacer(),
          Text(
            valeur,
            style: GoogleFonts.inter(
              fontWeight: FontWeight.w700,
              fontSize: 12.5,
              color: AppColors.encre,
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// GRAPHIQUES FLUTTER PUR (sans librairie externe)
// ─────────────────────────────────────────────────────────────────────────────

class _PointDonnee {
  final String label;
  final int valeur;
  final Color couleur;

  const _PointDonnee({
    required this.label,
    required this.valeur,
    required this.couleur,
  });
}

// ── Graphique en barres verticales ────────────────────────────────────────────

class _GrafiqueBarres extends StatelessWidget {
  final String titre;
  final List<_PointDonnee> donnees;
  final String Function(int)? formatValeur;

  const _GrafiqueBarres({
    required this.titre,
    required this.donnees,
    this.formatValeur,
  });

  @override
  Widget build(BuildContext context) {
    if (donnees.isEmpty) return const SizedBox.shrink();

    final maxVal = donnees.map((d) => d.valeur).reduce((a, b) => a > b ? a : b);
    final fmt = formatValeur ?? (v) => '$v';

    return CarteTC(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            titre,
            style: GoogleFonts.bricolageGrotesque(
              fontWeight: FontWeight.w700,
              fontSize: 15,
              color: AppColors.encre,
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 140,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: donnees.map((d) {
                final ratio = maxVal > 0 ? d.valeur / maxVal : 0.0;
                return Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        if (d.valeur > 0)
                          Text(
                            fmt(d.valeur),
                            style: GoogleFonts.inter(
                              fontSize: 9,
                              fontWeight: FontWeight.w700,
                              color: d.couleur,
                            ),
                          ),
                        const SizedBox(height: 2),
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 600),
                          height: 100 * ratio,
                          decoration: BoxDecoration(
                            color: d.couleur,
                            borderRadius: const BorderRadius.vertical(
                                top: Radius.circular(4)),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          d.label,
                          style: GoogleFonts.inter(
                            fontSize: 8.5,
                            color: AppColors.texteDoux,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Graphique donut (2 segments) ──────────────────────────────────────────────

class _GrafiqueDonut extends StatelessWidget {
  final String titre;
  final int valeurA;
  final int valeurB;
  final String labelA;
  final String labelB;
  final Color couleurA;
  final Color couleurB;

  const _GrafiqueDonut({
    required this.titre,
    required this.valeurA,
    required this.valeurB,
    required this.labelA,
    required this.labelB,
    required this.couleurA,
    required this.couleurB,
  });

  @override
  Widget build(BuildContext context) {
    final total = valeurA + valeurB;
    final ratioA = total > 0 ? valeurA / total : 0.5;
    final pctA = total > 0 ? (ratioA * 100).round() : 0;
    final pctB = 100 - pctA;

    return CarteTC(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            titre,
            style: GoogleFonts.bricolageGrotesque(
              fontWeight: FontWeight.w700,
              fontSize: 15,
              color: AppColors.encre,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              // ── Barre segmentée ────────────────────────────────────────
              Expanded(
                child: Column(
                  children: [
                    // Barre horizontale segmentée
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: SizedBox(
                        height: 28,
                        child: Row(
                          children: [
                            Flexible(
                              flex: valeurA > 0 ? valeurA : 1,
                              child: Container(
                                color: couleurA,
                                alignment: Alignment.center,
                                child: valeurA > 0
                                    ? Text(
                                        '$pctA%',
                                        style: GoogleFonts.inter(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w700,
                                          color: const Color(0xFF2A1E05),
                                        ),
                                      )
                                    : const SizedBox.shrink(),
                              ),
                            ),
                            Flexible(
                              flex: valeurB > 0 ? valeurB : 1,
                              child: Container(
                                color: couleurB,
                                alignment: Alignment.center,
                                child: valeurB > 0
                                    ? Text(
                                        '$pctB%',
                                        style: GoogleFonts.inter(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w700,
                                          color: AppColors.encreDoux,
                                        ),
                                      )
                                    : const SizedBox.shrink(),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        _LegendeItem(
                            couleur: couleurA,
                            label: '$labelA : $valeurA'),
                        const SizedBox(width: 16),
                        _LegendeItem(
                            couleur: couleurB,
                            label: '$labelB : $valeurB'),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              // ── Chiffre total ─────────────────────────────────────────
              Column(
                children: [
                  Text(
                    '$total',
                    style: GoogleFonts.bricolageGrotesque(
                      fontWeight: FontWeight.w800,
                      fontSize: 32,
                      color: AppColors.encre,
                    ),
                  ),
                  Text(
                    'Total',
                    style: GoogleFonts.inter(
                        fontSize: 12, color: AppColors.texteDoux),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _LegendeItem extends StatelessWidget {
  final Color couleur;
  final String label;

  const _LegendeItem({required this.couleur, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: couleur,
            borderRadius: BorderRadius.circular(3),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: GoogleFonts.inter(
              fontSize: 12, color: AppColors.texteDoux),
        ),
      ],
    );
  }
}

// ── Barres horizontales (Top 10) ──────────────────────────────────────────────

class _GrafiqueBarresHorizontales extends StatelessWidget {
  final List<Map<String, dynamic>> donnees;

  const _GrafiqueBarresHorizontales({required this.donnees});

  @override
  Widget build(BuildContext context) {
    if (donnees.isEmpty) return const SizedBox.shrink();
    final maxVal = donnees
        .map((d) => _StatsGlobales._int(d['nb_membres']))
        .reduce((a, b) => a > b ? a : b);

    return CarteTC(
      child: Column(
        children: donnees.take(10).toList().asMap().entries.map((e) {
          final i  = e.key;
          final d  = e.value;
          final nb = _StatsGlobales._int(d['nb_membres']);
          final nom = d['nom'] as String? ?? d['code'] as String? ?? '—';
          final isPrem = (d['plan'] as String? ?? '') == 'premium';
          final ratio = maxVal > 0 ? nb / maxVal : 0.0;

          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(
              children: [
                SizedBox(
                  width: 22,
                  child: Text(
                    '${i + 1}.',
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: i < 3 ? AppColors.orFonce : AppColors.texteDoux,
                    ),
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              nom,
                              style: GoogleFonts.inter(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                                color: AppColors.encre,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (isPrem) ...[
                            const SizedBox(width: 6),
                            const Icon(Icons.star,
                                size: 12, color: AppColors.or),
                          ],
                          const SizedBox(width: 6),
                          Text(
                            '$nb',
                            style: GoogleFonts.inter(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: AppColors.encre,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: ratio,
                          backgroundColor: AppColors.fondSecondaire,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            isPrem ? AppColors.or : AppColors.encreDoux,
                          ),
                          minHeight: 6,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }
}
