import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../utils/app_colors.dart';
import '../widgets/app_widgets.dart';
import '../models/tontine.dart';

/// Écran "Passer en Premium" — Gratuite → Premium IRRÉVERSIBLE.
///
/// - Si cagnotte < 200 000 XOF : KYC optionnel (peut continuer sans).
/// - Si cagnotte >= 200 000 XOF : KYC obligatoire avant accès Google Play.
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
  bool    _checkboxLu  = false;
  String? _kycStatut;   // mis à jour après soumission KYC

  static const _couleurPremium = Color(0xFFF59E0B);
  static const _googlePlayUrl =
      'https://play.google.com/store/apps/details?id=com.tontineclair.app';

  @override
  void initState() {
    super.initState();
    _kycStatut = widget.kycStatut;
  }

  bool get _kycRequis  => widget.montantCagnotte >= TontineData.kSeuilKyc;
  bool get _kycValide  => _kycStatut == 'valide';
  bool get _kycPending => _kycStatut == 'pending';
  bool get _kycBloquant => _kycRequis && !_kycValide;

  /// Bouton Google Play actif si :
  ///   - checkbox cochée ET
  ///   - KYC non bloquant (soit cagnotte < seuil, soit KYC valide)
  bool get _peutProceder => _checkboxLu && !_kycBloquant;

  Future<void> _ouvrirGooglePlay() async {
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
                          premium: 'SycaPay — Mobile Money',
                        ),
                        _LigneComparaison(
                          fonctionnalite: 'Caisse',
                          gratuite: 'Manuelle',
                          premium: 'SycaPay activé',
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
                          premium: '1 % sur versement',
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

                  // ── Bannière KYC (Premium uniquement) ─────────────────────
                  BanniereKyc(
                    kycStatut:       _kycStatut,
                    montantCagnotte: widget.montantCagnotte,
                    gestNom:         widget.gestNom,
                    code:            widget.code,
                    onSoumis: () async {
                      // Recharger le statut KYC après soumission
                      setState(() => _kycStatut = 'pending');
                    },
                  ),

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
                    if (_kycBloquant)
                      const Text(
                        '🔒 Soumettez votre KYC ci-dessus avant de continuer (cagnotte ≥ 200 000 XOF).',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 12,
                          color: Color(0xFF991B1B),
                          fontWeight: FontWeight.w600,
                        ),
                      )
                    else if (_kycPending)
                      const Text(
                        '⏳ KYC soumis — en attente de validation admin. Vous pourrez continuer après validation.',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 12, color: Color(0xFF92400E)),
                      )
                    else
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
