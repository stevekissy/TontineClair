import 'package:flutter/material.dart';
import '../services/supabase_service.dart';
import '../utils/app_colors.dart';
import '../utils/formatters.dart';
import '../widgets/app_widgets.dart';
import 'admin_dashboard_screen.dart';
import '../utils/app_localizations.dart';

class AdminScreen extends StatefulWidget {
  const AdminScreen({super.key});

  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends State<AdminScreen> {
  final _cleCtrl = TextEditingController();
  bool _connecte = false;
  bool _loading = false;
  String? _erreur;
  List<Map<String, dynamic>> _demandes = [];
  List<Map<String, dynamic>> _tontines = [];
  List<Map<String, dynamic>> _depenses = [];
  // Compteurs unifiés calculés depuis adminTontineCounts
  Map<String, dynamic> _counts = {};
  int _onglet = 0;
  // Filtre tontines : null=toutes, 'active','deleted','suspended','inactive','premium','gratuit','expire'
  String? _filtreStatut;
  // Filtre dépenses : 'tous' | 'pending' | 'validee' | 'rejetee'
  String _filtreDepense = 'pending';
  String get _cle => _cleCtrl.text.trim();

  @override
  void dispose() {
    _cleCtrl.dispose();
    super.dispose();
  }

  Future<void> _connecter() async {
    final cle = _cleCtrl.text.trim();
    if (cle.isEmpty) return;
    setState(() {
      _loading = true;
      _erreur = null;
    });

    try {
      // Charger en parallèle : demandes + tontines + compteurs + dépenses
      final results = await Future.wait([
        SupabaseService.adminListerDemandes(cle),
        SupabaseService.adminListerTontines(cle),
        SupabaseService.adminListerDepensesPending(cle),
      ]);
      final counts = await SupabaseService.adminTontineCounts(cle);

      setState(() {
        _connecte = true;
        _demandes = results[0] as List<Map<String, dynamic>>;
        _tontines = results[1] as List<Map<String, dynamic>>;
        _depenses = results[2] as List<Map<String, dynamic>>;
        _counts   = counts;
      });
    } catch (e) {
      setState(() => _erreur = 'Clé incorrecte ou erreur réseau.');
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _activer(String code, {int mois = 1}) async {
    final cle = _cleCtrl.text.trim();
    // Confirmer avant activation
    final confirmer = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.fondPapier,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('Activer Premium', style: TextStyle(fontWeight: FontWeight.w700, color: AppColors.encre)),
        content: Text('Activer Premium pour la tontine $code pendant $mois mois ?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(context.tr('annuler'))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.succes),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(context.tr('activer_premium'), style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (confirmer != true || !mounted) return;

    final ok = await SupabaseService.adminActiverPremium(
      cle: cle, code: code, mois: mois,
    );
    if (!mounted) return;
    if (ok) {
      afficherToast(context, '✅ Premium activé pour $code !');
      await _recharger();
    } else {
      afficherToast(context, 'Erreur lors de l\'activation.', estErreur: true);
    }
  }

  Future<void> _refuserDemande(String code) async {
    final cle       = _cleCtrl.text.trim();
    final motifCtrl = TextEditingController();
    String? motifErreur;

    // ── Dialog avec champ motif ──────────────────────────────────────────────
    final motif = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (sCtx, setSt) => AlertDialog(
          backgroundColor: AppColors.fondPapier,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text(
            context.tr('refuser_demande'),
            style: TextStyle(fontWeight: FontWeight.w700, color: AppColors.alerte),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Code tontine : $code',
                style: TextStyle(fontSize: 13, color: AppColors.texteDoux),
              ),
              SizedBox(height: 14),
              Text(
                context.tr('motif_refus'),
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5, color: AppColors.encre),
              ),
              const SizedBox(height: 6),
              TextField(
                controller: motifCtrl,
                maxLines: 2,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  hintText: 'Ex : Coordonnées invalides, doublon...',
                  filled: true,
                  fillColor: Colors.white,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: AppColors.lignes),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(color: AppColors.lignes),
                  ),
                  errorText: motifErreur,
                ),
                onChanged: (_) {
                  if (motifErreur != null) setSt(() => motifErreur = null);
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, null),
              child: Text(context.tr('annuler')),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: AppColors.alerte),
              onPressed: () {
                final t = motifCtrl.text.trim();
                if (t.length < 3) {
                  setSt(() => motifErreur = 'Veuillez indiquer un motif.');
                  return;
                }
                Navigator.pop(ctx, t);
              },
              child: Text(context.tr('confirmer_refus'), style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      ),
    );

    if (motif == null || !mounted) return;

    // ── Appel RPC avec motif ─────────────────────────────────────────────────
    try {
      await SupabaseService.adminRefuserDemande(
        cle: cle,
        code: code,
        motif: motif,
      );
      if (mounted) {
        afficherToast(context, 'Demande refusée pour $code.');
        await _recharger();
      }
    } catch (e) {
      if (mounted) {
        afficherToast(context, 'Erreur lors du refus : $e', estErreur: true);
      }
    }
  }

  Future<void> _desactiver(String code) async {
    final cle = _cleCtrl.text.trim();
    final ok = await SupabaseService.adminDesactiverPremium(cle: cle, code: code);
    if (!mounted) return;
    if (ok) {
      afficherToast(context, 'Premium désactivé pour $code.');
      await _recharger();
    } else {
      afficherToast(context, 'Erreur.', estErreur: true);
    }
  }

