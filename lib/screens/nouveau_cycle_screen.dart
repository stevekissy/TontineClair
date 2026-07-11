// ─────────────────────────────────────────────────────────────────────────────
// NouveauCycleScreen — Gestion complète du nouveau cycle
//
// États gérés :
//   1. Cycle terminé, aucun vote en cours   → proposer un nouveau cycle
//   2. Vote de redémarrage ouvert           → afficher le vote + voter
//   3. Vote clos et accepté                 → configurer et démarrer
//   4. Vote clos et refusé                  → afficher le résultat
//   5. Nouveau cycle démarré                → afficher le récap du cycle
// ─────────────────────────────────────────────────────────────────────────────

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/tontine.dart';
import '../services/tontine_provider.dart';
import '../services/supabase_service.dart';
import '../services/echeance_service.dart';
import '../utils/app_colors.dart';
import '../utils/formatters.dart';
import '../widgets/app_widgets.dart';

class NouveauCycleScreen extends StatefulWidget {
  final String code;

  const NouveauCycleScreen({super.key, required this.code});

  @override
  State<NouveauCycleScreen> createState() => _NouveauCycleScreenState();
}

class _NouveauCycleScreenState extends State<NouveauCycleScreen> {
  bool _enChargement = false;
  String? _erreur;
  String? _succes;

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<TontineProvider>();
    final tontine = provider.courante;

