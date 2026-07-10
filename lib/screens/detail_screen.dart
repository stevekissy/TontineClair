import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/tontine.dart';
import '../services/tontine_provider.dart';
import '../utils/app_colors.dart';
import '../utils/formatters.dart';
import '../widgets/app_widgets.dart';
import '../widgets/roue_rotation.dart';
import 'verrou_screen.dart';
import 'journal_screen.dart';
import 'abonnement_screen.dart';
import 'caisse_screen.dart';
import 'prets_screen.dart';
import 'votes_screen.dart';
import 'tirage_screen.dart';
import 'cotisations_screen.dart';
import 'membres_screen.dart';
import 'dashboard_screen.dart';

class DetailScreen extends StatefulWidget {
  final String code;

  const DetailScreen({super.key, required this.code});

  @override
  State<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends State<DetailScreen> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<TontineProvider>().chargerTontine(widget.code);
    });
    // Rafraîchissement automatique toutes les 30 secondes
    _timer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) {
        context.read<TontineProvider>().chargerTontine(widget.code);
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _debloqur(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const VerrouScreen()),
    );
  }

  void _verrouiller(BuildContext context) {
    context.read<TontineProvider>().verrouiller();
    afficherToast(context, 'Session gestionnaire terminée.');
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<TontineProvider>();

    if (provider.enChargement && provider.courante == null) {
      return Scaffold(
        backgroundColor: AppColors.fondPapier,
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (provider.erreur != null) {
      return Scaffold(
        backgroundColor: AppColors.fondPapier,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.error_outline, size: 48, color: AppColors.alerte),
                const SizedBox(height: 16),
                Text(
                  provider.erreur!,
                  style: const TextStyle(color: AppColors.alerte),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                BtnPrincipal(
                  label: 'Réessayer',
                  onTap: () => provider.chargerTontine(widget.code),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final tontine = provider.courante;
    if (tontine == null) {
      return Scaffold(
        backgroundColor: AppColors.fondPapier,
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final data = tontine.data;
    final estGest = provider.estDebloque;
    final gestNom = provider.gestActifNom;

    return Scaffold(
      backgroundColor: AppColors.fondPapier,
      body: SafeArea(
        child: Stack(
          children: [
            RefreshIndicator(
              onRefresh: () => provider.chargerTontine(widget.code),
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 120),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Header
                    const SizedBox(height: 18),
                    Row(
                      children: [
                        const LogoTontineClair(),
                        const Spacer(),
                        TextButton.icon(
                          onPressed: () => Navigator.of(context).pop(),
                          icon: const Icon(Icons.arrow_back, size: 16),
                          label: const Text('Mes tontines'),
                          style: TextButton.styleFrom(
                            foregroundColor: AppColors.encre,
                            textStyle: const TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 14,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    // Bandeau mode
                    _BandeauMode(
                      estGest: estGest,
                      gestNom: gestNom,
                      onDebloqur: () => _debloqur(context),
                      onVerrouiller: () => _verrouiller(context),
                    ),
                    const SizedBox(height: 10),
                    // Titre
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            data.nom,
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 26,
                              color: AppColors.encre,
                              letterSpacing: -0.02,
                            ),
                          ),
                        ),
                        BadgePlan(isPremium: tontine.isPremium),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        const Text(
                          'Code : ',
                          style: TextStyle(
                            fontSize: 13.5,
                            color: AppColors.texteDoux,
                          ),
                        ),
                        CodePuce(code: tontine.code),
                        const SizedBox(width: 12),
                        Text(
                          Formatters.periodicite(data.periode),
                          style: const TextStyle(
                            fontSize: 13.5,
                            color: AppColors.texteDoux,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '· ${Formatters.montantFCFA(data.montant)}/pers.',
                          style: const TextStyle(
                            fontSize: 13.5,
                            color: AppColors.texteDoux,
                          ),
                        ),
                      ],
                    ),
                    if (data.echeance != null) ...[
                      const SizedBox(height: 4),
                      _BandeauEcheance(echeance: data.echeance!),
                    ],
                    const SizedBox(height: 16),
                    // Roue de rotation
                    RoueRotation(data: data),
                    const SizedBox(height: 20),
                    // Actions rapides
                    _ActionsRapides(
                      data: data,
                      estGest: estGest,
                      isPremium: tontine.isPremium,
                      code: tontine.code,
                    ),
                    const SizedBox(height: 16),
                    // Liste des membres
                    _ListeMembres(data: data, estGest: estGest, code: tontine.code),
                    const SizedBox(height: 16),
                    // Informations
                    _InfosTontine(data: data),
                  ],
                ),
              ),
            ),
            // Barre du bas
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _BarreDetail(
                estGest: estGest,
                isPremium: tontine.isPremium,
                code: tontine.code,
                data: data,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BandeauMode extends StatelessWidget {
  final bool estGest;
  final String? gestNom;
  final VoidCallback onDebloqur;
  final VoidCallback onVerrouiller;

  const _BandeauMode({
    required this.estGest,
    required this.gestNom,
    required this.onDebloqur,
    required this.onVerrouiller,
  });

  @override
  Widget build(BuildContext context) {
    if (estGest) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.fondGestion,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            const Icon(Icons.lock_open, size: 16, color: AppColors.encre),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Mode gestion · $gestNom',
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                  color: AppColors.encre,
                ),
              ),
            ),
            GestureDetector(
              onTap: onVerrouiller,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                decoration: BoxDecoration(
                  color: AppColors.encre,
                  borderRadius: BorderRadius.circular(9),
                ),
                child: const Text(
                  'Verrouiller',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 12.5,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.fondConsultation,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          const Icon(Icons.visibility, size: 16, color: AppColors.orFonce),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              'Mode consultation',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 13,
                color: AppColors.orFonce,
              ),
            ),
          ),
          GestureDetector(
            onTap: onDebloqur,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(
                color: AppColors.or,
                borderRadius: BorderRadius.circular(9),
              ),
              child: const Text(
                'Accès gestionnaire',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 12.5,
                  color: Color(0xFF2A1E05),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BandeauEcheance extends StatelessWidget {
  final String echeance;

  const _BandeauEcheance({required this.echeance});

  @override
  Widget build(BuildContext context) {
    final date = DateTime.tryParse(echeance);
    if (date == null) return const SizedBox.shrink();
    final restant = Formatters.joursRestants(date);
    final estRetard = date.isBefore(DateTime.now());

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: estRetard ? AppColors.alerteFond : AppColors.succesFond,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        '📅 Échéance : ${Formatters.dateFormatee(date)} · $restant',
        style: TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
          color: estRetard ? AppColors.alerte : AppColors.succes,
        ),
      ),
    );
  }
}

class _ActionsRapides extends StatelessWidget {
  final TontineData data;
  final bool estGest;
  final bool isPremium;
  final String code;

  const _ActionsRapides({
    required this.data,
    required this.estGest,
    required this.isPremium,
    required this.code,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Modules',
          style: TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 18,
            color: AppColors.encre,
          ),
        ),
        const SizedBox(height: 10),
        GridView.count(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisCount: 2,
          childAspectRatio: 1.7,
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
          children: [
            _ActionBtn(
              icon: Icons.dashboard_outlined,
              label: 'Tableau de bord',
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => DashboardScreen(code: code),
                ),
              ),
            ),
            _ActionBtn(
              icon: Icons.group_outlined,
              label: 'Membres',
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => MembresScreen(code: code),
                ),
              ),
            ),
            _ActionBtn(
              icon: Icons.payments_outlined,
              label: 'Cotisations',
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => CotisationsScreen(code: code),
                ),
              ),
            ),
            _ActionBtn(
              icon: Icons.shuffle,
              label: 'Tirage',
              badge: data.tirageVerrouille ? '🔒' : null,
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => TirageScreen(code: code),
                ),
              ),
            ),
            _ActionBtn(
              icon: Icons.account_balance_wallet_outlined,
              label: 'Caisse',
              locked: !isPremium,
              onTap: isPremium
                  ? () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => CaisseScreen(code: code),
                        ),
                      )
                  : () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => AbonnementScreen(code: code),
                        ),
                      ),
            ),
            _ActionBtn(
              icon: Icons.handshake_outlined,
              label: 'Prêts',
              locked: !isPremium,
              onTap: isPremium
                  ? () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => PretsScreen(code: code),
                        ),
                      )
                  : () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => AbonnementScreen(code: code),
                        ),
                      ),
            ),
            _ActionBtn(
              icon: Icons.how_to_vote_outlined,
              label: 'Votes',
              locked: !isPremium,
              onTap: isPremium
                  ? () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => VotesScreen(code: code),
                        ),
                      )
                  : () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => AbonnementScreen(code: code),
                        ),
                      ),
            ),
            _ActionBtn(
              icon: Icons.history,
              label: 'Journal',
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => JournalScreen(code: code),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _ActionBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool locked;
  final String? badge;
  final VoidCallback? onTap;

  const _ActionBtn({
    required this.icon,
    required this.label,
    this.locked = false,
    this.badge,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.carte,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.lignes),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              color: locked ? AppColors.texteDoux : AppColors.encre,
              size: 22,
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 14,
                color: locked ? AppColors.texteDoux : AppColors.encre,
              ),
            ),
            if (locked) ...[
              const SizedBox(width: 4),
              const Text('🔒', style: TextStyle(fontSize: 11)),
            ],
            if (badge != null) ...[
              const SizedBox(width: 4),
              Text(badge!, style: const TextStyle(fontSize: 11)),
            ],
          ],
        ),
      ),
    );
  }
}

