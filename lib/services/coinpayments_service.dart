import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'supabase_service.dart';

/// Service Flutter pour les paiements CoinPayments (crypto).
///
/// ⚠️  Clés JAMAIS dans Flutter — tous les appels signés via Edge Function.
///
/// Architecture :
///   Flutter → coinpayments-payment (Edge Fn) → CoinPayments API
///   IPN     → coinpayments-ipn     (Edge Fn) → crédit RPC Supabase
///
/// Référence pivot : [numCommande] format TCP_CODE_MID_TS
/// custom field    : TC-TYPE-{numCommande} (routage IPN)
///
/// Flux de paiement :
///   1. creerTransaction   → checkout_url + txid (persist PENDING)
///   2. Utilisateur paie   → CoinPayments checkout page
///   3. IPN automatique    → coinpayments-ipn → crédit (voie principale)
///   4. verifierStatut     → polling Flutter (affichage statut)
///   5. confirmerEtCrediter → fallback si IPN non reçu (status=100 requis)
///
/// ⚠️  Crédit UNIQUEMENT après IPN ou confirmerEtCrediter serveur-side.
///     success_url / retour utilisateur ne déclenche JAMAIS de crédit.
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
    String?  typeOperation,  // 'cotisation'|'caisse'|'penalite'|'remboursement_pret'|'pret_octroye'
    String?  membreId,
    String?  membreNom,
    String?  pretId,
    String?  description,
    String?  currency2,      // 'USDT.TRC20'(défaut)|'USDT.ERC20'|'BTC'|'ETH'|'LTC'
    String?  buyerEmail,     // email acheteur — requis par CoinPayments (fallback géré côté Edge Fn)
  }) async {
    final payload = <String, dynamic>{
      'action':         'creer_transaction',
      // Le champ 'montant' est utilisé par l'Edge Fn (+ fallback montant_xof)
      'montant':        montantXof,
      'montant_xof':    montantXof,
      'numcommande':    numCommande,
      'tontine_code':   tontineCode,
      'type_operation': typeOperation ?? 'cotisation',
      if (membreId    != null) 'membre_id':    membreId,
      if (membreNom   != null) 'membre_nom':   membreNom,
      if (pretId      != null) 'pret_id':      pretId,
      if (description != null) 'description':  description,
      if (currency2   != null) 'currency2':    currency2,
      // buyer_email : transmis si dispo, sinon Edge Fn utilise noreply@tontineclair.com
      if (buyerEmail  != null && buyerEmail.isNotEmpty) 'buyer_email': buyerEmail,
    };

    final rep = await _appelerEdge(payload, timeout: const Duration(seconds: 55));
    return CoinPaymentsResultat.fromJson(rep, numCommande: numCommande);
  }

  // ── Récupérer les infos wallet pour affichage in-app ─────────────────────

  /// Récupère l'adresse de dépôt crypto sans ouvrir le navigateur.
  /// Appeler après creerTransaction() avec le txid + checkoutUrl retournés.
  static Future<Map<String, dynamic>> infoWallet({
    required String txid,
    required String checkoutUrl,
    required String currency2,
    String? numCommande,
  }) async {
    final rep = await _appelerEdge({
      'action':       'info_wallet',
      'txid':         txid,
      'checkout_url': checkoutUrl,
      'currency2':    currency2,
      if (numCommande != null) 'numcommande': numCommande,
    }, timeout: const Duration(seconds: 20));
    return rep;
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
    // L'action côté Edge Fn est 'statut' (lecture seule — jamais de crédit)
    final rep = await _appelerEdge({
      'action':      'statut',
      'txid':        txid,
      'numcommande': numCommande,
      if (tontineCode != null) 'tontine_code': tontineCode,
    }, timeout: const Duration(seconds: 25));

    return CoinPaymentsResultat.fromJson(rep, numCommande: numCommande);
  }

  // ── Confirmer et créditer (polling serveur-side) ──────────────────────────

  /// Demande à l'Edge Function de poller CoinPayments et de créditer dès
  /// confirmation. Vérification stricte côté serveur avant tout crédit.
  /// Déclenche la vérification stricte côté serveur et crédite si status=100.
  /// ⚠️  NE PAS APPELER depuis success_url ou retour utilisateur.
  ///     Appeler uniquement si l'IPN n'est pas arrivé après le délai max de polling.
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
      if (montantXof != null) ...{
        'montant':     montantXof,
        'montant_xof': montantXof,
      },
      if (membreId  != null) 'membre_id':  membreId,
      if (membreNom != null) 'membre_nom': membreNom,
      if (pretId    != null) 'pret_id':    pretId,
    }, timeout: const Duration(seconds: 120));

    return CoinPaymentsResultat.fromJson(rep, numCommande: numCommande);
  }

  // ── Actions d'administration (TC Admin) ──────────────────────────────────

  /// Appelle l'Edge Function CoinPayments avec une action admin.
  ///
  /// [action] : 'admin_transactions' | 'admin_audit_log' | 'admin_config_status'
  ///            | 'admin_reconciliation' | 'admin_verifier_tx' | 'info_wallet'
  /// [params] : payload supplémentaire transmis à l'Edge Function.
  ///
  /// Toutes les clés API restent dans Supabase Secrets — jamais exposées côté Flutter.
  static Future<Map<String, dynamic>> adminAction(
    String action,
    Map<String, dynamic> params, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    return _appelerEdge(
      {'action': action, ...params},
      timeout: timeout,
    );
  }

  // ── Générer une référence de commande unique ──────────────────────────────

  /// Génère une référence commande unique.
  /// Format : TCP_[CODE]_[SUFFIX]_[TIMESTAMP]  (TCP = TontineClair CoinPayments)
  ///
  /// Le champ custom envoyé à CoinPayments est construit côté Edge Function :
  ///   TC-TYPE-{numCommande}  ex: TC-COTISATION-TCP_TONTINE1_MID_1720000000000
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
  final bool    needsCredit;  // true = IPN reçu mais crédit en attente (déclencher confirmerEtCrediter)
  final bool    fromCache;    // true = résultat vient de la DB (déjà traité)

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
    this.needsCredit = false,
    this.fromCache   = false,
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

    // statusCode : peut être num (statut CoinPayments ex: 100) ou String ("pending")
    // creer_transaction retourne status:"pending" (String) — on parse de façon safe
    final rawStatus  = j['statusCode'] ?? j['status'];
    final statusCode = rawStatus is num
        ? rawStatus.toInt()
        : (rawStatus is String ? int.tryParse(rawStatus) ?? 0 : 0);
    final rawNorm    = j['statusNorm']      as String?
                   ?? j['statusNormalise']  as String?;

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
      txid:        j['txid']         as String?,
      checkoutUrl: j['checkoutUrl']  as String?
                ?? j['checkout_url'] as String?,
      numCommande: j['numcommande']  as String? ?? numCommande,
      statusText:  j['statusText']   as String?
                ?? j['status_text']  as String?,
      statusCode:  statusCode,
      statusNorm:  norm,
      ok:          j['ok'] == true,
      needsCredit: j['needsCredit'] == true,
      fromCache:   j['fromCache']   == true,
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
