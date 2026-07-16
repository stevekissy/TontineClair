import 'package:flutter/material.dart';
import '../services/supabase_service.dart';
import '../utils/app_colors.dart';
import '../utils/formatters.dart';
import '../widgets/app_widgets.dart';
import 'admin_dashboard_screen.dart';
import 'equipe_screen.dart';
import 'messagerie_screen.dart';
import 'support_admin_screen.dart';
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
  List<Map<String, dynamic>> _prets          = [];
  List<Map<String, dynamic>> _decaissements  = [];
  List<Map<String, dynamic>> _kycs            = [];
  // Compteurs unifiés calculés depuis adminTontineCounts
  Map<String, dynamic> _counts = {};
  int _onglet = 0;
  // Filtre tontines : null=toutes, 'active','deleted','suspended','inactive','premium','gratuit','expire'
  String? _filtreStatut;
  // Filtre dépenses : 'tous' | 'pending' | 'validee' | 'rejetee'
  String _filtreDepense      = 'pending';
  // Filtre prêts : 'pending' | 'validee' | 'rejetee' | 'tous'
  String _filtrePret         = 'pending';
  // Filtre décaissements : 'pending' | 'validee' | 'rejetee' | 'tous'
  String _filtreDecaissement = 'pending';
  // Filtre KYC : 'pending' | 'valide' | 'rejete' | 'tous'
  String _filtreKyc          = 'pending';
  String get _cle => _cleCtrl.text.trim();

  // ── Auth membre (role-based login) ───────────────────────────────────────────
  // null = connecté via clé master ; non-null = connecté en tant que membre
  String? _pseudoMembre;
  String? _clePersoMembre;
  String? _roleMembre;  // 'super_admin' | 'comptable' | 'conformite'
  String? _nomMembre;
  bool get _estMembreRole => _roleMembre != null;
  // Clés des champs pseudo/clePerso pour la connexion membre
  final _pseudoCtrl   = TextEditingController();
  final _clePersoCtrl = TextEditingController();
  bool _loginMembreMode = false; // bascule entre mode clé-master et mode membre

  @override
  void dispose() {
    _cleCtrl.dispose();
    _pseudoCtrl.dispose();
    _clePersoCtrl.dispose();
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
      final results = await Future.wait<List<Map<String, dynamic>>>(
        [
          SupabaseService.adminListerDemandes(cle),
          SupabaseService.adminListerTontines(cle),
          SupabaseService.adminListerDepensesPending(cle),
          SupabaseService.adminListerPretsPending(cle, statut: 'tous'),
          SupabaseService.adminListerDecaissements(cle, statut: 'tous'),
          SupabaseService.adminListerKyc(cle, statut: 'tous'),
        ],
      );
      final counts = await SupabaseService.adminTontineCounts(cle);

      setState(() {
        _connecte       = true;
        _demandes       = results[0];
        _tontines       = results[1];
        _depenses       = results[2];
        _prets          = results[3];
        _decaissements  = results[4];
        _kycs           = results[5];
        _counts         = counts;
      });
    } catch (e) {
      setState(() => _erreur = 'Clé incorrecte ou erreur réseau.');
    } finally {
      setState(() => _loading = false);
    }
  }

  // ── Connexion membre (pseudo + clePerso, role-based) ─────────────────────────
  Future<void> _connecterMembre() async {
    final pseudo   = _pseudoCtrl.text.trim();
    final clePerso = _clePersoCtrl.text.trim();
    if (pseudo.isEmpty || clePerso.isEmpty) {
      setState(() => _erreur = 'Pseudo et clé personnelle requis.');
      return;
    }
    setState(() { _loading = true; _erreur = null; });
    try {
      final res = await SupabaseService.adminAuthMembre(
        pseudo: pseudo, clePerso: clePerso,
      );
      if (res['ok'] != true) {
        setState(() => _erreur = 'Identifiants incorrects ou compte désactivé.');
        return;
      }
      final role = res['role'] as String? ?? '';
      // Charger uniquement les données selon le rôle
      List<Map<String, dynamic>> decaissements = [];
      List<Map<String, dynamic>> kycs          = [];
      if (role == 'comptable' || role == 'super_admin') {
        decaissements = await SupabaseService.adminListerDecaissements(_cle, statut: 'tous');
      }
      if (role == 'conformite' || role == 'super_admin') {
        kycs = await SupabaseService.adminListerKyc(_cle, statut: 'tous');
      }
      setState(() {
        _pseudoMembre   = pseudo;
        _clePersoMembre = clePerso;
        _roleMembre     = role;
        _nomMembre      = res['nom'] as String? ?? pseudo;
        _decaissements  = decaissements;
        _kycs           = kycs;
        _connecte       = true;
        // Onglet par défaut selon le rôle
        _onglet = role == 'conformite' ? 7 : 6; // KYC ou Décaissements
      });
    } catch (e) {
      setState(() => _erreur = 'Erreur de connexion : $e');
    } finally {
      if (mounted) setState(() => _loading = false);
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
    final results = await Future.wait<List<Map<String, dynamic>>>(
      [
        SupabaseService.adminListerDemandes(cle),
        SupabaseService.adminListerTontines(cle),
        SupabaseService.adminListerDepensesPending(cle),
        SupabaseService.adminListerPretsPending(cle, statut: 'tous'),
        SupabaseService.adminListerDecaissements(cle, statut: 'tous'),
        SupabaseService.adminListerKyc(cle, statut: 'tous'),
      ],
    );
    final counts = await SupabaseService.adminTontineCounts(cle);
    setState(() {
      _demandes      = results[0];
      _tontines      = results[1];
      _depenses      = results[2];
      _prets         = results[3];
      _decaissements = results[4];
      _kycs          = results[5];
      _counts        = counts;
    });
  }

  Future<void> _validerPret(int id, String code, int montantNet, String devise) async {
    final confirmer = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.fondPapier,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          'Valider le prêt',
          style: TextStyle(fontWeight: FontWeight.w700, color: AppColors.encre),
        ),
        content: Text(
          'Confirmer la validation ?\nLa caisse de $code sera débitée de ${Formatters.montant(montantNet, devise: devise)} (montant net).',
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

    final result = await SupabaseService.adminValiderPret(cle: _cle, id: id);
    if (!mounted) return;
    if (result['ok'] == true) {
      afficherToast(context, '✅ Prêt validé — caisse débitée !');
      SupabaseService.envoyerNotification(
        code:    code,
        type:    'pret',
        titre:   '🏦 Prêt approuvé',
        message: 'Un prêt de ${Formatters.montant(montantNet, devise: devise)} a été approuvé et décaissé.',
      );
      await _recharger();
    } else {
      afficherToast(context, result['erreur'] as String? ?? 'Erreur validation.', estErreur: true);
    }
  }

  Future<void> _rejeterPret(int id) async {
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
            'Rejeter le prêt',
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
                  hintText: 'Ex : Solde insuffisant, doublon...',
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

    final result = await SupabaseService.adminRejeterPret(cle: _cle, id: id, motif: motif);
    if (!mounted) return;
    if (result['ok'] == true) {
      afficherToast(context, 'Prêt rejeté.');
      await _recharger();
    } else {
      afficherToast(context, result['erreur'] as String? ?? 'Erreur rejet.', estErreur: true);
    }
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

  bool _recharging = false;

  Future<void> _rechargerAvecFeedback() async {
    if (_recharging) return;
    setState(() => _recharging = true);
    try {
      await _recharger();
    } finally {
      if (mounted) setState(() => _recharging = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.fondPapier,
      body: SafeArea(
        child: _connecte ? _CorpsAdmin() : _VueConnexion(),
      ),
    );
  }

  // ── Page de connexion (clé master OU pseudo+clePerso membre) ───────────────
  Widget _VueConnexion() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
      child: StatefulBuilder(
        builder: (ctx, setLocalState) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Logo + titre ────────────────────────────────────────────────
            Row(
              children: [
                Container(
                  width: 52, height: 52,
                  decoration: BoxDecoration(
                    color: AppColors.encre,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(Icons.admin_panel_settings_rounded,
                      color: Colors.white, size: 28),
                ),
                const SizedBox(width: 14),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: const [
                    Text(
                      'Espace Admin',
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 22,
                        color: AppColors.encre,
                      ),
                    ),
                    Text(
                      'TontineClair — accès restreint',
                      style: TextStyle(fontSize: 12, color: AppColors.texteDoux),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 24),

            // ── Sélecteur mode connexion ─────────────────────────────────────
            Container(
              decoration: BoxDecoration(
                color: AppColors.lignes,
                borderRadius: BorderRadius.circular(12),
              ),
              padding: const EdgeInsets.all(4),
              child: Row(
                children: [
                  Expanded(
                    child: GestureDetector(
                      onTap: () => setLocalState(() {
                        _loginMembreMode = false;
                        _erreur = null;
                      }),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        decoration: BoxDecoration(
                          color: !_loginMembreMode ? AppColors.encre : Colors.transparent,
                          borderRadius: BorderRadius.circular(9),
                        ),
                        child: Text(
                          'Super Admin',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 13,
                            color: !_loginMembreMode ? Colors.white : AppColors.texteDoux,
                          ),
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: GestureDetector(
                      onTap: () => setLocalState(() {
                        _loginMembreMode = true;
                        _erreur = null;
                      }),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        decoration: BoxDecoration(
                          color: _loginMembreMode ? AppColors.encre : Colors.transparent,
                          borderRadius: BorderRadius.circular(9),
                        ),
                        child: Text(
                          'Membre équipe',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 13,
                            color: _loginMembreMode ? Colors.white : AppColors.texteDoux,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),

            // ── Formulaire selon mode ────────────────────────────────────────
            CarteTC(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (!_loginMembreMode) ...[
                    // Mode clé master (super admin)
                    const ChampLabel(label: 'Clé administrateur'),
                    TextField(
                      controller: _cleCtrl,
                      obscureText: true,
                      decoration: const InputDecoration(hintText: 'Clé secrète admin'),
                      onSubmitted: (_) => _connecter(),
                    ),
                  ] else ...[
                    // Mode membre (comptable / conformité)
                    const ChampLabel(label: 'Pseudo'),
                    TextField(
                      controller: _pseudoCtrl,
                      decoration: const InputDecoration(
                        hintText: 'Votre pseudo membre',
                        prefixIcon: Icon(Icons.person_outline, size: 18),
                      ),
                      textInputAction: TextInputAction.next,
                    ),
                    const SizedBox(height: 14),
                    const ChampLabel(label: 'Clé personnelle'),
                    TextField(
                      controller: _clePersoCtrl,
                      obscureText: true,
                      decoration: const InputDecoration(
                        hintText: 'Votre clé secrète',
                        prefixIcon: Icon(Icons.lock_outline, size: 18),
                      ),
                      onSubmitted: (_) => _connecterMembre(),
                    ),
                  ],
                  ChampErreur(texte: _erreur),
                  const SizedBox(height: 16),
                  BtnPrincipal(
                    label: 'Accéder',
                    onTap: _loginMembreMode ? _connecterMembre : _connecter,
                    loading: _loading,
                  ),
                  if (_loginMembreMode) ...[
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        const Icon(Icons.info_outline, size: 13, color: AppColors.texteDoux),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            'Accès limité à votre rôle (Comptable ou Conformité)',
                            style: TextStyle(fontSize: 11.5, color: AppColors.texteDoux),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 16),
            TextButton.icon(
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.arrow_back, size: 15),
              label: Text(context.tr('retour')),
              style: TextButton.styleFrom(foregroundColor: AppColors.texteDoux),
            ),
          ],
        ),
      ),
    );
  }

  // ── Corps principal admin (après connexion) ──────────────────────────────────
  Widget _CorpsAdmin() {
    final nbDepensesPending      = _depenses.where((d) => (d['statut'] as String? ?? '') == 'pending').length;
    final nbPretsPending         = _prets.where((p) => (p['statut'] as String? ?? '') == 'pending').length;
    final nbDecaissementsPending = _decaissements.where((d) => (d['statut'] as String? ?? '') == 'pending').length;
    final nbKycPending           = _kycs.where((k) => (k['statut'] as String? ?? '') == 'pending').length;
    final nbDemandesPending      = _demandes.where((d) {
      final s = (d['statut'] as String? ?? '').toLowerCase().replaceAll(' ', '_');
      return s == 'en_attente' || s == 'pending';
    }).length;
    final totalAlertes = nbDemandesPending + nbDepensesPending + nbPretsPending +
        nbDecaissementsPending + nbKycPending;

    // ── Onglets visibles selon le rôle ───────────────────────────────────────
    // index réels : 0=Accueil 1=Demandes 2=Tontines 3=Stats 4=Dépenses 5=Prêts
    //               6=Décaiss. 7=KYC 8=Équipe 9=Messagerie 10=Support
    // Comptable  → uniquement Décaissements (index 6)
    // Conformité → uniquement KYC (index 7)
    // Super-admin → tout
    List<_OngletDef> onglets;
    if (_roleMembre == 'comptable') {
      onglets = [
        _OngletDef(icone: Icons.account_balance_wallet_rounded, label: 'Décaiss.',  badge: nbDecaissementsPending, index: 6),
        _OngletDef(icone: Icons.forum_outlined,                  label: 'Messages',  badge: 0,                      index: 9),
      ];
      if (!onglets.any((o) => o.index == _onglet)) {
        WidgetsBinding.instance.addPostFrameCallback((_) => setState(() => _onglet = 6));
      }
    } else if (_roleMembre == 'conformite') {
      onglets = [
        _OngletDef(icone: Icons.badge_outlined,  label: 'KYC',       badge: nbKycPending, index: 7),
        _OngletDef(icone: Icons.forum_outlined,  label: 'Messages',  badge: 0,            index: 9),
      ];
      if (!onglets.any((o) => o.index == _onglet)) {
        WidgetsBinding.instance.addPostFrameCallback((_) => setState(() => _onglet = 7));
      }
    } else {
      // super_admin ou clé master → accès complet
      onglets = [
        _OngletDef(icone: Icons.home_rounded,                   label: 'Accueil',   badge: 0,                      index: 0),
        _OngletDef(icone: Icons.how_to_reg_rounded,             label: 'Demandes',  badge: nbDemandesPending,       index: 1),
        _OngletDef(icone: Icons.group_outlined,                 label: 'Tontines',  badge: 0,                      index: 2),
        _OngletDef(icone: Icons.bar_chart_rounded,              label: 'Stats',     badge: 0,                      index: 3),
        _OngletDef(icone: Icons.receipt_long_outlined,          label: 'Dépenses',  badge: nbDepensesPending,       index: 4),
        _OngletDef(icone: Icons.account_balance_outlined,       label: 'Prêts',     badge: nbPretsPending,          index: 5),
        _OngletDef(icone: Icons.account_balance_wallet_rounded, label: 'Décaiss.',  badge: nbDecaissementsPending,  index: 6),
        _OngletDef(icone: Icons.badge_outlined,                 label: 'KYC',       badge: nbKycPending,            index: 7),
        _OngletDef(icone: Icons.groups_outlined,                label: 'Équipe',    badge: 0,                      index: 8),
        _OngletDef(icone: Icons.forum_outlined,                 label: 'Messages',  badge: 0,                      index: 9),
        _OngletDef(icone: Icons.support_agent_outlined,         label: 'Support',   badge: 0,                      index: 10),
      ];
    }

    // ── Bandeau identité rôle (si connecté en tant que membre) ───────────────
    Widget? bandeauRole;
    if (_estMembreRole) {
      final (labelRole, couleurRole) = switch (_roleMembre) {
        'comptable'  => ('Comptable', AppColors.orFonce),
        'conformite' => ('Conformité', AppColors.encre),
        _            => ('Super Admin', AppColors.succes),
      };
      bandeauRole = Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        color: couleurRole.withValues(alpha: 0.10),
        child: Row(
          children: [
            Icon(Icons.verified_user_outlined, size: 14, color: couleurRole),
            const SizedBox(width: 6),
            Text(
              'Connecté : $_nomMembre  •  $labelRole',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: couleurRole),
            ),
            const Spacer(),
            GestureDetector(
              onTap: () => setState(() {
                _connecte       = false;
                _roleMembre     = null;
                _pseudoMembre   = null;
                _clePersoMembre = null;
                _nomMembre      = null;
                _pseudoCtrl.clear();
                _clePersoCtrl.clear();
              }),
              child: Text('Déconnexion', style: TextStyle(fontSize: 11, color: couleurRole, decoration: TextDecoration.underline)),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        // ── Header ──────────────────────────────────────────────────────────
        _HeaderAdmin(
          totalAlertes: totalAlertes,
          recharging: _recharging,
          onRefresh: _rechargerAvecFeedback,
          onBack: () => Navigator.of(context).pop(),
        ),
        if (bandeauRole != null) bandeauRole,
        // ── Barre de navigation icônes ───────────────────────────────────────
        _BarreNavAdmin(
          onglets: onglets,
          ongletActif: _onglet,
          onSelect: (i) => setState(() => _onglet = i),
        ),
        const Divider(height: 1, color: AppColors.lignes),
        // ── Corps de l'onglet ────────────────────────────────────────────────
        Expanded(
          child: _onglet == 0 ? _VueResume(
              nbDemandesPending:      nbDemandesPending,
              nbDepensesPending:      nbDepensesPending,
              nbPretsPending:         nbPretsPending,
              nbDecaissementsPending: nbDecaissementsPending,
              nbKycPending:           nbKycPending,
              onNaviguer: (i) => setState(() => _onglet = i),
            )
            : _onglet == 1 ? _ListeDemandes()
            : _onglet == 2 ? _ListeTontines()
            : _onglet == 3 ? AdminDashboardScreen(cle: _cle)
            : _onglet == 4 ? _ListeDepenses()
            : _onglet == 5 ? _ListePrets()
            : _onglet == 6 ? _ListeDecaissements()
            : _onglet == 7 ? _ListeKyc()
            : _onglet == 8 ? EquipeScreen(
                cle:        _cle,
                roleActuel: _roleMembre ?? 'super_admin',
              )
            : _onglet == 9 ? AdminMessagerieScreen(
                pseudo:   _pseudoMembre   ?? '',
                clePerso: _clePersoMembre ?? '',
                nom:      _nomMembre      ?? (_pseudoMembre ?? 'Admin'),
              )
            : SupportAdminScreen(cle: _cle),
        ),
      ],
    );
  }

  Widget _ListeKyc() {
    final filtered = _filtreKyc == 'tous'
        ? _kycs
        : _kycs.where((k) => (k['statut'] as String? ?? '') == _filtreKyc).toList();

    final nbPending = _kycs.where((k) => k['statut'] == 'pending').length;
    final nbValide  = _kycs.where((k) => k['statut'] == 'valide').length;
    final nbRejete  = _kycs.where((k) => k['statut'] == 'rejete').length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _EnteteListe(
          titre: 'Dossiers KYC',
          sousTitre: 'Vérification identité — tontines Premium ≥ 200 000 XOF',
          icone: Icons.badge_outlined,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _FiltreChip(
                  label: 'En attente ($nbPending)',
                  selected: _filtreKyc == 'pending',
                  onTap: () => setState(() => _filtreKyc = 'pending'),
                  couleur: AppColors.orFonce,
                ),
                const SizedBox(width: 8),
                _FiltreChip(
                  label: 'Validés ($nbValide)',
                  selected: _filtreKyc == 'valide',
                  onTap: () => setState(() => _filtreKyc = 'valide'),
                  couleur: AppColors.succes,
                ),
                const SizedBox(width: 8),
                _FiltreChip(
                  label: 'Rejetés ($nbRejete)',
                  selected: _filtreKyc == 'rejete',
                  onTap: () => setState(() => _filtreKyc = 'rejete'),
                  couleur: AppColors.alerte,
                ),
                const SizedBox(width: 8),
                _FiltreChip(
                  label: 'Tous (${_kycs.length})',
                  selected: _filtreKyc == 'tous',
                  onTap: () => setState(() => _filtreKyc = 'tous'),
                  couleur: AppColors.encreDoux,
                ),
              ],
            ),
          ),
        ),
        if (filtered.isEmpty)
          Expanded(
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.badge_outlined, size: 48,
                      color: AppColors.texteDoux.withValues(alpha: 0.4)),
                  const SizedBox(height: 12),
                  Text(
                    _filtreKyc == 'pending'
                        ? 'Aucun dossier KYC en attente'
                        : 'Aucun dossier KYC dans cette catégorie',
                    style: const TextStyle(color: AppColors.texteDoux, fontSize: 15),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Les tontines Premium avec cagnotte ≥ 200 000 XOF\nsoumettent leurs dossiers ici.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppColors.texteDoux, fontSize: 12),
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
              itemBuilder: (_, i) => _CarteKyc(filtered[i]),
            ),
          ),
      ],
    );
  }

  Widget _CarteKyc(Map<String, dynamic> k) {
    final id          = k['id'] as int? ?? 0;
    final code        = k['code'] as String? ?? '—';
    final gestionnaire = k['gestionnaire'] as String? ?? '—';
    final nom         = k['nom'] as String? ?? '—';
    final pieceType   = k['piece_type'] as String? ?? '—';
    final pieceNumero = k['piece_numero'] as String? ?? '—';
    final statut      = k['statut'] as String? ?? 'pending';
    final motifRejet  = k['motif_rejet'] as String?;
    final soumisLe    = DateTime.tryParse(k['soumis_le'] as String? ?? '');
    final validatedAt = k['validated_at'] != null
        ? DateTime.tryParse(k['validated_at'] as String)
        : null;
    final validePar   = k['valide_par'] as String?;

    // Label de la pièce d'identité
    final pieceLabel = switch (pieceType) {
      'cni'       => 'CNI',
      'passeport' => 'Passeport',
      'sejour'    => 'Titre de séjour',
      _           => pieceType,
    };

    final Color statutCouleur;
    final Color statutFond;
    final String statutLabel;
    switch (statut) {
      case 'valide':
        statutCouleur = AppColors.succes; statutFond = AppColors.succesFond; statutLabel = '✓ Validé'; break;
      case 'rejete':
        statutCouleur = AppColors.alerte; statutFond = AppColors.alerteFond; statutLabel = '✗ Rejeté'; break;
      default:
        statutCouleur = AppColors.orFonce; statutFond = AppColors.fondConsultation; statutLabel = '⏳ En attente';
    }

    return CarteTC(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // En-tête : nom + badge statut
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      nom,
                      style: const TextStyle(
                          fontWeight: FontWeight.w800, fontSize: 15, color: AppColors.encre),
                    ),
                    Text(
                      'Gestionnaire : $gestionnaire · Tontine $code',
                      style: const TextStyle(
                          fontSize: 12, color: AppColors.encreDoux, fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                decoration: BoxDecoration(
                    color: statutFond, borderRadius: BorderRadius.circular(20)),
                child: Text(statutLabel,
                    style: TextStyle(
                        fontSize: 11, fontWeight: FontWeight.w700, color: statutCouleur)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // Bloc pièce d'identité
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
                color: AppColors.fondCode,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.lignes)),
            child: Column(
              children: [
                _InfoLigneAdmin(
                  icone: Icons.badge_outlined,
                  label: 'Type de pièce',
                  valeur: pieceLabel,
                ),
                _InfoLigneAdmin(
                  icone: Icons.numbers_rounded,
                  label: 'Numéro',
                  valeur: pieceNumero,
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          _InfoLigneAdmin(
            icone: Icons.calendar_today_outlined,
            label: 'Soumis le',
            valeur: Formatters.dateFormatee(soumisLe),
          ),
          if (validatedAt != null)
            _InfoLigneAdmin(
              icone: Icons.check_circle_outline,
              label: statut == 'valide' ? 'Validé le' : 'Rejeté le',
              valeur: Formatters.dateFormatee(validatedAt),
            ),
          if (validePar != null && validePar.isNotEmpty)
            _InfoLigneAdmin(
              icone: Icons.manage_accounts_outlined,
              label: 'Par',
              valeur: validePar,
            ),
          if (motifRejet != null && motifRejet.isNotEmpty)
            _InfoLigneAdmin(
              icone: Icons.cancel_outlined,
              label: 'Motif rejet',
              valeur: motifRejet,
            ),
          // Boutons action si pending
          if (statut == 'pending') ...[
            const SizedBox(height: 12),
            const Divider(color: AppColors.lignes, height: 1),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: BtnPrincipal(
                    label: 'Valider le KYC',
                    icone: Icons.verified_user_rounded,
                    couleur: AppColors.succes,
                    onTap: () => _validerKyc(id, code, gestionnaire),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: BtnSecondaire(
                    label: 'Rejeter',
                    onTap: () => _rejeterKyc(id, code, gestionnaire),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  // ── Onglet 💰 Décaissements pending ─────────────────────────────────────────
  Future<void> _validerDecaissement(
      int id, String code, String benefNom, int montantNet, String devise) async {
    final confirmer = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.fondPapier,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Valider le décaissement',
            style: TextStyle(fontWeight: FontWeight.w700, color: AppColors.encre)),
        content: Text(
          'Confirmer le décaissement ?\n'
          'La caisse de $code sera débitée de ${Formatters.montant(montantNet, devise: devise)} pour $benefNom.',
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

    final result = await SupabaseService.adminValiderDecaissement(cle: _cle, id: id);
    if (!mounted) return;
    if (result['ok'] == true) {
      afficherToast(context, '✅ Décaissement validé — caisse débitée !');
      SupabaseService.envoyerNotification(
        code:    code,
        type:    'decaissement',
        titre:   '💰 Décaissement approuvé',
        message: '${Formatters.montant(montantNet, devise: devise)} décaissé pour $benefNom.',
      );
      await _recharger();
    } else {
      afficherToast(context, result['erreur'] as String? ?? 'Erreur validation.', estErreur: true);
    }
  }

  Future<void> _rejeterDecaissement(int id, String code, String benefNom) async {
    final motifCtrl = TextEditingController();
    String? motifErreur;

    final motif = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (sCtx, setSt) => AlertDialog(
          backgroundColor: AppColors.fondPapier,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('Rejeter le décaissement',
              style: TextStyle(fontWeight: FontWeight.w700, color: AppColors.alerte)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Décaissement pour $benefNom (tontine $code)'),
              const SizedBox(height: 10),
              const Text('Motif de refus :'),
              const SizedBox(height: 8),
              TextField(
                controller: motifCtrl,
                maxLines: 2,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  hintText: 'Ex : Numéro incorrect, solde insuffisant...',
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
                if (t.length < 3) { setSt(() => motifErreur = 'Motif requis.'); return; }
                Navigator.pop(ctx, t);
              },
              child: const Text('Rejeter', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
            ),
          ],
        ),
      ),
    );
    if (motif == null || !mounted) return;

    final result = await SupabaseService.adminRejeterDecaissement(cle: _cle, id: id, motif: motif);
    if (!mounted) return;
    if (result['ok'] == true) {
      afficherToast(context, 'Décaissement rejeté.');
      SupabaseService.envoyerNotification(
        code:    code,
        type:    'decaissement',
        titre:   '❌ Décaissement refusé',
        message: 'Le décaissement pour $benefNom a été refusé. Motif : $motif',
      );
      await _recharger();
    } else {
      afficherToast(context, result['erreur'] as String? ?? 'Erreur rejet.', estErreur: true);
    }
  }

  // ── Vue Résumé / Accueil (onglet 0) ────────────────────────────────────────
  Widget _VueResume({
    required int nbDemandesPending,
    required int nbDepensesPending,
    required int nbPretsPending,
    required int nbDecaissementsPending,
    required int nbKycPending,
    required void Function(int) onNaviguer,
  }) {
    final now = DateTime.now();
    final nbActives = _tontines.where((t) => (t['status'] as String? ?? 'active') == 'active').length;
    final nbPremium = _tontines.where((t) => (t['plan'] as String? ?? '') == 'premium').length;
    final totalAlertes = nbDemandesPending + nbDepensesPending + nbPretsPending +
        nbDecaissementsPending + nbKycPending;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        // ── Bloc alertes ───────────────────────────────────────────────────
        if (totalAlertes > 0)
          _BlocAlertes(
            nbDemandesPending:      nbDemandesPending,
            nbDepensesPending:      nbDepensesPending,
            nbPretsPending:         nbPretsPending,
            nbDecaissementsPending: nbDecaissementsPending,
            nbKycPending:           nbKycPending,
            onNaviguer:             onNaviguer,
          )
        else
          _BlocInfo(
            icone:   Icons.check_circle_rounded,
            couleur: AppColors.succes,
            titre:   'Tout est à jour',
            message: 'Aucune action en attente de validation.',
          ),
        const SizedBox(height: 20),

        // ── Stats rapides ──────────────────────────────────────────────────
        const Text('Vue d\'ensemble',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15, color: AppColors.encre)),
        const SizedBox(height: 10),
        GridView.count(
          crossAxisCount: 2,
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          childAspectRatio: 2.6,
          children: [
            _StatCarteAdmin(icone: Icons.group_outlined,          label: 'Tontines actives', valeur: '$nbActives',        couleur: AppColors.succes),
            _StatCarteAdmin(icone: Icons.workspace_premium_rounded,label: 'Premium',          valeur: '$nbPremium',        couleur: AppColors.orFonce),
            _StatCarteAdmin(icone: Icons.how_to_reg_rounded,      label: 'Demandes total',   valeur: '${_demandes.length}', couleur: AppColors.encreDoux),
            _StatCarteAdmin(icone: Icons.receipt_long_outlined,   label: 'Dépenses total',   valeur: '${_depenses.length}', couleur: AppColors.encreDoux),
          ],
        ),
        const SizedBox(height: 20),

        // ── Raccourcis ─────────────────────────────────────────────────────
        const Text('Accès rapide',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15, color: AppColors.encre)),
        const SizedBox(height: 10),
        _RaccourciAdmin(icone: Icons.how_to_reg_rounded,             label: 'Demandes d\'activation',      sousTitre: '${_demandes.length} demande${_demandes.length > 1 ? "s" : ""}', badge: nbDemandesPending,      onTap: () => onNaviguer(1)),
        const SizedBox(height: 6),
        _RaccourciAdmin(icone: Icons.group_outlined,                 label: 'Gérer les tontines',           sousTitre: '$nbActives active${nbActives > 1 ? "s" : ""}',                  badge: 0,                     onTap: () => onNaviguer(2)),
        const SizedBox(height: 6),
        _RaccourciAdmin(icone: Icons.receipt_long_outlined,          label: 'Dépenses en attente',         sousTitre: '$nbDepensesPending en attente · ${_depenses.length} total',      badge: nbDepensesPending,     onTap: () => onNaviguer(4)),
        const SizedBox(height: 6),
        _RaccourciAdmin(icone: Icons.account_balance_outlined,       label: 'Prêts en attente',            sousTitre: '$nbPretsPending en attente · ${_prets.length} total',            badge: nbPretsPending,        onTap: () => onNaviguer(5)),
        const SizedBox(height: 6),
        _RaccourciAdmin(icone: Icons.account_balance_wallet_rounded, label: 'Décaissements en attente',    sousTitre: '$nbDecaissementsPending en attente · ${_decaissements.length} total', badge: nbDecaissementsPending, onTap: () => onNaviguer(6)),
        const SizedBox(height: 6),
        _RaccourciAdmin(icone: Icons.badge_outlined,                 label: 'Dossiers KYC',                sousTitre: '$nbKycPending en attente · ${_kycs.length} total',               badge: nbKycPending,          onTap: () => onNaviguer(7)),
        const SizedBox(height: 6),
        _RaccourciAdmin(icone: Icons.bar_chart_rounded,              label: 'Tableau de bord analytics',  sousTitre: 'Statistiques et métriques globales',                              badge: 0,                     onTap: () => onNaviguer(3)),
        const SizedBox(height: 24),

        // ── Pied de page ───────────────────────────────────────────────────
        Center(
          child: Text(
            'TontineClair · Admin · ${now.day.toString().padLeft(2,'0')}/${now.month.toString().padLeft(2,'0')}/${now.year}',
            style: const TextStyle(fontSize: 11, color: AppColors.texteDoux),
          ),
        ),
      ],
    );
  }

  // ── Onglet 🪪 KYC ──────────────────────────────────────────────────────────
  Future<void> _validerKyc(int id, String code, String gestNom) async {
    final confirmer = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.fondPapier,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          'Valider le KYC',
          style: TextStyle(fontWeight: FontWeight.w700, color: AppColors.succes),
        ),
        content: Text(
          'Confirmer la validation du dossier KYC de $gestNom (tontine $code) ?\n\n'
          'Le statut KYC sera mis à «\u202fvalide\u202f» et la tontine pourra opérer normalement.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.succes),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Valider KYC', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    if (confirmer != true || !mounted) return;

    final result = await SupabaseService.adminValiderKyc(cle: _cle, id: id);
    if (!mounted) return;
    if (result['ok'] == true) {
      afficherToast(context, '✅ KYC validé pour $gestNom !');
      SupabaseService.envoyerNotification(
        code:    code,
        type:    'kyc',
        titre:   '🪪 KYC approuvé',
        message: 'Votre dossier KYC a été validé. Votre tontine peut opérer normalement.',
      );
      await _recharger();
    } else {
      afficherToast(context, result['erreur'] as String? ?? 'Erreur validation KYC.', estErreur: true);
    }
  }

  Future<void> _rejeterKyc(int id, String code, String gestNom) async {
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
            'Rejeter le dossier KYC',
            style: TextStyle(fontWeight: FontWeight.w700, color: AppColors.alerte),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Gestionnaire : $gestNom (tontine $code)'),
              const SizedBox(height: 10),
              const Text('Motif du rejet :'),
              const SizedBox(height: 8),
              TextField(
                controller: motifCtrl,
                maxLines: 2,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  hintText: 'Ex : Document illisible, pièce expirée...',
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
                if (t.length < 3) { setSt(() => motifErreur = 'Motif requis.'); return; }
                Navigator.pop(ctx, t);
              },
              child: const Text('Rejeter', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
            ),
          ],
        ),
      ),
    );
    if (motif == null || !mounted) return;

    final result = await SupabaseService.adminRejeterKyc(cle: _cle, id: id, motif: motif);
    if (!mounted) return;
    if (result['ok'] == true) {
      afficherToast(context, 'Dossier KYC rejeté.');
      SupabaseService.envoyerNotification(
        code:    code,
        type:    'kyc',
        titre:   '❌ KYC refusé',
        message: 'Votre dossier KYC a été refusé. Motif : $motif. Veuillez soumettre un nouveau dossier.',
      );
      await _recharger();
    } else {
      afficherToast(context, result['erreur'] as String? ?? 'Erreur rejet KYC.', estErreur: true);
    }
  }

  Widget _ListeDecaissements() {
    final filtered = _filtreDecaissement == 'tous'
        ? _decaissements
        : _decaissements.where((d) => (d['statut'] as String? ?? '') == _filtreDecaissement).toList();

    final nbPending = _decaissements.where((d) => d['statut'] == 'pending').length;
    final nbValidee = _decaissements.where((d) => d['statut'] == 'validee').length;
    final nbRejetee = _decaissements.where((d) => d['statut'] == 'rejetee').length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _EnteteListe(
          titre: 'Décaissements',
          sousTitre: 'Clôture tour Premium — Mobile Money',
          icone: Icons.account_balance_wallet_rounded,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _FiltreChip(label: 'En attente ($nbPending)', selected: _filtreDecaissement == 'pending',
                    onTap: () => setState(() => _filtreDecaissement = 'pending'), couleur: AppColors.orFonce),
                const SizedBox(width: 8),
                _FiltreChip(label: 'Validés ($nbValidee)', selected: _filtreDecaissement == 'validee',
                    onTap: () => setState(() => _filtreDecaissement = 'validee'), couleur: AppColors.succes),
                const SizedBox(width: 8),
                _FiltreChip(label: 'Rejetés ($nbRejetee)', selected: _filtreDecaissement == 'rejetee',
                    onTap: () => setState(() => _filtreDecaissement = 'rejetee'), couleur: AppColors.alerte),
                const SizedBox(width: 8),
                _FiltreChip(label: 'Tous (${_decaissements.length})', selected: _filtreDecaissement == 'tous',
                    onTap: () => setState(() => _filtreDecaissement = 'tous'), couleur: AppColors.encreDoux),
              ],
            ),
          ),
        ),
        if (filtered.isEmpty)
          Expanded(
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.account_balance_wallet_outlined, size: 48,
                      color: AppColors.texteDoux.withValues(alpha: 0.4)),
                  const SizedBox(height: 12),
                  Text(
                    _filtreDecaissement == 'pending'
                        ? 'Aucun décaissement en attente'
                        : 'Aucun décaissement dans cette catégorie',
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
              itemBuilder: (_, i) => _CarteDecaissement(filtered[i]),
            ),
          ),
      ],
    );
  }

  Widget _CarteDecaissement(Map<String, dynamic> d) {
    final id           = d['id'] as int? ?? 0;
    final code         = d['code'] as String? ?? '—';
    final benefNom     = d['beneficiaire_nom'] as String? ?? '—';
    final montant      = d['montant'] as int? ?? 0;
    final commission   = d['commission'] as int? ?? 0;
    final montantNet   = d['montant_net'] as int? ?? 0;
    final numerTour    = d['numer_tour'] as int? ?? 0;
    final operateur    = d['operateur'] as String? ?? '—';
    final numBenef     = d['numero_beneficiaire'] as String? ?? '—';
    final gestionnaire = d['gestionnaire'] as String? ?? '—';
    final devise       = d['devise'] as String? ?? 'XOF';
    final statut       = d['statut'] as String? ?? 'pending';
    final motifRejet   = d['motif_rejet'] as String?;
    final createdAt    = DateTime.tryParse(d['created_at'] as String? ?? '');
    final validatedAt  = d['validated_at'] != null ? DateTime.tryParse(d['validated_at'] as String) : null;

    final Color statutCouleur;
    final Color statutFond;
    final String statutLabel;
    switch (statut) {
      case 'validee':
        statutCouleur = AppColors.succes; statutFond = AppColors.succesFond; statutLabel = '✓ Validé'; break;
      case 'rejetee':
        statutCouleur = AppColors.alerte; statutFond = AppColors.alerteFond; statutLabel = '✗ Rejeté'; break;
      default:
        statutCouleur = AppColors.orFonce; statutFond = AppColors.fondConsultation; statutLabel = '⏳ En attente';
    }

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
                    Text(benefNom,
                        style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15, color: AppColors.encre)),
                    Text('Tour $numerTour · Tontine $code',
                        style: const TextStyle(fontSize: 12, fontFamily: 'monospace', color: AppColors.encreDoux, fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                decoration: BoxDecoration(color: statutFond, borderRadius: BorderRadius.circular(20)),
                child: Text(statutLabel,
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: statutCouleur)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // Montants
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
                color: AppColors.fondCode,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.lignes)),
            child: Column(
              children: [
                _InfoLigneAdmin(icone: Icons.monetization_on_outlined, label: 'Montant versé',
                    valeur: Formatters.montant(montant, devise: devise)),
                _InfoLigneAdmin(icone: Icons.percent_rounded, label: 'Commission (1%)',
                    valeur: '− ${Formatters.montant(commission, devise: devise)}'),
                _InfoLigneAdmin(icone: Icons.account_balance_wallet_rounded, label: 'Net à décaisser',
                    valeur: Formatters.montant(montantNet, devise: devise)),
              ],
            ),
          ),
          const SizedBox(height: 8),
          _InfoLigneAdmin(icone: Icons.phone_android_rounded, label: 'Opérateur',
              valeur: operateur.isNotEmpty ? (operateur[0].toUpperCase() + operateur.substring(1)) : '—'),
          _InfoLigneAdmin(icone: Icons.phone_outlined, label: 'Numéro bénéficiaire', valeur: numBenef),
          _InfoLigneAdmin(icone: Icons.manage_accounts_outlined, label: 'Gestionnaire', valeur: gestionnaire),
          _InfoLigneAdmin(icone: Icons.calendar_today_outlined, label: 'Soumis le',
              valeur: Formatters.dateFormatee(createdAt)),
          if (validatedAt != null)
            _InfoLigneAdmin(
              icone: Icons.check_circle_outline,
              label: statut == 'validee' ? 'Validé le' : 'Rejeté le',
              valeur: Formatters.dateFormatee(validatedAt),
            ),
          if (motifRejet != null && motifRejet.isNotEmpty)
            _InfoLigneAdmin(icone: Icons.cancel_outlined, label: 'Motif rejet', valeur: motifRejet),
          if (statut == 'pending') ...[
            const SizedBox(height: 12),
            const Divider(color: AppColors.lignes, height: 1),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: BtnPrincipal(
                    label: 'Valider — débiter caisse',
                    icone: Icons.check_circle_rounded,
                    couleur: AppColors.succes,
                    onTap: () => _validerDecaissement(id, code, benefNom, montantNet, devise),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: BtnSecondaire(
                    label: 'Rejeter',
                    onTap: () => _rejeterDecaissement(id, code, benefNom),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  // ── Onglet 🏦 Prêts pending ──────────────────────────────────────────────────
  Widget _ListePrets() {
    final filtered = _filtrePret == 'tous'
        ? _prets
        : _prets.where((p) => (p['statut'] as String? ?? '') == _filtrePret).toList();

    final nbPending = _prets.where((p) => p['statut'] == 'pending').length;
    final nbValidee = _prets.where((p) => p['statut'] == 'validee').length;
    final nbRejetee = _prets.where((p) => p['statut'] == 'rejetee').length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _EnteteListe(
          titre: 'Prêts',
          sousTitre: 'Demandes de prêt en attente de validation',
          icone: Icons.account_balance_outlined,
        ),
        // ── Filtres ────────────────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _FiltreChip(
                  label: 'En attente ($nbPending)',
                  selected: _filtrePret == 'pending',
                  onTap: () => setState(() => _filtrePret = 'pending'),
                  couleur: AppColors.orFonce,
                ),
                const SizedBox(width: 8),
                _FiltreChip(
                  label: 'Validés ($nbValidee)',
                  selected: _filtrePret == 'validee',
                  onTap: () => setState(() => _filtrePret = 'validee'),
                  couleur: AppColors.succes,
                ),
                const SizedBox(width: 8),
                _FiltreChip(
                  label: 'Rejetés ($nbRejetee)',
                  selected: _filtrePret == 'rejetee',
                  onTap: () => setState(() => _filtrePret = 'rejetee'),
                  couleur: AppColors.alerte,
                ),
                const SizedBox(width: 8),
                _FiltreChip(
                  label: 'Tous (${_prets.length})',
                  selected: _filtrePret == 'tous',
                  onTap: () => setState(() => _filtrePret = 'tous'),
                  couleur: AppColors.encreDoux,
                ),
              ],
            ),
          ),
        ),
        if (filtered.isEmpty)
          Expanded(
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.account_balance_outlined, size: 48, color: AppColors.texteDoux.withValues(alpha: 0.4)),
                  const SizedBox(height: 12),
                  Text(
                    _filtrePret == 'pending' ? 'Aucun prêt en attente' : 'Aucun prêt dans cette catégorie',
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
              itemBuilder: (_, i) => _CartePret(filtered[i]),
            ),
          ),
      ],
    );
  }

  Widget _CartePret(Map<String, dynamic> p) {
    final id              = p['id'] as int? ?? 0;
    final code            = p['code'] as String? ?? '—';
    final emprunteur      = p['emprunteur_nom'] as String? ?? '—';
    final montant         = p['montant'] as int? ?? 0;
    final frais           = p['frais_transaction'] as int? ?? 0;
    final montantNet      = p['montant_net'] as int? ?? 0;
    final taux            = p['taux'];
    final durees          = p['durees_mois'] as int? ?? 0;
    final operateur       = p['operateur'] as String? ?? '—';
    final numBenef        = p['numero_beneficiaire'] as String? ?? '—';
    final nomBenef        = p['nom_beneficiaire'] as String? ?? '—';
    final gestionnaire    = p['gestionnaire'] as String? ?? '—';
    final devise          = p['devise'] as String? ?? 'XOF';
    final statut          = p['statut'] as String? ?? 'pending';
    final motifRejet      = p['motif_rejet'] as String?;
    final createdAt       = DateTime.tryParse(p['created_at'] as String? ?? '');
    final validatedAt     = p['validated_at'] != null ? DateTime.tryParse(p['validated_at'] as String) : null;

    final Color statutCouleur;
    final Color statutFond;
    final String statutLabel;
    switch (statut) {
      case 'validee':
        statutCouleur = AppColors.succes;
        statutFond    = AppColors.succesFond;
        statutLabel   = '✓ Validé';
        break;
      case 'rejetee':
        statutCouleur = AppColors.alerte;
        statutFond    = AppColors.alerteFond;
        statutLabel   = '✗ Rejeté';
        break;
      default:
        statutCouleur = AppColors.orFonce;
        statutFond    = AppColors.fondConsultation;
        statutLabel   = '⏳ En attente';
    }

    return CarteTC(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── En-tête ───────────────────────────────────────────────────────
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      emprunteur,
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                        color: AppColors.encre,
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
          // ── Montants ─────────────────────────────────────────────────────
          _InfoLigneAdmin(
            icone: Icons.monetization_on_outlined,
            label: 'Montant brut',
            valeur: Formatters.montant(montant, devise: devise),
          ),
          _InfoLigneAdmin(
            icone: Icons.percent_rounded,
            label: 'Frais (2%)',
            valeur: Formatters.montant(frais, devise: devise),
          ),
          _InfoLigneAdmin(
            icone: Icons.account_balance_wallet_outlined,
            label: 'Montant net',
            valeur: Formatters.montant(montantNet, devise: devise),
          ),
          _InfoLigneAdmin(
            icone: Icons.trending_up_rounded,
            label: 'Taux / Durée',
            valeur: '${taux ?? 5} % · $durees mois',
          ),
          // ── Mobile Money ─────────────────────────────────────────────────
          _InfoLigneAdmin(
            icone: Icons.phone_android_rounded,
            label: 'Opérateur',
            valeur: operateur.isNotEmpty ? (operateur[0].toUpperCase() + operateur.substring(1)) : '—',
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
          if (validatedAt != null)
            _InfoLigneAdmin(
              icone: Icons.check_circle_outline,
              label: statut == 'validee' ? 'Validé le' : 'Rejeté le',
              valeur: Formatters.dateFormatee(validatedAt),
            ),
          if (motifRejet != null && motifRejet.isNotEmpty)
            _InfoLigneAdmin(
              icone: Icons.cancel_outlined,
              label: 'Motif rejet',
              valeur: motifRejet,
            ),
          // ── Boutons d'action (seulement si pending) ───────────────────────
          if (statut == 'pending') ...[
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
                    onTap: () => _validerPret(id, code, montantNet, devise),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: BtnSecondaire(
                    label: 'Rejeter',
                    onTap: () => _rejeterPret(id),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
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
        _EnteteListe(
          titre: 'Demandes d\'adhésion',
          sousTitre: 'Validation des demandes membres en attente',
          icone: Icons.person_add_outlined,
        ),
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
        _EnteteListe(
          titre: 'Dépenses',
          sousTitre: 'Dépenses Mobile Money en attente de validation',
          icone: Icons.receipt_long_outlined,
        ),
        // ── Filtres ────────────────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
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
    String categorie(Map<String, dynamic> t) {
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
        : _tontines.where((t) => categorie(t) != 'deleted').length;
    final int nbActives    = rpcFiable
        ? ((_counts['actives']    ?? 0) as num).toInt()
        : _tontines.where((t) => categorie(t) == 'gratuit' || categorie(t) == 'premium').length;
    final int nbPremium    = rpcFiable
        ? ((_counts['premium']    ?? 0) as num).toInt()
        : _tontines.where((t) => categorie(t) == 'premium').length;
    final int nbGratuites  = rpcFiable
        ? ((_counts['gratuites']  ?? 0) as num).toInt()
        : _tontines.where((t) => categorie(t) == 'gratuit').length;
    final int nbExpirees   = rpcFiable
        ? ((_counts['expirees']   ?? 0) as num).toInt()
        : _tontines.where((t) => categorie(t) == 'expire').length;
    final int nbSuspendues = rpcFiable
        ? ((_counts['suspendues'] ?? 0) as num).toInt()
        : _tontines.where((t) => categorie(t) == 'suspended').length;
    final int nbInactives  = rpcFiable
        ? ((_counts['inactives']  ?? 0) as num).toInt()
        : _tontines.where((t) => categorie(t) == 'inactive').length;
    final int nbSupprimees = rpcFiable
        ? ((_counts['supprimees'] ?? 0) as num).toInt()
        : _tontines.where((t) => categorie(t) == 'deleted').length;

    // ── Filtrage de la liste affichée ────────────────────────────────────────
    final tontinesFiltrees = _filtreStatut == null
        ? _tontines // Toutes (y compris supprimées pour la vue admin)
        : _tontines.where((t) {
            if (_filtreStatut == 'premium')  return categorie(t) == 'premium';
            if (_filtreStatut == 'gratuit')  return categorie(t) == 'gratuit';
            if (_filtreStatut == 'expire')   return categorie(t) == 'expire';
            return (t['status'] as String? ?? 'active') == _filtreStatut;
          }).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _EnteteListe(
          titre: 'Tontines',
          sousTitre: 'Toutes les tontines — gestion Premium & activation',
          icone: Icons.groups_2_outlined,
        ),
        // ── Résumé statistiques ─────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
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
                      if (isExpire) ...[
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

// ─── Données onglet ────────────────────────────────────────────────────────────
class _OngletDef {
  final IconData icone;
  final String label;
  final int badge;
  /// Index réel de l'onglet dans la hiérarchie globale (0-10).
  /// Permet au rôle-based filtering de ne montrer qu'un sous-ensemble d'onglets
  /// tout en continuant d'utiliser les mêmes indices de contenu.
  final int index;
  const _OngletDef({required this.icone, required this.label, required this.badge, required this.index});
}

// ─── Donnée alerte résumé ──────────────────────────────────────────────────────
class _AlerteItem {
  final String label;
  final IconData icone;
  final Color couleur;
  final int onglet;
  const _AlerteItem({required this.label, required this.icone, required this.couleur, required this.onglet});
}

// ─── Header admin ──────────────────────────────────────────────────────────────
class _HeaderAdmin extends StatelessWidget {
  final int totalAlertes;
  final bool recharging;
  final VoidCallback onRefresh;
  final VoidCallback onBack;
  const _HeaderAdmin({
    required this.totalAlertes,
    required this.recharging,
    required this.onRefresh,
    required this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 10),
      decoration: const BoxDecoration(
        color: AppColors.fondPapier,
        border: Border(bottom: BorderSide(color: AppColors.lignes, width: 0.5)),
      ),
      child: Row(
        children: [
          // Icône admin + titre
          Container(
            width: 36, height: 36,
            decoration: BoxDecoration(
              color: AppColors.encre,
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.admin_panel_settings_rounded, color: Colors.white, size: 20),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Espace Admin',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15, color: AppColors.encre),
                ),
                Text(
                  totalAlertes > 0
                      ? '$totalAlertes action${totalAlertes > 1 ? "s" : ""} en attente'
                      : 'Tout est à jour',
                  style: TextStyle(
                    fontSize: 11,
                    color: totalAlertes > 0 ? AppColors.alerte : AppColors.succes,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          // Badge total alertes
          if (totalAlertes > 0)
            Container(
              margin: const EdgeInsets.only(right: 8),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: AppColors.alerteFond,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: AppColors.alerte.withValues(alpha: 0.3)),
              ),
              child: Text(
                '$totalAlertes',
                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: AppColors.alerte),
              ),
            ),
          // Bouton refresh
          IconButton(
            onPressed: onRefresh,
            icon: recharging
                ? const SizedBox(
                    width: 18, height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.encreDoux),
                  )
                : const Icon(Icons.refresh_rounded, color: AppColors.encreDoux, size: 22),
            tooltip: 'Actualiser',
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            padding: EdgeInsets.zero,
          ),
          // Bouton retour
          IconButton(
            onPressed: onBack,
            icon: const Icon(Icons.close_rounded, color: AppColors.texteDoux, size: 20),
            tooltip: 'Quitter',
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            padding: EdgeInsets.zero,
          ),
        ],
      ),
    );
  }
}

// ─── Barre navigation icônes ───────────────────────────────────────────────────
class _BarreNavAdmin extends StatelessWidget {
  final List<_OngletDef> onglets;
  final int ongletActif;
  final void Function(int) onSelect;
  const _BarreNavAdmin({required this.onglets, required this.ongletActif, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.fondPapier,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: List.generate(onglets.length, (i) {
            final o = onglets[i];
            // Utilise o.index (index réel) pour comparer et naviguer
            final selected = ongletActif == o.index;
            return Padding(
              padding: const EdgeInsets.only(right: 6),
              child: GestureDetector(
                onTap: () => onSelect(o.index),
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                      decoration: BoxDecoration(
                        color: selected ? AppColors.encre : AppColors.fondCode,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(o.icone, size: 15,
                              color: selected ? Colors.white : AppColors.encreDoux),
                          const SizedBox(width: 5),
                          Text(
                            o.label,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: selected ? Colors.white : AppColors.encre,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (o.badge > 0)
                      Positioned(
                        top: -5,
                        right: -5,
                        child: Container(
                          width: 18, height: 18,
                          alignment: Alignment.center,
                          decoration: const BoxDecoration(color: AppColors.alerte, shape: BoxShape.circle),
                          child: Text(
                            o.badge > 9 ? '9+' : '${o.badge}',
                            style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w900, color: Colors.white),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            );
          }),
        ),
      ),
    );
  }
}

// ─── Bloc alertes résumé ───────────────────────────────────────────────────────
class _BlocAlertes extends StatelessWidget {
  final int nbDemandesPending, nbDepensesPending, nbPretsPending, nbDecaissementsPending, nbKycPending;
  final void Function(int) onNaviguer;
  const _BlocAlertes({
    required this.nbDemandesPending,
    required this.nbDepensesPending,
    required this.nbPretsPending,
    required this.nbDecaissementsPending,
    required this.nbKycPending,
    required this.onNaviguer,
  });

  @override
  Widget build(BuildContext context) {
    final items = <_AlerteItem>[
      if (nbDemandesPending > 0)      _AlerteItem(label: '$nbDemandesPending demande${nbDemandesPending>1?"s":""} d\'activation',    icone: Icons.how_to_reg_rounded,             couleur: AppColors.orFonce, onglet: 1),
      if (nbDepensesPending > 0)      _AlerteItem(label: '$nbDepensesPending dépense${nbDepensesPending>1?"s":""} en attente',         icone: Icons.receipt_long_outlined,          couleur: AppColors.alerte,  onglet: 4),
      if (nbPretsPending > 0)         _AlerteItem(label: '$nbPretsPending prêt${nbPretsPending>1?"s":""} en attente',                  icone: Icons.account_balance_outlined,       couleur: AppColors.alerte,  onglet: 5),
      if (nbDecaissementsPending > 0) _AlerteItem(label: '$nbDecaissementsPending décaissement${nbDecaissementsPending>1?"s":""} en attente', icone: Icons.account_balance_wallet_rounded, couleur: AppColors.alerte, onglet: 6),
      if (nbKycPending > 0)           _AlerteItem(label: '$nbKycPending dossier${nbKycPending>1?"s":""} KYC en attente',              icone: Icons.badge_outlined,                 couleur: AppColors.alerte,  onglet: 7),
    ];
    final total = items.length;
    return Container(
      decoration: BoxDecoration(
        color: AppColors.alerteFond,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.alerte.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
            child: Row(
              children: [
                const Icon(Icons.notifications_active_rounded, size: 15, color: AppColors.alerte),
                const SizedBox(width: 8),
                Text(
                  '$total action${total > 1 ? "s" : ""} requise${total > 1 ? "s" : ""}',
                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13, color: AppColors.alerte),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: AppColors.lignes),
          ...items.map((item) => InkWell(
            onTap: () => onNaviguer(item.onglet),
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                children: [
                  Container(
                    width: 30, height: 30,
                    decoration: BoxDecoration(
                      color: item.couleur.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(item.icone, size: 15, color: item.couleur),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(item.label,
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.encre)),
                  ),
                  const Icon(Icons.chevron_right_rounded, size: 17, color: AppColors.texteDoux),
                ],
              ),
            ),
          )),
        ],
      ),
    );
  }
}

// ─── Bloc info (état vide positif) ────────────────────────────────────────────
class _BlocInfo extends StatelessWidget {
  final IconData icone;
  final Color couleur;
  final String titre;
  final String message;
  const _BlocInfo({required this.icone, required this.couleur, required this.titre, required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: couleur.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: couleur.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          Icon(icone, color: couleur, size: 28),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(titre, style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13.5, color: couleur)),
                const SizedBox(height: 2),
                Text(message, style: const TextStyle(fontSize: 12, color: AppColors.texteDoux)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Carte statistique accueil ─────────────────────────────────────────────────
class _StatCarteAdmin extends StatelessWidget {
  final IconData icone;
  final String label;
  final String valeur;
  final Color couleur;
  const _StatCarteAdmin({required this.icone, required this.label, required this.valeur, required this.couleur});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: couleur.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: couleur.withValues(alpha: 0.18)),
      ),
      child: Row(
        children: [
          Icon(icone, size: 18, color: couleur),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(valeur, style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18, color: couleur)),
                Text(label, style: const TextStyle(fontSize: 10, color: AppColors.texteDoux, fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Raccourci d'accès rapide ──────────────────────────────────────────────────
class _RaccourciAdmin extends StatelessWidget {
  final IconData icone;
  final String label;
  final String sousTitre;
  final int badge;
  final VoidCallback onTap;
  const _RaccourciAdmin({
    required this.icone,
    required this.label,
    required this.sousTitre,
    required this.badge,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.lignes),
        ),
        child: Row(
          children: [
            Container(
              width: 36, height: 36,
              decoration: BoxDecoration(
                color: AppColors.fondCode,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icone, size: 18, color: AppColors.encreDoux),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: AppColors.encre)),
                  Text(sousTitre, style: const TextStyle(fontSize: 11, color: AppColors.texteDoux)),
                ],
              ),
            ),
            if (badge > 0)
              Container(
                margin: const EdgeInsets.only(right: 6),
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: AppColors.alerte,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text('$badge', style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: Colors.white)),
              ),
            const Icon(Icons.chevron_right_rounded, size: 18, color: AppColors.texteDoux),
          ],
        ),
      ),
    );
  }
}

// ─── En-tête de section liste ──────────────────────────────────────────────────
class _EnteteListe extends StatelessWidget {
  final String titre;
  final String sousTitre;
  final IconData icone;
  const _EnteteListe({required this.titre, required this.sousTitre, required this.icone});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
      child: Row(
        children: [
          Container(
            width: 34, height: 34,
            decoration: BoxDecoration(
              color: AppColors.fondCode,
              borderRadius: BorderRadius.circular(9),
              border: Border.all(color: AppColors.lignes),
            ),
            child: Icon(icone, size: 17, color: AppColors.encreDoux),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(titre, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14.5, color: AppColors.encre)),
                Text(sousTitre, style: const TextStyle(fontSize: 11, color: AppColors.texteDoux)),
              ],
            ),
          ),
        ],
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
