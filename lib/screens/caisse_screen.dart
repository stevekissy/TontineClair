import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/tontine.dart';
import '../services/tontine_provider.dart';
import '../services/devise_service.dart';
import '../services/supabase_service.dart';
import '../utils/app_colors.dart';
import '../utils/formatters.dart';
import '../widgets/app_widgets.dart';
import '../utils/app_localizations.dart';
import '../services/locale_service.dart';
import 'paiement_caisse_pro_screen.dart';

// ─── Opérateurs Mobile Money disponibles ──────────────────────────────────────
const _operateursMobileMoney = ['orange', 'moov', 'mtn', 'wave'];

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
                    context.tr('caisse_commune'),
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 28,
                      color: AppColors.encre,
                    ),
                  ),
                  SizedBox(height: 16),
                  // Solde
                  Container(
                    padding: EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: AppColors.encre,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Column(
                      children: [
                        Text(
                          context.tr('solde_disponible'),
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
                  SizedBox(height: 16),
                  // Actions gestionnaire
                  if (estGest) ...[
                    Row(
                      children: [
                        Expanded(
                          child: _BtnAction(
                            icon: Icons.add,
                            label: context.tr('apport'),
                            couleur: AppColors.succes,
                            // Mode Pro : apport via SycaPay — Mode Lite : modale PIN
                            onTap: () => tontine.isPremium
                                ? _apportPro(context, provider, tontine, data)
                                : _mouvement(context, provider, data, 'apport'),
                          ),
                        ),
                        SizedBox(width: 10),
                        Expanded(
                          child: _BtnAction(
                            icon: Icons.remove,
                            label: context.tr('depense'),
                            couleur: AppColors.alerte,
                            onTap: () => tontine.isPremium
                                ? _depensePremium(context, provider, tontine, data)
                                : _mouvement(context, provider, data, 'depense'),
                          ),
                        ),
                        SizedBox(width: 10),
                        Expanded(
                          child: _BtnAction(
                            icon: Icons.warning_amber,
                            label: context.tr('penalite'),
                            couleur: AppColors.orFonce,
                            onTap: () => tontine.isPremium
                                ? _penalitePro(context, provider, tontine, data)
                                : _mouvement(context, provider, data, 'penalite'),
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: 16),
                  ],
                  // Historique
                  Text(
                    context.tr('mouvements'),
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 18,
                      color: AppColors.encre,
                    ),
                  ),
                  SizedBox(height: 10),
                  if (data.caisse.isEmpty)
                    Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          context.tr('aucun_mouvement'),
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

  // ── Apport Pro : saisie montant + description → SycaPay ──────────────────
  Future<void> _apportPro(
    BuildContext context,
    TontineProvider provider,
    dynamic tontine,
    TontineData data,
  ) async {
    final montantCtrl = TextEditingController();
    final descCtrl = TextEditingController();

    // Modale légère pour saisir montant et description
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.fondPapier,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
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
                'Apport de caisse Pro',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 20,
                  color: AppColors.encre,
                ),
              ),
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: const Color(0xFFEAF4EE),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.rocket_launch_rounded, size: 13, color: Color(0xFF1A6B3C)),
                    SizedBox(width: 6),
                    Text(
                      'Le paiement sera effectué via SycaPay Mobile Money',
                      style: TextStyle(fontSize: 12, color: Color(0xFF1A6B3C)),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              ChampLabel(label: 'Montant (${DeviseService.parCode(data.devise).symbole})'),
              TextField(
                controller: montantCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(hintText: '5 000'),
                autofocus: true,
              ),
              ChampLabel(label: context.tr('description_motif')),
              TextField(
                controller: descCtrl,
                maxLength: 100,
                decoration: const InputDecoration(
                  hintText: 'Ex : Frais de local',
                  counterText: '',
                ),
              ),
              const SizedBox(height: 16),
              BtnPrincipal(
                label: 'Continuer vers SycaPay',
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
    );

    if (confirmed != true || !context.mounted) return;

    final montant = int.tryParse(montantCtrl.text.trim());
    if (montant == null || montant <= 0) {
      afficherToast(context, 'Montant invalide', estErreur: true);
      return;
    }

    // Ouvrir l'écran SycaPay pour apport caisse
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PaiementCaisseProScreen(
          code: tontine.code,
          montant: montant,
          description: descCtrl.text.trim(),
        ),
      ),
    );
  }

  // ── Dépense Premium : Mobile Money uniquement → statut pending → validation admin ──
  Future<void> _depensePremium(
    BuildContext context,
    TontineProvider provider,
    dynamic tontine,
    TontineData data,
  ) async {
    final montantCtrl = TextEditingController();
    final descCtrl    = TextEditingController();
    final numCtrl     = TextEditingController();
    final nomCtrl     = TextEditingController();
    String operateur  = _operateursMobileMoney.first;

    final confirmed = await showModalBottomSheet<bool>(
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
                  'Dépense de caisse',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 20,
                    color: AppColors.encre,
                  ),
                ),
                const SizedBox(height: 4),
                // Badge info paiement
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFF3E0),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.phone_android_rounded, size: 13, color: Color(0xFFE65100)),
                      SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          'Mobile Money — validation admin requise',
                          style: TextStyle(fontSize: 12, color: Color(0xFFE65100)),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                // Montant
                ChampLabel(label: 'Montant (${DeviseService.parCode(data.devise).symbole})'),
                TextField(
                  controller: montantCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(hintText: '5 000'),
                  autofocus: true,
                ),
                // Description
                ChampLabel(label: 'Description / motif'),
                TextField(
                  controller: descCtrl,
                  maxLength: 100,
                  decoration: const InputDecoration(
                    hintText: 'Ex : Frais de local',
                    counterText: '',
                  ),
                ),
                // Opérateur
                ChampLabel(label: 'Opérateur Mobile Money'),
                DropdownButtonFormField<String>(
                  value: operateur,
                  decoration: const InputDecoration(),
                  items: _operateursMobileMoney
                      .map((op) => DropdownMenuItem(
                            value: op,
                            child: Text(Formatters.methodePaiement(op)),
                          ))
                      .toList(),
                  onChanged: (v) => setS(() => operateur = v!),
                ),
                // Numéro bénéficiaire
                ChampLabel(label: 'Numéro bénéficiaire'),
                TextField(
                  controller: numCtrl,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(hintText: 'Ex : 07 01 02 03'),
                ),
                // Nom bénéficiaire
                ChampLabel(label: 'Nom bénéficiaire'),
                TextField(
                  controller: nomCtrl,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(hintText: 'Ex : Kouamé Jean'),
                ),
                const SizedBox(height: 16),
                BtnPrincipal(
                  label: 'Soumettre pour validation',
                  icone: Icons.send_rounded,
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

    if (confirmed != true || !context.mounted) return;

    // Validations
    final montant = int.tryParse(montantCtrl.text.trim());
    if (montant == null || montant <= 0) {
      afficherToast(context, 'Montant invalide', estErreur: true);
      return;
    }
    if (montant > data.soldeCaisse) {
      afficherToast(
        context,
        'Solde insuffisant (${Formatters.montant(data.soldeCaisse, devise: data.devise)} disponibles)',
        estErreur: true,
      );
      return;
    }
    if (numCtrl.text.trim().isEmpty) {
      afficherToast(context, 'Numéro bénéficiaire requis', estErreur: true);
      return;
    }
    if (nomCtrl.text.trim().isEmpty) {
      afficherToast(context, 'Nom bénéficiaire requis', estErreur: true);
      return;
    }

    // Confirmation simple (pas de PIN — la validation sera faite par l'admin)
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.fondPapier,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          'Confirmer la dépense',
          style: TextStyle(fontWeight: FontWeight.w700, color: AppColors.encre),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _RecapLigne('Montant', Formatters.montant(montant, devise: data.devise)),
            _RecapLigne('Opérateur', Formatters.methodePaiement(operateur)),
            _RecapLigne('Bénéficiaire', nomCtrl.text.trim()),
            _RecapLigne('Numéro', numCtrl.text.trim()),
            if (descCtrl.text.trim().isNotEmpty)
              _RecapLigne('Motif', descCtrl.text.trim()),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.orFonce.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                '⏳ La dépense sera soumise à validation par l\'admin. La caisse ne sera débitée qu\'après approbation.',
                style: TextStyle(fontSize: 12, color: AppColors.orFonce, height: 1.4),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Annuler'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.alerte),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Soumettre', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );

    if (ok != true || !context.mounted) return;

    // Soumettre la dépense en pending dans Supabase
    try {
      final ref = Formatters.genererReference();
      await SupabaseService.soumettreDepensePending(
        code: tontine.code,
        montant: montant,
        description: descCtrl.text.trim(),
        operateur: operateur,
        numeroBeneficiaire: numCtrl.text.trim(),
        nomBeneficiaire: nomCtrl.text.trim(),
        gestionnaire: provider.gestActifNom ?? '',
        reference: ref,
        devise: data.devise,
      );
      if (context.mounted) {
        afficherToast(
          context,
          '✅ Dépense soumise ! En attente de validation admin.',
        );
      }
    } catch (e) {
      if (context.mounted) {
        afficherToast(context, 'Erreur : $e', estErreur: true);
      }
    }
  }

  // ── Pénalité Pro : sélection membre + montant → SycaPay ─────────────────────
  Future<void> _penalitePro(
    BuildContext context,
    TontineProvider provider,
    dynamic tontine,
    TontineData data,
  ) async {
    final montantCtrl  = TextEditingController();
    final descCtrl     = TextEditingController();
    final membresOrdre = data.membresActifs;

    if (membresOrdre.isEmpty) {
      afficherToast(context, 'Aucun membre actif dans cette tontine', estErreur: true);
      return;
    }

    String? membrePenaliteId = membresOrdre.first.id;

    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.fondPapier,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => Padding(
          padding: EdgeInsets.only(
            left: 16, right: 16, top: 16,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
          ),
          child: SingleChildScrollView(
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
                  'Pénalité Pro',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 20, color: AppColors.encre),
                ),
                const SizedBox(height: 4),
                // Badge SycaPay
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: AppColors.orFonce.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.rocket_launch_rounded, size: 13, color: AppColors.orFonce),
                      SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          'Le paiement de la pénalité sera effectué via SycaPay',
                          style: TextStyle(fontSize: 12, color: AppColors.orFonce),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                // Membre à pénaliser
                ChampLabel(label: 'Membre à pénaliser'),
                DropdownButtonFormField<String>(
                  value: membrePenaliteId,
                  decoration: const InputDecoration(),
                  items: membresOrdre.map((m) => DropdownMenuItem(
                    value: m.id,
                    child: Text(m.nom, overflow: TextOverflow.ellipsis),
                  )).toList(),
                  onChanged: (v) => setS(() => membrePenaliteId = v),
                ),
                const SizedBox(height: 4),
                // Montant
                ChampLabel(label: 'Montant (${DeviseService.parCode(data.devise).symbole})'),
                TextField(
                  controller: montantCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(hintText: '1 000'),
                  autofocus: true,
                ),
                // Description (optionnelle)
                ChampLabel(label: 'Motif (optionnel)'),
                TextField(
                  controller: descCtrl,
                  maxLength: 100,
                  decoration: const InputDecoration(
                    hintText: 'Ex : Retard de cotisation',
                    counterText: '',
                  ),
                ),
                const SizedBox(height: 16),
                BtnPrincipal(
                  label: 'Continuer vers SycaPay',
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

    if (confirmed != true || !context.mounted) return;

    final montant = int.tryParse(montantCtrl.text.trim());
    if (montant == null || montant <= 0) {
      afficherToast(context, 'Montant invalide', estErreur: true);
      return;
    }
    if (membrePenaliteId == null) {
      afficherToast(context, 'Veuillez sélectionner un membre', estErreur: true);
      return;
    }

    final membre = membresOrdre.where((m) => m.id == membrePenaliteId).firstOrNull;
    if (!context.mounted) return;

    // Ouvrir l'écran SycaPay pour pénalité
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PaiementCaisseProScreen(
          code:          tontine.code,
          montant:       montant,
          description:   descCtrl.text.trim(),
          typeOperation: 'penalite',
          membreId:      membrePenaliteId,
          membreNom:     membre?.nom ?? '',
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
                SizedBox(height: 16),
                Text(
                  type == 'apport'
                      ? context.tr('apport_caisse')
                      : type == 'depense'
                          ? 'Dépense de caisse'
                          : 'Appliquer une pénalité',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 20,
                    color: AppColors.encre,
                  ),
                ),
                // Membre pénalisé (pénalité uniquement)
                if (type == 'penalite' && membresOrdre.isNotEmpty) ...[
                  ChampLabel(label: context.tr('membre_penalise')),
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
                  decoration: InputDecoration(hintText: '5 000'),
                  autofocus: true,
                ),
                ChampLabel(label: context.tr('description_motif')),
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
                  ChampLabel(label: context.tr('mode_paiement_label')),
                  DropdownButtonFormField<String>(
                    value: methode,
                    decoration: InputDecoration(),
                    items: ['especes', 'orange', 'mtn', 'moov', 'wave']
                        .map((m) => DropdownMenuItem(
                              value: m,
                              child: Text(Formatters.methodePaiement(m)),
                            ))
                        .toList(),
                    onChanged: (v) => setS(() => methode = v!),
                  ),
                ],
                SizedBox(height: 16),
                BtnPrincipal(
                  label: context.tr('enregistrer'),
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
      final _lang = Provider.of<LocaleService>(context, listen: false).langue.code;
      final _typeNotif = type == 'penalite' ? 'penalite' : 'caisse';
      final _montantStr = Formatters.montant(montant, devise: data.devise);
      final _desc = descFinale.isNotEmpty ? ' — $descFinale' : '';
      final _t = SupabaseService.notifTexte(_typeNotif, _lang, vars: {
        'nom': nomMembre,
        'montant': _montantStr,
        'libelle': libelleType,
        'desc': _desc,
      });
      SupabaseService.envoyerNotification(
        code: code,
        type: _typeNotif,
        titre: _t['titre']!,
        message: _t['message']!,
      );
    }
  }
}

// ─── Ligne récap dialog de confirmation ───────────────────────────────────────
class _RecapLigne extends StatelessWidget {
  final String label;
  final String valeur;
  const _RecapLigne(this.label, this.valeur);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$label : ',
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AppColors.texteDoux,
            ),
          ),
          Expanded(
            child: Text(
              valeur,
              style: const TextStyle(fontSize: 13, color: AppColors.encre),
            ),
          ),
        ],
      ),
    );
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
