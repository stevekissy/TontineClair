import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/tontine.dart';
import '../services/tontine_provider.dart';
import '../services/devise_service.dart';
import '../services/supabase_service.dart';
import '../services/blockchain_service.dart';
import '../services/kyc_service.dart';
import '../utils/app_colors.dart';
import '../utils/formatters.dart';
import '../widgets/app_widgets.dart';
import '../utils/app_localizations.dart';
import '../services/locale_service.dart';
import 'paiement_choix_screen.dart';
import 'kyc_screen.dart';
import '../services/subscription_service.dart';
import '../services/email_service.dart' as email_svc;

// ─── Widget animé pour le solde caisse ────────────────────────────────────────
/// Affiche le solde avec une animation de compteur fun quand la valeur change.
class _SoldeAnime extends StatefulWidget {
  final int solde;
  final String devise;

  const _SoldeAnime({required this.solde, required this.devise});

  @override
  State<_SoldeAnime> createState() => _SoldeAnimeState();
}

class _SoldeAnimeState extends State<_SoldeAnime>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _anim;
  int _ancienSolde = 0;

  @override
  void initState() {
    super.initState();
    _ancienSolde = widget.solde;
    _ctrl = AnimationController(
      duration: const Duration(milliseconds: 1200),
      vsync: this,
    );
    _anim = CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic);
  }

  @override
  void didUpdateWidget(_SoldeAnime oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.solde != widget.solde) {
      _ancienSolde = oldWidget.solde;
      _ctrl.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _anim,
      builder: (context, _) {
        final valeurAffichee = (_ancienSolde +
                (_anim.value * (widget.solde - _ancienSolde)))
            .round();
        return Text(
          Formatters.montant(valeurAffichee, devise: widget.devise),
          style: const TextStyle(
            fontWeight: FontWeight.w800,
            fontSize: 34,
            color: Colors.white,
          ),
        );
      },
    );
  }
}

// ─── Opérateurs Mobile Money disponibles ──────────────────────────────────────
const _operateursMobileMoney = ['orange', 'moov', 'mtn', 'wave'];

class CaisseScreen extends StatefulWidget {
  final String code;

  const CaisseScreen({super.key, required this.code});

  @override
  State<CaisseScreen> createState() => _CaisseScreenState();
}

