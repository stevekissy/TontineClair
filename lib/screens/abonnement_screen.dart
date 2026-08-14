import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/tontine.dart';
import '../services/tontine_provider.dart';
import '../services/supabase_service.dart';
import '../services/platform_service.dart';
import '../services/subscription_service.dart';
import '../utils/app_colors.dart';
import '../utils/formatters.dart';
import '../widgets/app_widgets.dart';
import 'creation_screen.dart';
import 'dart:async';

// ─────────────────────────────────────────────────────────────────────────────
// ÉCRAN ABONNEMENT — détection automatique de la plateforme
//
// WEB    → formulaire de contact + demande manuelle
// ANDROID → message Google Play Billing (in-app purchase)
// iOS    → message Apple In-App Purchase (StoreKit)
// ─────────────────────────────────────────────────────────────────────────────

class AbonnementScreen extends StatefulWidget {
  final String code;
  /// Forcer la plateforme (utilisé depuis création sans tontine chargée)
  final PlatformType? platformeForce;
  /// Montant de la cagnotte — pour détecter si le KYC est obligatoire
  final int montantCagnotte;
  /// Statut KYC du gestionnaire
  final String? kycStatut;
  /// Nom du gestionnaire (pour le formulaire KYC)
  final String gestNom;
  /// true = tontine créée en mode Gratuit → ne peut PAS passer Premium.
  /// Affiche uniquement les avantages + message "créez une nouvelle tontine Premium".
  final bool estTontineGratuite;

  const AbonnementScreen({
    super.key,
    required this.code,
    this.platformeForce,
    this.montantCagnotte = 0,
    this.kycStatut,
    this.gestNom = '',
    this.estTontineGratuite = false,
  });

  @override
  State<AbonnementScreen> createState() => _AbonnementScreenState();
}

class _AbonnementScreenState extends State<AbonnementScreen> {
  bool _demandeEnvoyee = false;
  String _formule = 'mensuel';
  bool _checkboxLu = false;
  String? _kycStatut;

  static const _couleurPremium = Color(0xFFF59E0B);

  PlatformType get _platform =>
      widget.platformeForce ?? PlatformService.current;

  bool get _kycRequis    => widget.montantCagnotte >= TontineData.kSeuilKyc;
  bool get _kycValide    => _kycStatut == 'valide';
  bool get _kycPending   => _kycStatut == 'pending';
  bool get _kycBloquant  => _kycRequis && !_kycValide;
  bool get _peutProceder => _checkboxLu && !_kycBloquant;

