// ─────────────────────────────────────────────────────────────────────────────
// ScoreMembreScreen — Fiche Score de Confiance IA
// TontineClair — Système d'aide à la décision complet
// ─────────────────────────────────────────────────────────────────────────────

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/tontine.dart';
import '../models/score_modeles.dart';
import '../services/score_service.dart';
import '../services/supabase_service.dart';
import '../services/tontine_provider.dart';
import '../services/blockchain_service.dart';
import '../utils/app_colors.dart';
import '../utils/formatters.dart';
import '../widgets/app_widgets.dart';
import '../utils/app_localizations.dart';
import '../services/locale_service.dart';

// ─── Couleurs du score ────────────────────────────────────────────────────────
Color _couleurScore(int score) {
  if (score >= 80) return const Color(0xFF2E7D5B);
  if (score >= 65) return const Color(0xFF35407A);
  if (score >= 50) return const Color(0xFFD99A2B);
  if (score >= 35) return const Color(0xFFE07A2F);
  return const Color(0xFFC4453C);
}

Color _couleurRec(TypeRecommandation t) {
  switch (t) {
    case TypeRecommandation.positif:
      return const Color(0xFF2E7D5B);
    case TypeRecommandation.conseil:
      return const Color(0xFF35407A);
    case TypeRecommandation.info:
      return const Color(0xFF6B7280);
    case TypeRecommandation.alerte:
      return const Color(0xFFD99A2B);
    case TypeRecommandation.risque:
      return const Color(0xFFC4453C);
  }
}

IconData _iconeRec(TypeRecommandation t) {
  switch (t) {
    case TypeRecommandation.positif:
      return Icons.verified_rounded;
    case TypeRecommandation.conseil:
      return Icons.lightbulb_outline_rounded;
    case TypeRecommandation.info:
      return Icons.info_outline_rounded;
    case TypeRecommandation.alerte:
      return Icons.warning_amber_rounded;
    case TypeRecommandation.risque:
      return Icons.gpp_bad_rounded;
  }
}

// ─── Constantes quorum/majorité par défaut ───────────────────────────────────
const int _quorumDefaut = 50;    // % minimum de votants requis
const int _majoriteDefaut = 67;  // % de Oui requis pour adopter (≈2/3)

// ─── Écran ────────────────────────────────────────────────────────────────────
class ScoreMembreScreen extends StatefulWidget {
  final String code;
  final Membre membre;
  final bool estGestionnaire;

  const ScoreMembreScreen({
    super.key,
    required this.code,
    required this.membre,
    required this.estGestionnaire,
  });

  @override
  State<ScoreMembreScreen> createState() => _ScoreMembreScreenState();
}

