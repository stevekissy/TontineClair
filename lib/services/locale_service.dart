// ─────────────────────────────────────────────────────────────────────────────
// LocaleService — Gestion de la langue de l'application
//
// 8 langues disponibles — change uniquement les textes de l'UI.
// Les données (tontines, montants, devises) ne sont jamais affectées.
// ─────────────────────────────────────────────────────────────────────────────

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Modèle langue
// ─────────────────────────────────────────────────────────────────────────────

class AppLangue {
  final String code;     // ex: 'fr'
  final String region;   // ex: 'FR'
  final String nom;      // nom dans la langue elle-même
  final String nomFr;    // nom en français
  final String drapeau;  // emoji drapeau

  const AppLangue({
    required this.code,
    required this.region,
    required this.nom,
    required this.nomFr,
    required this.drapeau,
  });

  Locale get locale => Locale(code, region);

  @override
  String toString() => '$drapeau $nom';
}

// ─────────────────────────────────────────────────────────────────────────────
// Catalogue des langues disponibles
// ─────────────────────────────────────────────────────────────────────────────

class LocaleService extends ChangeNotifier {
  static const String _prefKey = 'app_langue_code';

  // ── Langues disponibles ──────────────────────────────────────────────────
  static const List<AppLangue> langues = [
    AppLangue(code: 'fr', region: 'FR', nom: 'Français',  nomFr: 'Français',  drapeau: '🇫🇷'),
    AppLangue(code: 'en', region: 'US', nom: 'English',   nomFr: 'Anglais',   drapeau: '🇬🇧'),
    AppLangue(code: 'ar', region: 'SA', nom: 'العربية',   nomFr: 'Arabe',     drapeau: '🇸🇦'),
    AppLangue(code: 'pt', region: 'BR', nom: 'Português', nomFr: 'Portugais', drapeau: '🇧🇷'),
    AppLangue(code: 'es', region: 'ES', nom: 'Español',   nomFr: 'Espagnol',  drapeau: '🇪🇸'),
    AppLangue(code: 'sw', region: 'KE', nom: 'Kiswahili', nomFr: 'Swahili',   drapeau: '🇰🇪'),
    AppLangue(code: 'ha', region: 'NG', nom: 'Hausa',     nomFr: 'Haoussa',   drapeau: '🇳🇬'),
    AppLangue(code: 'am', region: 'ET', nom: 'አማርኛ',      nomFr: 'Amharique', drapeau: '🇪🇹'),
  ];

  // ── État courant ─────────────────────────────────────────────────────────
  AppLangue _langue = langues.first; // Français par défaut

  AppLangue get langue => _langue;
  Locale    get locale  => _langue.locale;

  // ── Initialisation depuis SharedPreferences ──────────────────────────────
  Future<void> initialiser() async {
    final prefs = await SharedPreferences.getInstance();
    final code  = prefs.getString(_prefKey);
    if (code != null) {
      final trouve = langues.firstWhere(
        (l) => l.code == code,
        orElse: () => langues.first,
      );
      _langue = trouve;
      notifyListeners();
    }
  }

  // ── Changer la langue ────────────────────────────────────────────────────
  Future<void> changerLangue(AppLangue langue) async {
    if (_langue.code == langue.code) return;
    _langue = langue;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKey, langue.code);
  }

  // ── Helpers statiques ────────────────────────────────────────────────────
  static AppLangue parCode(String code) {
    return langues.firstWhere(
      (l) => l.code == code,
      orElse: () => langues.first,
    );
  }
}
