import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'supabase_service.dart';

/// Service Flutter pour les paiements Mobile Money via PayDunya (API PAR).
///
/// ⚠️  Clés JAMAIS dans Flutter — tous les appels passent via Edge Function.
///
/// Architecture :
///   Flutter → paydunya-payment (Edge Fn) → PayDunya API
///   IPN     → paydunya-ipn     (Edge Fn) → crédit RPC Supabase
///
/// Référence pivot : [numCommande] format TDP_CODE_MID_TS
///
/// Flux de paiement :
///   1. creerInvoice       → checkout_url + token (persist PENDING)
///   2. Utilisateur paie   → Page PayDunya (navigateur)
///   3. IPN automatique    → paydunya-ipn → crédit (voie principale)
///   4. verifierStatut     → polling Flutter (affichage statut)
///   5. confirmerEtCrediter → fallback si IPN non reçu (status=completed)
///
/// Opérateurs Mobile Money CI supportés :
///   orange-money-ci | wave-ci | mtn-ci | moov-ci | djamo-ci
class PayDunyaService {
  static const String _edgeFnPayment = 'paydunya-payment';

  // ── Appel Edge Function ───────────────────────────────────────────────────

  static Future<Map<String, dynamic>> _appelerEdge(
    Map<String, dynamic> payload, {
    Duration timeout = const Duration(seconds: 50),
  }) async {
    final url = Uri.parse(
      '${SupabaseService.supabaseUrl}/functions/v1/$_edgeFnPayment',
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
        debugPrint('[PayDunya] ${payload['action']} → HTTP ${resp.statusCode}');
      }

      if (resp.statusCode == 401 || resp.statusCode == 403) {
        throw PayDunyaException(
          'Authentification Edge Function échouée (${resp.statusCode}). '
          'Vérifiez SUPABASE_ANON_KEY.',
        );
      }

      final Map<String, dynamic> body = jsonDecode(resp.body);

      if (body['erreur'] == true) {
        throw PayDunyaException(
          body['message'] as String? ?? 'Erreur PayDunya inconnue',
        );
      }

      return body;

    } on TimeoutException {
      throw PayDunyaException('Délai dépassé (${timeout.inSeconds}s). Réessayez.');
    } on PayDunyaException {
      rethrow;
    } catch (e) {
      throw PayDunyaException('Erreur réseau: $e');
    }
  }

  // ── 1. Créer une invoice PayDunya (checkout Mobile Money) ─────────────────

  /// Crée une facture de paiement PayDunya.
  ///
  /// Retourne [PayDunyaResultat] avec [checkoutUrl] à ouvrir dans le navigateur.
  static Future<PayDunyaResultat> creerInvoice({
    required String tontineCode,
    required String typeOperation,  // cotisation | caisse | penalite | remboursement_pret | pret_octroye
    required int    montantXof,
    String? description,
    String? membreId,
    String? membreNom,
    String? membreEmail,
    String? telephone,
    String? pretId,
  }) async {
    final data = await _appelerEdge({
      'action':         'creer_invoice',
      'tontine_code':   tontineCode,
      'type_operation': typeOperation,
      'montant':        montantXof,
      if (description  != null) 'description':  description,
      if (membreId     != null) 'membre_id':     membreId,
      if (membreNom    != null) 'membre_nom':    membreNom,
      if (membreEmail  != null) 'membre_email':  membreEmail,
      if (telephone    != null) 'telephone':     telephone,
      if (pretId       != null) 'pret_id':       pretId,
    });

    return PayDunyaResultat(
      token:        data['token']        as String,
      checkoutUrl:  data['checkoutUrl']  as String,
      numCommande:  data['numcommande']  as String,
      status:       data['status']       as String? ?? 'pending',
      sandbox:      data['sandbox']      as bool?   ?? true,
      idempotent:   data['idempotent']   as bool?   ?? false,
    );
  }

  // ── 2. Vérifier le statut d'une invoice ──────────────────────────────────

  /// Vérifie le statut d'une invoice PayDunya.
  ///
  /// Retourne le statut : pending | completed | cancelled | failed
  static Future<PayDunyaStatut> verifierStatut({
    String? token,
    String? numCommande,
  }) async {
    assert(token != null || numCommande != null,
        'token ou numCommande requis');

    final data = await _appelerEdge({
      'action':      'statut',
      if (token       != null) 'token':       token,
      if (numCommande != null) 'numcommande': numCommande,
    });

    return PayDunyaStatut(
      ok:          data['ok']          as bool?   ?? false,
      status:      data['status']      as String? ?? 'pending',
      montant:     (data['montant']    as num?)?.toInt(),
      operateur:   data['operateur']   as String?,
      receiptUrl:  data['receiptUrl']  as String?,
      needsCredit: data['needsCredit'] as bool?   ?? false,
      numCommande: data['numcommande'] as String?,
      token:       data['token']       as String?,
      fromCache:   data['fromCache']   as bool?   ?? false,
    );
  }

  // ── 3. Confirmer et créditer ─────────────────────────────────────────────

  /// Vérifie le statut PayDunya ET crédite Supabase si completed.
  /// Idempotent : peut être appelé plusieurs fois sans double-crédit.
  static Future<PayDunyaStatut> confirmerEtCrediter({
    required String numCommande,
    required String tontineCode,
    required String typeOperation,
    String? membreNom,
    String? membreId,
    String? pretId,
    int?    montantXof,
  }) async {
    final data = await _appelerEdge({
      'action':         'confirmer_et_crediter',
      'numcommande':    numCommande,
      'tontine_code':   tontineCode,
      'type_operation': typeOperation,
      if (membreNom  != null) 'membre_nom':  membreNom,
      if (membreId   != null) 'membre_id':   membreId,
      if (pretId     != null) 'pret_id':     pretId,
      if (montantXof != null) 'montant':     montantXof,
    });

    return PayDunyaStatut(
      ok:          data['ok']     as bool?   ?? false,
      status:      data['status'] as String? ?? 'pending',
      numCommande: numCommande,
      fromCache:   data['fromCache'] as bool? ?? false,
    );
  }

  // ── 4. Vérifier une référence en DB ──────────────────────────────────────

  /// Lookup rapide en DB interne (sans appel PayDunya API).
  static Future<Map<String, dynamic>> verifierReference(
    String numCommande,
  ) async {
    return _appelerEdge({
      'action':      'verifier_ref',
      'numcommande': numCommande,
    });
  }

  // ── Polling automatique ───────────────────────────────────────────────────

  /// Lance un polling toutes les [intervalle] jusqu'à [timeout] ou paiement confirmé.
  ///
  /// Appelé par l'écran après que l'utilisateur a payé sur PayDunya.
  /// Déclenche [onStatutChange] à chaque changement, [onConfirme] si completed.
  static Future<void> pollerjusquaConfirmation({
    required String      numCommande,
    required String      tontineCode,
    required String      typeOperation,
    required String      token,
    String?              membreNom,
    String?              membreId,
    String?              pretId,
    int?                 montantXof,
    Duration             intervalle  = const Duration(seconds: 8),
    Duration             timeout     = const Duration(minutes: 15),
    void Function(PayDunyaStatut)? onStatutChange,
    void Function(PayDunyaStatut)? onConfirme,
    void Function(String)?         onEchec,
    void Function()?               onTimeout,
  }) async {
    final deadline = DateTime.now().add(timeout);
    int tentatives = 0;

    while (DateTime.now().isBefore(deadline)) {
      tentatives++;
      await Future<void>.delayed(intervalle);

      if (kDebugMode) debugPrint('[PayDunya] Polling #$tentatives ($numCommande)');

      try {
        final statut = await verifierStatut(
          numCommande: numCommande,
          token:       token,
        );

        onStatutChange?.call(statut);

        if (statut.ok || statut.needsCredit) {
          // Déclencher le crédit côté serveur
          final confirmation = await confirmerEtCrediter(
            numCommande:    numCommande,
            tontineCode:    tontineCode,
            typeOperation:  typeOperation,
            membreNom:      membreNom,
            membreId:       membreId,
            pretId:         pretId,
            montantXof:     montantXof,
          );
          onConfirme?.call(confirmation);
          return;
        }

        if (statut.status == 'cancelled' || statut.status == 'failed') {
          onEchec?.call('Paiement ${statut.status}.');
          return;
        }

      } catch (e) {
        if (kDebugMode) debugPrint('[PayDunya] Polling erreur #$tentatives: $e');
        // Continuer le polling malgré les erreurs réseau transitoires
      }
    }

    // Timeout
    onTimeout?.call();
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Modèles de données
// ─────────────────────────────────────────────────────────────────────────────

/// Résultat de la création d'une invoice PayDunya.
class PayDunyaResultat {
  final String token;
  final String checkoutUrl;
  final String numCommande;
  final String status;
  final bool   sandbox;
  final bool   idempotent;

  const PayDunyaResultat({
    required this.token,
    required this.checkoutUrl,
    required this.numCommande,
    required this.status,
    required this.sandbox,
    required this.idempotent,
  });

  bool get estSandbox => sandbox;
}

/// Statut d'une invoice PayDunya.
class PayDunyaStatut {
  final bool    ok;          // true si completed + crédité
  final String  status;      // pending | completed | cancelled | failed | credited
  final int?    montant;
  final String? operateur;   // orange-money-ci | wave-ci | mtn-ci | moov-ci ...
  final String? receiptUrl;
  final bool    needsCredit; // completed mais pas encore crédité → appeler confirmerEtCrediter
  final String? numCommande;
  final String? token;
  final bool    fromCache;   // réponse depuis DB (pas de re-vérification PayDunya)

  const PayDunyaStatut({
    required this.ok,
    required this.status,
    this.montant,
    this.operateur,
    this.receiptUrl,
    this.needsCredit = false,
    this.numCommande,
    this.token,
    this.fromCache   = false,
  });

  bool get enAttente     => status == 'pending';
  bool get confirme      => ok || status == 'completed' || status == 'credited';
  bool get annule        => status == 'cancelled';
  bool get echoue        => status == 'failed';
  bool get terminal      => confirme || annule || echoue;

  String get operateurLabel {
    const labels = {
      'orange-money-ci':      'Orange Money CI',
      'wave-ci':              'Wave CI',
      'mtn-ci':               'MTN Mobile Money CI',
      'moov-ci':              'Moov Money CI',
      'djamo-ci':             'Djamo CI',
      'orange-money-senegal': 'Orange Money SN',
      'wave-senegal':         'Wave SN',
      'mtn-cameroun':         'MTN Cameroun',
    };
    return labels[operateur] ?? (operateur ?? 'Mobile Money');
  }
}

/// Exception PayDunya.
class PayDunyaException implements Exception {
  final String message;
  const PayDunyaException(this.message);

  @override
  String toString() => 'PayDunyaException: $message';
}