class _ScoreMembreScreenState extends State<ScoreMembreScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabs;
  bool _chargement = true;
  List<HistoriqueScore> _historique = [];
  ScoreDetail? _scoreDetail;
  List<RecommandationIA> _recommandations = [];
  List<PropositionRetrait> _propositions = [];

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _charger());
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _charger() async {
    setState(() => _chargement = true);
    try {
      final toutesVoix = await SupabaseService.lireVoix(widget.code);
      final voixMembre = toutesVoix
          .where((v) => (v['membre_id'] as String?) == widget.membre.id)
          .toList();

      // ── Calcul du score (SOURCE UNIQUE : ScoreService) ───────────────────
      // IMPORTANT : lire le membre depuis le provider RECHARGÉ (pas widget.membre
      // qui est immuable et peut contenir l'ancien scoreOverride).
      // Après chargerTontine(), le JSONB Supabase est relu — scoreOverride y est
      // présent et ScoreService l'utilisera directement.
      if (!mounted) return;
      final data   = context.read<TontineProvider>().courante!.data;
      // Membre rechargé depuis Supabase (avec scoreOverride si modifié)
      final membreFrais = data.membres.where((m) => m.id == widget.membre.id).firstOrNull
                          ?? widget.membre;
      final detail = ScoreService.calculerScore(data, membreFrais.id, voixMembre);
      final _langIA = context.read<LocaleService>().langue.code;
      final recs   = ScoreService.genererRecommandations(data, membreFrais, detail, voixMembre, langueCode: _langIA);

      // ── Historique des scores (v6) ───────────────────────────────────────
      List<HistoriqueScore> historique = [];
      try {
        final histRaw = await SupabaseService.rpc(
          'lire_historique_score',
          {'p_code': widget.code, 'p_membre_id': widget.membre.id},
        );
        if (histRaw is List) {
          historique = histRaw
              .map((e) => HistoriqueScore.fromJson(e as Map<String, dynamic>))
              .toList();
        }
      } catch (_) {
        // Table scores_historique absente (avant v6) — mode dégradé silencieux
      }

      // ── Backfill automatique : initialiser le score si historique vide ───
      // Si la table v6 vient d'être créée et qu'aucun historique n'existe
      // pour ce membre, on insère l'entrée initiale avec le score calculé.
      if (historique.isEmpty && detail.score != 50) {
        try {
          await SupabaseService.rpc('init_score_membre', {
            'p_code':      widget.code,
            'p_membre_id': widget.membre.id,
            'p_score':     detail.score,
            'p_desc':      'Score calculé depuis les données existantes '
                           '(${detail.composantes.length} composantes)',
          });
          // Re-lire l'historique après init
          final histRaw2 = await SupabaseService.rpc(
            'lire_historique_score',
            {'p_code': widget.code, 'p_membre_id': widget.membre.id},
          );
          if (histRaw2 is List) {
            historique = histRaw2
                .map((e) => HistoriqueScore.fromJson(e as Map<String, dynamic>))
                .toList();
          }
        } catch (_) {
          // v6 non déployée — silencieux, l'app reste fonctionnelle
        }
      }

      // ── Propositions de retrait (v6) ─────────────────────────────────────
      List<PropositionRetrait> propositions = [];
      try {
        final propRaw = await SupabaseService.rpc(
          'lire_propositions_retrait',
          {'p_code': widget.code},
        );
        if (propRaw is List) {
          propositions = propRaw
              .where((e) =>
                  (e as Map<String, dynamic>)['membreId'] == widget.membre.id)
              .map((e) => PropositionRetrait.fromJson(e as Map<String, dynamic>))
              .toList();
        }
      } catch (_) {}

      if (!mounted) return;

      setState(() {
        _historique = historique;
        _scoreDetail = detail;
        _recommandations = recs;
        _propositions = propositions;
        _chargement = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _chargement = false);
      afficherToast(context, 'Erreur : $e', estErreur: true);
    }
  }

  // ── Enregistrer score dans l'historique v6 ───────────────────────────────
  Future<void> _enregistrerScoreV6({
    required int score,
    required int scorePrecedent,
    required String evenement,
    required String description,
    String? gestionnaire,
  }) async {
    try {
      await SupabaseService.rpc('enregistrer_score', {
        'p_code': widget.code,
        'p_membre_id': widget.membre.id,
        'p_score': score,
        'p_score_prec': scorePrecedent,
        'p_evenement': evenement,
        'p_description': description,
        if (gestionnaire != null) 'p_gestionnaire': gestionnaire,
      });
    } catch (_) {
      // v6 non déployée — silencieux
    }
  }

  // ── Modal : Proposer le retrait ───────────────────────────────────────────
  void _afficherModalRetrait(BuildContext ctx, TontineData data) {
    final motifCtrl = TextEditingController();
    final pinCtrl = TextEditingController();
    int quorum = _quorumDefaut;
    int majorite = _majoriteDefaut;
    bool loading = false;
    String? erreur;

    showModalBottomSheet(
      context: ctx,
      isScrollControlled: true,
      backgroundColor: AppColors.fondPapier,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => StatefulBuilder(
        builder: (sCtx, setSt) => Padding(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 20,
            bottom: MediaQuery.of(sCtx).viewInsets.bottom + 24,
          ),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Handle
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

                // Titre
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: const Color(0xFFC4453C).withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Icon(Icons.gpp_bad_rounded,
                          size: 18, color: Color(0xFFC4453C)),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            context.tr('proposer_retrait'),
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 17,
                              color: Color(0xFFC4453C),
                            ),
                          ),
                          Text(
                            context.tr('vote_securise_collectif'),
                            style: TextStyle(
                                fontSize: 11, color: AppColors.texteDoux),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                // Résumé du membre
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: AppColors.fondCode,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.lignes),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.person_rounded,
                              size: 15, color: AppColors.texteDoux),
                          const SizedBox(width: 6),
                          Text(
                            widget.membre.nom,
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 14,
                              color: AppColors.encre,
                            ),
                          ),
                          if (widget.membre.role != null) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 7, vertical: 2),
                              decoration: BoxDecoration(
                                color: AppColors.encreDoux.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                widget.membre.role!,
                                style: const TextStyle(
                                    fontSize: 10, color: AppColors.encreDoux),
                              ),
                            ),
                          ],
                        ],
                      ),
                      if (_scoreDetail != null) ...[
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            // Mini cercle score
                            Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: _couleurScore(_scoreDetail!.score)
                                    .withValues(alpha: 0.12),
                                border: Border.all(
                                    color: _couleurScore(_scoreDetail!.score),
                                    width: 2),
                              ),
                              child: Center(
                                child: Text(
                                  '${_scoreDetail!.score}',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w900,
                                    color: _couleurScore(_scoreDetail!.score),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '${ScoreService.emojiNiveau(_scoreDetail!.niveau)} ${ScoreService.labelNiveau(_scoreDetail!.niveau)}',
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w700,
                                      color: _couleurScore(_scoreDetail!.score),
                                    ),
                                  ),
                                  Text(
                                    "${context.tr('score_confiance')} : ${_scoreDetail!.score}/100",
                                    style: const TextStyle(
                                        fontSize: 11,
                                        color: AppColors.texteDoux),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        // ── Badge "Score modifié manuellement" ─────────────
                        Builder(builder: (bCtx) {
                          final m = (data?.membres ?? <Membre>[])
                              .where((x) => x.id == widget.membre.id)
                              .firstOrNull;
                          if (m == null || !m.aScoreOverride) {
                            return const SizedBox.shrink();
                          }
                          return Container(
                            margin: const EdgeInsets.only(top: 6),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 5),
                            decoration: BoxDecoration(
                              color: const Color(0xFFFFF3CD),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                  color: AppColors.orFonce.withValues(alpha: 0.4)),
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.edit_note_rounded,
                                    size: 13, color: AppColors.orFonce),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    'Score modifié manuellement'
                                    '${m.adminOverride != null ? " par ${m.adminOverride}" : ""}'
                                    '${m.motifOverride != null ? " — ${m.motifOverride}" : ""}',
                                    style: const TextStyle(
                                        fontSize: 10.5,
                                        color: AppColors.orFonce),
                                  ),
                                ),
                              ],
                            ),
                          );
                        }),
                        const SizedBox(height: 10),
                        // Raisons principales (impact négatif)
                        const Text(
                          'Facteurs négatifs identifiés :',
                          style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: AppColors.texteDoux),
                        ),
                        const SizedBox(height: 4),
                        ..._scoreDetail!.composantes
                            .where((c) => c.impact < 0)
                            .take(3)
                            .map((c) => Padding(
                                  padding: const EdgeInsets.only(top: 3),
                                  child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      const Icon(Icons.remove_circle_outline,
                                          size: 12, color: Color(0xFFC4453C)),
                                      const SizedBox(width: 5),
                                      Expanded(
                                        child: Text(
                                          '${c.label} : ${c.detail}',
                                          style: const TextStyle(
                                              fontSize: 11,
                                              color: AppColors.texteDoux),
                                        ),
                                      ),
                                    ],
                                  ),
                                )),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 16),

                // Recommandations IA pertinentes
                if (_recommandations
                    .where((r) =>
                        r.type == TypeRecommandation.alerte ||
                        r.type == TypeRecommandation.risque)
                    .isNotEmpty) ...[
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFF3CD),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFFFFD700)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.auto_awesome_rounded,
                                size: 13, color: Color(0xFFD99A2B)),
                            const SizedBox(width: 5),
                            Text(
                              context.tr('recommandations_ia_consultatif'),
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFF856404),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        ..._recommandations
                            .where((r) =>
                                r.type == TypeRecommandation.alerte ||
                                r.type == TypeRecommandation.risque)
                            .map((r) => Padding(
                                  padding: const EdgeInsets.only(top: 3),
                                  child: Text(
                                    '• ${r.message}',
                                    style: const TextStyle(
                                      fontSize: 11,
                                      color: Color(0xFF856404),
                                    ),
                                  ),
                                )),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                ],

                // ── Motif obligatoire ─────────────────────────────────────
                ChampLabel(label: context.tr('motif_proposition')),
                TextField(
                  controller: motifCtrl,
                  maxLines: 3,
                  maxLength: 300,
                  decoration: InputDecoration(
                    hintText:
                        context.tr('motif_retrait_hint'),
                    hintStyle: TextStyle(
                        fontSize: 12, color: AppColors.texteDoux.withValues(alpha: 0.7)),
                  ),
                  onChanged: (_) {
                    if (erreur != null) setSt(() => erreur = null);
                  },
                ),

                // ── Paramètres du vote ────────────────────────────────────
                const SizedBox(height: 4),
                _SectionTitreCompacte(
                    icone: Icons.tune_rounded,
                    titre: 'Règles du vote'),
                const SizedBox(height: 8),

                // Quorum
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(
                                context.tr('quorum_minimum'),
                                style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: AppColors.encre),
                              ),
                              const SizedBox(width: 4),
                              Text(
                                '$quorum%',
                                style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w800,
                                    color: AppColors.encreDoux),
                              ),
                            ],
                          ),
                          Text(
                            context.tr('taux_participation_requis'),
                            style: TextStyle(
                                fontSize: 10, color: AppColors.texteDoux),
                          ),
                        ],
                      ),
                    ),
                    Row(
                      children: [
                        _BtnAjusteur(
                          icone: Icons.remove,
                          onTap: quorum > 30
                              ? () => setSt(() => quorum -= 10)
                              : null,
                        ),
                        const SizedBox(width: 4),
                        _BtnAjusteur(
                          icone: Icons.add,
                          onTap: quorum < 90
                              ? () => setSt(() => quorum += 10)
                              : null,
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 10),

                // Majorité
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(
                                context.tr('majorite_requise'),
                                style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: AppColors.encre),
                              ),
                              const SizedBox(width: 4),
                              Text(
                                '$majorite%',
                                style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w800,
                                    color: majorite >= 67
                                        ? const Color(0xFF2E7D5B)
                                        : AppColors.encreDoux),
                              ),
                              if (majorite >= 67) ...[
                                const SizedBox(width: 4),
                                const Text(
                                  '(2/3)',
                                  style: TextStyle(
                                      fontSize: 10,
                                      color: AppColors.texteDoux),
                                ),
                              ],
                            ],
                          ),
                          Text(
                            context.tr('votes_pour_requis'),
                            style: TextStyle(
                                fontSize: 10, color: AppColors.texteDoux),
                          ),
                        ],
                      ),
                    ),
                    Row(
                      children: [
                        _BtnAjusteur(
                          icone: Icons.remove,
                          onTap: majorite > 51
                              ? () => setSt(() => majorite -= 1)
                              : null,
                        ),
                        const SizedBox(width: 4),
                        _BtnAjusteur(
                          icone: Icons.add,
                          onTap: majorite < 90
                              ? () => setSt(() => majorite += 1)
                              : null,
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 14),

                // ── PIN gestionnaire ──────────────────────────────────────
                ChampLabel(label: context.tr('votre_pin_gest')),
                TextField(
                  controller: pinCtrl,
                  keyboardType: TextInputType.number,
                  obscureText: true,
                  maxLength: 6,
                  decoration: const InputDecoration(
                    hintText: '••••',
                    counterText: '',
                  ),
                  onChanged: (_) {
                    if (erreur != null) setSt(() => erreur = null);
                  },
                ),

                if (erreur != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    erreur!,
                    style: const TextStyle(
                        color: Color(0xFFC4453C), fontSize: 12),
                  ),
                ],

                const SizedBox(height: 10),

                // Avertissement
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFF3CD),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFFFFD700)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.gavel_rounded,
                              size: 13, color: Color(0xFFD99A2B)),
                          const SizedBox(width: 5),
                          Expanded(
                            child: Text(
                              context.tr('conditions_vote_retrait'),
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF856404),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 5),
                      Text(
                        '• Vote sécurisé : 1 voix/membre, PIN obligatoire, irréversible\n'
                        '• Quorum : $quorum% minimum de participation requis\n'
                        '• Majorité : $majorite% des voix Pour requis\n'
                        '• Le membre concerné ne peut pas influencer le résultat\n'
                        '• Vote accepté → statut "Retiré" (historique conservé)\n'
                        '• Vote refusé → membre maintenu + plan de suivi IA',
                        style: const TextStyle(
                            fontSize: 10, color: Color(0xFF856404)),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 16),

                if (loading)
                  const Center(child: CircularProgressIndicator())
                else
                  BtnPrincipal(
                    label: context.tr('creer_vote_retrait'),
                    couleur: const Color(0xFFC4453C),
                    icone: Icons.how_to_vote_rounded,
                    onTap: () async {
                      if (motifCtrl.text.trim().length < 20) {
                        setSt(() => erreur =
                            'Le motif doit contenir au moins 20 caractères.');
                        return;
                      }
                      if (pinCtrl.text.trim().length < 4) {
                        setSt(() => erreur =
                            'PIN gestionnaire obligatoire (4-6 chiffres).');
                        return;
                      }
                      setSt(() => loading = true);

                      final provider = context.read<TontineProvider>();
                      final gestNom = provider.gestActifNom ?? '';

                      try {
                        await _creerVoteRetrait(
                          ctx: ctx,
                          data: data,
                          provider: provider,
                          gestNom: gestNom,
                          gestPin: pinCtrl.text.trim(),
                          motif: motifCtrl.text.trim(),
                          quorum: quorum,
                          majorite: majorite,
                        );
                        if (sCtx.mounted) Navigator.pop(sCtx);
                      } catch (e) {
                        setSt(() {
                          erreur = 'Erreur : $e';
                          loading = false;
                        });
                      }
                    },
                  ),

                const SizedBox(height: 8),
                BtnSecondaire(
                  label: 'Annuler',
                  onTap: () => Navigator.pop(sCtx),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── Créer le vote de retrait automatiquement ─────────────────────────────
  Future<void> _creerVoteRetrait({
    required BuildContext ctx,
    required TontineData data,
    required TontineProvider provider,
    required String gestNom,
    required String gestPin,
    required String motif,
    required int quorum,
    required int majorite,
  }) async {
    final voteId = 'ret_${DateTime.now().millisecondsSinceEpoch}';
    final now = DateTime.now().toIso8601String();
    final question = 'Faut-il retirer ${widget.membre.nom} de la tontine ?';

    final newData = data.toJson();

    // ── Créer le vote dans tontines.data['votes'] ─────────────────────────
    final votes = List<Map<String, dynamic>>.from(
      (newData['votes'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ?? [],
    );
    votes.insert(0, {
      'id': voteId,
      'type': 'retrait',
      'sujet': question,
      'question': question,
      'description':
          'Proposition de retrait de ${widget.membre.nom}.\n'
          'Motif : $motif\n'
          'Score au moment de la proposition : ${_scoreDetail?.score ?? 0}/100\n'
          'Quorum requis : $quorum% · Majorité requise : $majorite%',
      'creePar': gestNom,
      'createur': gestNom,
      'le': now,
      'dateCreation': now,
      'statut': 'ouvert',
      'clos': false,
      'mode': 'securise',
      'membreConcerneId': widget.membre.id,
      'membreConcerneNom': widget.membre.nom,
      'motifRetrait': motif,
      'scoreAuMoment': _scoreDetail?.score ?? 0,
      'quorum': quorum,
      'majorite': majorite,
    });
    newData['votes'] = votes;

    // ── Journal d'audit ───────────────────────────────────────────────────
    final journal = List<Map<String, dynamic>>.from(
      (newData['journal'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ?? [],
    );
    journal.insert(0, {
      'quoi':         'RETRAIT_PROPOSE:${widget.membre.id}:score=${_scoreDetail?.score ?? 0}'
                      ':quorum=${quorum}%:majorite=${majorite}%',
      'gestionnaire': gestNom,
      'quand':        now,
    });
    newData['journal'] = journal;

    // ── Sauvegarder dans Supabase ─────────────────────────────────────────
    await SupabaseService.ecrireTontine(
      code: widget.code,
      nom: gestNom,
      pin: gestPin,
      data: newData,
    );

    // ── Enregistrer dans la table dédiée (v6) ────────────────────────────
    try {
      await SupabaseService.rpc('proposer_retrait', {
        'p_code': widget.code,
        'p_nom': gestNom,
        'p_pin': gestPin,
        'p_membre_id': widget.membre.id,
        'p_membre_nom': widget.membre.nom,
        'p_score': _scoreDetail?.score ?? 0,
        'p_motif': motif,
        'p_vote_id': voteId,
        'p_quorum': quorum,
        'p_majorite': majorite,
      });
    } catch (_) {
      // v6 non déployée — continue sans table dédiée
    }

    // ── Enregistrer dans l'historique des scores (v6) ────────────────────
    await _enregistrerScoreV6(
      score: _scoreDetail?.score ?? 0,
      scorePrecedent: _scoreDetail?.score ?? 0,
      evenement: 'retrait',
      description: 'Proposition de retrait soumise au vote. Motif : $motif',
      gestionnaire: gestNom,
    );

    // ── BLOCKCHAIN : retrait proposé (non-bloquant) ───────────────────
    BlockchainService.enregistrerRetraitPropose(
      tontineCode: widget.code,
      membreId   : widget.membre.id,
      membreNom  : widget.membre.nom,
      score      : _scoreDetail?.score ?? 0,
    ).catchError((e) {
      if (kDebugMode) debugPrint('[Blockchain] retrait_propose erreur: $e');
      return BlockchainResultat(ok: false, erreur: '$e', phase: 1);
    });
    // ────────────────────────────────────────────────────────────────────

    // ── NOTIFICATION : retrait proposé ───────────────────────────────────
    {
      final _langRP = Provider.of<LocaleService>(ctx, listen: false).langue.code;
      final _tRP = SupabaseService.notifTexte(
        'retrait_propose',
        _langRP,
        vars: {
          'nom'  : widget.membre.nom,
          'score': '${_scoreDetail?.score ?? 0}',
        },
      );
      SupabaseService.envoyerNotification(
        code    : widget.code,
        type    : 'retrait_propose',
        titre   : _tRP['titre']!,
        message : _tRP['message']!,
        donneesExtra: {'membre_id': widget.membre.id},
      );
    }
    // ─────────────────────────────────────────────────────────────────────

    await provider.chargerTontine(widget.code);
    await _charger();

    if (ctx.mounted) {
      afficherToast(
        ctx,
        '✅ Vote de retrait créé ! Les membres peuvent maintenant voter.',
      );
    }
  }

  // ── Modifier manuellement le score (admin uniquement) ────────────────────
  void _afficherModalModifScore(BuildContext ctx, TontineData data) {
    // Afficher le score effectif actuel (scoreOverride si présent, sinon calculé)
    final scoreCtrl = TextEditingController(
        text: '${_scoreDetail?.score ?? widget.membre.scoreEffectif}');
    final motifCtrl = TextEditingController();
    final pinCtrl = TextEditingController();
    bool loading = false;
    String? erreur;

    showModalBottomSheet(
      context: ctx,
      isScrollControlled: true,
      backgroundColor: AppColors.fondPapier,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => StatefulBuilder(
        builder: (sCtx, setSt) => Padding(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 20,
            bottom: MediaQuery.of(sCtx).viewInsets.bottom + 24,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
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
              Row(
                children: [
                  const Icon(Icons.admin_panel_settings_rounded,
                      size: 18, color: AppColors.encreDoux),
                  const SizedBox(width: 8),
                  Text(
                    context.tr('modifier_score_manuel'),
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                      color: AppColors.encre,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                context.tr('reserve_admin_audit'),
                style: TextStyle(fontSize: 11, color: AppColors.texteDoux),
              ),
              const SizedBox(height: 16),
              ChampLabel(label: context.tr('nouveau_score')),
              TextField(
                controller: scoreCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  hintText: 'Ex : 72',
                  suffixText: '/100',
                ),
                onChanged: (_) {
                  if (erreur != null) setSt(() => erreur = null);
                },
              ),
              const SizedBox(height: 10),
              ChampLabel(label: context.tr('motif_modification')),
              TextField(
                controller: motifCtrl,
                maxLines: 2,
                maxLength: 200,
                decoration: InputDecoration(
                  hintText: context.tr('motif_modif_hint'),
                ),
                onChanged: (_) {
                  if (erreur != null) setSt(() => erreur = null);
                },
              ),
              const SizedBox(height: 10),
              ChampLabel(label: context.tr('votre_pin_gest')),
              TextField(
                controller: pinCtrl,
                keyboardType: TextInputType.number,
                obscureText: true,
                maxLength: 6,
                decoration: const InputDecoration(
                  hintText: '••••',
                  counterText: '',
                ),
              ),
              if (erreur != null) ...[
                const SizedBox(height: 6),
                Text(erreur!,
                    style: const TextStyle(
                        color: Color(0xFFC4453C), fontSize: 12)),
              ],
              const SizedBox(height: 16),
              if (loading)
                const Center(child: CircularProgressIndicator())
              else
                BtnPrincipal(
                  label: 'Enregistrer la modification',
                  onTap: () async {
                    final nouveauScore = int.tryParse(scoreCtrl.text.trim());
                    if (nouveauScore == null ||
                        nouveauScore < 0 ||
                        nouveauScore > 100) {
                      setSt(() => erreur = 'Score invalide (0-100)');
                      return;
                    }
                    if (motifCtrl.text.trim().length < 10) {
                      setSt(
                          () => erreur = 'Motif obligatoire (min. 10 caractères)');
                      return;
                    }
                    if (pinCtrl.text.trim().length < 4) {
                      setSt(() => erreur = 'PIN obligatoire');
                      return;
                    }
                    setSt(() => loading = true);

                    final provider = context.read<TontineProvider>();
                    // provider.modifierScoreMembre() utilise _gestActifNom en interne
                    final ancienScore = _scoreDetail?.score ?? widget.membre.scoreEffectif;

                    try {
                      // ── RPC atomique v13 via provider ───────────────────────
                      // provider.modifierScoreMembre() :
                      //   1. Appelle modifier_score_membre (RPC SQL atomique)
                      //   2. Recharge la tontine depuis Supabase
                      //   3. Appelle notifyListeners() → tous les écrans
                      //      abonnés (classement, membres, dashboard) se
                      //      rebuilderont avec le nouveau scoreOverride.
                      final result = await provider.modifierScoreMembre(
                        membreId: widget.membre.id,
                        nouveau:  nouveauScore,
                        motif:    motifCtrl.text.trim(),
                        pin:      pinCtrl.text.trim(),
                      );

                      if (result['ok'] != true) {
                        setSt(() {
                          erreur  = result['message'] as String? ?? 'Erreur inconnue';
                          loading = false;
                        });
                        return;
                      }

                      // ── Fermer la dialog AVANT de recharger ─────────────────
                      // Ordre important : on ferme d'abord, puis on recharge
                      // l'écran parent. Inverser les deux provoquerait un setState
                      // sur un widget démontant la dialog.
                      if (sCtx.mounted) Navigator.pop(sCtx);

                      // ── Réinitialiser _scoreDetail pour forcer l'affichage ──
                      // du spinner pendant le rechargement (évite l'affichage
                      // de l'ancien score si _charger() est lent).
                      if (mounted) setState(() => _scoreDetail = null);

                      // ── Rechargement local (historique + recommandations) ───
                      // _charger() relit scores_historique et recalcule le score
                      // via ScoreService, qui utilisera scoreOverride.
                      await _charger();
                      if (mounted) {
                        // Utiliser context du State (pas ctx du builder) pour éviter async-gap warning
                        afficherToast(context,
                          '✅ Score modifié : $ancienScore → $nouveauScore');
                        // Notification push à tous les membres
                        final langCode = Provider.of<LocaleService>(context, listen: false).langue.code;
                        final tNotif = SupabaseService.notifTexte(
                          'score_modifie',
                          langCode,
                          vars: {
                            'nom': widget.membre.nom,
                            'ancien': ancienScore.toString(),
                            'nouveau': nouveauScore.toString(),
                          },
                        );
                        SupabaseService.envoyerNotification(
                          code: widget.code,
                          type: 'score_modifie',
                          titre: tNotif['titre']!,
                          message: tNotif['message']!,
                          donneesExtra: {'membre_id': widget.membre.id},
                        );
                      }
                    } catch (e) {
                      // Si la dialog est encore ouverte, afficher l'erreur dedans
                      // Sinon, afficher un toast dans l'écran parent
                      if (sCtx.mounted) {
                        setSt(() {
                          erreur  = 'Erreur : $e';
                          loading = false;
                        });
                      } else if (mounted) {
                        afficherToast(context, 'Erreur : $e', estErreur: true);
                      }
                    }
                  },
                ),
              const SizedBox(height: 8),
              BtnSecondaire(
                  label: 'Annuler', onTap: () => Navigator.pop(sCtx)),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<TontineProvider>();
    final data = provider.courante?.data;
    if (data == null) {
      return const Scaffold(
          body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      backgroundColor: AppColors.fondPapier,
      appBar: AppBar(
        backgroundColor: AppColors.fondPapier,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded,
              size: 18, color: AppColors.encre),
          onPressed: () => Navigator.pop(context),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.membre.nom,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: AppColors.encre,
              ),
            ),
            Text(
              context.tr('score_confiance_ia'),
              style: TextStyle(fontSize: 11, color: AppColors.texteDoux),
            ),
          ],
        ),
        actions: [
          if (widget.estGestionnaire)
            IconButton(
              icon: const Icon(Icons.edit_note_rounded,
                  size: 20, color: AppColors.encreDoux),
              tooltip: context.tr('modifier_score_manuel'),
              onPressed: () => _afficherModalModifScore(context, data),
            ),
          IconButton(
            icon: const Icon(Icons.refresh_rounded,
                size: 20, color: AppColors.encreDoux),
            onPressed: _charger,
            tooltip: context.tr('recalculer'),
          ),
        ],
        bottom: TabBar(
          controller: _tabs,
          labelColor: AppColors.encreDoux,
          unselectedLabelColor: AppColors.texteDoux,
          indicatorColor: AppColors.encreDoux,
          indicatorWeight: 2,
          labelStyle:
              const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          tabs: [
            Tab(text: context.tr('tab_score_ia')),
            Tab(text: context.tr('historique')),
            Tab(text: context.tr('decisions')),
          ],
        ),
      ),
      body: _chargement
          ? const Center(child: CircularProgressIndicator())
          : TabBarView(
              controller: _tabs,
              children: [
                _ongletScore(data),
                _ongletHistorique(),
                _ongletDecisions(data),
              ],
            ),
    );
  }

  // ── Onglet 1 : Score & IA ─────────────────────────────────────────────────
  Widget _ongletScore(TontineData data) {
    final detail = _scoreDetail;
    if (detail == null) {
      return const Center(child: Text('Données insuffisantes'));
    }

    // Vérifier si le membre est retiré
    final estRetire = widget.membre.role?.toLowerCase() == 'retiré' ||
        widget.membre.role?.toLowerCase() == 'retire' ||
        widget.membre.role?.toLowerCase() == 'inactif';

    return RefreshIndicator(
      onRefresh: _charger,
      color: AppColors.encreDoux,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Badge "Membre retiré" si applicable
          if (estRetire) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFC4453C).withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                    color: const Color(0xFFC4453C).withValues(alpha: 0.3)),
              ),
              child: const Row(
                children: [
                  Icon(Icons.person_off_rounded,
                      size: 16, color: Color(0xFFC4453C)),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Ce membre a été retiré de la tontine suite à un vote collectif. '
                      'Son historique complet est conservé à des fins d\'archivage.',
                      style: TextStyle(
                          fontSize: 12, color: Color(0xFFC4453C), height: 1.4),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],

          // Carte score principal
          _CarteScorePrincipal(
            scoreDetail: detail,
            membre: widget.membre,
            historique: _historique,
          ),
          const SizedBox(height: 16),

          // Composantes détaillées
          _SectionTitre(
              icone: Icons.analytics_outlined, titre: 'Détail du calcul'),
          const SizedBox(height: 8),
          ...detail.composantes.map((c) => _LigneComposante(composante: c)),
          const SizedBox(height: 16),

          // Recommandations IA
          if (_recommandations.isNotEmpty) ...[
            _SectionTitre(
                icone: Icons.auto_awesome_rounded,
                titre: 'Recommandations de l\'IA'),
            const SizedBox(height: 4),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: AppColors.fondCode,
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Row(
                children: [
                  Icon(Icons.info_outline_rounded,
                      size: 12, color: AppColors.texteDoux),
                  SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'L\'IA assiste uniquement. Toutes les décisions restent à votre initiative et aux membres.',
                      style:
                          TextStyle(fontSize: 10, color: AppColors.texteDoux),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            ..._recommandations
                .map((r) => _CarteRecommandation(rec: r)),
            const SizedBox(height: 16),
          ],

          // Plan de suivi IA (si vote de retrait refusé)
          if (_planSuiviActif(data)) ...[
            _CartePlanSuivi(
              membre: widget.membre,
              recommandations: _recommandations,
              scoreDetail: detail,
            ),
            const SizedBox(height: 16),
          ],

          // Bouton retrait (gestionnaire uniquement, membre non retiré)
          if (widget.estGestionnaire && !estRetire) ...[
            const Divider(color: AppColors.lignes),
            const SizedBox(height: 8),
            BtnPrincipal(
              label: 'Proposer le retrait du membre',
              couleur: const Color(0xFFC4453C),
              icone: Icons.gpp_bad_rounded,
              onTap: () => _afficherModalRetrait(context, data),
            ),
            const SizedBox(height: 4),
            Center(
              child: Text(
                'Réservé aux gestionnaires · Décision collective par vote sécurisé',
                style:
                    TextStyle(fontSize: 10, color: AppColors.texteDoux),
                textAlign: TextAlign.center,
              ),
            ),
          ],

          const SizedBox(height: 32),
        ],
      ),
    );
  }

  // Vérifie si un plan de suivi est actif (vote de retrait refusé)
  bool _planSuiviActif(TontineData data) {
    final votesRetrait = data.votes.where((v) =>
        v.type == 'retrait' &&
        v.clos &&
        v.adopte == false &&
        (v.question.contains(widget.membre.nom) ||
            (v.description?.contains(widget.membre.id) ?? false)));
    return votesRetrait.isNotEmpty;
  }

  // ── Onglet 2 : Historique ─────────────────────────────────────────────────
  Widget _ongletHistorique() {
    if (_historique.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.timeline_rounded, size: 48, color: AppColors.texteDoux),
            const SizedBox(height: 12),
            const Text(
              'Aucun historique disponible',
              style: TextStyle(color: AppColors.texteDoux, fontSize: 14),
            ),
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                'L\'historique s\'enrichit automatiquement après chaque événement '
                '(cotisation, prêt, vote, sanction...).',
                style: const TextStyle(color: AppColors.texteDoux, fontSize: 11),
                textAlign: TextAlign.center,
              ),
            ),
            if (_scoreDetail != null) ...[
              const SizedBox(height: 24),
              _CarteHistoriqueSimulee(scoreDetail: _scoreDetail!),
            ],
          ],
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: _historique.length,
      separatorBuilder: (_, __) =>
          const Divider(color: AppColors.lignes, height: 1),
      itemBuilder: (_, i) => _LigneHistorique(entree: _historique[i]),
    );
  }

  // ── Onglet 3 : Décisions ──────────────────────────────────────────────────
  Widget _ongletDecisions(TontineData data) {
    final votesRetrait = data.votes
        .where((v) =>
            v.type == 'retrait' &&
            (v.question.contains(widget.membre.nom) ||
                (v.description?.contains(widget.membre.id) ?? false)))
        .toList();

    if (votesRetrait.isEmpty && _propositions.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.gavel_rounded,
                size: 48, color: AppColors.texteDoux),
            const SizedBox(height: 12),
            const Text(
              'Aucune décision collective',
              style: TextStyle(color: AppColors.texteDoux, fontSize: 14),
            ),
            const SizedBox(height: 6),
            Text(
              'Les votes de retrait proposés apparaîtront ici.',
              style:
                  TextStyle(color: AppColors.texteDoux, fontSize: 11),
            ),
          ],
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (votesRetrait.isNotEmpty) ...[
          _SectionTitre(
              icone: Icons.how_to_vote_rounded, titre: 'Votes de retrait'),
          const SizedBox(height: 8),
          ...votesRetrait
              .map((v) => _CarteVoteRetrait(vote: v)),
          const SizedBox(height: 16),
        ],
        if (_propositions.isNotEmpty) ...[
          _SectionTitre(
              icone: Icons.history_rounded,
              titre: 'Historique des propositions'),
          const SizedBox(height: 8),
          ..._propositions
              .map((p) => _CarteProposition(proposition: p)),
        ],
      ],
    );
  }
}

