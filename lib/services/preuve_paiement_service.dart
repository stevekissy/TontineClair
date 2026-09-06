// ─────────────────────────────────────────────────────────────────────────────
// PreuvePaiementService — Stockage permanent des preuves de paiement
//
// Architecture :
//   • Supabase Storage bucket "preuves-paiement" (public read, auth write)
//   • Chemin : {tontineCode}/{membreId}/{timestamp}_{description}.jpg/.png/.pdf
//   • Upload via REST API (cohérent avec la stratégie HTTP du projet)
//   • Lecture via URL publique Supabase Storage
//
// Sécurité :
//   • La clé anon permet l'upload (bucket ouvert à la clé anon)
//   • Les preuves sont accessibles via URL préfixée par le code tontine
//   • En cas de contestation, le gestionnaire peut voir toutes les preuves
//
// Conservation :
//   • Permanente — aucun TTL, aucune suppression automatique
//   • Suppression possible uniquement par le gestionnaire
//   • Suppression du dossier complet à la suppression de la tontine
// ─────────────────────────────────────────────────────────────────────────────

import 'dart:convert';
import 'package:flutter/foundation.dart';  // inclut Uint8List via dart:typed_data
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

  /// Vrai si la preuve est un PDF (non prévisualisable comme image).
  bool get estPdf => nom.toLowerCase().endsWith('.pdf');

  @override
  String toString() => 'PreuvePaiement($nom, $uploadedAt)';
}

class PreuvePaiementService {
  static const String _bucket = 'preuves-paiement';

  // ── URL Supabase Storage ──────────────────────────────────────────────────
  static String get _storageBase =>
      '${SupabaseService.supabaseUrl}/storage/v1';
  static String get _apiKey => SupabaseService.supabaseAnonKey;

  // ── Extension et Content-Type selon les bytes ────────────────────────────
  static ({String extension, String contentType}) _detecterFormat(Uint8List bytes) {
    // Signature PDF : %PDF
    if (bytes.length >= 4 &&
        bytes[0] == 0x25 && bytes[1] == 0x50 &&
        bytes[2] == 0x44 && bytes[3] == 0x46) {
      return (extension: '.pdf', contentType: 'application/pdf');
    }
    // Signature PNG : \x89PNG
    if (bytes.length >= 4 &&
        bytes[0] == 0x89 && bytes[1] == 0x50 &&
        bytes[2] == 0x4E && bytes[3] == 0x47) {
      return (extension: '.png', contentType: 'image/png');
    }
    // Signature HEIC : vérification de la boîte 'ftyp'
    if (bytes.length >= 12 &&
        bytes[4] == 0x66 && bytes[5] == 0x74 &&
        bytes[6] == 0x79 && bytes[7] == 0x70) {
      return (extension: '.heic', contentType: 'image/heic');
    }
    // Défaut → JPEG
    return (extension: '.jpg', contentType: 'image/jpeg');
  }

  // ── Chemin de stockage ────────────────────────────────────────────────────
  /// [contexte] : ex. "Tour3_cotisation", "Tour3_preuve", etc.
  static String _chemin(
    String tontineCode,
    String membreId,
    String description,
    String extension,
  ) {
    final ts = DateTime.now().millisecondsSinceEpoch;
    // Nettoyer la description pour un nom de fichier valide
    final desc = description
        .replaceAll(' ', '_')
        .replaceAll(RegExp(r'[^\w\-]'), '')
        .toLowerCase();
    return '${tontineCode.toUpperCase()}/$membreId/${ts}_$desc$extension';
  }

  /// Upload une preuve de paiement dans Supabase Storage.
  ///
  /// [description] : contexte enrichi, ex. "Tour3_cotisation_5000FCFA"
  /// Retourne l'URL publique si succès, null si erreur.
  static Future<String?> uploaderPreuve({
    required String tontineCode,
    required String membreId,
    required Uint8List imageBytes,
    required String description,
  }) async {
    final format = _detecterFormat(imageBytes);
    final chemin = _chemin(
      tontineCode,
      membreId,
      description.isEmpty ? 'preuve' : description,
      format.extension,
    );

    final uri = Uri.parse('$_storageBase/object/$_bucket/$chemin');

    try {
      final resp = await http.post(
        uri,
        headers: {
          'Authorization': 'Bearer $_apiKey',
          'apikey': _apiKey,
          'Content-Type': format.contentType,
          'x-upsert': 'true',
        },
        body: imageBytes,
      );

      if (resp.statusCode == 200 || resp.statusCode == 201) {
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
          'limit': 200,
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
      final preuves = <PreuvePaiement>[];

      for (final item in items) {
        final nom = item['name'] as String? ?? '';
        if (nom.isEmpty) continue;
        final chemin = '$prefix$nom';
        final url = '$_storageBase/object/public/$_bucket/$chemin';

        // Extraire la date depuis le timestamp dans le nom (ex: 1721234567_preuve.jpg)
        DateTime uploadedAt = DateTime.now();
        final parts = nom.split('_');
        if (parts.isNotEmpty) {
          final ts = int.tryParse(parts[0]);
          if (ts != null) uploadedAt = DateTime.fromMillisecondsSinceEpoch(ts);
        }

        // Description = nom nettoyé sans timestamp ni extension
        final desc = nom
            .replaceFirst(RegExp(r'^\d+_'), '')
            .replaceAll(RegExp(r'\.(jpg|jpeg|png|webp|heic|pdf)$'), '')
            .replaceAll('_', ' ');

        preuves.add(PreuvePaiement(
          url: url,
          nom: nom,
          cheminStorage: chemin,
          uploadedAt: uploadedAt,
          description: desc,
        ));
      }

      return preuves;
    } catch (e) {
      if (kDebugMode) debugPrint('[PreuvePaiement] Liste exception: $e');
      return [];
    }
  }

  /// Supprime une preuve (gestionnaire uniquement).
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

  /// Supprime toutes les preuves d'un membre dans une tontine.
  /// Utilisé lors du retrait d'un membre ou à la suppression de la tontine.
  static Future<void> supprimerDossierMembre({
    required String tontineCode,
    required String membreId,
  }) async {
    try {
      final preuves = await listerPreuves(
        tontineCode: tontineCode,
        membreId: membreId,
      );
      for (final p in preuves) {
        await supprimerPreuve(p.cheminStorage);
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[PreuvePaiement] SupprimerDossier exception: $e');
    }
  }
}