    if (tontine == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final data = tontine.data;
    final estGest = provider.estDebloque;
    final vote = data.voteRedemarrage;

    return Scaffold(
      backgroundColor: AppColors.fondPapier,
      body: SafeArea(
        child: Column(
          children: [
            _EnTete(code: widget.code),
            Expanded(
              child: RefreshIndicator(
                onRefresh: () => provider.chargerTontine(widget.code),
                child: SingleChildScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // ── Messages feedback ──
                      if (_erreur != null) ...[
                        const SizedBox(height: 12),
                        _BandeauMessage(
                          texte: _erreur!,
                          type: 'erreur',
                          onDismiss: () => setState(() => _erreur = null),
                        ),
                      ],
                      if (_succes != null) ...[
                        const SizedBox(height: 12),
                        _BandeauMessage(
                          texte: _succes!,
                          type: 'succes',
                          onDismiss: () => setState(() => _succes = null),
                        ),
                      ],

                      const SizedBox(height: 20),

                      // ── État 0 : Tontine en attente de démarrage ──
                      // (ordre vide, jamais lancée — PAS un cycle terminé)
                      if (data.cycleEnAttente)
                        _EtatEnAttente(data: data, estGest: estGest)

                      // ── État 1 : Cycle en cours ──
                      else if (data.cycleActif)
                        _EtatCycleEnCours(data: data)

                      // ── État 2 : Cycle terminé, peut proposer ──
                      else if (data.cycleTermine && (vote == null || data.peutProposerNouveauCycle))
                        _EtatPeutProposer(
                          data: data,
                          estGest: estGest,
                          enChargement: _enChargement,
                          onProposer: estGest ? () => _proposerCycle(provider, data) : null,
                        )

                      // ── État 3 : Vote ouvert ──
                      else if (vote != null && !vote.clos)
                        _EtatVoteOuvert(
                          data: data,
                          vote: vote,
                          tontineCode: widget.code,
                          estGest: estGest,
                          enChargement: _enChargement,
                          onVoter: (membreId) => _voter(context, provider, data, vote, membreId),
                          onClore: estGest ? () => _cloreVote(provider, vote) : null,
                          onRefresh: () => provider.chargerTontine(widget.code),
                        )

                      // ── État 4 : Vote clos, accepté → configurer et démarrer ──
                      else if (vote != null && vote.clos && vote.adopte == true)
                        _EtatVoteAccepte(
                          data: data,
                          vote: vote,
                          estGest: estGest,
                          enChargement: _enChargement,
                          onDemarrer: estGest
                              ? (cfg) => _demarrerCycle(provider, vote, cfg)
                              : null,
                        )

                      // ── État 5 : Vote clos, refusé ──
                      else if (vote != null && vote.clos && vote.adopte != true)
                        _EtatVoteRefuse(
                          data: data,
                          vote: vote,
                          estGest: estGest,
                          enChargement: _enChargement,
                          onReproposer: estGest ? () => _proposerCycle(provider, data) : null,
                        )

                      // ── Fallback ──
                      else
                        const SizedBox.shrink(),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Actions ──────────────────────────────────────────────────────────────

  Future<void> _proposerCycle(TontineProvider provider, TontineData data) async {
    final pin = await _demanderPin(
      titre: 'Proposer un nouveau cycle',
      sousTitre: 'Confirme avec ton PIN pour ouvrir le vote.',
      recap: [
        (label: 'Tontine', valeur: data.nom),
        (label: 'Action', valeur: 'Créer un vote de redémarrage'),
      ],
    );
    if (pin == null || !mounted) return;

    setState(() { _enChargement = true; _erreur = null; });
    final result = await provider.proposerNouveauCycle(pin: pin);
    if (!mounted) return;
    setState(() => _enChargement = false);

    if (result['ok'] == true) {
      setState(() => _succes = '✅ Vote de redémarrage ouvert ! Les membres peuvent maintenant voter.');
    } else {
      setState(() => _erreur = result['erreur'] as String? ?? 'Erreur inconnue.');
    }
  }

  Future<void> _voter(
    BuildContext context,
    TontineProvider provider,
    TontineData data,
    Vote vote,
    String membreId,
  ) async {
    // Trouver le membre
    final membre = data.membres.where((m) => m.id == membreId).firstOrNull;
    if (membre == null) return;

    // Vérifier s'il a déjà voté
    if (data.aMemberVoteRedemarrage(membreId)) {
      if (mounted) afficherToast(context, 'Vous avez déjà voté.', estErreur: true);
      return;
    }

    // Choisir son vote
    String? choix = await _choisirChoix(context, membre.nom);
    if (choix == null || !mounted) return;

    // PIN du membre
    final pinCtrl = TextEditingController();
    final pinOk = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('PIN de ${membre.nom}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Confirmer ton vote : ${_labelChoix(choix)}'),
            const SizedBox(height: 12),
            TextField(
              controller: pinCtrl,
              obscureText: true,
              keyboardType: TextInputType.number,
              maxLength: 6,
              decoration: const InputDecoration(
                hintText: 'Ton PIN membre',
                counterText: '',
              ),
              autofocus: true,
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annuler')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Voter ${_labelChoix(choix)}', style: const TextStyle(fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );

    if (pinOk != true || !mounted) return;

    setState(() => _enChargement = true);
    try {
      final res = await SupabaseService.voter(
        code: widget.code,
        voteId: vote.id,
        membreId: membreId,
        pinMembre: pinCtrl.text.trim(),
        choix: choix,
        appareil: kIsWeb ? 'Web' : 'Mobile',
      );
      if (!mounted) return;
      if (res == 'OK') {
        setState(() => _succes = '✅ Vote enregistré : ${_labelChoix(choix)}');
        await provider.chargerTontine(widget.code);
      } else {
        setState(() => _erreur = 'Erreur : $res');
      }
    } catch (e) {
      if (mounted) setState(() => _erreur = 'Erreur : $e');
    } finally {
      if (mounted) setState(() => _enChargement = false);
    }
  }

  Future<void> _cloreVote(TontineProvider provider, Vote vote) async {
    final pin = await _demanderPin(
      titre: 'Clôturer le vote',
      sousTitre: 'Le résultat sera calculé immédiatement.',
      recap: [(label: 'Vote', valeur: vote.question)],
    );
    if (pin == null || !mounted) return;

    setState(() { _enChargement = true; _erreur = null; });
    final result = await provider.cloreVoteRedemarrage(voteId: vote.id, pin: pin);
    if (!mounted) return;
    setState(() => _enChargement = false);

    if (result['ok'] == true) {
      final adopte = result['adopte'] as bool? ?? false;
      setState(() => _succes = adopte
          ? '✅ Vote ACCEPTÉ — Vous pouvez maintenant démarrer le nouveau cycle.'
          : '❌ Vote REFUSÉ — Le cycle ne sera pas redémarré.');
    } else {
      setState(() => _erreur = result['erreur'] as String? ?? 'Erreur inconnue.');
    }
  }

  Future<void> _demarrerCycle(
    TontineProvider provider,
    Vote vote,
    _ConfigNouveauCycle cfg,
  ) async {
    final pin = await _demanderPin(
      titre: 'Démarrer le cycle ${(provider.courante?.data.cycleNumero ?? 1) + 1}',
      sousTitre: 'Confirme la configuration avec ton PIN.',
      recap: [
        (label: 'Montant', valeur: Formatters.montantFCFA(cfg.montant)),
        (label: 'Périodicité', valeur: EcheanceService.labelPeriode(cfg.periodicite)),
        if (cfg.echeance != null)
          (label: '1ère échéance', valeur: Formatters.dateFormatee(cfg.echeance)),
        (label: 'Ordre', valeur: Formatters.methodeOrdre(cfg.methodeOrdre)),
      ],
    );
    if (pin == null || !mounted) return;

    setState(() { _enChargement = true; _erreur = null; });
    final result = await provider.demarrerNouveauCycle(
      voteId: vote.id,
      pin: pin,
      montant: cfg.montant,
      periodicite: cfg.periodicite,
      echeance: cfg.echeance?.toIso8601String(),
      methodeOrdre: cfg.methodeOrdre,
    );
    if (!mounted) return;
    setState(() => _enChargement = false);

    if (result['ok'] == true) {
      final cycleNum = result['cycleNum'] as int? ?? 2;
      setState(() => _succes = '🎉 Cycle $cycleNum démarré ! Tour 1 en cours.');
    } else {
      setState(() => _erreur = result['erreur'] as String? ?? 'Erreur inconnue.');
    }
  }

  // ── Helpers UI ────────────────────────────────────────────────────────────

  Future<String?> _demanderPin({
    required String titre,
    required String sousTitre,
    required List<({String label, String valeur})> recap,
  }) {
    return afficherModalePin(
      context,
      titre: titre,
      sousTitre: sousTitre,
      recap: recap,
      onValider: (pin) async => true,
    ).then((ok) async {
      if (ok != true) return null;
      // Demander le PIN séparément
      final ctrl = TextEditingController();
      if (!mounted) return null;
      return showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(titre),
          content: TextField(
            controller: ctrl,
            obscureText: true,
            keyboardType: TextInputType.number,
            maxLength: 6,
            decoration: const InputDecoration(hintText: 'PIN gestionnaire', counterText: ''),
            autofocus: true,
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annuler')),
            TextButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('Confirmer', style: TextStyle(fontWeight: FontWeight.w700)),
            ),
          ],
        ),
      );
    });
  }

  Future<String?> _choisirChoix(BuildContext context, String nomMembre) {
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Vote de $nomMembre'),
        content: const Text('Souhaitez-vous recommencer un nouveau cycle de tontine ?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'oui'),
            style: TextButton.styleFrom(foregroundColor: AppColors.succes),
            child: const Text('✅ Oui'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'non'),
            style: TextButton.styleFrom(foregroundColor: AppColors.alerte),
            child: const Text('❌ Non'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'abstention'),
            style: TextButton.styleFrom(foregroundColor: AppColors.texteDoux),
            child: const Text('🤷 Abstention'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Annuler'),
          ),
        ],
      ),
    );
  }

  String _labelChoix(String choix) {
    switch (choix) {
      case 'oui':        return '✅ Oui';
      case 'non':        return '❌ Non';
      case 'abstention': return '🤷 Abstention';
      default:           return choix;
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Widgets internes
// ─────────────────────────────────────────────────────────────────────────────

class _EnTete extends StatelessWidget {
  final String code;
  const _EnTete({required this.code});

  @override
  Widget build(BuildContext context) {
    return Padding(
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
    );
  }
}

// ── État 1 : Cycle en cours ──────────────────────────────────────────────────
// ─── État 0 : Tontine en attente de démarrage ────────────────────────────────
// Affichée quand la tontine vient d'être créée mais le premier cycle
// n'a pas encore démarré (ordre de passage non défini).
class _EtatEnAttente extends StatelessWidget {
  final TontineData data;
  final bool estGest;
  const _EtatEnAttente({required this.data, required this.estGest});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        CarteTC(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: AppColors.encre.withValues(alpha: 0.08),
                      shape: BoxShape.circle,
                    ),
                    child: const Center(child: Text('⏳', style: TextStyle(fontSize: 20))),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Tontine en attente de démarrage',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 16,
                            color: AppColors.encre,
                          ),
                        ),
                        Text(
                          'Cycle N°1 — ${data.membres.length} membre${data.membres.length > 1 ? 's' : ''}',
                          style: TextStyle(fontSize: 12, color: AppColors.texteDoux),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              const Divider(height: 1),
              const SizedBox(height: 16),
              Text(
                'La tontine a été créée avec succès. Pour lancer le premier cycle :',
                style: TextStyle(fontSize: 14, color: AppColors.encre),
              ),
              const SizedBox(height: 12),
              _EtapeInfo(
                numero: '1',
                texte: 'Aller dans l\'onglet "Tirage" pour définir l\'ordre de passage des membres.',
              ),
              const SizedBox(height: 8),
              _EtapeInfo(
                numero: '2',
                texte: 'Configurer l\'échéance du premier tour dans "Cotisations".',
              ),
              const SizedBox(height: 8),
              _EtapeInfo(
                numero: '3',
                texte: 'Le premier tour démarre automatiquement dès que l\'ordre est verrouillé.',
              ),
              if (!estGest) ...[
                const SizedBox(height: 16),
                _BandeauGestRequis(),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        // Infos de la tontine
        CarteTC(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Paramètres de la tontine',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                  color: AppColors.encre,
                ),
              ),
              const SizedBox(height: 12),
              _InfoLigneCycle(
                label: 'Nom',
                valeur: data.nom,
              ),
              _InfoLigneCycle(
                label: 'Cotisation',
                valeur: '${data.montant} FCFA / ${Formatters.periodicite(data.periode)}',
              ),
              _InfoLigneCycle(
                label: 'Membres inscrits',
                valeur: '${data.membres.length} membre${data.membres.length > 1 ? 's' : ''}',
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ─── Étape numérotée (pour _EtatEnAttente) ───────────────────────────────────
class _EtapeInfo extends StatelessWidget {
  final String numero;
  final String texte;
  const _EtapeInfo({required this.numero, required this.texte});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 24,
          height: 24,
          decoration: BoxDecoration(
            color: AppColors.encre,
            shape: BoxShape.circle,
          ),
          child: Center(
            child: Text(
              numero,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            texte,
            style: TextStyle(fontSize: 13, color: AppColors.texteDoux),
          ),
        ),
      ],
    );
  }
}

class _EtatCycleEnCours extends StatelessWidget {
  final TontineData data;
  const _EtatCycleEnCours({required this.data});

  @override
  Widget build(BuildContext context) {
    return CarteTC(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppColors.succesFond,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.rotate_right, color: AppColors.succes, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Cycle en cours',
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 17,
                    color: AppColors.encre,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'Le cycle ${data.cycleNum} de « ${data.nom} » est actuellement en cours.',
            style: const TextStyle(fontSize: 14, color: AppColors.texteDoux),
          ),
          const SizedBox(height: 8),
          _InfoLigneCycle(label: 'Tour', valeur: '${data.numerTour} / ${data.ordre.length}'),
          _InfoLigneCycle(label: 'Périodicité', valeur: EcheanceService.labelPeriode(data.periode)),
          _InfoLigneCycle(
            label: 'Échéance prochaine',
            valeur: Formatters.dateFormatee(data.prochaineEcheanceDate),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: AppColors.succesFond,
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Text(
              'Le bouton « Proposer un nouveau cycle » apparaîtra automatiquement quand tous les membres auront reçu leur cagnotte.',
              style: TextStyle(fontSize: 12.5, color: AppColors.succes),
            ),
          ),
        ],
      ),
    );
  }
}

// ── État 2 : Peut proposer ───────────────────────────────────────────────────
class _EtatPeutProposer extends StatelessWidget {
  final TontineData data;
  final bool estGest;
  final bool enChargement;
  final VoidCallback? onProposer;