// ─── Bouton ajusteur +/- ─────────────────────────────────────────────────────
class _BtnAjusteur extends StatelessWidget {
  final IconData icone;
  final VoidCallback? onTap;

  const _BtnAjusteur({required this.icone, this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          color: onTap != null ? AppColors.fondCode : AppColors.lignes,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
              color: onTap != null ? AppColors.lignes : AppColors.lignes),
        ),
        child: Icon(
          icone,
          size: 16,
          color: onTap != null ? AppColors.encreDoux : AppColors.texteDoux,
        ),
      ),
    );
  }
}

// ─── Section titre compacte ───────────────────────────────────────────────────
class _SectionTitreCompacte extends StatelessWidget {
  final IconData icone;
  final String titre;

  const _SectionTitreCompacte({required this.icone, required this.titre});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icone, size: 14, color: AppColors.encreDoux),
        const SizedBox(width: 5),
        Text(
          titre,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: AppColors.encre,
          ),
        ),
      ],
    );
  }
}

// ─── Carte score principal ────────────────────────────────────────────────────
class _CarteScorePrincipal extends StatelessWidget {
  final ScoreDetail scoreDetail;
  final Membre membre;
  final List<HistoriqueScore> historique;

  const _CarteScorePrincipal({
    required this.scoreDetail,
    required this.membre,
    required this.historique,
  });

