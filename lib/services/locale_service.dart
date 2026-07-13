// ─────────────────────────────────────────────────────────────────────────────
// LocaleService — Gestion de la langue de l'application
//
// Langues disponibles, choisies selon les devises/pays couverts par TontineClair :
//   🇫🇷 Français   — Afrique de l'Ouest, France, Belgique, Suisse, Maghreb
//   🇬🇧 English    — Afrique de l'Est/Sud, Nigeria, Ghana, États-Unis, UK
//   🇸🇦 العربية    — Maghreb, Égypte, Moyen-Orient
//   🇵🇹 Português  — Brésil, Angola, Cap-Vert, Mozambique, Guinée-Bissau
//   🇪🇸 Español    — Amérique du Sud, Espagne, Mexique
//   🇰🇪 Kiswahili  — Kenya, Tanzanie, Ouganda, Rwanda, Burundi
//   🇳🇬 Hausa      — Nigeria Nord, Niger, Ghana Nord, Afrique de l'Ouest
//   🇪🇹 Amharique  — Éthiopie, Érythrée
// ─────────────────────────────────────────────────────────────────────────────

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Modèle langue
// ─────────────────────────────────────────────────────────────────────────────

class AppLangue {
  final String code;        // ex: 'fr'
  final String region;      // ex: 'FR'
  final String nom;         // nom dans la langue elle-même
  final String nomFr;       // nom en français (pour l'UI de sélection)
  final String drapeau;     // emoji drapeau
  final String devises;     // devises principales associées
  final TextDirection direction;

  const AppLangue({
    required this.code,
    required this.region,
    required this.nom,
    required this.nomFr,
    required this.drapeau,
    required this.devises,
    this.direction = TextDirection.ltr,
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
    AppLangue(
      code:    'fr',
      region:  'FR',
      nom:     'Français',
      nomFr:   'Français',
      drapeau: '🇫🇷',
      devises: 'XOF · XAF · EUR · MAD · DZD · TND',
    ),
    AppLangue(
      code:    'en',
      region:  'US',
      nom:     'English',
      nomFr:   'Anglais',
      drapeau: '🇬🇧',
      devises: 'USD · GBP · NGN · GHS · KES · ZAR',
    ),
    AppLangue(
      code:    'ar',
      region:  'SA',
      nom:     'العربية',
      nomFr:   'Arabe',
      drapeau: '🇸🇦',
      devises: 'SAR · AED · MAD · EGP · DZD · TND',
      direction: TextDirection.rtl,
    ),
    AppLangue(
      code:    'pt',
      region:  'BR',
      nom:     'Português',
      nomFr:   'Portugais',
      drapeau: '🇧🇷',
      devises: 'BRL · AOA · MZN · CVE',
    ),
    AppLangue(
      code:    'es',
      region:  'ES',
      nom:     'Español',
      nomFr:   'Espagnol',
      drapeau: '🇪🇸',
      devises: 'EUR · MXN · COP · ARS · CLP · PEN',
    ),
    AppLangue(
      code:    'sw',
      region:  'KE',
      nom:     'Kiswahili',
      nomFr:   'Swahili',
      drapeau: '🇰🇪',
      devises: 'KES · TZS · UGX · RWF · BIF',
    ),
    AppLangue(
      code:    'ha',
      region:  'NG',
      nom:     'Hausa',
      nomFr:   'Haoussa',
      drapeau: '🇳🇬',
      devises: 'NGN · XOF · GHS',
    ),
    AppLangue(
      code:    'am',
      region:  'ET',
      nom:     'አማርኛ',
      nomFr:   'Amharique',
      drapeau: '🇪🇹',
      devises: 'ETB · ERN',
    ),
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
