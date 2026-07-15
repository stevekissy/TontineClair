// ignore_for_file: avoid_print
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/tontine_provider.dart';
import '../services/supabase_service.dart';
import '../services/platform_service.dart';
import '../services/subscription_service.dart';
import '../services/feature_gate_service.dart';
import '../models/tontine.dart';
import '../services/mandat_service.dart';
import '../utils/app_colors.dart';
import '../utils/formatters.dart';
import '../widgets/app_widgets.dart';
import 'mandat_screen.dart';

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

  const AbonnementScreen({
    super.key,
    required this.code,
    this.platformeForce,
  });

  @override
  State<AbonnementScreen> createState() => _AbonnementScreenState();
}

class _AbonnementScreenState extends State<AbonnementScreen> {
  bool _loading = false;
  bool _demandeEnvoyee = false;
  String _formule = 'mensuel';

  PlatformType get _platform =>
      widget.platformeForce ?? PlatformService.current;

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<TontineProvider>();
    final tontine  = provider.courante;

    // Statut Premium — depuis SubscriptionService (source unique)
    final isPremium = tontine?.isPremium ?? SubscriptionService.isPremium;

    return Scaffold(
      backgroundColor: AppColors.fondPapier,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 40),
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

              Text(
                'Abonnement',
                style: GoogleFonts.bricolageGrotesque(
                  fontWeight: FontWeight.w800,
                  fontSize: 28,
                  color: AppColors.encre,
                ),
              ),
              const SizedBox(height: 8),

              // ── Statut actuel ─────────────────────────────────────────────
              if (isPremium && tontine != null)
                _BandeauPremiumActif(tontine: tontine)
              else if (isPremium)
                _BandeauPremiumActifSimple()
              else
                Text(
                  'Débloquez toutes les fonctionnalités avec Premium.',
                  style: GoogleFonts.inter(
                    fontSize: 15,
                    color: AppColors.texteDoux,
                  ),
                ),
              const SizedBox(height: 24),

              // ── Tableau comparatif ────────────────────────────────────────
              _TableauComparatif(),
              const SizedBox(height: 24),

              // ── Section souscription selon la plateforme ─────────────────
              if (!isPremium) ...[
                _SectionTitre(
                  titre: 'Choisissez votre formule',
                  icone: Icons.workspace_premium,
                ),
                const SizedBox(height: 12),

                // ── Sélection formule ─────────────────────────────────────
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
                const SizedBox(height: 20),

                // ── CTA selon la plateforme ───────────────────────────────
                _buildCtaPlateforme(context, tontine),
              ],

              const SizedBox(height: 32),

              // ── Section Forfait Mandat ────────────────────────────────────
              if (tontine != null) ...[
                const Divider(height: 1),
                const SizedBox(height: 24),
                _SectionForfaitMandat(tontine: tontine),
                const SizedBox(height: 24),
              ],

