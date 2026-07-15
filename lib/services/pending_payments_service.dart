import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'sycapay_service.dart';

/// Service de récupération des paiements SycaPay interrompus.
///
/// Problèmes couverts :
///   - Utilisateur ferme l'app pendant le paiement
///   - Réseau coupé après débit Mobile Money
///   - Téléphone redémarre pendant le paiement
///   - Webhook SycaPay arrive après fermeture de l'app
///
/// Usage :
///   - Appeler [sauvegarderPaiementEnCours] juste avant checkoutpay
///   - Appeler [supprimerPaiementEnCours] après succès ou échec définitif
///   - Appeler [verifierPaiementsEnAttente] au démarrage de l'app
class PendingPaymentsService {
  static const String _prefKey = 'sycapay_pending_v1';

  // ── Sauvegarder un paiement en cours ─────────────────────────────────────

  /// Sauvegarde un paiement initié dans SharedPreferences.
  /// Appelé juste AVANT l'appel checkoutpay (persist-first).
  static Future<void> sauvegarderPaiementEnCours({
    required String numCommande,
    required String codeTontine,
    required String operateur,
    required int    montant,
    required String typeOperation, // 'cotisation' | 'caisse'
    String?         membreId,
    String?         description,
  }) async {
    try {
      final prefs   = await SharedPreferences.getInstance();
      final enCours = _chargerListe(prefs);

      // Supprimer si déjà présent (idempotent)
      enCours.removeWhere((p) => p['numCommande'] == numCommande);

      enCours.add({
        'numCommande':   numCommande,
        'codeTontine':   codeTontine,
        'operateur':     operateur,
        'montant':       montant,
        'typeOperation': typeOperation,
        'membreId':      membreId,
        'description':   description,
        'createdAt':     DateTime.now().millisecondsSinceEpoch,
      });

      await prefs.setString(_prefKey, jsonEncode(enCours));
      if (kDebugMode) debugPrint('[Pending] Sauvegardé: $numCommande');
    } catch (e) {
      if (kDebugMode) debugPrint('[Pending] Erreur sauvegarde: $e');
    }
  }

  // ── Supprimer un paiement traité ──────────────────────────────────────────

  static Future<void> supprimerPaiementEnCours(String numCommande) async {
    try {
      final prefs   = await SharedPreferences.getInstance();
      final enCours = _chargerListe(prefs);
      final avant   = enCours.length;
      enCours.removeWhere((p) => p['numCommande'] == numCommande);
      if (enCours.length != avant) {
        await prefs.setString(_prefKey, jsonEncode(enCours));
        if (kDebugMode) debugPrint('[Pending] Supprimé: $numCommande');
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[Pending] Erreur suppression: $e');
    }
  }

  // ── Vérifier les paiements en attente au démarrage ────────────────────────

  /// Vérifie dans Supabase les paiements qui étaient en cours lors de la
  /// dernière session. Retourne la liste des paiements avec leur statut actuel.
  ///
  /// Appelé dans main.dart ou au chargement d'une tontine.
  static Future<List<PaiementEnAttente>> verifierPaiementsEnAttente() async {
    try {
      final prefs   = await SharedPreferences.getInstance();
      final enCours = _chargerListe(prefs);

      if (enCours.isEmpty) return [];

      final resultats = <PaiementEnAttente>[];

      for (final p in List<Map<String, dynamic>>.from(enCours)) {
        final numCommande   = p['numCommande'] as String?;
        if (numCommande == null) continue;

        // Ignorer les très anciens (> 24h) — expirés
        final createdAt = p['createdAt'] as int? ?? 0;
        final age       = DateTime.now().millisecondsSinceEpoch - createdAt;
        if (age > 86400000) {
          await supprimerPaiementEnCours(numCommande);
          continue;
        }

        // Vérifier dans Supabase
        final resultat = await SycaPayService.verifierReferenceSupabase(numCommande);

        final statut = resultat?.statusNormalise ?? 'inconnu';

        resultats.add(PaiementEnAttente(
          numCommande:   numCommande,
          codeTontine:   p['codeTontine'] as String? ?? '',
          operateur:     p['operateur']   as String? ?? '',
          montant:       p['montant']     as int?    ?? 0,
          typeOperation: p['typeOperation'] as String? ?? 'cotisation',
          membreId:      p['membreId']    as String?,
          description:   p['description'] as String?,
          statut:        statut,
          transactionId: resultat?.transactionId,
          createdAt:     DateTime.fromMillisecondsSinceEpoch(createdAt),
        ));

        // Si définitivement terminé → supprimer
        if (statut == 'credited' || statut == 'failed' || statut == 'expired') {
          await supprimerPaiementEnCours(numCommande);
        }
      }

      return resultats;

    } catch (e) {
      if (kDebugMode) debugPrint('[Pending] Erreur vérification: $e');
      return [];
    }
  }

  // ── Helpers privés ────────────────────────────────────────────────────────

  static List<Map<String, dynamic>> _chargerListe(SharedPreferences prefs) {
    try {
      final raw = prefs.getString(_prefKey);
      if (raw == null || raw.isEmpty) return [];
      final list = jsonDecode(raw) as List<dynamic>;
      return list.cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }
}

// ── Modèle ────────────────────────────────────────────────────────────────────

class PaiementEnAttente {
  final String    numCommande;
  final String    codeTontine;
  final String    operateur;
  final int       montant;
  final String    typeOperation;   // 'cotisation' | 'caisse'
  final String?   membreId;
  final String?   description;
  final String    statut;          // 'pending'|'confirmed'|'credited'|'failed'|'expired'|'inconnu'
  final String?   transactionId;
  final DateTime  createdAt;

  const PaiementEnAttente({
    required this.numCommande,
    required this.codeTontine,
    required this.operateur,
    required this.montant,
    required this.typeOperation,
    required this.statut,
    required this.createdAt,
    this.membreId,
    this.description,
    this.transactionId,
  });

  bool get estConfirme => statut == 'confirmed' || statut == 'credited';
  bool get estEnAttente => statut == 'pending' || statut == 'inconnu';
  bool get estEchoue   => statut == 'failed' || statut == 'expired';

  @override
  String toString() =>
      'PaiementEnAttente($numCommande, $statut, $montant XOF, $typeOperation)';
}