  @override
  Widget build(BuildContext context) {
    final score = scoreDetail.score;
    final couleur = _couleurScore(score);
    final niveau = ScoreService.labelNiveau(scoreDetail.niveau);
    final emoji = ScoreService.emojiNiveau(scoreDetail.niveau);

    // Évolution par rapport au score précédent
    int? evolution;
    if (historique.isNotEmpty) {
      evolution = historique.first.evolution;
    }

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: couleur.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: couleur.withValues(alpha: 0.3)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              // Cercle score
              Container(
                width: 84,
                height: 84,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: couleur.withValues(alpha: 0.12),
                  border: Border.all(color: couleur, width: 3),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      '$score',
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w900,
                        color: couleur,
                        height: 1,
                      ),
                    ),
                    Text(
                      '/100',
                      style: TextStyle(
                          fontSize: 10,
                          color: couleur.withValues(alpha: 0.7)),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          '$emoji $niveau',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: couleur,
                          ),
                        ),
                        if (evolution != null) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: evolution > 0
                                  ? const Color(0xFF2E7D5B).withValues(alpha: 0.1)
                                  : evolution < 0
                                      ? const Color(0xFFC4453C)
                                          .withValues(alpha: 0.1)
                                      : AppColors.fondCode,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              evolution > 0
                                  ? '↑ +$evolution'
                                  : evolution < 0
                                      ? '↓ $evolution'
                                      : '→ stable',
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                color: evolution > 0
                                    ? const Color(0xFF2E7D5B)
                                    : evolution < 0
                                        ? const Color(0xFFC4453C)
                                        : AppColors.texteDoux,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      membre.nom,
                      style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: AppColors.encre),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Calculé le ${Formatters.dateFormatee(scoreDetail.calculeLe)}',
                      style: const TextStyle(
                          fontSize: 11, color: AppColors.texteDoux),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // Barre de progression
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: score / 100,
              backgroundColor: AppColors.fondCode,
              valueColor: AlwaysStoppedAnimation<Color>(couleur),
              minHeight: 8,
            ),
          ),
          const SizedBox(height: 8),
          // Légende niveaux compacte
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: const [
              Text('🔴 0', style: TextStyle(fontSize: 9)),
              Text('🟠 35', style: TextStyle(fontSize: 9)),
              Text('🟡 50', style: TextStyle(fontSize: 9)),
              Text('🔵 65', style: TextStyle(fontSize: 9)),
              Text('🟢 80', style: TextStyle(fontSize: 9)),
            ],
          ),
        ],
      ),
    );
  }
}

