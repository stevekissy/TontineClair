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

// ─────────────────────────────────────────────────────────────────────────────
// Écran principal Espace Admin — Redesign v2
// Onglets : Dashboard (activité) | Tontines (gestion) | Équipe & Support
// Supprimé : validation manuelle prêts, décaissements, KYC, dépenses
// (paiements automatiques via SycaPay)
// ─────────────────────────────────────────────────────────────────────────────

class AdminScreen extends StatefulWidget {
  const AdminScreen({super.key});

  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends State<AdminScreen> {
  final _cleCtrl     = TextEditingController();
  final _pseudoCtrl  = TextEditingController();
  final _clePersoCtrl = TextEditingController();

  bool _connecte     = false;
  bool _loading      = false;
  String? _erreur;

  // Données essentielles
  List<Map<String, dynamic>> _tontines  = [];
  List<Map<String, dynamic>> _demandes  = [];
  Map<String, dynamic>       _counts    = {};

  // Onglet actif : 0=Dashboard, 1=Tontines, 2=Équipe, 3=Messagerie, 4=Support
  int _onglet = 0;

  // Filtre tontines
  String? _filtreStatut;

  // Loading état boutons blocage (clé = code tontine)
  final Map<String, bool> _blocageLoading = {};

  // Auth membre
  String? _pseudoMembre;
  String? _clePersoMembre;
  String? _roleMembre;
  String? _nomMembre;
  bool get _estMembreRole => _roleMembre != null;
  bool _loginMembreMode = false;

  // Rechargement en cours
  bool _recharging = false;

  String get _cle          => _cleCtrl.text.trim();
  String get _cleEffective => _estMembreRole ? (_clePersoMembre ?? '') : _cle;

  @override
  void dispose() {
    _cleCtrl.dispose();
    _pseudoCtrl.dispose();
    _clePersoCtrl.dispose();
    super.dispose();
  }

  // ── Connexion super-admin ────────────────────────────────────────────────────
  Future<void> _connecter() async {
    final cle = _cleCtrl.text.trim();
    if (cle.isEmpty) return;
    setState(() { _loading = true; _erreur = null; });

    final cleValide = await SupabaseService.verifierCleAdmin(cle);
    if (!cleValide) {
      setState(() { _loading = false; _erreur = 'Clé administrateur incorrecte.'; });
      return;
    }

    List<Map<String, dynamic>> tontines = [];
    List<Map<String, dynamic>> demandes = [];
    Map<String, dynamic>       counts   = {};

    try { tontines = await SupabaseService.adminListerTontines(cle); } catch (_) {}
    try { demandes = await SupabaseService.adminListerDemandes(cle); } catch (_) {}
    try { counts   = await SupabaseService.adminTontineCounts(cle);  } catch (_) {}

    setState(() {
      _connecte = true;
      _loading  = false;
      _tontines = tontines;
      _demandes = demandes;
      _counts   = counts;
    });
  }

  // ── Connexion membre (role-based) ────────────────────────────────────────────
  Future<void> _connecterMembre() async {
    final pseudo   = _pseudoCtrl.text.trim();
    final clePerso = _clePersoCtrl.text.trim();
    if (pseudo.isEmpty || clePerso.isEmpty) {
      setState(() => _erreur = 'Pseudo et clé personnelle requis.');
      return;
    }
    setState(() { _loading = true; _erreur = null; });
    try {
      final res = await SupabaseService.adminAuthMembre(pseudo: pseudo, clePerso: clePerso);
      if (res['ok'] != true) {
        setState(() => _erreur = 'Identifiants incorrects ou compte désactivé.');
        return;
      }
      final role = res['role'] as String? ?? '';
      List<Map<String, dynamic>> tontines = [];
      List<Map<String, dynamic>> demandes = [];
      try { tontines = await SupabaseService.adminListerTontines(clePerso); } catch (_) {}
      try { demandes = await SupabaseService.adminListerDemandes(clePerso); } catch (_) {}
      setState(() {
        _pseudoMembre   = pseudo;
        _clePersoMembre = clePerso;
        _roleMembre     = role;
        _nomMembre      = res['nom'] as String? ?? pseudo;
        _tontines       = tontines;
        _demandes       = demandes;
        _connecte       = true;
        _onglet         = 0;
      });
    } catch (e) {
      setState(() => _erreur = 'Erreur de connexion : $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // ── Déconnexion ──────────────────────────────────────────────────────────────
  void _deconnecter() {
    setState(() {
      _connecte       = false;
      _erreur         = null;
      _tontines       = [];
      _demandes       = [];
      _counts         = {};
      _roleMembre     = null;
      _pseudoMembre   = null;
      _clePersoMembre = null;
      _nomMembre      = null;
      _onglet         = 0;
    });
    _cleCtrl.clear();
    _pseudoCtrl.clear();
    _clePersoCtrl.clear();
  }

  Future<bool> _confirmerDeconnexion() async {
    final confirme = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.fondPapier,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: AppColors.alerte.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.logout_rounded, color: AppColors.alerte, size: 22),
            ),
            const SizedBox(width: 12),
            const Text('Se déconnecter ?',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: AppColors.encre)),
          ],
        ),
        content: const Text(
          'Voulez-vous vraiment quitter votre session administrateur ?',
          style: TextStyle(fontSize: 14, color: AppColors.texteDoux, height: 1.45),
        ),
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        actions: [
          OutlinedButton(
            onPressed: () => Navigator.pop(ctx, false),
            style: OutlinedButton.styleFrom(
              side: BorderSide(color: AppColors.lignes),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            ),
            child: const Text('Annuler', style: TextStyle(color: AppColors.texteDoux, fontWeight: FontWeight.w600)),
          ),
          ElevatedButton.icon(
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.logout_rounded, size: 16, color: Colors.white),
            label: const Text('Se déconnecter', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.alerte,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              elevation: 0,
            ),
          ),
        ],
      ),
    );
    return confirme == true;
  }

  // ── Rechargement des données ─────────────────────────────────────────────────
  Future<void> _recharger() async {
    final cle = _cleEffective;
    List<Map<String, dynamic>> tontines = _tontines;
    List<Map<String, dynamic>> demandes = _demandes;
    Map<String, dynamic>       counts   = _counts;

    try { tontines = await SupabaseService.adminListerTontines(cle); } catch (_) {}
    try { demandes = await SupabaseService.adminListerDemandes(cle); } catch (_) {}
    try { counts   = await SupabaseService.adminTontineCounts(cle);  } catch (_) {}

    if (mounted) setState(() {
      _tontines = tontines;
      _demandes = demandes;
      _counts   = counts;
    });
  }

  Future<void> _rechargerAvecFeedback() async {
    if (_recharging) return;
    setState(() => _recharging = true);
    try { await _recharger(); }
    finally { if (mounted) setState(() => _recharging = false); }
  }

  // ── Actions tontine ──────────────────────────────────────────────────────────
  Future<void> _activer(String code, {int mois = 1}) async {
    final cle = _cleEffective;
    final confirmer = await showDialog<bool>(
      context: context,
      builder: (ctx) => _DialogConfirm(
        icone: Icons.workspace_premium_rounded,
        couleur: AppColors.succes,
        titre: 'Activer Premium',
        message: 'Activer Premium pour la tontine $code pendant $mois mois ?',
        labelOk: 'Activer',
      ),
    );
    if (confirmer != true || !mounted) return;
    final ok = await SupabaseService.adminActiverPremium(cle: cle, code: code, mois: mois);
    if (!mounted) return;
    if (ok) {
      afficherToast(context, '✅ Premium activé pour $code !');
      await _recharger();
    } else {
      afficherToast(context, 'Erreur lors de l\'activation.', estErreur: true);
    }
  }

  Future<void> _desactiver(String code) async {
    final cle = _cleEffective;
    final confirmer = await showDialog<bool>(
      context: context,
      builder: (ctx) => _DialogConfirm(
        icone: Icons.workspace_premium_rounded,
        couleur: AppColors.alerte,
        titre: 'Désactiver Premium',
        message: 'Désactiver le plan Premium pour la tontine $code ?',
        labelOk: 'Désactiver',
        couleurOk: AppColors.alerte,
      ),
    );
    if (confirmer != true || !mounted) return;
    final ok = await SupabaseService.adminDesactiverPremium(cle: cle, code: code);
    if (!mounted) return;
    if (ok) {
      afficherToast(context, 'Premium désactivé pour $code.');
      await _recharger();
    } else {
      afficherToast(context, 'Erreur.', estErreur: true);
    }
  }

  Future<void> _bloquerTontine(String code, String nomTontine) async {
    String motif = '';
    final confirm = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (sCtx, setSt) => AlertDialog(
          backgroundColor: AppColors.fondPapier,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFFD32F2F).withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.lock_rounded, color: Color(0xFFD32F2F), size: 20),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text('Bloquer $nomTontine',
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: AppColors.encre)),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFD32F2F).withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFFD32F2F).withValues(alpha: 0.2)),
                ),
                child: Row(
                  children: const [
                    Icon(Icons.warning_amber_rounded, color: Color(0xFFD32F2F), size: 16),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Tous les membres seront bloqués immédiatement.',
                        style: TextStyle(fontSize: 12, color: Color(0xFFD32F2F), fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              const Text('Motif du blocage *',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: AppColors.encre)),
              const SizedBox(height: 6),
              TextField(
                autofocus: true,
                decoration: InputDecoration(
                  hintText: 'Ex: suspicion de fraude, vérification...',
                  filled: true,
                  fillColor: Colors.white,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(color: AppColors.lignes),
                  ),
                  isDense: true,
                ),
                maxLines: 2,
                textCapitalization: TextCapitalization.sentences,
                onChanged: (v) => motif = v.trim(),
              ),
            ],
          ),
          actionsPadding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Annuler', style: TextStyle(color: AppColors.texteDoux)),
            ),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFD32F2F),
                elevation: 0,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              onPressed: () => Navigator.pop(ctx, true),
              icon: const Icon(Icons.lock_rounded, size: 15, color: Colors.white),
              label: const Text('Bloquer', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
            ),
          ],
        ),
      ),
    );
    if (confirm != true || !mounted) return;
    if (motif.isEmpty) {
      afficherToast(context, 'Le motif est obligatoire.', estErreur: true);
      return;
    }
    setState(() => _blocageLoading[code] = true);
    final result = await SupabaseService.adminBloquerTontine(
      cle: _cleEffective, code: code, motif: motif,
    );
    if (!mounted) return;
    setState(() => _blocageLoading.remove(code));
    if (result['ok'] == true) {
      afficherToast(context, '🔒 Tontine $code bloquée avec succès.');
      await _recharger();
    } else {
      afficherToast(context, 'Erreur : ${result['erreur'] ?? 'Blocage échoué'}', estErreur: true);
    }
  }

  Future<void> _debloquerTontine(String code, String nomTontine) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => _DialogConfirm(
        icone: Icons.lock_open_rounded,
        couleur: const Color(0xFF2E7D32),
        titre: 'Débloquer $nomTontine',
        message: 'Les membres de $code pourront à nouveau accéder normalement à leur tontine.',
        labelOk: 'Débloquer',
        couleurOk: const Color(0xFF2E7D32),
      ),
    );
    if (confirm != true || !mounted) return;
    setState(() => _blocageLoading[code] = true);
    final result = await SupabaseService.adminDebloquerTontine(cle: _cleEffective, code: code);
    if (!mounted) return;
    setState(() => _blocageLoading.remove(code));
    if (result['ok'] == true) {
      afficherToast(context, '🔓 Tontine $code débloquée.');
      await _recharger();
    } else {
      afficherToast(context, 'Erreur : ${result['erreur'] ?? 'Déblocage échoué'}', estErreur: true);
    }
  }

  Future<void> _refuserDemande(String code) async {
    final motifCtrl = TextEditingController();
    String? motifErreur;
    final motif = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (sCtx, setSt) => AlertDialog(
          backgroundColor: AppColors.fondPapier,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text(context.tr('refuser_demande'),
              style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.alerte)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Code tontine : $code', style: const TextStyle(fontSize: 13, color: AppColors.texteDoux)),
              const SizedBox(height: 14),
              Text(context.tr('motif_refus'),
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5, color: AppColors.encre)),
              const SizedBox(height: 6),
              TextField(
                controller: motifCtrl,
                maxLines: 2,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  hintText: 'Ex : Coordonnées invalides, doublon...',
                  filled: true,
                  fillColor: Colors.white,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: AppColors.lignes),
                  ),
                  errorText: motifErreur,
                ),
                onChanged: (_) { if (motifErreur != null) setSt(() => motifErreur = null); },
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, null), child: Text(context.tr('annuler'))),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: AppColors.alerte),
              onPressed: () {
                final t = motifCtrl.text.trim();
                if (t.length < 3) { setSt(() => motifErreur = 'Motif requis.'); return; }
                Navigator.pop(ctx, t);
              },
              child: Text(context.tr('confirmer_refus'), style: const TextStyle(color: Colors.white)),
            ),
          ],
        ),
      ),
    );
    if (motif == null || !mounted) return;
    try {
      await SupabaseService.adminRefuserDemande(cle: _cleEffective, code: code, motif: motif);
      if (mounted) { afficherToast(context, 'Demande refusée pour $code.'); await _recharger(); }
    } catch (e) {
      if (mounted) afficherToast(context, 'Erreur : $e', estErreur: true);
    }
  }

  Future<void> _restaurerTontine(BuildContext context, String code, String nom) async {
    final motifCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.fondPapier,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: const Text('Restaurer la tontine',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 17)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Restaurer « $nom » ?',
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
            const SizedBox(height: 6),
            const Text(
              'La tontine redeviendra active. Un nouveau code sera généré.',
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
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
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
        cle: _cleEffective, code: code, motif: motifCtrl.text.trim(),
      );
      if (!mounted) return;
      if (result['ok'] == true) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(result['message'] as String? ?? 'Tontine restaurée avec succès.'),
            backgroundColor: AppColors.succes,
          ),
        );
        await _recharger();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(result['erreur'] as String? ?? 'Erreur lors de la restauration.'),
            backgroundColor: AppColors.alerte,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erreur : $e'), backgroundColor: AppColors.alerte),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // ── Build principal ──────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_connecte,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final ok = await _confirmerDeconnexion();
        if (ok && mounted) _deconnecter();
      },
      child: Scaffold(
        backgroundColor: AppColors.fondPapier,
        body: SafeArea(
          child: _connecte ? _CorpsAdmin() : _VueConnexion(),
        ),
      ),
    );
  }

  // ════════════════════════════════════════════════════════════════════════════
  // VUE CONNEXION
  // ════════════════════════════════════════════════════════════════════════════
  Widget _VueConnexion() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 40, 24, 24),
      child: StatefulBuilder(
        builder: (ctx, setLocalState) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Logo + titre ─────────────────────────────────────────────────
            Center(
              child: Column(
                children: [
                  Container(
                    width: 64, height: 64,
                    decoration: BoxDecoration(
                      color: AppColors.encre,
                      borderRadius: BorderRadius.circular(18),
                      boxShadow: [
                        BoxShadow(
                          color: AppColors.encre.withValues(alpha: 0.20),
                          blurRadius: 16,
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                    child: const Icon(Icons.admin_panel_settings_rounded, color: Colors.white, size: 32),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Espace Admin',
                    style: TextStyle(fontWeight: FontWeight.w900, fontSize: 26, color: AppColors.encre),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'TontineClair — accès restreint',
                    style: TextStyle(fontSize: 13, color: AppColors.texteDoux),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 32),

            // ── Sélecteur mode connexion ──────────────────────────────────────
            Container(
              decoration: BoxDecoration(
                color: AppColors.lignes,
                borderRadius: BorderRadius.circular(12),
              ),
              padding: const EdgeInsets.all(4),
              child: Row(
                children: [
                  _TabConnexion(
                    label: 'Super Admin',
                    selected: !_loginMembreMode,
                    onTap: () => setLocalState(() { _loginMembreMode = false; _erreur = null; }),
                  ),
                  _TabConnexion(
                    label: 'Membre équipe',
                    selected: _loginMembreMode,
                    onTap: () => setLocalState(() { _loginMembreMode = true; _erreur = null; }),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),

            // ── Formulaire ────────────────────────────────────────────────────
            CarteTC(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (!_loginMembreMode) ...[
                    const ChampLabel(label: 'Clé administrateur'),
                    TextField(
                      controller: _cleCtrl,
                      obscureText: true,
                      decoration: const InputDecoration(
                        hintText: 'Clé secrète admin',
                        prefixIcon: Icon(Icons.key_rounded, size: 18),
                      ),
                      onSubmitted: (_) => _connecter(),
                    ),
                  ] else ...[
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
                    const SizedBox(height: 10),
                    Row(
                      children: const [
                        Icon(Icons.info_outline, size: 12, color: AppColors.texteDoux),
                        SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            'Accès limité selon votre rôle',
                            style: TextStyle(fontSize: 11.5, color: AppColors.texteDoux),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ════════════════════════════════════════════════════════════════════════════
  // CORPS ADMIN (après connexion)
  // ════════════════════════════════════════════════════════════════════════════
  Widget _CorpsAdmin() {
    final nbDemandesPending = _demandes.where((d) {
      final s = (d['statut'] as String? ?? '').toLowerCase().replaceAll(' ', '_');
      return s == 'en_attente' || s == 'pending';
    }).length;
    final nbTontinesBloquees = _tontines.where((t) => (t['status'] as String? ?? '') == 'blocked').length;
    final nbTontines         = _tontines.where((t) => (t['status'] as String? ?? 'active') != 'deleted').length;

    // Bandeau rôle membre
    Widget? bandeauRole;
    if (_estMembreRole) {
      final (labelRole, couleurRole) = switch (_roleMembre) {
        'comptable'  => ('Comptable',   AppColors.orFonce),
        'conformite' => ('Conformité',  AppColors.encre),
        _            => ('Super Admin', AppColors.succes),
      };
      bandeauRole = _BandeauRole(
        nom: _nomMembre ?? _pseudoMembre ?? '',
        role: labelRole,
        couleur: couleurRole,
        onDeconnecter: () async {
          final ok = await _confirmerDeconnexion();
          if (ok && mounted) _deconnecter();
        },
      );
    }

    // Onglets
    final onglets = [
      _OngletDef(icone: Icons.dashboard_rounded,      label: 'Activité',  badge: nbDemandesPending, index: 0),
      _OngletDef(icone: Icons.groups_2_outlined,       label: 'Tontines',  badge: nbTontinesBloquees, index: 1),
      _OngletDef(icone: Icons.bar_chart_rounded,       label: 'Stats',     badge: 0,                  index: 2),
      _OngletDef(icone: Icons.groups_outlined,         label: 'Équipe',    badge: 0,                  index: 3),
      _OngletDef(icone: Icons.forum_outlined,          label: 'Messages',  badge: 0,                  index: 4),
      _OngletDef(icone: Icons.support_agent_outlined,  label: 'Support',   badge: 0,                  index: 5),
    ];

    return Column(
      children: [
        _HeaderAdmin(
          totalAlertes:    nbDemandesPending + nbTontinesBloquees,
          nbTontines:      nbTontines,
          recharging:      _recharging,
          onRefresh:       _rechargerAvecFeedback,
          onDeconnecter:   () async {
            final ok = await _confirmerDeconnexion();
            if (ok && mounted) _deconnecter();
          },
        ),
        if (bandeauRole != null) bandeauRole,
        _BarreNavAdmin(
          onglets:     onglets,
          ongletActif: _onglet,
          onSelect:    (i) => setState(() => _onglet = i),
        ),
        const Divider(height: 1, color: AppColors.lignes),
        Expanded(
          child: switch (_onglet) {
            0 => _VueDashboard(
                nbDemandesPending:    nbDemandesPending,
                nbTontinesBloquees:   nbTontinesBloquees,
                onNaviguer:           (i) => setState(() => _onglet = i),
              ),
            1 => _VueTontines(),
            2 => AdminDashboardScreen(cle: _cleEffective),
            3 => EquipeScreen(
                cle:        _cleEffective,
                roleActuel: _roleMembre ?? 'super_admin',
              ),
            4 => AdminMessagerieScreen(
                pseudo:   _pseudoMembre   ?? '',
                clePerso: _clePersoMembre ?? _cleEffective,
                nom:      _nomMembre      ?? (_pseudoMembre ?? 'Admin'),
              ),
            _ => SupportAdminScreen(cle: _cleEffective),
          },
        ),
      ],
    );
  }

  // ════════════════════════════════════════════════════════════════════════════
  // ONGLET 0 — DASHBOARD / ACTIVITÉ
  // ════════════════════════════════════════════════════════════════════════════
  Widget _VueDashboard({
    required int nbDemandesPending,
    required int nbTontinesBloquees,
    required void Function(int) onNaviguer,
  }) {
    final now = DateTime.now();
    final nbActives  = _tontines.where((t) => (t['status'] as String? ?? 'active') == 'active').length;
    final nbPremium  = _tontines.where((t) => (t['plan']   as String? ?? '') == 'premium').length;
    final nbGratuites= _tontines.where((t) {
      final st = (t['status'] as String? ?? 'active');
      final pl = (t['plan']   as String? ?? '');
      return st == 'active' && pl != 'premium';
    }).length;
    final nbTotal    = _tontines.where((t) => (t['status'] as String? ?? 'active') != 'deleted').length;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        // ── Alertes actives ───────────────────────────────────────────────────
        if (nbDemandesPending > 0 || nbTontinesBloquees > 0) ...[
          _SectionTitre(titre: 'Actions requises', icone: Icons.notifications_active_rounded, couleur: AppColors.alerte),
          const SizedBox(height: 10),
          if (nbDemandesPending > 0)
            _CarteAlerte(
              icone:   Icons.how_to_reg_rounded,
              titre:   '$nbDemandesPending demande${nbDemandesPending > 1 ? "s" : ""} en attente',
              detail:  'Activer le plan Premium pour ces tontines.',
              couleur: AppColors.orFonce,
              onTap:   () => onNaviguer(1),
            ),
          if (nbTontinesBloquees > 0) ...[
            const SizedBox(height: 8),
            _CarteAlerte(
              icone:   Icons.lock_rounded,
              titre:   '$nbTontinesBloquees tontine${nbTontinesBloquees > 1 ? "s" : ""} bloquée${nbTontinesBloquees > 1 ? "s" : ""}',
              detail:  'Des tontines sont actuellement bloquées.',
              couleur: const Color(0xFFD32F2F),
              onTap:   () => onNaviguer(1),
            ),
          ],
          const SizedBox(height: 24),
        ] else ...[
          _CarteStatutOk(),
          const SizedBox(height: 24),
        ],

        // ── Métriques plateforme ──────────────────────────────────────────────
        _SectionTitre(titre: 'Vue d\'ensemble', icone: Icons.analytics_outlined, couleur: AppColors.encre),
        const SizedBox(height: 12),
        GridView.count(
          crossAxisCount: 2,
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          childAspectRatio: 1.7,
          children: [
            _MetriqueCard(
              icone:   Icons.groups_2_outlined,
              valeur:  '$nbTotal',
              label:   'Tontines totales',
              couleur: AppColors.encre,
            ),
            _MetriqueCard(
              icone:   Icons.check_circle_outline,
              valeur:  '$nbActives',
              label:   'Actives',
              couleur: AppColors.succes,
            ),
            _MetriqueCard(
              icone:   Icons.workspace_premium_rounded,
              valeur:  '$nbPremium',
              label:   'Premium',
              couleur: AppColors.orFonce,
            ),
            _MetriqueCard(
              icone:   Icons.card_giftcard_rounded,
              valeur:  '$nbGratuites',
              label:   'Gratuites',
              couleur: AppColors.encreDoux,
            ),
          ],
        ),
        const SizedBox(height: 24),

        // ── Demandes en attente ───────────────────────────────────────────────
        if (_demandes.isNotEmpty) ...[
          _SectionTitre(
            titre:   'Demandes d\'activation (${_demandes.length})',
            icone:   Icons.how_to_reg_rounded,
            couleur: AppColors.encre,
            action:  nbDemandesPending > 0 ? '${nbDemandesPending} en attente' : null,
          ),
          const SizedBox(height: 10),
          ..._demandes.take(3).map((d) => _CarteDemandeCompacte(
            demande:    d,
            onActiver:  (code, mois) => _activer(code, mois: mois),
            onRefuser:  (code)       => _refuserDemande(code),
          )),
          if (_demandes.length > 3) ...[
            const SizedBox(height: 8),
            _BtnVoirTout(
              label: 'Voir toutes les demandes (${_demandes.length})',
              onTap: () => onNaviguer(1),
            ),
          ],
          const SizedBox(height: 24),
        ],

        // ── Tontines bloquées ─────────────────────────────────────────────────
        if (nbTontinesBloquees > 0) ...[
          _SectionTitre(
            titre:   'Tontines bloquées ($nbTontinesBloquees)',
            icone:   Icons.lock_rounded,
            couleur: const Color(0xFFD32F2F),
          ),
          const SizedBox(height: 10),
          ..._tontines
              .where((t) => (t['status'] as String? ?? '') == 'blocked')
              .take(3)
              .map((t) => _CarteTontineCompacte(
                tontine:       t,
                blocageLoading: _blocageLoading,
                onBloquer:     _bloquerTontine,
                onDebloquer:   _debloquerTontine,
                onActiver:     _activer,
                onDesactiver:  _desactiver,
                onRestaurer:   (code, nom) => _restaurerTontine(context, code, nom),
              )),
          const SizedBox(height: 24),
        ],

        // ── Pied de page ──────────────────────────────────────────────────────
        Center(
          child: Text(
            'TontineClair · Admin · ${now.day.toString().padLeft(2, '0')}/${now.month.toString().padLeft(2, '0')}/${now.year}',
            style: const TextStyle(fontSize: 11, color: AppColors.texteDoux),
          ),
        ),
      ],
    );
  }

  // ════════════════════════════════════════════════════════════════════════════
  // ONGLET 1 — TONTINES (gestion complète)
  // ════════════════════════════════════════════════════════════════════════════
  Widget _VueTontines() {
    final now = DateTime.now();

    String categorie(Map<String, dynamic> t) {
      final st = (t['status'] as String? ?? 'active');
      if (st == 'deleted')   return 'deleted';
      if (st == 'blocked')   return 'blocked';
      if (st == 'suspended') return 'suspended';
      if (st == 'inactive')  return 'inactive';
      final isPremium  = (t['plan'] as String? ?? '') == 'premium';
      final expireStr  = t['plan_expire'] as String? ?? t['expire'] as String?;
      final expire     = expireStr != null ? DateTime.tryParse(expireStr) : null;
      if (isPremium && expire != null && expire.isBefore(now)) return 'expire';
      if (isPremium) return 'premium';
      return 'gratuit';
    }

    final bool rpcFiable = _tontines.isEmpty && _counts.isNotEmpty &&
        ((_counts['total'] as num?)?.toInt() ?? 0) > 0;

    final int nbTotal      = rpcFiable ? ((_counts['total']      ?? 0) as num).toInt() : _tontines.where((t) => categorie(t) != 'deleted').length;
    final int nbActives    = rpcFiable ? ((_counts['actives']    ?? 0) as num).toInt() : _tontines.where((t) => categorie(t) == 'gratuit' || categorie(t) == 'premium').length;
    final int nbPremium    = rpcFiable ? ((_counts['premium']    ?? 0) as num).toInt() : _tontines.where((t) => categorie(t) == 'premium').length;
    final int nbGratuites  = rpcFiable ? ((_counts['gratuites']  ?? 0) as num).toInt() : _tontines.where((t) => categorie(t) == 'gratuit').length;
    final int nbExpirees   = rpcFiable ? ((_counts['expirees']   ?? 0) as num).toInt() : _tontines.where((t) => categorie(t) == 'expire').length;
    final int nbSuspendues = rpcFiable ? ((_counts['suspendues'] ?? 0) as num).toInt() : _tontines.where((t) => categorie(t) == 'suspended').length;
    final int nbInactives  = rpcFiable ? ((_counts['inactives']  ?? 0) as num).toInt() : _tontines.where((t) => categorie(t) == 'inactive').length;
    final int nbSupprimees = rpcFiable ? ((_counts['supprimees'] ?? 0) as num).toInt() : _tontines.where((t) => categorie(t) == 'deleted').length;
    final int nbBloquees   = _tontines.where((t) => categorie(t) == 'blocked').length;

    final tontinesFiltrees = _filtreStatut == null
        ? _tontines
        : _tontines.where((t) {
            if (_filtreStatut == 'blocked')  return categorie(t) == 'blocked';
            if (_filtreStatut == 'premium')  return categorie(t) == 'premium';
            if (_filtreStatut == 'gratuit')  return categorie(t) == 'gratuit';
            if (_filtreStatut == 'expire')   return categorie(t) == 'expire';
            return (t['status'] as String? ?? 'active') == _filtreStatut;
          }).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── En-tête section + stats rapides ──────────────────────────────────
        Container(
          color: Colors.white,
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 34, height: 34,
                    decoration: BoxDecoration(
                      color: AppColors.fondCode,
                      borderRadius: BorderRadius.circular(9),
                      border: Border.all(color: AppColors.lignes),
                    ),
                    child: const Icon(Icons.groups_2_outlined, size: 17, color: AppColors.encreDoux),
                  ),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Gestion des tontines',
                            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14.5, color: AppColors.encre)),
                        Text('Bloquer, activer, surveiller',
                            style: TextStyle(fontSize: 11, color: AppColors.texteDoux)),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _StatBadge(label: 'Actives',    valeur: nbActives,   couleur: AppColors.succes),
                    const SizedBox(width: 8),
                    _StatBadge(label: 'Premium',    valeur: nbPremium,   couleur: AppColors.orFonce),
                    const SizedBox(width: 8),
                    _StatBadge(label: 'Gratuites',  valeur: nbGratuites, couleur: AppColors.encreDoux),
                    if (nbBloquees > 0) ...[
                      const SizedBox(width: 8),
                      _StatBadge(label: '🔒 Bloquées', valeur: nbBloquees, couleur: const Color(0xFFD32F2F)),
                    ],
                    if (nbSupprimees > 0) ...[
                      const SizedBox(width: 8),
                      _StatBadge(label: 'Supprimées', valeur: nbSupprimees, couleur: AppColors.alerte),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1, color: AppColors.lignes),

        // ── Filtres ───────────────────────────────────────────────────────────
        Container(
          color: AppColors.fondPapier,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            child: Row(
              children: [
                _FiltreChip(label: 'Toutes ($nbTotal)',      selected: _filtreStatut == null,       onTap: () => setState(() => _filtreStatut = null),        couleur: AppColors.encre),
                const SizedBox(width: 8),
                _FiltreChip(label: 'Actives ($nbActives)',   selected: _filtreStatut == 'active',   onTap: () => setState(() => _filtreStatut = 'active'),    couleur: AppColors.succes),
                const SizedBox(width: 8),
                _FiltreChip(label: 'Gratuites ($nbGratuites)', selected: _filtreStatut == 'gratuit', onTap: () => setState(() => _filtreStatut = 'gratuit'),  couleur: AppColors.encreDoux),
                const SizedBox(width: 8),
                _FiltreChip(label: 'Premium ($nbPremium)',   selected: _filtreStatut == 'premium',  onTap: () => setState(() => _filtreStatut = 'premium'),   couleur: AppColors.orFonce),
                if (nbBloquees > 0) ...[
                  const SizedBox(width: 8),
                  _FiltreChip(label: '🔒 Bloquées ($nbBloquees)', selected: _filtreStatut == 'blocked', onTap: () => setState(() => _filtreStatut = 'blocked'), couleur: const Color(0xFFD32F2F)),
                ],
                if (nbExpirees > 0) ...[
                  const SizedBox(width: 8),
                  _FiltreChip(label: 'Expirées ($nbExpirees)', selected: _filtreStatut == 'expire', onTap: () => setState(() => _filtreStatut = 'expire'), couleur: AppColors.alerte),
                ],
                if (nbSuspendues > 0) ...[
                  const SizedBox(width: 8),
                  _FiltreChip(label: 'Désactivées ($nbSuspendues)', selected: _filtreStatut == 'suspended', onTap: () => setState(() => _filtreStatut = 'suspended'), couleur: AppColors.orFonce),
                ],
                if (nbInactives > 0) ...[
                  const SizedBox(width: 8),
                  _FiltreChip(label: 'Inactives ($nbInactives)', selected: _filtreStatut == 'inactive', onTap: () => setState(() => _filtreStatut = 'inactive'), couleur: AppColors.texteDoux),
                ],
                const SizedBox(width: 8),
                _FiltreChip(label: 'Supprimées ($nbSupprimees)', selected: _filtreStatut == 'deleted', onTap: () => setState(() => _filtreStatut = 'deleted'), couleur: AppColors.alerte),
              ],
            ),
          ),
        ),
        const Divider(height: 1, color: AppColors.lignes),

        // ── Liste tontines ────────────────────────────────────────────────────
        if (tontinesFiltrees.isEmpty)
          Expanded(
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    _filtreStatut == 'deleted' ? Icons.delete_outline_rounded : Icons.search_off_rounded,
                    size: 48, color: AppColors.texteDoux.withValues(alpha: 0.4),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _filtreStatut == 'deleted' ? 'Aucune tontine supprimée.' : 'Aucune tontine dans cette catégorie.',
                    style: const TextStyle(color: AppColors.texteDoux, fontSize: 15),
                  ),
                ],
              ),
            ),
          )
        else
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              itemCount: tontinesFiltrees.length,
              itemBuilder: (_, i) => _CarteTontineCompacte(
                tontine:        tontinesFiltrees[i],
                blocageLoading: _blocageLoading,
                onBloquer:      _bloquerTontine,
                onDebloquer:    _debloquerTontine,
                onActiver:      _activer,
                onDesactiver:   _desactiver,
                onRestaurer:    (code, nom) => _restaurerTontine(context, code, nom),
              ),
            ),
          ),
      ],
    );
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// WIDGETS PRIVÉS
// ═════════════════════════════════════════════════════════════════════════════

// ── Onglet connexion ───────────────────────────────────────────────────────────
class _TabConnexion extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _TabConnexion({required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: selected ? AppColors.encre : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 13,
              color: selected ? Colors.white : AppColors.texteDoux,
            ),
          ),
        ),
      ),
    );
  }
}

