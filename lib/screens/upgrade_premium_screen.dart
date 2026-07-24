import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../utils/app_colors.dart';
import '../widgets/app_widgets.dart';
import '../models/kyc_model.dart';
import '../services/kyc_service.dart';
import 'kyc_screen.dart';

/// Écran "Passer en Premium" — Gratuite → Premium IRRÉVERSIBLE.
///
/// KYC obligatoire pour TOUT passage en Premium, sans condition de montant.
/// Compte Gratuit → aucun KYC.
class UpgradePremiumScreen extends StatefulWidget {
  final String  code;
  final int     montantCagnotte;
  final String? kycStatut;
  final String  gestNom;

  const UpgradePremiumScreen({
    super.key,
    required this.code,
    this.montantCagnotte = 0,
    this.kycStatut,
    this.gestNom = '',
  });

  @override
  State<UpgradePremiumScreen> createState() => _UpgradePremiumScreenState();
}

class _UpgradePremiumScreenState extends State<UpgradePremiumScreen> {
  bool _checkboxLu     = false;
  bool _kycVerifie     = false;   // true = Smile ID a confirmé verified
  bool _kycEnCours     = false;   // spinner pendant le check
  bool _kycEnAttente   = false;   // pending/processing après soumission

  static const _couleurPremium = Color(0xFFF59E0B);
  static const _googlePlayUrl =
      'https://play.google.com/store/apps/details?id=com.tontineclair.app';

  @override
  void initState() {
    super.initState();
    // Vérifier d'emblée le statut KYC depuis Supabase
    _verifierKycInitial();
  }

  /// KYC toujours obligatoire pour tout passage Premium
  bool get _peutProceder => _checkboxLu && _kycVerifie;

  Future<void> _verifierKycInitial() async {
    setState(() => _kycEnCours = true);
    final userId = widget.gestNom.isNotEmpty ? widget.gestNom : widget.code;
    final kyc = await KycService.getStatus(userId);
    if (!mounted) return;
    final valide = !KycService.kycBloquantDepuisStatut(kyc);
    final enAttente = kyc.status == KycStatus.pending ||
                      kyc.status == KycStatus.processing;
    setState(() {
      _kycVerifie   = valide;
      _kycEnAttente = enAttente && !valide;
      _kycEnCours   = false;
    });
  }

