import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'supabase_service.dart';

/// Service Flutter pour les paiements CoinPayments (crypto).
///
/// ⚠️  Les clés CoinPayments ne sont JAMAIS stockées côté Flutter.
///     Tous les appels signés passent via la Supabase Edge Function
///     `coinpayments-payment` (à déployer côté Supabase).
///
/// Architecture :
///   Flutter → Supabase Edge Function (sécurisée) → CoinPayments API
///
/// Référence pivot : [numCommande] (TC_CODE_MEMBREID_TIMESTAMP)
///   → même format que SycaPay pour cohérence de traçabilité
///
/// Flux de paiement CoinPayments :
///   1. createTransaction → obtient checkout_url + txid
///   2. Utilisateur paie sur le checkout_url (navigateur/WebView)
///   3. getTransactionInfo → vérifie le statut (polling)
///   4. Statut 100 = complet → créditer via Supabase RPC
///
/// Codes de statut CoinPayments :
///   -1  = annulé / timeout
///    0  = en attente
///    1  = paiement partiel reçu
///    2  = en cours de traitement (confirmations blockchain)
///  100  = complet et confirmé
class CoinPaymentsService {
  static const String _edgeFn = 'coinpayments-payment';

  // ── Appel Edge Function ───────────────────────────────────────────────────

  static Future<Map<String, dynamic>> _appelerEdge(
    Map<String, dynamic> payload, {
    Duration timeout = const Duration(seconds: 50),
  }) async {
    final url = Uri.parse(
      '${SupabaseService.supabaseUrl}/functions/v1/$_edgeFn',
    );
    try {
      final resp = await http
          .post(
            url,
            headers: {
              'Content-Type':  'application/json',
              'Authorization': 'Bearer ${SupabaseService.supabaseAnonKey}',
              'apikey':        SupabaseService.supabaseAnonKey,
            },
            body: jsonEncode(payload),
          )
          .timeout(timeout);

      if (kDebugMode) {
        debugPrint('[CoinPayments] ${payload['action']} → HTTP ${resp.statusCode}');
        if (resp.body.length < 800) debugPrint('[CoinPayments] body: ${resp.body}');
      }

      if (resp.statusCode == 200 || resp.statusCode == 201) {
        return jsonDecode(resp.body) as Map<String, dynamic>;
      }
      return {
        'erreur':  true,
        'code':    resp.statusCode,
        'message': 'Erreur serveur (${resp.statusCode}): ${resp.body}',
      };
    } on TimeoutException {
      return {
        'erreur':  true,
        'code':    -504,
        'message': 'Délai dépassé. Réseau lent ou service surchargé.',
      };
    } catch (e) {
      return {
        'erreur':  true,
        'code':    -503,
        'message': 'Connexion impossible : $e',
      };
    }
  }

  // ── Créer une transaction CoinPayments ───────────────────────────────────

  /// Crée une transaction CoinPayments et retourne l'URL de paiement.
  ///
  /// [montantUsd] : montant en USD (CoinPayments travaille en USD ; conversion
  ///               XOF → USD effectuée côté Edge Function).
  /// [montantXof] : montant original en XOF pour traçabilité.
  /// [devise]     : 'XOF' | 'USD' | etc.
  static Future<CoinPaymentsResultat> creerTransaction({
    required int    montantXof,
    required String numCommande,
    required String tontineCode,
    String?  typeOperation,  // 'cotisation' | 'caisse' | 'penalite' | 'remboursement_pret'
    String?  membreId,
    String?  membreNom,
    String?  pretId,
    String?  description,
    String?  currency2,      // crypto cible : 'BTC' | 'ETH' | 'USDT' | 'LTC' (défaut: USDT.TRC20)
  }) async {
    final payload = <String, dynamic>{
      'action':         'creer_transaction',
      'montant_xof':    montantXof,
      'numcommande':    numCommande,
      'tontine_code':   tontineCode,
      'type_operation': typeOperation ?? 'cotisation',
      if (membreId    != null) 'membre_id':     membreId,
      if (membreNom   != null) 'membre_nom':    membreNom,
      if (pretId      != null) 'pret_id':       pretId,
      if (description != null) 'description':   description,
      if (currency2   != null) 'currency2':     currency2,
    };

    final rep = await _appelerEdge(payload, timeout: const Duration(seconds: 30));
    return CoinPaymentsResultat.fromJson(rep, numCommande: numCommande);
  }

  // ── Vérifier le statut d'une transaction ─────────────────────────────────

  /// Interroge CoinPayments pour obtenir le statut d'une transaction.
  ///
  /// [txid] : l'identifiant retourné par creerTransaction.
  static Future<CoinPaymentsResultat> verifierStatut({
    required String txid,
    required String numCommande,
    String?  tontineCode,
  }) async {
    final rep = await _appelerEdge({
      'action':       'verifier_statut',
      'txid':         txid,
      'numcommande':  numCommande,
      if (tontineCode != null) 'tontine_code': tontineCode,
    }, timeout: const Duration(seconds: 25));

    return CoinPaymentsResultat.fromJson(rep, numCommande: numCommande);
  }

  // ── Confirmer et créditer (polling serveur-side) ──────────────────────────