  Future<void> _recharger() async {
    final cle = _cleCtrl.text.trim();
    final results = await Future.wait([
      SupabaseService.adminListerDemandes(cle),
      SupabaseService.adminListerTontines(cle),
      SupabaseService.adminListerDepensesPending(cle),
    ]);
    final counts = await SupabaseService.adminTontineCounts(cle);
    setState(() {
      _demandes = results[0] as List<Map<String, dynamic>>;
      _tontines = results[1] as List<Map<String, dynamic>>;
      _depenses = results[2] as List<Map<String, dynamic>>;
      _counts   = counts;
    });
  }

  Future<void> _validerDepense(int id, String code, int montant, String devise) async {
    final confirmer = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.fondPapier,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          'Valider la dépense',
          style: TextStyle(fontWeight: FontWeight.w700, color: AppColors.encre),
        ),
        content: Text(
          'Confirmer la validation ?\nLa caisse de $code sera débitée de ${Formatters.montant(montant, devise: devise)}.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.succes),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Valider', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    if (confirmer != true || !mounted) return;

    final result = await SupabaseService.adminValiderDepense(cle: _cle, id: id);
    if (!mounted) return;
    if (result['ok'] == true) {
      afficherToast(context, '✅ ${result['message'] ?? 'Dépense validée !'}');
      // Notification aux membres de la tontine
      SupabaseService.envoyerNotification(
        code:    code,
        type:    'caisse',
        titre:   '💸 Dépense approuvée',
        message: 'Une dépense de ${Formatters.montant(montant, devise: devise)} a été approuvée par l\'admin.',
      );
      await _recharger();
    } else {
      afficherToast(context, result['erreur'] as String? ?? 'Erreur validation.', estErreur: true);
    }
  }

