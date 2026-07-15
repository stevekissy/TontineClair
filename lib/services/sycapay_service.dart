import 'dart:convert';
import 'package:http/http.dart' as http;
import 'supabase_service.dart';

/// Service Flutter pour les paiements SycaPay.
///
/// ⚠️  Les clés SycaPay (MarchandID / API Key / Secret Key) ne sont JAMAIS
///     stockées côté Flutter. Tous les appels signés passent exclusivement
///     par la Supabase Edge Function `sycapay-payment`.
///
/// Architecture :
///   Flutter → Supabase Edge Function → SycaPay Production API
///
/// SycaPay Production : https://dev.sycapay.com/
/// (malgré le sous-domaine "dev", c'est bien le endpoint de production)
class SycaPayService {
  // ── Constantes métier ─────────────────────────────────────────────────────
  static const double commissionPct = 0.01; // 1% sur décaissements
  static const String _edgeFn = 'sycapay-payment';

  // ── Calculs financiers ────────────────────────────────────────────────────

  /// Commission due sur [montant] (arrondie à l'entier le plus proche).
  static int calculerCommission(int montant) =>
      (montant * commissionPct).round();

  /// Montant net que reçoit le bénéficiaire (avant commission séparée).
  static int montantNet(int montant) => montant; // bénéficiaire reçoit 100%

  /// Montant de commission facturé séparément à la caisse tontine.
  static int commissionCaisse(int montant) => calculerCommission(montant);

  // ── Appel Edge Function ───────────────────────────────────────────────────

  static Future<Map<String, dynamic>> _appelerEdge(
    Map<String, dynamic> payload,
  ) async {
    final url = Uri.parse(
      '${SupabaseService.supabaseUrl}/functions/v1/$_edgeFn',
    );
    try {
      final resp = await http
          .post(
            url,
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer ${SupabaseService.supabaseAnonKey}',
              'apikey': SupabaseService.supabaseAnonKey,
            },
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 45));

      if (resp.statusCode == 200 || resp.statusCode == 201) {
        return jsonDecode(resp.body) as Map<String, dynamic>;
      }
      return {
        'erreur': true,
        'code': resp.statusCode,
        'message': 'Erreur serveur (${resp.statusCode})',
      };
    } catch (e) {
      return {
        'erreur': true,
        'code': -504,
        'message': 'Connexion impossible : $e',
      };
    }
  }

  // ── Initier un paiement (cotisation Pro) ──────────────────────────────────

  /// Initie un paiement Mobile Money pour une cotisation Pro.
  ///
  /// [telephone]   : numéro du membre payeur (format CI : 07XXXXXXXX)
  /// [montant]     : montant en XOF
  /// [numCommande] : référence unique (ex: TontineClair_CODE_MEMBREID_TIMESTAMP)
  /// [operateur]   : 'orange' | 'moov' | 'mtn' | 'wave'
  /// [otp]         : requis pour Orange uniquement (#144*8*2#)
  /// [urlNotif]    : URL webhook Supabase pour confirmer la transaction
  ///
  /// Retourne la réponse brute de SycaPay via l'Edge Function.
  static Future<SycaPayResultat> initierPaiement({
    required String telephone,
    required int montant,
    required String numCommande,
    required String operateur,
    String? otp,
    String? nomMembre,
    String? prenomMembre,
    String? urlNotif,
  }) async {
    final payload = {
      'action': 'payer',
      'telephone': telephone,
      'montant': montant.toString(),
      'currency': 'XOF',
      'numcommande': numCommande,
      'operateur': operateur,
      if (otp != null) 'otp': otp,
      if (nomMembre != null) 'name': nomMembre,
      if (prenomMembre != null) 'pname': prenomMembre,
      if (urlNotif != null) 'urlnotif': urlNotif,
    };

    final rep = await _appelerEdge(payload);
    return SycaPayResultat.fromJson(rep);
  }

  // ── Vérifier le statut d'une transaction ──────────────────────────────────

  /// Vérifie le statut d'une transaction via son `transactionId` SycaPay.
  static Future<SycaPayResultat> verifierStatut(String transactionId) async {
    final rep = await _appelerEdge({
      'action': 'statut',
      'ref': transactionId,
    });
    return SycaPayResultat.fromJson(rep);
  }

  // ── Générer une référence de commande unique ──────────────────────────────

  /// Génère un numéro de commande unique pour éviter les doublons (idempotence).
  /// Format : TC_[CODE]_[MEMBREID]_[TIMESTAMP]
  static String genererNumCommande(String codeTontine, String membreId) {
    final ts = DateTime.now().millisecondsSinceEpoch;
    return 'TC_${codeTontine.toUpperCase()}_${membreId}_$ts';
  }
}

// ── Modèle de résultat SycaPay ────────────────────────────────────────────────

class SycaPayResultat {
  final int code;             // 0 = succès, <0 = erreur
  final String message;
  final String? transactionId;
  final String? paiementId;
  final String? mobile;
  final String? orderId;
  final String? montant;
  final String? operateur;
  final bool erreurReseau;    // true si la connexion a échoué avant SycaPay

  const SycaPayResultat({
    required this.code,
    required this.message,
    this.transactionId,
    this.paiementId,
    this.mobile,
    this.orderId,
    this.montant,
    this.operateur,
    this.erreurReseau = false,
  });

  bool get estSucces   => code == 0;
  bool get estEnAttente => code == -200;
  bool get estEchec    => !estSucces && !estEnAttente;

  factory SycaPayResultat.fromJson(Map<String, dynamic> j) {
    if (j['erreur'] == true) {
      return SycaPayResultat(
        code: (j['code'] as num?)?.toInt() ?? -999,
        message: j['message'] as String? ?? 'Erreur inconnue',
        erreurReseau: true,
      );
    }
    return SycaPayResultat(
      code: (j['code'] as num?)?.toInt() ?? -999,
      message: j['message'] as String? ?? '',
      transactionId: j['transactionId'] as String? ?? j['transactionID'] as String?,
      paiementId: j['paiementId'] as String?,
      mobile: j['mobile'] as String?,
      orderId: j['orderId'] as String?,
      montant: j['montant'] as String? ?? j['amount'] as String?,
      operateur: j['operator'] as String?,
    );
  }

  /// Message lisible en français pour l'utilisateur.
  String get messageFr {
    if (erreurReseau) return 'Connexion impossible. Vérifiez votre réseau.';
    switch (code) {
      case 0:    return 'Paiement initié avec succès.';
      case -1:   return 'Paiement échoué. Réessayez.';
      case -3:   return 'Solde insuffisant.';
      case -4:   return 'Service momentanément indisponible.';
      case -5:   return 'Code OTP incorrect.';
      case -7:   return 'Numéro ou code OTP invalide.';
      case -8:   return 'Session expirée. Réessayez.';
      case -14:  return 'Erreur d\'authentification.';
      case -200: return 'Paiement en attente de confirmation.';
      case -250: return 'Référence de paiement introuvable.';
      case -400: return 'Numéro de téléphone manquant.';
      case -500: return 'Accès non autorisé.';
      default:   return 'Erreur ($code). Contactez le support.';
    }
  }
}