class _ListeMembres extends StatelessWidget {
  final TontineData data;
  final bool estGest;
  final String code;

  const _ListeMembres({
    required this.data,
    required this.estGest,
    required this.code,
  });

  @override
  Widget build(BuildContext context) {
    final membres = data.membres;
    // tourActuel est un INDEX 0-based dans ordre[]
    // On cherche le membre dont l'ID est ordre[tourActuel]
    final benefId = data.beneficiaireId; // null si cycleTermine
    // isServi : l'ID apparaît dans ordre[] à un index < tourActuel
    final ordreIdx = {for (int i = 0; i < data.ordre.length; i++) data.ordre[i]: i};

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text(
              'Membres',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 18,
                color: AppColors.encre,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '${membres.where((m) => m.paye).length}/${membres.length} payés',
              style: const TextStyle(
                fontSize: 13,
                color: AppColors.texteDoux,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        ...membres.asMap().entries.map(
          (e) {
            final m = e.value;
            final idxDansOrdre = ordreIdx[m.id];
            final isCourant = !data.cycleTermine && m.id == benefId;
            // isServi = déjà passé = son index dans ordre[] < tourActuel
            final isServi = data.cycleTermine ||
                (idxDansOrdre != null && idxDansOrdre < data.tourActuel);
            return _LigneMembre(
              membre: m,
              rang: e.key + 1,
              isCourant: isCourant,
              isServi: isServi && !isCourant,
              isBeneficiaire: isCourant,
            );
          },
        ),
      ],
    );
  }
}

