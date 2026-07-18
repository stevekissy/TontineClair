import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'supabase_service.dart';

/// Service Flutter pour les paiements SycaPay.
///
/// ⚠️  Les clés SycaPay ne sont JAMAIS stockées côté Flutter.
///     Tous les appels signés passent via la Supabase Edge Function `sycapay-payment`.
///
/// Architecture :
///   Flutter → Supabase Edge Function (sécurisée) → SycaPay Production API
///
/// Référence pivot : [numCommande] (TC_CODE_MEMBREID_TIMESTAMP)
///   → stockée dans sycapay_transactions (Supabase)
///   → utilisée pour GetStatus ET pour l'idempotence
///   → JAMAIS le transactionId SycaPay seul (instable)
class SycaPayService {
  static const double commissionPct = 0.02;
  static const String _edgeFn      = 'sycapay-payment';

  static int calculerCommission(int montant) => (montant * commissionPct).round();
  static int montantNet(int montant)         => montant;
  static int commissionCaisse(int montant)   => calculerCommission(montant);

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
        debugPrint('[SycaPay] ${payload['action']} → HTTP ${resp.statusCode}');
        if (resp.body.length < 500) debugPrint('[SycaPay] body: ${resp.body}');
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
        'message': 'Délai dépassé (${timeout.inSeconds}s). Réseau lent ou Edge Function surchargée.',
      };
    } catch (e) {
      return {
        'erreur':  true,
        'code':    -504,
        'message': 'Connexion impossible : $e',
      };
    }
  }

  // ── Initier un paiement ───────────────────────────────────────────────────

  /// Lance un paiement Mobile Money.
  ///
  /// [numCommande] est la référence pivot stockée dans Supabase.
  /// L'Edge Function créera automatiquement la ligne dans sycapay_transactions.
  static Future<SycaPayResultat> initierPaiement({
    required String telephone,
    required int    montant,
    required String numCommande,
    required String operateur,
    required String tontineCode,
    String?  otp,
    String?  nomMembre,
    String?  prenomMembre,
    String?  typeOperation, // 'cotisation' | 'caisse' | 'penalite' | 'remboursement_pret'
    String?  membreId,
    String?  membreNom,
    String?  pretId,
    String?  description,
  }) async {
    final payload = <String, dynamic>{
      'action':         'payer',
      'telephone':      telephone,
      'montant':        montant.toString(),
      'currency':       'XOF',
      'numcommande':    numCommande,
      'operateur':      operateur,
      'tontine_code':   tontineCode,
      'type_operation': typeOperation ?? 'cotisation',
      if (otp          != null) 'otp':           otp,
      if (nomMembre    != null) 'name':          nomMembre,
      if (prenomMembre != null) 'pname':         prenomMembre,
      if (membreId     != null) 'membre_id':     membreId,
      if (membreNom    != null) 'membre_nom':    membreNom,
      if (pretId       != null) 'pret_id':       pretId,
      if (membreId     != null) 'emprunteur_id': membreId,
      if (membreNom    != null) 'emprunteur_nom':membreNom,
      if (description  != null) 'description':   description,
    };

    final rep = await _appelerEdge(payload, timeout: const Duration(seconds: 55));
    return SycaPayResultat.fromJson(rep, numCommande: numCommande);
  }

  // ── Vérifier le statut (par numCommande — ref pivot) ─────────────────────

  /// Vérifie le statut d'une transaction par son numCommande interne.
  ///
  /// Utilise numCommande (pas transactionId) — c'est la ref que SycaPay
  /// accepte dans GetStatus.php et qui est stockée dans notre DB.
  static Future<SycaPayResultat> verifierStatut(
    String numCommande, {
    String? transactionId,  // fallback si GetStatus ne trouve pas par numCommande
    String? tontineCode,
  }) async {
    final rep = await _appelerEdge({
      'action':         'statut',
      'numcommande':    numCommande,
      if (transactionId != null) 'transactionId': transactionId,
      if (tontineCode   != null) 'tontine_code':  tontineCode,
    }, timeout: const Duration(seconds: 30));

    return SycaPayResultat.fromJson(rep, numCommande: numCommande);
  }

  // ── Vérifier une ref dans Supabase (pour récupération après crash) ────────

  /// Cherche une transaction dans Supabase par sa référence interne.
  /// Utilisé au redémarrage de l'app pour retrouver les pending.
  static Future<SycaPayResultat?> verifierReferenceSupabase(
    String numCommande,
  ) async {
    try {
      final rep = await _appelerEdge({
        'action':      'verifier_ref',
        'numcommande': numCommande,
      }, timeout: const Duration(seconds: 15));

      if (rep['erreur'] == true) return null;
      if (rep['trouve'] != true) return null;

      return SycaPayResultat.fromJson({
        'code':           rep['statusNormalise'] == 'confirmed' ? 0 : -200,
        'statusNormalise': rep['statusNormalise'],
        'transactionId':  rep['transactionId'],
        'montant':        rep['amount']?.toString(),
        'operateur':      rep['operator'],
        'fromCache':      true,
      }, numCommande: numCommande);
    } catch (e) {
      if (kDebugMode) debugPrint('[SycaPay] verifierReferenceSupabase erreur: $e');
      return null;
    }
  }

  // ── Confirmer et créditer côté serveur ───────────────────────────────────

  /// Demande à l'Edge Function de poller SycaPay pendant 150s CÔTÉ SERVEUR
  /// et de créditer la caisse/cotisation automatiquement dès confirmation.
  ///
  /// Flutter n'a qu'à attendre la réponse (watchdog Flutter 180s).
  /// Si l'app se ferme pendant ce temps, le webhook crédite automatiquement.
  ///
  /// Retourne un [SycaPayResultat] avec :
  ///   - estSucces = true si confirmé ET crédité
  ///   - estEnAttente = true si timeout (bouton Vérifier à afficher)
  ///   - estEchec = true si refus définitif (solde insuf, etc.)
  ///   - timeout = true si Edge Fn a atteint sa limite 150s
  static Future<SycaPayResultat> confirmerEtCrediter({
    required String numCommande,
    required String tontineCode,
    required String typeOperation, // 'caisse' | 'cotisation' | 'penalite' | 'remboursement_pret'
    String?  transactionId,
    int?     montant,
    String?  operateur,
    String?  membreId,
    String?  membreNom,
    String?  pretId,
    String?  description,
  }) async {
    final rep = await _appelerEdge({
      'action':         'confirmer_et_crediter',
      'numcommande':    numCommande,
      'tontine_code':   tontineCode,
      'type_operation': typeOperation,
      if (transactionId != null) 'transactionId':  transactionId,
      if (montant       != null) 'montant':         montant,
      if (operateur     != null) 'operateur':       operateur,
      if (membreId      != null) 'membre_id':       membreId,
      if (membreNom     != null) 'membre_nom':      membreNom,
      if (pretId        != null) 'pret_id':         pretId,
      if (membreId      != null) 'emprunteur_id':   membreId,
      if (membreNom     != null) 'emprunteur_nom':  membreNom,
      if (description   != null) 'description':     description,
    // Timeout 170s : légèrement > 150s polling serveur, < 180s watchdog Flutter
    }, timeout: const Duration(seconds: 170));

    return _SycaPayResultatEtendu.fromJsonV4(rep, numCommande: numCommande);
  }

  // ── Marquer la transaction comme créditée (anti double-crédit) ───────────

  /// Appelle l'Edge Function pour marquer la transaction 'credited'.
  /// Doit être appelé APRÈS l'écriture réussie dans ecrireTontineSansPIN.
  static Future<bool> marquerCredite(String numCommande) async {
    try {
      final rep = await _appelerEdge({
        'action':      'marquer_credite',
        'numcommande': numCommande,
      }, timeout: const Duration(seconds: 15));

      if (rep['dejaCredite'] == true) {
        if (kDebugMode) debugPrint('[SycaPay] $numCommande déjà crédité — OK idempotent');
        return true; // Considéré comme succès (idempotent)
      }
      return rep['ok'] == true;
    } catch (e) {
      if (kDebugMode) debugPrint('[SycaPay] marquerCredite erreur: $e');
      return false; // Non bloquant
    }
  }

  // ── Générer une référence de commande unique ──────────────────────────────

  /// Format : TC_[CODE]_[SUFFIX]_[TIMESTAMP]
  static String genererNumCommande(String codeTontine, String suffix) {
    final ts = DateTime.now().millisecondsSinceEpoch;
    // Nettoyer le suffix (pas de caractères spéciaux)
    final safeSuffix = suffix.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').toUpperCase();
    return 'TC_${codeTontine.toUpperCase()}_${safeSuffix}_$ts';
  }
}