  Future<void> _rejeterDepense(int id) async {
    final motifCtrl = TextEditingController();
    String? motifErreur;

    final motif = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (sCtx, setSt) => AlertDialog(
          backgroundColor: AppColors.fondPapier,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text(
            'Rejeter la dépense',
            style: TextStyle(fontWeight: FontWeight.w700, color: AppColors.alerte),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Indiquez le motif de refus :'),
              const SizedBox(height: 10),
              TextField(
                controller: motifCtrl,
                maxLines: 2,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  hintText: 'Ex : Bénéficiaire non identifié...',
                  filled: true,
                  fillColor: Colors.white,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  errorText: motifErreur,
                ),
                onChanged: (_) {
                  if (motifErreur != null) setSt(() => motifErreur = null);
                },
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, null), child: const Text('Annuler')),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: AppColors.alerte),
              onPressed: () {
                final t = motifCtrl.text.trim();
                if (t.length < 3) {
                  setSt(() => motifErreur = 'Motif requis.');
                  return;
                }
                Navigator.pop(ctx, t);
              },
              child: const Text('Rejeter', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
            ),
          ],
        ),
      ),
    );

    if (motif == null || !mounted) return;

    final result = await SupabaseService.adminRejeterDepense(cle: _cle, id: id, motif: motif);
    if (!mounted) return;
    if (result['ok'] == true) {
      afficherToast(context, 'Dépense rejetée.');
      await _recharger();
    } else {
      afficherToast(context, result['erreur'] as String? ?? 'Erreur rejet.', estErreur: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.fondPapier,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(16, 18, 16, 0),
              child: Row(
                children: [
                  LogoTontineClair(),
                  Spacer(),
                  TextButton.icon(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: Icon(Icons.arrow_back, size: 16),
                    label: Text(context.tr('retour')),
                    style: TextButton.styleFrom(foregroundColor: AppColors.encre),
                  ),
                ],
              ),
            ),
            Expanded(
              child: _connecte ? _VueAdmin() : _VueConnexion(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _VueConnexion() {
    return SingleChildScrollView(
      padding: EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            context.tr('espace_admin'),
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 28,
              color: AppColors.encre,
            ),
          ),
          SizedBox(height: 20),
          CarteTC(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ChampLabel(label: context.tr('cle_admin')),
                TextField(
                  controller: _cleCtrl,
                  obscureText: true,
                  decoration: InputDecoration(
                    hintText: 'Clé secrète',
                  ),
                  onSubmitted: (_) => _connecter(),
                ),
                ChampErreur(texte: _erreur),
                SizedBox(height: 16),
                BtnPrincipal(
                  label: context.tr('acceder_btn'),
                  onTap: _connecter,
                  loading: _loading,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _VueAdmin() {
    final nbDepensesPending = _depenses.where((d) => (d['statut'] as String? ?? '') == 'pending').length;
    return Column(
      children: [
        // Onglets
        Padding(
          padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _OngletBtn(
                  label: "${context.tr('demandes')} (\${_demandes.length})",
                  selected: _onglet == 0,
                  onTap: () => setState(() => _onglet = 0),
                ),
                const SizedBox(width: 10),
                _OngletBtn(
                  label: 'Tontines (${_counts.isNotEmpty
                      ? (_counts['total'] ?? _tontines.where((t) => (t['status'] as String? ?? 'active') != 'deleted').length)
                      : _tontines.where((t) => (t['status'] as String? ?? 'active') != 'deleted').length})',
                  selected: _onglet == 1,
                  onTap: () => setState(() => _onglet = 1),
                ),
                const SizedBox(width: 10),
                _OngletBtn(
                  label: '📊 Dashboard',
                  selected: _onglet == 2,
                  onTap: () => setState(() => _onglet = 2),
                ),
                const SizedBox(width: 10),
                // Onglet dépenses avec badge rouge si pending
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    _OngletBtn(
                      label: '💸 Dépenses',
                      selected: _onglet == 3,
                      onTap: () => setState(() => _onglet = 3),
                    ),
                    if (nbDepensesPending > 0)
                      Positioned(
                        top: -4,
                        right: -4,
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: const BoxDecoration(
                            color: AppColors.alerte,
                            shape: BoxShape.circle,
                          ),
                          child: Text(
                            '$nbDepensesPending',
                            style: const TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.w800,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: _onglet == 0
              ? _ListeDemandes()
              : _onglet == 1
                  ? _ListeTontines()
                  : _onglet == 2
                      ? AdminDashboardScreen(cle: _cle)
                      : _ListeDepenses(),
        ),
      ],
    );
  }

  Widget _ListeDemandes() {
    // Séparer en attente vs traitées
    final enAttente = _demandes.where((d) {
      final s = (d['statut'] as String? ?? '').toLowerCase().replaceAll(' ', '_');
      return s == 'en_attente' || s == 'en attente' || s == 'pending';
    }).toList();
    final traitees = _demandes.where((d) {
      final s = (d['statut'] as String? ?? '').toLowerCase().replaceAll(' ', '_');
      return s != 'en_attente' && s != 'en attente' && s != 'pending' && s.isNotEmpty;
    }).toList();

    if (_demandes.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.inbox_outlined, size: 48, color: AppColors.texteDoux.withValues(alpha: 0.5)),
            SizedBox(height: 12),
            Text(
              context.tr('aucune_demande'),
              style: TextStyle(color: AppColors.texteDoux, fontSize: 15),
            ),
          ],
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      children: [
        if (enAttente.isNotEmpty) ...[
          Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                Container(
                  width: 8, height: 8,
                  decoration: BoxDecoration(
                    color: AppColors.alerte,
                    shape: BoxShape.circle,
                  ),
                ),
                SizedBox(width: 8),
                Text(
                  "${context.tr('en_attente')} (\${enAttente.length})",
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                    color: AppColors.encre,
                  ),
                ),
              ],
            ),
          ),
          ...enAttente.map((d) => _CarteDemande(d, enAttente: true)),
        ],
        if (traitees.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.only(top: 16, bottom: 8),
            child: Row(
              children: [
                Container(
                  width: 8, height: 8,
                  decoration: BoxDecoration(
                    color: AppColors.texteDoux.withValues(alpha: 0.5),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  'Traitées (${traitees.length})',
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                    color: AppColors.texteDoux,
                  ),
                ),
              ],
            ),
          ),
          ...traitees.map((d) => _CarteDemande(d, enAttente: false)),
        ],
      ],
    );
  }

  Widget _ListeDepenses() {
    // Filtrage selon statut sélectionné
    final filtered = _filtreDepense == 'tous'
        ? _depenses
        : _depenses.where((d) => (d['statut'] as String? ?? '') == _filtreDepense).toList();

    final nbPending  = _depenses.where((d) => d['statut'] == 'pending').length;
    final nbValidee  = _depenses.where((d) => d['statut'] == 'validee').length;
    final nbRejetee  = _depenses.where((d) => d['statut'] == 'rejetee').length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Filtres ──────────────────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _FiltreChip(
                  label: 'En attente ($nbPending)',
                  selected: _filtreDepense == 'pending',
                  onTap: () => setState(() => _filtreDepense = 'pending'),
                  couleur: AppColors.orFonce,
                ),
                const SizedBox(width: 8),
                _FiltreChip(
                  label: 'Validées ($nbValidee)',
                  selected: _filtreDepense == 'validee',
                  onTap: () => setState(() => _filtreDepense = 'validee'),
                  couleur: AppColors.succes,
                ),
                const SizedBox(width: 8),
                _FiltreChip(
                  label: 'Rejetées ($nbRejetee)',
                  selected: _filtreDepense == 'rejetee',
                  onTap: () => setState(() => _filtreDepense = 'rejetee'),
                  couleur: AppColors.alerte,
                ),
                const SizedBox(width: 8),
                _FiltreChip(
                  label: 'Toutes (${_depenses.length})',
                  selected: _filtreDepense == 'tous',
                  onTap: () => setState(() => _filtreDepense = 'tous'),
                  couleur: AppColors.encreDoux,
                ),
              ],
            ),
          ),
        ),

        // ── Liste ─────────────────────────────────────────────────────────────
        if (filtered.isEmpty)
          Expanded(
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.receipt_long_outlined,
                    size: 48,
                    color: AppColors.texteDoux.withValues(alpha: 0.4),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _filtreDepense == 'pending'
                        ? 'Aucune dépense en attente'
                        : 'Aucune dépense dans cette catégorie',
                    style: const TextStyle(color: AppColors.texteDoux, fontSize: 15),
                  ),
                ],
              ),
            ),
          )
        else
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              itemCount: filtered.length,
              itemBuilder: (_, i) => _CarteDepense(filtered[i]),
            ),
          ),
      ],
    );
  }

  Widget _CarteDepense(Map<String, dynamic> d) {
    final id              = d['id'] as int? ?? 0;
    final code            = d['code'] as String? ?? '—';
    final montant         = d['montant'] as int? ?? 0;
    final description     = d['description'] as String? ?? '';
    final operateur       = d['operateur'] as String? ?? '—';
    final numBenef        = d['numero_beneficiaire'] as String? ?? '—';
    final nomBenef        = d['nom_beneficiaire'] as String? ?? '—';
    final gestionnaire    = d['gestionnaire'] as String? ?? '—';
    final devise          = d['devise'] as String? ?? 'XOF';
    final statut          = d['statut'] as String? ?? 'pending';
    final motifRejet      = d['motif_rejet'] as String?;
    final createdAt       = DateTime.tryParse(d['created_at'] as String? ?? '');
    final valideAt       = d['valide_le'] != null ? DateTime.tryParse(d['valide_le'] as String) : null;

    // Couleurs selon statut
    final Color statutCouleur;
    final Color statutFond;
    final String statutLabel;
    switch (statut) {
      case 'validee':
        statutCouleur = AppColors.succes;
        statutFond    = AppColors.succesFond;
        statutLabel   = '✓ Validée';
        break;
      case 'rejetee':
        statutCouleur = AppColors.alerte;
        statutFond    = AppColors.alerteFond;
        statutLabel   = '✗ Rejetée';
        break;
      default:
        statutCouleur = AppColors.orFonce;
        statutFond    = AppColors.fondConsultation;
        statutLabel   = '⏳ En attente';
    }

    // Icône opérateur
    final IconData opIcon;
    switch (operateur.toLowerCase()) {
      case 'orange': opIcon = Icons.signal_cellular_alt; break;
      case 'mtn':    opIcon = Icons.signal_cellular_alt; break;
      case 'moov':   opIcon = Icons.signal_cellular_alt; break;
      case 'wave':   opIcon = Icons.waves_rounded;       break;
      default:       opIcon = Icons.phone_android_rounded;
    }

    return CarteTC(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Ligne titre + badge statut ─────────────────────────────────────
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      Formatters.montant(montant, devise: devise),
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 18,
                        color: AppColors.alerte,
                      ),
                    ),
                    Text(
                      'Tontine : $code',
                      style: const TextStyle(
                        fontSize: 12,
                        fontFamily: 'monospace',
                        color: AppColors.encreDoux,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                decoration: BoxDecoration(
                  color: statutFond,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  statutLabel,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: statutCouleur,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),

          // ── Infos Mobile Money ────────────────────────────────────────────
          _InfoLigneAdmin(
            icone: opIcon,
            label: 'Opérateur',
            valeur: operateur[0].toUpperCase() + operateur.substring(1),
          ),
          _InfoLigneAdmin(
            icone: Icons.person_outline_rounded,
            label: 'Bénéficiaire',
            valeur: nomBenef,
          ),
          _InfoLigneAdmin(
            icone: Icons.phone_outlined,
            label: 'Numéro',
            valeur: numBenef,
          ),
          if (description.isNotEmpty)
            _InfoLigneAdmin(
              icone: Icons.notes_rounded,
              label: 'Motif',
              valeur: description,
            ),
          _InfoLigneAdmin(
            icone: Icons.manage_accounts_outlined,
            label: 'Gestionnaire',
            valeur: gestionnaire,
          ),
          _InfoLigneAdmin(
            icone: Icons.calendar_today_outlined,
            label: 'Soumis le',
            valeur: Formatters.dateFormatee(createdAt),
          ),
          if (valideAt != null)
            _InfoLigneAdmin(
              icone: Icons.check_circle_outline,
              label: statut == 'validee' ? 'Validé le' : 'Rejeté le',
              valeur: Formatters.dateFormatee(valideAt),
            ),
          if (motifRejet != null && motifRejet.isNotEmpty)
            _InfoLigneAdmin(
              icone: Icons.cancel_outlined,
              label: 'Motif rejet',
              valeur: motifRejet,
            ),

          // ── Boutons d'action (seulement si pending) ────────────────────────
          if (statut == 'pending') ...
            [
              const SizedBox(height: 12),
              const Divider(color: AppColors.lignes, height: 1),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: BtnPrincipal(
                      label: 'Valider',
                      icone: Icons.check_circle_rounded,
                      couleur: AppColors.succes,
                      onTap: () => _validerDepense(id, code, montant, devise),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 2,
                    child: BtnSecondaire(
                      label: 'Rejeter',
                      onTap: () => _rejeterDepense(id),
                    ),
                  ),
                ],
              ),
            ],
        ],
      ),
    );
  }

  Widget _CarteDemande(Map<String, dynamic> d, {required bool enAttente}) {
    final statut      = d['statut'] as String? ?? '';
    final code        = d['code'] as String? ?? '';
    // Nom du demandeur : v12 retourne 'gestionnaire' + 'nom' (double clé pour compat)
    final nom         = d['gestionnaire'] as String? ?? d['nom'] as String? ?? '—';
    final contact     = d['contact'] as String? ?? '—';
    // Formule : v12 retourne 'formule' (alias de 'plan')
    final formule     = d['formule'] as String? ?? d['plan'] as String? ?? 'mensuel';
    final nbMembres   = d['nb_membres'] as int? ?? 0;
    final nomTontine  = d['nom_tontine'] as String? ?? code;
    final quand       = DateTime.tryParse(d['quand'] as String? ?? '');
    final motifRefus  = d['motif_refus'] as String?;

    // Couleur selon statut
    Color statutCouleur;
    Color statutFond;
    String statutLabel;
    // Normalisation du statut : accepte les valeurs v12 ('approuvee', 'refusee',
    // 'en_attente') + anciennes valeurs ('activée', 'refusée', 'active', 'refuse')
    final statutNorm = statut
        .toLowerCase()
        .replaceAll('é', 'e')
        .replaceAll('è', 'e')
        .replaceAll(' ', '_');
    if (statutNorm == 'approuvee' || statutNorm == 'activee' || statutNorm == 'active') {
      statutCouleur = AppColors.succes;
      statutFond    = AppColors.succesFond;
      statutLabel   = '✓ Approuvée';
    } else if (statutNorm == 'refusee' || statutNorm == 'refuse') {
      statutCouleur = AppColors.alerte;
      statutFond    = AppColors.alerteFond;
      statutLabel   = '✗ Refusée';
    } else {
      statutCouleur = AppColors.orFonce;
      statutFond    = AppColors.fondConsultation;
      statutLabel   = '⏳ En attente';
    }

    return CarteTC(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Ligne titre + badge statut ──────────────────────────────
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  nom,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                    color: AppColors.encre,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                decoration: BoxDecoration(
                  color: statutFond,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  statutLabel,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: statutCouleur,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),

          // ── Infos clés ───────────────────────────────────────────────
          _InfoLigneDemande(
            icone: Icons.group_outlined,
            label: 'Tontine',
            valeur: '$nomTontine · Code $code',
          ),
          if (nbMembres > 0)
            _InfoLigneDemande(
              icone: Icons.people_alt_outlined,
              label: 'Membres',
              valeur: '$nbMembres membres',
            ),
          _InfoLigneDemande(
            icone: Icons.phone_outlined,
            label: 'Contact',
            valeur: contact,
          ),
          _InfoLigneDemande(
            icone: Icons.workspace_premium_outlined,
            label: 'Formule',
            valeur: formule == 'annuel'
                ? 'Annuel — 25 000 FCFA/an'
                : 'Mensuel — 2 500 FCFA/mois',
          ),
          _InfoLigneDemande(
            icone: Icons.calendar_today_outlined,
            label: 'Date',
            valeur: Formatters.dateFormatee(quand),
          ),
          // ── Motif de refus (affiché si présent) ─────────────────────
          if (motifRefus != null && motifRefus.isNotEmpty)
            _InfoLigneDemande(
              icone: Icons.cancel_outlined,
              label: 'Motif refus',
              valeur: motifRefus,
            ),

          // ── Boutons d'action (seulement si en attente) ───────────────
          if (enAttente) ...[
            const SizedBox(height: 12),
            const Divider(color: AppColors.lignes, height: 1),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: BtnPrincipal(
                    label: formule == 'annuel' ? 'Activer (12 mois)' : 'Activer (1 mois)',
                    icone: Icons.verified_rounded,
                    couleur: AppColors.succes,
                    onTap: () => _activer(
                      code,
                      mois: formule == 'annuel' ? 12 : 1,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: BtnSecondaire(
                    label: 'Refuser',
                    onTap: () => _refuserDemande(code),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _InfoLigneDemande({
    required IconData icone,
    required String label,
    required String valeur,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icone, size: 13, color: AppColors.encreDoux),
          const SizedBox(width: 6),
          Text(
            '$label : ',
            style: const TextStyle(
              fontSize: 12,
              color: AppColors.texteDoux,
              fontWeight: FontWeight.w600,
            ),
          ),
          Expanded(
            child: Text(
              valeur,
              style: const TextStyle(
                fontSize: 12,
                color: AppColors.encre,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _ListeTontines() {
    final now = DateTime.now();

    // ── Classement de chaque tontine dans une catégorie ───────────────────────
    // Catégories exclusives dans l'ordre de priorité :
    //   deleted > suspended > inactive > expire (premium expiré) > premium > gratuit (active)
    String _categorie(Map<String, dynamic> t) {
      final st = (t['status'] as String? ?? 'active');
      if (st == 'deleted')   return 'deleted';
      if (st == 'suspended') return 'suspended';
      if (st == 'inactive')  return 'inactive';
      final isPremium  = (t['plan'] as String? ?? '') == 'premium';
      final expireStr  = t['plan_expire'] as String? ?? t['expire'] as String?;
      final expire     = expireStr != null ? DateTime.tryParse(expireStr) : null;
      if (isPremium && expire != null && expire.isBefore(now)) return 'expire';
      if (isPremium) return 'premium';
      return 'gratuit';
    }

    // ── Comptes par catégorie ────────────────────────────────────────────────
    // Toujours calculer depuis _tontines (source de vérité locale, cohérente
    // avec la liste affichée). _counts RPC est utilisé uniquement si _tontines
    // est vide ET que _counts retourne un total > 0.
    final bool rpcFiable = _tontines.isEmpty &&
        _counts.isNotEmpty &&
        ((_counts['total'] as num?)?.toInt() ?? 0) > 0;

    final int nbTotal      = rpcFiable
        ? ((_counts['total']      ?? 0) as num).toInt()
        : _tontines.where((t) => _categorie(t) != 'deleted').length;
    final int nbActives    = rpcFiable
        ? ((_counts['actives']    ?? 0) as num).toInt()
        : _tontines.where((t) => _categorie(t) == 'gratuit' || _categorie(t) == 'premium').length;
    final int nbPremium    = rpcFiable
        ? ((_counts['premium']    ?? 0) as num).toInt()
        : _tontines.where((t) => _categorie(t) == 'premium').length;
    final int nbGratuites  = rpcFiable
        ? ((_counts['gratuites']  ?? 0) as num).toInt()
        : _tontines.where((t) => _categorie(t) == 'gratuit').length;
    final int nbExpirees   = rpcFiable
        ? ((_counts['expirees']   ?? 0) as num).toInt()
        : _tontines.where((t) => _categorie(t) == 'expire').length;
    final int nbSuspendues = rpcFiable
        ? ((_counts['suspendues'] ?? 0) as num).toInt()
        : _tontines.where((t) => _categorie(t) == 'suspended').length;
    final int nbInactives  = rpcFiable
        ? ((_counts['inactives']  ?? 0) as num).toInt()
        : _tontines.where((t) => _categorie(t) == 'inactive').length;
    final int nbSupprimees = rpcFiable
        ? ((_counts['supprimees'] ?? 0) as num).toInt()
        : _tontines.where((t) => _categorie(t) == 'deleted').length;

    // ── Filtrage de la liste affichée ────────────────────────────────────────
    final tontinesFiltrees = _filtreStatut == null
        ? _tontines // Toutes (y compris supprimées pour la vue admin)
        : _tontines.where((t) {
            if (_filtreStatut == 'premium')  return _categorie(t) == 'premium';
            if (_filtreStatut == 'gratuit')  return _categorie(t) == 'gratuit';
            if (_filtreStatut == 'expire')   return _categorie(t) == 'expire';
            return (t['status'] as String? ?? 'active') == _filtreStatut;
          }).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Résumé statistiques ─────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Row(
            children: [
              _StatBadge(label: 'Actives', valeur: nbActives, couleur: AppColors.succes),
              const SizedBox(width: 8),
              _StatBadge(label: 'Premium', valeur: nbPremium, couleur: AppColors.or),
              const SizedBox(width: 8),
              _StatBadge(label: 'Gratuites', valeur: nbGratuites, couleur: AppColors.encreDoux),
              if (nbSupprimees > 0) ...[
                const SizedBox(width: 8),
                _StatBadge(label: 'Supprimées', valeur: nbSupprimees, couleur: AppColors.alerte),
              ],
            ],
          ),
        ),

        // ── Filtres ──────────────────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _FiltreChip(
                  label: 'Toutes ($nbTotal)',
                  selected: _filtreStatut == null,
                  onTap: () => setState(() => _filtreStatut = null),
                  couleur: AppColors.encre,
                ),
                const SizedBox(width: 8),
                _FiltreChip(
                  label: 'Actives ($nbActives)',
                  selected: _filtreStatut == 'active',
                  onTap: () => setState(() => _filtreStatut = 'active'),
                  couleur: AppColors.succes,
                ),
                const SizedBox(width: 8),
                _FiltreChip(
                  label: 'Gratuites ($nbGratuites)',
                  selected: _filtreStatut == 'gratuit',
                  onTap: () => setState(() => _filtreStatut = 'gratuit'),
                  couleur: AppColors.encreDoux,
                ),
                const SizedBox(width: 8),
                _FiltreChip(
                  label: 'Premium ($nbPremium)',
                  selected: _filtreStatut == 'premium',
                  onTap: () => setState(() => _filtreStatut = 'premium'),
                  couleur: AppColors.or,
                ),
                if (nbExpirees > 0) ...[
                  const SizedBox(width: 8),
                  _FiltreChip(
                    label: 'Expirées ($nbExpirees)',
                    selected: _filtreStatut == 'expire',
                    onTap: () => setState(() => _filtreStatut = 'expire'),
                    couleur: AppColors.orFonce,
                  ),
                ],
                if (nbSuspendues > 0) ...[
                  const SizedBox(width: 8),
                  _FiltreChip(
                    label: 'Désactivées ($nbSuspendues)',
                    selected: _filtreStatut == 'suspended',
                    onTap: () => setState(() => _filtreStatut = 'suspended'),
                    couleur: AppColors.orFonce,
                  ),
                ],
                if (nbInactives > 0) ...[
                  const SizedBox(width: 8),
                  _FiltreChip(
                    label: 'Inactives ($nbInactives)',
                    selected: _filtreStatut == 'inactive',
                    onTap: () => setState(() => _filtreStatut = 'inactive'),
                    couleur: AppColors.texteDoux,
                  ),
                ],
                // Supprimées : toujours visible pour accès rapide Admin
                const SizedBox(width: 8),
                _FiltreChip(
                  label: 'Supprimées ($nbSupprimees)',
                  selected: _filtreStatut == 'deleted',
                  onTap: () => setState(() => _filtreStatut = 'deleted'),
                  couleur: AppColors.alerte,
                ),
              ],
            ),
          ),
        ),

        // ── Liste ────────────────────────────────────────────────
        if (tontinesFiltrees.isEmpty)
          Expanded(
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    _filtreStatut == 'deleted'
                        ? Icons.delete_outline_rounded
                        : Icons.search_off_rounded,
                    size: 44,
                    color: AppColors.texteDoux.withValues(alpha: 0.4),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _filtreStatut == 'deleted'
                        ? 'Aucune tontine supprimée.'
                        : 'Aucune tontine dans cette catégorie.',
                    style: const TextStyle(color: AppColors.texteDoux, fontSize: 15),
                  ),
                ],
              ),
            ),
          )
        else
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              itemCount: tontinesFiltrees.length,
              itemBuilder: (_, i) {
                final t           = tontinesFiltrees[i];
                final code        = t['code'] as String? ?? '';
                final status      = (t['status'] as String? ?? 'active');
                final isSupprimee = status == 'deleted';
                final isPremium   = (t['plan'] as String? ?? '') == 'premium';
                final expireStr   = t['plan_expire'] as String? ?? t['expire'] as String?;
                final expire      = expireStr != null ? DateTime.tryParse(expireStr) : null;
                final isExpire    = isPremium && expire != null && expire.isBefore(now);

                // Nom : utiliser 'nom' en priorité, fallback 'code'
                final nomBrut   = t['nom'] as String?;
                final nomAffich = (nomBrut == null || nomBrut.trim().isEmpty)
                    ? 'Tontine sans nom'
                    : nomBrut.trim();

                // Gestionnaire / propriétaire
                final gest = t['president'] as String?
                    ?? t['gestionnaire'] as String?
                    ?? t['created_by'] as String?
                    ?? t['owner'] as String?;

                // Membres
                final nbMembres = t['membres'] as int? ?? t['nb_membres'] as int? ?? 0;

                // Dates
                final cree      = DateTime.tryParse(t['cree'] as String? ?? '');
                final deletedAt = t['deleted_at'] != null
                    ? DateTime.tryParse(t['deleted_at'] as String)
                    : null;

                return CarteTC(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                // ── Nom tontine ────────────────────────────
                                Text(
                                  nomAffich,
                                  style: TextStyle(
                                    fontWeight: FontWeight.w700,
                                    fontSize: 15,
                                    color: isSupprimee ? AppColors.texteDoux : AppColors.encre,
                                    decoration: isSupprimee ? TextDecoration.lineThrough : null,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                // ── Code ───────────────────────────────────
                                Text(
                                  'Code : $code',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontFamily: 'monospace',
                                    color: AppColors.encreDoux,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                // ── Membres + date création ────────────────
                                Text(
                                  '$nbMembres membre${nbMembres > 1 ? 's' : ''}'
                                  '${cree != null ? ' · Créé ${Formatters.dateFormatee(cree)}' : ''}',
                                  style: const TextStyle(fontSize: 12, color: AppColors.texteDoux),
                                ),
                                // ── Gestionnaire ───────────────────────────
                                if (gest != null && gest.isNotEmpty)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 2),
                                    child: Text(
                                      'Gestionnaire : $gest',
                                      style: const TextStyle(fontSize: 12, color: AppColors.texteDoux),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          // ── Badge statut + actions ─────────────────────
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              if (isSupprimee)
                                _BadgeStatut(label: 'Supprimée', couleur: AppColors.alerte)
                              else if (isExpire)
                                _BadgeStatut(label: 'Expirée', couleur: AppColors.orFonce)
                              else
                                BadgePlan(isPremium: isPremium),
                              if (!isSupprimee) ...[
                                const SizedBox(height: 6),
                                if (!isPremium)
                                  _BtnAction(
                                    label: 'Activer',
                                    couleur: AppColors.encre,
                                    onTap: () => _activer(code),
                                  )
                                else
                                  _BtnAction(
                                    label: 'Désactiver',
                                    couleur: AppColors.alerte,
                                    onTap: () => _desactiver(code),
                                  ),
                              ],
                            ],
                          ),
                        ],
                      ),

                      // ── Détails expiration ──────────────────────────────
                      if (isExpire && expire != null) ...[
                        const SizedBox(height: 6),
                        _InfoLigneAdmin(
                          icone: Icons.timer_off_rounded,
                          label: 'Expiré le',
                          valeur: Formatters.dateFormatee(expire),
                        ),
                      ],

                      // ── Détails suppression ─────────────────────────────
                      if (isSupprimee) ...[
                        const SizedBox(height: 10),
                        const Divider(height: 1, color: AppColors.lignes),
                        const SizedBox(height: 8),
                        _InfoLigneAdmin(
                          icone: Icons.person_outline_rounded,
                          label: 'Gestionnaire',
                          valeur: gest ?? '—',
                        ),
                        _InfoLigneAdmin(
                          icone: Icons.group_outlined,
                          label: 'Membres avant suppression',
                          valeur: '$nbMembres',
                        ),
                        _InfoLigneAdmin(
                          icone: Icons.workspace_premium_rounded,
                          label: 'Formule',
                          valeur: isPremium ? 'Premium' : 'Gratuit',
                        ),
                        if (cree != null)
                          _InfoLigneAdmin(
                            icone: Icons.event_outlined,
                            label: 'Créée le',
                            valeur: Formatters.dateFormatee(cree),
                          ),
                        if (t['deleted_by'] != null)
                          _InfoLigneAdmin(
                            icone: Icons.person_remove_outlined,
                            label: 'Supprimé par',
                            valeur: t['deleted_by'] as String,
                          ),
                        if (deletedAt != null)
                          _InfoLigneAdmin(
                            icone: Icons.delete_outline_rounded,
                            label: 'Date de suppression',
                            valeur: Formatters.dateFormatee(deletedAt),
                          ),
                        if (t['deletion_reason'] != null &&
                            (t['deletion_reason'] as String).isNotEmpty)
                          _InfoLigneAdmin(
                            icone: Icons.notes_rounded,
                            label: 'Motif',
                            valeur: t['deletion_reason'] as String,
                          ),
                        const SizedBox(height: 10),
                        // Bouton restaurer
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed: () => _restaurerTontine(context, code, nomAffich),
                            icon: const Icon(Icons.restore_rounded, size: 16),
                            label: const Text(
                              'Restaurer la tontine',
                              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                            ),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: AppColors.succes,
                              side: BorderSide(color: AppColors.succes.withValues(alpha: 0.5)),
                              padding: const EdgeInsets.symmetric(vertical: 9),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8)),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                );
              },
            ),
          ),
      ],
    );
  }

  /// Dialogue de restauration d'une tontine supprimée (Super Admin)
  Future<void> _restaurerTontine(BuildContext context, String code, String nom) async {
    final motifCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Restaurer la tontine',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 17)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Restaurer « $nom » ?',
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
            ),
            const SizedBox(height: 6),
            const Text(
              'La tontine redeviendra active. Un nouveau code d\'invitation '
              'sera généré. L\'ancien code reste définitivement invalide.',
              style: TextStyle(fontSize: 13, color: AppColors.texteDoux, height: 1.5),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: motifCtrl,
              decoration: const InputDecoration(
                labelText: 'Motif de restauration *',
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
              maxLines: 2,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.succes),
            child: const Text('Restaurer', style: TextStyle(fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );

    if (ok != true || !mounted) return;
    if (motifCtrl.text.trim().length < 5) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Le motif est obligatoire (minimum 5 caractères).')),
      );
      return;
    }

    setState(() => _loading = true);
    try {
      final result = await SupabaseService.restaurerTontine(
        cle:   _cle,
        code:  code,
        motif: motifCtrl.text.trim(),
      );
      if (!mounted) return;
      if (result['ok'] == true) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(result['message'] as String? ?? 'Tontine restaurée avec succès.'),
            backgroundColor: AppColors.succes,
          ),
        );
        // Recharger la liste
        final tontines = await SupabaseService.adminListerTontines(_cle);
        if (mounted) setState(() { _tontines = tontines; _loading = false; });
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(result['erreur'] as String? ?? 'Erreur lors de la restauration.'),
            backgroundColor: AppColors.alerte,
          ),
        );
        setState(() => _loading = false);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erreur : $e'), backgroundColor: AppColors.alerte),
        );
        setState(() => _loading = false);
      }
    }
  }
}

