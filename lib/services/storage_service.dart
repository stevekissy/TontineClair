import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/tontine.dart';

class StorageService {
  static const String _keyListe         = 'tontines_liste';
  static const String _keyGestActif     = 'gest_actif';
  // _keyNbCrees conservé pour compatibilité future (migration de données)
  // ignore: unused_field
  static const String _keyNbCrees       = 'tontines_nb_crees';
  static const String _keyTontinesCrees = 'tontines_crees_codes';

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
      liste[idx] = TontineLocale(code: code, nom: nom, isPro: liste[idx].isPro);
      await sauvegarderListe(liste);
    }
  }

  /// Met à jour le tier (Lite/Pro) d'une tontine dans le cache local.
  /// Appelé après chargement d'une tontine complète pour afficher le badge Pro.
  static Future<void> mettreAJourTier(String code, bool isPro) async {
    final liste = await getListe();
    final idx = liste.indexWhere((t) => t.code == code);
    if (idx >= 0) {
      liste[idx] = TontineLocale(
        code: code,
        nom: liste[idx].nom,
        isPro: isPro,
      );
      await sauvegarderListe(liste);
    }
  }

  // ─── Configuration Supabase ─────────────────────────────────
  // Les credentials sont codés en dur dans SupabaseService (const).
  // Ces méthodes sont des stubs conservés pour compatibilité.

  static Future<String?> getProjectUrl() async =>
      'https://ubrqtcxbxcmvmxleiglh.supabase.co';
  static Future<String?> getAnonKey() async =>
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9'
      '.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InVicnF0Y3hieGNtdm14bGVpZ2xoIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODMyNzYwMzYsImV4cCI6MjA5ODg1MjAzNn0'
      '.GaCZwMG34cFcxR3lkLuq-7uMM7sQoc_VIqiDEzMgEq4';

  // No-op : credentials fixes, rien à charger depuis le stockage.
  static Future<void> loadSupabaseConfig() async {}
  static Future<bool> estConfigured()      async => true;

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

  // ─── Compteur tontines CRÉÉES (pas rejointes) ────────────────
  // Distingue les tontines créées par cet appareil des tontines rejointes.

  /// Retourne le nombre de tontines que CET appareil a créées.
  static Future<int> getNbTontinesCrees() async {
    final prefs = await SharedPreferences.getInstance();
    // Utilise la liste des codes créés pour une source de vérité fiable
    final raw = prefs.getString(_keyTontinesCrees);
    if (raw == null) return 0;
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list.length;
    } catch (_) {
      return 0;
    }
  }

  /// Enregistre qu'une nouvelle tontine a été créée par cet appareil.
  static Future<void> enregistrerTontineCree(String code) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_keyTontinesCrees);
    List<String> codes = [];
    if (raw != null) {
      try {
        codes = (jsonDecode(raw) as List<dynamic>).map((e) => e.toString()).toList();
      } catch (_) {}
    }
    if (!codes.contains(code.toUpperCase())) {
      codes.add(code.toUpperCase());
      await prefs.setString(_keyTontinesCrees, jsonEncode(codes));
    }
  }

  /// Supprime une tontine créée du compteur (si supprimée).
  static Future<void> retirerTontineCree(String code) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_keyTontinesCrees);
    if (raw == null) return;
    try {
      final codes = (jsonDecode(raw) as List<dynamic>)
          .map((e) => e.toString())
          .where((c) => c != code.toUpperCase())
          .toList();
      await prefs.setString(_keyTontinesCrees, jsonEncode(codes));
    } catch (_) {}
  }
}
