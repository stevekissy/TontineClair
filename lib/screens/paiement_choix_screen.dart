import 'package:flutter/material.dart';
import '../models/tontine.dart';
import '../utils/app_colors.dart';
import 'paiement_caisse_pro_screen.dart';
import 'paiement_coinpayments_screen.dart';
import 'paiement_pro_screen.dart';

/// Écran de choix du moyen de paiement Premium.
///
/// Accessible depuis cotisations_screen (cotisation), caisse_screen (apport/pénalité)
/// et prets_screen (remboursement).
///
/// Présente deux options :
///   📱  SycaPay      → Mobile Money (Orange, Moov, MTN, Wave) — Afrique de l'Ouest
///   ₿   CoinPayments → Paiement crypto (USDT, BTC, ETH, LTC)
///
/// Paramètre [typeFlux] détermine quel écran de paiement est poussé :
///   'cotisation'           → PaiementProScreen
///   'caisse' / 'penalite'
///   / 'remboursement_pret'
///   / 'pret_octroye' …     → PaiementCaisseProScreen
class PaiementChoixScreen extends StatelessWidget {
  /// Code de la tontine (pivot de toutes les opérations)
  final String code;

  /// Membre concerné (cotisation) — null si caisse/prêt
  final Membre? membre;

  /// Type d'opération :
  ///   'cotisation' | 'caisse' | 'penalite' | 'remboursement_pret' |
  ///   'pret_octroye' | 'depense_caisse' | 'decaissement_cagnotte'
  final String typeFlux;

  // ── Paramètres spécifiques caisse / prêts ────────────────────────────────
  final int?    montant;       // obligatoire si typeFlux != 'cotisation'
  final String? description;
  final String? membreId;
  final String? membreNom;
  final String? pretId;
  final String? telephone;
  final String? operateur;
  final int?    taux;
  final int?    dureesMois;
  final int?    numeroTour;

  const PaiementChoixScreen({
    super.key,
    required this.code,
    required this.typeFlux,
    this.membre,
    this.montant,
    this.description,
    this.membreId,
    this.membreNom,
    this.pretId,
    this.telephone,
    this.operateur,
    this.taux,
    this.dureesMois,
    this.numeroTour,
  });

  // ── Libellé affiché selon le flux ────────────────────────────────────────

  String get _titreOperation {
    switch (typeFlux) {
      case 'cotisation':              return 'Cotisation';
      case 'caisse':                  return 'Apport en caisse';
      case 'penalite':                return 'Pénalité';
      case 'remboursement_pret':      return 'Remboursement de prêt';
      case 'pret_octroye':            return 'Prêt octroyé';
      case 'depense_caisse':          return 'Dépense de caisse';
      case 'decaissement_cagnotte':   return 'Décaissement cagnotte';
      default:                        return 'Paiement';
    }
  }

  String get _nomMembre => membre?.nom ?? membreNom ?? '';

  // ── Navigation vers SycaPay ───────────────────────────────────────────────

  void _allerSycaPay(BuildContext ctx) {
    Navigator.pop(ctx);   // fermer le choix
    if (typeFlux == 'cotisation' && membre != null) {
      Navigator.push(
        ctx,
        MaterialPageRoute(
          builder: (_) => PaiementProScreen(code: code, membre: membre!),
        ),
      );
    } else {
      // Caisse, pénalité, prêts → PaiementCaisseProScreen
      _pousserCaissePro(ctx, gateway: 'sycapay');
    }
  }

  // ── Navigation vers CoinPayments ─────────────────────────────────────────

  void _allerCoinPayments(BuildContext ctx) {
    Navigator.pop(ctx);   // fermer le choix
    Navigator.push(
      ctx,
      MaterialPageRoute(
        builder: (_) => PaiementCoinPaymentsScreen(
          code:          code,
          typeFlux:      typeFlux,
          membre:        membre,
          montant:       montant,
          description:   description ?? _titreOperation,
          membreId:      membreId ?? membre?.id,
          membreNom:     membreNom ?? membre?.nom,
          pretId:        pretId,
          taux:          taux,
          dureesMois:    dureesMois,
          numeroTour:    numeroTour,
        ),
      ),
    );
  }