// ─── Section titre ────────────────────────────────────────────────────────────
class _SectionTitre extends StatelessWidget {
  final IconData icone;
  final String titre;

  const _SectionTitre({required this.icone, required this.titre});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icone, size: 16, color: AppColors.encreDoux),
        const SizedBox(width: 6),
        Text(
          titre,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: AppColors.encre,
          ),
        ),
      ],
    );
  }
}

// ─── Ligne composante du score ────────────────────────────────────────────────
class _LigneComposante extends StatelessWidget {
  final ComposanteScore composante;

  const _LigneComposante({required this.composante});

  @override
  Widget build(BuildContext context) {
    final isPos = composante.type == TypeImpact.positif;
    final isNeg = composante.type == TypeImpact.negatif;
    final couleur = isPos
        ? const Color(0xFF2E7D5B)
        : isNeg
            ? const Color(0xFFC4453C)
            : AppColors.texteDoux;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 42,
            alignment: Alignment.centerRight,
            child: Text(
              '${composante.impact >= 0 ? '+' : ''}${composante.impact}',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: couleur,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  composante.label,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppColors.encre,
                  ),
                ),
                Text(
                  composante.detail,
                  style: const TextStyle(
                      fontSize: 11, color: AppColors.texteDoux),
                ),
              ],
            ),
          ),
          Icon(
            isPos
                ? Icons.arrow_upward_rounded
                : isNeg
                    ? Icons.arrow_downward_rounded
                    : Icons.remove_rounded,
            size: 14,
            color: couleur,
          ),
        ],
      ),
    );
  }
}