// ── Modèle de résultat SycaPay ─────────────────────────────────────────────────

class SycaPayResultat {
  final int     code;
  final String  message;
  final String? transactionId;   // ID SycaPay (peut être null pour certains opérateurs)
  final String? numCommande;     // Notre référence pivot (TC_...)
  final String? mobile;
  final String? montant;
  final String? operateur;
  final bool    erreurReseau;
  final String  statusNormalise; // 'confirmed'|'pending'|'failed'|'expired'|'unknown'
  final bool    fromCache;       // true si réponse vient de Supabase (pas SycaPay direct)
  final bool    dejaConfirme;    // true si idempotent (déjà traité)
  final bool    _ok;             // true si confirmer_et_crediter réussi
  final bool    _timeout;        // true si Edge Fn a timeout

  const SycaPayResultat({
    required this.code,
    required this.message,
    this.transactionId,
    this.numCommande,
    this.mobile,
    this.montant,
    this.operateur,
    this.erreurReseau    = false,
    this.statusNormalise = 'unknown',
    this.fromCache       = false,
    this.dejaConfirme    = false,
    bool ok              = false,
    bool timeout         = false,
  })  : _ok      = ok,
        _timeout  = timeout;

  // ── Getters sémantiques ───────────────────────────────────────────────────

  bool get estSucces    => (statusNormalise == 'confirmed' || code == 0) && ok;
  bool get estEnAttente => statusNormalise == 'pending'
                        || code == -200
                        || code == -9
                        || timeout;
  bool get estEchec     => statusNormalise == 'failed'
                        || (statusNormalise == 'unknown' && !estEnAttente && !estSucces);
  bool get estExpire    => statusNormalise == 'expired' || code == -8;