  const _EtatPeutProposer({
    required this.data,
    required this.estGest,
    required this.enChargement,
    this.onProposer,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Bannière "Cycle terminé"
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [AppColors.encre, Color(0xFF2A3F6F)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '🎉 Cycle terminé !',
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 22,
                  color: AppColors.or,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Tous les membres de « ${data.nom} » ont reçu leur cagnotte.',
                style: const TextStyle(fontSize: 14, color: Colors.white70),
              ),
              const SizedBox(height: 12),
              Text(
                'Cycle ${data.cycleNum} · ${data.ordre.length} tour${data.ordre.length > 1 ? 's' : ''} · ${EcheanceService.labelPeriode(data.periode)}',
                style: const TextStyle(fontSize: 13, color: Colors.white54),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        // Historique du cycle
        if (data.historique.isNotEmpty) ...[
          const Text(
            'Récapitulatif du cycle',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15, color: AppColors.encre),
          ),
          const SizedBox(height: 8),
          CarteTC(
            child: Column(
              children: data.historique.take(10).map((h) {
                final tour = (h['tour'] as num?)?.toInt() ?? '?';
                final benef = h['beneficiaire'] as String? ?? h['membre'] as String? ?? '?';
                final montant = (h['totalRecu'] as num?)?.toInt()
                    ?? (h['total'] as num?)?.toInt()
                    ?? data.membres.length * data.montant;
                final dateRaw = h['date'];
                DateTime? dateD;
                if (dateRaw is int) dateD = DateTime.fromMillisecondsSinceEpoch(dateRaw);
                else if (dateRaw is String) dateD = DateTime.tryParse(dateRaw);
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Row(
                    children: [
                      Container(
                        width: 26,
                        height: 26,
                        decoration: BoxDecoration(
                          color: AppColors.or.withValues(alpha: 0.15),
                          shape: BoxShape.circle,
                        ),
                        child: Center(
                          child: Text(
                            '$tour',
                            style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: AppColors.encre,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          benef,
                          style: const TextStyle(fontSize: 13.5, color: AppColors.encre),
                        ),
                      ),
                      Text(
                        Formatters.montantFCFA(montant),
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: AppColors.succes,
                        ),
                      ),
                      if (dateD != null) ...[
                        const SizedBox(width: 6),
                        Text(
                          Formatters.dateFormatee(dateD),
                          style: const TextStyle(fontSize: 11, color: AppColors.texteDoux),
                        ),
                      ],
                    ],
                  ),
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 16),
        ],

        // Message + bouton
        CarteTC(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Proposer un nouveau cycle',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 16,
                  color: AppColors.encre,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Le nouveau cycle ne démarrera pas automatiquement. '
                'Un vote des membres est requis pour confirmer le redémarrage.',
                style: TextStyle(fontSize: 13.5, color: AppColors.texteDoux),
              ),
              const SizedBox(height: 16),
              if (!estGest)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: AppColors.fondSecondaire,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppColors.lignes),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.lock_outline, size: 16, color: AppColors.texteDoux),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Connectez-vous en tant que gestionnaire pour proposer un nouveau cycle.',
                          style: TextStyle(fontSize: 13, color: AppColors.texteDoux),
                        ),
                      ),
                    ],
                  ),
                )
              else
                BtnPrincipal(
                  label: '🔄 Proposer un nouveau cycle',
                  onTap: onProposer,
                  loading: enChargement,
                ),
            ],
          ),
        ),
      ],
    );
  }
}