  Future<void> _lancerKyc() async {
    final userId = widget.gestNom.isNotEmpty ? widget.gestNom : widget.code;
    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => KycScreen(userId: userId)),
    );
    if (!mounted) return;
    if (result == true) await _verifierKycInitial();
  }

  Future<void> _ouvrirGooglePlay() async {
    final userId = widget.gestNom.isNotEmpty ? widget.gestNom : widget.code;
    final bloquant = await KycService.kycBloquantPourPremium(userId);
    if (!mounted) return;
    if (bloquant) {
      setState(() => _kycVerifie = false);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Vérification d\'identité Smile ID requise avant le passage Premium.'),
        backgroundColor: Colors.red,
      ));
      return;
    }
    final uri = Uri.parse(_googlePlayUrl);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.fondPapier,
      body: SafeArea(
        child: Stack(
          children: [
            SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 120),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 18),
                  // ── En-tête ────────────────────────────────────────────────
                  Row(
                    children: [
                      const LogoTontineClair(),
                      const Spacer(),
                      TextButton.icon(
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.arrow_back, size: 16),
                        label: const Text('Retour'),
                        style: TextButton.styleFrom(
                          foregroundColor: AppColors.encre,
                          textStyle: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),

                  // ── Titre ─────────────────────────────────────────────────
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
                              'Passer en Premium',
                              style: TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 24,
                                color: AppColors.encre,
                                letterSpacing: -0.02,
                              ),
                            ),
                            Text(
                              'Débloque toutes les fonctionnalités',
                              style: TextStyle(
                                fontSize: 14,
                                color: AppColors.texteDoux,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),

                  // ── Tableau comparatif ─────────────────────────────────────
                  CarteTC(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Comparaison des formules',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 16,
                            color: AppColors.encre,
                          ),
                        ),
                        const SizedBox(height: 16),
                        _LigneComparaison(
                          fonctionnalite: 'Tontines',
                          gratuite: '1 tontine',
                          premium: 'Illimitées',
                        ),
                        _LigneComparaison(
                          fonctionnalite: 'Membres par tontine',
                          gratuite: '5 membres max',
                          premium: 'Illimités',
                        ),
                        _LigneComparaison(
                          fonctionnalite: 'Paiements',
                          gratuite: 'Manuels (PIN)',
                          premium: 'Paiement automatisé',
                        ),
                        _LigneComparaison(
                          fonctionnalite: 'Caisse',
                          gratuite: 'Manuelle',
                          premium: 'Automatisé',
                        ),
                        _LigneComparaison(
                          fonctionnalite: 'PDF & export',
                          gratuite: 'Disponible',
                          premium: 'Disponible',
                          egalite: true,
                        ),
                        _LigneComparaison(
                          fonctionnalite: 'Votes & décisions',
                          gratuite: 'Disponible',
                          premium: 'Disponible',
                          egalite: true,
                        ),
                        _LigneComparaison(
                          fonctionnalite: 'Commission décaissement',
                          gratuite: 'Aucune',
                          premium: '2 % sur versement',
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),

                  // ── Avertissement irréversible ─────────────────────────────
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFF3CD),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                          color: const Color(0xFFF59E0B).withValues(alpha: 0.5)),
                    ),
                    child: const Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('⚠️', style: TextStyle(fontSize: 18)),
                        SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Action irréversible',
                                style: TextStyle(
                                  fontWeight: FontWeight.w800,
                                  fontSize: 14,
                                  color: Color(0xFF78350F),
                                ),
                              ),
                              SizedBox(height: 4),
                              Text(
                                'Une fois passée en Premium, cette tontine ne peut pas revenir en Gratuite. '
                                'Le paiement est géré par Google Play.',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: Color(0xFF92400E),
                                  height: 1.4,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),

                  // ── Bannière KYC Smile ID — toujours obligatoire en Premium ──
                  _BanniereKycSmileId(
                    kycVerifie:   _kycVerifie,
                    kycEnCours:   _kycEnCours,
                    kycEnAttente: _kycEnAttente,
                    onLancerKyc:  _lancerKyc,
                  ),
                  const SizedBox(height: 8),

                  // ── Checkbox confirmation ──────────────────────────────────
                  GestureDetector(
                    onTap: () => setState(() => _checkboxLu = !_checkboxLu),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 150),
                          width: 22,
                          height: 22,
                          decoration: BoxDecoration(
                            color: _checkboxLu
                                ? _couleurPremium
                                : Colors.transparent,
                            border: Border.all(
                              color: _checkboxLu
                                  ? _couleurPremium
                                  : AppColors.lignes,
                              width: 2,
                            ),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: _checkboxLu
                              ? const Icon(Icons.check,
                                  size: 14, color: Colors.white)
                              : null,
                        ),
                        const SizedBox(width: 10),
                        const Expanded(
                          child: Text(
                            'J\'ai compris que le passage en Premium est définitif et irréversible. '
                            'Je serai redirigé vers Google Play pour finaliser le paiement.',
                            style: TextStyle(
                              fontSize: 13.5,
                              color: AppColors.encre,
                              height: 1.4,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // ── Bouton bas fixe ────────────────────────────────────────────
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
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: _peutProceder ? _ouvrirGooglePlay : null,
                        icon: const Icon(Icons.open_in_new_rounded, size: 18),
                        label: const Text(
                          'Passer en Premium — Google Play',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 15,
                          ),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _peutProceder
                              ? _couleurPremium
                              : AppColors.lignes,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 15),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                          elevation: 0,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    if (!_kycVerifie && !_kycEnCours)
                      Text(
                        _kycEnAttente
                            ? '⏳ Vérification Smile ID en cours d\'analyse. Vous pourrez continuer dès confirmation.'
                            : '🔒 Vérification d\'identité Smile ID obligatoire avant le passage Premium.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 12,
                          color: _kycEnAttente
                              ? const Color(0xFF92400E)
                              : const Color(0xFF991B1B),
                          fontWeight: FontWeight.w600,
                        ),
                      )
                    else if (_kycVerifie)
                      const Text(
                        'Le passage en Premium sera activé après validation du paiement Google Play.',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 11.5, color: AppColors.texteDoux),
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

// ─── Ligne de comparaison Gratuite / Premium ──────────────────────────────────

class _LigneComparaison extends StatelessWidget {
  final String fonctionnalite;
  final String gratuite;
  final String premium;
  final bool egalite;

  const _LigneComparaison({
    required this.fonctionnalite,
    required this.gratuite,
    required this.premium,
    this.egalite = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Text(
              fonctionnalite,
              style: const TextStyle(
                fontSize: 13,
                color: AppColors.encre,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              gratuite,
              style: TextStyle(
                fontSize: 12.5,
                color: egalite ? AppColors.texteDoux : AppColors.alerte,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              premium,
              style: TextStyle(
                fontSize: 12.5,
                color: egalite
                    ? AppColors.texteDoux
                    : const Color(0xFFF59E0B),
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Bannière KYC Smile ID ────────────────────────────────────────────────────
class _BanniereKycSmileId extends StatelessWidget {
  final bool       kycVerifie;
  final bool       kycEnCours;
  final bool       kycEnAttente;
  final VoidCallback onLancerKyc;

  const _BanniereKycSmileId({
    required this.kycVerifie,
    required this.kycEnCours,
    required this.kycEnAttente,
    required this.onLancerKyc,
  });

  @override
  Widget build(BuildContext context) {
    if (kycEnCours) {
      return Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.fondSecondaire,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.lignes),
        ),
        child: const Row(children: [
          SizedBox(width: 20, height: 20,
            child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.or)),
          SizedBox(width: 12),
          Text('Vérification de votre identité…',
            style: TextStyle(fontSize: 13.5, color: AppColors.texteDoux)),
        ]),
      );
    }

    if (kycVerifie) {
      return Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFFE3F1EA),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFF2E7D5B).withValues(alpha: 0.4)),
        ),
        child: const Row(children: [
          Icon(Icons.verified_rounded, color: Color(0xFF2E7D5B), size: 22),
          SizedBox(width: 12),
          Expanded(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Identité vérifiée ✓',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14,
                  color: Color(0xFF1B5E3B))),
              Text('Votre identité a été confirmée par Smile ID.',
                style: TextStyle(fontSize: 12.5, color: Color(0xFF2E7D5B))),
            ],
          )),
        ]),
      );
    }

    if (kycEnAttente) {
      return Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFFFDF3E2),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.or.withValues(alpha: 0.4)),
        ),
        child: Row(children: [
          const Icon(Icons.hourglass_top_rounded, color: AppColors.or, size: 22),
          const SizedBox(width: 12),
          const Expanded(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Vérification en cours (Smile ID)',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14,
                  color: AppColors.encre)),
              Text('Résultat attendu sous 24–48h. Vous serez notifié.',
                style: TextStyle(fontSize: 12.5, color: AppColors.texteDoux)),
            ],
          )),
          TextButton(
            onPressed: null, // désactivé en attente
            child: const Text('En attente',
              style: TextStyle(color: AppColors.or, fontWeight: FontWeight.w600)),
          ),
        ]),
      );
    }

    // Non vérifié → bouton lancer KYC
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF3CD),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFF59E0B).withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(children: [
            Icon(Icons.fingerprint_rounded, color: Color(0xFFF59E0B), size: 22),
            SizedBox(width: 10),
            Expanded(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Vérification d\'identité obligatoire',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14,
                    color: Color(0xFF78350F))),
                Text('Requis pour activer le mode Premium.',
                  style: TextStyle(fontSize: 12.5, color: Color(0xFF92400E))),
              ],
            )),
          ]),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: onLancerKyc,
              icon: const Icon(Icons.verified_user_rounded, size: 18),
              label: const Text('Vérifier mon identité (Smile ID)',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFF59E0B),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 13),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                elevation: 0,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
