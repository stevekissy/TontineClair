import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/tontine.dart';
import '../services/tontine_provider.dart';
import '../utils/app_colors.dart';
import '../utils/formatters.dart';
import '../widgets/app_widgets.dart';

class PretsScreen extends StatelessWidget {
  final String code;

  const PretsScreen({super.key, required this.code});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<TontineProvider>();
    final tontine = provider.courante;
    if (tontine == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));

    final data = tontine.data;
    final estGest = provider.estDebloque;

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
                    'Prêts internes',
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 28,
                      color: AppColors.encre,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Solde caisse : ${Formatters.montantFCFA(data.soldeCaisse)}',
                    style: const TextStyle(
                      fontSize: 14,
                      color: AppColors.texteDoux,
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (estGest)
                    BtnKola(
                      label: '+ Nouveau prêt',
                      icon: Icons.add,
                      onTap: () => _nouveauPret(context, provider, data),
                    ),
                  const SizedBox(height: 16),
                  if (data.prets.isEmpty)
                    const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          'Aucun prêt enregistré.',
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
    final membres = data.membres;
    String? emprunteurId = membres.isNotEmpty ? membres[0].id : null;
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
                'Nouveau prêt',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 20,
                  color: AppColors.encre,
                ),
              ),
              const ChampLabel(label: 'Emprunteur'),
              DropdownButtonFormField<String>(
                value: emprunteurId,
                decoration: const InputDecoration(),
                items: membres
                    .map((m) => DropdownMenuItem(
                          value: m.id,
                          child: Text(m.nom),
                        ))
                    .toList(),
                onChanged: (v) => setS(() => emprunteurId = v),
              ),
              const ChampLabel(label: 'Montant (FCFA)'),
              TextField(
                controller: montantCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(hintText: '50 000'),
                autofocus: true,
              ),
              const ChampLabel(label: 'Taux d\'intérêt (%)'),
              TextField(
                controller: tauxCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(hintText: '5'),
              ),
              const ChampLabel(label: 'Durée (mois)'),
              TextField(
                controller: dureesCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(hintText: '3'),
              ),
              const SizedBox(height: 16),
              BtnPrincipal(
                label: 'Créer le prêt',
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
    final taux = double.tryParse(tauxCtrl.text.trim()) ?? 5;
    final durees = int.tryParse(dureesCtrl.text.trim()) ?? 3;

    if (montant == null || montant <= 0 || emprunteurId == null) {
      afficherToast(context, 'Données invalides', estErreur: true);
      return;
    }

    if (montant > data.soldeCaisse) {
      afficherToast(context, 'Solde insuffisant en caisse', estErreur: true);
      return;
    }

    final ok = await afficherModalePin(
      context,
      titre: 'Confirmer le prêt',
      sousTitre: '${Formatters.montantFCFA(montant)} · Taux $taux% · $durees mois',
      onValider: (pin) async {
        final ref = Formatters.genererReference();
        final emprunteur = membres.firstWhere((m) => m.id == emprunteurId);
        final dateDebut = DateTime.now().toIso8601String();

        // Générer l'échéancier
        final interet = (montant * taux / 100 * durees / 12).round();
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

        // Déduire de la caisse
        final caisse = List<Map<String, dynamic>>.from(
          (newData['caisse'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ?? [],
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
        newData['caisse'] = caisse;

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
          'quoi': 'PRET_${emprunteur.nom}_${montant}FCFA_${taux}%_${durees}M',
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
              BadgeStatut(statut: pret.statut),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _StatPret(
                label: 'Emprunté',
                valeur: Formatters.montantFCFA(pret.montant),
              ),
              const SizedBox(width: 16),
              _StatPret(
                label: 'Remboursé',
                valeur: Formatters.montantFCFA(pret.totalRembourse),
                couleur: AppColors.succes,
              ),
              const SizedBox(width: 16),
              _StatPret(
                label: 'Restant',
                valeur: Formatters.montantFCFA(pret.resteADu),
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
          if (estGest && pret.statut != 'solde') ...[
            const SizedBox(height: 12),
            BtnSecondaire(
              label: 'Enregistrer un remboursement',
              onTap: () => _rembourser(context),
            ),
          ],
        ],
      ),
    );
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
                'Reste à rembourser : ${Formatters.montantFCFA(pret.resteADu)}',
                style: const TextStyle(color: AppColors.texteDoux),
              ),
              const ChampLabel(label: 'Montant remboursé (FCFA)'),
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

    final ok = await afficherModalePin(
      context,
      titre: 'Confirmer le remboursement',
      sousTitre:
          '${Formatters.montantFCFA(montant)} · ${Formatters.methodePaiement(methode)}',
      onValider: (pin) async {
        final ref = Formatters.genererReference();
        final newData = data.toJson();

        // Ajouter à la caisse
        final caisse = List<Map<String, dynamic>>.from(
          (newData['caisse'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ?? [],
        );
        caisse.add({
          'id': '${ref}R',
          'type': 'remboursement',
          'montant': montant,
          'description': 'Remboursement prêt ${pret.emprunteurNom}',
          'gestionnaire': provider.gestActifNom ?? '',
          'date': DateTime.now().toIso8601String(),
          'reference': ref,
        });
        newData['caisse'] = caisse;

        // Ajouter remboursement au prêt
        final prets = List<Map<String, dynamic>>.from(
          (newData['prets'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ?? [],
        );
        final idx = prets.indexWhere((p) => p['id'] == pret.id);
        if (idx >= 0) {
          final rembs = List<Map<String, dynamic>>.from(
            (prets[idx]['remboursements'] as List<dynamic>?)
                    ?.cast<Map<String, dynamic>>() ??
                [],
          );
          rembs.add({
            'id': ref,
            'montant': montant,
            'date': DateTime.now().toIso8601String(),
            'methode': methode,
            'reference': ref,
          });
          prets[idx]['remboursements'] = rembs;
        }
        newData['prets'] = prets;

        final journal = List<Map<String, dynamic>>.from(
          (newData['journal'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ?? [],
        );
        journal.insert(0, {
          'quoi': 'REMBOURSEMENT_${pret.emprunteurNom}_${montant}FCFA',
          'gestionnaire': provider.gestActifNom ?? '',
          'quand': DateTime.now().toIso8601String(),
          'reference': ref,
        });
        newData['journal'] = journal;

        return provider.ecrire(newData, pin);
      },
    );

    if (ok == true && context.mounted) {
      afficherToast(context, 'Remboursement enregistré !');
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