// ── État 3 : Vote ouvert ──────────────────────────────────────────────────────
class _EtatVoteOuvert extends StatelessWidget {
  final TontineData data;
  final Vote vote;
  final String tontineCode;
  final bool estGest;
  final bool enChargement;
  final void Function(String membreId) onVoter;
  final VoidCallback? onClore;
  final VoidCallback onRefresh;

  const _EtatVoteOuvert({
    required this.data,
    required this.vote,
    required this.tontineCode,
    required this.estGest,
    required this.enChargement,
    required this.onVoter,
    this.onClore,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    final decompte = data.decompteRedemarrage;
    final nbVotes = decompte['oui']! + decompte['non']! + decompte['abstention']!;
    final nbTotal = data.membresActifs.length;
    final nbRestants = data.nbMembresRestantAVoterRedemarrage;
    final membresNonVotes = data.membresNonVotesRedemarrage;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Titre
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppColors.encre,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: AppColors.or.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Text(
                      'VOTE OUVERT',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: AppColors.or,
                        letterSpacing: 0.8,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                vote.question,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 16,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Proposé par ${vote.createur} · ${Formatters.dateFormatee(DateTime.tryParse(vote.dateCreation))}',
                style: const TextStyle(fontSize: 12, color: Colors.white54),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        // Décompte
        CarteTC(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Résultats en temps réel',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15, color: AppColors.encre),
              ),
              const SizedBox(height: 12),
              _BarreVote(label: '✅ Oui', nb: decompte['oui']!, total: nbTotal, couleur: AppColors.succes),
              const SizedBox(height: 8),
              _BarreVote(label: '❌ Non', nb: decompte['non']!, total: nbTotal, couleur: AppColors.alerte),
              const SizedBox(height: 8),
              _BarreVote(label: '🤷 Abstention', nb: decompte['abstention']!, total: nbTotal, couleur: AppColors.texteDoux),
              const Divider(height: 20, color: AppColors.lignes),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('$nbVotes / $nbTotal ont voté', style: const TextStyle(fontSize: 13, color: AppColors.texteDoux)),
                  Text('$nbRestants restant${nbRestants > 1 ? 's' : ''}', style: const TextStyle(fontSize: 13, color: AppColors.or)),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        // Membres qui peuvent voter
        if (membresNonVotes.isNotEmpty) ...[
          const Text(
            'Voter',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15, color: AppColors.encre),
          ),
          const SizedBox(height: 8),
          const ChampAide(texte: 'Chaque membre vote une seule fois avec son PIN. Le vote est irréversible.'),
          const SizedBox(height: 8),
          ...membresNonVotes.map((m) => Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: GestureDetector(
              onTap: enChargement ? null : () => onVoter(m.id),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppColors.lignes),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: AppColors.encreDoux.withValues(alpha: 0.1),
                        shape: BoxShape.circle,
                      ),
                      child: Center(
                        child: Text(
                          m.nom.isNotEmpty ? m.nom[0].toUpperCase() : '?',
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 13,
                            color: AppColors.encre,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(m.nom, style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 14)),
                    ),
                    const Text('Voter →', style: TextStyle(fontSize: 13, color: AppColors.encre, fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
            ),
          )),
          const SizedBox(height: 8),
        ],

        // Membres ayant déjà voté
        if (data.nbMembresVotesRedemarrage > 0) ...[
          Text(
            'Ont déjà voté (${data.nbMembresVotesRedemarrage})',
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: AppColors.texteDoux),
          ),
          const SizedBox(height: 6),
          CarteTC(
            child: Column(
              children: data.membresActifs
                  .where((m) => data.aMemberVoteRedemarrage(m.id))
                  .map((m) {
                    final choix = vote.voix[m.id]?.toString() ?? '';
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          Expanded(child: Text(m.nom, style: const TextStyle(fontSize: 13.5))),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: _couleurChoix(choix).withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              _labelChoixCourt(choix),
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: _couleurChoix(choix),
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  }).toList(),
            ),
          ),
          const SizedBox(height: 16),
        ],

