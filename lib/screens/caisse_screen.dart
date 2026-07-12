import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/tontine.dart';
import '../services/tontine_provider.dart';
import '../services/devise_service.dart';
import '../utils/app_colors.dart';
import '../utils/formatters.dart';
import '../widgets/app_widgets.dart';

class CaisseScreen extends StatelessWidget {
  final String code;

  const CaisseScreen({super.key, required this.code});

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
                    'Caisse commune',
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 28,
                      color: AppColors.encre,
                    ),
                  ),
                  const SizedBox(height: 16),
                  // Solde
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: AppColors.encre,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Column(
                      children: [
                        const Text(
                          'SOLDE DISPONIBLE',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.14,
                            color: AppColors.or,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          Formatters.montant(data.soldeCaisse, devise: data.devise),
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 34,
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  // Actions gestionnaire
                  if (estGest) ...[
                    Row(
                      children: [
                        Expanded(
                          child: _BtnAction(
                            icon: Icons.add,
                            label: 'Apport',
                            couleur: AppColors.succes,
                            onTap: () => _mouvement(context, provider, data, 'apport'),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _BtnAction(
                            icon: Icons.remove,
                            label: 'Dépense',
                            couleur: AppColors.alerte,
                            onTap: () => _mouvement(context, provider, data, 'depense'),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _BtnAction(
                            icon: Icons.warning_amber,
                            label: 'Pénalité',
                            couleur: AppColors.orFonce,
                            onTap: () => _mouvement(context, provider, data, 'penalite'),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                  ],
                  // Historique
                  const Text(
                    'Mouvements',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 18,
                      color: AppColors.encre,
                    ),
                  ),
                  const SizedBox(height: 10),
                  if (data.caisse.isEmpty)
                    const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          'Aucun mouvement enregistré.',
                          style: TextStyle(color: AppColors.texteDoux),
                        ),
                      ),
                    )
                  else
                    ...data.caisse.reversed.map(
                      (m) => _LigneMouvement(mouvement: m, devise: data.devise),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _mouvement(
    BuildContext context,
    TontineProvider provider,
    TontineData data,
    String type,
  ) async {
    final montantCtrl = TextEditingController();
    final descCtrl = TextEditingController();
    String methode = 'especes';

    // Pour les pénalités : menu de sélection du membre pénalisé
    // SOURCE UNIQUE DE MEMBRES : membresActifs avec double fallback
    final membresOrdre = data.membresActifs;
    String? membrePenaliteId =
        (type == 'penalite' && membresOrdre.isNotEmpty) ? membresOrdre.first.id : null;

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
                Text(
                  type == 'apport'
                      ? 'Apport en caisse'
                      : type == 'depense'
                          ? 'Dépense de caisse'
                          : 'Appliquer une pénalité',
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 20,
                    color: AppColors.encre,
                  ),
                ),
                // Membre pénalisé (pénalité uniquement)
                if (type == 'penalite' && membresOrdre.isNotEmpty) ...[
                  const ChampLabel(label: 'Membre pénalisé'),
                  DropdownButtonFormField<String>(
                    value: membrePenaliteId,
                    isExpanded: true,
                    decoration: const InputDecoration(),
                    items: membresOrdre
                        .map((m) => DropdownMenuItem(
                              value: m.id,
                              child: Text(m.nom, overflow: TextOverflow.ellipsis),
                            ))
                        .toList(),
                    onChanged: (v) => setS(() => membrePenaliteId = v),
                  ),
                ],
                ChampLabel(label: 'Montant (${DeviseService.parCode(data.devise).symbole})'),
                TextField(
                  controller: montantCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(hintText: '5 000'),
                  autofocus: true,
                ),
                const ChampLabel(label: 'Description / Motif'),
                TextField(
                  controller: descCtrl,
                  maxLength: 100,
                  decoration: InputDecoration(
                    hintText: type == 'penalite'
                        ? 'Ex : Retard de cotisation'
                        : 'Ex : Frais de local',
                    counterText: '',
                  ),
                ),
                if (type != 'penalite') ...[
                  const ChampLabel(label: 'Mode de paiement'),
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
                ],
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
                const SizedBox(height: 8),
              ],
            ),
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
    // Vérification solde pour les dépenses
    if (type == 'depense' && montant > data.soldeCaisse) {
      afficherToast(context,
          'Solde insuffisant (${Formatters.montant(data.soldeCaisse, devise: data.devise)} disponibles)',
          estErreur: true);
      return;
    }

    final nomMembre = (type == 'penalite' && membrePenaliteId != null)
        ? (membresOrdre.where((m) => m.id == membrePenaliteId).firstOrNull?.nom ?? '')
        : '';
    final descFinale = descCtrl.text.trim().isNotEmpty
        ? descCtrl.text.trim()
        : (type == 'penalite' && nomMembre.isNotEmpty ? 'Pénalité — $nomMembre' : '');

    final libelleType = type == 'apport'
        ? 'Apport'
        : type == 'depense'
            ? 'Dépense'
            : 'Pénalité';

    final ok = await afficherModalePin(
      context,
      titre: 'Confirmer le mouvement',
      sousTitre: 'Vérifie les détails avant de confirmer avec ton PIN.',
      recap: [
        (label: 'Type', valeur: libelleType),
        (label: 'Montant', valeur: Formatters.montant(montant, devise: data.devise)),
        if (descFinale.isNotEmpty) (label: 'Description', valeur: descFinale),
        (label: 'Solde actuel', valeur: Formatters.montant(data.soldeCaisse, devise: data.devise)),
      ],
      onValider: (pin) async {
        final ref = Formatters.genererReference();
        final now = DateTime.now().toIso8601String();
        final newData = data.toJson();
        // ── Correction : caisse est stockée comme {mouvements:[...]} ─────────
        // toJson() produit {'mouvements':[...]}, on lit donc dans cette Map.
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
        final entree = {
          'id': ref,
          'type': type,
          'montant': montant,
          'description': descFinale,
          'gestionnaire': provider.gestActifNom ?? '',
          'date': now,
          'reference': ref,
        };
        if (type == 'penalite' && membrePenaliteId != null) {
          entree['membreId'] = membrePenaliteId!;
          entree['membreNom'] = nomMembre;
        }
        caisse.add(entree);
        // Toujours écrire dans le format attendu par TontineData.fromJson()
        newData['caisse'] = {'mouvements': caisse};

        // Pénalité : incrémenter compteur + baisser score de confiance du membre
        if (type == 'penalite' && membrePenaliteId != null) {
          final membres = List<Map<String, dynamic>>.from(
            (newData['membres'] as List<dynamic>).cast<Map<String, dynamic>>(),
          );
          final idx = membres.indexWhere((m) => m['id'] == membrePenaliteId);
          if (idx >= 0) {
            membres[idx]['penalites'] = ((membres[idx]['penalites'] as int?) ?? 0) + 1;
            membres[idx]['score'] = (((membres[idx]['score'] as int?) ?? 50) - 5).clamp(0, 100);
          }
          newData['membres'] = membres;
        }

        final journal = List<Map<String, dynamic>>.from(
          (newData['journal'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ?? [],
        );
        journal.insert(0, {
          'quoi': type == 'penalite'
              ? 'PÉNALITÉ \u2014 $nomMembre \u2014 ${Formatters.montant(montant, devise: data.devise)}'
              : '${type == 'apport' ? 'APPORT' : 'DÉPENSE'} CAISSE \u2014 ${Formatters.montant(montant, devise: data.devise)}${descFinale.isNotEmpty ? ' \u2014 $descFinale' : ''}',
          'gestionnaire': provider.gestActifNom ?? '',
          'quand': now,
          'reference': ref,
        });
        newData['journal'] = journal;

        return provider.ecrire(newData, pin);
      },
    );

    if (ok == true && context.mounted) {
      afficherToast(context,
          type == 'penalite' ? 'Pénalité appliquée !' : 'Mouvement enregistré !');
    }
  }
}

class _BtnAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color couleur;
  final VoidCallback onTap;

  const _BtnAction({
    required this.icon,
    required this.label,
    required this.couleur,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: couleur.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: couleur.withValues(alpha: 0.3)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: couleur, size: 22),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 12,
                color: couleur,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LigneMouvement extends StatelessWidget {
  final MouvementCaisse mouvement;
  final String devise;

  const _LigneMouvement({required this.mouvement, this.devise = 'XOF'});

  bool get _isEntree =>
      mouvement.type == 'apport' ||
      mouvement.type == 'penalite' ||
      mouvement.type == 'remboursement';

  @override
  Widget build(BuildContext context) {
    final date = DateTime.tryParse(mouvement.date);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.carte,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.lignes),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: _isEntree ? AppColors.succesFond : AppColors.alerteFond,
              shape: BoxShape.circle,
            ),
            child: Icon(
              _isEntree ? Icons.add : Icons.remove,
              size: 18,
              color: _isEntree ? AppColors.succes : AppColors.alerte,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  mouvement.description.isNotEmpty
                      ? mouvement.description
                      : Formatters.capitaliser(mouvement.type),
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                    color: AppColors.texte,
                  ),
                ),
                Text(
                  '${mouvement.gestionnaire} · ${Formatters.dateFormatee(date)}',
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: AppColors.texteDoux,
                  ),
                ),
              ],
            ),
          ),
          Text(
            '${_isEntree ? '+' : '-'}${Formatters.montant(mouvement.montant, devise: devise)}',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 15,
              color: _isEntree ? AppColors.succes : AppColors.alerte,
            ),
          ),
        ],
      ),
    );
  }
}
