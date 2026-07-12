import 'package:flutter/material.dart';
import '../services/supabase_service.dart';
import '../utils/app_colors.dart';
import '../utils/formatters.dart';
import '../widgets/app_widgets.dart';
import 'admin_dashboard_screen.dart';

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
  int _onglet = 0;
  // Filtre statut tontines : null = toutes, 'active', 'deleted', 'suspended', 'inactive'
  String? _filtreStatut;
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
      final demandes = await SupabaseService.adminListerDemandes(cle);
      final tontines = await SupabaseService.adminListerTontines(cle);

      if (demandes.isEmpty && tontines.isEmpty) {
        // Peut-être clé incorrecte ou aucune donnée
        setState(() {
          _connecte = true;
          _demandes = demandes;
          _tontines = tontines;
        });
      } else {
        setState(() {
          _connecte = true;
          _demandes = demandes;
          _tontines = tontines;
        });
      }
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
        title: const Text('Activer Premium', style: TextStyle(fontWeight: FontWeight.w700, color: AppColors.encre)),
        content: Text('Activer Premium pour la tontine $code pendant $mois mois ?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.succes),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Activer', style: TextStyle(color: Colors.white)),
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
          title: const Text(
            'Refuser la demande',
            style: TextStyle(fontWeight: FontWeight.w700, color: AppColors.alerte),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Code tontine : $code',
                style: const TextStyle(fontSize: 13, color: AppColors.texteDoux),
              ),
              const SizedBox(height: 14),
              const Text(
                'Motif du refus',
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
                    borderSide: const BorderSide(color: AppColors.lignes),
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
              child: const Text('Annuler'),
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
              child: const Text('Confirmer le refus', style: TextStyle(color: Colors.white)),
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
    final demandes = await SupabaseService.adminListerDemandes(cle);
    final tontines = await SupabaseService.adminListerTontines(cle);
    setState(() {
      _demandes = demandes;
      _tontines = tontines;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.fondPapier,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
              child: Row(
                children: [
                  const LogoTontineClair(),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.arrow_back, size: 16),
                    label: const Text('Retour'),
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
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Espace administrateur',
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 28,
              color: AppColors.encre,
            ),
          ),
          const SizedBox(height: 20),
          CarteTC(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const ChampLabel(label: 'Clé administrateur'),
                TextField(
                  controller: _cleCtrl,
                  obscureText: true,
                  decoration: const InputDecoration(
                    hintText: 'Clé secrète',
                  ),
                  onSubmitted: (_) => _connecter(),
                ),
                ChampErreur(texte: _erreur),
                const SizedBox(height: 16),
                BtnPrincipal(
                  label: 'Accéder',
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
    return Column(
      children: [
        // Onglets
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _OngletBtn(
                  label: 'Demandes (${_demandes.length})',
                  selected: _onglet == 0,
                  onTap: () => setState(() => _onglet = 0),
                ),
                const SizedBox(width: 10),
                _OngletBtn(
                  label: 'Tontines (${_tontines.length})',
                  selected: _onglet == 1,
                  onTap: () => setState(() => _onglet = 1),
                ),
                const SizedBox(width: 10),
                _OngletBtn(
                  label: '📊 Dashboard',
                  selected: _onglet == 2,
                  onTap: () => setState(() => _onglet = 2),
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
                  : AdminDashboardScreen(cle: _cle),
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
            const SizedBox(height: 12),
            const Text(
              'Aucune demande.',
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
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                Container(
                  width: 8, height: 8,
                  decoration: const BoxDecoration(
                    color: AppColors.alerte,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  'En attente (${enAttente.length})',
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
    // Filtrer selon le statut sélectionné
    final tontinesFiltrees = _filtreStatut == null
        ? _tontines
        : _tontines.where((t) {
            final s = (t['status'] as String? ?? 'active');
            return s == _filtreStatut;
          }).toList();

    // Comptes par statut
    final nbActives    = _tontines.where((t) => (t['status'] as String? ?? 'active') == 'active').length;
    final nbSupprimees = _tontines.where((t) => (t['status'] as String? ?? '') == 'deleted').length;
    final nbSuspendues = _tontines.where((t) => (t['status'] as String? ?? '') == 'suspended').length;
    final nbInactives  = _tontines.where((t) => (t['status'] as String? ?? '') == 'inactive').length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Filtres statut ──────────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _FiltreChip(
                  label: 'Toutes (${_tontines.length})',
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
                if (nbSupprimees > 0) ...[
                  const SizedBox(width: 8),
                  _FiltreChip(
                    label: 'Supprimées ($nbSupprimees)',
                    selected: _filtreStatut == 'deleted',
                    onTap: () => setState(() => _filtreStatut = 'deleted'),
                    couleur: AppColors.alerte,
                  ),
                ],
                if (nbSuspendues > 0) ...[
                  const SizedBox(width: 8),
                  _FiltreChip(
                    label: 'Suspendues ($nbSuspendues)',
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
              ],
            ),
          ),
        ),

        // ── Liste ────────────────────────────────────────────────
        if (tontinesFiltrees.isEmpty)
          const Expanded(
            child: Center(
              child: Text('Aucune tontine.', style: TextStyle(color: AppColors.texteDoux)),
            ),
          )
        else
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              itemCount: tontinesFiltrees.length,
              itemBuilder: (_, i) {
                final t = tontinesFiltrees[i];
                final isPremium  = t['plan'] == 'premium';
                final status     = (t['status'] as String? ?? 'active');
                final isSupprimee = status == 'deleted';
                final cree       = DateTime.tryParse(t['cree'] as String? ?? '');
                final deletedAt  = t['deleted_at'] != null
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
                                Text(
                                  '${t['nom']} · Code ${t['code']}',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w700,
                                    fontSize: 15,
                                    color: isSupprimee
                                        ? AppColors.texteDoux
                                        : AppColors.encre,
                                    decoration: isSupprimee
                                        ? TextDecoration.lineThrough
                                        : null,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '${t['membres']} membres · Créé ${Formatters.dateFormatee(cree)}',
                                  style: const TextStyle(
                                      fontSize: 12, color: AppColors.texteDoux),
                                ),
                              ],
                            ),
                          ),
                          // Badge statut
                          if (isSupprimee)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: AppColors.alerteFond,
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: const Text(
                                'Supprimée',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.alerte,
                                ),
                              ),
                            )
                          else
                            Column(
                              children: [
                                BadgePlan(isPremium: isPremium),
                                const SizedBox(height: 6),
                                if (!isPremium)
                                  GestureDetector(
                                    onTap: () => _activer(t['code'] as String),
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                                      decoration: BoxDecoration(
                                        color: AppColors.encre,
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: const Text(
                                        'Activer',
                                        style: TextStyle(fontSize: 11, color: Colors.white, fontWeight: FontWeight.w700),
                                      ),
                                    ),
                                  )
                                else
                                  GestureDetector(
                                    onTap: () => _desactiver(t['code'] as String),
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                                      decoration: BoxDecoration(
                                        color: AppColors.alerte.withValues(alpha: 0.1),
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: const Text(
                                        'Désactiver',
                                        style: TextStyle(fontSize: 11, color: AppColors.alerte, fontWeight: FontWeight.w700),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                        ],
                      ),

                      // ── Détails suppression ─────────────────────────────
                      if (isSupprimee) ...[
                        const SizedBox(height: 10),
                        const Divider(height: 1, color: AppColors.lignes),
                        const SizedBox(height: 8),
                        if (t['deleted_by'] != null)
                          _InfoLigneAdmin(
                            icone: Icons.person_outline_rounded,
                            label: 'Supprimé par',
                            valeur: t['deleted_by'] as String,
                          ),
                        if (deletedAt != null)
                          _InfoLigneAdmin(
                            icone: Icons.calendar_today_outlined,
                            label: 'Date de suppression',
                            valeur: Formatters.dateFormatee(deletedAt),
                          ),
                        if (t['deletion_reason'] != null && (t['deletion_reason'] as String).isNotEmpty)
                          _InfoLigneAdmin(
                            icone: Icons.notes_rounded,
                            label: 'Motif',
                            valeur: t['deletion_reason'] as String,
                          ),
                        const SizedBox(height: 8),
                        // Bouton restaurer
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed: () => _restaurerTontine(
                              context,
                              t['code'] as String,
                              t['nom'] as String? ?? t['code'] as String,
                            ),
                            icon: const Icon(Icons.restore_rounded, size: 16),
                            label: const Text(
                              'Restaurer la tontine',
                              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                            ),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: AppColors.succes,
                              side: BorderSide(color: AppColors.succes.withValues(alpha: 0.5)),
                              padding: const EdgeInsets.symmetric(vertical: 9),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
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