              _buildNotesLegales(),
            ],
          ),
        ),
      ),
    );
  }

  // ─── CTA selon plateforme ────────────────────────────────────────────────

  Widget _buildCtaPlateforme(BuildContext context, dynamic tontine) {
    switch (_platform) {
      case PlatformType.android:
        return _SectionAndroid(formule: _formule);
      case PlatformType.ios:
        return _SectionIOS(formule: _formule);
      case PlatformType.web:
        return _SectionWeb(
          formule: _formule,
          code: widget.code.isNotEmpty
              ? widget.code
              : tontine?.code ?? '',
          loading: _loading,
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

    // Afficher le formulaire de collecte des infos avant d'envoyer
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
                          '✅ Demande envoyée ! L\'administrateur vous contactera sous 24h.');
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
              // WhatsApp contact (web uniquement)
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
    // Numéro WhatsApp admin : +225 02 43 21 76 (format international sans espaces)
    final url = Uri.parse('https://wa.me/22502432176?text=$msg');
    launchUrl(url, mode: LaunchMode.externalApplication).catchError((_) => false);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SECTION ANDROID — Google Play Billing
// Aucun formulaire web, aucun WhatsApp
// ─────────────────────────────────────────────────────────────────────────────

class _SectionAndroid extends StatelessWidget {
  final String formule;

  const _SectionAndroid({required this.formule});

  @override
  Widget build(BuildContext context) {
    return CarteTC(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Image.network(
                'https://upload.wikimedia.org/wikipedia/commons/thumb/7/78/Google_Play_Store_badge_EN.svg/320px-Google_Play_Store_badge_EN.svg.png',
                height: 28,
                errorBuilder: (_, __, ___) =>
                    const Icon(Icons.shop, color: AppColors.encreDoux, size: 28),
              ),
              const SizedBox(width: 10),
              Text(
                'Google Play',
                style: GoogleFonts.inter(
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                  color: AppColors.encre,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'L\'abonnement Premium est disponible via Google Play.\n'
            'Le paiement est sécurisé et géré directement par Google.',
            style: GoogleFonts.inter(
              fontSize: 13.5,
              color: AppColors.texteDoux,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 16),

          // Product ID affiché pour transparence
          _InfoProduit(
            productId: formule == 'annuel'
                ? FeatureGate.googlePlayYearly
                : FeatureGate.googlePlayMonthly,
            prix: formule == 'annuel' ? '25 000 FCFA/an' : '2 500 FCFA/mois',
          ),
          const SizedBox(height: 16),

          // Bouton Souscrire via Google Play
          BtnPrincipal(
            label: 'Souscrire via Google Play',
            icone: Icons.play_circle_outline,
            couleur: const Color(0xFF01875F), // couleur Google Play
            onTap: () => _lancerGooglePlay(context),
          ),
          const SizedBox(height: 8),

          // Restaurer les achats
          TextButton.icon(
            onPressed: () => _restaurerAchats(context),
            icon: const Icon(Icons.restore, size: 16),
            label: const Text('Restaurer les achats'),
            style: TextButton.styleFrom(
                foregroundColor: AppColors.texteDoux),
          ),

          const SizedBox(height: 12),
          _NoteRenouvellement(),
        ],
      ),
    );
  }

  void _lancerGooglePlay(BuildContext ctx) {
    // TODO : déclencher in_app_purchase quand le package est intégré.
    // Pour l'instant : afficher un message d'information.
    afficherToast(
      ctx,
      'Google Play Billing sera activé après publication sur le Play Store.',
    );
  }

  void _restaurerAchats(BuildContext ctx) {
    afficherToast(ctx, 'Restauration en cours via Google Play…');
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SECTION iOS — Apple In-App Purchase / StoreKit
// Aucun formulaire web, aucun WhatsApp
// ─────────────────────────────────────────────────────────────────────────────

class _SectionIOS extends StatelessWidget {
  final String formule;

  const _SectionIOS({required this.formule});

  @override
  Widget build(BuildContext context) {
    return CarteTC(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.apple, size: 28, color: AppColors.encre),
              const SizedBox(width: 10),
              Text(
                'App Store',
                style: GoogleFonts.inter(
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                  color: AppColors.encre,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'L\'abonnement Premium est disponible via l\'App Store d\'Apple.\n'
            'Le paiement est sécurisé et géré directement par Apple.',
            style: GoogleFonts.inter(
              fontSize: 13.5,
              color: AppColors.texteDoux,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 16),

          _InfoProduit(
            productId: formule == 'annuel'
                ? FeatureGate.appleYearly
                : FeatureGate.appleMonthly,
            prix: formule == 'annuel' ? '25 000 FCFA/an' : '2 500 FCFA/mois',
          ),
          const SizedBox(height: 16),

          BtnPrincipal(
            label: 'Souscrire via App Store',
            icone: Icons.apple,
            couleur: const Color(0xFF0071E3), // couleur Apple
            onTap: () => _lancerAppStore(context),
          ),
          const SizedBox(height: 8),

          TextButton.icon(
            onPressed: () => _restaurerAchats(context),
            icon: const Icon(Icons.restore, size: 16),
            label: const Text('Restaurer les achats'),
            style: TextButton.styleFrom(
                foregroundColor: AppColors.texteDoux),
          ),

          const SizedBox(height: 12),
          _NoteRenouvellement(),
        ],
      ),
    );
  }

  void _lancerAppStore(BuildContext ctx) {
    // TODO : déclencher StoreKit quand le package est intégré.
    afficherToast(
      ctx,
      'Apple In-App Purchase sera activé après publication sur l\'App Store.',
    );
  }

  void _restaurerAchats(BuildContext ctx) {
    afficherToast(ctx, 'Restauration en cours via App Store…');
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// WIDGETS COMMUNS
// ─────────────────────────────────────────────────────────────────────────────

class _InfoProduit extends StatelessWidget {
  final String productId;
  final String prix;

  const _InfoProduit({required this.productId, required this.prix});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.fondCode,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          const Icon(Icons.label_outline, size: 14, color: AppColors.texteDoux),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  productId,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    color: AppColors.encreDoux,
                  ),
                ),
                Text(
                  prix,
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: AppColors.encre,
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

class _NoteRenouvellement extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Text(
      '⟳ Se renouvelle automatiquement. Annulez à tout moment depuis les paramètres de votre compte store.',
      style: GoogleFonts.inter(
        fontSize: 11.5,
        color: AppColors.texteDoux,
        height: 1.4,
      ),
    );
  }
}

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

class _TableauComparatif extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.carte,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.lignes, width: 1),
      ),
      child: Column(
        children: [
          _EnTeteTableau(),
          const Divider(height: 1, color: AppColors.lignes),
          _LigneTableau('Tontines',
              '1', 'Illimitées', false),
          _LigneTableau('Membres par tontine',
              '5 max', 'Illimités', false),
          _LigneTableau('Cotisations et tours',
              '✓', '✓', true),
          _LigneTableau('Votes sécurisés',
              '—', '✓', false),
          _LigneTableau('Prêts internes',
              '—', '✓', false),
          _LigneTableau('Exports PDF',
              '—', '✓', false),
          _LigneTableau('Score IA de confiance',
              '—', '✓', false),
          _LigneTableau('Statistiques avancées',
              '—', '✓', false),
          _LigneTableau('Partage WhatsApp',
              '—', '✓', false),
          _LigneTableau('Historique complet',
              '—', '✓', false),
          _LigneTableau('Journal d\'audit',
              '—', '✓', false),
          _LigneTableau('Relances automatiques',
              '—', '✓', false),
        ],
      ),
    );
  }
}