// ── Donnée onglet ──────────────────────────────────────────────────────────────
class _OngletDef {
  final IconData icone;
  final String label;
  final int badge;
  final int index;
  const _OngletDef({required this.icone, required this.label, required this.badge, required this.index});
}

// ── Header admin ───────────────────────────────────────────────────────────────
class _HeaderAdmin extends StatelessWidget {
  final int totalAlertes;
  final int nbTontines;
  final bool recharging;
  final VoidCallback onRefresh;
  final VoidCallback onDeconnecter;

  const _HeaderAdmin({
    required this.totalAlertes,
    required this.nbTontines,
    required this.recharging,
    required this.onRefresh,
    required this.onDeconnecter,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 10),
      decoration: const BoxDecoration(
        color: AppColors.fondPapier,
        border: Border(bottom: BorderSide(color: AppColors.lignes, width: 0.5)),
      ),
      child: Row(
        children: [
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
                const Text('Espace Admin',
                    style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15, color: AppColors.encre)),
                Text(
                  totalAlertes > 0
                      ? '$totalAlertes action${totalAlertes > 1 ? "s" : ""} requise${totalAlertes > 1 ? "s" : ""}'
                      : '$nbTontines tontines actives',
                  style: TextStyle(
                    fontSize: 11,
                    color: totalAlertes > 0 ? AppColors.alerte : AppColors.succes,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          if (totalAlertes > 0)
            Container(
              margin: const EdgeInsets.only(right: 6),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: AppColors.alerteFond,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: AppColors.alerte.withValues(alpha: 0.3)),
              ),
              child: Text('$totalAlertes',
                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: AppColors.alerte)),
            ),
          IconButton(
            onPressed: onRefresh,
            icon: recharging
                ? const SizedBox(width: 18, height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.encreDoux))
                : const Icon(Icons.refresh_rounded, color: AppColors.encreDoux, size: 22),
            tooltip: 'Actualiser',
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            padding: EdgeInsets.zero,
          ),
          Tooltip(
            message: 'Se déconnecter',
            child: InkWell(
              onTap: onDeconnecter,
              borderRadius: BorderRadius.circular(10),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: AppColors.alerte.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppColors.alerte.withValues(alpha: 0.20)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: const [
                    Icon(Icons.logout_rounded, size: 15, color: AppColors.alerte),
                    SizedBox(width: 5),
                    Text('Déconnexion',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.alerte)),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Bandeau rôle membre ────────────────────────────────────────────────────────
class _BandeauRole extends StatelessWidget {
  final String nom;
  final String role;
  final Color couleur;
  final VoidCallback onDeconnecter;

  const _BandeauRole({
    required this.nom,
    required this.role,
    required this.couleur,
    required this.onDeconnecter,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
      decoration: BoxDecoration(
        color: couleur.withValues(alpha: 0.08),
        border: Border(bottom: BorderSide(color: couleur.withValues(alpha: 0.15))),
      ),
      child: Row(
        children: [
          Icon(Icons.shield_outlined, size: 14, color: couleur),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '$nom  •  $role',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: couleur),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          GestureDetector(
            onTap: onDeconnecter,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: AppColors.alerte.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: AppColors.alerte.withValues(alpha: 0.25)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: const [
                  Icon(Icons.logout_rounded, size: 12, color: AppColors.alerte),
                  SizedBox(width: 4),
                  Text('Déconnexion',
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppColors.alerte)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Barre navigation ───────────────────────────────────────────────────────────
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
            final o        = onglets[i];
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
                          Icon(o.icone, size: 15, color: selected ? Colors.white : AppColors.encreDoux),
                          const SizedBox(width: 5),
                          Text(o.label,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: selected ? Colors.white : AppColors.encre,
                              )),
                        ],
                      ),
                    ),
                    if (o.badge > 0)
                      Positioned(
                        top: -5, right: -5,
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

// ── Titre de section ───────────────────────────────────────────────────────────
class _SectionTitre extends StatelessWidget {
  final String titre;
  final IconData icone;
  final Color couleur;
  final String? action;
  const _SectionTitre({required this.titre, required this.icone, required this.couleur, this.action});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 28, height: 28,
          decoration: BoxDecoration(
            color: couleur.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(7),
          ),
          child: Icon(icone, size: 14, color: couleur),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(titre,
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14, color: AppColors.encre)),
        ),
        if (action != null)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: AppColors.alerte.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(action!,
                style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppColors.alerte)),
          ),
      ],
    );
  }
}