        // Bouton clôturer (gestionnaire seulement)
        if (estGest)
          BtnSecondaire(
            label: 'Clôturer le vote',
            onTap: enChargement ? null : onClore,
          ),
      ],
    );
  }

  Color _couleurChoix(String choix) {
    switch (choix) {
      case 'oui':        return AppColors.succes;
      case 'non':        return AppColors.alerte;
      case 'abstention': return AppColors.texteDoux;
      default:           return AppColors.texteDoux;
    }
  }

  String _labelChoixCourt(String choix) {
    switch (choix) {
      case 'oui':        return '✅ Oui';
      case 'non':        return '❌ Non';
      case 'abstention': return '🤷 Abs.';
      default:           return choix;
    }
  }
}

// ── État 4 : Vote accepté → configurer ───────────────────────────────────────

class _ConfigNouveauCycle {
  int montant;
  String periodicite;
  DateTime? echeance;
  String methodeOrdre;

  _ConfigNouveauCycle({
    required this.montant,
    required this.periodicite,
    this.echeance,
    required this.methodeOrdre,
  });
}

class _EtatVoteAccepte extends StatefulWidget {
  final TontineData data;
  final Vote vote;
  final bool estGest;
  final bool enChargement;
  final void Function(_ConfigNouveauCycle cfg)? onDemarrer;

