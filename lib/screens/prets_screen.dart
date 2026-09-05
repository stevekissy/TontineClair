import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/tontine.dart';
import '../services/tontine_provider.dart';
import '../services/devise_service.dart';
import '../services/supabase_service.dart';
import '../services/blockchain_service.dart';
import '../utils/app_colors.dart';
import '../utils/formatters.dart';
import '../widgets/app_widgets.dart';
import '../utils/app_localizations.dart';
import '../services/locale_service.dart';
import 'paiement_choix_screen.dart';

// ── Opérateurs Mobile Money disponibles ───────────────────────────────────────
const _operateursPret = ['orange', 'moov', 'mtn', 'wave'];

// ── Bug #3 fix : StatefulWidget pour permettre le rechargement des membres ──
class PretsScreen extends StatefulWidget {
  final String code;

  const PretsScreen({super.key, required this.code});

  @override
  State<PretsScreen> createState() => _PretsScreenState();
}

class _PretsScreenState extends State<PretsScreen> {
  bool _chargement = false;

  /// Prêts soumis en attente de validation admin (table prets_pending)
  List<Map<String, dynamic>> _pretsPending = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _recharger());
  }

  Future<void> _recharger() async {
    if (!mounted) return;
    setState(() => _chargement = true);
    try {
      await Future.wait([
        context.read<TontineProvider>().chargerTontine(widget.code),
        _chargerPending(),
      ]);
    } finally {
      if (mounted) setState(() => _chargement = false);
    }
  }

  /// Charge les demandes pending depuis prets_pending (toutes statuts pour affichage complet)
  Future<void> _chargerPending() async {
    try {
      final liste = await SupabaseService.listerPretsPendingPourCode(widget.code);
      if (mounted) setState(() => _pretsPending = liste);
    } catch (_) {
      // Non-bloquant : on affiche juste sans les pending si erreur
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
              child: RefreshIndicator(
                onRefresh: _recharger,
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
                      label: 'Nouveau prêt',
                      icon: Icons.add,
                      onTap: () => _nouveauPret(context, provider, tontine, data),
                    ),
                  SizedBox(height: 16),

                  // ── Section prêts en attente de validation (prets_pending) ──
                  if (_pretsPending.isNotEmpty) ...[
                    _SectionPending(pretsPending: _pretsPending),
                    const SizedBox(height: 20),
                    const Divider(),
                    const SizedBox(height: 8),
                  ],

                  // ── Section prêts validés / historique ──────────────────────
                  if (data.prets.isEmpty && _pretsPending.isEmpty)
                    Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Column(
                          children: [
                            Icon(Icons.account_balance_outlined, size: 48, color: AppColors.texteDoux.withValues(alpha: 0.4)),
                            const SizedBox(height: 12),
                            Text(
                              context.tr('aucun_pret'),
                              style: TextStyle(color: AppColors.texteDoux),
                            ),
                          ],
                        ),
                      ),
                    )
                  else if (data.prets.isNotEmpty) ...[
                    if (_pretsPending.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Text(
                          'Prêts accordés',
                          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16, color: AppColors.encre),
                        ),
                      ),
                    ...data.prets.map(
                      (p) => _CartePret(
                        pret: p,
                        estGest: estGest,
                        data: data,
                        provider: provider,
                        isPremium:   tontine.isPremium == true,
                        tontineCode: tontine.code,
                      ),
                    ),
                  ],
                ],
              ),
              ), // RefreshIndicator
            ),
          ],
        ),
      ),
    );
  }

  // ── Nouveau prêt : formulaire complet ────────────────────────────────────
  // • Mode Premium : Crypto CoinPayments
  // • Mode Lite    : PIN direct comme avant
  Future<void> _nouveauPret(
    BuildContext context,
    TontineProvider provider,
    dynamic tontine,
    TontineData data,
  ) async {
    final bool isPremium = tontine.isPremium == true;

    final List<Membre> membresOrdre = data.membresActifs;
    if (membresOrdre.isEmpty) {
      afficherToast(context, 'Aucun membre disponible. Rechargez la page.', estErreur: true);
      return;
    }

    String? emprunteurId = membresOrdre.first.id;

    // ── Pré-remplir MM depuis le profil du premier emprunteur ────────────────
    Membre? emprunteurCourant() =>
        membresOrdre.where((m) => m.id == emprunteurId).firstOrNull;
    String? operateur    = emprunteurCourant()?.operateur ?? _operateursPret.first;
    final String numPreRempli = emprunteurCourant()?.numeroBenef ?? '';

    final montantCtrl   = TextEditingController();
    final tauxCtrl      = TextEditingController(text: '5');
    final dureesCtrl    = TextEditingController(text: '3');
    final numBenefCtrl  = TextEditingController(text: numPreRempli);
    final nomBenefCtrl  = TextEditingController(text: emprunteurCourant()?.nom ?? '');
    final referenceCtrl = TextEditingController();
    // Date de la première échéance (pré-remplie à J+30)
    DateTime datePremiereEcheance = DateTime.now().add(const Duration(days: 30));
    // Photo de preuve du prêt
    XFile?  photoFichierPret;
    String? photoBase64Pret;

    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.fondPapier,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) {

          // ── Picker photo prêt ────────────────────────────────────────────
          Future<void> prendrePhotoPret(ImageSource source) async {
            try {
              final picker = ImagePicker();
              final fichier = await picker.pickImage(
                source: source,
                maxWidth: 1200,
                maxHeight: 1200,
                imageQuality: 70,
              );
              if (fichier == null) return;
              final bytes = await fichier.readAsBytes();
              setS(() {
                photoFichierPret = fichier;
                photoBase64Pret  = base64Encode(bytes);
              });
            } catch (e) {
              if (!ctx.mounted) return;
              ScaffoldMessenger.of(ctx).showSnackBar(
                SnackBar(
                  content: Text('Erreur photo : $e'),
                  backgroundColor: Colors.red,
                ),
              );
            }
          }

          void afficherChoixPhotoPret() {
            showModalBottomSheet(
              context: ctx,
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
              ),
              builder: (_) => SafeArea(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ListTile(
                        leading: const Icon(Icons.camera_alt_rounded,
                            color: AppColors.or),
                        title: const Text('Prendre une photo'),
                        onTap: () {
                          Navigator.pop(ctx);
                          prendrePhotoPret(ImageSource.camera);
                        },
                      ),
                      ListTile(
                        leading: const Icon(Icons.photo_library_rounded,
                            color: AppColors.or),
                        title: const Text('Choisir dans la galerie'),
                        onTap: () {
                          Navigator.pop(ctx);
                          prendrePhotoPret(ImageSource.gallery);
                        },
                      ),
                      if (photoBase64Pret != null)
                        ListTile(
                          leading: const Icon(Icons.delete_outline_rounded,
                              color: AppColors.alerte),
                          title: const Text('Supprimer la photo',
                              style: TextStyle(color: AppColors.alerte)),
                          onTap: () {
                            Navigator.pop(ctx);
                            setS(() {
                              photoFichierPret = null;
                              photoBase64Pret  = null;
                            });
                          },
                        ),
                    ],
                  ),
                ),
              ),
            );
          }

          return Padding(
            padding: EdgeInsets.only(
              left: 16, right: 16, top: 16,
              bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(child: Container(
                    width: 40, height: 4,
                    decoration: BoxDecoration(
                      color: AppColors.lignes, borderRadius: BorderRadius.circular(2),
                    ),
                  )),
                  const SizedBox(height: 16),
                  Text(
                    isPremium ? 'Nouveau prêt Pro' : context.tr('nouveau_pret'),
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 20, color: AppColors.encre),
                  ),

                  const SizedBox(height: 16),
                  // Emprunteur
                  ChampLabel(label: context.tr('emprunteur')),
                  DropdownButtonFormField<String>(
                    initialValue: emprunteurId,
                    decoration: const InputDecoration(),
                    isExpanded: true,
                    items: membresOrdre.map((m) => DropdownMenuItem(
                      value: m.id,
                      child: Text(m.nom, overflow: TextOverflow.ellipsis),
                    )).toList(),
                    onChanged: (v) {
                      setS(() {
                        emprunteurId = v;
                        // Mettre à jour automatiquement les champs Mobile Money
                        final m = membresOrdre.where((m) => m.id == v).firstOrNull;
                        if (m != null) {
                          operateur = m.operateur ?? _operateursPret.first;
                          numBenefCtrl.text = m.numeroBenef ?? '';
                          nomBenefCtrl.text = m.nom;
                        }
                      });
                    },
                  ),
                  // Montant
                  ChampLabel(label: 'Montant du prêt (${DeviseService.parCode(data.devise).symbole})'),
                  TextField(
                    controller: montantCtrl,
                    keyboardType: TextInputType.number,
                    autofocus: true,
                    decoration: const InputDecoration(hintText: '50 000'),
                    onChanged: (_) => setS(() {}),
                  ),

                  // Taux + durée
                  Row(
                    children: [
                      Expanded(child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          ChampLabel(label: context.tr('taux_interet')),
                          TextField(
                            controller: tauxCtrl,
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            decoration: const InputDecoration(hintText: '5', suffixText: '%'),
                            onChanged: (_) => setS(() {}),
                          ),
                        ],
                      )),
                      const SizedBox(width: 12),
                      Expanded(child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          ChampLabel(label: context.tr('duree_mois')),
                          TextField(
                            controller: dureesCtrl,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(hintText: '3', suffixText: 'mois'),
                            onChanged: (_) => setS(() {}),
                          ),
                        ],
                      )),
                    ],
                  ),

                  // ── Résumé mensualité (calcul automatique) ──
                  Builder(builder: (ctx2) {
                    final m     = int.tryParse(montantCtrl.text.trim()) ?? 0;
                    final taux2 = double.tryParse(tauxCtrl.text.trim()) ?? 5;
                    final dur   = int.tryParse(dureesCtrl.text.trim()) ?? 3;
                    if (m <= 0 || dur <= 0) return const SizedBox.shrink();
                    final totalDu2   = (m * (1 + taux2 / 100)).round();
                    final mensualite = (totalDu2 / dur).round();
                    return Container(
                      margin: const EdgeInsets.only(top: 12),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        color: AppColors.fondSecondaire,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: AppColors.lignes),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('Mensualité',
                                  style: TextStyle(fontSize: 11, color: AppColors.texteDoux)),
                              Text(
                                Formatters.montant(mensualite, devise: data.devise),
                                style: const TextStyle(
                                  fontSize: 14, fontWeight: FontWeight.w700, color: AppColors.encre),
                              ),
                            ],
                          ),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              const Text('Total dû',
                                  style: TextStyle(fontSize: 11, color: AppColors.texteDoux)),
                              Text(
                                Formatters.montant(totalDu2, devise: data.devise),
                                style: const TextStyle(
                                  fontSize: 14, fontWeight: FontWeight.w700, color: AppColors.encreDoux),
                              ),
                            ],
                          ),
                        ],
                      ),
                    );
                  }),

                  // ── Date de la première échéance ──
                  const SizedBox(height: 12),
                  const ChampLabel(label: 'Date de la 1ère échéance'),
                  InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: () async {
                      final picked = await showDatePicker(
                        context: ctx,
                        initialDate: datePremiereEcheance,
                        firstDate: DateTime.now(),
                        lastDate: DateTime.now().add(const Duration(days: 365 * 3)),
                        locale: const Locale('fr'),
                        helpText: 'Choisir la date de la 1ère échéance',
                        confirmText: 'Confirmer',
                        cancelText: 'Annuler',
                      );
                      if (picked != null) {
                        setS(() => datePremiereEcheance = picked);
                      }
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: AppColors.lignes, width: 1.5),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.event_rounded, size: 18, color: AppColors.encreDoux),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              Formatters.dateFormatee(datePremiereEcheance),
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                color: AppColors.encre,
                              ),
                            ),
                          ),
                          const Icon(Icons.keyboard_arrow_down_rounded,
                              size: 18, color: AppColors.texteDoux),
                        ],
                      ),
                    ),
                  ),

                  // ── Tableau des échéances (calculé automatiquement) ──────────
                  Builder(builder: (ctx3) {
                    final montantV = int.tryParse(montantCtrl.text.trim()) ?? 0;
                    final tauxV    = double.tryParse(tauxCtrl.text.trim()) ?? 5;
                    final durV     = int.tryParse(dureesCtrl.text.trim()) ?? 3;
                    if (montantV <= 0 || durV <= 0) return const SizedBox.shrink();

                    final totalDuV   = (montantV * (1 + tauxV / 100)).round();
                    // Répartition : les (totalDuV % durV) premières échéances
                    // reçoivent 1 FCFA de plus pour absorber l'arrondi entier.
                    final baseV      = totalDuV ~/ durV;
                    final resteV     = totalDuV % durV;

                    return Container(
                      margin: const EdgeInsets.only(top: 14),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppColors.lignes),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // En-tête
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 9),
                            decoration: BoxDecoration(
                              color: AppColors.fondSecondaire,
                              borderRadius: const BorderRadius.vertical(
                                  top: Radius.circular(12)),
                              border: Border(
                                  bottom: BorderSide(color: AppColors.lignes)),
                            ),
                            child: Row(
                              children: const [
                                SizedBox(width: 28),
                                Expanded(
                                  child: Text('Date',
                                      style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w600,
                                          color: AppColors.texteDoux)),
                                ),
                                SizedBox(
                                  width: 90,
                                  child: Text('Montant',
                                      textAlign: TextAlign.right,
                                      style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w600,
                                          color: AppColors.texteDoux)),
                                ),
                              ],
                            ),
                          ),
                          // Lignes
                          ...List.generate(durV, (i) {
                            final dateEch = DateTime(
                              datePremiereEcheance.year,
                              datePremiereEcheance.month + i,
                              datePremiereEcheance.day,
                            );
                            final montantEch = baseV + (i < resteV ? 1 : 0);
                            final estDerniere = i == durV - 1;
                            return Container(
                              decoration: BoxDecoration(
                                border: estDerniere
                                    ? null
                                    : Border(
                                        bottom: BorderSide(
                                            color: AppColors.lignes
                                                .withValues(alpha: 0.5))),
                              ),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 10),
                              child: Row(
                                children: [
                                  // Numéro bulle
                                  Container(
                                    width: 22,
                                    height: 22,
                                    alignment: Alignment.center,
                                    decoration: BoxDecoration(
                                      color: AppColors.or
                                          .withValues(alpha: 0.15),
                                      shape: BoxShape.circle,
                                    ),
                                    child: Text(
                                      '${i + 1}',
                                      style: const TextStyle(
                                          fontSize: 10,
                                          fontWeight: FontWeight.w700,
                                          color: AppColors.or),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  // Date
                                  Expanded(
                                    child: Text(
                                      Formatters.dateFormatee(dateEch),
                                      style: const TextStyle(
                                          fontSize: 13,
                                          color: AppColors.encre),
                                    ),
                                  ),
                                  // Montant
                                  SizedBox(
                                    width: 90,
                                    child: Text(
                                      Formatters.montant(montantEch,
                                          devise: data.devise),
                                      textAlign: TextAlign.right,
                                      style: const TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600,
                                          color: AppColors.encre),
                                    ),
                                  ),
                                ],
                              ),
                            );
                          }),
                          // Pied : total
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 9),
                            decoration: BoxDecoration(
                              color: AppColors.fondSecondaire,
                              borderRadius: const BorderRadius.vertical(
                                  bottom: Radius.circular(12)),
                              border: Border(
                                  top: BorderSide(color: AppColors.lignes)),
                            ),
                            child: Row(
                              children: [
                                const SizedBox(width: 32),
                                const Expanded(
                                  child: Text('Total dû',
                                      style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                          color: AppColors.encre)),
                                ),
                                SizedBox(
                                  width: 90,
                                  child: Text(
                                    Formatters.montant(totalDuV,
                                        devise: data.devise),
                                    textAlign: TextAlign.right,
                                    style: const TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w700,
                                        color: AppColors.or),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    );
                  }),

                  // ── Référence de paiement ────────────────────────────────
                  const SizedBox(height: 16),
                  const ChampLabel(label: 'Référence de paiement'),
                  TextField(
                    controller: referenceCtrl,
                    keyboardType: TextInputType.text,
                    decoration: const InputDecoration(
                      hintText: 'N° transaction, reçu…',
                      prefixIcon: Icon(Icons.receipt_long_outlined,
                          size: 18, color: AppColors.texteDoux),
                    ),
                  ),

                  // ── Photo de preuve ──────────────────────────────────────
                  const SizedBox(height: 12),
                  const ChampLabel(label: 'Photo de preuve'),
                  GestureDetector(
                    onTap: afficherChoixPhotoPret,
                    child: Container(
                      width: double.infinity,
                      constraints: const BoxConstraints(minHeight: 64),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: photoBase64Pret != null
                              ? AppColors.or
                              : AppColors.lignes,
                          width: photoBase64Pret != null ? 1.5 : 1,
                        ),
                      ),
                      child: photoBase64Pret != null && photoFichierPret != null
                          // ── Aperçu photo ─────────────────────────────────
                          ? Stack(
                              children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(9),
                                  child: kIsWeb
                                      ? Image.memory(
                                          base64Decode(photoBase64Pret!),
                                          width: double.infinity,
                                          height: 160,
                                          fit: BoxFit.cover,
                                        )
                                      : Image.file(
                                          File(photoFichierPret!.path),
                                          width: double.infinity,
                                          height: 160,
                                          fit: BoxFit.cover,
                                        ),
                                ),
                                Positioned(
                                  top: 6, right: 6,
                                  child: GestureDetector(
                                    onTap: () => setS(() {
                                      photoFichierPret = null;
                                      photoBase64Pret  = null;
                                    }),
                                    child: Container(
                                      padding: const EdgeInsets.all(4),
                                      decoration: const BoxDecoration(
                                        color: Colors.black54,
                                        shape: BoxShape.circle,
                                      ),
                                      child: const Icon(Icons.close,
                                          size: 14, color: Colors.white),
                                    ),
                                  ),
                                ),
                              ],
                            )
                          // ── Placeholder ──────────────────────────────────
                          : Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 14),
                              child: Row(
                                children: [
                                  const Icon(Icons.add_a_photo_outlined,
                                      size: 22, color: AppColors.texteDoux),
                                  const SizedBox(width: 12),
                                  Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: const [
                                      Text(
                                        'Joindre une photo de preuve',
                                        style: TextStyle(
                                            fontSize: 14,
                                            fontWeight: FontWeight.w500,
                                            color: AppColors.encre),
                                      ),
                                      SizedBox(height: 2),
                                      Text(
                                        'Optionnel — reçu, capture d\'écran…',
                                        style: TextStyle(
                                            fontSize: 11,
                                            color: AppColors.texteDoux),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                    ),
                  ),

                  const SizedBox(height: 16),
                  BtnPrincipal(
                    label: isPremium ? 'Soumettre pour validation' : context.tr('creer_pret'),
                    icone: isPremium ? Icons.send_rounded : null,
                    onTap: () => Navigator.pop(ctx, true),
                  ),
                  const SizedBox(height: 8),
                  BtnSecondaire(label: 'Annuler', onTap: () => Navigator.pop(ctx, false)),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          );
        },
      ),
    );

    if (result != true || !context.mounted) return;

    final montant  = int.tryParse(montantCtrl.text.trim());
    final taux     = double.tryParse(tauxCtrl.text.trim()) ?? 5;
    final durees   = int.tryParse(dureesCtrl.text.trim()) ?? 3;
    final refPret  = referenceCtrl.text.trim();
    // Photo saisie dans le formulaire (utilisée en Lite et transmise si Pro ne jointe rien)
    final photoPret = photoBase64Pret;

    if (montant == null || montant <= 0 || emprunteurId == null) {
      afficherToast(context, 'Données invalides', estErreur: true);
      return;
    }

    final emprunteur    = membresOrdre.where((m) => m.id == emprunteurId).firstOrNull;
    final nomEmprunteur = emprunteur?.nom ?? '—';

    // ── MODE PREMIUM : confirmation manuelle puis enregistrement en DB ──────
    if (isPremium) {
      // Pré-remplir depuis le profil du membre si les champs sont vides
      if (numBenefCtrl.text.trim().isEmpty) {
        numBenefCtrl.text = emprunteur?.numeroBenef ?? '';
      }
      if (nomBenefCtrl.text.trim().isEmpty) {
        nomBenefCtrl.text = emprunteur?.nom ?? '';
      }

      if (montant > data.soldeCaisse) {
        afficherToast(context,
          'Solde insuffisant — caisse : ${Formatters.montant(data.soldeCaisse, devise: data.devise)}',
          estErreur: true);
        return;
      }

      if (!context.mounted) return;

      // Étape 1 : écran de paiement manuel (retourne méthode+référence ou null)
      final paiementResult = await Navigator.push<Map<String, String>>(
        context,
        MaterialPageRoute(
          builder: (_) => PaiementChoixScreen(
            code:        tontine.code,
            typeFlux:    'pret_octroye',
            montant:     montant,
            description: 'Prêt à $nomEmprunteur ($taux% / $durees mois)',
            membreId:    emprunteurId ?? '',
            membreNom:   nomEmprunteur,
            telephone:   numBenefCtrl.text.trim(),
            operateur:   operateur,
            taux:        taux.round(),
            dureesMois:  durees,
          ),
        ),
      );
      // Si l'utilisateur a annulé l'écran de paiement → on s'arrête
      if (paiementResult == null || !context.mounted) return;
      // Récupérer la photo depuis PaiementChoixScreen si non jointe dans le formulaire
      if (photoPret == null && paiementResult['photoPreuveBase64'] != null) {
        photoBase64Pret = paiementResult['photoPreuveBase64'];
      }
      // Sinon on continue vers l'enregistrement en DB (même chemin que LITE ci-dessous)
      // isPremium = false pour tomber dans le bloc LITE
    }

    // ── MODE LITE : PIN direct ──────────────────────────────────────────────
    if (montant > data.soldeCaisse) {
      afficherToast(context,
          'Solde insuffisant — caisse : ${Formatters.montant(data.soldeCaisse, devise: data.devise)}',
          estErreur: true);
      return;
    }

    final totalDuOctroyer = (montant * (1 + taux / 100)).round();

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
        final ref       = Formatters.genererReference();
        final dateDebut = DateTime.now().toIso8601String();
        final interet   = (montant * taux / 100).round();
        final totalDu   = montant + interet;
        final mensualite= (totalDu / durees).round();

        // Écheancier basé sur la date de 1ère échéance choisie par le gestionnaire
        final baseEch = DateTime(datePremiereEcheance.year,
            datePremiereEcheance.month, datePremiereEcheance.day);
        final echeancier = List.generate(durees, (i) {
          final dateEch = DateTime(baseEch.year, baseEch.month + i, baseEch.day);
          return {
            'mois': i + 1, 'date': dateEch.toIso8601String(),
            'montant': i == durees - 1 ? totalDu - mensualite * (durees - 1) : mensualite,
          };
        });

        final newData    = data.toJson();
        final caisseMapO = newData['caisse'];
        final caisse     = List<Map<String, dynamic>>.from(
          caisseMapO is Map<String, dynamic>
              ? ((caisseMapO['mouvements'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ?? [])
              : caisseMapO is List
                  ? caisseMapO.cast<Map<String, dynamic>>()
                  : [],
        );
        caisse.add({
          'id': '${ref}D', 'type': 'depense', 'montant': montant,
          'description': 'Prêt à $nomEmprunteur',
          'gestionnaire': provider.gestActifNom ?? '', 'date': dateDebut, 'reference': ref,
        });
        newData['caisse'] = {'mouvements': caisse};

        final prets = List<Map<String, dynamic>>.from(
          (newData['prets'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ?? [],
        );
        prets.add({
          'id': ref, 'emprunteurId': emprunteur!.id, 'emprunteurNom': emprunteur.nom,
          'montant': montant, 'taux': taux, 'dureesMois': durees,
          'dateDebut': dateDebut, 'statut': 'en_cours', 'remboursements': [],
          'echeancier': echeancier, 'gestionnaire': provider.gestActifNom ?? '', 'reference': ref,
          if (refPret.isNotEmpty)  'reference_paiement': refPret,
          if (photoBase64Pret != null && photoBase64Pret!.isNotEmpty)
            'photo_preuve': photoBase64Pret,
        });
        newData['prets'] = prets;

        final journal = List<Map<String, dynamic>>.from(
          (newData['journal'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ?? [],
        );
        journal.insert(0, {
          'quoi': 'NOUVEAU PRÊT — $nomEmprunteur — ${Formatters.montant(montant, devise: data.devise)} — $taux% — $durees mois',
          'gestionnaire': provider.gestActifNom ?? '', 'quand': dateDebut, 'reference': ref,
        });
        newData['journal'] = journal;
        return provider.ecrire(newData, pin);
      },
    );

    // ── BLOCKCHAIN : prêt octroyé (non-bloquant) ──────────────────────────
    if (ok == true && emprunteur != null) {
      BlockchainService.enregistrerPret(
        tontineCode: widget.code,
        membreId   : emprunteur.id,
        membreNom  : nomEmprunteur,
        montantXof : montant,
        metadata   : {'taux': taux, 'durees_mois': durees},
      ).catchError((e) {
        if (kDebugMode) debugPrint('[Blockchain] pret erreur: $e');
        return BlockchainResultat(ok: false, erreur: '$e', phase: 1);
      });
    }
    // ──────────────────────────────────────────────────────────────────────

    if (ok == true && context.mounted) {
      afficherToast(context, 'Prêt créé avec succès !');
      final lang = Provider.of<LocaleService>(context, listen: false).langue.code;
      final t    = SupabaseService.notifTexte('pret', lang, vars: {
        'nom': nomEmprunteur,
        'montant': Formatters.montant(montant, devise: data.devise),
        'taux': taux.toString(), 'duree': durees.toString(),
      });
      SupabaseService.envoyerNotification(
        code: widget.code, type: 'pret', titre: t['titre']!, message: t['message']!,
      );
    }
  }
}

class _CartePret extends StatelessWidget {
  final Pret pret;
  final bool estGest;
  final TontineData data;
  final TontineProvider provider;
  final bool   isPremium;
  final String tontineCode;

  const _CartePret({
    required this.pret,
    required this.estGest,
    required this.data,
    required this.provider,
    this.isPremium   = false,
    this.tontineCode = '',
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
            isPremium
                ? FilledButton.icon(
                    onPressed: () => _rembourserPro(context),
                    icon: const Icon(Icons.account_balance_wallet_rounded, size: 18),
                    label: const Text(
                      'Enregistrer un remboursement',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF1A6B3C),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                  )
                : BtnSecondaire(
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
    // ── Annulation autorisée ─────────────────────────────────────────────────
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
                  ? caisseMap.cast<Map<String, dynamic>>()
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

    // ── BLOCKCHAIN : annulation remboursement (non-bloquant) ──────────────
    if (ok == true) {
      BlockchainService.enregistrerAnnulationRemboursement(
        tontineCode: provider.courante?.code ?? '',
        membreId   : pret.emprunteurId,
        membreNom  : pret.emprunteurNom,
        montantXof : remb.montant,
        refInterne : remb.reference,
      ).catchError((e) {
        if (kDebugMode) debugPrint('[Blockchain] annulation_remboursement erreur: $e');
        return BlockchainResultat(ok: false, erreur: '$e', phase: 1);
      });
    }
    // ──────────────────────────────────────────────────────────────────────

    if (ok == true && context.mounted) {
      afficherToast(context, 'Remboursement annulé et caisse corrigée.');
      final tontineCode = provider.courante?.code ?? '';
      if (tontineCode.isNotEmpty) {
        final lang = Provider.of<LocaleService>(context, listen: false).langue.code;
        final t = SupabaseService.notifTexte('annulation_remboursement', lang, vars: {
          'montant': Formatters.montant(remb.montant, devise: data.devise),
          'nom': pret.emprunteurNom,
          'ref': remb.reference,
        });
        SupabaseService.envoyerNotification(
          code: tontineCode,
          type: 'annulation_remboursement',
          titre: t['titre']!,
          message: t['message']!,
        );
      }
    }
  }

  // ── Prochaine échéance non réglée ────────────────────────────────────────────
  // Retourne la première tranche de l'écheancier dont la date n'est pas encore
  // passée (ou la dernière si toutes sont passées). null si aucun écheancier.
  static Map<String, dynamic>? _prochaineEcheance(Pret p) {
    if (p.echeancier.isEmpty) return null;
    final now = DateTime.now();
    // Trier par date croissante
    final sorted = [...p.echeancier]..sort((a, b) {
        final da = DateTime.tryParse(a['date'] as String? ?? '') ?? DateTime(0);
        final db = DateTime.tryParse(b['date'] as String? ?? '') ?? DateTime(0);
        return da.compareTo(db);
      });
    // Première tranche future
    final future = sorted.firstWhere(
      (e) {
        final d = DateTime.tryParse(e['date'] as String? ?? '');
        return d != null && d.isAfter(now);
      },
      orElse: () => sorted.last,
    );
    return future;
  }

  // ── Remboursement Pro : modal de saisie ──────────────────────────────────────
  Future<void> _rembourserPro(BuildContext context) async {
    final montantCtrl = TextEditingController(text: pret.resteADu.toString());

    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.fondPapier,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          left: 16, right: 16, top: 16,
          bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(child: Container(
                width: 40, height: 4,
                decoration: BoxDecoration(
                  color: AppColors.lignes, borderRadius: BorderRadius.circular(2),
                ),
              )),
              const SizedBox(height: 16),
              const Text(
                'Remboursement',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 20, color: AppColors.encre),
              ),
              const SizedBox(height: 12),
              // ── Infos emprunteur ──
              Text(
                'Emprunteur : ${pret.emprunteurNom}',
                style: const TextStyle(fontWeight: FontWeight.w600, color: AppColors.encre),
              ),
              const SizedBox(height: 2),
              Text(
                'Reste à rembourser : ${Formatters.montant(pret.resteADu, devise: data.devise)}',
                style: const TextStyle(color: AppColors.texteDoux, fontSize: 13),
              ),
              // ── Prochaine échéance (si écheancier disponible) ──
              Builder(builder: (context) {
                final prochaineEch = _prochaineEcheance(pret);
                if (prochaineEch == null) return const SizedBox.shrink();
                final rawDate = prochaineEch['date'] as String? ?? '';
                final dtEch   = DateTime.tryParse(rawDate);
                final dateStr = dtEch != null ? Formatters.dateFormatee(dtEch) : rawDate;
                final montantEch = prochaineEch['montant'] as int? ?? 0;
                return Container(
                  margin: const EdgeInsets.only(top: 10),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFF3E0),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFFE07A2F).withValues(alpha: 0.35)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.event_rounded, size: 14, color: Color(0xFFE07A2F)),
                      const SizedBox(width: 7),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Prochaine échéance',
                              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFFE07A2F)),
                            ),
                            Text(
                              '${Formatters.montant(montantEch, devise: data.devise)} · Date limite : $dateStr',
                              style: const TextStyle(fontSize: 12, color: AppColors.encre, fontWeight: FontWeight.w500),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              }),
              const SizedBox(height: 12),
              ChampLabel(label: 'Montant à rembourser (${DeviseService.parCode(data.devise).symbole})'),
              TextField(
                controller: montantCtrl,
                keyboardType: TextInputType.number,
                autofocus: true,
                decoration: InputDecoration(hintText: pret.resteADu.toString()),
              ),
              const SizedBox(height: 16),
              BtnPrincipal(
                label: 'Continuer',
                onTap: () => Navigator.pop(ctx, true),
              ),
              const SizedBox(height: 8),
              BtnSecondaire(label: 'Annuler', onTap: () => Navigator.pop(ctx, false)),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );

    if (confirmed != true || !context.mounted) return;

    final montant = int.tryParse(montantCtrl.text.trim());
    if (montant == null || montant <= 0) {
      afficherToast(context, 'Montant invalide', estErreur: true); return;
    }
    if (montant > pret.resteADu) {
      afficherToast(context, 'Montant supérieur au reste dû', estErreur: true); return;
    }
    if (!context.mounted) return;

    // Étape 2 : écran de paiement manuel (retourne méthode+référence ou null)
    final paiementResult = await Navigator.push<Map<String, String>>(
      context,
      MaterialPageRoute(
        builder: (_) => PaiementChoixScreen(
          code:        tontineCode,
          typeFlux:    'remboursement_pret',
          montant:     montant,
          description: 'Remboursement prêt ${pret.emprunteurNom}',
          membreId:    pret.emprunteurId,
          membreNom:   pret.emprunteurNom,
          pretId:      pret.id,
        ),
      ),
    );
    if (paiementResult == null || !context.mounted) return;

    // Étape 3 : enregistrement en DB avec PIN — on réutilise _rembourser en
    // passant montant, méthode et photo déjà saisis (skip le bottom-sheet de saisie).
    await _rembourser(
      context,
      montantPre: montant,
      methodePre: paiementResult['methode'] ?? 'especes',
      photoPre:   paiementResult['photoPreuveBase64'],
    );
  }

  Future<void> _rembourser(
    BuildContext context, {
    int? montantPre,        // si fourni par _rembourserPro → skip saisie
    String? methodePre,     // méthode déjà choisie dans PaiementChoixScreen
    String? photoPre,       // photo preuve déjà choisie dans PaiementChoixScreen
  }) async {
    final montantCtrl = TextEditingController(
      text: montantPre != null ? montantPre.toString() : '',
    );
    // Si montantPre fourni (vient de _rembourserPro via PaiementChoixScreen),
    // on skip le bottom-sheet de saisie et on utilise les valeurs pré-remplies.
    String methode = methodePre ?? 'especes';
    // Photo de preuve : initialisée depuis photoPre (chemin Pro) ou vide (Lite)
    XFile?  photoFichier;
    String? photoBase64 = photoPre;

    bool result;
    if (montantPre != null) {
      // Chemin Premium : saisie déjà effectuée dans PaiementChoixScreen
      result = true;
    } else {
      // Chemin Lite : bottom-sheet de saisie avec champ photo
      result = await showModalBottomSheet<bool>(
        context: context,
        isScrollControlled: true,
        backgroundColor: AppColors.fondPapier,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setS) {
            // ── Picker photo (local à ce builder) ──────────────────────────
            Future<void> prendrePhoto(ImageSource source) async {
              try {
                final picker = ImagePicker();
                final fichier = await picker.pickImage(
                  source: source,
                  maxWidth: 1200,
                  maxHeight: 1200,
                  imageQuality: 70,
                );
                if (fichier == null) return;
                final bytes = await fichier.readAsBytes();
                setS(() {
                  photoFichier = fichier;
                  photoBase64  = base64Encode(bytes);
                });
              } catch (e) {
                if (!ctx.mounted) return;
                ScaffoldMessenger.of(ctx).showSnackBar(
                  SnackBar(
                    content: Text('Erreur photo : $e'),
                    backgroundColor: Colors.red,
                  ),
                );
              }
            }

            void afficherChoixPhoto() {
              showModalBottomSheet(
                context: ctx,
                shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
                ),
                builder: (_) => SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ListTile(
                          leading: const Icon(Icons.camera_alt_rounded,
                              color: AppColors.or),
                          title: const Text('Prendre une photo'),
                          onTap: () {
                            Navigator.pop(ctx);
                            prendrePhoto(ImageSource.camera);
                          },
                        ),
                        ListTile(
                          leading: const Icon(Icons.photo_library_rounded,
                              color: AppColors.or),
                          title: const Text('Choisir dans la galerie'),
                          onTap: () {
                            Navigator.pop(ctx);
                            prendrePhoto(ImageSource.gallery);
                          },
                        ),
                        if (photoBase64 != null)
                          ListTile(
                            leading: const Icon(Icons.delete_outline_rounded,
                                color: AppColors.alerte),
                            title: const Text('Supprimer la photo',
                                style: TextStyle(color: AppColors.alerte)),
                            onTap: () {
                              Navigator.pop(ctx);
                              setS(() {
                                photoFichier = null;
                                photoBase64  = null;
                              });
                            },
                          ),
                      ],
                    ),
                  ),
                ),
              );
            }

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
                  initialValue: methode,
                  decoration: const InputDecoration(),
                  items: ['especes', 'orange', 'mtn', 'moov', 'wave']
                      .map((m) => DropdownMenuItem(
                            value: m,
                            child: Text(Formatters.methodePaiement(m)),
                          ))
                      .toList(),
                  onChanged: (v) => setS(() => methode = v!),
                ),
                // ── Photo de preuve ──────────────────────────────────────────
                const SizedBox(height: 12),
                GestureDetector(
                  onTap: afficherChoixPhoto,
                  child: Container(
                    width: double.infinity,
                    constraints: const BoxConstraints(minHeight: 64),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: photoBase64 != null
                            ? AppColors.or
                            : AppColors.lignes,
                        width: photoBase64 != null ? 1.5 : 1,
                      ),
                    ),
                    child: photoBase64 != null && photoFichier != null
                        // ── Aperçu photo ──────────────────────────────────
                        ? Stack(
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(9),
                                child: kIsWeb
                                    ? Image.memory(
                                        base64Decode(photoBase64!),
                                        width: double.infinity,
                                        height: 160,
                                        fit: BoxFit.cover,
                                      )
                                    : Image.file(
                                        File(photoFichier!.path),
                                        width: double.infinity,
                                        height: 160,
                                        fit: BoxFit.cover,
                                      ),
                              ),
                              Positioned(
                                top: 6, right: 6,
                                child: GestureDetector(
                                  onTap: () => setS(() {
                                    photoFichier = null;
                                    photoBase64  = null;
                                  }),
                                  child: Container(
                                    padding: const EdgeInsets.all(4),
                                    decoration: const BoxDecoration(
                                      color: Colors.black54,
                                      shape: BoxShape.circle,
                                    ),
                                    child: const Icon(Icons.close,
                                        size: 14, color: Colors.white),
                                  ),
                                ),
                              ),
                            ],
                          )
                        // ── Placeholder ───────────────────────────────────
                        : Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 14),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.add_a_photo_outlined,
                                  size: 22,
                                  color: photoBase64 != null
                                      ? AppColors.or
                                      : AppColors.texteDoux,
                                ),
                                const SizedBox(width: 12),
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: const [
                                    Text(
                                      'Joindre une photo de preuve',
                                      style: TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w500,
                                          color: AppColors.encre),
                                    ),
                                    SizedBox(height: 2),
                                    Text(
                                      'Optionnel — reçu, capture d\'écran…',
                                      style: TextStyle(
                                          fontSize: 11,
                                          color: AppColors.texteDoux),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                  ),
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
          );
          },
        ),
      ) ?? false;
    }

    if (result != true || !context.mounted) return;

    final montant = montantPre ?? int.tryParse(montantCtrl.text.trim());
    if (montant == null || montant <= 0) {
      afficherToast(context, 'Montant invalide', estErreur: true);
      return;
    }

    bool pretSolde = false;
    String refRemboursement = '';

    final resteAvant = pret.resteADu;
    final resteApres = (resteAvant - montant).clamp(0, resteAvant);

    String refRembCapture = '';
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
        refRembCapture = ref;
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
                  ? caisseMap.cast<Map<String, dynamic>>()
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
            if (photoBase64 != null && photoBase64!.isNotEmpty)
              'photo_preuve': photoBase64,
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

    // ── BLOCKCHAIN : remboursement (non-bloquant) ──────────────────────────
    if (ok == true) {
      BlockchainService.enregistrerRemboursement(
        tontineCode: provider.courante?.code ?? '',
        membreId   : pret.emprunteurId,
        membreNom  : pret.emprunteurNom,
        montantXof : montant,
        refInterne : refRembCapture,
      ).catchError((e) {
        if (kDebugMode) debugPrint('[Blockchain] remboursement erreur: $e');
        return BlockchainResultat(ok: false, erreur: '$e', phase: 1);
      });
    }
    // ──────────────────────────────────────────────────────────────────────

    if (ok == true && context.mounted) {
      afficherToast(
        context,
        pretSolde
            ? '✅ Prêt soldé intégralement !'
            : 'Remboursement enregistré !',
      );
      final tontineCode = provider.courante?.code ?? '';
      if (tontineCode.isNotEmpty) {
        final lang2 = Provider.of<LocaleService>(context, listen: false).langue.code;
        final typeNotif2 = pretSolde ? 'pret_solde' : 'remboursement';
        final t2 = SupabaseService.notifTexte(typeNotif2, lang2, vars: {
          'nom': pret.emprunteurNom,
          'montant': pretSolde
              ? Formatters.montant(pret.totalDu, devise: data.devise)
              : Formatters.montant(montant, devise: data.devise),
          'reste': Formatters.montant(resteApres, devise: data.devise),
        });
        SupabaseService.envoyerNotification(
          code: tontineCode,
          type: typeNotif2,
          titre: t2['titre']!,
          message: t2['message']!,
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

// ─── Section des prêts en attente de validation (côté utilisateur) ────────────
class _SectionPending extends StatelessWidget {
  final List<Map<String, dynamic>> pretsPending;

  const _SectionPending({required this.pretsPending});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: AppColors.orFonce.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.hourglass_top_rounded, size: 14, color: AppColors.orFonce),
                  const SizedBox(width: 6),
                  Text(
                    'En attente de validation (${pretsPending.length})',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: AppColors.orFonce,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        ...pretsPending.map((p) => _CartePretPending(p)),
      ],
    );
  }
}