class _LigneMembre extends StatelessWidget {
  final Membre membre;
  final int rang;
  final bool isCourant;
  final bool isServi;
  final bool isBeneficiaire;

  const _LigneMembre({
    required this.membre,
    required this.rang,
    required this.isCourant,
    required this.isServi,
    this.isBeneficiaire = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: isCourant ? AppColors.fondCode : AppColors.carte,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isCourant ? AppColors.encreDoux : AppColors.lignes,
          width: isCourant ? 1.5 : 1,
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: isCourant ? AppColors.or : AppColors.fondCode,
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Text(
                '$rang',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                  color: isCourant ? const Color(0xFF2A1E05) : AppColors.encre,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  membre.nom,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                    color: AppColors.texte,
                  ),
                ),
                if (isCourant)
                  const Text(
                    'Tour en cours',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: AppColors.encreDoux,
                      fontWeight: FontWeight.w600,
                    ),
                  )
                else if (isServi)
                  const Text(
                    'A reçu sa part',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: AppColors.texteDoux,
                    ),
                  ),
              // Badge BÉNÉFICIAIRE — totalement indépendant du statut paye
              if (isBeneficiaire)
                Container(
                  margin: const EdgeInsets.only(top: 2),
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppColors.or.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(5),
                    border: Border.all(color: AppColors.or.withValues(alpha: 0.4)),
                  ),
                  child: const Text(
                    'BÉNÉFICIAIRE',
                    style: TextStyle(
                      fontSize: 9.5,
                      fontWeight: FontWeight.w800,
                      color: AppColors.or,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Statut paiement
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: membre.paye ? AppColors.succesFond : AppColors.alerteFond,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              membre.paye ? '✓ Payé' : 'En attente',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 12,
                color: membre.paye ? AppColors.succes : AppColors.alerte,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _InfosTontine extends StatelessWidget {
  final TontineData data;

  const _InfosTontine({required this.data});

  @override
  Widget build(BuildContext context) {
    final nbMembresPayes = data.membres.where((m) => m.paye).length;
    final totalCollecte = nbMembresPayes * data.montant;
    final totalAttendu = data.membres.length * data.montant;

    return CarteTC(
      child: Column(
        children: [
          _InfoLigne(
            label: 'Méthode d\'ordre',
            valeur: Formatters.methodeOrdre(data.methodeOrdre),
          ),
          const Divider(height: 16, color: AppColors.lignes),
          _InfoLigne(
            label: 'Tour courant',
            valeur:
                'Tour ${data.numerTour} / ${data.membres.length}',  // numerTour = tourActuel + 1
          ),
          const Divider(height: 16, color: AppColors.lignes),
          _InfoLigne(
            label: 'Collecté ce tour',
            valeur: Formatters.montantFCFA(totalCollecte),
            couleurValeur: AppColors.succes,
          ),
          const Divider(height: 16, color: AppColors.lignes),
          _InfoLigne(
            label: 'Cagnotte totale',
            valeur: Formatters.montantFCFA(totalAttendu),
            couleurValeur: AppColors.encre,
          ),
        ],
      ),
    );
  }
}

class _InfoLigne extends StatelessWidget {
  final String label;
  final String valeur;
  final Color? couleurValeur;

  const _InfoLigne({
    required this.label,
    required this.valeur,
    this.couleurValeur,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 13.5,
            color: AppColors.texteDoux,
          ),
        ),
        const Spacer(),
        Text(
          valeur,
          style: TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 14,
            color: couleurValeur ?? AppColors.texte,
          ),
        ),
      ],
    );
  }
}

