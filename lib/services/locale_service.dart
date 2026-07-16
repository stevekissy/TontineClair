// ─────────────────────────────────────────────────────────────────────────────
// LocaleService — Gestion de la langue de l'application
//
// 5 langues prioritaires : FR, EN, ES, PT, AR
// Architecture extensible : ajouter une langue = ajouter dans la liste + dans _translations
// Change uniquement les textes de l'UI.
// Les données (tontines, montants, devises) ne sont jamais affectées.
// ─────────────────────────────────────────────────────────────────────────────

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'supabase_service.dart';

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

  // ── Langues disponibles (5 prioritaires — extensible) ────────────────────
  static const List<AppLangue> langues = [
    AppLangue(code: 'fr', region: 'FR', nom: 'Français',  nomFr: 'Français',  drapeau: '🇫🇷'),
    AppLangue(code: 'en', region: 'US', nom: 'English',   nomFr: 'Anglais',   drapeau: '🇬🇧'),
    AppLangue(code: 'es', region: 'ES', nom: 'Español',   nomFr: 'Espagnol',  drapeau: '🇪🇸'),
    AppLangue(code: 'pt', region: 'BR', nom: 'Português', nomFr: 'Portugais', drapeau: '🇧🇷'),
    AppLangue(code: 'ar', region: 'SA', nom: 'العربية',   nomFr: 'Arabe',     drapeau: '🇸🇦'),
    // Pour ajouter une langue : décommenter + ajouter bloc dans app_localizations.dart
    // AppLangue(code: 'sw', region: 'KE', nom: 'Kiswahili', nomFr: 'Swahili',   drapeau: '🇰🇪'),
    // AppLangue(code: 'ha', region: 'NG', nom: 'Hausa',     nomFr: 'Haoussa',   drapeau: '🇳🇬'),
    // AppLangue(code: 'am', region: 'ET', nom: 'አማርኛ',      nomFr: 'Amharique', drapeau: '🇪🇹'),
  ];

  // ── État courant ─────────────────────────────────────────────────────────
  AppLangue _langue = langues.first; // Français par défaut

  AppLangue get langue => _langue;
  Locale    get locale  => _langue.locale;

  // ── Initialisation ───────────────────────────────────────────────────────
  // Ordre de priorité :
  //   1. SharedPreferences (local, immédiat — source de vérité hors-ligne)
  //   2. Supabase (distant, asynchrone — synchronise entre appareils)
  // Règle : Supabase écrase SharedPreferences SEULEMENT si la langue locale
  //         est 'fr' (défaut) et que Supabase a une préférence différente,
  //         afin de ne pas effacer un choix explicite fait hors-ligne.
  Future<void> initialiser() async {
    final prefs = await SharedPreferences.getInstance();

    // 1. Charger depuis SharedPreferences (immédiat)
    final codeLocal = prefs.getString(_prefKey);
    if (codeLocal != null) {
      _langue = langues.firstWhere(
        (l) => l.code == codeLocal,
        orElse: () => langues.first,
      );
      notifyListeners();
    }

    // 2. Tenter de charger depuis Supabase (asynchrone, silencieux)
    try {
      final token = prefs.getString('fcm_token') ?? '';
      if (token.isNotEmpty) {
        final codeDistant = await SupabaseService.chargerLangue(token: token);
        if (codeDistant != null && codeDistant != _langue.code) {
          // Supabase a une préférence : on la respecte et on met à jour local
          final langueDistante = langues.firstWhere(
            (l) => l.code == codeDistant,
            orElse: () => _langue,
          );
          if (langueDistante.code != _langue.code) {
            _langue = langueDistante;
            await prefs.setString(_prefKey, langueDistante.code);
            notifyListeners();
          }
        }
      }
    } catch (_) {
      // Silencieux — offline ou RPC absente, SharedPreferences suffit
    }
  }

  // ── Changer la langue ────────────────────────────────────────────────────
  // 1. Mise à jour immédiate de l'état + UI (notifyListeners)
  // 2. Persistance locale dans SharedPreferences
  // 3. Persistance distante dans Supabase (silencieuse, non bloquante)
  Future<void> changerLangue(AppLangue langue) async {
    if (_langue.code == langue.code) return;
    _langue = langue;
    notifyListeners();               // ← UI se met à jour immédiatement

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKey, langue.code);  // local toujours en premier

    // Supabase : silencieux, non bloquant
    try {
      final token = prefs.getString('fcm_token') ?? '';
      if (token.isNotEmpty) {
        await SupabaseService.sauvegarderLangue(
          langueCode: langue.code,
          token: token,
        );
      }
    } catch (_) {
      // Silencieux — l'UI est déjà à jour, SharedPreferences suffit
    }
  }

  // ── Helpers statiques ────────────────────────────────────────────────────
  static AppLangue parCode(String code) {
    return langues.firstWhere(
      (l) => l.code == code,
      orElse: () => langues.first,
    );
  }
}