class _CaisseScreenState extends State<CaisseScreen> {

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
                        _SoldeAnime(
                          solde: data.soldeCaisse,
                          devise: data.devise,
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
                            // Mode Pro : apport via CoinPayments — Mode Lite : modale PIN
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
                  else ...data.caisse.reversed.map(
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

  // ── Notifie tous les gestionnaires ayant un email d'un mouvement caisse ────
  // Appelé de manière non-bloquante (fire-and-forget) après chaque mouvement.
  static Future<void> _envoyerEmailsMouvement({
    required TontineData data,
    required String      typeLibelle, // 'Apport', 'Dépense', 'Pénalité'
    required int         montant,
    required String      gestActif,   // nom du gestionnaire qui a effectué l'action
    required String      devise,
    String?              description,
    String?              membreNom,   // pour les pénalités
  }) async {
    // Filtre : gestionnaires avec email renseigné
    final destinataires = data.gestionnaires
        .where((g) => g.email.trim().isNotEmpty)
        .toList();
    if (destinataires.isEmpty) return;

    final montantStr = Formatters.montant(montant, devise: devise);
    final desc       = description?.isNotEmpty == true ? description! : '';
    final tontineNom = data.nom;

    // Libellé complet selon le type
    final String detailAction;
    final String icone;
    final String couleur;
    switch (typeLibelle) {
      case 'Apport':
        detailAction = 'Un apport de <strong>$montantStr</strong> a été enregistré dans la caisse commune.';
        icone = '💰';
        couleur = '#2E7D5B';
      case 'Dépense':
        detailAction = 'Une dépense de <strong>$montantStr</strong> a été effectuée depuis la caisse commune${desc.isNotEmpty ? ' — $desc' : ''}.';
        icone = '💸';
        couleur = '#C4453C';
      case 'Pénalité':
        final membre = membreNom?.isNotEmpty == true ? ' sur <strong>$membreNom</strong>' : '';
        detailAction = 'Une pénalité de <strong>$montantStr</strong>$membre a été appliquée.';
        icone = '⚠️';
        couleur = '#D99A2B';
      default:
        detailAction = 'Un mouvement de <strong>$montantStr</strong> a été enregistré.';
        icone = '📋';
        couleur = '#1C2447';
    }

    // Envoyer en parallèle à tous les gestionnaires (non-bloquant)
    for (final gest in destinataires) {
      final nomAffiche = gest.prenom.isNotEmpty
          ? '${gest.prenom} ${gest.nomFamille}'.trim()
          : gest.nom;

      email_svc.EmailService.envoyer(
        type:        email_svc.TypeEmail.alerteSecurite, // type générique pour le layout
        destinataire: gest.email.trim(),
        variables: {
          'nom':     nomAffiche,
          'action':  '$icone $typeLibelle caisse — $tontineNom',
          'message': detailAction,
          'tontine': tontineNom,
          'date':    DateTime.now().toLocal().toString().substring(0, 16),
          'gest_actif': gestActif,
        },
      ).catchError((e) {
        if (kDebugMode) debugPrint('[CaisseEmail] Erreur envoi à ${gest.email}: $e');
        return email_svc.EmailResult.echec(e.toString());
      });
    }
  }

  // ── Apport Pro : saisie montant + description → CoinPayments ─────────────
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
                  children: [
                    Icon(Icons.rocket_launch_rounded, size: 13, color: Color(0xFF1A6B3C)),
                    SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        'Le paiement sera effectué automatiquement via Mobile Money',
                        style: TextStyle(fontSize: 12, color: Color(0xFF1A6B3C)),
                        softWrap: true,
                      ),
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
                label: 'Continuer vers le paiement',
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

    // Paiement via CoinPayments (Crypto)
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PaiementChoixScreen(
          code:        tontine.code,
          typeFlux:    'caisse',
          montant:     montant,
          description: descCtrl.text.trim().isNotEmpty
              ? descCtrl.text.trim()
              : 'Apport en caisse',
        ),
      ),
    );
    // Toujours recharger au retour
    if (context.mounted) {
      provider.chargerTontine(tontine.code, silencieux: true);
    }
    // ── Email à tous les gestionnaires ──
    _envoyerEmailsMouvement(
      data:        data,
      typeLibelle: 'Apport',
      montant:     montant,
      gestActif:   provider.gestActifNom ?? '',
      devise:      data.devise,
      description: descCtrl.text.trim(),
    );
  }

  // ── Dépense Premium : Mobile Money uniquement → statut pending → validation admin ──
  Future<void> _depensePremium(
    BuildContext context,
    TontineProvider provider,
    dynamic tontine,
    TontineData data,
  ) async {
    // ── Garde KYC — ignoré pour les abonnés Premium actifs ──────────────
    // Un abonnement Premium actif dispense de la vérification KYC pour les
    // dépenses de caisse. Sinon, on vérifie le statut KYC normalement.
    final bool abonnementActif = SubscriptionService.isPremium;
    if (!abonnementActif) {
      final gestNom = provider.gestActifNom ?? '';
      if (gestNom.isNotEmpty) {
        final kycResult = await KycService.canPerformFinancialAction(
          userId:     gestNom,
          actionType: 'withdrawal',
          amount:     data.soldeCaisse.toDouble(),
        );
        if (!kycResult.allowed && context.mounted) {
          final allerKyc = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              backgroundColor: AppColors.fondPapier,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
              title: const Row(children: [
                Icon(Icons.verified_user_outlined, color: AppColors.or, size: 22),
                SizedBox(width: 10),
                Expanded(
                  child: Text('Vérification d\'identité requise',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15, color: AppColors.encre)),
                ),
              ]),
              content: Text(
                kycResult.reason ??
                'Les dépenses de caisse Premium nécessitent une vérification d\'identité préalable.',
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
          if (context.mounted && allerKyc == true) {
            Navigator.push(context, MaterialPageRoute(builder: (_) => KycScreen(userId: gestNom)));
          }
          return;
        }
      }
    }

    final montantCtrl = TextEditingController();
    final descCtrl    = TextEditingController();
    final numCtrl     = TextEditingController();
    final nomCtrl     = TextEditingController();
    String operateur  = _operateursMobileMoney.first;

    // ── Membres disponibles pour pré-remplissage MM ──────────────────────────
    final membres = data.membresActifs;
    String? membreSelId; // null = bénéficiaire externe

    void preRemplirDepuisMembre(String? membreId, void Function(void Function()) setS) {
      final m = membres.where((m) => m.id == membreId).firstOrNull;
      if (m != null) {
        setS(() {
          if (m.operateur != null && _operateursMobileMoney.contains(m.operateur)) {
            operateur = m.operateur!;
          }
          numCtrl.text = m.numeroBenef ?? '';
          nomCtrl.text = m.nom;
        });
      }
    }

    // ── Formulaire dépense caisse ─────────────────────────────────────────
    if (!context.mounted) return;
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.fondPapier,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) {
          final membreSel = membres.where((m) => m.id == membreSelId).firstOrNull;
          final mmPreRempli = membreSel != null && (membreSel.numeroBenef?.isNotEmpty ?? false);
          return Padding(
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
                // Sélecteur membre (optionnel — pré-remplit automatiquement les champs MM)
                if (membres.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String?>(
                    value: membreSelId,
                    decoration: InputDecoration(
                      labelText: 'Bénéficiaire membre (optionnel)',
                      labelStyle: const TextStyle(fontSize: 13, color: AppColors.texteDoux),
                      prefixIcon: const Icon(Icons.person_outline_rounded, size: 18),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: const BorderSide(color: AppColors.lignes),
                      ),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    ),
                    isExpanded: true,
                    items: [
                      const DropdownMenuItem<String?>(
                        value: null,
                        child: Text('— Bénéficiaire externe —',
                            style: TextStyle(fontSize: 13, color: AppColors.texteDoux)),
                      ),
                      ...membres.map((m) => DropdownMenuItem<String?>(
                        value: m.id,
                        child: Row(
                          children: [
                            Expanded(child: Text(m.nom, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13))),
                            if (m.numeroBenef?.isNotEmpty ?? false)
                              const Icon(Icons.check_circle_outline, size: 14, color: Color(0xFF2E7D5B)),
                          ],
                        ),
                      )),
                    ],
                    onChanged: (v) {
                      setS(() => membreSelId = v);
                      preRemplirDepuisMembre(v, setS);
                    },
                  ),
                  // Badge pré-rempli
                  if (mmPreRempli) ...[
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: const Color(0xFFE8F5E9),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: const Color(0xFF2E7D5B).withValues(alpha: 0.4)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.check_circle_rounded, color: Color(0xFF2E7D5B), size: 14),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              'PayDunya utilisera automatiquement : ${Formatters.methodePaiement(membreSel!.operateur ?? '')}  ·  ${membreSel.numeroBenef}',
                              style: const TextStyle(fontSize: 11, color: Color(0xFF1B5E3B), fontWeight: FontWeight.w600),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                ],
                // Badge paiement crypto
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: const Color(0xFFEAF4EE),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.currency_bitcoin_rounded, size: 13, color: Color(0xFF1A6B3C)),
                      SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          'Paiement crypto — CoinPayments',
                          style: TextStyle(fontSize: 12, color: Color(0xFF1A6B3C)),
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
                  initialValue: operateur,
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
                  label: 'Continuer vers le paiement',
                  icone: Icons.account_balance_wallet_rounded,
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
        );
      }, // builder: (ctx, setS)
      ),
    );

    if (confirmed != true || !context.mounted) return;

    // ── Validations ──────────────────────────────────────────────────────
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

    // Paiement CoinPayments
    if (!context.mounted) return;

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PaiementChoixScreen(
          code:        tontine.code,
          typeFlux:    'depense_caisse',
          montant:     montant,
          description: descCtrl.text.trim().isNotEmpty
              ? descCtrl.text.trim()
              : 'Dépense caisse',
          membreNom:   nomCtrl.text.trim(),
          telephone:   numCtrl.text.trim(),
          operateur:   operateur,
        ),
      ),
    );
    // Toujours recharger au retour
    if (context.mounted) {
      provider.chargerTontine(tontine.code, silencieux: true);
    }
    // ── Email à tous les gestionnaires ──
    _envoyerEmailsMouvement(
      data:        data,
      typeLibelle: 'Dépense',
      montant:     montant,
      gestActif:   provider.gestActifNom ?? '',
      devise:      data.devise,
      description: descCtrl.text.trim(),
    );
  }

  // ── Pénalité Pro : sélection membre + montant → CoinPayments ───────────────
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
                // Badge paiement crypto
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: AppColors.orFonce.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.currency_bitcoin_rounded, size: 13, color: AppColors.orFonce),
                      SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          'Paiement de la pénalité via CoinPayments Crypto',
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
                  initialValue: membrePenaliteId,
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
                  label: 'Continuer vers le paiement',
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

    // Paiement via CoinPayments (Crypto)
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PaiementChoixScreen(
          code:        tontine.code,
          typeFlux:    'penalite',
          montant:     montant,
          description: descCtrl.text.trim().isNotEmpty
              ? descCtrl.text.trim()
              : 'Pénalité',
          membreId:    membrePenaliteId,
          membreNom:   membre?.nom ?? '',
        ),
      ),
    );
    // Toujours recharger au retour
    if (context.mounted) {
      provider.chargerTontine(tontine.code, silencieux: true);
    }
    // ── Email à tous les gestionnaires ──
    _envoyerEmailsMouvement(
      data:        data,
      typeLibelle: 'Pénalité',
      montant:     montant,
      gestActif:   provider.gestActifNom ?? '',
      devise:      data.devise,
      description: descCtrl.text.trim(),
      membreNom:   membre?.nom,
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
                    initialValue: membrePenaliteId,
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
                    initialValue: methode,
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

    // ref généré ici pour être accessible à la fois dans onValider ET dans le bloc blockchain
    final ref = Formatters.genererReference();

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
                  ? caisseMap.cast<Map<String, dynamic>>()
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

    // ── BLOCKCHAIN : pénalité / dépense / apport caisse (non-bloquant) ──
    if (ok == true) {
      if (type == 'penalite' && membrePenaliteId != null) {
        BlockchainService.enregistrerPenalite(
          tontineCode: widget.code,
          membreId   : membrePenaliteId!,
          membreNom  : nomMembre,
          montantXof : montant,
          refInterne : ref,
        ).catchError((e) {
          if (kDebugMode) debugPrint('[Blockchain] penalite erreur: $e');
          return BlockchainResultat(ok: false, erreur: '$e', phase: 1);
        });
      } else if (type == 'depense') {
        BlockchainService.enregistrerDepenseCaisse(
          tontineCode : widget.code,
          montantXof  : montant,
          description : descFinale.isNotEmpty ? descFinale : 'Dépense caisse',
          gestionnaire: provider.gestActifNom,
          refInterne  : ref,
        ).catchError((e) {
          if (kDebugMode) debugPrint('[Blockchain] depense_caisse erreur: $e');
          return BlockchainResultat(ok: false, erreur: '$e', phase: 1);
        });
      } else if (type == 'apport') {
        // Apport caisse manuel (espèces / Mobile Money hors CoinPayments)
        BlockchainService.enregistrerApport(
          tontineCode: widget.code,
          membreId   : provider.gestActifNom ?? 'gest',
          membreNom  : provider.gestActifNom ?? '',
          montantXof : montant,
          refInterne : ref,
        ).catchError((e) {
          if (kDebugMode) debugPrint('[Blockchain] apport_caisse erreur: $e');
          return BlockchainResultat(ok: false, erreur: '$e', phase: 1);
        });
      }
    }
    // ────────────────────────────────────────────────────────────────────

    if (ok == true && context.mounted) {
      afficherToast(context,
          type == 'penalite' ? 'Pénalité appliquée !' : 'Mouvement enregistré !');
      // ── Email à tous les gestionnaires (mouvement manuel caisse gratuite) ──
      _envoyerEmailsMouvement(
        data:        data,
        typeLibelle: type == 'apport' ? 'Apport'
                   : type == 'depense' ? 'Dépense'
                   : 'Pénalité',
        montant:     montant,
        gestActif:   provider.gestActifNom ?? '',
        devise:      data.devise,
        description: descFinale,
        membreNom:   type == 'penalite' ? nomMembre : null,
      );
      final lang = Provider.of<LocaleService>(context, listen: false).langue.code;
      final typeNotif = type == 'penalite' ? 'penalite' : 'caisse';
      final montantStr = Formatters.montant(montant, devise: data.devise);
      final desc = descFinale.isNotEmpty ? ' — $descFinale' : '';
      final t = SupabaseService.notifTexte(typeNotif, lang, vars: {
        'nom': nomMembre,
        'montant': montantStr,
        'libelle': libelleType,
        'desc': desc,
      });
      SupabaseService.envoyerNotification(
        code: widget.code,
        type: typeNotif,
        titre: t['titre']!,
        message: t['message']!,
      );
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
      mouvement.type == 'cotisation' ||
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

