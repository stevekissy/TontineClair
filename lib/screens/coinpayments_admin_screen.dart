// Stub — administration CoinPayments supprimée.
// Utiliser l'écran admin standard.
import 'package:flutter/material.dart';

class CoinPaymentsAdminScreen extends StatelessWidget {
  const CoinPaymentsAdminScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Paiements')),
      body: const Center(
        child: Text(
          'Gestion des paiements API désactivée.\n'
          'Les paiements se font désormais manuellement.',
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}
