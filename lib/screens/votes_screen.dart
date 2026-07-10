import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/tontine.dart';
import '../services/tontine_provider.dart';
import '../services/supabase_service.dart';
import '../utils/app_colors.dart';
import '../utils/formatters.dart';
import '../widgets/app_widgets.dart';

class VotesScreen extends StatefulWidget {
  final String code;

  const VotesScreen({super.key, required this.code});

  @override
  State<VotesScreen> createState() => _VotesScreenState();
}

class _VotesScreenState extends State<VotesScreen> {
  Map<String, List<Map<String, dynamic>>> _voixParVote = {};
  bool _chargementVoix = false; // ignore: unused_field

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _chargerVoix());
  }

  Future<void> _chargerVoix() async {
    setState(() => _chargementVoix = true);
    try {
      final tontine = context.read<TontineProvider>().courante;
      if (tontine == null) return;
      final voix = await SupabaseService.lireVoix(tontine.code);
      final map = <String, List<Map<String, dynamic>>>{};
      for (final v in voix) {
        final voteId = v['vote_id'] as String? ?? '';
        map.putIfAbsent(voteId, () => []).add(v);
      }
      setState(() => _voixParVote = map);
    } catch (_) {
    } finally {
      setState(() => _chargementVoix = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<TontineProvider>();
    final tontine = provider.courante;
    if (tontine == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));

    final data = tontine.data;
    final estGest = provider.estDebloque;
    final votes = data.votes;

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
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  const Text(
                    'Votes sécurisés',
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 28,
                      color: AppColors.encre,
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    '1 membre = 1 voix · Irréversible · Horodaté',
                    style: TextStyle(fontSize: 13.5, color: AppColors.texteDoux),
                  ),
                  const SizedBox(height: 16),
                  if (estGest)
                    BtnKola(
                      label: '+ Créer un vote',
                      icon: Icons.add,
                      onTap: () => _creerVote(context, provider, data),
                    ),
                  const SizedBox(height: 16),
                  if (votes.isEmpty)
                    const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          'Aucun vote en cours.',
                          style: TextStyle(color: AppColors.texteDoux),
                        ),
                      ),
                    )
                  else
                    ...votes.reversed.map(
                      (v) => _CarteVote(
                        vote: v,
                        voix: _voixParVote[v.id] ?? [],
                        membres: data.membres,
                        estGest: estGest,
                        code: tontine.code,
                        onVoter: () => _voter(context, provider, data, v),
                        onClore: estGest && !v.clos
                            ? () => _cloreVote(context, provider, data, v)
                            : null,
                        onRecharger: _chargerVoix,
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
                'Nouveau vote',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 20,
                  color: AppColors.encre,
                ),
              ),
              const ChampLabel(label: 'Type de vote'),
              DropdownButtonFormField<String>(
                value: type,
                decoration: const InputDecoration(),
                items: const [
                  DropdownMenuItem(value: 'libre', child: Text('Vote libre')),
                  DropdownMenuItem(
                      value: 'admission', child: Text('Admission d\'un nouveau membre')),
                  DropdownMenuItem(
                      value: 'retirage', child: Text('Retirage de l\'ordre de passage')),
                ],
                onChanged: (v) => setS(() => type = v!),
              ),
              const ChampLabel(label: 'Question / Objet du vote'),
              TextField(
                controller: questionCtrl,
                maxLength: 150,
                decoration: const InputDecoration(
                  hintText: 'Ex : Accepter Koua comme nouveau membre ?',
                ),
              ),
              if (type == 'admission') ...[
                const ChampLabel(label: 'Nom du nouveau membre'),
                TextField(
                  controller: nouveauNomCtrl,
                  maxLength: 30,
                  decoration: const InputDecoration(hintText: 'Ex : Koua M.'),
                ),
              ],
              const SizedBox(height: 16),
              BtnPrincipal(
                label: 'Ouvrir le vote',
                onTap: () => Navigator.pop(ctx, true),
              ),
              const SizedBox(height: 8),
              BtnSecondaire(
                label: 'Annuler',
                onTap: () => Navigator.pop(ctx, false),
              ),
            ],
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

    final ok = await afficherModalePin(
      context,
      titre: 'Créer le vote',
      sousTitre: question,
      onValider: (pin) async {
        final ref = Formatters.genererReference();
        final now = DateTime.now().toIso8601String();
        final newData = data.toJson();

        final votes = List<Map<String, dynamic>>.from(
          (newData['votes'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ?? [],
        );
        final newVote = {
          'id': ref,
          'type': type,
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
          (newData['journal'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ?? [],
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

    if (ok == true && context.mounted) {
      afficherToast(context, 'Vote ouvert !');
      await _chargerVoix();
    }
  }

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

    final membres = data.membres;
    String? membreId;
    final pinCtrl = TextEditingController();
    String choix = 'oui';

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
                style: const TextStyle(
                  fontSize: 14,
                  color: AppColors.texteDoux,
                ),
              ),
              const ChampLabel(label: 'Qui es-tu ?'),
              DropdownButtonFormField<String>(
                value: membreId,
                hint: const Text('Choisir un membre'),
                decoration: const InputDecoration(),
                items: membres
                    .where((m) => m.pinVote != null)
                    .map((m) => DropdownMenuItem(
                          value: m.id,
                          child: Text(m.nom),
                        ))
                    .toList(),
                onChanged: (v) => setS(() => membreId = v),
              ),
              const ChampLabel(label: 'Ton vote'),
              Row(
                children: ['oui', 'non', 'abstention'].map((c) {
                  final sel = choix == c;
                  return Expanded(
                    child: GestureDetector(
                      onTap: () => setS(() => choix = c),
                      child: Container(
                        margin: const EdgeInsets.only(right: 6),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        decoration: BoxDecoration(
                          color: sel
                              ? (c == 'oui'
                                  ? AppColors.succes
                                  : c == 'non'
                                      ? AppColors.alerte
                                      : AppColors.encreDoux)
                              : AppColors.fondCode,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Center(
                          child: Text(
                            c == 'oui'
                                ? '✓ Oui'
                                : c == 'non'
                                    ? '✗ Non'
                                    : '○ Abstention',
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
              const ChampLabel(label: 'Ton PIN de vote'),
              TextField(
                controller: pinCtrl,
                keyboardType: TextInputType.number,
                obscureText: true,
                maxLength: 6,
                textAlign: TextAlign.center,
                decoration: const InputDecoration(
                  hintText: '••••',
                  counterText: '',
                ),
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.4,
                ),
              ),
              const SizedBox(height: 16),
              BtnPrincipal(
                label: 'Voter',
                onTap: () => Navigator.pop(ctx, true),
              ),
              const SizedBox(height: 8),
              BtnSecondaire(
                label: 'Annuler',
                onTap: () => Navigator.pop(ctx, false),
              ),
            ],
          ),
        ),
      ),
    );

    if (result != true || !context.mounted) return;
    if (membreId == null || pinCtrl.text.length < 4) {
      afficherToast(context, 'Données incomplètes', estErreur: true);
      return;
    }

    try {
      final res = await SupabaseService.voter(
        code:       provider.courante!.code,
        voteId:     vote.id,
        membreId:   membreId!,
        pinMembre:  pinCtrl.text.trim(),
        choix:      choix,
        appareil:   'flutter',
      );

      if (!context.mounted) return;

      if (res == 'OK') {
        afficherToast(context, 'Vote enregistré !');
        await _chargerVoix();
      } else {
        final msgErreur = res == 'PIN_INCORRECT'   ? 'PIN incorrect.'
                        : res == 'DEJA_VOTE'       ? 'Vous avez déjà voté.'
                        : res == 'VOTE_CLOS'       ? 'Ce vote est clôturé.'
                        : 'Erreur : $res';
        afficherToast(context, msgErreur, estErreur: true);
      }
    } catch (e) {
      if (!context.mounted) return;
      afficherToast(context, 'Erreur : $e', estErreur: true);
    }
  }

  Future<void> _cloreVote(
    BuildContext context,
    TontineProvider provider,
    TontineData data,
    Vote vote,
  ) async {
    final voix = _voixParVote[vote.id] ?? [];
    final oui = voix.where((v) => v['choix'] == 'oui').length;
    final non = voix.where((v) => v['choix'] == 'non').length;
    final abstention = voix.where((v) => v['choix'] == 'abstention').length;
    final adopte = oui > non;

    final ok = await afficherModalePin(
      context,
      titre: 'Clore le vote',
      sousTitre:
          'Résultat : $oui pour, $non contre, $abstention abstentions. ${adopte ? 'ADOPTÉ' : 'REJETÉ'}',
      onValider: (pin) async {
        final now = DateTime.now().toIso8601String();
        final ref = Formatters.genererReference();
        final newData = data.toJson();

        final votes = List<Map<String, dynamic>>.from(
          (newData['votes'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ?? [],
        );
        final idx = votes.indexWhere((v) => v['id'] == vote.id);
        if (idx >= 0) {
          votes[idx]['clos'] = true;
          votes[idx]['dateCloture'] = now;
          votes[idx]['adopte'] = adopte;
        }

        // Si vote d'admission adopté : ajouter le membre
        if (vote.type == 'admission' && adopte && vote.nouveauMembreNom != null) {
          final membres = List<Map<String, dynamic>>.from(
            (newData['membres'] as List<dynamic>).cast<Map<String, dynamic>>(),
          );
          membres.add({
            'id': 'm${membres.length + 1}',
            'nom': vote.nouveauMembreNom,
            'paye': false,
            'score': 50,
          });
          newData['membres'] = membres;
        }

        newData['votes'] = votes;

        final journal = List<Map<String, dynamic>>.from(
          (newData['journal'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ?? [],
        );
        journal.insert(0, {
          'quoi': 'VOTE_CLOS_${adopte ? 'ADOPTE' : 'REJETE'}_${vote.id}',
          'gestionnaire': provider.gestActifNom ?? '',
          'quand': now,
          'reference': ref,
        });
        newData['journal'] = journal;

        return provider.ecrire(newData, pin);
      },
    );

    if (ok == true && context.mounted) {
      afficherToast(context, 'Vote clos. ${adopte ? 'Proposition adoptée !' : 'Proposition rejetée.'}');
    }
  }
}

class _CarteVote extends StatelessWidget {
  final Vote vote;
  final List<Map<String, dynamic>> voix;
  final List<Membre> membres;
  final bool estGest;
  final String code;
  final VoidCallback onVoter;
  final VoidCallback? onClore;
  final VoidCallback onRecharger;

  const _CarteVote({
    required this.vote,
    required this.voix,
    required this.membres,
    required this.estGest,
    required this.code,
    required this.onVoter,
    this.onClore,
    required this.onRecharger,
  });

  @override
  Widget build(BuildContext context) {
    final oui = voix.where((v) => v['choix'] == 'oui').length;
    final non = voix.where((v) => v['choix'] == 'non').length;
    final abstention = voix.where((v) => v['choix'] == 'abstention').length;
    final total = membres.where((m) => m.pinVote != null).length;
    final participation = voix.length;

    return CarteTC(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  vote.question,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                    color: AppColors.encre,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: vote.clos ? AppColors.fondCode : AppColors.succesFond,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  vote.clos ? 'Clos' : 'En cours',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: vote.clos ? AppColors.texteDoux : AppColors.succes,
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
          const SizedBox(height: 12),
          // Résultats
          Row(
            children: [
              _VotePuce(label: '✓ Oui', valeur: oui, couleur: AppColors.succes),
              const SizedBox(width: 8),
              _VotePuce(label: '✗ Non', valeur: non, couleur: AppColors.alerte),
              const SizedBox(width: 8),
              _VotePuce(
                  label: '○ Abs.',
                  valeur: abstention,
                  couleur: AppColors.texteDoux),
              const Spacer(),
              Text(
                '$participation/$total votants',
                style: const TextStyle(fontSize: 12, color: AppColors.texteDoux),
              ),
            ],
          ),
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
          ],
        ],
      ),
    );
  }

  String _labelType(String type) {
    switch (type) {
      case 'admission':
        return 'Admission';
      case 'retirage':
        return 'Retirage';
      default:
        return 'Libre';
    }
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