class _EnTeteTableau extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.fondSecondaire,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Row(
        children: [
          const Expanded(
            flex: 3,
            child: Text('Fonctionnalité',
                style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 12.5,
                    color: AppColors.encre)),
          ),
          Expanded(
            flex: 2,
            child: Center(
              child: Text('Gratuit',
                  style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: AppColors.texteDoux)),
            ),
          ),
          Expanded(
            flex: 2,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: AppColors.orFonce,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text('Premium',
                    style: GoogleFonts.inter(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: Colors.white)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LigneTableau extends StatelessWidget {
  final String label;
  final String gratuit;
  final String premium;
  final bool gratuitActif;

  const _LigneTableau(this.label, this.gratuit, this.premium, this.gratuitActif);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.lignes, width: 0.5)),
      ),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Text(
              label,
              style: GoogleFonts.inter(fontSize: 13, color: AppColors.encre),
            ),
          ),
          Expanded(
            flex: 2,
            child: Center(
              child: Text(
                gratuit,
                style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: gratuitActif ? AppColors.succes : AppColors.texteDoux,
                ),
              ),
            ),
          ),
          Expanded(
            flex: 2,
            child: Center(
              child: Text(
                premium,
                style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: AppColors.succes,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Section Forfait Mandat ──────────────────────────────────────────────────

class _SectionForfaitMandat extends StatelessWidget {
  final Tontine tontine;

  const _SectionForfaitMandat({required this.tontine});

  @override
  Widget build(BuildContext context) {
    final estMandat = tontine.estSousMandat;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Titre section
        Row(
          children: [
            Icon(
              Icons.verified_rounded,
              size: 18,
              color: estMandat ? AppColors.or : AppColors.texteDoux,
            ),
            const SizedBox(width: 8),
            Text(
              'Mode Gestion sous Mandat',
              style: GoogleFonts.inter(
                fontWeight: FontWeight.w700,
                fontSize: 16,
                color: AppColors.encre,
              ),
            ),
            const SizedBox(width: 8),
            if (estMandat) const BadgeMandat(),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'Activez le Mode Mandat pour gérer les paiements réels de votre tontine avec une commission transparente.',
          style: GoogleFonts.inter(
            fontSize: 13,
            color: AppColors.texteDoux,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 16),

        // Carte conditions
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: estMandat
                ? AppColors.or.withValues(alpha: 0.07)
                : AppColors.carte,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: estMandat
                  ? AppColors.or.withValues(alpha: 0.25)
                  : AppColors.lignes,
            ),
          ),
          child: Column(
            children: [
              _LigneForfait(
                icone: Icons.receipt_long_rounded,
                label: 'Forfait mensuel',
                valeur: Formatters.montant(MandatService.forfaitMensuelFCFA, devise: 'XOF'),
                accent: true,
              ),
              const Divider(height: 20),
              _LigneForfait(
                icone: Icons.percent_rounded,
                label: 'Commission sur décaissements',
                valeur: '1%',
                accent: true,
              ),
              const Divider(height: 20),
              _LigneForfait(
                icone: Icons.payments_rounded,
                label: 'Paiements réels activés',
                valeur: '✅',
                accent: false,
              ),
              const Divider(height: 20),
              _LigneForfait(
                icone: Icons.swap_horiz_rounded,
                label: 'Basculement libre ↔ mandat',
                valeur: 'Réversible',
                accent: false,
              ),
            ],
          ),
        ),

        const SizedBox(height: 16),

        // Bouton
        SizedBox(
          width: double.infinity,
          child: estMandat
              ? OutlinedButton.icon(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => MandatScreen(code: tontine.code),
                    ),
                  ),
                  icon: const Icon(Icons.settings_rounded, size: 16),
                  label: const Text('Gérer le Mode Mandat'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.or,
                    side: BorderSide(color: AppColors.or),
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                )
              : FilledButton.icon(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => MandatScreen(code: tontine.code),
                    ),
                  ),
                  icon: const Icon(Icons.verified_rounded, size: 16),
                  label: const Text('Activer le Mode Mandat'),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.or,
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}

class _LigneForfait extends StatelessWidget {
  final IconData icone;
  final String label;
  final String valeur;
  final bool accent;

  const _LigneForfait({
    required this.icone,
    required this.label,
    required this.valeur,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icone, size: 16, color: AppColors.texteDoux),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 13,
              color: AppColors.texte,
            ),
          ),
        ),
        Text(
          valeur,
          style: GoogleFonts.inter(
            fontWeight: FontWeight.w700,
            fontSize: 14,
            color: accent ? AppColors.or : AppColors.succes,
          ),
        ),
      ],
    );
  }
}
