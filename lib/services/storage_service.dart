import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/tontine.dart';
import '../services/supabase_service.dart';

class StorageService {
  static const String _keyListe       = 'tontines_liste';
  static const String _keyAnonKey     = 'supabase_anon_key';
  static const String _keyProjectUrl  = 'supabase_project_url';
  static const String _keyGestActif   = 'gest_actif';

  // ─── Liste locale des tontines ──────────────────────────────

  static Future<List<TontineLocale>> getListe() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_keyListe);
    if (raw == null) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => TontineLocale.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> sauvegarderListe(List<TontineLocale> liste) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _keyListe,
      jsonEncode(liste.map((t) => t.toJson()).toList()),
    );
  }

  static Future<void> ajouterTontine(TontineLocale t) async {
    final liste = await getListe();
    if (!liste.any((l) => l.code == t.code)) {
      liste.add(t);
      await sauvegarderListe(liste);
    }
  }

  static Future<void> retirerTontine(String code) async {
    final liste = await getListe();
    liste.removeWhere((t) => t.code == code);
    await sauvegarderListe(liste);
  }

  static Future<void> mettreAJourNom(String code, String nom) async {
    final liste = await getListe();
    final idx = liste.indexWhere((t) => t.code == code);
    if (idx >= 0) {
      liste[idx] = TontineLocale(code: code, nom: nom);
      await sauvegarderListe(liste);
    }
  }

  // ─── Configuration Supabase ─────────────────────────────────

  /// Retourne l'URL complète stockée, ou null si non configurée.
  static Future<String?> getProjectUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyProjectUrl);
  }

  /// Retourne la clé anon stockée, ou null si non configurée.
  static Future<String?> getAnonKey() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyAnonKey);
  }

  /// Sauvegarde URL + clé et les injecte dans [SupabaseService].
  static Future<void> sauvegarderConfig({
    required String projectUrl,
    required String anonKey,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyProjectUrl, projectUrl);
    await prefs.setString(_keyAnonKey, anonKey);
    SupabaseService.supabaseUrl  = projectUrl;
    SupabaseService.supabaseAnonKey = anonKey;
  }

  /// Alias de compatibilité (clé seule — URL déduite de ce qui est déjà stocké).
  static Future<void> saveSupabaseKey(String key) async {
    final url = await getProjectUrl() ?? SupabaseService.supabaseUrl;
    await sauvegarderConfig(projectUrl: url, anonKey: key);
  }

  /// Appelé au démarrage : recharge la config depuis le stockage local.
  /// Si aucune config n'est sauvegardée, les valeurs par défaut de
  /// [SupabaseService] (projet ubrqtcxbxcmvmxleiglh) restent actives.
  static Future<void> loadSupabaseConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final url = prefs.getString(_keyProjectUrl);
    final key = prefs.getString(_keyAnonKey);
    // On remplace les valeurs par défaut uniquement si l'utilisateur
    // a explicitement configuré ses propres identifiants.
    if (url != null && url.isNotEmpty) {
      SupabaseService.supabaseUrl = url;
    }
    if (key != null && key.isNotEmpty) {
      SupabaseService.supabaseAnonKey = key;
    }
  }

  /// Retourne true si la config est opérationnelle.
  /// La config est valide soit parce que l'utilisateur l'a saisie,
  /// soit parce que les valeurs par défaut de SupabaseService sont présentes.
  static Future<bool> estConfigured() async {
    // Si SupabaseService a déjà une URL et une clé (par défaut ou sauvegardées)
    if (SupabaseService.supabaseUrl.isNotEmpty &&
        SupabaseService.supabaseAnonKey.isNotEmpty) {
      return true;
    }
    // Sinon vérifier le stockage local
    final url = await getProjectUrl();
    final key = await getAnonKey();
    return url != null &&
        url.isNotEmpty &&
        key != null &&
        key.isNotEmpty;
  }

  /// Efface toute la configuration (pour ré-initialiser).
  static Future<void> effacerConfig() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyProjectUrl);
    await prefs.remove(_keyAnonKey);
    SupabaseService.supabaseUrl     = '';
    SupabaseService.supabaseAnonKey = '';
  }

  // ─── Gestionnaire actif (session locale) ────────────────────

  static Future<void> sauvegarderGestActif({
    required String code,
    required String nom,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      '${_keyGestActif}_$code',
      jsonEncode({'nom': nom}),
    );
  }

  static Future<Map<String, String>?> getGestActif(String code) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('${_keyGestActif}_$code');
    if (raw == null) return null;
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      return {'nom': m['nom'] as String? ?? ''};
    } catch (_) {
      return null;
    }
  }

  static Future<void> effacerGestActif(String code) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('${_keyGestActif}_$code');
  }
}