// ── Carte alerte ───────────────────────────────────────────────────────────────
class _CarteAlerte extends StatelessWidget {
  final IconData icone;
  final String titre;
  final String detail;
  final Color couleur;
  final VoidCallback onTap;
  const _CarteAlerte({
    required this.icone,
    required this.titre,
    required this.detail,
    required this.couleur,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: couleur.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: couleur.withValues(alpha: 0.25)),
        ),
        child: Row(
          children: [
            Container(
              width: 38, height: 38,
              decoration: BoxDecoration(
                color: couleur.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icone, size: 18, color: couleur),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(titre,
                      style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: couleur)),
                  const SizedBox(height: 2),
                  Text(detail,
                      style: const TextStyle(fontSize: 11.5, color: AppColors.texteDoux)),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, size: 18, color: couleur.withValues(alpha: 0.7)),
          ],
        ),
      ),
    );
  }
}

// ── Carte statut OK ────────────────────────────────────────────────────────────
class _CarteStatutOk extends StatelessWidget {
  const _CarteStatutOk();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.succes.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.succes.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          const Icon(Icons.check_circle_rounded, color: AppColors.succes, size: 28),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Tout est à jour',
                    style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13.5, color: AppColors.succes)),
                SizedBox(height: 2),
                Text('Aucune action en attente.',
                    style: TextStyle(fontSize: 12, color: AppColors.texteDoux)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Métrique card ──────────────────────────────────────────────────────────────
class _MetriqueCard extends StatelessWidget {
  final IconData icone;
  final String valeur;
  final String label;
  final Color couleur;
  const _MetriqueCard({required this.icone, required this.valeur, required this.label, required this.couleur});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.lignes),
        boxShadow: [
          BoxShadow(color: AppColors.encre.withValues(alpha: 0.04), blurRadius: 6, offset: const Offset(0, 2)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            children: [
              Container(
                width: 28, height: 28,
                decoration: BoxDecoration(
                  color: couleur.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(7),
                ),
                child: Icon(icone, size: 14, color: couleur),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(valeur,
              style: TextStyle(fontWeight: FontWeight.w900, fontSize: 22, color: couleur)),
          Text(label,
              style: const TextStyle(fontSize: 11, color: AppColors.texteDoux, fontWeight: FontWeight.w600),
              overflow: TextOverflow.ellipsis),
        ],
      ),
    );
  }
}