  const _EtatVoteAccepte({
    required this.data,
    required this.vote,
    required this.estGest,
    required this.enChargement,
    this.onDemarrer,
  });

  @override
  State<_EtatVoteAccepte> createState() => _EtatVoteAccepteState();
}

class _EtatVoteAccepteState extends State<_EtatVoteAccepte> {
  late _ConfigNouveauCycle _config;
  late TextEditingController _montantCtrl;

  @override
  void initState() {
    super.initState();
    _config = _ConfigNouveauCycle(
      montant: widget.data.montant,
      periodicite: widget.data.periode,
      methodeOrdre: widget.data.methodeOrdre,
    );
    _montantCtrl = TextEditingController(text: '${widget.data.montant}');
  }

  @override
  void dispose() {
    _montantCtrl.dispose();
    super.dispose();
  }

  Future<void> _choisirDate() async {
    final now = DateTime.now();
    final DateTime? picked;
    if (kIsWeb) {
      picked = await showDatePicker(
        context: context,
        initialDate: now.add(const Duration(days: 1)),
        firstDate: now,
        lastDate: now.add(const Duration(days: 365 * 5)),
        builder: (ctx, child) => Theme(
          data: Theme.of(ctx).copyWith(
            colorScheme: const ColorScheme.light(
              primary: AppColors.encre,
              onPrimary: Colors.white,
              surface: Colors.white,
              onSurface: AppColors.encre,
            ),
          ),
          child: child!,
        ),
      );
    } else {
      picked = await showDatePicker(
        context: context,
        initialDate: now.add(const Duration(days: 1)),
        firstDate: now,
        lastDate: now.add(const Duration(days: 365 * 5)),
        locale: const Locale('fr', 'FR'),
        builder: (ctx, child) => Theme(
          data: Theme.of(ctx).copyWith(
            colorScheme: const ColorScheme.light(
              primary: AppColors.encre,
              onPrimary: Colors.white,
              surface: Colors.white,
              onSurface: AppColors.encre,
            ),
          ),
          child: child!,
        ),
      );
    }
    if (picked != null && mounted) {
      setState(() => _config.echeance = picked);
    }
  }

