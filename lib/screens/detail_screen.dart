import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/tontine.dart';
import '../services/tontine_provider.dart';
import '../services/echeance_service.dart';
import '../services/supabase_service.dart';
import '../services/kyc_service.dart';
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
import 'nouveau_cycle_screen.dart';
import 'supprimer_tontine_screen.dart';
import '../utils/app_localizations.dart';
import '../services/locale_service.dart';
import 'kyc_screen.dart';
import 'securite_screen.dart';
import 'paiement_choix_screen.dart';
import 'verification_publique_screen.dart';
import 'certificat_blockchain_screen.dart';
import 'qr_tontine_screen.dart';
import '../services/blockchain_service.dart';

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
      // Premier chargement : normal (avec spinner si pas de données)
      context.read<TontineProvider>().chargerTontine(widget.code);
    });
    // Rafraîchissement automatique toutes les 30 secondes — silencieux
    // Si le réseau coupe temporairement, on garde l'écran actuel sans erreur
    _timer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) {
        context.read<TontineProvider>().rafraichirSilencieux();
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  // ── Traduction des codes RESEAU:xxx en messages lisibles ──────────────────
  static String _traduireErreur(String code) {
    switch (code) {
      case 'RESEAU:INTERNET':
        return 'Aucune connexion Internet.\nVérifiez votre Wi-Fi ou données mobiles.';
      case 'RESEAU:TIMEOUT':
        return 'Le serveur ne répond pas.\nRéessayez dans quelques instants.';
      case 'RESEAU:SSL':
        return 'Problème de connexion sécurisée.\nVérifiez votre réseau.';
      case 'RESEAU:DNS':
        return 'Impossible de joindre le serveur.\nVérifiez votre connexion Internet.';
      case 'RESEAU:CONNEXION':
        return 'Connexion refusée par le serveur.\nRéessayez plus tard.';
      case 'RESEAU:SERVEUR':
        return 'Le service est momentanément indisponible.\nRéessayez plus tard.';
      default:
        return 'Impossible de contacter le serveur.\nRéessayez plus tard.';
    }
  }

  static IconData _iconeErreur(String code) {
    if (code == 'RESEAU:INTERNET' || code == 'RESEAU:DNS') {
      return Icons.wifi_off_rounded;
    }
    if (code == 'RESEAU:TIMEOUT') return Icons.timer_off_outlined;
    if (code == 'RESEAU:SSL') return Icons.lock_outline;
    return Icons.cloud_off_rounded;
  }

  void _debloqur(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => VerrouScreen()),
    );
  }

  void _verrouiller(BuildContext context) {
    context.read<TontineProvider>().verrouiller();
    afficherToast(context, context.tr('session_terminee'));
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
      // ── Tontine supprimée : message spécifique + redirection accueil ──
      if (provider.erreur == 'TONTINE_DELETED') {
        return Scaffold(
          backgroundColor: AppColors.fondPapier,
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      color: AppColors.alerte.withValues(alpha: 0.1),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.delete_outline_rounded,
                      size: 36,
                      color: AppColors.alerte,
                    ),
                  ),
                  SizedBox(height: 20),
                  Text(
                    context.tr('tontine_supprimee'),
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      color: AppColors.encre,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Cette tontine a été supprimée par son gestionnaire '
                    'et n\'est plus accessible.',
                    style: TextStyle(
                      fontSize: 14.5,
                      color: AppColors.texte,
                      height: 1.6,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 28),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: () => Navigator.of(context)
                          .popUntil((route) => route.isFirst),
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.encre,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      child: const Text(
                        'Retour à mes tontines',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      }

      // ── Erreur réseau / serveur ──
      final msgAffiche = _traduireErreur(provider.erreur!);
      final icone = _iconeErreur(provider.erreur!);
      return Scaffold(
        backgroundColor: AppColors.fondPapier,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icone, size: 52, color: AppColors.alerte),
                const SizedBox(height: 16),
                Text(
                  msgAffiche,
                  style: const TextStyle(
                    color: AppColors.encre,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    height: 1.5,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                BtnPrincipal(
                  label: context.tr('reessayer'),
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
              onRefresh: () => provider.rafraichirSilencieux(),
              child: SingleChildScrollView(
                physics: AlwaysScrollableScrollPhysics(),
                padding: EdgeInsets.fromLTRB(16, 0, 16, 120),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Header
                    SizedBox(height: 18),
                    Row(
                      children: [
                        LogoTontineClair(),
                        Spacer(),
                        TextButton.icon(
                          onPressed: () => Navigator.of(context).pop(),
                          icon: Icon(Icons.arrow_back, size: 16),
                          label: Text(context.tr('mes_tontines')),
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
                        if (tontine.isPremium) ...[
                          const SizedBox(width: 6),
                          const BadgeProVert(),
                        ],
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
                          '· ${Formatters.montant(data.montant, devise: data.devise)}/pers.',
                          style: const TextStyle(
                            fontSize: 13.5,
                            color: AppColors.texteDoux,
                          ),
                        ),
                      ],
                    ),
                    // Bandeau échéance toujours visible (calcul auto si non définie)
                    const SizedBox(height: 8),
                    _BandeauEcheance(
                      echeance: data.echeance,
                      periode: data.periode,
                      estGest: estGest,
                      code: tontine.code,
                      gestNom: gestNom,
                    ),
                    const SizedBox(height: 16),
                    // Roue de rotation
                    RoueRotation(data: data),
                    // Badge blockchain — après la méthode d'ordre
                    const SizedBox(height: 16),
                    _BadgeBlockchain(code: tontine.code, nom: data.nom),
                    const SizedBox(height: 20),
                    // Actions rapides
                    _ActionsRapides(
                      data: data,
                      estGest: estGest,
                      isPremium: tontine.isPremium,
                      code: tontine.code,
                      gestNom: gestNom ?? '',
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
                gestNom: gestNom ?? '',
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
                padding: EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                decoration: BoxDecoration(
                  color: AppColors.encre,
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Text(
                  context.tr('verrouiller'),
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
      padding: EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.fondConsultation,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.visibility, size: 16, color: AppColors.orFonce),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              context.tr('mode_consultation'),
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
                  EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(
                color: AppColors.or,
                borderRadius: BorderRadius.circular(9),
              ),
              child: Text(
                context.tr('acces_gestionnaire'),
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

class _BandeauEcheance extends StatefulWidget {
  final String? echeance;
  final String periode;
  final bool estGest;
  final String code;
  final String? gestNom;

  const _BandeauEcheance({
    required this.echeance,
    required this.periode,
    this.estGest = false,
    this.code = '',
    this.gestNom,
  });

  @override
  State<_BandeauEcheance> createState() => _BandeauEcheanceState();
}

class _BandeauEcheanceState extends State<_BandeauEcheance> {

  // ── Dialogue calendrier avec jours restants en orange ────────────────────────
  void _afficherCalendrier(DateTime echeance) {
    showDialog(
      context: context,
      builder: (ctx) => _DialogCalendrier(echeance: echeance),
    );
  }

  @override
  Widget build(BuildContext context) {
    final prochaineDate = EcheanceService.prochaineEcheance(
      echeanceStockee: widget.echeance,
      periode: widget.periode,
    );
    final statut   = EcheanceService.statutEcheance(prochaineDate, widget.periode);
    final isRetard = statut == 'alerte';
    final delai    = EcheanceService.texteDelai(prochaineDate, periode: widget.periode);
    final periodeL = EcheanceService.labelPeriode(widget.periode);

    final couleurBandeau = isRetard ? AppColors.alerte : AppColors.succes;

    return Row(
      children: [
        // ── Bandeau échéance (non cliquable — lecture seule) ──────────────────
        Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: isRetard ? AppColors.alerteFond : AppColors.succesFond,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '📅 $periodeL · ${Formatters.dateFormatee(prochaineDate)} · $delai',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: couleurBandeau,
                    ),
                  ),
                ),

              ],
            ),
          ),
        ),
        // ── Bouton calendrier visuel (visible par tous, ouvre le dialogue) ────
        const SizedBox(width: 8),
        GestureDetector(
          onTap: () => _afficherCalendrier(prochaineDate),
          child: Container(
            padding: const EdgeInsets.all(7),
            decoration: BoxDecoration(
              color: AppColors.succes.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: AppColors.succes.withValues(alpha: 0.35),
                width: 1,
              ),
            ),
            child: Icon(
              Icons.calendar_month_outlined,
              size: 18,
              color: AppColors.succes,
            ),
          ),
        ),
      ],
    );
  }
}

// ─── Dialogue Calendrier échéance ─────────────────────────────────────────────
/// Affiche un calendrier mensuel avec les jours restants jusqu'à [echeance]
/// marqués en orange. Le mois affiché est celui de la date cible.
class _DialogCalendrier extends StatefulWidget {
  final DateTime echeance;
  const _DialogCalendrier({required this.echeance});

  @override
  State<_DialogCalendrier> createState() => _DialogCalendrierState();
}

class _DialogCalendrierState extends State<_DialogCalendrier> {
  late DateTime _moisAffiche;

  @override
  void initState() {
    super.initState();
    // Ouvrir directement sur le mois de l'échéance
    _moisAffiche = DateTime(widget.echeance.year, widget.echeance.month);
  }

  void _moisPrecedent() {
    setState(() {
      _moisAffiche = DateTime(_moisAffiche.year, _moisAffiche.month - 1);
    });
  }

  void _moisSuivant() {
    setState(() {
      _moisAffiche = DateTime(_moisAffiche.year, _moisAffiche.month + 1);
    });
  }

  @override
  Widget build(BuildContext context) {
    final today = DateTime.now();
    final todayNorm = DateTime(today.year, today.month, today.day);
    final echeanceNorm = DateTime(
      widget.echeance.year,
      widget.echeance.month,
      widget.echeance.day,
    );

    // Jours dans le mois affiché
    final premierJour = DateTime(_moisAffiche.year, _moisAffiche.month, 1);
    final dernierJour = DateTime(_moisAffiche.year, _moisAffiche.month + 1, 0);
    // Décalage : lundi = 0
    final decalage = (premierJour.weekday - 1) % 7;

    // Nom du mois en français
    const moisNoms = [
      '', 'Janvier', 'Février', 'Mars', 'Avril', 'Mai', 'Juin',
      'Juillet', 'Août', 'Septembre', 'Octobre', 'Novembre', 'Décembre',
    ];
    final titreEntete = '${moisNoms[_moisAffiche.month]} ${_moisAffiche.year}';

    // Calcul jours restants (depuis aujourd'hui jusqu'à l'échéance incluse)
    final joursRestants = echeanceNorm.difference(todayNorm).inDays;

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ── En-tête avec navigation mois ──────────────────────────────────
            Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.chevron_left),
                  onPressed: _moisPrecedent,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
                Expanded(
                  child: Text(
                    titreEntete,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                      color: AppColors.encre,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.chevron_right),
                  onPressed: _moisSuivant,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // ── Jours restants ────────────────────────────────────────────────
            if (joursRestants >= 0)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF3E0),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  joursRestants == 0
                      ? "Échéance aujourd'hui !"
                      : '$joursRestants jour${joursRestants > 1 ? 's' : ''} restant${joursRestants > 1 ? 's' : ''}',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFFE65100),
                  ),
                ),
              )
            else
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: AppColors.alerteFond,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  'Échéance dépassée (${(-joursRestants)} j)',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: AppColors.alerte,
                  ),
                ),
              ),
            const SizedBox(height: 12),
            // ── Noms des jours ────────────────────────────────────────────────
            Row(
              children: ['L', 'M', 'M', 'J', 'V', 'S', 'D'].map((j) {
                return Expanded(
                  child: Center(
                    child: Text(
                      j,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: AppColors.texteDoux,
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 6),
            // ── Grille des jours ──────────────────────────────────────────────
            Builder(builder: (ctx) {
              final cells = <Widget>[];
              // Cases vides avant le 1er
              for (var i = 0; i < decalage; i++) {
                cells.add(const SizedBox());
              }
              // Jours du mois
              for (var d = 1; d <= dernierJour.day; d++) {
                final date = DateTime(_moisAffiche.year, _moisAffiche.month, d);
                final estAujourdhui = date == todayNorm;
                final estEcheance = date == echeanceNorm;
                // Jours restants en orange = entre demain et écheance incluse
                final estRestant = date.isAfter(todayNorm) &&
                    !date.isAfter(echeanceNorm) &&
                    !estEcheance;
                final estPasse = date.isBefore(todayNorm);

                Color? fondCellule;
                Color texteCouleur;
                FontWeight poids = FontWeight.w400;
                if (estEcheance) {
                  fondCellule = const Color(0xFFE65100);
                  texteCouleur = Colors.white;
                  poids = FontWeight.w700;
                } else if (estAujourdhui) {
                  fondCellule = AppColors.encre;
                  texteCouleur = Colors.white;
                  poids = FontWeight.w700;
                } else if (estRestant) {
                  fondCellule = const Color(0xFFFFB74D);
                  texteCouleur = Colors.white;
                  poids = FontWeight.w600;
                } else if (estPasse) {
                  fondCellule = null;
                  texteCouleur = AppColors.encre.withValues(alpha: 0.30);
                } else {
                  fondCellule = null;
                  texteCouleur = AppColors.encre;
                }

                cells.add(
                  Container(
                    margin: const EdgeInsets.all(2),
                    decoration: fondCellule != null
                        ? BoxDecoration(
                            color: fondCellule,
                            shape: BoxShape.circle,
                          )
                        : null,
                    child: Center(
                      child: Text(
                        '$d',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: poids,
                          color: texteCouleur,
                        ),
                      ),
                    ),
                  ),
                );
              }

              return GridView.count(
                crossAxisCount: 7,
                shrinkWrap: true,
                physics: NeverScrollableScrollPhysics(),
                childAspectRatio: 1,
                children: cells,
              );
            }),
            SizedBox(height: 12),
            // ── Légende ───────────────────────────────────────────────────────
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _LegendePuce(couleur: AppColors.encre, label: "Aujourd'hui"),
                SizedBox(width: 12),
                _LegendePuce(
                    couleur: Color(0xFFFFB74D),
                    label: context.tr('jours_restants')),
                SizedBox(width: 12),
                _LegendePuce(
                    couleur: Color(0xFFE65100), label: 'Échéance'),
              ],
            ),
            SizedBox(height: 8),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(context.tr('fermer')),
            ),
          ],
        ),
      ),
    );
  }
}