// ── Carte demande compacte (dashboard) ────────────────────────────────────────
class _CarteDemandeCompacte extends StatelessWidget {
  final Map<String, dynamic>        demande;
  final void Function(String, int)  onActiver;
  final void Function(String)       onRefuser;

  const _CarteDemandeCompacte({
    required this.demande,
    required this.onActiver,
    required this.onRefuser,
  });

  @override
  Widget build(BuildContext context) {
    final statut      = demande['statut'] as String? ?? '';
    final code        = demande['code'] as String? ?? '';
    final nom         = demande['gestionnaire'] as String? ?? demande['nom'] as String? ?? '—';
    final formule     = demande['formule'] as String? ?? demande['plan'] as String? ?? 'mensuel';
    final nomTontine  = demande['nom_tontine'] as String? ?? code;

    final statutNorm = statut.toLowerCase().replaceAll('é', 'e').replaceAll('è', 'e').replaceAll(' ', '_');
    final enAttente  = statutNorm == 'en_attente' || statutNorm == 'pending';

    final Color statutCouleur;
    final Color statutFond;
    final String statutLabel;
    if (statutNorm == 'approuvee' || statutNorm == 'activee' || statutNorm == 'active') {
      statutCouleur = AppColors.succes; statutFond = AppColors.succesFond; statutLabel = '✓ Approuvée';
    } else if (statutNorm == 'refusee' || statutNorm == 'refuse') {
      statutCouleur = AppColors.alerte; statutFond = AppColors.alerteFond; statutLabel = '✗ Refusée';
    } else {
      statutCouleur = AppColors.orFonce; statutFond = AppColors.fondConsultation; statutLabel = '⏳ En attente';
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: enAttente ? AppColors.orFonce.withValues(alpha: 0.3) : AppColors.lignes),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(nom,
                        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: AppColors.encre)),
                    Text('$nomTontine · $code',
                        style: const TextStyle(fontSize: 11, color: AppColors.texteDoux)),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(color: statutFond, borderRadius: BorderRadius.circular(20)),
                child: Text(statutLabel,
                    style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: statutCouleur)),
              ),
            ],
          ),
          if (enAttente) ...[
            const SizedBox(height: 10),
            const Divider(height: 1, color: AppColors.lignes),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: BtnPrincipal(
                    label: formule == 'annuel' ? 'Activer 12 mois' : 'Activer 1 mois',
                    icone: Icons.verified_rounded,
                    couleur: AppColors.succes,
                    onTap: () => onActiver(code, formule == 'annuel' ? 12 : 1),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: BtnSecondaire(label: 'Refuser', onTap: () => onRefuser(code)),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

// ── Carte tontine compacte (réutilisable dans dashboard + liste tontines) ──────
class _CarteTontineCompacte extends StatelessWidget {
  final Map<String, dynamic>                    tontine;
  final Map<String, bool>                        blocageLoading;
  final void Function(String, String)            onBloquer;
  final void Function(String, String)            onDebloquer;
  final void Function(String, {int mois})        onActiver;
  final void Function(String)                    onDesactiver;
  final void Function(String, String)            onRestaurer;

  const _CarteTontineCompacte({
    required this.tontine,
    required this.blocageLoading,
    required this.onBloquer,
    required this.onDebloquer,
    required this.onActiver,
    required this.onDesactiver,
    required this.onRestaurer,
  });

  @override
  Widget build(BuildContext context) {
    final now         = DateTime.now();
    final code        = tontine['code'] as String? ?? '';
    final status      = tontine['status'] as String? ?? 'active';
    final isPremium   = (tontine['plan'] as String? ?? '') == 'premium';
    final expireStr   = tontine['plan_expire'] as String? ?? tontine['expire'] as String?;
    final expire      = expireStr != null ? DateTime.tryParse(expireStr) : null;
    final isExpire    = isPremium && expire != null && expire.isBefore(now);
    final isSupprimee = status == 'deleted';
    final isBloquee   = status == 'blocked';
    final isBlocLoad  = blocageLoading[code] == true;

    final nomBrut   = tontine['nom'] as String?;
    final nomAffich = (nomBrut == null || nomBrut.trim().isEmpty) ? 'Tontine sans nom' : nomBrut.trim();
    final gest      = tontine['president'] as String? ?? tontine['gestionnaire'] as String? ??
                      tontine['created_by'] as String? ?? tontine['owner'] as String?;
    final nbMembres = tontine['membres'] as int? ?? tontine['nb_membres'] as int? ?? 0;
    final cree      = DateTime.tryParse(tontine['cree'] as String? ?? '');
    final deletedAt = tontine['deleted_at'] != null ? DateTime.tryParse(tontine['deleted_at'] as String) : null;

    // Couleur de la bordure gauche selon état
    final Color bordureCouleur;
    if (isBloquee)   bordureCouleur = const Color(0xFFD32F2F);
    else if (isExpire)  bordureCouleur = AppColors.alerte;
    else if (isPremium) bordureCouleur = AppColors.orFonce;
    else                bordureCouleur = AppColors.lignes;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: isBloquee ? const Color(0xFFD32F2F).withValues(alpha: 0.25) : AppColors.lignes),
        boxShadow: [
          BoxShadow(color: AppColors.encre.withValues(alpha: 0.04), blurRadius: 6, offset: const Offset(0, 2)),
        ],
      ),
      child: IntrinsicHeight(
        child: Row(
          children: [
            // ── Bordure colorée gauche ────────────────────────────────────────
            Container(
              width: 4,
              decoration: BoxDecoration(
                color: bordureCouleur,
                borderRadius: const BorderRadius.only(
                  topLeft:    Radius.circular(14),
                  bottomLeft: Radius.circular(14),
                ),
              ),
            ),
            // ── Contenu ───────────────────────────────────────────────────────
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
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
                              Text(
                                nomAffich,
                                style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 14.5,
                                  color: isSupprimee ? AppColors.texteDoux : AppColors.encre,
                                  decoration: isSupprimee ? TextDecoration.lineThrough : null,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: AppColors.fondCode,
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(code,
                                        style: const TextStyle(
                                          fontSize: 10,
                                          fontFamily: 'monospace',
                                          fontWeight: FontWeight.w700,
                                          color: AppColors.encreDoux,
                                        )),
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    '$nbMembres membre${nbMembres > 1 ? "s" : ""}',
                                    style: const TextStyle(fontSize: 11, color: AppColors.texteDoux),
                                  ),
                                ],
                              ),
                              if (gest != null && gest.isNotEmpty) ...[
                                const SizedBox(height: 2),
                                Text(
                                  'Géré par $gest',
                                  style: const TextStyle(fontSize: 11, color: AppColors.texteDoux),
                                ),
                              ],
                              if (cree != null) ...[
                                const SizedBox(height: 2),
                                Text(
                                  'Créé ${Formatters.dateFormatee(cree)}',
                                  style: const TextStyle(fontSize: 11, color: AppColors.texteDoux),
                                ),
                              ],
                            ],
                          ),
                        ),
                        // ── Badges et boutons ─────────────────────────────────
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          mainAxisAlignment: MainAxisAlignment.start,
                          children: [
                            // Badge statut
                            if (isSupprimee)
                              _BadgeStatut(label: 'Supprimée', couleur: AppColors.alerte)
                            else if (isBloquee)
                              _BadgeStatut(label: '🔒 Bloquée', couleur: const Color(0xFFD32F2F))
                            else if (isExpire)
                              _BadgeStatut(label: 'Expirée', couleur: AppColors.alerte)
                            else
                              BadgePlan(isPremium: isPremium),

                            if (!isSupprimee) ...[
                              const SizedBox(height: 8),
                              if (isBlocLoad)
                                const SizedBox(width: 24, height: 24,
                                    child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.encreDoux))
                              else if (isBloquee)
                                _BtnAction(
                                  label: '🔓 Débloquer',
                                  couleur: const Color(0xFF2E7D32),
                                  onTap: () => onDebloquer(code, nomAffich),
                                )
                              else ...[
                                if (!isPremium)
                                  _BtnAction(
                                    label: 'Activer',
                                    couleur: AppColors.encre,
                                    onTap: () => onActiver(code),
                                  )
                                else
                                  _BtnAction(
                                    label: 'Désactiver',
                                    couleur: AppColors.alerte,
                                    onTap: () => onDesactiver(code),
                                  ),
                                const SizedBox(height: 4),
                                _BtnAction(
                                  label: '🔒 Bloquer',
                                  couleur: const Color(0xFFD32F2F),
                                  onTap: () => onBloquer(code, nomAffich),
                                ),
                              ],
                            ],
                          ],
                        ),
                      ],
                    ),

                    // ── Détails suppression ───────────────────────────────────
                    if (isSupprimee) ...[
                      const SizedBox(height: 10),
                      const Divider(height: 1, color: AppColors.lignes),
                      const SizedBox(height: 8),
                      if (tontine['deleted_by'] != null)
                        _InfoLigneAdmin(
                          icone: Icons.person_remove_outlined,
                          label: 'Supprimé par',
                          valeur: tontine['deleted_by'] as String,
                        ),
                      if (deletedAt != null)
                        _InfoLigneAdmin(
                          icone: Icons.delete_outline_rounded,
                          label: 'Supprimé le',
                          valeur: Formatters.dateFormatee(deletedAt),
                        ),
                      if (tontine['deletion_reason'] != null && (tontine['deletion_reason'] as String).isNotEmpty)
                        _InfoLigneAdmin(
                          icone: Icons.notes_rounded,
                          label: 'Motif',
                          valeur: tontine['deletion_reason'] as String,
                        ),
                      const SizedBox(height: 8),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: () => onRestaurer(code, nomAffich),
                          icon: const Icon(Icons.restore_rounded, size: 15),
                          label: const Text('Restaurer la tontine',
                              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppColors.succes,
                            side: BorderSide(color: AppColors.succes.withValues(alpha: 0.5)),
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                        ),
                      ),
                    ],

                    // ── Détails expiration ────────────────────────────────────
                    if (isExpire) ...[
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          const Icon(Icons.timer_off_rounded, size: 12, color: AppColors.alerte),
                          const SizedBox(width: 4),
                          Text('Expiré le ${Formatters.dateFormatee(expire)}',
                              style: const TextStyle(fontSize: 11, color: AppColors.alerte, fontWeight: FontWeight.w600)),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Bouton "voir tout" ─────────────────────────────────────────────────────────
class _BtnVoirTout extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _BtnVoirTout({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 11),
        decoration: BoxDecoration(
          color: AppColors.fondCode,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.lignes),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(label,
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.encreDoux)),
            const SizedBox(width: 4),
            const Icon(Icons.arrow_forward_rounded, size: 13, color: AppColors.encreDoux),
          ],
        ),
      ),
    );
  }
}

