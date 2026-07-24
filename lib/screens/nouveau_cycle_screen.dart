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
import '../services/blockchain_service.dart';
import '../services/devise_service.dart';
import '../services/echeance_service.dart';
import '../utils/app_colors.dart';
import '../utils/formatters.dart';
import '../widgets/app_widgets.dart';
import '../utils/app_localizations.dart';
import '../services/locale_service.dart';

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
  void initState() {
    super.initState();
    // Injecter les voix au chargement initial pour avoir les compteurs corrects
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final provider = context.read<TontineProvider>();
      await provider.injecterVoix(widget.code);
    });
  }

  Future<void> _rafraichir() async {
    final provider = context.read<TontineProvider>();
    await provider.chargerTontine(widget.code);
    if (mounted) await provider.injecterVoix(widget.code);
  }

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
                onRefresh: _rafraichir,
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

                      // ── États vote (3, 4, 5) AVANT état 2 ──────────────────
                      // PRIORITÉ : un vote actif ou clos prend le dessus sur
                      // "cycle terminé, peut proposer". Sans cela, l'État 2
                      // s'affiche même quand un vote clos+adopté attend de
                      // démarrer (peutProposerNouveauCycle retourne true si
                      // aucun vote OUVERT, mais ignore les votes clos).

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
                          onRefresh: _rafraichir,
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

                      // ── État 2 : Cycle terminé, peut proposer ──
                      // Affiché seulement si aucun vote en cours (ouvert OU clos)
                      else if (data.cycleTermine)
                        _EtatPeutProposer(
                          data: data,
                          estGest: estGest,
                          enChargement: _enChargement,
                          onProposer: estGest ? () => _proposerCycle(provider, data) : null,
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
      titre: context.tr('proposer_nouveau_cycle'),
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
      if (mounted) afficherToast(context, context.tr('deja_vote'), estErreur: true);
      return;
    }

    // Choisir son vote
    String? choix = await _choisirChoix(context, membre.nom);
    if (choix == null || !mounted || !context.mounted) return;

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
            SizedBox(height: 12),
            TextField(
              controller: pinCtrl,
              obscureText: true,
              keyboardType: TextInputType.number,
              maxLength: 6,
              decoration: InputDecoration(
                hintText: context.tr('pin_membre'),
                counterText: '',
              ),
              autofocus: true,
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(context.tr('annuler'))),
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
        // Libellé sans emoji pour éviter la double icône ("✅ Vote enregistré : ✅ Oui")
        final label = choix.toLowerCase() == 'oui'
            ? 'Oui'
            : choix.toLowerCase() == 'non'
                ? 'Non'
                : 'Abstention';
        setState(() {
          _erreur = null; // Effacer toute erreur précédente
          _succes = '✅ Vote enregistré : $label';
        });
        await provider.chargerTontine(widget.code);
        // ── Injecter les voix fraîches → notifyListeners() met à jour l'UI ──
        if (mounted) {
          await provider.injecterVoix(widget.code);
        }
      } else if (res == 'DEJA_VOTE') {
        // Pas une erreur technique — le membre avait déjà voté côté serveur
        setState(() {
          _erreur = null;
          _succes = '⚠️ Ce membre a déjà voté.';
        });
        // Recharger quand même pour mettre les compteurs à jour
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
      titre: context.tr('cloture_vote'),
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
      // ── Injecter adopte/clos directement dans le vote local ──────────────
      // Garantit l'affichage correct même si lire_tontine ne retourne pas
      // le champ adopte:bool dans le JSON votes[].
      final tontineActuelle = provider.courante;
      if (tontineActuelle != null) {
        for (final v in tontineActuelle.data.votes) {
          if (v.id == vote.id) {
            v.clos   = true;
            v.statut = 'clos';
            v.adopte = adopte;
            break;
          }
        }
      }
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
    final data = provider.courante?.data;

    // ── Gate KYC (Premium uniquement) ────────────────────────────────────────
    // La cagnotte du NOUVEAU cycle = nouveau montant × nbMembres actifs.
    // Si cette cagnotte >= 200 000 XOF et KYC absent/rejeté → on bloque.
    if (data != null && data.isPremium) {
      final nbMembres    = data.nbMembresActifs > 0 ? data.nbMembresActifs : data.membres.length;
      final nouvCagnotte = cfg.montant * nbMembres;
      final kycBloquant  = nouvCagnotte >= TontineData.kSeuilKyc && data.kycStatut != 'valide';

      if (kycBloquant) {
        final soumis = data.kycStatut == 'pending';
        if (!mounted) return;
        await showModalBottomSheet(
          context: context,
          isScrollControlled: true,
          backgroundColor: Colors.transparent,
          builder: (_) => soumis
              ? _KycEnAttenteSheet()
              : ModaleKyc(
                  code:    widget.code,
                  gestNom: provider.gestActifNom ?? '',
                ),
        );
        // Dans tous les cas on arrête ici : TontineClair doit valider avant de démarrer
        if (mounted && !soumis) {
          afficherToast(context,
            '⏳ Dossier KYC soumis — en attente de validation TontineClair.');
        }
        return;
      }
    }
    // ── Fin gate KYC ─────────────────────────────────────────────────────────

    final pin = await _demanderPin(
      titre: 'Démarrer le cycle ${(provider.courante?.data.cycleNumero ?? 1) + 1}',
      sousTitre: 'Confirme la configuration avec ton PIN.',
      recap: [
        (label: 'Montant', valeur: Formatters.montant(cfg.montant, devise: provider.courante?.data.devise ?? 'XOF')),
        (label: 'Périodicité', valeur: EcheanceService.labelPeriode(cfg.periodicite)),
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
      methodeOrdre: cfg.methodeOrdre,
    );
    if (!mounted) return;
    setState(() => _enChargement = false);

    if (result['ok'] == true) {
      final cycleNum = result['cycleNum'] as int? ?? 2;
      // ── BLOCKCHAIN : nouveau cycle démarré (non-bloquant) ─────────────────
      BlockchainService.enregistrerNouveauCycle(
        tontineCode : widget.code,
        gestionnaire: provider.gestActifNom ?? '',
        cycleNum    : cycleNum,
      ).catchError((e) {
        if (kDebugMode) debugPrint('[Blockchain] nouveau_cycle erreur: $e');
        return BlockchainResultat(ok: false, erreur: '$e', phase: 1);
      });
      // ──────────────────────────────────────────────────────────────────────
      // Retourner à l'écran précédent — le cycle est démarré
      if (mounted) {
        afficherToast(context, '🎉 Cycle $cycleNum démarré ! Tour 1 en cours.');
        final _lang = Provider.of<LocaleService>(context, listen: false).langue.code;
        final _t = SupabaseService.notifTexte('nouveau_cycle', _lang, vars: {'num': cycleNum.toString()});
        SupabaseService.envoyerNotification(
          code: widget.code,
          type: 'nouveau_cycle',
          titre: _t['titre']!,
          message: _t['message']!,
        );
        Navigator.of(context).pop();
      }
    } else {
      setState(() => _erreur = result['erreur'] as String? ?? 'Erreur inconnue.');
    }
  }

  // ── Helpers UI ────────────────────────────────────────────────────────────

  Future<String?> _demanderPin({
    required String titre,
    required String sousTitre,
    required List<({String label, String valeur})> recap,
  }) async {
    // Capturer le PIN saisi dans afficherModalePin via le callback onValider.
    // On stocke le PIN dans une variable locale et on retourne true pour fermer la modale.
    String? pinCapture;
    final ok = await afficherModalePin(
      context,
      titre: titre,
      sousTitre: sousTitre,
      recap: recap,
      onValider: (pin) async {
        if (pin.isEmpty || pin.length < 4) return false;
        pinCapture = pin;
        return true; // ferme la modale
      },
    );
    if (ok != true || pinCapture == null || pinCapture!.isEmpty) return null;
    return pinCapture;
  }

  Future<String?> _choisirChoix(BuildContext context, String nomMembre) {
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Vote de $nomMembre'),
        content: const Text('Souhaitez-vous recommencer un nouveau cycle de tontine ?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'Oui'),
            style: TextButton.styleFrom(foregroundColor: AppColors.succes),
            child: const Text('✅ Oui'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'Non'),
            style: TextButton.styleFrom(foregroundColor: AppColors.alerte),
            child: const Text('❌ Non'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'Abstention'),
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
    switch (choix.toLowerCase()) {
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
                valeur: '${Formatters.montant(data.montant, devise: data.devise)} / ${Formatters.periodicite(data.periode)}',
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
              Builder(builder: (ctx) {
                // Nombre de tours : ordre.length en priorité, sinon historique.length
                // (après un demarrer_nouveau_cycle, ordre[] est réinitialisé à [])
                final nbTours = data.ordre.isNotEmpty
                    ? data.ordre.length
                    : data.historique.length;
                return Text(
                  'Cycle ${data.cycleNum} · $nbTours tour${nbTours > 1 ? 's' : ''} · ${EcheanceService.labelPeriode(data.periode)}',
                  style: const TextStyle(fontSize: 13, color: Colors.white54),
                );
              }),
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
                        Formatters.montant(montant, devise: data.devise),
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
    switch (choix.toLowerCase()) {
      case 'oui':        return AppColors.succes;
      case 'non':        return AppColors.alerte;
      case 'abstention': return AppColors.texteDoux;
      default:           return AppColors.texteDoux;
    }
  }

  String _labelChoixCourt(String choix) {
    switch (choix.toLowerCase()) {
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
  String methodeOrdre;

  _ConfigNouveauCycle({
    required this.montant,
    required this.periodicite,
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
                ChampLabel(label: 'Montant de cotisation (${DeviseService.parCode(widget.data.devise).symbole})'),
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
                  initialValue: _config.periodicite,
                  decoration: const InputDecoration(),
                  items: EcheanceService.periodiciteOptions.entries.map((e) =>
                    DropdownMenuItem(value: e.key, child: Text(e.value)),
                  ).toList(),
                  onChanged: (v) => setState(() => _config.periodicite = v!),
                ),
                const SizedBox(height: 12),
                const ChampLabel(label: "Méthode d'ordre"),
                DropdownButtonFormField<String>(
                  initialValue: _config.methodeOrdre,
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

// ── Sheet affiché quand KYC est déjà 'pending' (en attente validation) ─────────
class _KycEnAttenteSheet extends StatelessWidget {
  const _KycEnAttenteSheet();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.fondPapier,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('⏳', style: TextStyle(fontSize: 40)),
          const SizedBox(height: 12),
          const Text(
            'KYC en attente de validation',
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 17,
              color: AppColors.encre,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Votre dossier d\'identité a été soumis et est en cours de vérification '
            'par TontineClair.\n\n'
            'Vous pourrez démarrer le nouveau cycle une fois votre KYC validé.\n'
            'Délai habituel : 24–48h.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13.5,
              color: AppColors.texteDoux,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.encre,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text('Compris',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15, color: Colors.white)),
            ),
          ),
        ],
      ),
    );
  }
}
