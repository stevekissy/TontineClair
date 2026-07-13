import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/tontine.dart';
import '../services/tontine_provider.dart';
import '../services/devise_service.dart';
import '../services/supabase_service.dart';
import '../utils/app_colors.dart';
import '../utils/formatters.dart';
import '../widgets/app_widgets.dart';
import '../utils/app_localizations.dart';
import '../services/locale_service.dart';

// ── Bug #3 fix : StatefulWidget pour permettre le rechargement des membres ──
class PretsScreen extends StatefulWidget {
  final String code;

  const PretsScreen({super.key, required this.code});

  @override
  State<PretsScreen> createState() => _PretsScreenState();
}

class _PretsScreenState extends State<PretsScreen> {
  bool _chargement = false;

  @override
  void initState() {
    super.initState();
    // Recharger depuis Supabase à l'ouverture pour avoir les membres à jour
    WidgetsBinding.instance.addPostFrameCallback((_) => _recharger());
  }

  Future<void> _recharger() async {
    if (!mounted) return;
    setState(() => _chargement = true);
    try {
      await context.read<TontineProvider>().chargerTontine(widget.code);
    } finally {
      if (mounted) setState(() => _chargement = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<TontineProvider>();
    final tontine = provider.courante;
    if (tontine == null || _chargement) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final data = tontine.data;
    final estGest = provider.estDebloque;

    return Scaffold(
      backgroundColor: AppColors.fondPapier,
      body: SafeArea(
        child: Column(
          children: [
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
            Expanded(
              child: ListView(
                padding: EdgeInsets.all(16),
                children: [
                  Text(
                    context.tr('prets_internes'),
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 28,
                      color: AppColors.encre,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Solde caisse : ${Formatters.montant(data.soldeCaisse, devise: data.devise)}',
                    style: const TextStyle(
                      fontSize: 14,
                      color: AppColors.texteDoux,
                    ),
                  ),
                  SizedBox(height: 16),
                  if (estGest)
                    BtnKola(
                      label: '+ Nouveau prêt',
                      icon: Icons.add,
                      onTap: () => _nouveauPret(context, provider, data),
                    ),
                  SizedBox(height: 16),
                  if (data.prets.isEmpty)
                    Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          context.tr('aucun_pret'),
                          style: TextStyle(color: AppColors.texteDoux),
                        ),
                      ),
                    )
                  else
                    ...data.prets.map(
                      (p) => _CartePret(
                        pret: p,
                        estGest: estGest,
                        data: data,
                        provider: provider,
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

  Future<void> _nouveauPret(
    BuildContext context,
    TontineProvider provider,
    TontineData data,
  ) async {
    // SOURCE UNIQUE DE MEMBRES (Bug #membres fix) — même liste que MembresScreen
    // data.membresActifs : ordre[] avec double fallback sur membres[] si IDs divergents
    final List<Membre> membresOrdre = data.membresActifs;

    // Si aucun membre disponible → erreur explicite
    if (membresOrdre.isEmpty) {
      afficherToast(
        context,
        'Aucun membre disponible. Rechargez la page.',
        estErreur: true,
      );
      return;
    }

    String? emprunteurId = membresOrdre.first.id;
    final montantCtrl = TextEditingController();
    final tauxCtrl = TextEditingController(text: '5');
    final dureesCtrl = TextEditingController(text: '3');

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
                  context.tr('nouveau_pret'),
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 20,
                    color: AppColors.encre,
                  ),
                ),
                ChampLabel(label: context.tr('emprunteur')),
                DropdownButtonFormField<String>(
                  value: emprunteurId,
                  decoration: const InputDecoration(),
                  isExpanded: true,
                  items: membresOrdre
                      .map((m) => DropdownMenuItem(
                            value: m.id,
                            child: Text(m.nom, overflow: TextOverflow.ellipsis),
                          ))
                      .toList(),
                  onChanged: (v) => setS(() => emprunteurId = v),
                ),
                ChampLabel(label: 'Montant (${DeviseService.parCode(data.devise).symbole})'),
                TextField(
                  controller: montantCtrl,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(hintText: '50 000'),
                  autofocus: true,
                ),
                ChampLabel(label: context.tr('taux_interet')),
                TextField(
                  controller: tauxCtrl,
                  keyboardType: TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(hintText: '5'),
                ),
                ChampLabel(label: context.tr('duree_mois')),
                TextField(
                  controller: dureesCtrl,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(hintText: '3'),
                ),
                SizedBox(height: 16),
                BtnPrincipal(
                  label: context.tr('creer_pret'),
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
      ),
    );

    if (result != true || !context.mounted) return;

    final montant = int.tryParse(montantCtrl.text.trim());
    final taux = double.tryParse(tauxCtrl.text.trim()) ?? 5;
    final durees = int.tryParse(dureesCtrl.text.trim()) ?? 3;

    if (montant == null || montant <= 0 || emprunteurId == null) {
      afficherToast(context, 'Données invalides', estErreur: true);
      return;
    }

    if (montant > data.soldeCaisse) {
      afficherToast(context,
          'Solde insuffisant — caisse : ${Formatters.montant(data.soldeCaisse, devise: data.devise)}',
          estErreur: true);
      return;
    }

    final totalDuOctroyer = (montant * (1 + taux / 100)).round();
    final nomEmprunteur = membresOrdre
        .where((m) => m.id == emprunteurId)
        .map((m) => m.nom)
        .firstOrNull ?? '—';

    final ok = await afficherModalePin(
      context,
      titre: context.tr('confirmer_pret'),
      sousTitre: 'Vérifie les détails avant de confirmer avec ton PIN.',
      recap: [
        (label: context.tr('emprunteur'), valeur: nomEmprunteur),
        (label: context.tr('montant_prete'), valeur: Formatters.montant(montant, devise: data.devise)),
        (label: context.tr('taux'), valeur: '$taux %'),
        (label: context.tr('duree'), valeur: '$durees mois'),
        (label: context.tr('total_du'), valeur: Formatters.montant(totalDuOctroyer, devise: data.devise)),
      ],
      onValider: (pin) async {
        final ref = Formatters.genererReference();
        final emprunteur = membresOrdre.firstWhere((m) => m.id == emprunteurId);
        final dateDebut = DateTime.now().toIso8601String();

        final interet = (montant * taux / 100).round();
        final totalDu = montant + interet;
        final mensualite = (totalDu / durees).round();

        final echeancier = List.generate(durees, (i) {
          final dateEch = DateTime.now().add(Duration(days: 30 * (i + 1)));
          return {
            'mois': i + 1,
            'date': dateEch.toIso8601String(),
            'montant': i == durees - 1
                ? totalDu - mensualite * (durees - 1)
                : mensualite,
          };
        });

        final newData = data.toJson();

        // ── Caisse : lire/écrire dans le format {mouvements:[...]} ───────────
        final caisseMapO = newData['caisse'];
        final caisse = List<Map<String, dynamic>>.from(
          caisseMapO is Map<String, dynamic>
              ? ((caisseMapO['mouvements'] as List<dynamic>?)
                      ?.cast<Map<String, dynamic>>() ??
                  [])
              : caisseMapO is List
                  ? (caisseMapO as List<dynamic>).cast<Map<String, dynamic>>()
                  : [],
        );
        caisse.add({
          'id': '${ref}D',
          'type': 'depense',
          'montant': montant,
          'description': 'Prêt à ${emprunteur.nom}',
          'gestionnaire': provider.gestActifNom ?? '',
          'date': dateDebut,
          'reference': ref,
        });
        newData['caisse'] = {'mouvements': caisse};

        final prets = List<Map<String, dynamic>>.from(
          (newData['prets'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ?? [],
        );
        prets.add({
          'id': ref,
          'emprunteurId': emprunteur.id,
          'emprunteurNom': emprunteur.nom,
          'montant': montant,
          'taux': taux,
          'dureesMois': durees,
          'dateDebut': dateDebut,
          'statut': 'en_cours',
          'remboursements': [],
          'echeancier': echeancier,
          'gestionnaire': provider.gestActifNom ?? '',
          'reference': ref,
        });
        newData['prets'] = prets;

        final journal = List<Map<String, dynamic>>.from(
          (newData['journal'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ?? [],
        );
        journal.insert(0, {
          'quoi': 'NOUVEAU PRÊTT — ${emprunteur.nom} — ${Formatters.montant(montant, devise: data.devise)} — ${taux}% — ${durees} mois',
          'gestionnaire': provider.gestActifNom ?? '',
          'quand': dateDebut,
          'reference': ref,
        });
        newData['journal'] = journal;

        return provider.ecrire(newData, pin);
      },
    );

    if (ok == true && context.mounted) {
      afficherToast(context, 'Prêt créé avec succès !');
      final _lang = Provider.of<LocaleService>(context, listen: false).langue.code;
      final _t = SupabaseService.notifTexte('pret', _lang, vars: {
        'nom': nomEmprunteur,
        'montant': Formatters.montant(montant, devise: data.devise),
        'taux': taux.toString(),
        'duree': durees.toString(),
      });
      SupabaseService.envoyerNotification(
        code: widget.code,
        type: 'pret',
        titre: _t['titre']!,
        message: _t['message']!,
      );
    }
  }
}

class _CartePret extends StatelessWidget {
  final Pret pret;
  final bool estGest;
  final TontineData data;
  final TontineProvider provider;

  const _CartePret({
    required this.pret,
    required this.estGest,
    required this.data,
    required this.provider,
  });

  @override
  Widget build(BuildContext context) {
    final progression = pret.totalDu > 0
        ? (pret.totalRembourse / pret.totalDu).clamp(0.0, 1.0)
        : 0.0;
    // Bug #2 fix : utiliser statutCalcule (computed) et non statut (stocké périmé)
    final statut = pret.statutCalcule;

    return CarteTC(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      pret.emprunteurNom,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 17,
                        color: AppColors.encre,
                      ),
                    ),
                    Text(
                      'Taux ${pret.taux}% · ${pret.dureesMois} mois · Réf. ${pret.reference}',
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.texteDoux,
                      ),
                    ),
                  ],
                ),
              ),
              BadgeStatut(statut: statut),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _StatPret(
                label: 'Emprunté',
                valeur: Formatters.montant(pret.montant, devise: data.devise),
              ),
              const SizedBox(width: 16),
              _StatPret(
                label: 'Remboursé',
                valeur: Formatters.montant(pret.totalRembourse, devise: data.devise),
                couleur: AppColors.succes,
              ),
              const SizedBox(width: 16),
              _StatPret(
                label: 'Restant',
                valeur: Formatters.montant(pret.resteADu, devise: data.devise),
                couleur: pret.resteADu > 0 ? AppColors.alerte : AppColors.succes,
              ),
            ],
          ),
          const SizedBox(height: 10),
          LinearProgressIndicator(
            value: progression,
            backgroundColor: AppColors.lignes,
            valueColor: const AlwaysStoppedAnimation<Color>(AppColors.succes),
            borderRadius: BorderRadius.circular(4),
            minHeight: 6,
          ),
          // ── Liste des remboursements avec bouton Annuler ─────────────────
          if (estGest && pret.remboursements.isNotEmpty) ...[
            const SizedBox(height: 12),
            const Divider(height: 1, color: AppColors.lignes),
            const SizedBox(height: 8),
            const Text(
              'Remboursements',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 12,
                color: AppColors.texteDoux,
              ),
            ),
            const SizedBox(height: 6),
            ...pret.remboursements.map((r) => Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${Formatters.dateFormatee(DateTime.tryParse(r.date))} — '
                      '${Formatters.montant(r.montant, devise: data.devise)}',
                      style: const TextStyle(fontSize: 12, color: AppColors.texte),
                    ),
                  ),
                  GestureDetector(
                    onTap: () => _annulerRemboursement(context, r),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: AppColors.alerteFond,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Text(
                        'Annuler',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: AppColors.alerte,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            )),
          ],
          // Bug #2 fix : bouton désactivé si statutCalcule == 'solde'
          if (estGest && statut != 'solde') ...[
            const SizedBox(height: 12),
            BtnSecondaire(
              label: 'Enregistrer un remboursement',
              onTap: () => _rembourser(context),
            ),
          ],
          // Indicateur "Prêt soldé" si statutCalcule == 'solde'
          if (statut == 'solde') ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: AppColors.succesFond,
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.check_circle_outline, size: 16, color: AppColors.succes),
                  SizedBox(width: 6),
                  Text(
                    'Prêt entièrement remboursé',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: AppColors.succes,
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

  Future<void> _annulerRemboursement(
    BuildContext context,
    Remboursement remb,
  ) async {
    final ok = await afficherModalePin(
      context,
      titre: 'Annuler ce remboursement',
      sousTitre: 'Cette action est irréversible et contre-passe la caisse.',
      recap: [
        (label: 'Emprunteur', valeur: pret.emprunteurNom),
        (label: 'Montant annulé', valeur: Formatters.montant(remb.montant, devise: data.devise)),
        (label: 'Date initiale', valeur: Formatters.dateFormatee(DateTime.tryParse(remb.date))),
        (label: 'Réf.', valeur: remb.reference),
      ],
      labelValider: 'Confirmer l\'annulation',
      onValider: (pin) async {
        final ref = Formatters.genererReference();
        final now = DateTime.now().toIso8601String();
        final newData = data.toJson();

        // ── 1. Supprimer le remboursement du prêt ───────────────────────────
        final prets = List<Map<String, dynamic>>.from(
          (newData['prets'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ?? [],
        );
        final idx = prets.indexWhere((p) => p['id'] == pret.id);
        if (idx >= 0) {
          final rembs = List<Map<String, dynamic>>.from(
            (prets[idx]['remboursements'] as List<dynamic>?)
                    ?.cast<Map<String, dynamic>>() ?? [],
          );
          rembs.removeWhere((r) => r['id'] == remb.id || r['reference'] == remb.reference);
          prets[idx]['remboursements'] = rembs;

          // Recalculer resteADu après suppression
          final totalDu = (prets[idx]['totalDu'] as num?)?.toInt() ?? pret.totalDu;
          final totalRembourse = rembs.fold<int>(
            0,
            (sum, r) => sum + ((r['montant'] as num?)?.toInt() ?? 0),
          );
          final nouveauReste = (totalDu - totalRembourse).clamp(0, totalDu);
          prets[idx]['resteADu'] = nouveauReste;

          // Si le prêt était soldé, le repasser en cours
          if ((prets[idx]['statut'] == 'solde' || prets[idx]['statut'] == 'soldé') && nouveauReste > 0) {
            prets[idx]['statut'] = 'en_cours';

            // Décrémenter pretsRembourses dans membres
            if (pret.emprunteurId.isNotEmpty) {
              final membres = List<Map<String, dynamic>>.from(
                (newData['membres'] as List<dynamic>).cast<Map<String, dynamic>>(),
              );
              final mIdx = membres.indexWhere((m) => m['id'] == pret.emprunteurId);
              if (mIdx >= 0) {
                final actuel = (membres[mIdx]['pretsRembourses'] as int?) ?? 0;
                membres[mIdx]['pretsRembourses'] = (actuel - 1).clamp(0, actuel);
              }
              newData['membres'] = membres;
            }
          }
        }
        newData['prets'] = prets;

        // ── 2. Contre-passe caisse : retirer le montant (dépense) ──────────
        final caisseMap = newData['caisse'];
        final caisse = List<Map<String, dynamic>>.from(
          caisseMap is Map<String, dynamic>
              ? ((caisseMap['mouvements'] as List<dynamic>?)
                      ?.cast<Map<String, dynamic>>() ?? [])
              : caisseMap is List
                  ? (caisseMap as List<dynamic>).cast<Map<String, dynamic>>()
                  : [],
        );
        caisse.add({
          'id': '${ref}A',
          'type': 'depense',
          'montant': remb.montant,
          'description': 'Annulation remb. ${pret.emprunteurNom} (réf. ${remb.reference})',
          'gestionnaire': provider.gestActifNom ?? '',
          'date': now,
          'reference': ref,
        });
        newData['caisse'] = {'mouvements': caisse};

        // ── 3. Journal ───────────────────────────────────────────────────────
        final journal = List<Map<String, dynamic>>.from(
          (newData['journal'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ?? [],
        );
        journal.insert(0, {
          'quoi': 'ANNULATION REMBOURSEMENT — ${pret.emprunteurNom} — ${Formatters.montant(remb.montant, devise: data.devise)} — Réf: ${remb.reference}',
          'gestionnaire': provider.gestActifNom ?? '',
          'quand': now,
          'reference': ref,
        });
        newData['journal'] = journal;

        return provider.ecrire(newData, pin);
      },
    );

    if (ok == true && context.mounted) {
      afficherToast(context, 'Remboursement annulé et caisse corrigée.');
      final tontineCode = provider.courante?.code ?? '';
      if (tontineCode.isNotEmpty) {
        final _lang = Provider.of<LocaleService>(context, listen: false).langue.code;
        final _t = SupabaseService.notifTexte('annulation_remboursement', _lang, vars: {
          'montant': Formatters.montant(remb.montant, devise: data.devise),
          'nom': pret.emprunteurNom,
          'ref': remb.reference,
        });
        SupabaseService.envoyerNotification(
          code: tontineCode,
          type: 'annulation_remboursement',
          titre: _t['titre']!,
          message: _t['message']!,
        );
      }
    }
  }

  Future<void> _rembourser(BuildContext context) async {
    final montantCtrl = TextEditingController();
    String methode = 'especes';

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
            children: [
              const Text(
                'Remboursement',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 20,
                  color: AppColors.encre,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Reste à rembourser : ${Formatters.montant(pret.resteADu, devise: data.devise)}',
                style: const TextStyle(color: AppColors.texteDoux),
              ),
              ChampLabel(label: 'Montant remboursé (${DeviseService.parCode(data.devise).symbole})'),
              TextField(
                controller: montantCtrl,
                keyboardType: TextInputType.number,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: pret.resteADu.toString(),
                ),
              ),
              const ChampLabel(label: 'Méthode'),
              DropdownButtonFormField<String>(
                value: methode,
                decoration: const InputDecoration(),
                items: ['especes', 'orange', 'mtn', 'moov', 'wave']
                    .map((m) => DropdownMenuItem(
                          value: m,
                          child: Text(Formatters.methodePaiement(m)),
                        ))
                    .toList(),
                onChanged: (v) => setS(() => methode = v!),
              ),
              const SizedBox(height: 16),
              BtnPrincipal(
                label: 'Enregistrer',
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

    final montant = int.tryParse(montantCtrl.text.trim());
    if (montant == null || montant <= 0) {
      afficherToast(context, 'Montant invalide', estErreur: true);
      return;
    }

    bool pretSolde = false;
    String refRemboursement = '';

    final resteAvant = pret.resteADu;
    final resteApres = (resteAvant - montant).clamp(0, resteAvant);

    final ok = await afficherModalePin(
      context,
      titre: 'Confirmer le remboursement',
      sousTitre: 'Vérifie les détails avant de confirmer avec ton PIN.',
      recap: [
        (label: 'Emprunteur', valeur: pret.emprunteurNom),
        (label: 'Montant remboursé', valeur: Formatters.montant(montant, devise: data.devise)),
        (label: 'Méthode', valeur: Formatters.methodePaiement(methode)),
        (label: 'Reste après', valeur: Formatters.montant(resteApres, devise: data.devise)),
        if (resteApres == 0) (label: 'Statut', valeur: '✅ Soldé'),
      ],
      onValider: (pin) async {
        final ref = Formatters.genererReference();
        refRemboursement = ref;
        final now = DateTime.now().toIso8601String();
        final newData = data.toJson();

        // ── Caisse : lire/écrire dans le format {mouvements:[...]} ───────────
        final caisseMap = newData['caisse'];
        final caisse = List<Map<String, dynamic>>.from(
          caisseMap is Map<String, dynamic>
              ? ((caisseMap['mouvements'] as List<dynamic>?)
                      ?.cast<Map<String, dynamic>>() ??
                  [])
              : caisseMap is List
                  ? (caisseMap as List<dynamic>).cast<Map<String, dynamic>>()
                  : [],
        );
        caisse.add({
          'id': '${ref}R',
          'type': 'remboursement',
          'montant': montant,
          'description': 'Remboursement prêt ${pret.emprunteurNom}',
          'gestionnaire': provider.gestActifNom ?? '',
          'date': now,
          'reference': ref,
        });
        newData['caisse'] = {'mouvements': caisse};

        // ── Prêt : ajouter le remboursement + passage auto à "soldé" ─────────
        final prets = List<Map<String, dynamic>>.from(
          (newData['prets'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ?? [],
        );
        final idx = prets.indexWhere((p) => p['id'] == pret.id);
        bool estSoldeMaintenant = false;
        if (idx >= 0) {
          final rembs = List<Map<String, dynamic>>.from(
            (prets[idx]['remboursements'] as List<dynamic>?)
                    ?.cast<Map<String, dynamic>>() ??
                [],
          );
          rembs.add({
            'id': ref,
            'montant': montant,
            'date': now,
            'methode': methode,
            'reference': ref,
          });
          prets[idx]['remboursements'] = rembs;

          // Recalculer resteADu : totalDu − Σ remboursements
          final totalDu = (prets[idx]['totalDu'] as num?)?.toInt() ?? pret.totalDu;
          final totalRembourse = rembs.fold<int>(
            0,
            (sum, r) => sum + ((r['montant'] as num?)?.toInt() ?? 0),
          );
          final nouveauReste = (totalDu - totalRembourse).clamp(0, totalDu);
          prets[idx]['resteADu'] = nouveauReste;

          // Passage automatique à "soldé" quand resteADu atteint 0
          if (nouveauReste <= 0) {
            prets[idx]['statut'] = 'solde';
            estSoldeMaintenant = true;
            pretSolde = true;
          }
        }
        newData['prets'] = prets;

        // ── Membres : incrémenter pretsRembourses si prêt soldé ──────────────
        if (estSoldeMaintenant && pret.emprunteurId.isNotEmpty) {
          final membres = List<Map<String, dynamic>>.from(
            (newData['membres'] as List<dynamic>).cast<Map<String, dynamic>>(),
          );
          final mIdx = membres.indexWhere((m) => m['id'] == pret.emprunteurId);
          if (mIdx >= 0) {
            membres[mIdx]['pretsRembourses'] =
                ((membres[mIdx]['pretsRembourses'] as int?) ?? 0) + 1;
          }
          newData['membres'] = membres;
        }

        // ── Journal ───────────────────────────────────────────────────────────
        final journal = List<Map<String, dynamic>>.from(
          (newData['journal'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ?? [],
        );
        journal.insert(0, {
          'quoi': estSoldeMaintenant
              ? 'REMBOURSEMENT SOLDE — ${pret.emprunteurNom} — ${Formatters.montant(montant, devise: data.devise)} — Prêt entièrement soldé'
              : 'REMBOURSEMENT — ${pret.emprunteurNom} — ${Formatters.montant(montant, devise: data.devise)} — Reste : ${Formatters.montant(resteApres, devise: data.devise)}',
          'gestionnaire': provider.gestActifNom ?? '',
          'quand': now,
          'reference': ref,
        });
        newData['journal'] = journal;

        return provider.ecrire(newData, pin);
      },
    );

    if (ok == true && context.mounted) {
      afficherToast(
        context,
        pretSolde
            ? '✅ Prêt soldé intégralement !'
            : 'Remboursement enregistré !',
      );
      final tontineCode = provider.courante?.code ?? '';
      if (tontineCode.isNotEmpty) {
        final _lang = Provider.of<LocaleService>(context, listen: false).langue.code;
        final _typeNotif2 = pretSolde ? 'pret_solde' : 'remboursement';
        final _t2 = SupabaseService.notifTexte(_typeNotif2, _lang, vars: {
          'nom': pret.emprunteurNom,
          'montant': pretSolde
              ? Formatters.montant(pret.totalDu, devise: data.devise)
              : Formatters.montant(montant, devise: data.devise),
          'reste': Formatters.montant(resteApres, devise: data.devise),
        });
        SupabaseService.envoyerNotification(
          code: tontineCode,
          type: _typeNotif2,
          titre: _t2['titre']!,
          message: _t2['message']!,
        );
      }

      // ── Reçu WhatsApp remboursement ───────────────────────────────────────
      final telEmprunteur = data.membres
          .where((m) => m.id == pret.emprunteurId)
          .map((m) => m.tel ?? '')
          .firstOrNull ?? '';

      final texteRecu = Uri.encodeComponent(
        '🧾 *Reçu de remboursement — ${data.nom}*\n\n'
        '👤 Emprunteur : ${pret.emprunteurNom}\n'
        '💰 Montant remboursé : ${Formatters.montant(montant, devise: data.devise)}\n'
        '📋 Méthode : ${Formatters.methodePaiement(methode)}\n'
        '🔖 Réf. : $refRemboursement\n'
        '📅 Date : ${Formatters.dateHeure(DateTime.now())}\n'
        '${pretSolde ? '✅ Prêt entièrement soldé !\n' : '💳 Reste à rembourser : ${Formatters.montant(resteApres, devise: data.devise)}\n'}'
        '\n_TontineClair_',
      );

      final waUrl = telEmprunteur.isNotEmpty
          ? Uri.parse('https://wa.me/$telEmprunteur?text=$texteRecu')
          : Uri.parse('https://wa.me/?text=$texteRecu');

      if (context.mounted) {
        await showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: AppColors.fondPapier,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
            ),
            title: const Text(
              '📲 Envoyer le reçu ?',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: AppColors.encre,
              ),
            ),
            content: Text(
              'Envoyer un reçu WhatsApp à ${pret.emprunteurNom} ?',
              style: const TextStyle(color: AppColors.texte),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Non'),
              ),
              TextButton(
                onPressed: () async {
                  Navigator.pop(ctx);
                  await launchUrl(waUrl, mode: LaunchMode.externalApplication);
                },
                child: const Text(
                  'Envoyer',
                  style: TextStyle(
                    color: AppColors.succes,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        );
      }
    }
  }
}

class _StatPret extends StatelessWidget {
  final String label;
  final String valeur;
  final Color? couleur;

  const _StatPret({required this.label, required this.valeur, this.couleur});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 11,
              color: AppColors.texteDoux,
            ),
          ),
          Text(
            valeur,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 13,
              color: couleur ?? AppColors.texte,
            ),
          ),
        ],
      ),
    );
  }
}