  // true si c'est la réponse de confirmer_et_crediter avec ok:true
  bool get ok      => _ok;
  // true si l'Edge Function a dépassé son timeout de polling (150s)
  bool get timeout => _timeout;

  // ── Constructeur depuis JSON Edge Function ────────────────────────────────

  factory SycaPayResultat.fromJson(
    Map<String, dynamic> j, {
    String? numCommande,
  }) {
    if (j['erreur'] == true) {
      return SycaPayResultat(
        code:            (j['code'] as num?)?.toInt() ?? -999,
        message:         j['message'] as String? ?? 'Erreur inconnue',
        numCommande:     numCommande,
        erreurReseau:    true,
        statusNormalise: 'failed',
      );
    }

    final code = (j['code'] as num?)?.toInt() ?? -999;
    final rawStatus = j['statusNormalise'] as String?;

    // Déterminer statusNormalise : depuis Edge Function ou calculé
    final String status;
    if (rawStatus != null && rawStatus.isNotEmpty) {
      status = rawStatus;
    } else {
      if (code == 0)                         status = 'confirmed';
      else if (code == -200 || code == -9)   status = 'pending';
      else if (code == -8)                   status = 'expired';
      else if (code == -250)                 status = 'unknown';
      else                                   status = 'failed';
    }

    // ✅ FIX: lire ok depuis la réponse JSON (était toujours false avant)
    // Nécessaire pour estSucces lors de l'action 'statut' avec code=0/confirmed
    final isOk = j['ok'] == true || code == 0;

    return SycaPayResultat(
      code:            code,
      message:         j['message']     as String? ?? j['messageFr'] as String? ?? '',
      transactionId:   j['transactionId'] as String?
                    ?? j['transactionID'] as String?
                    ?? j['orderId']       as String?,
      numCommande:     j['numcommande'] as String? ?? numCommande,
      mobile:          j['mobile']     as String?,
      montant:         j['montant']    as String? ?? j['amount'] as String?,
      operateur:       j['operator']   as String?,
      statusNormalise: status,
      fromCache:       j['fromCache']  == true,
      dejaConfirme:    j['idempotent'] == true,
      ok:              isOk,
    );
  }