class _BarreDetail extends StatelessWidget {
  final bool estGest;
  final bool isPremium;
  final String code;
  final TontineData data;

  const _BarreDetail({
    required this.estGest,
    required this.isPremium,
    required this.code,
    required this.data,
  });

  @override
  Widget build(BuildContext context) {
    if (!estGest) {
      return Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 18),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [
              AppColors.fondPapier,
              AppColors.fondPapier.withValues(alpha: 0),
            ],
          ),
        ),
        child: BtnKola(
          label: '🔐 Accès gestionnaire',
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const VerrouScreen()),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [
            AppColors.fondPapier,
            AppColors.fondPapier.withValues(alpha: 0),
          ],
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: BtnSecondaire(
              label: 'Cotisations',
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => CotisationsScreen(code: code),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: BtnPrincipal(
              label: 'Clôturer le tour',
              onTap: () => _cloturerTour(context),
            ),
          ),
        ],
      ),
    );
  }

  void _cloturerTour(BuildContext context) async {
    final provider = context.read<TontineProvider>();
    final tontine = provider.courante!;
    final data = tontine.data;
    final membres = data.membres;

    // Vérifier que tous ont payé
    final nonPayes = membres.where((m) => !m.paye).toList();

    if (nonPayes.isNotEmpty) {
      final continuer = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppColors.fondPapier,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
          title: const Text(
            '⚠️ Membres non payés',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: AppColors.encre,
            ),
          ),
          content: Text(
            '${nonPayes.length} membre(s) n\'ont pas encore payé : ${nonPayes.map((m) => m.nom).join(', ')}.\n\nConfirmer quand même la clôture ?',
            style: const TextStyle(color: AppColors.texte),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Annuler'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Clôturer', style: TextStyle(color: AppColors.alerte)),
            ),
          ],
        ),
      );
      if (continuer != true || !context.mounted) return;
    }

    // Confirmer avec PIN
    // ── Clôture alignée sur index.html ──────────────────────────────────
    // tourActuel est 0-based. Le bénéficiaire = membres[ ordre[tourActuel] ]
    // Après clôture : paiements={}, tourActuel++
    // Si tourActuel + 1 >= ordre.length → cycleTermine = true
    final beneficiaire = data.beneficiaire;
    final benefNom = beneficiaire?.nom ?? '—';
    final numerTourAffiche = data.numerTour; // = tourActuel + 1
    final ref = Formatters.genererReference();

    // Calculer payesIds (IDs des membres ayant payé) pour l'historique
    final payesIds = data.ordre
        .where((id) => data.paiements.containsKey(id))
        .toList();
    final nbPayesClot = payesIds.length;

    final ok = await afficherModalePin(
      context,
      titre: 'Clôturer le tour $numerTourAffiche',
      sousTitre: 'Confirme ton identité pour décaisser et passer au tour suivant.',
      onValider: (pin) async {
        // Préparer les nouvelles données
        final newData = data.toJson();

        // 1. Réinitialiser paiements{} (comme index.html : d.paiements = {})
        newData['paiements'] = {};

        // 2. Réinitialiser membres[].paye à false
        final nouveauxMembres = (membres)
            .map((m) => Membre(
                  id: m.id,
                  nom: m.nom,
                  paye: false,
                  score: m.score,
                  pinVote: m.pinVote,
                ))
            .toList();
        newData['membres'] = nouveauxMembres.map((m) => m.toJson()).toList();

        // 3. Incrémenter tourActuel (index 0-based) ou marquer cycleTermine
        //    Aligné sur : if(d.tourActuel + 1 >= d.ordre.length) d.cycleTermine = true
        //                 else d.tourActuel++
        final ordreLen = data.ordre.length;
        final prochainIndex = data.tourActuel + 1;
        final cycleTermineNow = prochainIndex >= ordreLen;
        newData['tourActuel'] = cycleTermineNow ? data.tourActuel : prochainIndex;
        newData['cycleTermine'] = cycleTermineNow;

        // 4. Historique : ajouter l'entrée du tour clôturé
        //    h.tour = numéro humain (tourActuel + 1 AVANT incrément = numerTourAffiche)
        final historique = List<Map<String, dynamic>>.from(
          (newData['historique'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ?? [],
        );
        final total = nbPayesClot * data.montant;
        historique.insert(0, {
          'tour': numerTourAffiche,
          'beneficiaire': benefNom,
          'total': total,
          'payes': nbPayesClot,
          'surTotal': data.ordre.length,
          'payesIds': payesIds,
          'par': provider.gestActifNom ?? '',
          'ref': ref,
          'date': DateTime.now().millisecondsSinceEpoch,
        });
        newData['historique'] = historique;

        // 5. Journal
        final journal = List<Map<String, dynamic>>.from(
          (newData['journal'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ?? [],
        );
        journal.insert(0, {
          'quoi': 'Tour $numerTourAffiche clôturé — décaissement de ${Formatters.montantFCFA(total)} remis à $benefNom',
          'par': provider.gestActifNom ?? '',
          'le': DateTime.now().millisecondsSinceEpoch,
          'reference': ref,
        });
        newData['journal'] = journal;

        return provider.ecrire(newData, pin);
      },
    );

    if (ok == true && context.mounted) {
      afficherToast(
        context,
        data.cycleTermine
            ? 'Cycle terminé 🎊 Chaque membre a été servi !'
            : 'Tour $numerTourAffiche clôturé avec succès.',
      );
    }
  }
}