  void _pousserCaissePro(BuildContext ctx, {required String gateway}) {
    // Import dynamique pour éviter la dépendance circulaire
    Navigator.push(
      ctx,
      MaterialPageRoute(
        builder: (_) => _CaisseProBridge(
          code:          code,
          montant:       montant ?? 0,
          description:   description ?? _titreOperation,
          typeOperation: typeFlux,
          membreId:      membreId,
          membreNom:     membreNom,
          pretId:        pretId,
          telephone:     telephone,
          operateur:     operateur,
          taux:          taux,
          dureesMois:    dureesMois,
          numeroTour:    numeroTour,
        ),
      ),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.fondPapier,
      appBar: AppBar(
        backgroundColor: AppColors.fondPapier,
        elevation: 0,
        title: Text(
          _titreOperation,
          style: const TextStyle(
            fontWeight: FontWeight.w700,
            color:      AppColors.encre,
            fontSize:   16,
          ),
        ),
        iconTheme: const IconThemeData(color: AppColors.encre),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ── En-tête ──────────────────────────────────────────────────
              if (_nomMembre.isNotEmpty) ...[
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
                  decoration: BoxDecoration(
                    color: AppColors.fondCode,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: AppColors.lignes),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.person_rounded,
                          color: AppColors.encre, size: 20),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _nomMembre,
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize:   15,
                            color:      AppColors.encre,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
              ],

              const Text(
                'Choisissez votre moyen de paiement',
                style: TextStyle(
                  fontSize:   17,
                  fontWeight: FontWeight.w700,
                  color:      AppColors.encre,
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                'Les deux options sont sécurisées et automatisées.',
                style: TextStyle(fontSize: 13, color: AppColors.texteDoux),
              ),
              const SizedBox(height: 28),

              // ── Carte SycaPay ─────────────────────────────────────────────
              _CarteChoix(
                titre:       'SycaPay — Mobile Money',
                sousTitre:   'Orange Money · Moov · MTN MoMo · Wave',
                icone:       Icons.phone_android_rounded,
                couleur:     const Color(0xFF1A6B3C),
                fondCouleur: const Color(0xFFEAF4EE),
                badges: const ['Orange', 'Moov', 'MTN', 'Wave'],
                description:
                    'Payez directement depuis votre portefeuille mobile. '
                    'Confirmation instantanée par push ou USSD.',
                onTap: () => _allerSycaPay(context),
              ),
              const SizedBox(height: 16),

              // ── Carte CoinPayments ─────────────────────────────────────────
              _CarteChoix(
                titre:       'CoinPayments — Crypto',
                sousTitre:   'USDT · Bitcoin · Ethereum · Litecoin',
                icone:       Icons.currency_bitcoin_rounded,
                couleur:     const Color(0xFFF7931A),
                fondCouleur: const Color(0xFFFFF8EE),
                badges: const ['USDT', 'BTC', 'ETH', 'LTC'],
                description:
                    'Payez en cryptomonnaie via CoinPayments. '
                    'Idéal pour les membres de la diaspora.',
                onTap: () => _allerCoinPayments(context),
              ),

              const Spacer(),

              // ── Note sécurité ─────────────────────────────────────────────
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.fondSecondaire,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.lock_rounded,
                        size: 16, color: AppColors.texteDoux),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Paiements sécurisés. Aucune clé financière stockée '
                        'sur votre appareil.',
                        style: TextStyle(
                            fontSize: 11,
                            color:    AppColors.texteDoux,
                            height:   1.4),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Carte de choix ────────────────────────────────────────────────────────────

class _CarteChoix extends StatelessWidget {
  final String       titre;
  final String       sousTitre;
  final IconData     icone;
  final Color        couleur;
  final Color        fondCouleur;
  final List<String> badges;
  final String       description;
  final VoidCallback onTap;

  const _CarteChoix({
    required this.titre,
    required this.sousTitre,
    required this.icone,
    required this.couleur,
    required this.fondCouleur,
    required this.badges,
    required this.description,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color:        Colors.white,
          borderRadius: BorderRadius.circular(18),
          border:       Border.all(color: couleur.withValues(alpha: 0.35), width: 1.5),
          boxShadow: [
            BoxShadow(
              color:  couleur.withValues(alpha: 0.08),
              blurRadius:  12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // En-tête
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color:        fondCouleur,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(icone, color: couleur, size: 26),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        titre,
                        style: TextStyle(
                          fontSize:   15,
                          fontWeight: FontWeight.w800,
                          color:      couleur,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        sousTitre,
                        style: const TextStyle(
                          fontSize: 12,
                          color:    AppColors.texteDoux,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right_rounded,
                    color: couleur.withValues(alpha: 0.7), size: 24),
              ],
            ),
            const SizedBox(height: 14),

            // Badges opérateurs / cryptos
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: badges.map((b) => Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                decoration: BoxDecoration(
                  color:        fondCouleur,
                  borderRadius: BorderRadius.circular(20),
                  border:       Border.all(color: couleur.withValues(alpha: 0.25)),
                ),
                child: Text(
                  b,
                  style: TextStyle(
                    fontSize:   11,
                    fontWeight: FontWeight.w600,
                    color:      couleur,
                  ),
                ),
              )).toList(),
            ),
            const SizedBox(height: 12),

            // Description
            Text(
              description,
              style: const TextStyle(
                fontSize: 12.5,
                color:    AppColors.texte,
                height:   1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Bridge vers PaiementCaisseProScreen ──────────────────────────────────

class _CaisseProBridge extends StatelessWidget {
  final String  code;
  final int     montant;
  final String  description;
  final String  typeOperation;
  final String? membreId;
  final String? membreNom;
  final String? pretId;
  final String? telephone;
  final String? operateur;
  final int?    taux;
  final int?    dureesMois;
  final int?    numeroTour;

  const _CaisseProBridge({
    required this.code,
    required this.montant,
    required this.description,
    required this.typeOperation,
    this.membreId,
    this.membreNom,
    this.pretId,
    this.telephone,
    this.operateur,
    this.taux,
    this.dureesMois,
    this.numeroTour,
  });

  @override
  Widget build(BuildContext context) {
    return PaiementCaisseProScreen(
      code:          code,
      montant:       montant,
      description:   description,
      typeOperation: typeOperation,
      membreId:      membreId,
      membreNom:     membreNom,
      pretId:        pretId,
      telephone:     telephone,
      operateur:     operateur,
      taux:          taux,
      dureesMois:    dureesMois,
      numeroTour:    numeroTour,
    );
  }
}