class _CartePretPending extends StatelessWidget {
  final Map<String, dynamic> p;
  const _CartePretPending(this.p);

  @override
  Widget build(BuildContext context) {
    final emprunteur = p['emprunteur_nom'] as String? ?? '—';
    final montant    = (p['montant'] as num?)?.toInt() ?? 0;
    final taux       = p['taux'];
    final durees     = (p['durees_mois'] as num?)?.toInt() ?? 0;
    final ref        = p['reference'] as String? ?? '—';
    final statut     = p['statut'] as String? ?? 'pending';
    final devise     = p['devise'] as String? ?? 'XOF';
    final createdAt  = DateTime.tryParse(p['created_at'] as String? ?? '');

    final Color couleurStatut;
    final String labelStatut;
    final IconData iconeStatut;
    switch (statut) {
      case 'validee':
        couleurStatut = AppColors.succes;
        labelStatut   = 'Validé ✓';
        iconeStatut   = Icons.check_circle_outline;
        break;
      case 'rejetee':
        couleurStatut = AppColors.alerte;
        labelStatut   = 'Rejeté ✗';
        iconeStatut   = Icons.cancel_outlined;
        break;
      default:
        couleurStatut = AppColors.orFonce;
        labelStatut   = '⏳ En attente';
        iconeStatut   = Icons.hourglass_top_rounded;
    }

    return CarteTC(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  emprunteur.toUpperCase(),
                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15, color: AppColors.encre),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: couleurStatut.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(iconeStatut, size: 13, color: couleurStatut),
                    const SizedBox(width: 4),
                    Text(labelStatut, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: couleurStatut)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Taux ${taux ?? 0}% · $durees mois · Réf. $ref',
            style: const TextStyle(fontSize: 12, color: AppColors.texteDoux),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Montant demandé', style: TextStyle(fontSize: 11, color: AppColors.texteDoux)),
                    Text(
                      Formatters.montant(montant, devise: devise),
                      style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15, color: AppColors.encre),
                    ),
                  ],
                ),
              ),
              if (createdAt != null)
                Text(
                  'Soumis le ${createdAt.day.toString().padLeft(2, '0')}/${createdAt.month.toString().padLeft(2, '0')}/${createdAt.year}',
                  style: const TextStyle(fontSize: 11, color: AppColors.texteDoux),
                ),
            ],
          ),
          if (statut == 'pending') ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.orFonce.withValues(alpha: 0.07),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                '⏳ Demande soumise — en attente de validation par TontineClair.\nNe relancez pas une nouvelle demande.',
                style: TextStyle(fontSize: 12, color: AppColors.orFonce, height: 1.4),
              ),
            ),
          ],
          if (statut == 'rejetee') ...[
            const SizedBox(height: 8),
            if ((p['motif_rejet'] as String?) != null && (p['motif_rejet'] as String).isNotEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.alerte.withValues(alpha: 0.07),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  'Motif : ${p['motif_rejet']}',
                  style: const TextStyle(fontSize: 12, color: AppColors.alerte, height: 1.4),
                ),
              ),
          ],
        ],
      ),
    );
  }
}
