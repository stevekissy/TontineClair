import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/tontine.dart';
import '../services/pdf_service.dart';
import '../services/tontine_provider.dart';
import '../services/supabase_service.dart';
import '../services/blockchain_service.dart';
import '../utils/app_colors.dart';
import '../utils/formatters.dart';
import '../widgets/app_widgets.dart';
import '../utils/app_localizations.dart';
import '../services/locale_service.dart';
import '../services/feature_gate_service.dart';

class VotesScreen extends StatefulWidget {
  final String code;

  const VotesScreen({super.key, required this.code});

  @override
  State<VotesScreen> createState() => _VotesScreenState();
}

class _VotesScreenState extends State<VotesScreen> {
  // ─── Voix : chargées UNE FOIS au démarrage, rechargées après chaque vote ────
  // Clé = vote_id, valeur = liste des voix de ce vote
  Map<String, List<Map<String, dynamic>>> _voixParVote = {};
  bool _chargementVoix = true;
  String? _erreurVoix;

  @override
  void initState() {
    super.initState();
    // CRITIQUE : charger les voix AVANT le premier build, via postFrameCallback
    WidgetsBinding.instance.addPostFrameCallback((_) => _chargerVoix());
  }

  Future<void> _chargerVoix() async {
    setState(() {
      _chargementVoix = true;
      _erreurVoix = null;
    });
    try {
      final tontine = context.read<TontineProvider>().courante;
      if (tontine == null) return;
      final voix = await SupabaseService.lireVoix(tontine.code);
      final map = <String, List<Map<String, dynamic>>>{};
      for (final v in voix) {
        // Bug #1 fix : RPC retourne vote_id (snake_case)
        final voteId = v['vote_id'] as String?
            ?? v['voteId'] as String?
            ?? '';
        if (voteId.isNotEmpty) {
          map.putIfAbsent(voteId, () => []).add(v);
        }
      }
      if (mounted) setState(() => _voixParVote = map);
    } catch (e) {
      // Bug #1 fix : afficher l'erreur à l'utilisateur au lieu de l'ignorer
      if (mounted) setState(() => _erreurVoix = 'Erreur chargement votes : $e');
    } finally {
      if (mounted) setState(() => _chargementVoix = false);
    }
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
    final votes = data.votes;

    return Scaffold(
      backgroundColor: AppColors.fondPapier,
      body: SafeArea(
        child: Column(
          children: [
            // ── En-tête ────────────────────────────────────────────────────
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
            // ── Contenu ────────────────────────────────────────────────────
            Expanded(
              child: _chargementVoix
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircularProgressIndicator(
                              color: AppColors.encre, strokeWidth: 2.5),
                          SizedBox(height: 12),
                          Text(context.tr('chargement_votes'),
                              style: TextStyle(color: AppColors.texteDoux)),
                        ],
                      ),
                    )
                  : _erreurVoix != null
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.wifi_off,
                                    size: 40, color: AppColors.alerte),
                                SizedBox(height: 12),
                                Text(
                                  _erreurVoix!,
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                      color: AppColors.alerte),
                                ),
                                SizedBox(height: 16),
                                TextButton(
                                  onPressed: _chargerVoix,
                                  child: Text(context.tr('reessayer')),
                                ),
                              ],
                            ),
                          ),
                        )
                      : ListView(
                      padding: EdgeInsets.all(16),
                      children: [
                        Text(
                          context.tr('votes'),
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 28,
                            color: AppColors.encre,
                          ),
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          '1 membre = 1 voix · Irréversible · Horodaté',
                          style: TextStyle(
                              fontSize: 13.5, color: AppColors.texteDoux),
                        ),
                        SizedBox(height: 16),
                        if (estGest)
                          BtnKola(
                            label: 'Créer un vote',
                            icon: Icons.add,
                            onTap: () => _creerVote(context, provider, data),
                          ),
                        SizedBox(height: 16),
                        if (votes.isEmpty)
                          Center(
                            child: Padding(
                              padding: EdgeInsets.all(24),
                              child: Text(
                                context.tr('aucun_vote'),
                                style: TextStyle(color: AppColors.texteDoux),
                              ),
                            ),
                          )
                        else
                          ...votes.reversed.map(
                            (v) => _CarteVote(
                              vote: v,
                              voix: _voixParVote[v.id] ?? [],
                              ordre: data.ordre,
                              membres: data.membresActifs, // SOURCE UNIQUE : fallback si IDs divergents
                              estGest: estGest,
                              code: tontine.code,
                              nomTontine: data.nom,
                              onVoter: () =>
                                  _voter(context, provider, data, v),
                              onClore: estGest && !v.clos
                                  ? () => _cloreVote(
                                      context, provider, data, v)
                                  : null,
                              onRecharger: _chargerVoix,
                              onExporterPdf: v.clos
                                  ? () => PdfService.exporterPvVote(
                                        tontine: tontine,
                                        vote: v,
                                        voixDetaillees: _voixParVote[v.id] ?? [],
                                        nomGestionnaire:
                                            provider.gestActifNom ?? '',
                                        langueCode: Provider.of<LocaleService>(context, listen: false).langue.code,
                                      )
                                  : null,
                            ),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  // ─── Créer un vote ─────────────────────────────────────────────────────────

  Future<void> _creerVote(
    BuildContext context,
    TontineProvider provider,
    TontineData data,
  ) async {
    String type = 'libre';
    final questionCtrl = TextEditingController();
    final nouveauNomCtrl = TextEditingController();

    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.fondPapier,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 16,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
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
                SizedBox(height: 16),
                Text(
                  context.tr('nouveau_vote'),
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 20,
                    color: AppColors.encre,
                  ),
                ),
                ChampLabel(label: context.tr('type_vote')),
                DropdownButtonFormField<String>(
                  initialValue: type,
                  decoration: InputDecoration(),
                  items: [
                    DropdownMenuItem(value: 'libre', child: Text(context.tr('vote_libre'))),
                    DropdownMenuItem(
                        value: 'admission',
                        child: Text("Admission d'un nouveau membre")),
                    DropdownMenuItem(
                        value: 'retirage',
                        child: Text("Retirage de l'ordre de passage")),
                  ],
                  onChanged: (v) => setS(() => type = v!),
                ),
                ChampLabel(label: context.tr('question_vote')),
                TextField(
                  controller: questionCtrl,
                  maxLength: 150,
                  decoration: InputDecoration(
                    hintText: 'Ex : Accepter Koua comme nouveau membre ?',
                  ),
                ),
                if (type == 'admission') ...[
                  ChampLabel(label: context.tr('nouveau_membre')),
                  TextField(
                    controller: nouveauNomCtrl,
                    maxLength: 30,
                    decoration: InputDecoration(hintText: 'Ex : Koua M.'),
                  ),
                ],
                SizedBox(height: 16),
                BtnPrincipal(
                  label: context.tr('ouvrir_vote'),
                  onTap: () => Navigator.pop(ctx, true),
                ),
                SizedBox(height: 8),
                BtnSecondaire(
                  label: context.tr('annuler'),
                  onTap: () => Navigator.pop(ctx, false),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      ),
    );

    if (result != true || !context.mounted) return;

    final question = questionCtrl.text.trim();
    if (question.isEmpty) {
      afficherToast(context, 'Question requise', estErreur: true);
      return;
    }

    final typeVoteStr = type == 'binaire' ? 'Oui / Non' : 'Candidats';

    final ok = await afficherModalePin(
      context,
      titre: context.tr('creer_vote'),
      sousTitre: 'Vérifie les détails avant de confirmer avec ton PIN.',
      recap: [
        (label: context.tr('question_vote'), valeur: question),
        (label: context.tr('type_vote'), valeur: typeVoteStr),
        (label: context.tr('nom_tontine'), valeur: data.nom),
      ],
      onValider: (pin) async {
        final ref = Formatters.genererReference();
        final now = DateTime.now().toIso8601String();
        final newData = data.toJson();

        final votes = List<Map<String, dynamic>>.from(
          (newData['votes'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ??
              [],
        );
        // FIX VOTE_INTROUVABLE : inclure TOUTES les clés — Supabase native + Flutter compat
        // La RPC SQL cherche 'sujet', 'creePar', 'le' (ms), 'statut'='ouvert'
        final newVote = {
          'id': ref,
          'type': type,
          // Clés Supabase native (attendues par la RPC SQL voter)
          'sujet': question,
          'creePar': provider.gestActifNom ?? '',
          'le': DateTime.now().millisecondsSinceEpoch,
          'statut': 'ouvert',
          'voix': <String, dynamic>{},
          // Clés Flutter compat (utilisées par Vote.fromJson côté Flutter)
          'question': question,
          'createur': provider.gestActifNom ?? '',
          'dateCreation': now,
          'clos': false,
          if (type == 'admission' && nouveauNomCtrl.text.isNotEmpty)
            'nouveauMembreNom': nouveauNomCtrl.text.trim(),
        };
        votes.add(newVote);
        newData['votes'] = votes;

        final journal = List<Map<String, dynamic>>.from(
          (newData['journal'] as List<dynamic>?)
                  ?.cast<Map<String, dynamic>>() ??
              [],
        );
        journal.insert(0, {
          'quoi': 'VOTE_CREE_$type',
          'gestionnaire': provider.gestActifNom ?? '',
          'quand': now,
          'reference': ref,
        });
        newData['journal'] = journal;

        return provider.ecrire(newData, pin);
      },
    );

    // ── BLOCKCHAIN : vote créé (non-bloquant) ─────────────────────────
    if (ok == true) {
      BlockchainService.enregistrerVoteCree(
        tontineCode : provider.courante!.code,
        gestionnaire: provider.gestActifNom ?? '',
        typeVote    : type,
        question    : question,
      ).catchError((e) {
        if (kDebugMode) debugPrint('[Blockchain] vote_cree erreur: $e');
        return BlockchainResultat(ok: false, erreur: '$e', phase: 1);
      });
    }
    // ────────────────────────────────────────────────────────────────────

    if (ok == true && context.mounted) {
      afficherToast(context, 'Vote ouvert !');
      // Notification push à tous les membres
      final _langVote = Provider.of<LocaleService>(context, listen: false).langue.code;
      final _tVoteOuvert = SupabaseService.notifTexte('vote_ouvert', _langVote, vars: {'question': question});
      SupabaseService.envoyerNotification(
        code: provider.courante!.code,
        type: 'vote',
        titre: _tVoteOuvert['titre']!,
        message: _tVoteOuvert['message']!,
      );
      await _chargerVoix();
    }
  }

  // ─── Voter ─────────────────────────────────────────────────────────────────
  // CORRECTION CRITIQUE :
  // 1. Voix déjà chargées (cf. initState) → pas de race condition
  // 2. Le menu utilise data.ordre (pas membres.where(pinVote!=null))
  // 3. On filtre uniquement les membres qui n'ont PAS encore voté sur CE vote

  Future<void> _voter(
    BuildContext context,
    TontineProvider provider,
    TontineData data,
    Vote vote,
  ) async {
    if (vote.clos) {
      afficherToast(context, 'Ce vote est clos.', estErreur: true);
      return;
    }

    // IDs des membres qui ont déjà voté sur CE vote
    final voixCeVote = _voixParVote[vote.id] ?? [];
    // Bug membres fix : gère aussi membreId camelCase (RPC peut retourner les deux)
    final dejaVote = voixCeVote
        .map((v) => v['membre_id'] as String? ?? v['membreId'] as String? ?? '')
        .where((id) => id.isNotEmpty)
        .toSet();

    // SOURCE UNIQUE DE MEMBRES : data.membresActifs avec double fallback
    // Si ordre[] contient des IDs qui ne matchent pas membres[] → fallback membres[]
    // = même liste que l'onglet Membres (évite "Tous ont voté" sur liste vide)
    final tousLesMembres = data.membresActifs;
    final restants = tousLesMembres
        .where((m) => !dejaVote.contains(m.id))
        .toList();

    if (restants.isEmpty) {
      afficherToast(context, 'Tous les membres ont déjà voté.', estErreur: true);
      return;
    }

    String? membreId = restants.first.id;
    final pinCtrl = TextEditingController();
    String choix = 'Oui';  // ← majuscule initiale : valeur attendue par la RPC SQL en production

    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.fondPapier,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 16,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
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
                const SizedBox(height: 16),
                const Text(
                  'Voter',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 20,
                    color: AppColors.encre,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  vote.question,
                  style: TextStyle(
                    fontSize: 14,
                    color: AppColors.texteDoux,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  '${restants.length} membre(s) n\'ont pas encore voté',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.succes,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                ChampLabel(label: context.tr('qui_etes_vous')),
                // CORRECTION : DropdownButtonFormField avec valeur initiale non-nulle
                DropdownButtonFormField<String>(
                  initialValue: membreId,
                  decoration: InputDecoration(),
                  isExpanded: true,
                  items: restants
                      .map((m) => DropdownMenuItem(
                            value: m.id,
                            child: Text(
                              m.nom,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ))
                      .toList(),
                  onChanged: (v) => setS(() => membreId = v),
                ),
                ChampLabel(label: context.tr('ton_vote')),
                Row(
                  children: ['Oui', 'Non', 'Abstention'].map((c) {
                    final sel = choix == c;
                    return Expanded(
                      child: GestureDetector(
                        onTap: () => setS(() => choix = c), // c = 'Oui'/'Non'/'Abstention'
                        child: Container(
                          margin: const EdgeInsets.only(right: 6),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          decoration: BoxDecoration(
                            color: sel
                                ? (c == 'Oui'
                                    ? AppColors.succes
                                    : c == 'Non'
                                        ? AppColors.alerte
                                        : AppColors.encreDoux)
                                : AppColors.fondCode,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Center(
                            child: Text(
                              c == 'Oui'
                                  ? '✓ Oui'
                                  : c == 'Non'
                                      ? '✗ Non'
                                      : '○ Abs.',
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 13,
                                color: sel ? Colors.white : AppColors.encre,
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
                ChampLabel(label: context.tr('ton_pin_vote')),
                TextField(
                  controller: pinCtrl,
                  keyboardType: TextInputType.number,
                  obscureText: true,
                  maxLength: 6,
                  textAlign: TextAlign.center,
                  decoration: InputDecoration(
                    hintText: '••••',
                    counterText: '',
                  ),
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.4,
                  ),
                ),
                SizedBox(height: 16),
                BtnPrincipal(
                  label: context.tr('voter'),
                  onTap: () => Navigator.pop(ctx, true),
                ),
                const SizedBox(height: 8),
                BtnSecondaire(
                  label: 'Annuler',
                  onTap: () => Navigator.pop(ctx, false),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      ),
    );

    if (result != true || !context.mounted) return;
    if (membreId == null || pinCtrl.text.length < 4) {
      afficherToast(context, 'Données incomplètes', estErreur: true);
      return;
    }
    if (vote.id.isEmpty) {
      afficherToast(context, 'Erreur : identifiant du vote manquant. Rechargez la tontine.', estErreur: true);
      return;
    }

    try {
      final res = await SupabaseService.voter(
        code: provider.courante!.code,
        voteId: vote.id,
        membreId: membreId!,
        pinMembre: pinCtrl.text.trim(),
        choix: choix,
        appareil: 'flutter',
      );

      if (!context.mounted) return;

      if (res == 'OK') {
        afficherToast(context, 'Vote enregistré !');
        // Notification push à tous les membres
        final _langVoter = Provider.of<LocaleService>(context, listen: false).langue.code;
        final _tVoter = SupabaseService.notifTexte('vote_enregistre', _langVoter, vars: {'question': vote.question});
        SupabaseService.envoyerNotification(
          code: provider.courante!.code,
          type: 'vote',
          titre: _tVoter['titre']!,
          message: _tVoter['message']!,
          donneesExtra: {'vote_id': vote.id},
        );
        await _chargerVoix();
      } else {
        final msgErreur = res == 'PIN_INCORRECT'
            ? 'PIN incorrect.'
            : res == 'DEJA_VOTE'
                ? 'Vous avez déjà voté sur ce scrutin.'
                : res == 'VOTE_CLOS'
                    ? 'Ce vote est clôturé.'
                    : 'Erreur : $res';
        afficherToast(context, msgErreur, estErreur: true);
      }
    } catch (e) {
      if (!context.mounted) return;
      afficherToast(context, 'Erreur : $e', estErreur: true);
    }
  }

  // ─── Clore un vote ─────────────────────────────────────────────────────────

  Future<void> _cloreVote(
    BuildContext context,
    TontineProvider provider,
    TontineData data,
    Vote vote,
  ) async {
    final voix = _voixParVote[vote.id] ?? [];
    final oui = voix.where((v) => (v['choix'] as String? ?? '').toLowerCase() == 'oui').length;
    final non = voix.where((v) => (v['choix'] as String? ?? '').toLowerCase() == 'non').length;
    final abstention = voix.where((v) => (v['choix'] as String? ?? '').toLowerCase() == 'abstention').length;
    final totalMembres = data.membresActifs.length;
    final participation = voix.length;

    // ── Logique spéciale pour les votes de retrait ─────────────────────────
    final estVoteRetrait = vote.type == 'retrait';

    // Récupérer quorum et majorité depuis le vote (ou valeurs par défaut)
    final quorumVote = estVoteRetrait
        ? _extraireQuorum(vote)
        : 0; // 0 = pas de quorum pour les votes normaux
    final majoriteVote = estVoteRetrait
        ? _extraireMajorite(vote)
        : 50; // 50% = majorité simple

    // Vérifier le quorum pour les votes de retrait
    bool quorumAtteint = true;
    if (estVoteRetrait && totalMembres > 0) {
      final tauxParticipation = (participation / totalMembres * 100).round();
      quorumAtteint = tauxParticipation >= quorumVote;
    }

    // Calculer le résultat selon la règle applicable
    bool adopte;
    if (estVoteRetrait && participation > 0) {
      // Vote retrait : majorité en % des voix exprimées (hors abstention)
      final exprimes = oui + non;
      adopte = exprimes > 0
          ? (oui / exprimes * 100) >= majoriteVote
          : false;
      // Si quorum non atteint → vote invalide (non adopté)
      if (!quorumAtteint) adopte = false;
    } else {
      // Vote normal : majorité simple Oui > Non
      adopte = oui > non;
    }

    // Résumé pour la modale de confirmation
    final recapVote = <({String label, String valeur})>[
      (label: 'Pour', valeur: '$oui voix'),
      (label: 'Contre', valeur: '$non voix'),
      (label: 'Abstention', valeur: '$abstention voix'),
      if (estVoteRetrait) ...[
        (label: 'Participation',
            valeur:
                '$participation / $totalMembres (${totalMembres > 0 ? (participation / totalMembres * 100).round() : 0}%)'),
        (label: 'Quorum requis', valeur: '$quorumVote%'),
        (label: 'Majorité requise', valeur: '$majoriteVote%'),
        if (!quorumAtteint)
          (label: '⚠️ Quorum', valeur: 'Non atteint → Proposition rejetée'),
      ],
      (
        label: 'Résultat',
        valeur: adopte ? '✅ ADOPTÉ' : '❌ REJETÉ'
      ),
    ];

    final ok = await afficherModalePin(
      context,
      titre: estVoteRetrait ? 'Clore le vote de retrait' : 'Clore le vote',
      sousTitre: estVoteRetrait
          ? 'Le résultat sera définitif. Le membre sera mis à jour si adopté.'
          : 'Le résultat sera enregistré définitivement.',
      recap: recapVote,
      onValider: (pin) async {
        final now = DateTime.now().toIso8601String();
        final ref = Formatters.genererReference();
        final newData = data.toJson();

        final votes = List<Map<String, dynamic>>.from(
          (newData['votes'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ??
              [],
        );
        final idx = votes.indexWhere((v) => v['id'] == vote.id);
        if (idx >= 0) {
          votes[idx]['clos'] = true;
          votes[idx]['statut'] = 'clos';
          votes[idx]['dateCloture'] = now;
          votes[idx]['closLe'] = now;
          votes[idx]['adopte'] = adopte;
          if (estVoteRetrait) {
            votes[idx]['decompte'] = {
              'oui': oui,
              'non': non,
              'abstention': abstention,
              'participation': participation,
              'totalMembres': totalMembres,
              'quorumAtteint': quorumAtteint,
              'majorite': majoriteVote,
            };
          }
        }

        // ── Vote d'admission adopté → ajouter le membre ──────────────────
        if (vote.type == 'admission' && adopte && vote.nouveauMembreNom != null) {
          final membres = List<Map<String, dynamic>>.from(
            (newData['membres'] as List<dynamic>).cast<Map<String, dynamic>>(),
          );

          // ── Vérification limite membres (Gratuit = 5 max) ─────────────
          final tontineData = provider.courante!.data;
          final peutAjouter = FeatureGate.peutAjouterMembre(
            isPremium: tontineData.isPremium,
            nbMembresActuels: membres.length,
          );
          if (!peutAjouter) {
            if (context.mounted) {
              afficherToast(
                context,
                'Limite atteinte : max ${FeatureGate.maxMembresGratuit} membres en formule Gratuite. '
                'Passez en Premium pour des membres illimités.',
                estErreur: true,
              );
            }
            return false; // Annuler l'admission (limite membres atteinte)
          }

          final newId = 'm${membres.length + 1}';
          membres.add({
            'id': newId,
            'nom': vote.nouveauMembreNom,
            'paye': false,
            'score': 50,
          });
          newData['membres'] = membres;

          final ordre = List<String>.from(
            (newData['ordre'] as List<dynamic>?)?.map((e) => e.toString()) ?? [],
          );
          ordre.add(newId);
          newData['ordre'] = ordre;

          // Notification nouveau membre admis
          final _langMembre = Provider.of<LocaleService>(context, listen: false).langue.code;
          final _tMembre = SupabaseService.notifTexte('nouveau_membre', _langMembre, vars: {'nom': vote.nouveauMembreNom ?? ''});
          SupabaseService.envoyerNotification(
            code: widget.code,
            type: 'nouveau_membre',
            titre: _tMembre['titre']!,
            message: _tMembre['message']!,
          );
        }

        // ── Vote de retrait adopté → passer le membre en "Retiré" ─────────
        if (estVoteRetrait && adopte) {
          final membreConcerneId = _extraireMembreConcerne(vote);
          if (membreConcerneId != null) {
            final membres = List<Map<String, dynamic>>.from(
              (newData['membres'] as List<dynamic>).cast<Map<String, dynamic>>(),
            );
            for (final m in membres) {
              if (m['id'] == membreConcerneId) {
                m['role'] = 'Retiré';
                m['dateRetrait'] = now;
                m['motifRetrait'] = _extraireMotif(vote);
                m['voteRetraitId'] = vote.id;
                break;
              }
            }
            newData['membres'] = membres;
          }

          // Mettre à jour le statut dans propositions_retrait (v6)
          try {
            await SupabaseService.rpc('maj_statut_retrait', {
              'p_code': provider.courante!.code,
              'p_nom': provider.gestActifNom ?? '',
              'p_pin': pin,
              'p_vote_id': vote.id,
              'p_statut': 'accepte',
            });
          } catch (_) {
            // v6 non déployée — silencieux
          }
        }

        // ── Vote de retrait refusé → mettre à jour le statut propositions ─
        if (estVoteRetrait && !adopte) {
          try {
            await SupabaseService.rpc('maj_statut_retrait', {
              'p_code': provider.courante!.code,
              'p_nom': provider.gestActifNom ?? '',
              'p_pin': pin,
              'p_vote_id': vote.id,
              'p_statut': 'refuse',
            });
          } catch (_) {}
        }

        newData['votes'] = votes;

        final journal = List<Map<String, dynamic>>.from(
          (newData['journal'] as List<dynamic>?)
                  ?.cast<Map<String, dynamic>>() ??
              [],
        );
        final typeLabel = estVoteRetrait ? 'RETRAIT' : 'VOTE';
        journal.insert(0, {
          'quoi': '${typeLabel}_CLOS_${adopte ? 'ADOPTE' : 'REJETE'}_${vote.id}'
              ':oui=$oui:non=$non:abs=$abstention:participation=$participation/$totalMembres',
          'gestionnaire': provider.gestActifNom ?? '',
          'quand': now,
          'reference': ref,
        });
        newData['journal'] = journal;

        return provider.ecrire(newData, pin);
      },
    );

    // ── BLOCKCHAIN : vote clôturé (non-bloquant) ───────────────────────────
    if (ok == true) {
      BlockchainService.enregistrerVoteClos(
        tontineCode : widget.code,
        gestionnaire: provider.gestActifNom ?? '',
        typeVote    : estVoteRetrait ? 'retrait' : vote.type,
        voteId      : vote.id,
        adopte      : adopte,
      ).catchError((e) {
        if (kDebugMode) debugPrint('[Blockchain] vote_clos erreur: $e');
        return BlockchainResultat(ok: false, erreur: '$e', phase: 1);
      });
    }
    // ────────────────────────────────────────────────────────────────────────

    if (ok == true && context.mounted) {
      String message;
      if (estVoteRetrait) {
        if (adopte) {
          message = '✅ Vote adopté — Le membre a été retiré de la tontine.';
        } else if (!quorumAtteint) {
          message = '⚠️ Vote invalide — Quorum non atteint ($quorumVote% requis).';
        } else {
          message = '❌ Vote rejeté — Le membre est maintenu. Un plan de suivi IA sera proposé.';
        }
      } else {
        message = 'Vote clos. ${adopte ? 'Proposition adoptée !' : 'Proposition rejetée.'}';
      }
      afficherToast(context, message);
      // Notification push résultat du vote
      final _langClos = Provider.of<LocaleService>(context, listen: false).langue.code;
      final _tClos = SupabaseService.notifTexte('vote_clos', _langClos, vars: {
        'question': vote.question,
        'resultat': adopte
            ? SupabaseService.notifTexte('vote_clos', _langClos)['titre'] ?? 'adoptée'
            : SupabaseService.notifTexte('vote_clos', _langClos)['titre_rejete'] ?? 'rejetée',
      });
      final _titreClos = adopte
          ? (SupabaseService.notifTexte('vote_clos', _langClos)['titre'] ?? '✅ Vote adopté')
          : (SupabaseService.notifTexte('vote_clos', _langClos)['titre_rejete'] ?? '❌ Vote rejeté');
      SupabaseService.envoyerNotification(
        code: provider.courante!.code,
        type: 'vote',
        titre: _titreClos,
        message: _tClos['message']!,
        donneesExtra: {'vote_id': vote.id},
      );
      await _chargerVoix();
    }
  }

  // ── Helpers : extraire les métadonnées d'un vote de retrait ───────────────
  int _extraireQuorum(Vote vote) {
    // Chercher dans la description ou les métadonnées du vote
    final desc = vote.description ?? '';
    final match = RegExp(r'Quorum requis\s*:\s*(\d+)%').firstMatch(desc);
    if (match != null) return int.tryParse(match.group(1) ?? '') ?? 50;
    return 50; // défaut 50%
  }

  int _extraireMajorite(Vote vote) {
    final desc = vote.description ?? '';
    final match = RegExp(r'Majorité requise\s*:\s*(\d+)%').firstMatch(desc);
    if (match != null) return int.tryParse(match.group(1) ?? '') ?? 67;
    return 67; // défaut 2/3
  }

  String? _extraireMembreConcerne(Vote vote) {
    // Le membreConcerneId est stocké dans la description du vote
    final desc = vote.description ?? '';
    // Essayer d'abord via vote.voix (ancien format)
    if (vote.voix.containsKey('membreConcerneId')) {
      return vote.voix['membreConcerneId'] as String?;
    }
    // Sinon essayer d'extraire de la description
    final match = RegExp(r'membreConcerneId\s*:\s*(\S+)').firstMatch(desc);
    return match?.group(1);
  }

  String _extraireMotif(Vote vote) {
    final desc = vote.description ?? '';
    final match = RegExp(r'Motif\s*:\s*(.+?)(?:\n|Score|$)').firstMatch(desc);
    return match?.group(1)?.trim() ?? 'Retrait par vote collectif';
  }
}

// ─── Carte d'un vote ──────────────────────────────────────────────────────────

class _CarteVote extends StatelessWidget {
  final Vote vote;
  final List<Map<String, dynamic>> voix;
  final List<String> ordre;
  final List<Membre> membres;
  final bool estGest;
  final String code;
  final String nomTontine;
  final VoidCallback onVoter;
  final VoidCallback? onClore;
  final VoidCallback onRecharger;
  final Future<void> Function()? onExporterPdf;

  const _CarteVote({
    required this.vote,
    required this.voix,
    required this.ordre,
    required this.membres,
    required this.estGest,
    required this.code,
    required this.nomTontine,
    required this.onVoter,
    this.onClore,
    required this.onRecharger,
    this.onExporterPdf,
  });

  @override
  Widget build(BuildContext context) {
    final oui = voix.where((v) => (v['choix'] as String? ?? '').toLowerCase() == 'oui').length;
    final non = voix.where((v) => (v['choix'] as String? ?? '').toLowerCase() == 'non').length;
    final abstention = voix.where((v) => (v['choix'] as String? ?? '').toLowerCase() == 'abstention').length;

    // Total des votants = membres actifs (membresActifs passé depuis le parent)
    final total = membres.isNotEmpty ? membres.length : ordre.length;
    final participation = voix.length;

    final estRetrait = vote.type == 'retrait';
    final couleurRetrait = const Color(0xFFC4453C);

    // Quorum et majorité pour votes de retrait
    final desc = vote.description ?? '';
    final quorumMatch = RegExp(r'Quorum requis\s*:\s*(\d+)%').firstMatch(desc);
    final majoriteMatch = RegExp(r'Majorité requise\s*:\s*(\d+)%').firstMatch(desc);
    final quorumPct = int.tryParse(quorumMatch?.group(1) ?? '') ?? 50;
    final majoritePct = int.tryParse(majoriteMatch?.group(1) ?? '') ?? 67;

    return CarteTC(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Badge spécial pour vote de retrait
          if (estRetrait) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: couleurRetrait.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.gpp_bad_rounded,
                      size: 12, color: couleurRetrait),
                  const SizedBox(width: 4),
                  Text(
                    'Vote de retrait · Sécurisé · PIN obligatoire',
                    style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: couleurRetrait),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],

          // En-tête : question + badge statut
          Row(
            children: [
              Expanded(
                child: Text(
                  vote.question,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                    color: estRetrait ? couleurRetrait : AppColors.encre,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: vote.clos
                      ? (vote.adopte == true && estRetrait
                          ? couleurRetrait.withValues(alpha: 0.1)
                          : AppColors.fondCode)
                      : AppColors.succesFond,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  vote.clos
                      ? (vote.adopte == true
                          ? (estRetrait ? 'Retiré ✗' : 'Adopté ✓')
                          : vote.adopte == false
                              ? (estRetrait ? 'Maintenu ✓' : 'Rejeté ✗')
                              : 'Clos')
                      : 'En cours',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: vote.clos
                        ? (vote.adopte == true
                            ? (estRetrait ? couleurRetrait : AppColors.succes)
                            : AppColors.texteDoux)
                        : AppColors.succes,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '${_labelType(vote.type)} · par ${vote.createur} · ${Formatters.dateFormatee(DateTime.tryParse(vote.dateCreation))}',
            style: const TextStyle(fontSize: 12, color: AppColors.texteDoux),
          ),

          // Règles du vote de retrait
          if (estRetrait && !vote.clos) ...[
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              decoration: BoxDecoration(
                color: AppColors.fondCode,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                children: [
                  Icon(Icons.tune_rounded,
                      size: 11, color: AppColors.texteDoux),
                  const SizedBox(width: 5),
                  Text(
                    'Quorum : $quorumPct% · Majorité : $majoritePct% · '
                    'Participation : $participation/$total '
                    '(${total > 0 ? (participation / total * 100).round() : 0}%)',
                    style: const TextStyle(
                        fontSize: 10, color: AppColors.texteDoux),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 12),

          // Résultats
          Row(
            children: [
              _VotePuce(
                  label: '✓ Oui', valeur: oui, couleur: AppColors.succes),
              const SizedBox(width: 8),
              _VotePuce(
                  label: '✗ Non', valeur: non, couleur: AppColors.alerte),
              const SizedBox(width: 8),
              _VotePuce(
                  label: '○ Abs.',
                  valeur: abstention,
                  couleur: AppColors.texteDoux),
              const Spacer(),
              Text(
                '$participation/$total votants',
                style: const TextStyle(
                    fontSize: 12, color: AppColors.texteDoux),
              ),
            ],
          ),

          // Registre nominatif (qui a voté quoi)
          if (voix.isNotEmpty) ...[
            const SizedBox(height: 10),
            const Divider(height: 1, color: AppColors.lignes),
            const SizedBox(height: 8),
            _RegistreVoix(voix: voix, membres: membres),
          ],

          // Actions (seulement si vote ouvert)
          if (!vote.clos) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: BtnSecondaire(
                    label: 'Voter',
                    onTap: onVoter,
                  ),
                ),
                if (onClore != null) ...[
                  const SizedBox(width: 10),
                  Expanded(
                    child: BtnPrincipal(
                      label: 'Clore',
                      onTap: onClore,
                    ),
                  ),
                ],
              ],
            ),
            // ── Notifications WhatsApp gestionnaire (vote ouvert) ────────────
            if (estGest) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: _BtnWaVote(
                      label: '📢 Annoncer',
                      tooltip: 'Annoncer l\'ouverture du vote',
                      onTap: () => _annoncerOuverture(context),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _BtnWaVote(
                      label: '🔔 Relancer',
                      tooltip: 'Relancer les non-votants',
                      onTap: () => _relancerNonVotants(context),
                    ),
                  ),
                ],
              ),
            ],
          ],

          // ── Partager résultat + PV PDF (vote clos, gestionnaire) ────────
          if (vote.clos && estGest) ...[
            const SizedBox(height: 10),
            _BtnWaVote(
              label: '📊 Partager le résultat',
              tooltip: 'Publier le résultat sur WhatsApp',
              onTap: () => _partagerResultat(context, oui, non, abstention),
            ),
            if (onExporterPdf != null) ...[  
              const SizedBox(height: 8),
              _BtnPdfVote(
                onTap: onExporterPdf!,
              ),
            ],
          ],
        ],
      ),
    );
  }

  // ── Texte d'annonce d'ouverture ───────────────────────────────────────────
  void _annoncerOuverture(BuildContext context) {
    final texte = Uri.encodeComponent(
      '🗳️ *Nouveau vote ouvert — $nomTontine*\n\n'
      '📋 Question : ${vote.question}\n'
      '🏷️ Type : ${_labelType(vote.type)}\n'
      '📅 Ouvert le : ${Formatters.dateFormatee(DateTime.tryParse(vote.dateCreation))}\n\n'
      'Connectez-vous à TontineClair avec le code *$code* pour voter.',
    );
    launchUrl(
      Uri.parse('https://wa.me/?text=$texte'),
      mode: LaunchMode.externalApplication,
    );
  }

  // ── Relancer les non-votants ──────────────────────────────────────────────
  void _relancerNonVotants(BuildContext context) {
    final membreParId = {for (final m in membres) m.id: m.nom};
    final ayantVote = voix.map((v) => v['membre_id'] as String? ?? '').toSet();
    final nonVotants = ordre
        .where((id) => !ayantVote.contains(id))
        .map((id) => membreParId[id] ?? id)
        .toList();

    final listeNoms = nonVotants.isEmpty
        ? '(tous ont voté)'
        : nonVotants.join(', ');

    final texte = Uri.encodeComponent(
      '⏰ *Rappel de vote — $nomTontine*\n\n'
      '📋 Vote en cours : ${vote.question}\n\n'
      '🔔 Membres n\'ayant pas encore voté :\n$listeNoms\n\n'
      'Connectez-vous avec le code *$code* pour voter avant la clôture.',
    );
    launchUrl(
      Uri.parse('https://wa.me/?text=$texte'),
      mode: LaunchMode.externalApplication,
    );
  }

  // ── Partager le résultat ──────────────────────────────────────────────────
  void _partagerResultat(
    BuildContext context,
    int oui,
    int non,
    int abstention,
  ) {
    final statut = vote.adopte == true
        ? '✅ Adopté'
        : vote.adopte == false
            ? '❌ Rejeté'
            : '⚪ Clos sans décision';

    final texte = Uri.encodeComponent(
      '📊 *Résultat du vote — $nomTontine*\n\n'
      '📋 Question : ${vote.question}\n'
      '🏁 Résultat : $statut\n\n'
      '✓ Oui : $oui  ·  ✗ Non : $non  ·  ○ Abstention : $abstention\n'
      '👥 Participation : ${voix.length} / ${membres.isNotEmpty ? membres.length : ordre.length}\n\n'
      '_TontineClair · Code ${vote.id.substring(0, 6).toUpperCase()}',
    );
    launchUrl(
      Uri.parse('https://wa.me/?text=$texte'),
      mode: LaunchMode.externalApplication,
    );
  }

  String _labelType(String type) {
    switch (type) {
      case 'admission':
        return 'Admission';
      case 'retirage':
        return 'Retirage';
      case 'retrait':
        return '⚠️ Retrait membre';
      default:
        return 'Libre';
    }
  }
}

// ─── Petit bouton WhatsApp inline pour les votes ─────────────────────────────

class _BtnWaVote extends StatelessWidget {
  final String label;
  final String tooltip;
  final VoidCallback onTap;

  const _BtnWaVote({
    required this.label,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 12),
          decoration: BoxDecoration(
            color: const Color(0xFF25D366).withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: const Color(0xFF25D366).withValues(alpha: 0.35),
            ),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              color: Color(0xFF128C7E),
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Bouton export PV PDF ─────────────────────────────────────────────────────

class _BtnPdfVote extends StatefulWidget {
  final Future<void> Function() onTap;
  const _BtnPdfVote({required this.onTap});

  @override
  State<_BtnPdfVote> createState() => _BtnPdfVoteState();
}

class _BtnPdfVoteState extends State<_BtnPdfVote> {
  bool _loading = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _loading
          ? null
          : () async {
              setState(() => _loading = true);
              try {
                await widget.onTap();
              } catch (e) {
                if (context.mounted) {
                  afficherToast(context, 'Erreur export PDF : $e',
                      estErreur: true);
                }
              } finally {
                if (mounted) setState(() => _loading = false);
              }
            },
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 12),
        decoration: BoxDecoration(
          color: AppColors.encre.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: AppColors.encre.withValues(alpha: 0.20),
          ),
        ),
        child: _loading
            ? const Center(
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.encre,
                  ),
                ),
              )
            : const Text(
                '📄 Exporter le PV (PDF)',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: AppColors.encre,
                ),
              ),
      ),
    );
  }
}

// ─── Registre nominatif des voix ─────────────────────────────────────────────

class _RegistreVoix extends StatelessWidget {
  final List<Map<String, dynamic>> voix;
  final List<Membre> membres;

  const _RegistreVoix({required this.voix, required this.membres});

  @override
  Widget build(BuildContext context) {
    final membreParId = {for (final m in membres) m.id: m.nom};

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Registre des votes',
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w700,
            color: AppColors.texteDoux,
            letterSpacing: 0.3,
          ),
        ),
        const SizedBox(height: 6),
        ...voix.map((v) {
          final membreId = v['membre_id'] as String? ?? '';
          final nomMembre =
              membreParId[membreId] ?? v['membre_nom'] as String? ?? membreId;
          final choix = v['choix'] as String? ?? '';
          final quand = v['date'] as String? ?? v['horodatage'] as String? ?? '';
          final dateD = DateTime.tryParse(quand);

          return Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              children: [
                _BadgeChoix(choix: choix),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    nomMembre,
                    style: const TextStyle(
                      fontSize: 12.5,
                      color: AppColors.texte,
                      fontWeight: FontWeight.w600,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (dateD != null)
                  Text(
                    Formatters.heureFormatee(dateD),
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppColors.texteDoux,
                    ),
                  ),
              ],
            ),
          );
        }),
      ],
    );
  }
}

class _BadgeChoix extends StatelessWidget {
  final String choix;
  const _BadgeChoix({required this.choix});

  @override
  Widget build(BuildContext context) {
    final choixNorm = choix.toLowerCase();
    final (label, couleur) = switch (choixNorm) {
      'oui' => ('✓', AppColors.succes),
      'non' => ('✗', AppColors.alerte),
      _ => ('○', AppColors.texteDoux),
    };
    return Container(
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        color: couleur.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Center(
        child: Text(
          label,
          style: TextStyle(
              fontSize: 11, fontWeight: FontWeight.w800, color: couleur),
        ),
      ),
    );
  }
}

class _VotePuce extends StatelessWidget {
  final String label;
  final int valeur;
  final Color couleur;

  const _VotePuce({
    required this.label,
    required this.valeur,
    required this.couleur,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: couleur.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        '$label : $valeur',
        style: TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w700,
          color: couleur,
        ),
      ),
    );
  }
}
