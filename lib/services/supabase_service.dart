import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/tontine.dart';

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
  static Future<dynamic> rpc(String fn, Map<String, dynamic> args) async {
    const url = _url;
    const key = _key;

    final uri = Uri.parse('$url/rest/v1/rpc/$fn');
    if (kDebugMode) debugPrint('[RPC] → $fn  args=$args');

    http.Response response;
    try {
      response = await http
          .post(
            uri,
            headers: {
              'Content-Type': 'application/json',
              'apikey': key,
              'Authorization': 'Bearer $key',
              // Pas de "Prefer" : comportement identique à index.html
            },
            body: jsonEncode(args),
          )
          .timeout(const Duration(seconds: 15));
    } catch (e) {
      throw Exception('RESEAU: connexion à Supabase impossible — vérifiez votre connexion internet.');
    }

    if (kDebugMode) {
      debugPrint('[RPC] ← ${response.statusCode}  '
          '${response.body.length > 300 ? response.body.substring(0, 300) : response.body}');
    }

    // ── Erreurs HTTP (identique à index.html) ──────────────────────────────
    if (!_isOk(response.statusCode)) {
      final txt = response.body;
      if (response.statusCode == 404 || txt.contains('Could not find the function')) {
        throw Exception(
            'SQL: la fonction "$fn" est introuvable dans la base. '
            'Exécutez les scripts supabase.sql → v2 → v3 → v4 → v5 dans Supabase › SQL Editor.');
      }
      if (response.statusCode == 401 || response.statusCode == 403) {
        throw Exception(
            'CLE: clé anon refusée (${response.statusCode}). '
            'Vérifiez Settings › API › anon public dans votre projet Supabase.');
      }
      throw Exception('Erreur Supabase $fn (${response.statusCode}) : $txt');
    }

    // ── Corps de la réponse ────────────────────────────────────────────────
    final body = response.body.trim();
    if (body.isEmpty || body == 'null') return null;

    // ── Décodage JSON ──────────────────────────────────────────────────────
    dynamic decoded;
    try {
      decoded = jsonDecode(body);
    } catch (_) {
      // Réponse texte brute (ne devrait pas arriver pour nos fonctions)
      return body;
    }

    // PostgREST sans "Prefer" retourne la valeur directe pour RETURNS jsonb :
    //   • scalaire JSON : bool, String, int → retourné tel quel
    //   • objet JSON    : Map               → retourné tel quel
    //   • tableau JSON  : List              → retourné tel quel (lire_voix_tontine etc.)
    // Aucune désencapsulation supplémentaire nécessaire.
    return decoded;
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
    );
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
    return result == true;
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
    return result == true;
  }

  static Future<bool> supprimerTontine({
    required String code,
    required String nom,
    required String pin,
  }) async {
    final result = await rpc('supprimer_tontine', {
      'p_code': code.toUpperCase(),
      'p_nom': nom,
      'p_pin': pin,
    });
    return result == true;
  }

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

  static Future<bool> demanderPremium({
    required String code,
    required String nom,
    required String pin,
    required String contact,
    String formule = 'mensuel',
  }) async {
    final result = await rpc('demander_premium', {
      'p_code':    code.toUpperCase(),
      'p_nom':     nom,
      'p_pin':     pin,
      'p_contact': contact,
      'p_formule': formule,
    });
    return result == true;
  }

  /// Lire les demandes Premium en attente — liste complète pour l'admin
  static Future<List<Map<String, dynamic>>> adminListerDemandesPremium(String cle) async {
    final result = await rpc('admin_lister_demandes', {'p_cle': cle});
    if (result == null) return [];
    if (result is List) return result.cast<Map<String, dynamic>>();
    return [];
  }

  /// Refuser une demande Premium
  static Future<bool> adminRefuserDemande({
    required String cle,
    required String code,
  }) async {
    try {
      final result = await rpc('admin_refuser_demande', {
        'p_cle':  cle,
        'p_code': code.toUpperCase(),
      });
      return result == true;
    } catch (_) {
      // Fallback : marquer comme refusée via lister_tontines
      return false;
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // ADMIN
  // ═══════════════════════════════════════════════════════════════════════════

  static Future<List<Map<String, dynamic>>> adminListerDemandes(String cle) async {
    final result = await rpc('admin_lister_demandes', {'p_cle': cle});
    if (result == null) return [];
    if (result is List) return result.cast<Map<String, dynamic>>();
    return [];
  }

  static Future<List<Map<String, dynamic>>> adminListerTontines(String cle) async {
    final result = await rpc('admin_lister_tontines', {'p_cle': cle});
    if (result == null) return [];
    if (result is List) return result.cast<Map<String, dynamic>>();
    return [];
  }

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