class _LegendePuce extends StatelessWidget {
  final Color couleur;
  final String label;

  const _LegendePuce({
    required this.couleur,
    required this.label,
  });

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
            shape: BoxShape.circle,
            border: Border.all(
              color: AppColors.encre.withValues(alpha: 0.2),
              width: 0.5,
            ),
          ),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 10,
            color: AppColors.encre,
          ),
        ),
      ],
    );
  }
}

// ─── Actions rapides ──────────────────────────────────────────────────────────
class _ActionsRapides extends StatelessWidget {
  final TontineData data;
  final bool estGest;
  final bool isPremium;
  final String code;
  final String gestNom;

  const _ActionsRapides({
    required this.data,
    required this.estGest,
    required this.isPremium,
    required this.code,
    this.gestNom = '',
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.tr('membres_modules'),
          style: TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 18,
            color: AppColors.encre,
          ),
        ),
        SizedBox(height: 10),
        GridView.count(
          shrinkWrap: true,
          physics: NeverScrollableScrollPhysics(),
          crossAxisCount: 2,
          childAspectRatio: 1.7,
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
          children: [
            _ActionBtn(
              icon: Icons.dashboard_outlined,
              label: context.tr('tableau_de_bord'),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => DashboardScreen(code: code),
                ),
              ),
            ),
            _ActionBtn(
              icon: Icons.group_outlined,
              label: context.tr('membres'),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => MembresScreen(code: code),
                ),
              ),
            ),
            _ActionBtn(
              icon: Icons.payments_outlined,
              label: context.tr('cotisations'),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => CotisationsScreen(code: code),
                ),
              ),
            ),
            _ActionBtn(
              icon: Icons.shuffle,
              label: context.tr('tirage'),
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
              label: context.tr('caisse'),
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
                          builder: (_) => AbonnementScreen(
                            code: code,
                            montantCagnotte: data.montantCagnotte,
                            kycStatut: data.kycStatut,
                            gestNom: gestNom,
                          ),
                        ),
                      ),
            ),
            _ActionBtn(
              icon: Icons.handshake_outlined,
              label: context.tr('prets'),
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
                          builder: (_) => AbonnementScreen(
                            code: code,
                            montantCagnotte: data.montantCagnotte,
                            kycStatut: data.kycStatut,
                            gestNom: gestNom,
                          ),
                        ),
                      ),
            ),
            _ActionBtn(
              icon: Icons.how_to_vote_outlined,
              label: context.tr('votes'),
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
                          builder: (_) => AbonnementScreen(
                            code: code,
                            montantCagnotte: data.montantCagnotte,
                            kycStatut: data.kycStatut,
                            gestNom: gestNom,
                          ),
                        ),
                      ),
            ),
            _ActionBtn(
              icon: Icons.history,
              label: context.tr('journal'),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => JournalScreen(code: code),
                ),
              ),
            ),
            if (data.cycleTermine)
              _ActionBtn(
                icon: Icons.refresh_rounded,
                label: context.tr('nouveau_cycle'),
                badge: '🎉',
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => NouveauCycleScreen(code: code),
                  ),
                ),
              ),
          ],
        ),

        // ── Zone dangereuse (gestionnaire uniquement) ─────────────────
        if (estGest) ...[
          const SizedBox(height: 28),
          _ZoneDangereuse(code: code, nomTontine: data.nom),
        ],
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