// ── Dialog de confirmation générique ──────────────────────────────────────────
class _DialogConfirm extends StatelessWidget {
  final IconData icone;
  final Color couleur;
  final String titre;
  final String message;
  final String labelOk;
  final Color? couleurOk;

  const _DialogConfirm({
    required this.icone,
    required this.couleur,
    required this.titre,
    required this.message,
    required this.labelOk,
    this.couleurOk,
  });

  @override
  Widget build(BuildContext context) {
    final okCouleur = couleurOk ?? AppColors.succes;
    return AlertDialog(
      backgroundColor: AppColors.fondPapier,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      title: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: couleur.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icone, color: couleur, size: 20),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(titre,
                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15, color: AppColors.encre)),
          ),
        ],
      ),
      content: Text(message,
          style: const TextStyle(fontSize: 13.5, color: AppColors.texteDoux, height: 1.5)),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      actions: [
        OutlinedButton(
          onPressed: () => Navigator.pop(context, false),
          style: OutlinedButton.styleFrom(
            side: BorderSide(color: AppColors.lignes),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
          child: const Text('Annuler', style: TextStyle(color: AppColors.texteDoux, fontWeight: FontWeight.w600)),
        ),
        ElevatedButton(
          onPressed: () => Navigator.pop(context, true),
          style: ElevatedButton.styleFrom(
            backgroundColor: okCouleur,
            elevation: 0,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
          child: Text(labelOk, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
        ),
      ],
    );
  }
}

