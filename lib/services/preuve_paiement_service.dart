// ─────────────────────────────────────────────────────────────────────────────
// PreuvePaiementService — Stockage permanent des preuves de paiement
//
// Architecture :
//   • Supabase Storage bucket "preuves-paiement" (public read, auth write)
//   • Chemin : {tontineCode}/{membreId}/{timestamp}_{description}.jpg
//   • Upload via REST API (cohérent avec la stratégie HTTP du projet)
//   • Lecture via URL publique Supabase Storage
//
// Sécurité :
//   • La clé anon permet le upload en lecture publique
//   • Les preuves sont accessibles uniquement via URL avec le code tontine
//   • En cas de contestation, le gestionnaire peut voir toutes les preuves
// ─────────────────────────────────────────────────────────────────────────────

import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'supabase_service.dart';

/// Métadonnées d'une preuve de paiement stockée.
class PreuvePaiement {
  final String url;
  final String nom;
  final String cheminStorage;
  final DateTime uploadedAt;
  final String description;

  const PreuvePaiement({
    required this.url,
    required this.nom,
    required this.cheminStorage,
    required this.uploadedAt,
    required this.description,
  });

  @override
  String toString() => 'PreuvePaiement($nom, $uploadedAt)';
}

class PreuvePaiementService {
  static const String _bucket = 'preuves-paiement';

  // ── URL Supabase Storage ──────────────────────────────────────────────────
  static String get _storageBase =>
      '${SupabaseService.supabaseUrl}/storage/v1';
  static String get _apiKey => SupabaseService.supabaseAnonKey;

  // ── Chemin de stockage ────────────────────────────────────────────────────
  static String _chemin(String tontineCode, String membreId, String description) {
    final ts = DateTime.now().millisecondsSinceEpoch;
    // Nettoyer la description pour un nom de fichier valide
    final desc = description
        .replaceAll(' ', '_')
        .replaceAll(RegExp(r'[^\w\-]'), '')
        .toLowerCase();
    return '$tontineCode/$membreId/${ts}_$desc.jpg';
  }

  /// Upload une preuve de paiement (bytes JPEG/PNG) dans Supabase Storage.
  /// Retourne l'URL publique si succès, null si erreur.
  static Future<String?> uploaderPreuve({
    required String tontineCode,
    required String membreId,
    required Uint8List imageBytes,
    required String description,
  }) async {
    final chemin = _chemin(
      tontineCode.toUpperCase(),
      membreId,
      description.isEmpty ? 'preuve' : description,
    );

    final uri = Uri.parse(
      '$_storageBase/object/$_bucket/$chemin',
    );

    try {
      final resp = await http.post(
        uri,
        headers: {
          'Authorization': 'Bearer $_apiKey',
          'apikey': _apiKey,
          'Content-Type': 'image/jpeg',
          'x-upsert': 'true',
        },
        body: imageBytes,
      );

      if (resp.statusCode == 200 || resp.statusCode == 201) {
        // Construire l'URL publique
        return '$_storageBase/object/public/$_bucket/$chemin';
      } else {
        if (kDebugMode) {
          debugPrint('[PreuvePaiement] Upload erreur ${resp.statusCode}: ${resp.body}');
        }
        return null;
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[PreuvePaiement] Upload exception: $e');
      return null;
    }
  }

  /// Liste les preuves d'un membre dans une tontine.
  /// Utilise l'API Storage list.
  static Future<List<PreuvePaiement>> listerPreuves({
    required String tontineCode,
    required String membreId,
  }) async {
    final prefix = '${tontineCode.toUpperCase()}/$membreId/';

    final uri = Uri.parse('$_storageBase/object/list/$_bucket');

    try {
      final resp = await http.post(
        uri,
        headers: {
          'Authorization': 'Bearer $_apiKey',
          'apikey': _apiKey,
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'prefix': prefix,
          'limit': 100,
          'offset': 0,
          'sortBy': {'column': 'created_at', 'order': 'desc'},
        }),
      );

      if (resp.statusCode != 200) {
        if (kDebugMode) {
          debugPrint('[PreuvePaiement] Liste erreur ${resp.statusCode}: ${resp.body}');
        }
        return [];
      }

      final List<dynamic> items = jsonDecode(resp.body) as List<dynamic>;
      return items.map((item) {
        final nom = item['name'] as String? ?? '';
        final chemin = '$prefix$nom';
        final url = '$_storageBase/object/public/$_bucket/$chemin';

        // Extraire la date depuis le timestamp dans le nom (ex: 1721234567_preuve.jpg)
        DateTime uploadedAt = DateTime.now();
        final parts = nom.split('_');
        if (parts.isNotEmpty) {
          final ts = int.tryParse(parts[0]);
          if (ts != null) {
            uploadedAt = DateTime.fromMillisecondsSinceEpoch(ts);
          }
        }

        // Description = nom nettoyé sans timestamp ni extension
        final desc = nom
            .replaceFirst(RegExp(r'^\d+_'), '')
            .replaceAll('.jpg', '')
            .replaceAll('.png', '')
            .replaceAll('_', ' ');

        return PreuvePaiement(
          url: url,
          nom: nom,
          cheminStorage: chemin,
          uploadedAt: uploadedAt,
          description: desc,
        );
      }).toList();
    } catch (e) {
      if (kDebugMode) debugPrint('[PreuvePaiement] Liste exception: $e');
      return [];
    }
  }

  /// Supprime une preuve de paiement (gestionnaire uniquement).
  static Future<bool> supprimerPreuve(String chemin) async {
    final uri = Uri.parse('$_storageBase/object/$_bucket/$chemin');
    try {
      final resp = await http.delete(
        uri,
        headers: {
          'Authorization': 'Bearer $_apiKey',
          'apikey': _apiKey,
        },
      );
      return resp.statusCode == 200;
    } catch (e) {
      if (kDebugMode) debugPrint('[PreuvePaiement] Suppression exception: $e');
      return false;
    }
  }
}