  @override
  Widget build(BuildContext context) {
    final decompte = widget.data.decompteRedemarrage;
    final nouveauCycleNum = widget.data.cycleNumero + 1;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Bannière accepté
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppColors.succesFond,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.succes.withValues(alpha: 0.3)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('✅ Vote ACCEPTÉ', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15, color: AppColors.succes)),
              const SizedBox(height: 4),
              Text(
                '${decompte['oui']} oui · ${decompte['non']} non · ${decompte['abstention']} abstention',
                style: const TextStyle(fontSize: 13, color: AppColors.succes),
              ),
              const SizedBox(height: 4),
              Text(
                'Les membres ont approuvé le cycle $nouveauCycleNum.',
                style: const TextStyle(fontSize: 13, color: AppColors.succes),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        // Configuration du nouveau cycle
        if (widget.estGest) ...[
          const Text(
            'Configurer le nouveau cycle',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16, color: AppColors.encre),
          ),
          const SizedBox(height: 8),
          const ChampAide(texte: 'Confirmez ou modifiez la configuration du cycle. Les membres et l\'historique sont préservés.'),
          const SizedBox(height: 12),
          CarteTC(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const ChampLabel(label: 'Montant de cotisation (FCFA)'),
                TextField(
                  controller: _montantCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(hintText: 'Ex : 10 000'),
                  onChanged: (v) {
                    final m = int.tryParse(v);
                    if (m != null) setState(() => _config.montant = m);
                  },
                ),
                const SizedBox(height: 12),
                const ChampLabel(label: 'Périodicité'),
                DropdownButtonFormField<String>(
                  value: _config.periodicite,
                  decoration: const InputDecoration(),
                  items: EcheanceService.periodiciteOptions.entries.map((e) =>
                    DropdownMenuItem(value: e.key, child: Text(e.value)),
                  ).toList(),
                  onChanged: (v) => setState(() => _config.periodicite = v!),
                ),
                const SizedBox(height: 12),
                const ChampLabel(label: 'Première échéance (facultatif)'),
                if (_config.echeance == null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(
                      'Auto : ${Formatters.dateFormatee(EcheanceService.prochaineEcheance(periode: _config.periodicite))}',
                      style: const TextStyle(fontSize: 12, color: AppColors.texteDoux, fontStyle: FontStyle.italic),
                    ),
                  ),
                Row(
                  children: [
                    Expanded(
                      child: GestureDetector(
                        onTap: _choisirDate,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            border: Border.all(color: _config.echeance != null ? AppColors.encre : AppColors.lignes, width: _config.echeance != null ? 2 : 1.5),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            children: [
                              Text(
                                _config.echeance == null
                                    ? 'Choisir une date...'
                                    : Formatters.dateFormatee(_config.echeance),
                                style: TextStyle(
                                  fontSize: 15.5,
                                  color: _config.echeance == null ? AppColors.texteDoux : AppColors.encre,
                                  fontWeight: _config.echeance != null ? FontWeight.w600 : FontWeight.normal,
                                ),
                              ),
                              const Spacer(),
                              const Icon(Icons.calendar_today, size: 18, color: AppColors.texteDoux),
                            ],
                          ),
                        ),
                      ),
                    ),
                    if (_config.echeance != null) ...[
                      const SizedBox(width: 8),
                      GestureDetector(
                        onTap: () => setState(() => _config.echeance = null),
                        child: Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: AppColors.fondSecondaire,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: AppColors.lignes),
                          ),
                          child: const Icon(Icons.clear, size: 18, color: AppColors.texteDoux),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 12),
                const ChampLabel(label: "Méthode d'ordre"),
                DropdownButtonFormField<String>(
                  value: _config.methodeOrdre,
                  decoration: const InputDecoration(),
                  items: const [
                    DropdownMenuItem(value: 'tirage', child: Text('🎲 Tirage au sort')),
                    DropdownMenuItem(value: 'rotation', child: Text('Rotation classique')),
                    DropdownMenuItem(value: 'manuel', child: Text('Ordre manuel')),
                  ],
                  onChanged: (v) => setState(() => _config.methodeOrdre = v!),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          BtnPrincipal(
            label: '🚀 Démarrer le cycle $nouveauCycleNum',
            onTap: widget.onDemarrer != null && !widget.enChargement
                ? () => widget.onDemarrer!(_config)
                : null,
            loading: widget.enChargement,
          ),
        ] else
          const _BandeauGestRequis(),
      ],
    );
  }
}