// ── Filtre chip ────────────────────────────────────────────────────────────────
class _FiltreChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Color couleur;
  const _FiltreChip({required this.label, required this.selected, required this.onTap, required this.couleur});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? couleur : couleur.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: couleur.withValues(alpha: 0.4)),
        ),
        child: Text(label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: selected ? Colors.white : couleur,
            )),
      ),
    );
  }
}

// ── Ligne info ─────────────────────────────────────────────────────────────────
class _InfoLigneAdmin extends StatelessWidget {
  final IconData icone;
  final String label;
  final String valeur;
  const _InfoLigneAdmin({required this.icone, required this.label, required this.valeur});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icone, size: 13, color: AppColors.texteDoux),
          const SizedBox(width: 6),
          Text('$label : ',
              style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: AppColors.texteDoux)),
          Expanded(
            child: Text(valeur, style: const TextStyle(fontSize: 11.5, color: AppColors.encre)),
          ),
        ],
      ),
    );
  }
}

// ── Badge stat compact ─────────────────────────────────────────────────────────
class _StatBadge extends StatelessWidget {
  final String label;
  final int valeur;
  final Color couleur;
  const _StatBadge({required this.label, required this.valeur, required this.couleur});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: couleur.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: couleur.withValues(alpha: 0.3)),
      ),
      child: Column(
        children: [
          Text('$valeur', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900, color: couleur)),
          Text(label, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: couleur)),
        ],
      ),
    );
  }
}

// ── Badge statut tontine ───────────────────────────────────────────────────────
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
      child: Text(label,
          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: couleur)),
    );
  }
}

// ── Bouton action compact ──────────────────────────────────────────────────────
class _BtnAction extends StatelessWidget {
  final String label;
  final Color couleur;
  final VoidCallback onTap;
  const _BtnAction({required this.label, required this.couleur, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          color: couleur.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: couleur.withValues(alpha: 0.3)),
        ),
        child: Text(label,
            style: TextStyle(fontSize: 11, color: couleur, fontWeight: FontWeight.w700)),
      ),
    );
  }
}