// ─── Carte recommandation IA ──────────────────────────────────────────────────
class _CarteRecommandation extends StatelessWidget {
  final RecommandationIA rec;

  const _CarteRecommandation({required this.rec});

  @override
  Widget build(BuildContext context) {
    final couleur = _couleurRec(rec.type);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: couleur.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: couleur.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(_iconeRec(rec.type), size: 14, color: couleur),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  rec.titre,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: couleur,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            rec.message,
            style: const TextStyle(
                fontSize: 12, color: AppColors.encre, height: 1.4),
          ),
          if (rec.actionSuggeree != null) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                const Icon(Icons.arrow_forward_rounded,
                    size: 11, color: AppColors.texteDoux),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    rec.actionSuggeree!,
                    style: const TextStyle(
                        fontSize: 11,
                        color: AppColors.texteDoux,
                        fontStyle: FontStyle.italic),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

// ─── Carte plan de suivi (vote retrait refusé) ────────────────────────────────
class _CartePlanSuivi extends StatelessWidget {
  final Membre membre;
  final List<RecommandationIA> recommandations;
  final ScoreDetail scoreDetail;

  const _CartePlanSuivi({
    required this.membre,
    required this.recommandations,
    required this.scoreDetail,
  });

  @override
  Widget build(BuildContext context) {
    final conseils = recommandations
        .where((r) =>
            r.type == TypeRecommandation.conseil ||
            r.type == TypeRecommandation.info)
        .toList();

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF35407A).withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: const Color(0xFF35407A).withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.psychology_rounded,
                  size: 16, color: Color(0xFF35407A)),
              SizedBox(width: 6),
              Text(
                'Plan de suivi IA — Vote de maintien',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF35407A),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '${membre.nom} a été maintenu(e) suite au vote. '
            'L\'IA propose les actions suivantes pour améliorer la situation :',
            style: const TextStyle(
                fontSize: 12, color: AppColors.texteDoux, height: 1.4),
          ),
          const SizedBox(height: 8),
          if (conseils.isEmpty) ...[
            Text(
              '• Assurer un suivi régulier des cotisations et remboursements\n'
              '• Prévoir un entretien de suivi dans les 30 prochains jours\n'
              '• Recalculer le score après chaque événement',
              style: const TextStyle(
                  fontSize: 12, color: AppColors.encre, height: 1.5),
            ),
          ] else
            ...conseils.map((c) => Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('• ',
                          style: TextStyle(
                              fontSize: 12, color: Color(0xFF35407A))),
                      Expanded(
                        child: Text(
                          c.message,
                          style: const TextStyle(
                              fontSize: 12,
                              color: AppColors.encre,
                              height: 1.4),
                        ),
                      ),
                    ],
                  ),
                )),
          const SizedBox(height: 8),
          Text(
            'Score actuel : ${scoreDetail.score}/100 · Objectif recommandé : ≥ 65',
            style: const TextStyle(
                fontSize: 11,
                color: AppColors.texteDoux,
                fontStyle: FontStyle.italic),
          ),
        ],
      ),
    );
  }
}

