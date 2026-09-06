import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/tontine.dart';
import 'blockchain_service.dart';

class SupabaseService {
  // ═══════════════════════════════════════════════════════════════════════════
  // CREDENTIALS — lus depuis les variables de compilation (--dart-define).
  // En l'absence de variable, la valeur de secours (defaultValue) est utilisée.
  //
  // Pour le build web (Netlify) :
  //   flutter build web --release \
  //     --dart-define=SUPABASE_URL=$SUPABASE_URL \
  //     --dart-define=SUPABASE_ANON_KEY=$SUPABASE_ANON_KEY
  //
  // Pour un build local sans variables, les valeurs codées en dur prennent
  // le relais automatiquement — l'app reste fonctionnelle.
  // ═══════════════════════════════════════════════════════════════════════════
  static const String _url = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://ubrqtcxbxcmvmxleiglh.supabase.co',
  );
  static const String _key = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9'
        '.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InVicnF0Y3hieGNtdm14bGVpZ2xoIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODMyNzYwMzYsImV4cCI6MjA5ODg1MjAzNn0'
        '.GaCZwMG34cFcxR3lkLuq-7uMM7sQoc_VIqiDEzMgEq4',
  );

  // Accesseurs publics en lecture seule (pour le diagnostic dev)
  static String get supabaseUrl      => _url;
  static String get supabaseAnonKey  => _key;

  // ─────────────────────────────────────────────────────────────────────────
  // Couche HTTP RPC — fidèle à la fonction rpc() de index.html de référence.
  //
  // Headers IDENTIQUES à index.html (ni plus, ni moins) :
  //   Content-Type, apikey, Authorization
  // PAS de "Prefer: return=representation" — ce header modifie le format
  // de réponse de PostgREST et casse le parsing des fonctions RETURNS jsonb.
  //
  // Réponses possibles de PostgREST pour RETURNS jsonb / LANGUAGE sql :
  //   • corps vide   → null  (ex: lire_tontine avec code inconnu)
  //   • "null"       → null
  //   • {...}        → Map   (ex: lire_tontine avec code connu)
  //   • true/false   → bool  (ex: verifier_gestionnaire)
  //   • "OK"         → String (ex: voter)
  //   • [{...}]      → List  (ex: lire_voix_tontine retourne jsonb agrégé)
  // ─────────────────────────────────────────────────────────────────────────
  // Nombre de tentatives automatiques en cas d'échec réseau
  static const int _maxRetries = 3;
  // Délai entre chaque tentative (exponentiel : 1s, 2s, 4s)
  static const Duration _retryBase = Duration(seconds: 1);

  // ── Classifie toute exception réseau en code interne RESEAU:xxx ────────────
  static String _classifierErreurReseau(Object e, Object stack, String contexte) {
    final raw = e.toString();
    if (kDebugMode) {
      debugPrint('[RPC] ERREUR réseau — $contexte');
      debugPrint('[RPC]   type: ${e.runtimeType}');
      debugPrint('[RPC]   message: $raw');
      debugPrint('[RPC]   stack: $stack');
    }
    // Déjà classifié avec le corps SQL réel — propager tel quel
    if (raw.contains('SERVEUR:5') || raw.contains('SERVEUR:4')) {
      return raw.replaceFirst('Exception: ', '');
    }
    if (e is SocketException) {
      return 'RESEAU:INTERNET';
    }
    if (raw.contains('TimeoutException') || raw.contains('timed out')) {
      return 'RESEAU:TIMEOUT';
    }
    if (e is HandshakeException || raw.contains('HandshakeException') || raw.contains('CERTIFICATE')) {
      return 'RESEAU:SSL';
    }
    if (raw.contains('Failed host lookup') || raw.contains('No address associated')) {
      return 'RESEAU:DNS';
    }
    if (raw.contains('Connection refused') || raw.contains('ECONNREFUSED')) {
      return 'RESEAU:CONNEXION';
    }
    if (raw.contains('Invalid argument') || raw.contains('status code 0')) {
      return 'RESEAU:INTERNET';
    }
    return 'RESEAU:SERVEUR';
  }

  static Future<dynamic> rpc(String fn, Map<String, dynamic> args) async {
    final uri = Uri.parse('$_url/rest/v1/rpc/$fn');

    if (kDebugMode) {
      debugPrint('[RPC] → POST ${uri.toString()}');
      debugPrint('[RPC]   fn=$fn  args=$args');
    }

    http.Response? response;
    String? codeErreur;

    // ── Retry 3 fois avec backoff exponentiel (1s, 2s, 4s) ──────────────────
    for (int tentative = 1; tentative <= _maxRetries; tentative++) {
      try {
        response = await http
            .post(
              uri,
              headers: {
                'Content-Type': 'application/json',
                'apikey': _key,
                'Authorization': 'Bearer $_key',
              },
              body: jsonEncode(args),
            )
            .timeout(const Duration(seconds: 30));
        codeErreur = null;
        break;
      } catch (e, stack) {
        codeErreur = _classifierErreurReseau(e, stack, '$fn tentative $tentative/$_maxRetries');
        if (tentative < _maxRetries) {
          await Future.delayed(_retryBase * (1 << (tentative - 1)));
        }
      }
    }

    // Toutes tentatives épuisées → lever exception avec code interne
    if (codeErreur != null) {
      if (kDebugMode) debugPrint('[RPC] ✗ échec définitif $codeErreur pour $fn');
      throw Exception(codeErreur);
    }

    final resp = response!;

    if (kDebugMode) {
      debugPrint('[RPC] ← HTTP ${resp.statusCode} $fn');
      debugPrint('[RPC]   body=${resp.body.length > 300 ? '${resp.body.substring(0, 300)}...' : resp.body}');
    }

    // ── Status 0 = réponse jamais reçue ─────────────────────────────────────
    if (resp.statusCode == 0) {
      if (kDebugMode) debugPrint('[RPC] ✗ statusCode=0 pour $fn');
      throw Exception('RESEAU:INTERNET');
    }

    // ── Erreurs HTTP ─────────────────────────────────────────────────────────
    if (!_isOk(resp.statusCode)) {
      if (kDebugMode) debugPrint('[RPC] ✗ HTTP ${resp.statusCode} pour $fn: ${resp.body}');
      final txt = resp.body;
      if (resp.statusCode == 404 || txt.contains('Could not find the function')) {
        throw Exception(
            'SQL: la fonction "$fn" est introuvable dans la base. '
            'Exécutez les scripts supabase.sql → v2 → v3 → v4 → v5 dans Supabase › SQL Editor.');
      }
      if (resp.statusCode == 401 || resp.statusCode == 403) {
        throw Exception(
            'CLE: clé anon refusée (${resp.statusCode}). '
            'Vérifiez Settings › API › anon public dans votre projet Supabase.');
      }
      if (resp.statusCode >= 500) {
        // Extraire le message SQL réel pour faciliter le diagnostic
        String sqlMsg = txt;
        try {
          final j = jsonDecode(txt);
          sqlMsg = j['message'] as String? ?? j['hint'] as String? ?? j['details'] as String? ?? txt;
        } catch (_) {}
        if (kDebugMode) debugPrint('[RPC] ✗ SQL body: $sqlMsg');
        throw Exception('SERVEUR:${resp.statusCode}:$sqlMsg');
      }
      throw Exception('RESEAU:SERVEUR');
    }

    // ── Corps de la réponse ──────────────────────────────────────────────────
    final body = resp.body.trim();
    if (body.isEmpty || body == 'null') return null;

    // ── Décodage JSON ────────────────────────────────────────────────────────
    try {
      return jsonDecode(body);
    } catch (_) {
      return body;
    }
  }

  static bool _isOk(int statusCode) => statusCode >= 200 && statusCode < 300;

  // ─────────────────────────────────────────────────────────────────────────
  // Diagnostic : teste la connexion et retourne un rapport détaillé
  // ─────────────────────────────────────────────────────────────────────────
  // ⚠️  IMPORTANT : GET /rest/v1/ renvoie 401 avec une clé anon (comportement
  //     Supabase normal — cette route nécessite la clé service, pas anon).
  //     On utilise directement un appel RPC pour tester clé + fonctions SQL.
  // ─────────────────────────────────────────────────────────────────────────
  static Future<DiagnosticResult> diagnostiquer() async {
    const url = _url;

    // Test unique : appel RPC lire_tontine avec un code bidon.
    // • Si HTTP 200 / null retourné   → clé OK + SQL initialisé ✅
    // • Si PGRST202 (fonction absente) → clé OK mais SQL manquant ⚠️
    // • Si erreur réseau / timeout    → projet inaccessible ❌
    // • Si 401/403                    → clé invalide ❌
    bool connecte = false;
    bool sqlOk = false;
    String message = '';

    try {
      await rpc('lire_tontine', {'p_code': 'XXXXXX'});
      // null retourné = fonction existe, code bidon simplement absent → tout OK
      connecte = true;
      sqlOk = true;
      message = 'Connexion OK — projet opérationnel.';
    } catch (e) {
      final msg = e.toString();
      if (msg.contains('PGRST202') || msg.contains('introuvable') || msg.contains('no matches')) {
        // Clé OK mais fonctions SQL absentes
        connecte = true;
        sqlOk = false;
        message = 'Connexion OK mais scripts SQL manquants.\n'
            'Exécutez supabase.sql → v2 → v3 → v4 → v5 dans Supabase › SQL Editor.';
      } else if (msg.contains('401') || msg.contains('403') || msg.contains('anon')) {
        connecte = false;
        sqlOk = false;
        message = 'Clé anon invalide. Vérifiez dans Supabase → Settings → API.';
      } else {
        // Erreur réseau, timeout, DNS…
        connecte = false;
        sqlOk = false;
        message = 'Impossible de joindre Supabase.\nVérifiez votre connexion internet.';
      }
    }

    return DiagnosticResult(
      connecte: connecte,
      sqlInitialise: sqlOk,
      message: message,
      details: {'url': url},
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // TONTINES
  // ═══════════════════════════════════════════════════════════════════════════

  static Future<Tontine> lireTontine(String code) async {
    final result = await rpc('lire_tontine', {'p_code': code.toUpperCase()});

    // Supabase retourne null quand la tontine n'existe pas
    if (result == null) {
      throw Exception('CODE_INTROUVABLE');
    }

    // Désérialisation robuste : accepte Map, String JSON, ou List[Map]
    Map<String, dynamic> rawData;
    if (result is Map<String, dynamic>) {
      rawData = result;
    } else if (result is String) {
      rawData = jsonDecode(result) as Map<String, dynamic>;
    } else if (result is List && result.isNotEmpty) {
      rawData = result[0] as Map<String, dynamic>;
    } else {
      throw Exception('CODE_INTROUVABLE');
    }

    // ── Soft delete : tontine supprimée ──────────────────────────────────────
    // La RPC lire_tontine (v16) retourne {__deleted__: true} si status=deleted
    if (rawData['__deleted__'] == true) {
      throw Exception('TONTINE_DELETED');
    }

    // Extraire les métadonnées soft-delete injectées par la RPC
    final status = rawData['__status__'] as String? ?? 'active';
    final invitationActive = rawData['__invitation_code_active__'] as bool? ?? true;
    // Nettoyer avant désérialisation TontineData
    rawData.remove('__status__');
    rawData.remove('__invitation_code_active__');

    final tData = TontineData.fromJson(rawData);

    // Lire le plan d'abonnement (v5+) — optionnel
    String plan = 'free';
    DateTime? planExpire;
    try {
      final planResult = await rpc('lire_plan', {'p_code': code.toUpperCase()});
      if (planResult is Map<String, dynamic>) {
        plan = (planResult['plan'] as String?) ?? 'free';
        final expireStr = planResult['expire'] as String?;
        if (expireStr != null) planExpire = DateTime.tryParse(expireStr);
      }
    } catch (_) {
      // lire_plan absent (v4 ou moins) → plan gratuit par défaut
    }

    return Tontine(
      code: code.toUpperCase(),
      data: tData,
      plan: plan,
      planExpire: planExpire,
      status: status,
      invitationCodeActive: invitationActive,
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // SOFT DELETE — Suppression logique d'une tontine
  // ═══════════════════════════════════════════════════════════════════════════

  /// Supprime logiquement une tontine (soft delete).
  /// Requiert PIN gestionnaire + motif + confirmation du nom exact.
  /// Retourne {ok: bool, message?: String, erreur?: String}
  static Future<Map<String, dynamic>> supprimerTontine({
    required String code,
    required String nom,
    required String pin,
    required String raison,
    required String nomConfirmation,
  }) async {
    final result = await rpc('delete_tontine', {
      'p_code':             code.toUpperCase(),
      'p_nom':              nom,
      'p_pin':              pin,
      'p_raison':           raison,
      'p_nom_confirmation': nomConfirmation,
    });
    if (result is Map<String, dynamic>) return result;
    return {'ok': false, 'erreur': 'Réponse inattendue du serveur.'};
  }

  /// Vérifie si un code d'invitation est valide (côté serveur).
  ///
  /// IMPORTANT : comportement PESSIMISTE.
  /// Si la RPC check_invitation_code (v17) n'existe pas encore (404/PGRST202),
  /// on retourne ok:true (la barrière 2 = lireTontine prendra le relais).
  /// Si la RPC existe mais retourne une erreur HTTP, on retourne ok:false.
  ///
  /// Codes d'erreur possibles : TONTINE_DELETED, INVITATION_INACTIVE,
  ///   CODE_INTROUVABLE, TONTINE_SUSPENDED.
  ///
  /// Retourne {ok: bool, erreur?: String, message?: String, nom?: String}
  static Future<Map<String, dynamic>> verifierCodeInvitation(String code) async {
    try {
      final result = await rpc('check_invitation_code', {'p_code': code.toUpperCase()});
      if (result is Map<String, dynamic>) return result;
      // Réponse null ou inattendue : laisser passer à lireTontine (barrière 2)
      return {'ok': true};
    } on Exception catch (e) {
      final msg = e.toString();
      // RPC introuvable (migration v16/v17 non exécutée) → laisser lireTontine décider
      if (msg.contains('PGRST202') ||
          msg.contains('introuvable') ||
          msg.contains('Could not find')) {
        return {'ok': true}; // Fallback : lireTontine prend le relais
      }
      // Autre erreur réseau/serveur → propager
      rethrow;
    }
  }

  /// Restaure une tontine supprimée (Super Admin uniquement).
  /// Retourne {ok: bool, message?: String, erreur?: String}
  static Future<Map<String, dynamic>> restaurerTontine({
    required String cle,
    required String code,
    required String motif,
  }) async {
    final result = await rpc('restore_deleted_tontine', {
      'p_cle':   cle,
      'p_code':  code.toUpperCase(),
      'p_motif': motif,
    });
    if (result is Map<String, dynamic>) return result;
    return {'ok': false, 'erreur': 'Réponse inattendue du serveur.'};
  }

  static Future<String> creerTontine({
    required String code,
    required List<Map<String, dynamic>> gestionnaires,
    required Map<String, dynamic> data,
  }) async {
    final result = await rpc('creer_tontine', {
      'p_code': code.toUpperCase(),
      'p_gestionnaires': gestionnaires,
      'p_data': data,
    });
    if (result == false || result == null) {
      throw Exception('Impossible de créer la tontine. Le code est peut-être déjà pris.');
    }
    return code.toUpperCase();
  }

  static Future<bool> verifierGestionnaire({
    required String code,
    required String nom,
    required String pin,
  }) async {
    final result = await rpc('verifier_gestionnaire', {
      'p_code': code.toUpperCase(),
      'p_nom': nom,
      'p_pin': pin,
    });
    // Supabase peut retourner : true (bool), "true" (String), 1 (int), ou null.
    // L'ancien `result == true` échoue pour String/int → PIN toujours "incorrect".
    // On normalise comme ecrireTontine() :
    if (result == null) return false;          // null = non trouvé / erreur
    if (result is bool) return result;          // true/false direct
    if (result is int) return result != 0;      // 1 = ok, 0 = ko
    if (result is String) return result.toLowerCase() == 'true'; // "true"/"false"
    if (result is Map<String, dynamic>) {
      // {ok: true} ou {verified: true} selon version RPC
      final v = result['ok'] ?? result['verified'] ?? result['result'];
      if (v is bool) return v;
      if (v is int) return v != 0;
      if (v is String) return v.toLowerCase() == 'true';
    }
    return false; // type inattendu → refus par sécurité
  }

  static Future<bool> ecrireTontine({
    required String code,
    required String nom,
    required String pin,
    required Map<String, dynamic> data,
  }) async {
    final result = await rpc('ecrire_tontine', {
      'p_code': code.toUpperCase(),
      'p_nom': nom,
      'p_pin': pin,
      'p_data': data,
    });
    // Supabase peut retourner : true (bool), "true" (String), 1 (int), ou null.
    // On normalise tous les cas positifs → true, comme ecrireTontineSansPIN.
    // null sans exception = void SQL return = succès
    if (result == null) return true;
    if (result is bool) return result;
    if (result is int) return result != 0;
    if (result is String) return result.toLowerCase() == 'true';
    // Map {ok: true} — certaines versions de la RPC retournent un objet
    if (result is Map<String, dynamic>) return result['ok'] == true;
    return true; // tout autre type non-null = succès
  }

  /// Écrit les données d'une tontine SANS vérification de PIN gestionnaire.
  /// Utilisé après confirmation de paiement (cotisations + caisse).
  ///
  /// Nécessite que la fonction SQL `ecrire_tontine_sans_pin` soit créée
  /// dans Supabase.
  ///
  /// Le retour de Supabase peut être : true (bool), "true" (string),
  /// 1 (int), ou null si la fonction est introuvable.
  static Future<bool> ecrireTontineSansPIN({
    required String code,
    required Map<String, dynamic> data,
    // Paramètres optionnels pour l'ancrage blockchain (cotisation/apport)
    String?  membreId,
    String?  membreNom,
    int?     montantXof,
    String?  devise,                  // devise réelle de la tontine — passer toujours
    String?  typeOperationBlockchain, // 'cotisation' | 'apport' | null
    String?  refInterne,
  }) async {
    try {
      final result = await rpc('ecrire_tontine_sans_pin', {
        'p_code': code.toUpperCase(),
        'p_data': data,
      });

      if (kDebugMode) {
        debugPrint('[Paiement] ecrire_tontine_sans_pin → result=$result (${result.runtimeType})');
      }

      // Supabase retourne void → HTTP body vide → rpc() retourne null.
      // null sans exception = succès (la fonction SQL a retourné VOID = OK).
      bool ok = true; // défaut : pas d'exception lancée = succès
      if (result == null) {
        ok = true;   // void SQL return = succès garanti
      } else if (result is bool) {
        ok = result;
      } else if (result is int) {
        ok = result != 0;
      } else if (result is String) {
        ok = result.toLowerCase() == 'true';
      } else if (result is Map<String, dynamic>) {
        ok = result['ok'] == true;
      }

      // ── BLOCKCHAIN : ancrage cotisation/apport après succès (non-bloquant) ─
      if (ok && typeOperationBlockchain != null && membreId != null && montantXof != null) {
        final fn = typeOperationBlockchain == 'apport'
            ? BlockchainService.enregistrerApport(
                tontineCode    : code.toUpperCase(),
                membreId       : membreId,
                membreNom      : membreNom ?? '',
                montantXof     : montantXof,
                devise         : devise,
                refInterne     : refInterne,
              )
            : BlockchainService.enregistrerCotisation(
                tontineCode    : code.toUpperCase(),
                membreId       : membreId,
                membreNom      : membreNom ?? '',
                montantXof     : montantXof,
                devise         : devise,
                refInterne     : refInterne,
              );
        fn.catchError((e) {
          if (kDebugMode) debugPrint('[Blockchain] ecrireTontineSansPIN hook erreur: $e');
          return BlockchainResultat(ok: false, erreur: '$e', phase: 1);
        });
      }
      // ─────────────────────────────────────────────────────────────────────

      return ok;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[Paiement] ecrire_tontine_sans_pin ERREUR: $e');
      }
      rethrow;
    }
  }

  // supprimerTontine (soft delete) est défini plus haut — ancienne version supprimée

  // ═══════════════════════════════════════════════════════════════════════════
  // VOTES
  // ═══════════════════════════════════════════════════════════════════════════

  static Future<List<Map<String, dynamic>>> lireVoix(String code) async {
    final result = await rpc('lire_voix_tontine', {'p_code': code.toUpperCase()});
    if (result == null) return [];
    if (result is List) return result.cast<Map<String, dynamic>>();
    return [];
  }

  static Future<String> voter({
    required String code,
    required String voteId,
    required String membreId,
    required String pinMembre,
    required String choix,
    required String appareil,
  }) async {
    final result = await rpc('voter', {
      'p_code':       code.toUpperCase(),
      'p_vote_id':    voteId,
      'p_membre_id':  membreId,
      'p_pin_membre': pinMembre,
      'p_choix':      choix,
      'p_appareil':   appareil,
    });
    return result?.toString() ?? 'ERREUR';
  }

  static Future<List<String>> membresAvecPin(String code) async {
    final result = await rpc('membres_avec_pin', {'p_code': code.toUpperCase()});
    if (result == null) return [];
    if (result is List) return result.map((e) => e.toString()).toList();
    return [];
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // PINS MEMBRES
  // ═══════════════════════════════════════════════════════════════════════════

  static Future<bool> definirPinMembre({
    required String code,
    required String membreId,
    required String gestNom,
    required String gestPin,
    required String nouveauPin,
  }) async {
    final result = await rpc('definir_pin_membre', {
      'p_code':        code.toUpperCase(),
      'p_nom':         gestNom,
      'p_pin':         gestPin,
      'p_membre_id':   membreId,
      'p_pin_membre':  nouveauPin,
    });
    return result == true;
  }

  static Future<bool> changerPinMembre({
    required String code,
    required String membreId,
    required String ancienPin,
    required String nouveauPin,
  }) async {
    final result = await rpc('changer_pin_membre', {
      'p_code':       code.toUpperCase(),
      'p_membre_id':  membreId,
      'p_ancien':     ancienPin,
      'p_nouveau':    nouveauPin,
    });
    return result == true;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // SCORE DE CONFIANCE IA
  // ═══════════════════════════════════════════════════════════════════════════

  /// Modifie manuellement le score d'un membre (admin uniquement).
  ///
  /// Cette RPC est atomique : elle écrit en une seule transaction
  ///   • scoreOverride dans tontines.data.membres[] (pour persistance)
  ///   • scores_historique (pour l'onglet Historique)
  ///   • journal_audit (pour traçabilité admin)
  ///
  /// Retourne {ok: bool, ancien: int, nouveau: int, message: String}
  static Future<Map<String, dynamic>> modifierScoreMembre({
    required String code,
    required String nom,
    required String pin,
    required String membreId,
    required int nouveau,
    required String motif,
  }) async {
    final result = await rpc('modifier_score_membre', {
      'p_code':      code.toUpperCase(),
      'p_nom':       nom,
      'p_pin':       pin,
      'p_membre_id': membreId,
      'p_nouveau':   nouveau,
      'p_motif':     motif,
    });
    if (result is Map<String, dynamic>) return result;
    return {'ok': false, 'message': 'Réponse inattendue du serveur.'};
  }

  /// Lit le score effectif d'un membre (scoreOverride en priorité).
  static Future<Map<String, dynamic>?> lireScoreMembre({
    required String code,
    required String membreId,
  }) async {
    try {
      final result = await rpc('lire_score_membre', {
        'p_code':      code.toUpperCase(),
        'p_membre_id': membreId,
      });
      if (result is Map<String, dynamic>) return result;
    } catch (_) {}
    return null;
  }

  /// Supprime l'override et laisse ScoreService recalculer librement.
  static Future<bool> reinitialiserScoreOverride({
    required String code,
    required String nom,
    required String pin,
    required String membreId,
  }) async {
    final result = await rpc('reinitialiser_score_override', {
      'p_code':      code.toUpperCase(),
      'p_nom':       nom,
      'p_pin':       pin,
      'p_membre_id': membreId,
    });
    return result == true;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // PREMIUM / ABONNEMENT
  // ═══════════════════════════════════════════════════════════════════════════

  static Future<Map<String, dynamic>> lirePlan(String code) async {
    try {
      final result = await rpc('lire_plan', {'p_code': code.toUpperCase()});
      if (result == null) return {'plan': 'free', 'expire': null};
      if (result is Map<String, dynamic>) return result;
    } catch (_) {}
    return {'plan': 'free', 'expire': null};
  }

  /// Envoie une demande d'activation Premium (Web uniquement).
  ///
  /// [code]    : code de la tontine
  /// [nom]     : nom complet du demandeur
  /// [contact] : WhatsApp ou email
  /// [formule] : 'mensuel' (2 500 FCFA) | 'annuel' (25 000 FCFA)
  /// [pin]     : ignoré — conservé pour compatibilité signature existante
  ///
  /// Anti-doublon géré côté SQL : si une demande 'en_attente' existe déjà
  /// pour ce code, la fonction retourne true sans insérer de doublon.
  static Future<bool> demanderPremium({
    required String code,
    required String nom,
    required String contact,
    String formule = 'mensuel',
    String pin     = '0000',   // ignoré côté SQL, garde compat signature
  }) async {
    final result = await rpc('demander_premium', {
      'p_code':      code.toUpperCase(),
      'p_nom':       nom,
      'p_contact':   contact,
      'p_formule':   formule,
      'p_pin':       pin,
      'p_plateforme': 'web',
    });
    return result == true;
  }

  /// Lire les demandes Premium en attente — liste complète pour l'admin.
  ///
  /// Retourne une liste de maps avec les champs :
  ///   id, code, statut, gestionnaire, nom, contact, formule, montant,
  ///   plateforme, motif_refus, traite_par, traite_le, quand,
  ///   nom_tontine, nb_membres
  static Future<List<Map<String, dynamic>>> adminListerDemandesPremium(String cle) async {
    final result = await rpc('admin_lister_demandes', {'p_cle': cle});
    if (result == null) return [];
    // admin_lister_demandes retourne jsonb (= objet/liste directement)
    if (result is List) return result.cast<Map<String, dynamic>>();
    return [];
  }

  /// Refuser une demande Premium avec motif obligatoire (v12).
  ///
  /// [cle]   : clé admin
  /// [code]  : code tontine
  /// [motif] : raison du refus (ex: 'Coordonnées invalides')
  static Future<bool> adminRefuserDemande({
    required String cle,
    required String code,
    String motif = '',
  }) async {
    final result = await rpc('admin_refuser_demande', {
      'p_cle':   cle,
      'p_code':  code.toUpperCase(),
      'p_motif': motif,
    });
    return result == true;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // ADMIN
  // ═══════════════════════════════════════════════════════════════════════════

  /// Alias de [adminListerDemandesPremium] — conservé pour compatibilité.
  static Future<List<Map<String, dynamic>>> adminListerDemandes(String cle) async {
    return adminListerDemandesPremium(cle);
  }

  static Future<List<Map<String, dynamic>>> adminListerTontines(String cle) async {
    // Essayer d'abord admin_lister_tontines (RPC v1)
    try {
      final result = await rpc('admin_lister_tontines', {'p_cle': cle});
      if (result is List && result.isNotEmpty) {
        return result.cast<Map<String, dynamic>>();
      }
    } catch (_) {
      // RPC absente ou erreur → fallback sur admin_dashboard_tontines
    }
    // Fallback : admin_dashboard_tontines (RPC v2, plus récente)
    try {
      final result = await rpc('admin_dashboard_tontines', {
        'p_cle':    cle,
        'p_filtre': 'toutes',
        'p_limit':  500,
        'p_offset': 0,
      });
      if (result is List) return result.cast<Map<String, dynamic>>();
    } catch (_) {
      // Aucune RPC disponible
    }
    return [];
  }

  /// Récupère les soldes réels des caisses depuis Supabase pour toutes les tontines.
  /// Retourne une Map<code, soldeCaisse> calculée depuis data->caisse de chaque tontine.
  /// Utilisée par AdminSoldesScreen pour comparer solde blockchain vs solde réel.
  static Future<Map<String, int>> adminSoldesCaisses(String cle) async {
    final Map<String, int> soldes = {};
    try {
      // Récupérer toutes les tontines actives avec leur data JSON
      final tontines = await adminListerTontines(cle);
      for (final t in tontines) {
        final code = t['code'] as String? ?? '';
        if (code.isEmpty) continue;
        // Le solde peut être pré-calculé dans la liste admin si disponible
        final soldePrecalcule = t['solde_caisse'] as int?
            ?? t['soldeCaisse'] as int?;
        if (soldePrecalcule != null) {
          soldes[code] = soldePrecalcule;
          continue;
        }
        // Sinon lire la tontine complète
        try {
          final tontine = await lireTontine(code);
          soldes[code] = tontine.data.soldeCaisse;
        } catch (_) {
          // Tontine inaccessible : ignorer
        }
      }
    } catch (_) {}
    return soldes;
  }

  /// Compteurs unifiés pour l'Admin (v17).
  /// Retourne {total, actives, premium, gratuites, inactives, expirees,
  ///           suspendues, supprimees, demandes_en_attente}
  /// Fallback : calcul local depuis adminListerTontines si RPC absente.
  static Future<Map<String, dynamic>> adminTontineCounts(String cle) async {
    // Calcul local depuis la liste des tontines (robuste, pas de dépendance RPC)
    Map<String, dynamic> calculerLocalement(List<Map<String, dynamic>> tontines) {
      int actives = 0, premium = 0, gratuites = 0;
      int inactives = 0, suspendues = 0, supprimees = 0, expirees = 0;
      final now = DateTime.now();
      for (final t in tontines) {
        final st = (t['status'] as String? ?? 'active');
        if (st == 'deleted')   { supprimees++; continue; }
        if (st == 'suspended') { suspendues++; continue; }
        if (st == 'inactive')  { inactives++;  continue; }
        actives++;
        final isPrem = (t['plan'] as String? ?? '') == 'premium';
        final expStr = t['plan_expire'] as String? ?? t['expire'] as String?;
        final exp    = expStr != null ? DateTime.tryParse(expStr) : null;
        if (isPrem && exp != null && exp.isBefore(now)) {
          expirees++; premium--; actives--;
        } else if (isPrem) {
          premium++;
        } else {
          gratuites++;
        }
      }
      final nonSupp = tontines.length - supprimees;
      return {
        'total':               nonSupp,
        'actives':             actives,
        'premium':             premium,
        'gratuites':           gratuites,
        'inactives':           inactives,
        'suspendues':          suspendues,
        'expirees':            expirees,
        'supprimees':          supprimees,
        'demandes_en_attente': 0,
      };
    }

    try {
      final result = await rpc('admin_tontine_counts', {'p_cle': cle});
      // RPC peut retourner Map directement ou List<Map> selon version Supabase
      Map<String, dynamic>? fromRpc;
      if (result is Map<String, dynamic> && result.isNotEmpty) {
        fromRpc = result;
      } else if (result is List && result.isNotEmpty && result.first is Map<String, dynamic>) {
        fromRpc = result.first as Map<String, dynamic>;
      }
      // Valider que la RPC retourne un total cohérent (> 0)
      // Si total == 0 la RPC est probablement non déployée ou mal configurée
      if (fromRpc != null) {
        final total = (fromRpc['total'] as num?)?.toInt() ?? 0;
        if (total > 0) return fromRpc;
      }
      // Fallback systématique : calcul local depuis la liste des tontines
      final tontines = await adminListerTontines(cle);
      return calculerLocalement(tontines);
    } on Exception catch (e) {
      final msg = e.toString();
      if (msg.contains('PGRST202') ||
          msg.contains('Could not find') ||
          msg.contains('introuvable') ||
          msg.contains('function') ||
          msg.contains('does not exist')) {
        final tontines = await adminListerTontines(cle);
        return calculerLocalement(tontines);
      }
      return {};
    }
  }

  /// Active le Premium pour une tontine et met à jour premium_requests (v12).
  ///
  /// Met à jour :
  ///   • tontines.plan = 'premium' + tontines.plan_expire
  ///   • premium_requests.status = 'approuvee'
  static Future<bool> adminActiverPremium({
    required String cle,
    required String code,
    required int mois,
  }) async {
    final result = await rpc('admin_activer_premium', {
      'p_cle':  cle,
      'p_code': code.toUpperCase(),
      'p_mois': mois,
    });
    return result == true;
  }

  static Future<bool> adminDesactiverPremium({
    required String cle,
    required String code,
  }) async {
    final result = await rpc('admin_desactiver_premium', {
      'p_cle':  cle,
      'p_code': code.toUpperCase(),
    });
    return result == true;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // ADMIN DASHBOARD — RPCs v1 (supabase-admin.sql)
  // ═══════════════════════════════════════════════════════════════════════════

  /// KPI cards : total tontines, Premium, Gratuites, membres, revenus, alertes
  static Future<Map<String, dynamic>> adminStatsGlobales(String cle) async {
    final result = await rpc('admin_stats_globales', {'p_cle': cle});
    if (result == null) return {};
    if (result is Map<String, dynamic>) return result;
    return {};
  }

  /// Tableau des tontines (filtre: toutes|premium|gratuites|expires)
  static Future<List<Map<String, dynamic>>> adminDashboardTontines(
    String cle, {
    String filtre = 'toutes',
    int limit = 100,
    int offset = 0,
  }) async {
    final result = await rpc('admin_dashboard_tontines', {
      'p_cle':    cle,
      'p_filtre': filtre,
      'p_limit':  limit,
      'p_offset': offset,
    });
    if (result == null) return [];
    if (result is List) return result.cast<Map<String, dynamic>>();
    return [];
  }

  /// Liste des abonnements (statut: tous|actif|expire|en_attente)
  static Future<List<Map<String, dynamic>>> adminListerAbonnements(
    String cle, {
    String statut = 'tous',
    int limit = 50,
  }) async {
    final result = await rpc('admin_lister_abonnements', {
      'p_cle':    cle,
      'p_statut': statut,
      'p_limit':  limit,
    });
    if (result == null) return [];
    if (result is List) return result.cast<Map<String, dynamic>>();
    return [];
  }

  /// Alertes admin (expirations, demandes en attente, inactivité)
  static Future<List<Map<String, dynamic>>> adminAlertes(String cle) async {
    final result = await rpc('admin_alertes', {'p_cle': cle});
    if (result == null) return [];
    if (result is List) return result.cast<Map<String, dynamic>>();
    return [];
  }

  /// Enregistrer un abonnement Premium lors de l'activation
  static Future<bool> adminEnregistrerAbonnement({
    required String cle,
    required String code,
    String formule = 'mensuel',
    int montant = 2500,
    String? moyen,
    String? reference,
    String? note,
  }) async {
    final result = await rpc('admin_enregistrer_abonnement', {
      'p_cle':       cle,
      'p_code':      code.toUpperCase(),
      'p_formule':   formule,
      'p_montant':   montant,
      if (moyen != null)     'p_moyen':     moyen,
      if (reference != null) 'p_reference': reference,
      if (note != null)      'p_note':      note,
    });
    return result == true;
  }

  /// Évolution mensuelle : nouvelles tontines, Premium actives, revenus (12 mois)
  static Future<List<Map<String, dynamic>>> adminStatsMensuelles(String cle) async {
    final result = await rpc('admin_stats_mensuelles', {'p_cle': cle});
    if (result == null) return [];
    if (result is List) return result.cast<Map<String, dynamic>>();
    return [];
  }

  /// Top 10 tontines par nombre de membres
  static Future<List<Map<String, dynamic>>> adminTopTontines(String cle) async {
    final result = await rpc('admin_top_tontines', {'p_cle': cle});
    if (result == null) return [];
    if (result is List) return result.cast<Map<String, dynamic>>();
    return [];
  }

  // ── Gestion des échéances ─────────────────────────────────────────────────

  /// Met à jour l'échéance d'une tontine dans Supabase.
  ///
  /// [code]     : code de la tontine (ex: 'A1B2C3')
  /// [nom]      : nom du gestionnaire (pour authentification)
  /// [pin]      : PIN du gestionnaire
  /// [echeance] : nouvelle date au format ISO 8601 (ex: '2024-12-31T00:00:00.000Z')
  ///              Passer null ou '' pour effacer l'échéance.
  ///
  /// Retourne true si la mise à jour a réussi.
  static Future<bool> majEcheance({
    required String code,
    required String nom,
    required String pin,
    required String echeance,
  }) async {
    final result = await rpc('maj_echeance', {
      'p_code':     code.toUpperCase(),
      'p_nom':      nom,
      'p_pin':      pin,
      'p_echeance': echeance,
    });
    return result == true;
  }

  /// Lit uniquement la config (periodicite + echeance) d'une tontine.
  /// Utile pour rafraîchir les paramètres sans recharger toute la tontine.
  static Future<Map<String, dynamic>?> lireConfigTontine(String code) async {
    final result = await rpc('lire_config_tontine', {
      'p_code': code.toUpperCase(),
    });
    if (result is Map<String, dynamic>) return result;
    return null;
  }

  /// Recalcule les échéances passées pour toutes les tontines actives.
  /// Appel admin — retourne un résumé des mises à jour.
  static Future<Map<String, dynamic>?> recalculerEcheancesExpir() async {
    final result = await rpc('recalculer_echeances_expir', {});
    if (result is Map<String, dynamic>) return result;
    return null;
  }

  // ══════════════════════════════════════════════════════════════════════════
  // NOUVEAU CYCLE
  // ══════════════════════════════════════════════════════════════════════════

  /// Propose un nouveau cycle en créant un vote de redémarrage.
  ///
  /// Prérequis : cycleTermine == true, aucun vote ouvert de type 'nouveau_cycle'.
  /// Retourne {ok: bool, vote_id?: String, erreur?: String}
  static Future<Map<String, dynamic>> proposerNouveauCycle({
    required String code,
    required String nom,
    required String pin,
    String question = 'Souhaitez-vous recommencer un nouveau cycle de tontine ?',
  }) async {
    final result = await rpc('proposer_nouveau_cycle', {
      'p_code':     code.toUpperCase(),
      'p_nom':      nom,
      'p_pin':      pin,
      'p_question': question,
    });
    if (result is Map<String, dynamic>) return result;
    return {'ok': false, 'erreur': 'Réponse inattendue du serveur.'};
  }

  /// Lit l'état du cycle courant + le vote de redémarrage s'il existe.
  ///
  /// Retourne : cycleTermine, cycleNum, tourActuel, nbMembres, nbTours,
  ///            voteRedemarrage (objet vote complet), peutProposer
  static Future<Map<String, dynamic>?> lireEtatCycle(String code) async {
    final result = await rpc('lire_etat_cycle', {
      'p_code': code.toUpperCase(),
    });
    if (result is Map<String, dynamic>) return result;
    return null;
  }

  /// Démarre le nouveau cycle après un vote favorable.
  ///
  /// [voteId]      : ID du vote 'nouveau_cycle' clos et adopté
  /// [montant]     : nouveau montant (null = conserver l'ancien)
  /// [periodicite] : nouvelle périodicité (null = conserver l'ancienne)
  /// [echeance]    : 1ère échéance ISO 8601 (null = calculer auto)
  /// [methodeOrdre]: méthode d'ordre (null = conserver l'ancienne)
  ///
  /// Retourne {ok: bool, cycleNum?: int, message?: String, erreur?: String}
  static Future<Map<String, dynamic>> demarrerNouveauCycle({
    required String code,
    required String nom,
    required String pin,
    required String voteId,
    int? montant,
    String? periodicite,
    String? echeance,
    String? methodeOrdre,
  }) async {
    final params = <String, dynamic>{
      'p_code':     code.toUpperCase(),
      'p_nom':      nom,
      'p_pin':      pin,
      'p_vote_id':  voteId,
    };
    if (montant != null)      params['p_montant']       = montant;
    if (periodicite != null)  params['p_periodicite']   = periodicite;
    if (echeance != null)     params['p_echeance']      = echeance;
    if (methodeOrdre != null) params['p_methode_ordre'] = methodeOrdre;

    final result = await rpc('demarrer_nouveau_cycle', params);
    if (result is Map<String, dynamic>) return result;
    return {'ok': false, 'erreur': 'Réponse inattendue du serveur.'};
  }

  /// Clôture le vote de redémarrage et calcule le résultat.
  ///
  /// Retourne {ok: bool, adopte: bool, oui: int, non: int, abstention: int, message: String}
  static Future<Map<String, dynamic>> cloreVoteRedemarrage({
    required String code,
    required String nom,
    required String pin,
    required String voteId,
  }) async {
    final result = await rpc('clore_vote_redemarrage', {
      'p_code':    code.toUpperCase(),
      'p_nom':     nom,
      'p_pin':     pin,
      'p_vote_id': voteId,
    });
    if (result is Map<String, dynamic>) return result;
    return {'ok': false, 'erreur': 'Réponse inattendue du serveur.'};
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // NOTIFICATIONS FCM
  // ═══════════════════════════════════════════════════════════════════════════

  /// Enregistre le token FCM d'un appareil pour une tontine donnée.
  /// Appelée au démarrage de l'app pour chaque tontine enregistrée.
  static Future<void> sauvegarderTokenFCM({
    required String code,
    required String token,
  }) async {
    try {
      // Détecter la plateforme réelle — ne jamais hardcoder 'android' sur iOS
      final String plateforme;
      if (kIsWeb) {
        plateforme = 'web';
      } else if (Platform.isIOS) {
        plateforme = 'ios';
      } else if (Platform.isAndroid) {
        plateforme = 'android';
      } else {
        plateforme = 'android'; // fallback desktop
      }

      await rpc('sauvegarder_token', {
        'p_code':     code.toUpperCase(),
        'p_token':    token,
        'p_appareil': plateforme,
      });
    } catch (_) {
      // Silencieux — non bloquant
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // LANGUE UTILISATEUR
  // ═══════════════════════════════════════════════════════════════════════════

  /// Sauvegarde la langue préférée de l'utilisateur dans Supabase.
  /// Clé SharedPreferences utilisée comme identifiant appareil.
  /// Silencieux — SharedPreferences reste la source de vérité locale.
  static Future<void> sauvegarderLangue({
    required String langueCode,
    required String token,   // fcm_token ou identifiant appareil
  }) async {
    try {
      await rpc('sauvegarder_langue_appareil', {
        'p_token':  token,
        'p_langue': langueCode,
      });
    } catch (_) {
      // Silencieux — non bloquant, SharedPreferences est la source de vérité
    }
  }

  /// Charge la langue préférée depuis Supabase pour un appareil.
  /// Retourne null si la RPC n'existe pas ou si aucune préférence n'est
  /// enregistrée. Dans ce cas, SharedPreferences prend le relais.
  static Future<String?> chargerLangue({required String token}) async {
    try {
      final result = await rpc('charger_langue_appareil', {'p_token': token});
      if (result is Map<String, dynamic>) {
        final code = result['langue'] as String?;
        if (code != null && code.isNotEmpty) return code;
      }
    } catch (_) {
      // RPC absente ou erreur réseau → fallback SharedPreferences
    }
    return null;
  }

  // ══════════════════════════════════════════════════════
  // HELPER TRADUCTION NOTIFICATIONS
  // ══════════════════════════════════════════════════════

  /// Retourne {titre, message} traduit pour un type de notification.
  /// [vars] : variables à substituer (ex: {'nom': 'Alice', 'montant': '5000'})
  static Map<String, String> notifTexte(
    String type,
    String langueCode, {
    Map<String, String> vars = const {},
  }) {
    const n = <String, Map<String, Map<String, String>>>{
      'cotisation': {
        'titre': {
          'fr': '💰 Cotisation reçue',
          'en': '💰 Contribution received',
          'es': '💰 Cotización recibida',
          'pt': '💰 Contribuição recebida',
          'ar': '💰 تم استلام الاشتراك',
        },
        'message': {
          'fr': '{nom} a cotisé pour le tour en cours.',
          'en': '{nom} has contributed for the current round.',
          'es': '{nom} ha cotizado para la ronda actual.',
          'pt': '{nom} contribuiu para a rodada atual.',
          'ar': '{nom} دفع اشتراكه للجولة الحالية.',
        },
      },
      'decaissement': {
        'titre': {
          'fr': '💸 Décaissement effectué',
          'en': '💸 Disbursement made',
          'es': '💸 Desembolso realizado',
          'pt': '💸 Desembolso efetuado',
          'ar': '💸 تم الصرف',
        },
        'message': {
          'fr': '{nom} a reçu le décaissement du tour {tour}.',
          'en': '{nom} received the disbursement for round {tour}.',
          'es': '{nom} recibió el desembolso del turno {tour}.',
          'pt': '{nom} recebeu o desembolso da rodada {tour}.',
          'ar': '{nom} استلم الدفعة في الجولة {tour}.',
        },
      },
      'decaissement_cycle_fin': {
        'titre': {
          'fr': '🎊 Cycle terminé !',
          'en': '🎊 Cycle completed!',
          'es': '🎊 ¡Ciclo completado!',
          'pt': '🎊 Ciclo concluído!',
          'ar': '🎊 اكتملت الدورة!',
        },
        'message': {
          'fr': 'Tous les membres ont été servis. Le cycle est terminé !',
          'en': 'All members have been served. The cycle is complete!',
          'es': 'Todos los miembros han sido atendidos. ¡El ciclo ha terminado!',
          'pt': 'Todos os membros foram atendidos. O ciclo está concluído!',
          'ar': 'تمت خدمة جميع الأعضاء. انتهت الدورة!',
        },
      },
      'tirage_verrouille': {
        'titre': {
          'fr': '🔒 Tirage verrouillé',
          'en': '🔒 Draw locked',
          'es': '🔒 Sorteo bloqueado',
          'pt': '🔒 Sorteio bloqueado',
          'ar': '🔒 تم قفل القرعة',
        },
        'message': {
          'fr': 'L\'ordre de passage est définitif : {ordre}',
          'en': 'The order of turns is final: {ordre}',
          'es': 'El orden de turnos es definitivo: {ordre}',
          'pt': 'A ordem das rodadas é definitiva: {ordre}',
          'ar': 'ترتيب الأدوار نهائي: {ordre}',
        },
      },
      'penalite': {
        'titre': {
          'fr': '⚠️ Pénalité appliquée',
          'en': '⚠️ Penalty applied',
          'es': '⚠️ Penalización aplicada',
          'pt': '⚠️ Penalidade aplicada',
          'ar': '⚠️ تم تطبيق العقوبة',
        },
        'message': {
          'fr': 'Pénalité de {montant} appliquée à {nom}',
          'en': 'Penalty of {montant} applied to {nom}',
          'es': 'Penalización de {montant} aplicada a {nom}',
          'pt': 'Penalidade de {montant} aplicada a {nom}',
          'ar': 'غرامة {montant} طُبِّقت على {nom}',
        },
      },
      'caisse': {
        'titre': {
          'fr': '💰 Apport en caisse',
          'en': '💰 Cash contribution',
          'es': '💰 Aportación en caja',
          'pt': '💰 Contribuição em caixa',
          'ar': '💰 إيداع في الصندوق',
        },
        'message': {
          'fr': '{libelle} de {montant}{desc}',
          'en': '{libelle} of {montant}{desc}',
          'es': '{libelle} de {montant}{desc}',
          'pt': '{libelle} de {montant}{desc}',
          'ar': '{libelle} بمبلغ {montant}{desc}',
        },
      },
      'pret': {
        'titre': {
          'fr': '🤝 Nouveau prêt accordé',
          'en': '🤝 New loan granted',
          'es': '🤝 Nuevo préstamo concedido',
          'pt': '🤝 Novo empréstimo concedido',
          'ar': '🤝 تم منح قرض جديد',
        },
        'message': {
          'fr': 'Prêt de {montant} accordé à {nom} ({taux}% — {duree} mois)',
          'en': 'Loan of {montant} granted to {nom} ({taux}% — {duree} months)',
          'es': 'Préstamo de {montant} concedido a {nom} ({taux}% — {duree} meses)',
          'pt': 'Empréstimo de {montant} concedido a {nom} ({taux}% — {duree} meses)',
          'ar': 'قرض بمبلغ {montant} لـ {nom} ({taux}% — {duree} أشهر)',
        },
      },
      'remboursement': {
        'titre': {
          'fr': '💳 Remboursement enregistré',
          'en': '💳 Repayment recorded',
          'es': '💳 Reembolso registrado',
          'pt': '💳 Reembolso registado',
          'ar': '💳 تم تسجيل السداد',
        },
        'message': {
          'fr': 'Remboursement de {montant} reçu de {nom} — Reste : {reste}',
          'en': 'Repayment of {montant} received from {nom} — Remaining: {reste}',
          'es': 'Reembolso de {montant} recibido de {nom} — Resto: {reste}',
          'pt': 'Reembolso de {montant} recebido de {nom} — Restante: {reste}',
          'ar': 'استلام سداد {montant} من {nom} — المتبقي: {reste}',
        },
      },
      'pret_solde': {
        'titre': {
          'fr': '✅ Prêt entièrement soldé',
          'en': '✅ Loan fully repaid',
          'es': '✅ Préstamo totalmente saldado',
          'pt': '✅ Empréstimo totalmente liquidado',
          'ar': '✅ تم سداد القرض بالكامل',
        },
        'message': {
          'fr': 'Le prêt de {nom} est entièrement remboursé ({montant})',
          'en': 'The loan of {nom} is fully repaid ({montant})',
          'es': 'El préstamo de {nom} está totalmente reembolsado ({montant})',
          'pt': 'O empréstimo de {nom} foi totalmente reembolsado ({montant})',
          'ar': 'تم سداد قرض {nom} بالكامل ({montant})',
        },
      },
      'annulation_remboursement': {
        'titre': {
          'fr': '↩️ Remboursement annulé',
          'en': '↩️ Repayment cancelled',
          'es': '↩️ Reembolso cancelado',
          'pt': '↩️ Reembolso cancelado',
          'ar': '↩️ تم إلغاء السداد',
        },
        'message': {
          'fr': 'Annulation remboursement de {montant} — {nom} (Réf. {ref})',
          'en': 'Repayment cancellation of {montant} — {nom} (Ref. {ref})',
          'es': 'Cancelación reembolso de {montant} — {nom} (Ref. {ref})',
          'pt': 'Cancelamento reembolso de {montant} — {nom} (Ref. {ref})',
          'ar': 'إلغاء سداد {montant} — {nom} (مرجع {ref})',
        },
      },
      'vote_ouvert': {
        'titre': {
          'fr': '🗳️ Vote ouvert',
          'en': '🗳️ Vote opened',
          'es': '🗳️ Votación abierta',
          'pt': '🗳️ Votação aberta',
          'ar': '🗳️ تم فتح التصويت',
        },
        'message': {
          'fr': 'Un nouveau vote est ouvert : {question}',
          'en': 'A new vote is open: {question}',
          'es': 'Una nueva votación está abierta: {question}',
          'pt': 'Uma nova votação está aberta: {question}',
          'ar': 'تم فتح تصويت جديد: {question}',
        },
      },
      'vote_enregistre': {
        'titre': {
          'fr': '🗳️ Nouveau vote',
          'en': '🗳️ New vote cast',
          'es': '🗳️ Nuevo voto',
          'pt': '🗳️ Novo voto',
          'ar': '🗳️ تصويت جديد',
        },
        'message': {
          'fr': 'Un membre vient de voter sur : {question}',
          'en': 'A member just voted on: {question}',
          'es': 'Un miembro acaba de votar sobre: {question}',
          'pt': 'Um membro acabou de votar sobre: {question}',
          'ar': 'صوّت أحد الأعضاء على: {question}',
        },
      },
      'nouveau_membre': {
        'titre': {
          'fr': '🎉 Nouveau membre admis',
          'en': '🎉 New member admitted',
          'es': '🎉 Nuevo miembro admitido',
          'pt': '🎉 Novo membro admitido',
          'ar': '🎉 تم قبول عضو جديد',
        },
        'message': {
          'fr': '{nom} a été admis(e) dans la tontine par vote.',
          'en': '{nom} has been admitted to the tontine by vote.',
          'es': '{nom} ha sido admitido(a) en la tontina por votación.',
          'pt': '{nom} foi admitido(a) na tontina por votação.',
          'ar': 'تم قبول {nom} في التنتين عن طريق التصويت.',
        },
      },
      'vote_clos': {
        'titre': {
          'fr': '✅ Vote adopté',
          'en': '✅ Vote passed',
          'es': '✅ Votación aprobada',
          'pt': '✅ Votação aprovada',
          'ar': '✅ تمت الموافقة على التصويت',
        },
        'titre_rejete': {
          'fr': '❌ Vote rejeté',
          'en': '❌ Vote rejected',
          'es': '❌ Votación rechazada',
          'pt': '❌ Votação rejeitada',
          'ar': '❌ تم رفض التصويت',
        },
        'message': {
          'fr': 'Le vote "{question}" est clôturé : {resultat}.',
          'en': 'The vote "{question}" is closed: {resultat}.',
          'es': 'La votación "{question}" está cerrada: {resultat}.',
          'pt': 'A votação "{question}" foi encerrada: {resultat}.',
          'ar': 'التصويت "{question}" أُغلق: {resultat}.',
        },
      },
      'nouveau_cycle': {
        'titre': {
          'fr': '🔄 Nouveau cycle démarré',
          'en': '🔄 New cycle started',
          'es': '🔄 Nuevo ciclo iniciado',
          'pt': '🔄 Novo ciclo iniciado',
          'ar': '🔄 بدأت دورة جديدة',
        },
        'message': {
          'fr': 'Le cycle {num} de la tontine vient de démarrer ! Tour 1 en cours.',
          'en': 'Cycle {num} of the tontine has just started! Round 1 in progress.',
          'es': '¡El ciclo {num} de la tontina acaba de empezar! Turno 1 en curso.',
          'pt': 'O ciclo {num} da tontina acabou de começar! Rodada 1 em andamento.',
          'ar': 'انطلقت الدورة {num} من التنتين! الجولة 1 جارية.',
        },
      },
      'annulation_cotisation': {
        'titre': {
          'fr': '↩️ Paiement annulé',
          'en': '↩️ Payment cancelled',
          'es': '↩️ Pago cancelado',
          'pt': '↩️ Pagamento cancelado',
          'ar': '↩️ تم إلغاء الدفع',
        },
        'message': {
          'fr': 'Le paiement de {nom} (Tour {tour}) a été annulé par le gestionnaire.',
          'en': 'The payment of {nom} (Round {tour}) was cancelled by the manager.',
          'es': 'El pago de {nom} (Turno {tour}) fue cancelado por el gestor.',
          'pt': 'O pagamento de {nom} (Rodada {tour}) foi cancelado pelo gestor.',
          'ar': 'تم إلغاء دفع {nom} (الجولة {tour}) من قِبَل المدير.',
        },
      },
      'score_modifie': {
        'titre': {
          'fr': '📊 Score modifié',
          'en': '📊 Score updated',
          'es': '📊 Puntuación modificada',
          'pt': '📊 Pontuação modificada',
          'ar': '📊 تم تعديل النقاط',
        },
        'message': {
          'fr': 'Le score de {nom} a été modifié : {ancien} → {nouveau}/100',
          'en': 'Score of {nom} updated: {ancien} → {nouveau}/100',
          'es': 'La puntuación de {nom} fue modificada: {ancien} → {nouveau}/100',
          'pt': 'A pontuação de {nom} foi modificada: {ancien} → {nouveau}/100',
          'ar': 'تم تعديل نقاط {nom}: {ancien} → {nouveau}/100',
        },
      },
      'retrait_propose': {
        'titre': {
          'fr': '🗳️ Vote de retrait ouvert',
          'en': '🗳️ Withdrawal vote opened',
          'es': '🗳️ Votación de retiro abierta',
          'pt': '🗳️ Votação de retirada aberta',
          'ar': '🗳️ تم فتح تصويت الانسحاب',
        },
        'message': {
          'fr': 'Un vote de retrait est ouvert pour {nom} (score : {score}/100).',
          'en': 'A withdrawal vote is open for {nom} (score: {score}/100).',
          'es': 'Una votación de retiro está abierta para {nom} (puntuación: {score}/100).',
          'pt': 'Uma votação de retirada está aberta para {nom} (pontuação: {score}/100).',
          'ar': 'تم فتح تصويت الانسحاب لـ {nom} (النقاط: {score}/100).',
        },
      },
      // ── Lite/Pro ────────────────────────────────────────────────────────────
      'passage_pro': {
        'titre': {
          'fr': '🚀 Tontine passée en Pro !',
          'en': '🚀 Tontine upgraded to Pro!',
          'es': '🚀 ¡Tontina actualizada a Pro!',
          'pt': '🚀 Tontina atualizada para Pro!',
          'ar': '🚀 ترقية التنتين إلى Pro!',
        },
        'message': {
          'fr': 'Votre tontine est maintenant en mode Pro. Les paiements mobile money sont activés.',
          'en': 'Your tontine is now in Pro mode. Mobile money payments are enabled.',
          'es': 'Su tontina ahora está en modo Pro. Los pagos por mobile money están activados.',
          'pt': 'A sua tontina está agora em modo Pro. Os pagamentos por mobile money estão ativados.',
          'ar': 'تنتينك الآن في وضع Pro. تم تفعيل المدفوعات عبر الموبايل.',
        },
      },
      'cotisation_pro_confirmee': {
        'titre': {
          'fr': '✅ Paiement mobile confirmé',
          'en': '✅ Mobile payment confirmed',
          'es': '✅ Pago móvil confirmado',
          'pt': '✅ Pagamento móvel confirmado',
          'ar': '✅ تم تأكيد الدفع عبر الموبايل',
        },
        'message': {
          'fr': '{nom} a payé sa cotisation via mobile money (Tour {tour}).',
          'en': '{nom} paid their contribution via mobile money (Round {tour}).',
          'es': '{nom} pagó su cotización vía mobile money (Turno {tour}).',
          'pt': '{nom} pagou a contribuição via mobile money (Rodada {tour}).',
          'ar': '{nom} دفع اشتراكه عبر الموبايل (الجولة {tour}).',
        },
      },
      'decaissement_demande': {
        'titre': {
          'fr': '📤 Demande de décaissement',
          'en': '📤 Disbursement request',
          'es': '📤 Solicitud de desembolso',
          'pt': '📤 Pedido de desembolso',
          'ar': '📤 طلب صرف',
        },
        'message': {
          'fr': 'Le gestionnaire demande le décaissement du Tour {tour} pour {nom} ({montant}). En attente de validation Admin.',
          'en': 'The manager requests disbursement for Round {tour} to {nom} ({montant}). Awaiting Admin validation.',
          'es': 'El gestor solicita el desembolso del Turno {tour} para {nom} ({montant}). Pendiente de validación Admin.',
          'pt': 'O gestor solicita o desembolso da Rodada {tour} para {nom} ({montant}). Aguardando validação Admin.',
          'ar': 'المدير يطلب صرف الجولة {tour} لـ {nom} ({montant}). في انتظار موافقة الإدارة.',
        },
      },
      'pret_octroye': {
        'titre': {
          'fr': '🤝 Prêt octroyé',
          'en': '🤝 Loan granted',
          'es': '🤝 Préstamo otorgado',
          'pt': '🤝 Empréstimo concedido',
          'ar': '🤝 تم منح قرض',
        },
        'message': {
          'fr': 'Prêt de {montant} accordé à {nom} ({taux}% — {duree} mois) . Paiement automatisé.',
          'en': 'Loan of {montant} granted to {nom} ({taux}% — {duree} months) . Paiement automatisé.',
          'es': 'Préstamo de {montant} concedido a {nom} ({taux}% — {duree} meses) . Paiement automatisé.',
          'pt': 'Empréstimo de {montant} concedido a {nom} ({taux}% — {duree} meses) . Paiement automatisé.',
          'ar': 'قرض {montant} لـ {nom} ({taux}% — {duree} أشهر). دفع تلقائي.',
        },
      },
      'depense_caisse': {
        'titre': {
          'fr': '💸 Dépense caisse',
          'en': '💸 Cash expense',
          'es': '💸 Gasto de caja',
          'pt': '💸 Despesa de caixa',
          'ar': '💸 مصروف الصندوق',
        },
        'message': {
          'fr': 'Dépense de {montant} vers {nom} — {desc}',
          'en': 'Expense of {montant} to {nom} — {desc}',
          'es': 'Gasto de {montant} a {nom} — {desc}',
          'pt': 'Despesa de {montant} para {nom} — {desc}',
          'ar': 'مصروف {montant} لـ {nom} — {desc}',
        },
      },
      'decaissement_cagnotte': {
        'titre': {
          'fr': '💸 Cagnotte versée',
          'en': '💸 Jackpot paid',
          'es': '💸 Premio pagado',
          'pt': '💸 Prêmio pago',
          'ar': '💸 تم صرف الجائزة',
        },
        'message': {
          'fr': 'Tour {tour} — {montant} versé à {nom} . Paiement automatisé.',
          'en': 'Round {tour} — {montant} paid to {nom} . Paiement automatisé.',
          'es': 'Turno {tour} — {montant} pagado a {nom}. Pago automatizado.',
          'pt': 'Rodada {tour} — {montant} pago a {nom} . Paiement automatisé.',
          'ar': 'الجولة {tour} — {montant} صُرف لـ {nom}. دفع تلقائي.',
        },
      },
      'securite': {
        'titre': {
          'fr': '🔒 Modification sécurité',
          'en': '🔒 Security change',
          'es': '🔒 Cambio de seguridad',
          'pt': '🔒 Alteração de segurança',
          'ar': '🔒 تغيير في الأمان',
        },
        'message': {
          'fr': '{desc}',
          'en': '{desc}',
          'es': '{desc}',
          'pt': '{desc}',
          'ar': '{desc}',
        },
      },
    };

    String sub(String? tpl) {
      if (tpl == null) return '';
      var s = tpl;
      vars.forEach((k, v) => s = s.replaceAll('{$k}', v));
      return s;
    }

    final lang = ['fr', 'en', 'es', 'pt', 'ar'].contains(langueCode) ? langueCode : 'fr';
    final bloc = n[type];
    if (bloc == null) return {'titre': '', 'message': ''};

    final titre = sub(bloc['titre']?[lang] ?? bloc['titre']?['fr']);
    final message = sub(bloc['message']?[lang] ?? bloc['message']?['fr']);
    return {'titre': titre, 'message': message};
  }

  /// Envoie une notification push via l'Edge Function Supabase.
  /// [type] : 'cotisation' | 'vote' | 'decaissement' | 'membre' | 'cycle'
  // ═══════════════════════════════════════════════════════════════════════════
  // DÉPENSES PENDING (Mobile Money — validation admin)
  // ═══════════════════════════════════════════════════════════════════════════

  /// Soumet une dépense Mobile Money en statut 'pending'.
  /// La caisse n'est PAS débitée — l'admin devra valider.
  static Future<void> soumettreDepensePending({
    required String code,
    required int montant,
    required String description,
    required String operateur,
    required String numeroBeneficiaire,
    required String nomBeneficiaire,
    required String gestionnaire,
    required String reference,
    required String devise,
  }) async {
    final url = Uri.parse('$_url/rest/v1/depenses_pending');
    final body = {
      'code':               code.toUpperCase(),
      'montant':            montant,
      'description':        description,
      'operateur':          operateur,
      'numero_beneficiaire': numeroBeneficiaire,
      'nom_beneficiaire':   nomBeneficiaire,
      'gestionnaire':       gestionnaire,
      'reference':          reference,
      'devise':             devise,
      'statut':             'pending',
    };
    final resp = await http.post(
      url,
      headers: {
        'Content-Type':  'application/json',
        'Authorization': 'Bearer $_key',
        'apikey':        _key,
        'Prefer':        'return=minimal',
      },
      body: jsonEncode(body),
    );
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw Exception('Erreur soumission dépense: ${resp.statusCode} ${resp.body}');
    }
  }

  /// Récupère les dépenses pending pour l'admin.
  /// Retourne toutes les dépenses ou filtrées par [statut] (pending|validee|rejetee).
  static Future<List<Map<String, dynamic>>> adminListerDepensesPending(
    String cle, {
    String statut = 'tous',
  }) async {
    try {
      final params = <String, String>{
        'order': 'cree_le.desc',
        'limit': '200',
      };
      if (statut != 'tous') params['statut'] = 'eq.$statut';

      final url = Uri.parse('$_url/rest/v1/depenses_pending')
          .replace(queryParameters: params);

      final resp = await http.get(
        url,
        headers: {
          'Authorization': 'Bearer $_key',
          'apikey':        _key,
        },
      );
      if (resp.statusCode != 200) return [];
      final list = jsonDecode(resp.body) as List<dynamic>;
      return list.cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }

  /// Valide une dépense pending : débite la caisse + marque validee.
  /// [id] = id de la dépense dans depenses_pending.
  /// [cle] = clé admin pour authentification.
  static Future<Map<String, dynamic>> adminValiderDepense({
    required String cle,
    required int id,
  }) async {
    try {
      final result = await rpc('admin_valider_depense', {
        'p_cle': cle,
        'p_id':  id,
      });
      if (result is Map<String, dynamic>) return result;
      return {'ok': false, 'erreur': 'Réponse inattendue'};
    } catch (e) {
      return {'ok': false, 'erreur': '$e'};
    }
  }

  /// Rejette une dépense pending.
  static Future<Map<String, dynamic>> adminRejeterDepense({
    required String cle,
    required int id,
    required String motif,
  }) async {
    try {
      final result = await rpc('admin_rejeter_depense', {
        'p_cle':   cle,
        'p_id':    id,
        'p_motif': motif,
      });
      if (result is Map<String, dynamic>) return result;
      return {'ok': false, 'erreur': 'Réponse inattendue'};
    } catch (e) {
      return {'ok': false, 'erreur': '$e'};
    }
  }

  // ── Prêts pending (Premium) ───────────────────────────────────────────────

  /// Soumet une demande de prêt en attente de validation admin.
  static Future<void> soumettrePretenPending({
    required String code,
    required String emprunteurId,
    required String emprunteurNom,
    required int    montant,
    required int    fraisTransaction,
    required int    montantNet,
    required double taux,
    required int    dureesMois,
    required String operateur,
    required String numeroBeneficiaire,
    required String nomBeneficiaire,
    required String gestionnaire,
    required String reference,
    required String devise,
    String description = '',
  }) async {
    final url  = Uri.parse('$_url/rest/v1/prets_pending');
    final body = {
      'code':                  code.toUpperCase(),
      'emprunteur_id':         emprunteurId,
      'emprunteur_nom':        emprunteurNom,
      'montant':               montant,
      'frais_transaction':     fraisTransaction,
      'montant_net':           montantNet,
      'taux':                  taux,
      'durees_mois':           dureesMois,
      'operateur':             operateur,
      'numero_beneficiaire':   numeroBeneficiaire,
      'nom_beneficiaire':      nomBeneficiaire,
      'gestionnaire':          gestionnaire,
      'reference':             reference,
      'devise':                devise,
      'description':           description,
      'statut':                'pending',
    };
    final resp = await http.post(
      url,
      headers: {
        'Content-Type':  'application/json',
        'Authorization': 'Bearer $_key',
        'apikey':        _key,
        'Prefer':        'return=minimal',
      },
      body: jsonEncode(body),
    );
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw Exception('Erreur soumission prêt: ${resp.statusCode} ${resp.body}');
    }
  }

  /// Récupère les demandes de prêts pour l'admin (tous statuts ou filtré).
  static Future<List<Map<String, dynamic>>> adminListerPretsPending(
    String cle, {
    String statut = 'tous',
  }) async {
    try {
      final params = <String, String>{
        'order': 'created_at.desc',   // ← corrigé : created_at (pas cree_le)
        'limit': '200',
      };
      if (statut != 'tous') params['statut'] = 'eq.$statut';

      final url = Uri.parse('$_url/rest/v1/prets_pending')
          .replace(queryParameters: params);

      final resp = await http.get(
        url,
        headers: {
          'Authorization': 'Bearer $_key',
          'apikey':        _key,
          'Accept':        'application/json',
        },
      );
      if (resp.statusCode != 200) return [];
      final decoded = jsonDecode(resp.body);
      if (decoded is! List) return [];
      return decoded.cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }

  /// Récupère les demandes de prêts pending pour un code tontine (côté utilisateur).
  static Future<List<Map<String, dynamic>>> listerPretsPendingPourCode(
    String code,
  ) async {
    try {
      final url = Uri.parse('$_url/rest/v1/prets_pending').replace(
        queryParameters: {
          'code':  'eq.${code.toUpperCase()}',
          'order': 'created_at.desc',
          'limit': '50',
        },
      );
      final resp = await http.get(
        url,
        headers: {
          'Authorization': 'Bearer $_key',
          'apikey':        _key,
          'Accept':        'application/json',
        },
      );
      if (resp.statusCode != 200) return [];
      final decoded = jsonDecode(resp.body);
      if (decoded is! List) return [];
      return decoded.cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }

  /// Valide un prêt pending : débite caisse + crée le prêt dans le JSON tontine.
  static Future<Map<String, dynamic>> adminValiderPret({
    required String cle,
    required int    id,
  }) async {
    try {
      final result = await rpc('admin_valider_pret', {
        'p_cle': cle,
        'p_id':  id,
      });
      if (result is Map<String, dynamic>) return result;
      return {'ok': false, 'erreur': 'Réponse inattendue'};
    } catch (e) {
      return {'ok': false, 'erreur': '$e'};
    }
  }

  /// Rejette un prêt pending.
  static Future<Map<String, dynamic>> adminRejeterPret({
    required String cle,
    required int    id,
    required String motif,
  }) async {
    try {
      final result = await rpc('admin_rejeter_pret', {
        'p_cle':   cle,
        'p_id':    id,
        'p_motif': motif,
      });
      if (result is Map<String, dynamic>) return result;
      return {'ok': false, 'erreur': 'Réponse inattendue'};
    } catch (e) {
      return {'ok': false, 'erreur': '$e'};
    }
  }

  // ────────────────────────────────────────────────────────────────────────────
  // Décaissements pending (clôture de tour Premium)
  // ────────────────────────────────────────────────────────────────────────────

  /// Soumet un décaissement en attente après clôture de tour Premium.
  /// La caisse N'EST PAS débitée — l'admin valide ensuite via adminValiderDecaissement.
  static Future<void> soumettreDecaissementPending({
    required String code,
    required String beneficiaireId,
    required String beneficiaireNom,
    required int    montant,
    required int    commission,
    required int    montantNet,
    required int    numerTour,
    required String operateur,
    required String numeroBenef,
    required String gestionnaire,
    required String reference,
    String devise = '', // jamais XOF par défaut
  }) async {
    final url = Uri.parse('$_url/rest/v1/decaissements_pending');
    final body = {
      'code':                code.toUpperCase(),
      'beneficiaire_id':     beneficiaireId,
      'beneficiaire_nom':    beneficiaireNom,
      'montant':             montant,
      'commission':          commission,
      'montant_net':         montantNet,
      'numer_tour':          numerTour,
      'operateur':           operateur,
      'numero_beneficiaire': numeroBenef,
      'gestionnaire':        gestionnaire,
      'reference':           reference,
      'devise':              devise,
      'statut':              'pending',
    };
    final resp = await http.post(
      url,
      headers: {
        'Content-Type':  'application/json',
        'Authorization': 'Bearer $_key',
        'apikey':        _key,
        'Prefer':        'return=minimal',
      },
      body: jsonEncode(body),
    );
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw Exception('Erreur soumission décaissement: ${resp.statusCode} ${resp.body}');
    }
  }

  /// Retourne tous les décaissements (filtre par statut : 'tous' | 'pending' | 'validee' | 'rejetee').
  static Future<List<Map<String, dynamic>>> adminListerDecaissements(
    String cle, {
    String statut = 'tous',
  }) async {
    try {
      final result = await rpc('admin_lister_decaissements', {
        'p_cle':    cle,
        'p_statut': statut,
      });
      if (result is List) return List<Map<String, dynamic>>.from(result.cast<Map<String, dynamic>>());
      return [];
    } catch (_) {
      return [];
    }
  }

  /// Valide un décaissement pending : débite la caisse via RPC.
  static Future<Map<String, dynamic>> adminValiderDecaissement({
    required String cle,
    required int    id,
    // Paramètres optionnels pour l'ancrage blockchain
    String? tontineCode,
    String? beneficiaireId,
    String? beneficiaireNom,
    int?    montant,
    String? devise,           // devise réelle de la tontine
  }) async {
    try {
      final result = await rpc('admin_valider_decaissement', {
        'p_cle': cle,
        'p_id':  id,
      });
      // ── BLOCKCHAIN : ancrage distribution validée (non-bloquant) ─────────
      if (result is Map<String, dynamic> && result['ok'] == true) {
        if (tontineCode != null && beneficiaireId != null && montant != null) {
          BlockchainService.enregistrerDistribution(
            tontineCode : tontineCode,
            membreId    : beneficiaireId,
            membreNom   : beneficiaireNom ?? '',
            montantXof  : montant,
            devise      : devise,
            refInterne  : id.toString(),
          ).catchError((e) {
            if (kDebugMode) debugPrint('[Blockchain] distribution hook erreur: $e');
            return BlockchainResultat(ok: false, erreur: '$e', phase: 1);
          });
        }
      }
      // ─────────────────────────────────────────────────────────────────────
      if (result is Map<String, dynamic>) return result;
      return {'ok': false, 'erreur': 'Réponse inattendue'};
    } catch (e) {
      return {'ok': false, 'erreur': '$e'};
    }
  }

  /// Rejette un décaissement pending avec motif.
  static Future<Map<String, dynamic>> adminRejeterDecaissement({
    required String cle,
    required int    id,
    required String motif,
  }) async {
    try {
      final result = await rpc('admin_rejeter_decaissement', {
        'p_cle':   cle,
        'p_id':    id,
        'p_motif': motif,
      });
      if (result is Map<String, dynamic>) return result;
      return {'ok': false, 'erreur': 'Réponse inattendue'};
    } catch (e) {
      return {'ok': false, 'erreur': '$e'};
    }
  }


  // ═══════════════════════════════════════════════════════════════════════════
  // SUPPORT CLIENT — Tickets et messagerie support
  // ═══════════════════════════════════════════════════════════════════════════

  /// Ouvrir un ticket de support (depuis l'app client).
  static Future<Map<String, dynamic>> supportOuvrirTicket({
    required String gestionnaire,
    String? codeTontine,
    required String categorie,
    required String sujet,
    required String description,
    String priorite = 'normale',
  }) async {
    try {
      final result = await rpc('support_ouvrir_ticket', {
        'p_gestionnaire': gestionnaire,
        'p_code_tontine': codeTontine,
        'p_categorie':    categorie,
        'p_sujet':        sujet,
        'p_description':  description,
        'p_priorite':     priorite,
      });
      if (result is Map<String, dynamic>) return result;
      return {'ok': false, 'erreur': 'Réponse inattendue'};
    } catch (e) {
      return {'ok': false, 'erreur': '$e'};
    }
  }

  /// Lister les tickets de l'utilisateur courant.
  static Future<List<Map<String, dynamic>>> supportMesTickets(String gestionnaire) async {
    try {
      final result = await rpc('support_mes_tickets', {'p_gestionnaire': gestionnaire});
      if (result == null) return [];
      final list = result is List ? result : (result as Map)['data'] ?? [];
      return List<Map<String, dynamic>>.from(list as List);
    } catch (_) {
      return [];
    }
  }

  /// Récupérer les messages d'un ticket — lecture REST directe (côté client).
  /// La RPC support_messages_ticket ne retourne pas toujours les messages admin
  /// (est_admin=true). On lit directement support_messages par ticket_id pour
  /// avoir TOUS les messages (client + admin) dans l'ordre chronologique.
  static Future<List<Map<String, dynamic>>> supportMessagesTicket({
    required int ticketId,
    bool estAdmin = false,
    required String cleOuGest,
  }) async {
    try {
      // Lecture REST directe : retourne TOUS les messages du ticket (client + admin)
      final url = Uri.parse('$_url/rest/v1/support_messages').replace(
        queryParameters: {
          'ticket_id': 'eq.$ticketId',
          'order':     'envoye_le.asc',
          'select':    'id,ticket_id,auteur,corps,est_admin,envoye_le,lu_client,lu_admin',
        },
      );
      final resp = await http.get(url, headers: {
        'Authorization': 'Bearer $_key',
        'apikey':        _key,
        'Accept':        'application/json',
      });

      if (resp.statusCode == 200) {
        final decoded = jsonDecode(resp.body);
        if (decoded is List && decoded.isNotEmpty) {
          // Marquer les messages admin comme lus par le client (asynchrone)
          _marquerLuClient(ticketId);
          return decoded.cast<Map<String, dynamic>>();
        }
      }

      // Fallback : RPC si REST échoue (RLS restrictive)
      final result = await rpc('support_messages_ticket', {
        'p_ticket_id':   ticketId,
        'p_est_admin':   estAdmin,
        'p_cle_ou_gest': cleOuGest,
      });
      if (result == null) return [];
      final list = result is List ? result : (result as Map)['data'] ?? [];
      return List<Map<String, dynamic>>.from(list as List);
    } catch (_) {
      return [];
    }
  }

  /// Marque les messages admin d'un ticket comme lus par le client.
  static Future<void> _marquerLuClient(int ticketId) async {
    try {
      final url = Uri.parse('$_url/rest/v1/support_messages').replace(
        queryParameters: {
          'ticket_id': 'eq.$ticketId',
          'est_admin': 'eq.true',
          'lu_client': 'eq.false',
        },
      );
      await http.patch(url,
        headers: {
          'Authorization': 'Bearer $_key',
          'apikey':        _key,
          'Content-Type':  'application/json',
        },
        body: jsonEncode({'lu_client': true}),
      );
    } catch (_) {}
  }

  /// Envoyer un message dans un ticket — INSERT REST direct pour le client.
  /// Plus fiable que la RPC qui peut bloquer selon les politiques RLS.
  static Future<Map<String, dynamic>> supportRepondre({
    required int ticketId,
    required String auteur,
    required String corps,
    bool estAdmin = false,
    required String cleOuGest,
  }) async {
    try {
      // INSERT REST direct dans support_messages
      final url = Uri.parse('$_url/rest/v1/support_messages');
      final resp = await http.post(url,
        headers: {
          'Authorization': 'Bearer $_key',
          'apikey':        _key,
          'Content-Type':  'application/json',
          'Prefer':        'return=minimal',
        },
        body: jsonEncode({
          'ticket_id': ticketId,
          'auteur':    auteur.isNotEmpty ? auteur : 'Utilisateur',
          'corps':     corps,
          'est_admin': estAdmin,
          'lu_client': estAdmin ? false : true,   // client voit ses propres messages
          'lu_admin':  estAdmin ? true  : false,  // admin voit les messages client
        }),
      );

      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        // Mettre à jour mis_a_jour du ticket
        final urlTicket = Uri.parse('$_url/rest/v1/support_tickets').replace(
          queryParameters: {'id': 'eq.$ticketId'},
        );
        await http.patch(urlTicket,
          headers: {
            'Authorization': 'Bearer $_key',
            'apikey':        _key,
            'Content-Type':  'application/json',
          },
          body: jsonEncode({'mis_a_jour': DateTime.now().toIso8601String()}),
        );
        return {'ok': true};
      }

      // Fallback : RPC si REST bloqué
      final result = await rpc('support_repondre', {
        'p_ticket_id':   ticketId,
        'p_auteur':      auteur,
        'p_corps':       corps,
        'p_est_admin':   estAdmin,
        'p_cle_ou_gest': cleOuGest,
      });
      if (result is Map<String, dynamic>) return result;
      return {'ok': false, 'erreur': 'Erreur envoi'};
    } catch (e) {
      return {'ok': false, 'erreur': '$e'};
    }
  }

  static Future<void> envoyerNotification({
    required String code,
    required String type,
    required String titre,
    required String message,
    Map<String, String>? donneesExtra,
  }) async {
    try {
      final url = Uri.parse('$_url/functions/v1/envoyer_notification');
      final body = {
        'code':    code.toUpperCase(),
        'type':    type,
        'titre':   titre,
        'message': message,
        if (donneesExtra != null) 'donneesExtra': donneesExtra,
      };
      final res = await http.post(
        url,
        headers: {
          'Content-Type':  'application/json',
          'Authorization': 'Bearer $_key',
          'apikey':        _key,
        },
        body: jsonEncode(body),
      ).timeout(const Duration(seconds: 10));

      if (kDebugMode) {
        try {
          final json = jsonDecode(res.body) as Map<String, dynamic>;
          final envoyes = json['envoyes'] ?? 0;
          final total   = json['total']   ?? 0;
          final purges  = json['tokens_purges'] ?? 0;
          debugPrint('[FCM Broadcast] ✅ $type → tontine ${code.toUpperCase()} : '
              '$envoyes/$total appareils notifiés, $purges tokens purgés');
        } catch (_) {
          debugPrint('[FCM Broadcast] Réponse brute: ${res.body.substring(0, res.body.length.clamp(0, 200))}');
        }
      }
    } catch (e) {
      // Silencieux — la notification n'est jamais bloquante
      if (kDebugMode) debugPrint('[FCM Broadcast] ❌ Erreur envoi notification: $e');
    }
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // PIN Reset v2 — RPC + Edge Function send-manager-pin (SMTP Hostinger)
  // ─────────────────────────────────────────────────────────────────────────────

  /// Étape 1 : génère un code via RPC v3 (vérification stricte de l'email).
  /// Retourne ok:true + code si l'email correspond, ok:false + erreur sinon.
  /// L'email saisi DOIT correspondre exactement à celui enregistré à la création.
  static Future<Map<String, dynamic>> demanderResetPin({
    required String code,
    required String nom,
    required String contact,
  }) async {
    try {
      final res = await rpc('demander_reset_pin_v3', {
        'p_code':    code.toUpperCase(),
        'p_nom':     nom,
        'p_contact': contact.trim().toLowerCase(),
      });
      if (res is Map) return Map<String, dynamic>.from(res);
      return {'ok': false, 'erreur': 'Réponse serveur inattendue. Réessayez.'};
    } catch (e) {
      return {'ok': false, 'erreur': 'Erreur réseau. Vérifiez votre connexion.'};
    }
  }

  /// Étape 1b : appelle l'Edge Function send-manager-pin via HTTP direct.
  /// Evite les FunctionException du SDK Supabase qui masquent la vraie erreur.
  /// Retourne {success: true} ou {success: false, error: "message"}.
  static Future<Map<String, dynamic>> envoyerCodeResetPin({
    required String email,
    required String gestNom,
    required String tontineCode,
    required String codeClair,
  }) async {
    try {
      final uri = Uri.parse('$_url/functions/v1/send-manager-pin');
      final response = await http.post(
        uri,
        headers: {
          'Content-Type':  'application/json',
          'Authorization': 'Bearer $_key',
          'apikey':        _key,
        },
        body: jsonEncode({
          'email':       email.trim(),
          'gestNom':     gestNom,
          'tontineCode': tontineCode.toUpperCase(),
          'code':        codeClair,
        }),
      ).timeout(const Duration(seconds: 30));

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      if (response.statusCode == 200 && data['success'] == true) {
        return {'success': true};
      }
      final errMsg = data['error'] as String?
          ?? "Impossible d'envoyer le code (statut ${response.statusCode})";
      return {'success': false, 'error': errMsg};

    } on TimeoutException {
      return {'success': false, 'error': 'Délai dépassé. Vérifiez votre connexion.'};
    } catch (e) {
      return {'success': false, 'error': 'Erreur réseau. Vérifiez votre connexion.'};
    }
  }

  /// Valide le code à 6 chiffres saisi par le gestionnaire.
  /// Retourne {ok, message, erreur, tentatives_restantes}.
  /// Maximum 5 tentatives, comparaison SHA-256 côté SQL.
  static Future<Map<String, dynamic>> validerCodeResetPin({
    required String codeTontine,
    required String nom,
    required String codeSaisi,
  }) async {
    try {
      final res = await rpc('valider_code_reset_pin', {
        'p_code_tontine': codeTontine.toUpperCase(),
        'p_nom':          nom,
        'p_code_saisi':   codeSaisi.trim(),
      });
      if (res is Map) return Map<String, dynamic>.from(res);
      return {'ok': false, 'erreur': 'Réponse inattendue du serveur.'};
    } catch (e) {
      return {'ok': false, 'erreur': 'Erreur réseau. Vérifiez votre connexion.'};
    }
  }

  /// Définit un nouveau PIN après validation du code de réinitialisation.
  /// Retourne {ok, message, erreur}.
  /// Vérifie côté SQL que la session reset est valide (code utilisé < 5 min).
  static Future<Map<String, dynamic>> reinitialiserPin({
    required String codeTontine,
    required String nom,
    required String nouveauPin,
  }) async {
    try {
      final res = await rpc('reinitialiser_pin', {
        'p_code_tontine':  codeTontine.toUpperCase(),
        'p_nom':           nom,
        'p_nouveau_pin':   nouveauPin,
      });
      if (res is Map) return Map<String, dynamic>.from(res);
      return {'ok': false, 'erreur': 'Réponse inattendue du serveur.'};
    } catch (e) {
      return {'ok': false, 'erreur': 'Erreur réseau. Vérifiez votre connexion.'};
    }
  }

  /// Modifie le PIN depuis une session connectée (vérifie l'ancien PIN).
  /// Retourne {ok, message, erreur}.
  static Future<Map<String, dynamic>> modifierPin({
    required String code,
    required String nom,
    required String ancienPin,
    required String nouveauPin,
  }) async {
    try {
      final res = await rpc('modifier_pin', {
        'p_code':        code.toUpperCase(),
        'p_nom':         nom,
        'p_ancien_pin':  ancienPin,
        'p_nouveau_pin': nouveauPin,
      });
      if (res is Map) return Map<String, dynamic>.from(res);
      return {'ok': false, 'erreur': 'Réponse inattendue du serveur.'};
    } catch (e) {
      return {'ok': false, 'erreur': 'Erreur réseau. Vérifiez votre connexion.'};
    }
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // E-mail logs — Historique admin des e-mails envoyés
  // ─────────────────────────────────────────────────────────────────────────────

  /// Retourne la liste paginée des e-mails loggés (admin uniquement).
  /// [statut] filtre optionnel : 'envoye' | 'pending' | 'echoue'
  /// [type]   filtre optionnel : ex. 'pin_reset', 'alerte_securite', etc.
  static Future<List<Map<String, dynamic>>> adminEmailLogs(
    String cle, {
    String? statut,
    String? type,
    int limit = 50,
    int offset = 0,
  }) async {
    try {
      final params = <String, dynamic>{
        'p_cle':    cle,
        'p_limit':  limit,
        'p_offset': offset,
      };
      if (statut != null && statut.isNotEmpty) params['p_statut'] = statut;
      if (type   != null && type.isNotEmpty)   params['p_type']   = type;
      final res = await rpc('admin_email_logs', params);
      if (res is List) {
        return res.map((e) => Map<String, dynamic>.from(e as Map)).toList();
      }
      // La RPC peut aussi retourner un JSONB {logs:[...]}
      if (res is Map && res['logs'] is List) {
        return (res['logs'] as List)
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
      }
      return [];
    } catch (_) {
      return [];
    }
  }

  /// Remet un e-mail en statut 'pending' pour relance.
  static Future<bool> adminRelancerEmail({
    required String cle,
    required String emailId,
  }) async {
    try {
      await rpc('admin_relancer_email', {
        'p_cle':      cle,
        'p_email_id': emailId,
      });
      return true;
    } catch (_) {
      return false;
    }
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // Admin — Réinitialisation PIN gestionnaire via Edge Function send-manager-pin
  // ─────────────────────────────────────────────────────────────────────────────

  /// Récupère la liste {nom, email} de tous les gestionnaires d'une tontine.
  /// Appel REST direct sur la colonne `gestionnaires` (sans clé admin).
  /// Ne retourne jamais les PINs — uniquement nom + email.
  /// Retourne [] si la tontine est introuvable ou si aucun email n'est renseigné.
  static Future<List<Map<String, String>>> lireEmailsGestionnaires(String code) async {
    try {
      final uri = Uri.parse(
        '$_url/rest/v1/tontines?select=gestionnaires&code=eq.${code.toUpperCase()}',
      );
      final res = await http.get(
        uri,
        headers: {
          'apikey':        _key,
          'Authorization': 'Bearer $_key',
          'Accept':        'application/json',
        },
      ).timeout(const Duration(seconds: 10));

      if (res.statusCode != 200 && res.statusCode != 206) return [];

      final body = jsonDecode(res.body);
      if (body is! List || body.isEmpty) return [];

      final gests = body[0]['gestionnaires'];
      if (gests is! List) return [];

      final result = <Map<String, String>>[];
      for (final g in gests) {
        if (g is Map) {
          final nom   = (g['nom']   as String? ?? '').trim();
          final email = (g['email'] as String? ?? '').trim();
          if (nom.isNotEmpty && email.isNotEmpty) {
            result.add({'nom': nom, 'email': email});
          }
        }
      }
      return result;
    } catch (e) {
      if (kDebugMode) debugPrint('[lireEmailsGestionnaires] Erreur: $e');
      return [];
    }
  }

  /// Récupère la liste {nom, email} de tous les membres d'une tontine Premium
  /// qui ont renseigné leur e-mail lors de la création.
  ///
  /// Lit directement la colonne `data`→`membres[]` (champ 'email') via REST.
  /// Retourne [] si la tontine est introuvable, Gratuite, ou si aucun membre
  /// n'a d'e-mail.
  static Future<List<Map<String, String>>> lireEmailsMembres(String code) async {
    try {
      final uri = Uri.parse(
        '$_url/rest/v1/tontines?select=data&code=eq.${code.toUpperCase()}',
      );
      final res = await http.get(
        uri,
        headers: {
          'apikey':        _key,
          'Authorization': 'Bearer $_key',
          'Accept':        'application/json',
        },
      ).timeout(const Duration(seconds: 10));

      if (res.statusCode != 200 && res.statusCode != 206) return [];

      final body = jsonDecode(res.body);
      if (body is! List || body.isEmpty) return [];

      final data = body[0]['data'];
      if (data is! Map) return [];

      final membres = data['membres'];
      if (membres is! List) return [];

      final result = <Map<String, String>>[];
      for (final m in membres) {
        if (m is Map) {
          final nom   = (m['nom']   as String? ?? '').trim();
          final email = (m['email'] as String? ?? '').trim();
          if (nom.isNotEmpty && email.isNotEmpty) {
            result.add({'nom': nom, 'email': email});
          }
        }
      }
      if (kDebugMode) {
        debugPrint('[lireEmailsMembres] ${result.length} membre(s) avec email pour $code');
      }
      return result;
    } catch (e) {
      if (kDebugMode) debugPrint('[lireEmailsMembres] Erreur: $e');
      return [];
    }
  }

  /// Lit l'e-mail enregistré d'un gestionnaire dans la colonne `gestionnaires`.
  /// Retourne {ok: true, email, gest_nom} ou {ok: false, erreur}.
  static Future<Map<String, dynamic>> adminGetGestionnaireEmail({
    required String cle,
    required String codeTontine,
    required String nomGest,
  }) async {
    try {
      final res = await rpc('admin_get_gestionnaire_email', {
        'p_cle':          cle,
        'p_code_tontine': codeTontine.toUpperCase(),
        'p_nom_gest':     nomGest.trim(),
      });
      if (res is Map) return Map<String, dynamic>.from(res);
      return {'ok': false, 'erreur': 'Réponse inattendue du serveur.'};
    } catch (e) {
      return {'ok': false, 'erreur': 'Erreur réseau. Vérifiez votre connexion.'};
    }
  }

  /// Enregistre ou met à jour l'e-mail d'un gestionnaire dans la tontine.
  /// Retourne {ok: true, email, gest_nom, ancienEmail?, message} ou {ok: false, erreur}.
  static Future<Map<String, dynamic>> adminSetGestionnaireEmail({
    required String cle,
    required String codeTontine,
    required String nomGest,
    required String email,
  }) async {
    try {
      final res = await rpc('admin_set_gestionnaire_email', {
        'p_cle':          cle,
        'p_code_tontine': codeTontine.toUpperCase(),
        'p_nom_gest':     nomGest.trim(),
        'p_email':        email.trim().toLowerCase(),
      });
      if (res is Map) return Map<String, dynamic>.from(res);
      return {'ok': false, 'erreur': 'Réponse inattendue du serveur.'};
    } catch (e) {
      return {'ok': false, 'erreur': 'Erreur réseau. Vérifiez votre connexion.'};
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // BLOCAGE / DÉBLOCAGE DE TONTINE (Issue 10 — Sécurité Admin)
  // ─────────────────────────────────────────────────────────────────────────

  /// Bloque une tontine (status → 'blocked').
  /// Les membres ne peuvent plus y accéder tant qu'elle est bloquée.
  /// [motif] : raison du blocage (ex: suspicion de fraude, sécurité)
  static Future<Map<String, dynamic>> adminBloquerTontine({
    required String cle,
    required String code,
    required String motif,
  }) async {
    try {
      // Tentative via RPC dédiée (si déployée)
      final res = await rpc('admin_bloquer_tontine', {
        'p_cle':   cle,
        'p_code':  code.toUpperCase(),
        'p_motif': motif.trim(),
      });
      if (res is Map) return Map<String, dynamic>.from(res);
      return {'ok': true};
    } catch (_) {
      // Fallback : mise à jour directe via REST (si RPC non déployée)
      try {
        final tontine = await lireTontine(code);
        final data    = tontine.data.toJson();
        data['_blocage'] = {
          'motif':  motif.trim(),
          'date':   DateTime.now().toIso8601String(),
          'auteur': 'admin',
        };
        final response = await http.patch(
          Uri.parse('$_url/rest/v1/tontines?code=eq.${code.toUpperCase()}'),
          headers: {
            'apikey':        _key,
            'Authorization': 'Bearer $_key',
            'Content-Type':  'application/json',
            'Prefer':        'return=minimal',
          },
          body: jsonEncode({'status': 'blocked', 'data': data}),
        ).timeout(const Duration(seconds: 20));
        if (response.statusCode == 204) return {'ok': true};
        return {'ok': false, 'erreur': 'Erreur ${response.statusCode}'};
      } catch (e) {
        return {'ok': false, 'erreur': 'Erreur réseau : $e'};
      }
    }
  }

  /// Débloque une tontine (status → 'active').
  static Future<Map<String, dynamic>> adminDebloquerTontine({
    required String cle,
    required String code,
  }) async {
    try {
      final res = await rpc('admin_debloquer_tontine', {
        'p_cle':  cle,
        'p_code': code.toUpperCase(),
      });
      if (res is Map) return Map<String, dynamic>.from(res);
      return {'ok': true};
    } catch (_) {
      // Fallback : mise à jour directe via REST
      try {
        final tontine = await lireTontine(code);
        final data    = tontine.data.toJson();
        data.remove('_blocage');
        final response = await http.patch(
          Uri.parse('$_url/rest/v1/tontines?code=eq.${code.toUpperCase()}'),
          headers: {
            'apikey':        _key,
            'Authorization': 'Bearer $_key',
            'Content-Type':  'application/json',
            'Prefer':        'return=minimal',
          },
          body: jsonEncode({'status': 'active', 'data': data}),
        ).timeout(const Duration(seconds: 20));
        if (response.statusCode == 204) return {'ok': true};
        return {'ok': false, 'erreur': 'Erreur ${response.statusCode}'};
      } catch (e) {
        return {'ok': false, 'erreur': 'Erreur réseau : $e'};
      }
    }
  }

  /// Envoie un message broadcast à tous les membres d'une tontine.
  static Future<Map<String, dynamic>> adminEnvoyerMessageTontine({
    required String cle,
    required String code,
    required String message,
    required String type,
  }) async {
    try {
      final res = await rpc('admin_message_tontine', {
        'p_cle':     cle,
        'p_code':    code.toUpperCase(),
        'p_message': message.trim(),
        'p_type':    type,
      });
      if (res is Map) return Map<String, dynamic>.from(res);
      // Fallback : envoyer une notification push
      await envoyerNotification(
        code:    code,
        type:    'alerte_securite',
        titre:   '⚠️ Message de l\'administration',
        message: message.trim(),
      );
      return {'ok': true};
    } catch (e) {
      return {'ok': false, 'erreur': 'Erreur : $e'};
    }
  }

  /// Liste les tickets de support côté admin.
  static Future<List<Map<String, dynamic>>> adminListerTickets(
      String cle, {String statut = 'tous'}) async {
    try {
      final res = await rpc('admin_lister_tickets_support', {
        'p_cle':    cle,
        'p_statut': statut,
      });
      if (res is List) return res.cast<Map<String, dynamic>>();
    } catch (_) {}
    // Fallback : REST
    try {
      final query = statut == 'tous'
          ? '$_url/rest/v1/support_tickets?order=created_at.desc&limit=100'
          : '$_url/rest/v1/support_tickets?statut=eq.$statut&order=created_at.desc&limit=100';
      final response = await http.get(
        Uri.parse(query),
        headers: {'apikey': _key, 'Authorization': 'Bearer $_key'},
      ).timeout(const Duration(seconds: 20));
      if (response.statusCode == 200) {
        final list = jsonDecode(response.body);
        if (list is List) return list.cast<Map<String, dynamic>>();
      }
    } catch (_) {}
    return [];
  }

  /// Répondre à un ticket de support (admin).
  static Future<Map<String, dynamic>> adminRepondreTicket({
    required String cle,
    required String ticketId,
    required String reponse,
  }) async {
    try {
      final res = await rpc('admin_repondre_ticket', {
        'p_cle':      cle,
        'p_ticket_id': ticketId,
        'p_reponse':   reponse.trim(),
      });
      if (res is Map) return Map<String, dynamic>.from(res);
      return {'ok': true};
    } catch (e) {
      return {'ok': false, 'erreur': 'Erreur : $e'};
    }
  }

  /// Étape 1 (Admin) : appelle la RPC admin_reinitialiser_pin_gestionnaire.
  /// Accepte un [emailOverride] pour les tontines sans email enregistré.
  /// La RPC génère un code hashé et retourne {ok, email, gest_nom, tontine_code, code_clair}.
  ///
  /// Retourne :
  ///   {ok: true,  email, gest_nom, tontine_code, code_clair, email_source}  ← succès
  ///   {ok: false, erreur: "message lisible"}                                  ← échec
  static Future<Map<String, dynamic>> adminDemanderResetPinGestionnaire({
    required String cle,
    required String codeTontine,
    required String nomGest,
    String emailOverride = '',
  }) async {
    try {
      final res = await rpc('admin_reinitialiser_pin_gestionnaire', {
        'p_cle':            cle,
        'p_code_tontine':   codeTontine.toUpperCase(),
        'p_nom_gest':       nomGest.trim(),
        'p_email_override': emailOverride.trim().toLowerCase(),
      });
      if (res is Map) return Map<String, dynamic>.from(res);
      return {'ok': false, 'erreur': 'Réponse inattendue du serveur.'};
    } catch (e) {
      return {'ok': false, 'erreur': 'Erreur réseau. Vérifiez votre connexion.'};
    }
  }

  /// Étape 2 (Admin) : appelle l'Edge Function send-manager-pin via SDK Supabase.
  /// Retourne {success: true} ou {success: false, error: "message"}.
  static Future<Map<String, dynamic>> adminEnvoyerResetPinGestionnaire({
    required String email,
    required String gestNom,
    required String tontineCode,
    required String codeClair,
  }) async {
    try {
      final uri = Uri.parse('$_url/functions/v1/send-manager-pin');
      final response = await http.post(
        uri,
        headers: {
          'Content-Type':  'application/json',
          'Authorization': 'Bearer $_key',
          'apikey':        _key,
        },
        body: jsonEncode({
          'email':       email.trim(),
          'gestNom':     gestNom,
          'tontineCode': tontineCode.toUpperCase(),
          'code':        codeClair,
        }),
      ).timeout(const Duration(seconds: 30));

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      if (response.statusCode == 200 && data['success'] == true) {
        return {'success': true};
      }
      final errMsg = data['error'] as String?
          ?? "Impossible d'envoyer le code (statut ${response.statusCode})";
      return {'success': false, 'error': errMsg};

    } on TimeoutException {
      return {'success': false, 'error': 'Délai dépassé. Vérifiez votre connexion.'};
    } catch (e) {
      return {'success': false, 'error': 'Erreur réseau. Vérifiez votre connexion.'};
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Modèle de résultat de diagnostic
// ─────────────────────────────────────────────────────────────────────────────
class DiagnosticResult {
  final bool connecte;
  final bool sqlInitialise;
  final String message;
  final Map<String, dynamic> details;

  const DiagnosticResult({
    required this.connecte,
    required this.sqlInitialise,
    required this.message,
    required this.details,
  });
}