// ─── Zone Dangereuse ──────────────────────────────────────────────────────────
class _ZoneDangereuse extends StatelessWidget {
  final String code;
  final String nomTontine;

  const _ZoneDangereuse({required this.code, required this.nomTontine});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // En-tête section
        Row(
          children: [
            Expanded(child: Divider(color: AppColors.alerte.withValues(alpha: 0.35))),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 10),
              child: Text(
                context.tr('zone_dangereuse'),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: AppColors.alerte.withValues(alpha: 0.8),
                  letterSpacing: 0.5,
                ),
              ),
            ),
            Expanded(child: Divider(color: AppColors.alerte.withValues(alpha: 0.35))),
          ],
        ),
        const SizedBox(height: 12),

        // Carte suppression
        Container(
          width: double.infinity,
          padding: EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppColors.alerte.withValues(alpha: 0.04),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: AppColors.alerte.withValues(alpha: 0.3),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                context.tr('supprimer_tontine'),
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: AppColors.encre,
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                'Rend la tontine inaccessible à tous les membres. '
                'Le code d\'invitation est immédiatement invalidé. '
                'L\'historique reste conservé.',
                style: TextStyle(
                  fontSize: 13,
                  color: AppColors.texteDoux,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => SupprimerTontineScreen(
                        code: code,
                        nomTontine: nomTontine,
                      ),
                    ),
                  ),
                  icon: const Icon(Icons.delete_outline_rounded, size: 17),
                  label: const Text(
                    'Supprimer la tontine',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.alerte,
                    side: BorderSide(color: AppColors.alerte.withValues(alpha: 0.6)),
                    padding: const EdgeInsets.symmetric(vertical: 11),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
      ],
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
            valeur: Formatters.montant(totalCollecte, devise: data.devise),
            couleurValeur: AppColors.succes,
          ),
          const Divider(height: 16, color: AppColors.lignes),
          _InfoLigne(
            label: 'Cagnotte totale',
            valeur: Formatters.montant(totalAttendu, devise: data.devise),
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
  final String gestNom;

  const _BarreDetail({
    required this.estGest,
    required this.isPremium,
    required this.code,
    required this.data,
    this.gestNom = '',
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
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
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
              const SizedBox(width: 8),
              // ── Menu ··· gestionnaire (Sécurité, etc.) ────────────────────
              PopupMenuButton<String>(
                icon: const Icon(
                  Icons.more_vert,
                  color: AppColors.encre,
                  size: 22,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                color: AppColors.fondPapier,
                elevation: 6,
                onSelected: (val) {
                  if (val == 'securite') {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => SecuriteScreen(
                          tontineCode: code,
                          gestNom: gestNom,
                        ),
                      ),
                    );
                  }
                },
                itemBuilder: (_) => [
                  PopupMenuItem<String>(
                    value: 'securite',
                    child: Row(
                      children: [
                        Container(
                          width: 34,
                          height: 34,
                          decoration: BoxDecoration(
                            color: AppColors.encre.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Icon(
                            Icons.security_rounded,
                            size: 18,
                            color: AppColors.encre,
                          ),
                        ),
                        const SizedBox(width: 12),
                        const Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              'Sécurité',
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 14,
                                color: AppColors.encre,
                              ),
                            ),
                            Text(
                              'Modifier le PIN',
                              style: TextStyle(
                                fontSize: 12,
                                color: AppColors.texteDoux,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _cloturerTour(BuildContext context) async {
    final provider = context.read<TontineProvider>();
    final tontine  = provider.courante!;
    final data     = tontine.data;
    final membres  = data.membres;

    // ── Vérifier que tous ont payé ─────────────────────────────────────────
    final nonPayes = membres.where((m) => !m.paye).toList();
    if (nonPayes.isNotEmpty) {
      final continuer = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppColors.fondPapier,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          title: const Text(
            '⚠️ Membres non payés',
            style: TextStyle(fontWeight: FontWeight.w700, color: AppColors.encre),
          ),
          content: Text(
            '${nonPayes.length} membre(s) n\'ont pas encore payé : '
            '${nonPayes.map((m) => m.nom).join(', ')}.\n\nConfirmer quand même la clôture ?',
            style: const TextStyle(color: AppColors.texte),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Clôturer', style: TextStyle(color: AppColors.alerte)),
            ),
          ],
        ),
      );
      if (continuer != true || !context.mounted) return;
    }

    // ── Données de base ────────────────────────────────────────────────────
    final beneficiaire     = data.beneficiaire;
    final benefId          = beneficiaire?.id ?? '';
    final benefNom         = beneficiaire?.nom ?? '—';
    final numerTourAffiche = data.numerTour;
    final ref              = Formatters.genererReference();

    final membresPayes = data.membres.where((m) => m.paye).toList();
    final payesIds     = membresPayes.isNotEmpty
        ? membresPayes.map((m) => m.id).toList()
        : data.paiements.keys.toList();
    final nbPayesClot = payesIds.isNotEmpty ? payesIds.length : data.membres.length;
    final montantVerse = data.montant * data.membres.length;
    final commission   = isPremium ? (montantVerse * 0.025).round() : 0;
    final montantNet   = montantVerse - commission;

    // ── Garde KYC — obligatoire pour les décaissements Premium ────────────
    if (isPremium && context.mounted) {
      final kycResult = await KycService.canPerformFinancialAction(
        userId:     gestNom,
        actionType: 'disbursement',
        amount:     montantNet.toDouble(),
      );
      if (!kycResult.allowed) {
        if (!context.mounted) return;
        final allerKyc = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: AppColors.fondPapier,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
            title: Row(children: [
              const Icon(Icons.verified_user_outlined, color: AppColors.or, size: 22),
              const SizedBox(width: 10),
              const Expanded(
                child: Text('Vérification d\'identité requise',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15, color: AppColors.encre)),
              ),
            ]),
            content: Text(
              kycResult.reason ??
              'Le décaissement requiert une vérification d\'identité (KYC) préalable.\n\n'
              'Complétez votre vérification d\'identité pour accéder à cette fonctionnalité.',
              style: const TextStyle(color: AppColors.texte, height: 1.5),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Plus tard', style: TextStyle(color: AppColors.texteDoux)),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.encre,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Vérifier mon identité', style: TextStyle(fontWeight: FontWeight.w700)),
              ),
            ],
          ),
        );
        if (!context.mounted) return;
        if (allerKyc == true) {
          Navigator.push(context, MaterialPageRoute(builder: (_) => KycScreen(userId: gestNom)));
        }
        return;
      }
    }

    // ── Branchement Premium / Lite ─────────────────────────────────────────
    if (!context.mounted) return;
    if (isPremium) {
      await _cloturerTourPremium(
        context:           context,
        provider:          provider,
        data:              data,
        membres:           membres,
        beneficiaire:      beneficiaire,
        benefId:           benefId,
        benefNom:          benefNom,
        numerTourAffiche:  numerTourAffiche,
        ref:               ref,
        payesIds:          payesIds,
        nbPayesClot:       nbPayesClot,
        montantVerse:      montantVerse,
        commission:        commission,
        montantNet:        montantNet,
      );
    } else {
      await _cloturerTourLite(
        context:           context,
        provider:          provider,
        data:              data,
        membres:           membres,
        benefNom:          benefNom,
        numerTourAffiche:  numerTourAffiche,
        ref:               ref,
        payesIds:          payesIds,
        nbPayesClot:       nbPayesClot,
        montantVerse:      montantVerse,
      );
    }
  }

  /// ── Clôture Lite : PIN → débite caisse → tour suivant ─────────────────────
  Future<void> _cloturerTourLite({
    required BuildContext              context,
    required TontineProvider           provider,
    required TontineData               data,
    required List<Membre>              membres,
    required String                    benefNom,
    required int                       numerTourAffiche,
    required String                    ref,
    required List<String>              payesIds,
    required int                       nbPayesClot,
    required int                       montantVerse,
  }) async {
    final ok = await afficherModalePin(
      context,
      titre:     'Clôturer le tour $numerTourAffiche',
      sousTitre: 'Cette action est définitive et déclenche le versement.',
      recap: [
        (label: 'Bénéficiaire',    valeur: benefNom),
        (label: 'Montant versé',   valeur: Formatters.montant(montantVerse, devise: data.devise)),
        (label: 'Cotisants payés', valeur: '$nbPayesClot / ${data.membres.length}'),
        (label: 'Tour',            valeur: 'N° $numerTourAffiche → N° ${numerTourAffiche + 1}'),
      ],
      onValider: (pin) async {
        final newData = _preparerNouvellesDonnees(
          data: data, membres: membres, payesIds: payesIds,
          nbPayesClot: nbPayesClot, numerTourAffiche: numerTourAffiche,
          ref: ref, gestNom: provider.gestActifNom ?? '',
          debiterCaisse: true,  // Lite : caisse débitée immédiatement
          montantVerse: montantVerse,
          benefNom: benefNom,
        );
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
      final lang      = Provider.of<LocaleService>(context, listen: false).langue.code;
      final typeNotif = data.cycleTermine ? 'decaissement_cycle_fin' : 'decaissement';
      final t         = SupabaseService.notifTexte(typeNotif, lang,
          vars: {'nom': benefNom, 'tour': numerTourAffiche.toString()});
      SupabaseService.envoyerNotification(
        code:    provider.courante!.code,
        type:    'decaissement',
        titre:   t['titre']!,
        message: t['message']!,
        donneesExtra: {'beneficiaire': benefNom},
      );
    }
  }

  /// ── Clôture Premium : formulaire Mobile Money → PIN → pending → admin valide ─
  Future<void> _cloturerTourPremium({
    required BuildContext              context,
    required TontineProvider           provider,
    required TontineData               data,
    required List<Membre>              membres,
    required Membre?                   beneficiaire,
    required String                    benefId,
    required String                    benefNom,
    required int                       numerTourAffiche,
    required String                    ref,
    required List<String>              payesIds,
    required int                       nbPayesClot,
    required int                       montantVerse,
    required int                       commission,
    required int                       montantNet,
  }) async {
    // Pré-remplir depuis le profil membre (si déjà renseigné)
    String? operateur  = beneficiaire?.operateur;
    String  numeroBenef = beneficiaire?.numeroBenef ?? '';

    // ── Étape 1 : formulaire Mobile Money ────────────────────────────────────
    const ops = ['orange', 'moov', 'mtn', 'wave'];
    final numCtrl = TextEditingController(text: numeroBenef);

    final mmOk = await showModalBottomSheet<bool>(
      context:         context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (sCtx, setSt) => Container(
          decoration: const BoxDecoration(
            color: AppColors.fondPapier,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          padding: EdgeInsets.fromLTRB(
            20, 20, 20,
            20 + MediaQuery.of(sCtx).viewInsets.bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Poignée
              Center(
                child: Container(
                  width: 40, height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.lignes,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                '💸 Décaissement — Tour',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18, color: AppColors.encre),
              ),
              const SizedBox(height: 4),
              Text(
                'Bénéficiaire : $benefNom · Tour $numerTourAffiche',
                style: const TextStyle(fontSize: 13, color: AppColors.texteDoux),
              ),
              const SizedBox(height: 16),

              // Récap montants
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.fondCode,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.lignes),
                ),
                child: Column(
                  children: [
                    _LigneRecapCloture('Montant versé',      Formatters.montant(montantVerse, devise: data.devise)),
                    _LigneRecapCloture('Frais réseau (2,5%)', '− ${Formatters.montant(commission, devise: data.devise)}', rouge: true),
                    const Divider(height: 12, color: AppColors.lignes),
                    _LigneRecapCloture('Montant net à décaisser', Formatters.montant(montantNet, devise: data.devise), gras: true),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // Opérateur
              const Text('Opérateur Mobile Money *',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.texteDoux)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: ops.map((op) {
                  final sel = operateur == op;
                  return GestureDetector(
                    onTap: () => setSt(() => operateur = op),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      decoration: BoxDecoration(
                        color: sel ? AppColors.encre : AppColors.fondCode,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: sel ? AppColors.encre : AppColors.lignes),
                      ),
                      child: Text(
                        op[0].toUpperCase() + op.substring(1),
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                          color: sel ? Colors.white : AppColors.encre,
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 12),

              // Numéro
              const Text('Numéro Mobile Money *',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.texteDoux)),
              const SizedBox(height: 6),
              TextField(
                controller: numCtrl,
                keyboardType: TextInputType.phone,
                decoration: InputDecoration(
                  hintText: 'Ex : +225 07 00 00 00',
                  filled: true,
                  fillColor: Colors.white,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: AppColors.lignes),
                  ),
                  prefixIcon: const Icon(Icons.phone_outlined, size: 18),
                ),
              ),
              const SizedBox(height: 16),

              // Bouton continuer
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.encre,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: () {
                    if (operateur == null || numCtrl.text.trim().isEmpty) {
                      ScaffoldMessenger.of(sCtx).showSnackBar(
                        const SnackBar(content: Text('Choisissez un opérateur et saisissez le numéro.')),
                      );
                      return;
                    }
                    Navigator.pop(sCtx, true);
                  },
                  child: const Text(
                    'Continuer avec le PIN',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15, color: Colors.white),
                  ),
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );

    if (mmOk != true || !context.mounted) return;
    numeroBenef = numCtrl.text.trim();

    // ── Étape 2 : confirmation PIN ───────────────────────────────────────────
    // operateur est garanti non-null ici (vérifié dans le bottom sheet avant pop)
    final String op = operateur ?? '';
    final operateurLabel = op.isEmpty ? '' : '${op[0].toUpperCase()}${op.substring(1)}';

    final ok = await afficherModalePin(
      context,
      titre:     'Confirmer la clôture',
      sousTitre: 'La demande de décaissement sera envoyée à l\'Admin.',
      recap: [
        (label: 'Bénéficiaire',               valeur: benefNom),
        (label: 'Opérateur',                  valeur: operateurLabel),
        (label: 'Numéro',                     valeur: numeroBenef),
        (label: 'Montant brut',               valeur: Formatters.montant(montantVerse, devise: data.devise)),
        (label: 'Frais réseau (2,5%)', valeur: '− ${Formatters.montant(commission, devise: data.devise)}'),
        (label: 'Montant net à décaisser',    valeur: Formatters.montant(montantNet, devise: data.devise)),
        (label: 'Tour',                       valeur: 'N° $numerTourAffiche → N° ${numerTourAffiche + 1}'),
        (label: '⚡ Mode',                    valeur: 'Paiement automatisé'),
      ],
      onValider: (pin) async {
        // ── A. Avancer le tour dans le JSON (débiter la caisse immédiatement) ──
        final newData = _preparerNouvellesDonnees(
          data: data, membres: membres, payesIds: payesIds,
          nbPayesClot: nbPayesClot, numerTourAffiche: numerTourAffiche,
          ref: ref, gestNom: provider.gestActifNom ?? '',
          debiterCaisse: true,
          montantVerse: montantVerse,
          benefNom: benefNom,
        );
        return provider.ecrire(newData, pin);
      },
    );

    if (ok == true && context.mounted) {
      // ── B. Naviguer vers CoinPayments pour le décaissement ──────────
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => PaiementChoixScreen(
            code:        provider.courante!.code,
            typeFlux:    'decaissement_cagnotte',
            montant:     montantNet,
            description: 'Cagnotte tour $numerTourAffiche → $benefNom',
            membreId:    benefId,
            membreNom:   benefNom,
            telephone:   numeroBenef,
            operateur:   op,
            numeroTour:  numerTourAffiche,
          ),
        ),
      );
    }
  }

  /// ── Helper : prépare le JSON du tour suivant (commun Lite & Premium) ────────
  Map<String, dynamic> _preparerNouvellesDonnees({
    required TontineData           data,
    required List<Membre>          membres,
    required List<String>          payesIds,
    required int                   nbPayesClot,
    required int                   numerTourAffiche,
    required String                ref,
    required String                gestNom,
    required bool                  debiterCaisse,
    required int                   montantVerse,
    required String                benefNom,
  }) {
    final newData = data.toJson();

    // 1. Réinitialiser paiements{}
    newData['paiements'] = {};

    // 2. Réinitialiser membres[].paye à false (en préservant tous les champs)
    newData['membres'] = membres.map((m) => {
      ...m.toJson(),
      'paye': false,
    }).toList();

    // 3. Avancer tourActuel ou marquer cycleTermine
    final prochainIndex   = data.tourActuel + 1;
    final cycleTermineNow = prochainIndex >= data.ordre.length;
    newData['tourActuel']   = cycleTermineNow ? data.tourActuel : prochainIndex;
    newData['cycleTermine'] = cycleTermineNow;

    // 4. Historique
    final historique = List<Map<String, dynamic>>.from(
      (newData['historique'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ?? [],
    );
    final total = nbPayesClot * data.montant;
    historique.insert(0, {
      'tour':        numerTourAffiche,
      'beneficiaire': benefNom,
      'total':       total,
      'payes':       nbPayesClot,
      'surTotal':    data.ordre.length,
      'payesIds':    payesIds,
      'par':         gestNom,
      'ref':         ref,
      'date':        DateTime.now().millisecondsSinceEpoch,
    });
    newData['historique'] = historique;

    // 5. Caisse : débiter seulement en mode Lite
    if (debiterCaisse) {
      final caisseMapRaw = newData['caisse'];
      final List<Map<String, dynamic>> caisseMvts;
      if (caisseMapRaw is Map<String, dynamic>) {
        caisseMvts = List<Map<String, dynamic>>.from(
          (caisseMapRaw['mouvements'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ?? [],
        );
      } else if (caisseMapRaw is List) {
        caisseMvts = List<Map<String, dynamic>>.from(caisseMapRaw.cast<Map<String, dynamic>>());
      } else {
        caisseMvts = [];
      }
      caisseMvts.insert(0, {
        'id':          '${ref}D',
        'type':        'decaissement',
        'montant':     total,
        'description': 'Décaissement Tour $numerTourAffiche — $benefNom',
        'gestionnaire': gestNom,
        'date':        DateTime.now().toIso8601String(),
        'reference':   ref,
      });
      newData['caisse'] = {'mouvements': caisseMvts};
    }

    // 6. Journal
    final journal = List<Map<String, dynamic>>.from(
      (newData['journal'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ?? [],
    );
    final modeStr = debiterCaisse ? 'décaissement immédiat' : 'décaissement en attente TontineClair';
    journal.insert(0, {
      'quoi':         'DECAISSEMENT — Tour $numerTourAffiche clôturé — ${Formatters.montant(montantVerse, devise: data.devise)} pour $benefNom ($modeStr)',
      'gestionnaire': gestNom,
      'quand':        DateTime.now().toIso8601String(),
      'reference':    ref,
    });
    newData['journal'] = journal;

    return newData;
  }
}

// ── Widget récap ligne pour la modale de clôture ─────────────────────────────
class _LigneRecapCloture extends StatelessWidget {
  final String label;
  final String valeur;
  final bool rouge;
  final bool gras;

  const _LigneRecapCloture(this.label, this.valeur, {this.rouge = false, this.gras = false});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: rouge ? AppColors.alerte : AppColors.texteDoux,
                fontWeight: gras ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ),
          Text(
            valeur,
            style: TextStyle(
              fontSize: 13,
              fontWeight: gras ? FontWeight.w800 : FontWeight.w600,
              color: rouge ? AppColors.alerte : AppColors.encre,
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Badge Blockchain Phase 3 — affiché dans DetailScreen sous le titre
// Charge le dernier TX on-chain et affiche un badge "Vérifié Blockchain"
// ═══════════════════════════════════════════════════════════════════════════════
class _BadgeBlockchain extends StatefulWidget {
  final String code;
  final String nom;
  const _BadgeBlockchain({required this.code, required this.nom});

  @override
  State<_BadgeBlockchain> createState() => _BadgeBlockchainState();
}

class _BadgeBlockchainState extends State<_BadgeBlockchain> {
  BlockchainEntry? _derniereTx;
  int              _totalOps   = 0;
  bool             _loading    = true;

  // ── Statut calculé depuis les TX réelles de CETTE tontine ──────────────
  // 'onchain'  : au moins 1 TX confirmed + txHash valide (66 chars)
  // 'pending'  : au moins 1 TX avec txHash mais pas encore confirmed
  // 'phase1'   : aucune TX on-chain (journal SHA-256 uniquement)
  String _statutBlockchain = 'phase1';

  @override
  void initState() {
    super.initState();
    _charger();
  }

  Future<void> _charger() async {
    try {
      // Charger toutes les entrées de cette tontine (limit 200)
      // — source unique de vérité, pas de cache, pas de champ phase global
      final toutes = await BlockchainService.lireJournal(
          tontineCode: widget.code, limit: 200);

      if (!mounted) return;

      // Calcul du statut depuis les TX réelles
      final confirme = toutes.where((e) =>
          e.estConfirme &&
          e.txHash != null &&
          e.txHash!.length == 66).toList();

      final enAttente = toutes.where((e) =>
          e.txHash != null &&
          e.txHash!.length == 66 &&
          !e.estConfirme &&
          !e.estEchec).toList();

      final String statut;
      if (confirme.isNotEmpty) {
        statut = 'onchain';
      } else if (enAttente.isNotEmpty) {
        statut = 'pending';
      } else {
        statut = 'phase1';
      }

      // Dernière TX pertinente : confirmed en priorité, sinon pending, sinon première
      final derniere = confirme.isNotEmpty
          ? confirme.first
          : (enAttente.isNotEmpty ? enAttente.first
              : (toutes.isNotEmpty ? toutes.first : null));

      setState(() {
        _totalOps          = toutes.length;
        _derniereTx        = derniere;
        _statutBlockchain  = statut;
        _loading           = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _ouvrir() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => VerificationPubliqueScreen(
          codeTontine: widget.code,
          nomTontine : widget.nom,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const SizedBox(
        height: 36,
        child: Row(
          children: [
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: AppColors.texteDoux,
              ),
            ),
            SizedBox(width: 8),
            Text('Chargement blockchain…',
                style: TextStyle(fontSize: 12, color: AppColors.texteDoux)),
          ],
        ),
      );
    }

    // Couleurs et textes selon le statut réel de la tontine
    final bool estOnChain = _statutBlockchain == 'onchain';
    final bool estPending = _statutBlockchain == 'pending';

    final Color couleurBadge = estOnChain
        ? const Color(0xFF00C853)
        : estPending
            ? const Color(0xFFFF9800)
            : AppColors.encre;

    final Color couleurFond = estOnChain
        ? const Color(0xFF00C853).withValues(alpha: 0.08)
        : estPending
            ? const Color(0xFFFF9800).withValues(alpha: 0.06)
            : AppColors.fondCode;

    final Color couleurBordure = estOnChain
        ? const Color(0xFF00C853).withValues(alpha: 0.4)
        : estPending
            ? const Color(0xFFFF9800).withValues(alpha: 0.35)
            : AppColors.lignes;

    final IconData icone = estOnChain
        ? Icons.verified
        : estPending
            ? Icons.hourglass_top_rounded
            : Icons.lock_outline;

    final String titre = estOnChain
        ? 'Verifie Blockchain — Phase 2 On-chain'
        : estPending
            ? 'Synchronisation en attente…'
            : 'Journal Blockchain — Phase 1';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: _ouvrir,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: couleurFond,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: couleurBordure),
            ),
            child: Row(
              children: [
                Icon(icone, size: 16, color: couleurBadge),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        titre,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: couleurBadge,
                        ),
                      ),
                      if (_totalOps > 0)
                        Text(
                          '$_totalOps opération${_totalOps > 1 ? "s" : ""} enregistrée${_totalOps > 1 ? "s" : ""}',
                          style: const TextStyle(
                              fontSize: 11, color: AppColors.texteDoux),
                        ),
                      if (_derniereTx != null && (estOnChain || estPending))
                        Text(
                          '${_derniereTx!.iconeMetier}  ${_derniereTx!.descriptionMetier}',
                          style: TextStyle(
                            fontSize: 10,
                            color: couleurBadge,
                            fontWeight: FontWeight.w600,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right, size: 18, color: AppColors.texteDoux),
              ],
            ),
          ),
        ),
        // ── Actions rapides Phase 4 ──────────────────────────────────────────
        if (!_loading && (_totalOps > 0 || _derniereTx != null)) ...[
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: GestureDetector(
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => CertificatBlockchainScreen(
                        codeTontine: widget.code,
                        nomTontine : widget.nom,
                      ),
                    ),
                  ),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 7),
                    decoration: BoxDecoration(
                      color: AppColors.fondCode,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppColors.lignes),
                    ),
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.workspace_premium,
                            size: 13, color: AppColors.encre),
                        SizedBox(width: 4),
                        Text('Certificat PDF',
                            style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: AppColors.encre)),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: GestureDetector(
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => QrTontineScreen(
                        codeTontine: widget.code,
                        nomTontine : widget.nom,
                      ),
                    ),
                  ),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 7),
                    decoration: BoxDecoration(
                      color: AppColors.whatsapp.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                          color: AppColors.whatsapp.withValues(alpha: 0.3)),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.qr_code,
                            size: 13,
                            color: AppColors.whatsapp.withValues(alpha: 0.9)),
                        const SizedBox(width: 4),
                        Text('QR Code',
                            style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: AppColors.whatsapp.withValues(alpha: 0.9))),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}