  /// Demande à l'Edge Function de poller CoinPayments et de créditer dès
  /// confirmation. Même pattern sécurisé que SycaPay v5.
  static Future<CoinPaymentsResultat> confirmerEtCrediter({
    required String txid,
    required String numCommande,
    required String tontineCode,
    required String typeOperation,
    int?     montantXof,
    String?  membreId,
    String?  membreNom,
    String?  pretId,
  }) async {
    final rep = await _appelerEdge({
      'action':         'confirmer_et_crediter',
      'txid':           txid,
      'numcommande':    numCommande,
      'tontine_code':   tontineCode,
      'type_operation': typeOperation,
      if (montantXof != null) 'montant_xof':  montantXof,
      if (membreId   != null) 'membre_id':    membreId,
      if (membreNom  != null) 'membre_nom':   membreNom,
      if (pretId     != null) 'pret_id':      pretId,
    }, timeout: const Duration(seconds: 120));

    return CoinPaymentsResultat.fromJson(rep, numCommande: numCommande);
  }

  // ── Générer une référence de commande unique ──────────────────────────────

  /// Format : TCP_[CODE]_[SUFFIX]_[TIMESTAMP]  (TCP = TontineClair CoinPayments)
  static String genererNumCommande(String codeTontine, String suffix) {
    final ts = DateTime.now().millisecondsSinceEpoch;
    final safeSuffix = suffix.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').toUpperCase();
    return 'TCP_${codeTontine.toUpperCase()}_${safeSuffix}_$ts';
  }
}

// ── Modèle de résultat CoinPayments ──────────────────────────────────────────

class CoinPaymentsResultat {
  final bool    erreur;
  final String  message;
  final String? txid;          // identifiant transaction CoinPayments
  final String? checkoutUrl;   // URL à ouvrir dans le navigateur
  final String? numCommande;   // notre référence pivot
  final String? statusText;    // texte statut CoinPayments
  final int     statusCode;    // -1, 0, 1, 2, 100
  final String  statusNorm;    // 'pending' | 'processing' | 'confirmed' | 'failed' | 'cancelled'
  final bool    ok;            // true = confirmé ET crédité côté serveur

  const CoinPaymentsResultat({
    required this.erreur,
    required this.message,
    this.txid,
    this.checkoutUrl,
    this.numCommande,
    this.statusText,
    this.statusCode  = 0,
    this.statusNorm  = 'pending',
    this.ok          = false,
  });

  // ── Getters sémantiques ───────────────────────────────────────────────────

  bool get estSucces    => ok && statusNorm == 'confirmed';
  bool get estEnAttente => statusNorm == 'pending' || statusNorm == 'processing';
  bool get estEchec     => statusNorm == 'failed'  || statusNorm == 'cancelled';
  bool get estConfirme  => statusCode == 100;
  bool get aCheckoutUrl => checkoutUrl != null && checkoutUrl!.isNotEmpty;

  // ── Constructeur depuis JSON Edge Function ────────────────────────────────

  factory CoinPaymentsResultat.fromJson(
    Map<String, dynamic> j, {
    String? numCommande,
  }) {
    if (j['erreur'] == true) {
      return CoinPaymentsResultat(
        erreur:     true,
        message:    j['message'] as String? ?? 'Erreur inconnue',
        numCommande: numCommande,
        statusNorm: 'failed',
      );
    }

    final statusCode = (j['status'] as num?)?.toInt() ?? 0;
    final rawNorm    = j['statusNormalise'] as String?;

    final String norm;
    if (rawNorm != null && rawNorm.isNotEmpty) {
      norm = rawNorm;
    } else if (statusCode == 100)                  { norm = 'confirmed'; }
    else if (statusCode == -1)                     { norm = 'cancelled'; }
    else if (statusCode >= 1 && statusCode < 100)  { norm = 'processing'; }
    else                                           { norm = 'pending'; }

    return CoinPaymentsResultat(
      erreur:      false,
      message:     j['message']     as String? ?? '',
      txid:        j['txid']        as String?,
      checkoutUrl: j['checkout_url'] as String? ?? j['checkoutUrl'] as String?,
      numCommande: j['numcommande'] as String? ?? numCommande,
      statusText:  j['status_text'] as String?,
      statusCode:  statusCode,
      statusNorm:  norm,
      ok:          j['ok'] == true,
    );
  }

  // ── Message lisible ───────────────────────────────────────────────────────

  String get messageFr {
    if (erreur) return 'Connexion impossible. Vérifiez votre réseau.';
    switch (statusNorm) {
      case 'confirmed':  return 'Paiement crypto confirmé avec succès.';
      case 'processing': return 'Transaction en cours de confirmation blockchain…';
      case 'pending':    return 'En attente du paiement crypto.';
      case 'cancelled':  return 'Transaction annulée ou expirée.';
      case 'failed':     return 'Paiement échoué. Veuillez réessayer.';
      default:           return 'Statut en cours de vérification…';
    }
  }

  @override
  String toString() =>
      'CoinPaymentsResultat(status=$statusNorm, txid=$txid, ref=$numCommande, ok=$ok)';
}
