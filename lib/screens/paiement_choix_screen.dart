import 'package:flutter/material.dart';
import '../models/tontine.dart';
import '../utils/app_colors.dart';
import '../utils/formatters.dart';
import 'paiement_coinpayments_screen.dart';
import 'paiement_paydunya_screen.dart';

/// Écran de choix du mode de paiement.
///
/// Présente deux options :
///   • Mobile Money (PayDunya) — Orange Money, Wave, MTN, Moov, Djamo
///   • Crypto (CoinPayments)  — USDT, BTC, ETH, LTC, BNB…
///
/// Accessible depuis cotisations_screen, caisse_screen et prets_screen.
class PaiementChoixScreen extends StatelessWidget {
  final String  code;
  final Membre? membre;
  final String  typeFlux;
  final int?    montant;
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

  // ── Titre lisible de l'opération ─────────────────────────────────────────

  String get _titreOperation {
    switch (typeFlux) {
      case 'cotisation':            return 'Cotisation';
      case 'caisse':                return 'Apport en caisse';
      case 'penalite':              return 'Pénalité';
      case 'remboursement_pret':    return 'Remboursement de prêt';
      case 'pret_octroye':          return 'Prêt octroyé';
      case 'depense_caisse':        return 'Dépense de caisse';
      case 'decaissement_cagnotte': return 'Décaissement cagnotte';
      default:                      return 'Paiement';
    }
  }

  // ── Montant effectif ─────────────────────────────────────────────────────

  int get _montantEffectif {
    if (montant != null && montant! > 0) return montant!;
    return 0;
  }

  // ── Navigation vers PayDunya ─────────────────────────────────────────────
  // IMPORTANT : on utilise push (pas pushReplacement) pour que le bool
  // retourné par pop() remonte correctement jusqu'à l'écran appelant
  // (CaisseScreen, CotisationsScreen, etc.).