// ─── Ligne historique score ───────────────────────────────────────────────────
class _LigneHistorique extends StatelessWidget {
  final HistoriqueScore entree;

  const _LigneHistorique({required this.entree});

  @override
  Widget build(BuildContext context) {
    final evolution = entree.evolution;
    final couleur = evolution > 0
        ? const Color(0xFF2E7D5B)
        : evolution < 0
            ? const Color(0xFFC4453C)
            : AppColors.texteDoux;

    final iconeEvenement = switch (entree.evenement) {
      'cotisation' => Icons.payments_outlined,
      'retard' => Icons.schedule_rounded,
      'pret' || 'remboursement' => Icons.account_balance_rounded,
      'vote' => Icons.how_to_vote_rounded,
      'admin' => Icons.admin_panel_settings_rounded,
      'sanction' => Icons.warning_amber_rounded,
      'retrait' => Icons.gpp_bad_rounded,
      _ => Icons.timeline_rounded,
    };

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Indicateur évolution
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: couleur.withValues(alpha: 0.12),
            ),
            child: Center(
              child: Text(
                evolution > 0 ? '+$evolution' : '$evolution',
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: couleur),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(iconeEvenement,
                        size: 12, color: AppColors.texteDoux),
                    const SizedBox(width: 4),
                    Text(
                      _labelEvenement(entree.evenement),
                      style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: AppColors.texteDoux),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  entree.description,
                  style: const TextStyle(
                      fontSize: 12, color: AppColors.encre, height: 1.3),
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Text(
                      '${entree.scorePrecedent} → ${entree.score}',
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: couleur),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      Formatters.dateFormatee(entree.quand),
                      style: const TextStyle(
                          fontSize: 11, color: AppColors.texteDoux),
                    ),
                    if (entree.gestionnaire != null) ...[
                      const SizedBox(width: 6),
                      Text(
                        '· ${entree.gestionnaire}',
                        style: const TextStyle(
                            fontSize: 10,
                            color: AppColors.texteDoux,
                            fontStyle: FontStyle.italic),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _labelEvenement(String evt) {
    return switch (evt) {
      'cotisation' => 'Cotisation',
      'retard' => 'Retard',
      'pret' => 'Prêt',
      'remboursement' => 'Remboursement',
      'vote' => 'Vote',
      'admin' => 'Modification admin',
      'sanction' => 'Sanction',
      'retrait' => 'Proposition de retrait',
      _ => evt,
    };
  }
}

// ─── Carte historique simulée (quand table v6 absente) ───────────────────────
class _CarteHistoriqueSimulee extends StatelessWidget {
  final ScoreDetail scoreDetail;

  const _CarteHistoriqueSimulee({required this.scoreDetail});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 24),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.fondCode,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.lignes),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Score actuel calculé',
                style:
                    TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
              Text(
                '${scoreDetail.score}/100',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: _couleurScore(scoreDetail.score),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'L\'historique s\'enrichira après les prochains événements (cotisations, votes, prêts).',
            style: TextStyle(fontSize: 10, color: AppColors.texteDoux),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

// ─── Carte vote de retrait ────────────────────────────────────────────────────
class _CarteVoteRetrait extends StatelessWidget {
  final Vote vote;

  const _CarteVoteRetrait({required this.vote});

  @override
  Widget build(BuildContext context) {
    final couleur = vote.clos
        ? (vote.adopte == true
            ? const Color(0xFFC4453C)
            : const Color(0xFF2E7D5B))
        : const Color(0xFFD99A2B);

    // Paramètres du vote de retrait
    final quorum = (vote.voix['quorum'] as num?)?.toInt() ?? _quorumDefaut;
    final majorite = (vote.voix['majorite'] as num?)?.toInt() ?? _majoriteDefaut;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: couleur.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: couleur.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.how_to_vote_rounded, size: 14, color: couleur),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  vote.question,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: couleur,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: couleur.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  vote.clos
                      ? (vote.adopte == true
                          ? '✗ Retrait adopté'
                          : '✓ Membre maintenu')
                      : '⏳ Vote en cours',
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: couleur),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                Formatters.dateFormatee(DateTime.tryParse(vote.dateCreation)),
                style: const TextStyle(
                    fontSize: 11, color: AppColors.texteDoux),
              ),
            ],
          ),
          const SizedBox(height: 6),
          // Règles du vote
          Text(
            'Quorum : $quorum% · Majorité : $majorite%',
            style: const TextStyle(fontSize: 10, color: AppColors.texteDoux),
          ),
          if (vote.description != null) ...[
            const SizedBox(height: 6),
            Text(
              vote.description!,
              style: const TextStyle(
                  fontSize: 11,
                  color: AppColors.texteDoux,
                  height: 1.4),
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          // Si accepté → information sur le statut
          if (vote.clos && vote.adopte == true) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFFC4453C).withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Row(
                children: [
                  Icon(Icons.person_off_rounded,
                      size: 12, color: Color(0xFFC4453C)),
                  SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Le retrait a été adopté. Le statut du membre a été mis à jour.',
                      style: TextStyle(
                          fontSize: 10, color: Color(0xFFC4453C)),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ─── Carte proposition de retrait ─────────────────────────────────────────────
class _CarteProposition extends StatelessWidget {
  final PropositionRetrait proposition;

  const _CarteProposition({required this.proposition});

  @override
  Widget build(BuildContext context) {
    final couleur = proposition.statut == 'accepte'
        ? const Color(0xFFC4453C)
        : proposition.statut == 'refuse'
            ? const Color(0xFF2E7D5B)
            : const Color(0xFFD99A2B);

    final labelStatut = {
          'en_attente': '⏳ En attente',
          'vote_ouvert': '🗳 Vote ouvert',
          'accepte': '✗ Retrait accepté',
          'refuse': '✓ Maintien confirmé',
        }[proposition.statut] ??
        proposition.statut;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: couleur.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: couleur.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                labelStatut,
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: couleur),
              ),
              Text(
                'Score : ${proposition.scoreAuMoment}/100',
                style: const TextStyle(
                    fontSize: 11, color: AppColors.texteDoux),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Motif : ${proposition.motif}',
            style: const TextStyle(fontSize: 12, color: AppColors.encre),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Text(
                'Proposé par ${proposition.proposePar}',
                style: const TextStyle(
                    fontSize: 10, color: AppColors.texteDoux),
              ),
              const SizedBox(width: 8),
              Text(
                Formatters.dateFormatee(proposition.quand),
                style: const TextStyle(
                    fontSize: 10, color: AppColors.texteDoux),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