  @override
  void initState() {
    super.initState();
    _kycStatut = widget.kycStatut;
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<TontineProvider>();
    final tontine  = provider.courante;

    // Statut Premium — depuis SubscriptionService (source unique)
    final isPremium = tontine?.isPremium ?? SubscriptionService.isPremium;

    // ── Cas : tontine créée en Gratuit → upgrade impossible ──────────────
    if (widget.estTontineGratuite) {
      return _EcranTontineGratuite(code: widget.code);
    }

    return Scaffold(
      backgroundColor: AppColors.fondPapier,
      body: SafeArea(
        child: Stack(
          children: [
            SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 120),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── En-tête ──────────────────────────────────────────────────
                  Row(
                    children: [
                      const LogoTontineClair(),
                      const Spacer(),
                      TextButton.icon(
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.arrow_back, size: 16),
                        label: const Text('Retour'),
                        style: TextButton.styleFrom(
                            foregroundColor: AppColors.encre),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),

                  // ── Titre + sous-titre ────────────────────────────────────────
                  Row(
                    children: [
                      Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: _couleurPremium.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: const Center(
                          child: Text('⭐', style: TextStyle(fontSize: 24)),
                        ),
                      ),
                      const SizedBox(width: 14),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Abonnement',
                              style: TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 26,
                                color: AppColors.encre,
                                letterSpacing: -0.5,
                              ),
                            ),
                            Text(
                              'Débloquez toutes les fonctionnalités',
                              style: TextStyle(
                                fontSize: 13.5,
                                color: AppColors.texteDoux,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),

                  // ── Statut actuel (si déjà Premium) ──────────────────────────
                  if (isPremium && tontine != null)
                    _BandeauPremiumActif(tontine: tontine)
                  else if (isPremium)
                    _BandeauPremiumActifSimple(),

                  if (isPremium) const SizedBox(height: 24),

                  // ── Tableau comparatif amélioré ───────────────────────────────
                  _TableauComparatif(),
                  const SizedBox(height: 20),

                  // ══════════════════════════════════════════════════════════════
                  // Tout ce qui suit n'est visible que si NON Premium
                  // ══════════════════════════════════════════════════════════════
                  if (!isPremium) ...[

                    // ── Sélection formule ─────────────────────────────────────
                    _SectionTitre(
                      titre: 'Choisissez votre formule',
                      icone: Icons.workspace_premium,
                    ),
                    const SizedBox(height: 12),
                    Row(children: [
                      Expanded(
                        child: _CarteTarif(
                          label: 'Mensuel',
                          prix: '2 500 FCFA / mois',
                          description: 'Flexible, sans engagement',
                          badge: null,
                          selected: _formule == 'mensuel',
                          onTap: () => setState(() => _formule = 'mensuel'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _CarteTarif(
                          label: 'Annuel',
                          prix: '25 000 FCFA / an',
                          description: '2 mois offerts vs mensuel',
                          badge: '−17%',
                          selected: _formule == 'annuel',
                          onTap: () => setState(() => _formule = 'annuel'),
                        ),
                      ),
                    ]),
                    const SizedBox(height: 24),

                    // ── Carte jaune : Action irréversible ─────────────────────
                    _CarteIrreversible(),
                    const SizedBox(height: 16),

                    // ── Carte rouge KYC (si cagnotte >= 200 000 XOF) ─────────
                    if (_kycRequis && !_kycValide) ...[
                      _CarteKycObligatoire(
                        kycStatut:       _kycStatut,
                        montantCagnotte: widget.montantCagnotte,
                        gestNom:         widget.gestNom,
                        code:            widget.code,
                        onSoumis:        () => setState(() => _kycStatut = 'pending'),
                      ),
                      const SizedBox(height: 16),
                    ],

                    // ── KYC validé : bandeau succès ───────────────────────────
                    if (_kycValide) ...[
                      _BandeauKycValide(),
                      const SizedBox(height: 16),
                    ],

                    // ── Checkbox confirmation ─────────────────────────────────
                    if (!_kycBloquant) ...[
                      _CheckboxConfirmation(
                        valeur:   _checkboxLu,
                        onChange: (v) => setState(() => _checkboxLu = v),
                      ),
                      const SizedBox(height: 20),
                    ],

                    // ── Message KYC bloquant ──────────────────────────────────
                    if (_kycBloquant) ...[
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFEF2F2),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFFFCA5A5)),
                        ),
                        child: const Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('🔒', style: TextStyle(fontSize: 16)),
                            SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                'Soumettez votre KYC avant de continuer.\n'
                                'Impossible de payer tant que le KYC n\'est pas validé.',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: Color(0xFF991B1B),
                                  fontWeight: FontWeight.w600,
                                  height: 1.4,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 20),
                    ],

                    // ── KYC pending ───────────────────────────────────────────
                    if (_kycPending && !_kycValide && !_kycBloquant) ...[
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFFBEB),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFFFDE68A)),
                        ),
                        child: const Row(
                          children: [
                            Text('⏳', style: TextStyle(fontSize: 16)),
                            SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                'KYC soumis — en attente de validation TontineClair. Vous pourrez continuer après validation.',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: Color(0xFF92400E),
                                  height: 1.4,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 20),
                    ],
                  ],

                  const SizedBox(height: 32),
                  _buildNotesLegales(),
                ],
              ),
            ),

            // ── Bouton bas fixe (uniquement si NON Premium) ───────────────────
            if (!isPremium)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [
                        AppColors.fondPapier,
                        AppColors.fondPapier.withValues(alpha: 0),
                      ],
                    ),
                  ),
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 18),
                  child: _buildCtaPlateforme(context, tontine),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ─── CTA selon plateforme ────────────────────────────────────────────────

  Widget _buildCtaPlateforme(BuildContext context, dynamic tontine) {
    switch (_platform) {
      case PlatformType.android:
        return _SectionAndroid(
          formule:       _formule,
          peutProceder:  _peutProceder,
          kycBloquant:   _kycBloquant,
          kycPending:    _kycPending && !_kycValide,
        );
      case PlatformType.ios:
        return _SectionIOS(
          formule:      _formule,
          peutProceder: _peutProceder,
          kycBloquant:  _kycBloquant,
        );
      case PlatformType.web:
        return _SectionWeb(
          formule: _formule,
          code: widget.code.isNotEmpty
              ? widget.code
              : tontine?.code ?? '',
          loading: false,
          demandeEnvoyee: _demandeEnvoyee,
          onDemander: _demanderPremium,
        );
    }
  }

  Future<void> _demanderPremium() async {
    final code = widget.code.isNotEmpty
        ? widget.code
        : (context.read<TontineProvider>().courante?.code ?? '');

    if (code.isEmpty) {
      afficherToast(context, 'Code de tontine manquant.', estErreur: true);
      return;
    }

    await _afficherFormulaireDemandeWeb(code);
  }

  Future<void> _afficherFormulaireDemandeWeb(String code) async {
    final nomCtrl     = TextEditingController();
    final contactCtrl = TextEditingController();
    String? erreur;
    bool loading = false;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.fondPapier,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => StatefulBuilder(
        builder: (sCtx, setSt) => Padding(
          padding: EdgeInsets.only(
            left: 20, right: 20, top: 20,
            bottom: MediaQuery.of(sCtx).viewInsets.bottom + 28,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40, height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.lignes,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                '⭐ Demande d\'activation Premium',
                style: GoogleFonts.bricolageGrotesque(
                  fontWeight: FontWeight.w700, fontSize: 18, color: AppColors.encre,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Formule : ${_formule == "annuel" ? "Annuel — 25 000 FCFA/an" : "Mensuel — 2 500 FCFA/mois"}\n'
                'Code tontine : $code',
                style: GoogleFonts.inter(fontSize: 13, color: AppColors.texteDoux),
              ),
              const SizedBox(height: 18),
              Text('Votre nom', style: GoogleFonts.inter(fontWeight: FontWeight.w600, fontSize: 13.5, color: AppColors.encre)),
              const SizedBox(height: 6),
              TextField(
                controller: nomCtrl,
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(
                  hintText: 'Prénom et nom',
                  filled: true, fillColor: Colors.white,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.lignes, width: 1.5)),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.lignes, width: 1.5)),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.encre, width: 1.5)),
                ),
                onChanged: (_) { if (erreur != null) setSt(() => erreur = null); },
              ),
              const SizedBox(height: 14),
              Text('WhatsApp ou Email', style: GoogleFonts.inter(fontWeight: FontWeight.w600, fontSize: 13.5, color: AppColors.encre)),
              const SizedBox(height: 6),
              TextField(
                controller: contactCtrl,
                keyboardType: TextInputType.emailAddress,
                decoration: InputDecoration(
                  hintText: '+225 07 00 00 00 00 ou email@exemple.com',
                  filled: true, fillColor: Colors.white,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.lignes, width: 1.5)),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.lignes, width: 1.5)),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.encre, width: 1.5)),
                ),
                onChanged: (_) { if (erreur != null) setSt(() => erreur = null); },
              ),
              if (erreur != null) ...[
                const SizedBox(height: 8),
                Text(erreur!, style: const TextStyle(color: AppColors.alerte, fontSize: 13)),
              ],
              const SizedBox(height: 20),
              if (loading)
                const Center(child: CircularProgressIndicator())
              else
                BtnPrincipal(
                  label: 'Envoyer ma demande',
                  icone: Icons.workspace_premium,
                  couleur: AppColors.orFonce,
                  onTap: () async {
                    if (nomCtrl.text.trim().length < 2) {
                      setSt(() => erreur = 'Entrez votre nom complet.');
                      return;
                    }
                    if (contactCtrl.text.trim().length < 6) {
                      setSt(() => erreur = 'Entrez votre WhatsApp ou email.');
                      return;
                    }
                    setSt(() { loading = true; erreur = null; });
                    try {
                      await SupabaseService.demanderPremium(
                        code: code,
                        nom: nomCtrl.text.trim(),
                        pin: '0000',
                        contact: contactCtrl.text.trim(),
                        formule: _formule,
                      );
                      if (sCtx.mounted) Navigator.of(sCtx).pop();
                      if (mounted) {
                        setState(() => _demandeEnvoyee = true);
                        afficherToast(context,
                          '✅ Demande envoyée ! TontineClair vous contactera sous 24h.');
                      }
                    } catch (e) {
                      setSt(() { loading = false; erreur = 'Erreur : $e'; });
                    }
                  },
                ),
              const SizedBox(height: 8),
              BtnSecondaire(label: 'Annuler', onTap: () => Navigator.of(sheetCtx).pop()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNotesLegales() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(color: AppColors.lignes),
        const SizedBox(height: 12),
        Text(
          'Informations légales',
          style: GoogleFonts.inter(
            fontWeight: FontWeight.w700,
            fontSize: 13,
            color: AppColors.encre,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '• L\'abonnement se renouvelle automatiquement sauf annulation avant la fin de la période.\n'
          '• Les données de votre compte sont conservées après expiration.\n'
          '• Aucune fonctionnalité n\'est supprimée — seule la création est bloquée après expiration.\n'
          '• Contactez support@tontineclair.com pour toute question.',
          style: GoogleFonts.inter(
            fontSize: 12,
            color: AppColors.texteDoux,
            height: 1.6,
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// CARTE JAUNE — Action irréversible
// ─────────────────────────────────────────────────────────────────────────────

class _CarteIrreversible extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFFFFBEB),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFF59E0B).withValues(alpha: 0.5), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFFF59E0B).withValues(alpha: 0.08),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: const Color(0xFFF59E0B).withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Center(
              child: Text('⚠️', style: TextStyle(fontSize: 18)),
            ),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Action irréversible',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 14.5,
                    color: Color(0xFF78350F),
                  ),
                ),
                SizedBox(height: 6),
                Text(
                  'Une fois cette tontine passée en Premium, elle ne pourra plus revenir à la formule Gratuite.',
                  style: TextStyle(
                    fontSize: 13,
                    color: Color(0xFF92400E),
                    height: 1.5,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  "L'abonnement sera géré automatiquement par Google Play (Android) ou Apple App Store (iPhone).",
                  style: TextStyle(
                    fontSize: 13,
                    color: Color(0xFF92400E),
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// CARTE ROUGE — KYC obligatoire (cagnotte >= 200 000 XOF)
// ─────────────────────────────────────────────────────────────────────────────

class _CarteKycObligatoire extends StatelessWidget {
  final String? kycStatut;
  final int     montantCagnotte;
  final String  gestNom;
  final String  code;
  final VoidCallback onSoumis;

  const _CarteKycObligatoire({
    required this.kycStatut,
    required this.montantCagnotte,
    required this.gestNom,
    required this.code,
    required this.onSoumis,
  });

  @override
  Widget build(BuildContext context) {
    final isPending = kycStatut == 'pending';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFFEF2F2),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFEF4444).withValues(alpha: 0.4), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFFEF4444).withValues(alpha: 0.07),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: const Color(0xFFEF4444).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Center(
                  child: Text('🚨', style: TextStyle(fontSize: 18)),
                ),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'KYC obligatoire',
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 14.5,
                        color: Color(0xFF991B1B),
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      'Cette cagnotte dépasse 200 000 XOF.',
                      style: TextStyle(
                        fontSize: 13,
                        color: Color(0xFFB91C1C),
                        height: 1.4,
                      ),
                    ),
                    Text(
                      'Une vérification d\'identité est obligatoire avant de pouvoir activer Premium.',
                      style: TextStyle(
                        fontSize: 13,
                        color: Color(0xFFB91C1C),
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (!isPending) ...[
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () => _ouvrirKyc(context),
                icon: const Icon(Icons.description_outlined, size: 16),
                label: const Text(
                  'Soumettre le KYC',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFEF4444),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  elevation: 0,
                ),
              ),
            ),
          ],
          if (isPending) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFFFFFBEB),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Row(
                children: [
                  Text('⏳', style: TextStyle(fontSize: 14)),
                  SizedBox(width: 8),
                  Text(
                    'KYC soumis — en attente de validation',
                    style: TextStyle(
                      fontSize: 12.5,
                      color: Color(0xFF92400E),
                      fontWeight: FontWeight.w600,
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

  void _ouvrirKyc(BuildContext context) async {
    final soumis = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ModaleKyc(code: code, gestNom: gestNom),
    );
    if (soumis == true) onSoumis();
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// BANDEAU KYC VALIDÉ
// ─────────────────────────────────────────────────────────────────────────────

class _BandeauKycValide extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.succesFond,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.succes.withValues(alpha: 0.4)),
      ),
      child: const Row(
        children: [
          Icon(Icons.verified_user, color: AppColors.succes, size: 22),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              'Identité vérifiée — vous pouvez procéder au paiement.',
              style: TextStyle(
                fontSize: 13.5,
                color: AppColors.succes,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// CHECKBOX CONFIRMATION
// ─────────────────────────────────────────────────────────────────────────────

class _CheckboxConfirmation extends StatelessWidget {
  final bool valeur;
  final ValueChanged<bool> onChange;

  const _CheckboxConfirmation({required this.valeur, required this.onChange});

  static const _couleurPremium = Color(0xFFF59E0B);

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => onChange(!valeur),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: valeur
              ? _couleurPremium.withValues(alpha: 0.06)
              : AppColors.carte,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: valeur ? _couleurPremium : AppColors.lignes,
            width: valeur ? 1.5 : 1,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                color: valeur ? _couleurPremium : Colors.transparent,
                border: Border.all(
                  color: valeur ? _couleurPremium : AppColors.lignes,
                  width: 2,
                ),
                borderRadius: BorderRadius.circular(6),
              ),
              child: valeur
                  ? const Icon(Icons.check, size: 14, color: Colors.white)
                  : null,
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Text(
                'J\'ai compris que le passage en Premium est définitif et irréversible.',
                style: TextStyle(
                  fontSize: 13.5,
                  color: AppColors.encre,
                  height: 1.4,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SECTION WEB — formulaire de demande manuelle
// Visible UNIQUEMENT sur plateforme web
// ─────────────────────────────────────────────────────────────────────────────

class _SectionWeb extends StatelessWidget {
  final String formule;
  final String code;
  final bool loading;
  final bool demandeEnvoyee;
  final VoidCallback onDemander;

  const _SectionWeb({
    required this.formule,
    required this.code,
    required this.loading,
    required this.demandeEnvoyee,
    required this.onDemander,
  });

  @override
  Widget build(BuildContext context) {
    if (demandeEnvoyee) {
      return _CarteSucces();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CarteTC(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.language,
                      size: 18, color: AppColors.encreDoux),
                  const SizedBox(width: 8),
                  Text(
                    'Activation Premium Web',
                    style: GoogleFonts.inter(
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                      color: AppColors.encre,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                'Sélectionnez la formule puis cliquez sur "Demander l\'activation". '
                'Notre équipe vous contactera pour finaliser le paiement.',
                style: GoogleFonts.inter(
                  fontSize: 13.5,
                  color: AppColors.texteDoux,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 16),
              BtnPrincipal(
                label: 'Demander l\'activation Premium',
                icone: Icons.workspace_premium,
                couleur: AppColors.orFonce,
                loading: loading,
                onTap: onDemander,
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: () => _ouvrirWhatsApp(context, formule),
                icon: const Icon(Icons.chat, size: 16),
                label: const Text('Contacter sur WhatsApp'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.succes,
                  side: const BorderSide(color: AppColors.succes),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  void _ouvrirWhatsApp(BuildContext ctx, String f) {
    final montant = f == 'annuel' ? '25 000 FCFA/an' : '2 500 FCFA/mois';
    final msg = Uri.encodeComponent(
      'Bonjour, je souhaite activer Premium TontineClair ($montant) pour la tontine $code.',
    );
    final url = Uri.parse('https://wa.me/22502432176?text=$msg');
    launchUrl(url, mode: LaunchMode.externalApplication).catchError((_) => false);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SECTION ANDROID — Google Play Billing
// ─────────────────────────────────────────────────────────────────────────────

// ─────────────────────────────────────────────────────────────────────────────
// SECTION ANDROID — Google Play Billing (in_app_purchase)
// Flux réel : InAppPurchase.buyNonConsumable → purchaseStream → activation
// ─────────────────────────────────────────────────────────────────────────────
class _SectionAndroid extends StatefulWidget {
  final String formule;
  final bool   peutProceder;
  final bool   kycBloquant;
  final bool   kycPending;

  const _SectionAndroid({
    required this.formule,
    required this.peutProceder,
    required this.kycBloquant,
    required this.kycPending,
  });

  @override
  State<_SectionAndroid> createState() => _SectionAndroidState();
}

class _SectionAndroidState extends State<_SectionAndroid> {
  bool _achatlEnCours = false;
  StreamSubscription<AchatResult>? _sub;

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _lancerAchat() async {
    if (_achatlEnCours) return;
    setState(() => _achatlEnCours = true);

    final productId = widget.formule == 'annuel'
        ? SubscriptionProductIds.annuel
        : SubscriptionProductIds.mensuel;

    final result = await SubscriptionService.acheter(productId);

    if (!mounted) return;
    setState(() => _achatlEnCours = false);

    if (result.estSucces) {
      afficherToast(
        context,
        '✅ Abonnement Premium activé ! Profitez de toutes les fonctionnalités.',
      );
      // Retourner à l'écran précédent avec succès
      if (mounted) Navigator.of(context).pop(true);
    } else if (result.statut == AchatStatut.annule) {
      afficherToast(context, 'Achat annulé.');
    } else {
      afficherToast(
        context,
        result.message ?? 'Erreur lors de l\'achat. Réessayez.',
        estErreur: true,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final prixLabel = widget.formule == 'annuel'
        ? '25 000 FCFA / an'
        : '2 500 FCFA / mois';

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: (widget.peutProceder && !_achatlEnCours)
                ? _lancerAchat
                : null,
            icon: _achatlEnCours
                ? const SizedBox(
                    width: 20, height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white),
                  )
                : const Icon(Icons.play_circle_outline_rounded, size: 20),
            label: Text(
              _achatlEnCours
                  ? 'Paiement en cours…'
                  : 'S\'abonner — $prixLabel',
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: widget.peutProceder
                  ? const Color(0xFF01875F)
                  : AppColors.lignes,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 15),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
              elevation: 0,
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          widget.peutProceder
              ? 'Paiement sécurisé via Google Play. Renouvellement automatique.'
              : widget.kycBloquant
                  ? '🔒 Vérification d\'identité requise avant le paiement.'
                  : 'Cochez la case ci-dessus pour activer le bouton.',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 11.5,
            color: widget.kycBloquant
                ? const Color(0xFF991B1B)
                : AppColors.texteDoux,
            fontWeight: widget.kycBloquant ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
        const SizedBox(height: 8),
        // Bouton restaurer achats
        TextButton(
          onPressed: () async {
            await SubscriptionService.restaurerAchats();
            if (context.mounted) {
              afficherToast(context,
                  'Restauration en cours… Patientez quelques secondes.');
            }
          },
          child: const Text(
            'Restaurer un achat précédent',
            style: TextStyle(
              fontSize: 12,
              color: AppColors.texteDoux,
              decoration: TextDecoration.underline,
            ),
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SECTION iOS — Apple In-App Purchase / StoreKit
// ─────────────────────────────────────────────────────────────────────────────
class _SectionIOS extends StatefulWidget {
  final String formule;
  final bool   peutProceder;
  final bool   kycBloquant;

  const _SectionIOS({
    required this.formule,
    required this.peutProceder,
    required this.kycBloquant,
  });

  @override
  State<_SectionIOS> createState() => _SectionIOSState();
}

class _SectionIOSState extends State<_SectionIOS> {
  bool _achatEnCours = false;

  Future<void> _lancerAchat() async {
    if (_achatEnCours) return;
    setState(() => _achatEnCours = true);

    final productId = widget.formule == 'annuel'
        ? SubscriptionProductIds.annuel
        : SubscriptionProductIds.mensuel;

    final result = await SubscriptionService.acheter(productId);

    if (!mounted) return;
    setState(() => _achatEnCours = false);

    if (result.estSucces) {
      afficherToast(context, '✅ Abonnement Premium activé !');
      if (mounted) Navigator.of(context).pop(true);
    } else if (result.statut == AchatStatut.annule) {
      afficherToast(context, 'Achat annulé.');
    } else {
      afficherToast(
        context,
        result.message ?? 'Erreur lors de l\'achat.',
        estErreur: true,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final prixLabel = widget.formule == 'annuel'
        ? '25 000 FCFA / an'
        : '2 500 FCFA / mois';

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: (widget.peutProceder && !_achatEnCours)
                ? _lancerAchat
                : null,
            icon: _achatEnCours
                ? const SizedBox(
                    width: 20, height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white),
                  )
                : const Icon(Icons.apple_rounded, size: 20),
            label: Text(
              _achatEnCours
                  ? 'Paiement en cours…'
                  : 'S\'abonner — $prixLabel',
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: widget.peutProceder
                  ? const Color(0xFF0071E3)
                  : AppColors.lignes,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 15),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
              elevation: 0,
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          widget.peutProceder
              ? 'Paiement sécurisé via l\'App Store. Renouvellement automatique.'
              : widget.kycBloquant
                  ? '🔒 Vérification d\'identité requise avant le paiement.'
                  : 'Cochez la case ci-dessus pour activer le bouton.',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 11.5,
            color: widget.kycBloquant
                ? const Color(0xFF991B1B)
                : AppColors.texteDoux,
            fontWeight: widget.kycBloquant ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: () async {
            await SubscriptionService.restaurerAchats();
            if (context.mounted) {
              afficherToast(context, 'Restauration en cours…');
            }
          },
          child: const Text(
            'Restaurer un achat précédent',
            style: TextStyle(
              fontSize: 12,
              color: AppColors.texteDoux,
              decoration: TextDecoration.underline,
            ),
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// WIDGETS COMMUNS
// ─────────────────────────────────────────────────────────────────────────────

class _CarteSucces extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return CarteTC(
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: AppColors.succesFond,
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(Icons.check_circle, color: AppColors.succes, size: 24),
          ),
          const SizedBox(width: 14),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Demande envoyée !',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                    color: AppColors.succes,
                  ),
                ),
                Text(
                  'Nous vous contacterons sous 24h pour activer votre Premium.',
                  style: TextStyle(fontSize: 13, color: AppColors.texteDoux),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _BandeauPremiumActifSimple extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return CarteTC(
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: AppColors.fondConsultation,
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.workspace_premium,
                color: AppColors.orFonce, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Premium actif',
                  style: GoogleFonts.bricolageGrotesque(
                    fontWeight: FontWeight.w800,
                    fontSize: 16,
                    color: AppColors.orFonce,
                  ),
                ),
                Text(
                  'Toutes les fonctionnalités sont débloquées.',
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    color: AppColors.texteDoux,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _BandeauPremiumActif extends StatelessWidget {
  final dynamic tontine;

  const _BandeauPremiumActif({required this.tontine});

  @override
  Widget build(BuildContext context) {
    final expire = tontine?.planExpire as DateTime?;

    return CarteTC(
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: AppColors.fondConsultation,
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.workspace_premium,
                color: AppColors.orFonce, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '★ Premium actif',
                  style: GoogleFonts.bricolageGrotesque(
                    fontWeight: FontWeight.w800,
                    fontSize: 16,
                    color: AppColors.orFonce,
                  ),
                ),
                if (expire != null)
                  Text(
                    'Expire le ${Formatters.dateFormatee(expire)}',
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      color: AppColors.texteDoux,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionTitre extends StatelessWidget {
  final String titre;
  final IconData icone;

  const _SectionTitre({required this.titre, required this.icone});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icone, size: 16, color: AppColors.encre),
        const SizedBox(width: 8),
        Text(
          titre,
          style: GoogleFonts.bricolageGrotesque(
            fontWeight: FontWeight.w700,
            fontSize: 18,
            color: AppColors.encre,
          ),
        ),
      ],
    );
  }
}

class _CarteTarif extends StatelessWidget {
  final String label;
  final String prix;
  final String description;
  final String? badge;
  final bool selected;
  final VoidCallback onTap;

  const _CarteTarif({
    required this.label,
    required this.prix,
    required this.description,
    required this.badge,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: selected ? AppColors.encre : AppColors.carte,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected ? AppColors.encre : AppColors.lignes,
            width: selected ? 2 : 1,
          ),
          boxShadow: selected
              ? [BoxShadow(color: AppColors.encre.withValues(alpha: 0.15), blurRadius: 10, offset: const Offset(0, 4))]
              : [],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (badge != null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: AppColors.orFonce,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  badge!,
                  style: GoogleFonts.inter(
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                  ),
                ),
              ),
            if (badge != null) const SizedBox(height: 8),
            Text(
              label,
              style: GoogleFonts.inter(
                fontWeight: FontWeight.w700,
                fontSize: 15,
                color: selected ? Colors.white : AppColors.encre,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              prix,
              style: GoogleFonts.bricolageGrotesque(
                fontWeight: FontWeight.w800,
                fontSize: 14,
                color: selected ? Colors.white : AppColors.orFonce,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              description,
              style: GoogleFonts.inter(
                fontSize: 11.5,
                color: selected
                    ? Colors.white.withValues(alpha: 0.7)
                    : AppColors.texteDoux,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// TABLEAU COMPARATIF — version améliorée
// ─────────────────────────────────────────────────────────────────────────────

class _TableauComparatif extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.lignes, width: 1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Column(
          children: [
            // ── En-tête avec badges ──────────────────────────────────────────
            _EnTeteTableau(),
            // ── Lignes ──────────────────────────────────────────────────────
            _LigneTableau(
              icone: Icons.home_work_outlined,
              label: 'Tontines',
              gratuit: '1',
              premium: 'Illimitées',
              gratuitOk: true,
            ),
            _LigneTableau(
              icone: Icons.group_outlined,
              label: 'Membres par tontine',
              gratuit: '5 max',
              premium: 'Illimités',
              gratuitOk: true,
            ),
            _LigneTableau(
              icone: Icons.payments_outlined,
              label: 'Cotisations & tours',
              gratuit: '✓',
              premium: '✓',
              gratuitOk: true,
              egalite: true,
            ),
            _LigneTableau(
              icone: Icons.account_balance_wallet_outlined,
              label: 'Caisse & trésorerie',
              gratuit: '—',
              premium: '✓',
            ),
            _LigneTableau(
              icone: Icons.how_to_vote_outlined,
              label: 'Votes sécurisés',
              gratuit: '—',
              premium: '✓',
            ),
            _LigneTableau(
              icone: Icons.handshake_outlined,
              label: 'Prêts internes',
              gratuit: '—',
              premium: '✓',
            ),
            _LigneTableau(
              icone: Icons.picture_as_pdf_outlined,
              label: 'Exports PDF',
              gratuit: '—',
              premium: '✓',
            ),
            _LigneTableau(
              icone: Icons.psychology_outlined,
              label: 'Score IA de confiance',
              gratuit: '—',
              premium: '✓',
            ),
            _LigneTableau(
              icone: Icons.bar_chart_rounded,
              label: 'Statistiques avancées',
              gratuit: '—',
              premium: '✓',
            ),
            _LigneTableau(
              icone: Icons.share_outlined,
              label: 'Partage WhatsApp',
              gratuit: '—',
              premium: '✓',
            ),
            _LigneTableau(
              icone: Icons.history_rounded,
              label: 'Historique complet',
              gratuit: '—',
              premium: '✓',
            ),
            _LigneTableau(
              icone: Icons.notifications_outlined,
              label: 'Relances automatiques',
              gratuit: '—',
              premium: '✓',
              derniere: true,
            ),
          ],
        ),
      ),
    );
  }
}

class _EnTeteTableau extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFFF8F9FA), Color(0xFFF0F0EF)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Row(
        children: [
          const Expanded(
            flex: 5,
            child: Text(
              'Fonctionnalité',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 12,
                color: AppColors.encreDoux,
                letterSpacing: 0.5,
              ),
            ),
          ),
          // Badge Gratuit
          SizedBox(
            width: 72,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: AppColors.lignes,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Text(
                  'Gratuit',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: AppColors.encreDoux,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          // Badge Premium
          SizedBox(
            width: 76,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFFF59E0B), Color(0xFFD97706)],
                  ),
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFFF59E0B).withValues(alpha: 0.3),
                      blurRadius: 6,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.star_rounded, size: 10, color: Colors.white),
                    SizedBox(width: 3),
                    Text(
                      'Premium',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LigneTableau extends StatelessWidget {
  final IconData icone;
  final String   label;
  final String   gratuit;
  final String   premium;
  final bool     gratuitOk;
  final bool     egalite;
  final bool     derniere;

  const _LigneTableau({
    required this.icone,
    required this.label,
    required this.gratuit,
    required this.premium,
    this.gratuitOk = false,
    this.egalite   = false,
    this.derniere  = false,
  });

  @override
  Widget build(BuildContext context) {
    final bool premiumActif = premium == '✓' || premium == 'Illimitées' || premium == 'Illimités';
    final bool gratuitActif = gratuitOk && (gratuit == '✓' || gratuit == '1' || gratuit == '5 max');
    final bool isPremiumOnly = !egalite && !gratuitOk;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
      decoration: BoxDecoration(
        color: isPremiumOnly
            ? const Color(0xFFFFFDF5)
            : Colors.white,
        border: derniere
            ? null
            : const Border(bottom: BorderSide(color: AppColors.lignes, width: 0.5)),
      ),
      child: Row(
        children: [
          // Icône
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: isPremiumOnly
                  ? const Color(0xFFF59E0B).withValues(alpha: 0.1)
                  : AppColors.fondSecondaire,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              icone,
              size: 15,
              color: isPremiumOnly
                  ? const Color(0xFFF59E0B)
                  : AppColors.encreDoux,
            ),
          ),
          const SizedBox(width: 10),
          // Label
          Expanded(
            flex: 5,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                color: AppColors.encre,
                fontWeight: isPremiumOnly ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ),
          // Colonne Gratuit
          SizedBox(
            width: 72,
            child: Center(
              child: _buildCellule(gratuit, gratuitActif, false),
            ),
          ),
          const SizedBox(width: 8),
          // Colonne Premium
          SizedBox(
            width: 76,
            child: Center(
              child: _buildCellule(premium, premiumActif, !egalite),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCellule(String valeur, bool actif, bool isPremiumStyle) {
    if (valeur == '✓') {
      return Container(
        width: 26,
        height: 26,
        decoration: BoxDecoration(
          color: isPremiumStyle
              ? const Color(0xFFF59E0B).withValues(alpha: 0.12)
              : actif
                  ? AppColors.succesFond
                  : AppColors.fondSecondaire,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(
          Icons.check_rounded,
          size: 15,
          color: isPremiumStyle
              ? const Color(0xFFF59E0B)
              : actif
                  ? AppColors.succes
                  : AppColors.texteDoux,
        ),
      );
    }
    if (valeur == '—') {
      return const Text(
        '—',
        style: TextStyle(
          fontSize: 14,
          color: AppColors.lignes,
          fontWeight: FontWeight.w700,
        ),
      );
    }
    return Text(
      valeur,
      textAlign: TextAlign.center,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w700,
        color: isPremiumStyle
            ? const Color(0xFFF59E0B)
            : actif
                ? AppColors.succes
                : AppColors.texteDoux,
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// ÉCRAN TONTINE GRATUITE — upgrade impossible
// Affiche : tableau comparatif + formules (lecture seule) + message explicatif
// ─────────────────────────────────────────────────────────────────────────────

class _EcranTontineGratuite extends StatelessWidget {
  final String code;
  const _EcranTontineGratuite({required this.code});

  static const _couleurPremium = Color(0xFFF59E0B);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.fondPapier,
      body: SafeArea(
        child: Column(
          children: [
            // ── En-tête ────────────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
              child: Row(
                children: [
                  const LogoTontineClair(),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.arrow_back, size: 16),
                    label: const Text('Retour'),
                    style: TextButton.styleFrom(
                        foregroundColor: AppColors.encre),
                  ),
                ],
              ),
            ),

            // ── Contenu scrollable ─────────────────────────────────────────
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 18, 16, 32),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // ── Titre ──────────────────────────────────────────────
                    Row(
                      children: [
                        Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color: _couleurPremium.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: const Center(
                            child: Text('⭐', style: TextStyle(fontSize: 24)),
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Fonctionnalités Premium',
                                style: GoogleFonts.bricolageGrotesque(
                                  fontWeight: FontWeight.w800,
                                  fontSize: 22,
                                  color: AppColors.encre,
                                  letterSpacing: -0.5,
                                ),
                              ),
                              Text(
                                'Découvrez tout ce que Premium offre',
                                style: GoogleFonts.inter(
                                  fontSize: 13,
                                  color: AppColors.texteDoux,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),

                    // ── Bannière d'information importante ─────────────────
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFFF3CD),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: const Color(0xFFFFC107).withValues(alpha: 0.6),
                          width: 1.5,
                        ),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              color: const Color(0xFFFFC107).withValues(alpha: 0.25),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Icon(
                              Icons.info_outline_rounded,
                              color: Color(0xFFB45309),
                              size: 20,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Mise à niveau impossible',
                                  style: GoogleFonts.inter(
                                    fontWeight: FontWeight.w700,
                                    fontSize: 14,
                                    color: const Color(0xFF92400E),
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  'Cette tontine a été créée en mode Gratuit. '
                                  'Il n\'est pas possible de la passer en Premium.\n\n'
                                  'Pour accéder aux fonctionnalités Premium '
                                  '(Caisse, Prêts, Votes, Tirage au sort), '
                                  'vous devez créer une nouvelle tontine et '
                                  'choisir l\'option Premium dès le départ.',
                                  style: GoogleFonts.inter(
                                    fontSize: 13,
                                    color: const Color(0xFF78350F),
                                    height: 1.5,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),

                    // ── Tableau comparatif (lecture seule) ─────────────────
                    Text(
                      'Avantages Premium',
                      style: GoogleFonts.bricolageGrotesque(
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                        color: AppColors.encre,
                      ),
                    ),
                    const SizedBox(height: 12),
                    _TableauComparatif(),
                    const SizedBox(height: 24),

                    // ── Formules tarifaires (affichage lecture seule) ──────
                    Text(
                      'Nos formules',
                      style: GoogleFonts.bricolageGrotesque(
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                        color: AppColors.encre,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: _CarteFormulaLectureSeule(
                            label: 'Mensuel',
                            prix: '2 500 FCFA / mois',
                            description: 'Flexible, sans engagement',
                            badge: null,
                            highlighted: true,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _CarteFormulaLectureSeule(
                            label: 'Annuel',
                            prix: '25 000 FCFA / an',
                            description: '2 mois offerts vs mensuel',
                            badge: '-17%',
                            highlighted: false,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 32),

                    // ── Bouton CTA : créer une nouvelle tontine Premium ────
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: () {
                          // Retour à l'accueil puis navigation vers création
                          Navigator.of(context).popUntil((route) => route.isFirst);
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const CreationScreen(),
                            ),
                          );
                        },
                        icon: const Icon(Icons.add_circle_outline_rounded, size: 20),
                        label: Text(
                          'Créer une tontine Premium',
                          style: GoogleFonts.inter(
                            fontWeight: FontWeight.w700,
                            fontSize: 15,
                          ),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _couleurPremium,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                          elevation: 0,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),

                    // ── Retour discret ─────────────────────────────────────
                    SizedBox(
                      width: double.infinity,
                      child: TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        style: TextButton.styleFrom(
                          foregroundColor: AppColors.texteDoux,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                        child: Text(
                          'Retour à ma tontine',
                          style: GoogleFonts.inter(fontSize: 14),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Carte tarif en lecture seule (pour _EcranTontineGratuite)
// ─────────────────────────────────────────────────────────────────────────────

class _CarteFormulaLectureSeule extends StatelessWidget {
  final String label;
  final String prix;
  final String description;
  final String? badge;
  final bool highlighted;

  const _CarteFormulaLectureSeule({
    required this.label,
    required this.prix,
    required this.description,
    required this.badge,
    required this.highlighted,
  });

  static const _couleurPremium = Color(0xFFF59E0B);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: highlighted ? AppColors.encre : AppColors.carte,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: highlighted ? AppColors.encre : AppColors.lignes,
          width: highlighted ? 2 : 1,
        ),
        boxShadow: highlighted
            ? [BoxShadow(
                color: AppColors.encre.withValues(alpha: 0.15),
                blurRadius: 10,
                offset: const Offset(0, 4),
              )]
            : [],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (badge != null) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: _couleurPremium,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                badge!,
                style: GoogleFonts.inter(
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                ),
              ),
            ),
            const SizedBox(height: 8),
          ],
          Text(
            label,
            style: GoogleFonts.inter(
              fontWeight: FontWeight.w700,
              fontSize: 15,
              color: highlighted ? Colors.white : AppColors.encre,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            prix,
            style: GoogleFonts.bricolageGrotesque(
              fontWeight: FontWeight.w800,
              fontSize: 13,
              color: highlighted ? Colors.white : _couleurPremium,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            description,
            style: GoogleFonts.inter(
              fontSize: 11,
              color: highlighted
                  ? Colors.white.withValues(alpha: 0.7)
                  : AppColors.texteDoux,
            ),
          ),
        ],
      ),
    );
  }
}