class _OngletBtn extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _OngletBtn({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? AppColors.encre : AppColors.fondCode,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 13,
            color: selected ? Colors.white : AppColors.encre,
          ),
        ),
      ),
    );
  }
}

// ─── Filtre chip statut ────────────────────────────────────────────────────────
class _FiltreChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Color couleur;

  const _FiltreChip({
    required this.label,
    required this.selected,
    required this.onTap,
    required this.couleur,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? couleur : couleur.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: couleur.withValues(alpha: 0.4)),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: selected ? Colors.white : couleur,
          ),
        ),
      ),
    );
  }
}

// ─── Ligne info admin ──────────────────────────────────────────────────────────
class _InfoLigneAdmin extends StatelessWidget {
  final IconData icone;
  final String label;
  final String valeur;

  const _InfoLigneAdmin({
    required this.icone,
    required this.label,
    required this.valeur,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icone, size: 14, color: AppColors.texteDoux),
          const SizedBox(width: 6),
          Text(
            '$label : ',
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: AppColors.texteDoux,
            ),
          ),
          Expanded(
            child: Text(
              valeur,
              style: const TextStyle(fontSize: 12, color: AppColors.texte),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Badge statistique compact ─────────────────────────────────────────────────
class _StatBadge extends StatelessWidget {
  final String label;
  final int valeur;
  final Color couleur;

  const _StatBadge({
    required this.label,
    required this.valeur,
    required this.couleur,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: couleur.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: couleur.withValues(alpha: 0.3)),
      ),
      child: Column(
        children: [
          Text(
            '$valeur',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: couleur,
            ),
          ),
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: couleur,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Badge statut tontine ──────────────────────────────────────────────────────
class _BadgeStatut extends StatelessWidget {
  final String label;
  final Color couleur;

  const _BadgeStatut({required this.label, required this.couleur});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: couleur.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: couleur.withValues(alpha: 0.3)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: couleur,
        ),
      ),
    );
  }
}

// ─── Bouton action compact (Activer / Désactiver) ──────────────────────────────
class _BtnAction extends StatelessWidget {
  final String label;
  final Color couleur;
  final VoidCallback onTap;

  const _BtnAction({
    required this.label,
    required this.couleur,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: couleur.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: couleur.withValues(alpha: 0.3)),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            color: couleur,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}