  // ── Message lisible en français ───────────────────────────────────────────

  String get messageFr {
    if (erreurReseau) return 'Connexion impossible. Vérifiez votre réseau et réessayez.';
    switch (statusNormalise) {
      case 'confirmed': return 'Paiement confirmé avec succès.';
      case 'pending':   return 'Paiement en attente de confirmation Mobile Money.';
      case 'expired':   return 'Session expirée. Veuillez réessayer.';
      case 'failed':    return _messageEchecParCode();
      default:          return 'Statut en cours de vérification…';
    }
  }

  String _messageEchecParCode() {
    switch (code) {
      case -1:   return 'Paiement échoué. Réessayez.';
      case -3:   return 'Solde insuffisant.';
      case -4:   return 'Service momentanément indisponible.';
      case -5:   return 'Code OTP incorrect ou expiré.';
      case -7:   return 'Numéro de téléphone ou OTP invalide.';
      case -14:  return 'Erreur d\'authentification SycaPay.';
      case -400: return 'Numéro de téléphone manquant.';
      case -500: return 'Accès non autorisé.';
      default:   return 'Échec du paiement (code $code). Contactez le support.';
    }
  }

  @override
  String toString() =>
      'SycaPayResultat(code=$code, status=$statusNormalise, ref=$numCommande, txId=$transactionId)';
}

// ── Parser résultat confirmer_et_crediter ─────────────────────────────────────

class _SycaPayResultatEtendu {
  static SycaPayResultat fromJsonV4(
    Map<String, dynamic> j, {
    String? numCommande,
  }) {
    if (j['erreur'] == true) {
      return SycaPayResultat(
        code:            (j['code'] as num?)?.toInt() ?? -999,
        message:         j['message'] as String? ?? 'Erreur inconnue',
        numCommande:     numCommande,
        erreurReseau:    true,
        statusNormalise: 'failed',
        ok:              false,
        timeout:         false,
      );
    }

    final code     = (j['code'] as num?)?.toInt() ?? -999;
    final rawStatus = j['statusNormalise'] as String?;
    final isOk     = j['ok'] == true || code == 0;
    final isTimeout = j['timeout'] == true;
    final isPending = j['pending'] == true
                   || rawStatus == 'pending'
                   || code == -200;

    final String status;
    if (rawStatus != null && rawStatus.isNotEmpty) {
      status = rawStatus;
    } else if (isOk)       { status = 'confirmed'; }
    else if (isPending)    { status = 'pending'; }
    else if (code == -8)   { status = 'expired'; }
    else                   { status = 'failed'; }

    return SycaPayResultat(
      code:            code,
      message:         j['message'] as String? ?? '',
      transactionId:   j['transactionId'] as String?,
      numCommande:     j['numcommande'] as String? ?? numCommande,
      statusNormalise: status,
      fromCache:       j['fromCache']  == true || j['fromWebhook'] == true,
      dejaConfirme:    j['idempotent'] == true,
      ok:              isOk,
      timeout:         isTimeout,
    );
  }
}

// ── Résultat de polling complet (enum conservé pour compatibilité) ─────────────

enum PollingStatus {
  confirmed,  // paiement confirmé → crédité côté serveur
  failed,     // paiement échoué définitivement
  expired,    // session expirée
  timeout,    // watchdog déclenché
  cancelled,  // annulé par l'utilisateur
}
