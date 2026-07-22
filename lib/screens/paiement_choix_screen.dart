import 'package:flutter/material.dart';
import '../models/tontine.dart';
import '../utils/app_colors.dart';
import 'paiement_coinpayments_screen.dart';

/// Écran de paiement Premium — CoinPayments uniquement.
///
/// Accessible depuis cotisations_screen (cotisation), caisse_screen (apport/pénalité)
/// et prets_screen (remboursement).
///
/// SycaPay a été retiré de l'application.
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

  @override
  Widget build(BuildContext context) {
    // Redirection immédiate vers CoinPayments (plus de choix intermédiaire)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!context.mounted) return;
      Navigator.pushReplacement(
        context,
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
    });

    // Écran transitoire pendant la redirection
    return Scaffold(
      backgroundColor: AppColors.fondPapier,
      body: const Center(
        child: CircularProgressIndicator(color: AppColors.or),
      ),
    );
  }
}