  void _allerPayDunya(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PaiementPayDunyaScreen(
          code:        code,
          typeFlux:    typeFlux,
          membre:      membre,
          montant:     montant,
          description: description ?? _titreOperation,
          membreId:    membreId  ?? membre?.id,
          membreNom:   membreNom ?? membre?.nom,
          telephone:   telephone ?? membre?.tel,
          pretId:      pretId,
          taux:        taux,
          dureesMois:  dureesMois,
          numeroTour:  numeroTour,
        ),
      ),
    ).then((result) {
      // Propager le résultat à l'écran appelant
      if (context.mounted) Navigator.pop(context, result);
    });
  }

  // ── Navigation vers CoinPayments ─────────────────────────────────────────
  // IMPORTANT : on utilise push (pas pushReplacement) pour que le bool
  // retourné par pop() remonte correctement jusqu'à l'écran appelant.

  void _allerCoinPayments(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PaiementCoinPaymentsScreen(
          code:        code,
          typeFlux:    typeFlux,
          membre:      membre,
          montant:     montant,
          description: description ?? _titreOperation,
          membreId:    membreId  ?? membre?.id,
          membreNom:   membreNom ?? membre?.nom,
          pretId:      pretId,
          taux:        taux,
          dureesMois:  dureesMois,
          numeroTour:  numeroTour,
        ),
      ),
    ).then((result) {
      // Propager le résultat à l'écran appelant
      if (context.mounted) Navigator.pop(context, result);
    });
  }

  // ─────────────────────────────────────────────────────────────────────────
  // BUILD
  // ─────────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.fondPapier,
      appBar: AppBar(
        backgroundColor: AppColors.or,
        foregroundColor: Colors.white,
        title: const Text(
          'Choisir le mode de paiement',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
        ),
        centerTitle: true,
        elevation: 0,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Récapitulatif ─────────────────────────────────────────────
              _buildRecap(context),
              const SizedBox(height: 24),

              // ── Titre ─────────────────────────────────────────────────────
              const Text(
                'Comment souhaitez-vous payer ?',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF1A1A2E),
                ),
              ),
              const SizedBox(height: 16),

              // ── Option 1 : Mobile Money (PayDunya) ───────────────────────
              _buildOptionCard(
                context:     context,
                titre:       'Mobile Money',
                sousTitre:   'Orange Money, Wave, MTN, Moov, Djamo',
                details:     'Paiement instantané en FCFA\nvia votre opérateur mobile',
                icone:       Icons.phone_android,
                couleur:     const Color(0xFFFF6B35),
                badge:       'Recommandé',
                badgeCouleur: Colors.green,
                operateurs:  [
                  _OperateurBadge('Orange', const Color(0xFFFF6600)),
                  _OperateurBadge('Wave',   const Color(0xFF1A73E8)),
                  _OperateurBadge('MTN',    const Color(0xFFFFCC00)),
                  _OperateurBadge('Moov',   const Color(0xFF00A0DC)),
                ],
                onTap: () => _allerPayDunya(context),
              ),
              const SizedBox(height: 16),

              // ── Option 2 : Crypto (CoinPayments) ─────────────────────────
              _buildOptionCard(
                context:    context,
                titre:      'Cryptomonnaie',
                sousTitre:  'USDT, Bitcoin, Ethereum, Litecoin, BNB…',
                details:    'Paiement en crypto\n7 devises numériques disponibles',
                icone:      Icons.currency_bitcoin,
                couleur:    const Color(0xFFF7931A),
                operateurs: [
                  _OperateurBadge('USDT',    const Color(0xFF26A17B)),
                  _OperateurBadge('BTC',     const Color(0xFFF7931A)),
                  _OperateurBadge('ETH',     const Color(0xFF627EEA)),
                  _OperateurBadge('LTC',     const Color(0xFF9DA2A6)),
                ],
                onTap: () => _allerCoinPayments(context),
              ),
              const SizedBox(height: 24),

              // ── Note de sécurité ──────────────────────────────────────────
              _buildNoteSecurite(),
            ],
          ),
        ),
      ),
    );
  }

  // ── Récapitulatif ─────────────────────────────────────────────────────────

  Widget _buildRecap(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color:        AppColors.or.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border:       Border.all(color: AppColors.or.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Container(
            width: 44, height: 44,
            decoration: BoxDecoration(
              color:        AppColors.or.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.receipt_long, color: AppColors.or, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  description ?? _titreOperation,
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                ),
                if ((membreNom ?? membre?.nom) != null)
                  Text(
                    membreNom ?? membre?.nom ?? '',
                    style: TextStyle(color: Colors.grey[600], fontSize: 12),
                  ),
              ],
            ),
          ),
          if (_montantEffectif > 0)
            Text(
              Formatters.montant(_montantEffectif),
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: AppColors.or,
              ),
            ),
        ],
      ),
    );
  }

  // ── Carte option de paiement ──────────────────────────────────────────────

  Widget _buildOptionCard({
    required BuildContext          context,
    required String                titre,
    required String                sousTitre,
    required String                details,
    required IconData              icone,
    required Color                 couleur,
    required List<_OperateurBadge> operateurs,
    required VoidCallback          onTap,
    String?                        badge,
    Color?                         badgeCouleur,
  }) {
    return Material(
      borderRadius: BorderRadius.circular(18),
      color: Colors.white,
      elevation: 3,
      shadowColor: couleur.withValues(alpha: 0.15),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // En-tête
              Row(
                children: [
                  Container(
                    width: 52, height: 52,
                    decoration: BoxDecoration(
                      color:        couleur.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(icone, color: couleur, size: 28),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              titre,
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 17,
                                color: Color(0xFF1A1A2E),
                              ),
                            ),
                            if (badge != null) ...[
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                decoration: BoxDecoration(
                                  color:        (badgeCouleur ?? Colors.green).withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: Text(
                                  badge,
                                  style: TextStyle(
                                    color:      badgeCouleur ?? Colors.green,
                                    fontSize:   10,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        Text(
                          sousTitre,
                          style: TextStyle(color: Colors.grey[600], fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  Icon(Icons.arrow_forward_ios, color: couleur, size: 18),
                ],
              ),
              const SizedBox(height: 14),
              const Divider(height: 1),
              const SizedBox(height: 14),
              // Détails
              Text(
                details,
                style: const TextStyle(color: Color(0xFF444466), fontSize: 13),
              ),
              const SizedBox(height: 12),
              // Badges opérateurs
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: operateurs.map((op) => _buildOperateurMini(op)).toList(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildOperateurMini(_OperateurBadge op) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color:        op.couleur.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
        border:       Border.all(color: op.couleur.withValues(alpha: 0.25)),
      ),
      child: Text(
        op.nom,
        style: TextStyle(
          color:      op.couleur,
          fontSize:   11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  // ── Note de sécurité ──────────────────────────────────────────────────────

  Widget _buildNoteSecurite() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color:        Colors.grey[100],
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.shield_outlined, color: Colors.green, size: 18),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'Vos paiements sont sécurisés. Les clés de paiement ne sont '
              'jamais stockées dans l\'application. Tous les crédits sont '
              'vérifiés côté serveur avant d\'être appliqués.',
              style: TextStyle(fontSize: 11, color: Colors.black54),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Modèles internes
// ─────────────────────────────────────────────────────────────────────────────

class _OperateurBadge {
  final String nom;
  final Color  couleur;
  const _OperateurBadge(this.nom, this.couleur);
}
