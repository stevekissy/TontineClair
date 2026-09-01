// Stub — intégration PayDunya supprimée.
// Le paiement automatique Mobile Money n'est plus disponible.
// Toutes les opérations passent par le paiement manuel (PaiementChoixScreen).

class PayDunyaService {
  // Service désactivé — aucune méthode API disponible.
  const PayDunyaService._();
}

class PayDunyaResultat {
  const PayDunyaResultat._();
}

class PayDunyaStatut {
  const PayDunyaStatut._();
}

class PayDunyaException implements Exception {
  final String message;
  const PayDunyaException(this.message);
  @override
  String toString() => 'PayDunyaException: $message';
}