// ── État 5 : Vote refusé ──────────────────────────────────────────────────────
class _EtatVoteRefuse extends StatelessWidget {
  final TontineData data;
  final Vote vote;
  final bool estGest;
  final bool enChargement;
  final VoidCallback? onReproposer;

  const _EtatVoteRefuse({
    required this.data,
    required this.vote,
    required this.estGest,
    required this.enChargement,
    this.onReproposer,
  });

  @override
  Widget build(BuildContext context) {
    final decompte = data.decompteRedemarrage;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppColors.alerteFond,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.alerte.withValues(alpha: 0.3)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('❌ Vote REFUSÉ', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15, color: AppColors.alerte)),
              const SizedBox(height: 4),
              Text(
                '${decompte['oui']} oui · ${decompte['non']} non · ${decompte['abstention']} abstention',
                style: const TextStyle(fontSize: 13, color: AppColors.alerte),
              ),
              const SizedBox(height: 8),
              const Text(
                'La tontine reste au statut « Cycle terminé ». L\'historique est conservé.',
                style: TextStyle(fontSize: 13, color: AppColors.alerte),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        CarteTC(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Que faire maintenant ?', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15, color: AppColors.encre)),
              const SizedBox(height: 8),
              const Text(
                '• L\'historique complet du cycle est conservé.\n'
                '• Aucun nouveau cycle ne sera créé.\n'
                '• Vous pouvez soumettre une nouvelle proposition après discussion avec les membres.',
                style: TextStyle(fontSize: 13.5, color: AppColors.texteDoux, height: 1.5),
              ),
            ],
          ),
        ),
        if (estGest) ...[
          const SizedBox(height: 16),
          BtnSecondaire(
            label: '🔄 Nouvelle proposition',
            onTap: enChargement ? null : onReproposer,
          ),
        ],
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Widgets partagés
// ─────────────────────────────────────────────────────────────────────────────

class _BarreVote extends StatelessWidget {
  final String label;
  final int nb;
  final int total;
  final Color couleur;

  const _BarreVote({required this.label, required this.nb, required this.total, required this.couleur});

  @override
  Widget build(BuildContext context) {
    final pct = total == 0 ? 0.0 : nb / total;
    return Row(
      children: [
        SizedBox(width: 90, child: Text(label, style: const TextStyle(fontSize: 13.5))),
        const SizedBox(width: 8),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: pct,
              backgroundColor: couleur.withValues(alpha: 0.1),
              valueColor: AlwaysStoppedAnimation<Color>(couleur),
              minHeight: 8,
            ),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 30,
          child: Text(
            '$nb',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5, color: couleur),
            textAlign: TextAlign.right,
          ),
        ),
      ],
    );
  }
}

class _InfoLigneCycle extends StatelessWidget {
  final String label;
  final String valeur;

  const _InfoLigneCycle({required this.label, required this.valeur});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Text(label, style: const TextStyle(fontSize: 13, color: AppColors.texteDoux)),
          const Spacer(),
          Text(valeur, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.encre)),
        ],
      ),
    );
  }
}

class _BandeauMessage extends StatelessWidget {
  final String texte;
  final String type; // 'erreur' | 'succes'
  final VoidCallback onDismiss;

  const _BandeauMessage({required this.texte, required this.type, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    final isErreur = type == 'erreur';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: isErreur ? AppColors.alerteFond : AppColors.succesFond,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: isErreur ? AppColors.alerte : AppColors.succes, width: 0.5),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              texte,
              style: TextStyle(fontSize: 13, color: isErreur ? AppColors.alerte : AppColors.succes),
            ),
          ),
          GestureDetector(
            onTap: onDismiss,
            child: Icon(Icons.close, size: 16, color: isErreur ? AppColors.alerte : AppColors.succes),
          ),
        ],
      ),
    );
  }
}

class _BandeauGestRequis extends StatelessWidget {
  const _BandeauGestRequis();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.fondSecondaire,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.lignes),
      ),
      child: const Row(
        children: [
          Icon(Icons.lock_outline, size: 16, color: AppColors.texteDoux),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              'Connectez-vous en tant que gestionnaire pour démarrer le nouveau cycle.',
              style: TextStyle(fontSize: 13, color: AppColors.texteDoux),
            ),
          ),
        ],
      ),
    );
  }
}
