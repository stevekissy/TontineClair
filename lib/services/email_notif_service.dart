// ═══════════════════════════════════════════════════════════════════════════
// EmailNotifService — Diffusion email temps réel à TOUS les membres + gestionnaires
//
// Chaque action tontine (cotisation, prêt, remboursement, vote, cycle…)
// déclenche un email immédiat à :
//   1. Tous les gestionnaires (via supabase colonne gestionnaires[].email)
//   2. Tous les membres Premium avec email enregistré (data.membres[].email)
//
// Utilisation :
//   EmailNotifService.diffuserTous(
//     code: tontineCode,
//     data: data,
//     icone: '💰',
//     action: 'Cotisation enregistrée',
//     message: 'La cotisation de <strong>Awa Diallo</strong> a été enregistrée.',
//     gestActif: provider.gestActifNom ?? '',
//   );
//
// ⚡ Toujours fire-and-forget : ne bloque jamais l'UI.
// ═══════════════════════════════════════════════════════════════════════════

import 'package:flutter/foundation.dart';
import '../models/tontine.dart';
import 'supabase_service.dart';
import 'email_service.dart' as email_svc;

class EmailNotifService {
  EmailNotifService._();

  /// Diffuse un email à TOUS les gestionnaires + membres Premium.
  ///
  /// [code]      — code de la tontine (ex: 'TC-ABCD1234')
  /// [data]      — données de la tontine (pour tier, nom, membres fallback)
  /// [icone]     — emoji représentatif du mouvement (ex: '💰', '🔄', '🗳️')
  /// [action]    — titre court de l'action (ex: 'Cotisation enregistrée')
  /// [message]   — corps HTML détaillé du message (peut contenir <strong>, <br>)
  /// [gestActif] — nom du gestionnaire ayant déclenché l'action
  /// [devise]    — code devise pour le formatage (optionnel, pour enrichir le contexte)
  static void diffuserTous({
    required String      code,
    required TontineData data,
    required String      icone,
    required String      action,
    required String      message,
    required String      gestActif,
    String?              devise,
  }) {
    // Fire-and-forget : on ne await pas pour ne jamais bloquer l'UI
    _envoyerAsync(
      code:      code,
      data:      data,
      icone:     icone,
      action:    action,
      message:   message,
      gestActif: gestActif,
    );
  }

  // ── Implémentation asynchrone interne ────────────────────────────────────
  static Future<void> _envoyerAsync({
    required String      code,
    required TontineData data,
    required String      icone,
    required String      action,
    required String      message,
    required String      gestActif,
  }) async {
    final tontineNom = data.nom;
    final dateStr    = _dateHeure();

    // ── 1. Gestionnaires — source principale : REST Supabase ────────────────
    List<Map<String, String>> destinatairesGest =
        await SupabaseService.lireEmailsGestionnaires(code);

    // Fallback local si REST retourne vide
    if (destinatairesGest.isEmpty) {
      for (final g in data.gestionnaires) {
        final email = g.email.trim();
        final nom   = g.nom.trim();
        if (email.isNotEmpty && nom.isNotEmpty) {
          destinatairesGest.add({'nom': nom, 'email': email});
        }
      }
    }

    // ── Envoi aux gestionnaires ──────────────────────────────────────────────
    for (final d in destinatairesGest) {
      _envoyer(
        destinataire: d['email']!,
        nom:          d['nom']!,
        icone:        icone,
        action:       action,
        message:      message,
        tontineNom:   tontineNom,
        dateStr:      dateStr,
        gestActif:    gestActif,
      );
    }

    // ── 2. Membres Premium — lus depuis data.membres[].email ────────────────
    // Disponible sur TOUTES les formules (pas seulement premium/pro) :
    // les membres peuvent avoir un email quel que soit le tier.
    List<Map<String, String>> emailsMembres;
    try {
      emailsMembres = await SupabaseService.lireEmailsMembres(code);
    } catch (e) {
      if (kDebugMode) debugPrint('[EmailNotif] lireEmailsMembres erreur: $e');
      emailsMembres = [];
    }

    // Collecte des emails gestionnaires pour dédupliquer
    final emailsGestSet = destinatairesGest.map((d) => d['email']).toSet();

    for (final m in emailsMembres) {
      final adresse   = m['email']!;
      final nomMembre = m['nom']!;

      // Éviter les doublons (membre qui est aussi gestionnaire)
      if (emailsGestSet.contains(adresse)) continue;

      _envoyer(
        destinataire: adresse,
        nom:          nomMembre,
        icone:        icone,
        action:       action,
        message:      message,
        tontineNom:   tontineNom,
        dateStr:      dateStr,
        gestActif:    gestActif,
      );
    }

    if (kDebugMode) {
      debugPrint('[EmailNotif] ✓ Diffusion "$action" — '
          '${destinatairesGest.length} gest + ${emailsMembres.length} membres');
    }
  }

  // ── Envoi unitaire fire-and-forget ───────────────────────────────────────
  static void _envoyer({
    required String destinataire,
    required String nom,
    required String icone,
    required String action,
    required String message,
    required String tontineNom,
    required String dateStr,
    required String gestActif,
  }) {
    email_svc.EmailService.envoyer(
      type:         email_svc.TypeEmail.alerteSecurite,
      destinataire: destinataire,
      variables: {
        'nom':        nom,
        'action':     '$icone $action — $tontineNom',
        'message':    message,
        'tontine':    tontineNom,
        'date':       dateStr,
        'gest_actif': gestActif,
      },
    ).then((result) {
      if (kDebugMode) {
        if (result.ok) {
          debugPrint('[EmailNotif] ✓ $destinataire (id=${result.emailId})');
        } else {
          debugPrint('[EmailNotif] ✗ $destinataire : ${result.erreur}');
        }
      }
    }).catchError((Object e) {
      if (kDebugMode) debugPrint('[EmailNotif] ✗ Exception $destinataire : $e');
    });
  }

  // ── Helpers ──────────────────────────────────────────────────────────────
  static String _dateHeure() {
    final d = DateTime.now().toLocal();
    final dd = d.day.toString().padLeft(2, '0');
    final mm = d.month.toString().padLeft(2, '0');
    final hh = d.hour.toString().padLeft(2, '0');
    final mi = d.minute.toString().padLeft(2, '0');
    return '$dd/$mm/${d.year} à $hh:$mi';
  }

  // ── Builders de messages HTML prêts à l'emploi ───────────────────────────

  static String msgCotisation(String membreNom, String montantStr, String tontineNom) =>
      'La cotisation de <strong>$membreNom</strong> de <strong>$montantStr</strong> '
      'a été enregistrée dans la tontine <strong>$tontineNom</strong>.';

  static String msgCotisationEnAttente(String membreNom, String tontineNom) =>
      '<strong>$membreNom</strong> a déclaré sa cotisation dans '
      '<strong>$tontineNom</strong> — en attente d\'approbation par un gestionnaire.';

  static String msgCotisationApprouvee(String membreNom, String montantStr, String approbateur) =>
      'La cotisation de <strong>$membreNom</strong> de <strong>$montantStr</strong> '
      'a été <strong>approuvée</strong> par $approbateur.';

  static String msgCotisationAnnulee(String membreNom, String montantStr, int tour) =>
      'La cotisation de <strong>$membreNom</strong> (Tour $tour, <strong>$montantStr</strong>) '
      'a été <strong>annulée</strong>.';

  static String msgPret(String emprunteurNom, String montantStr, double taux, int duree) =>
      'Un prêt de <strong>$montantStr</strong> a été accordé à <strong>$emprunteurNom</strong>.'
      '<br>Taux : $taux% — Durée : $duree mois.';

  static String msgRemboursement(String emprunteurNom, String montantStr, String resteStr, {bool solde = false}) =>
      solde
        ? '<strong>$emprunteurNom</strong> a <strong>soldé intégralement</strong> son prêt '
          '(dernier versement : <strong>$montantStr</strong>). Prêt clôturé ✅'
        : '<strong>$emprunteurNom</strong> a effectué un remboursement de '
          '<strong>$montantStr</strong>. Reste dû : <strong>$resteStr</strong>.';

  static String msgAnnulationRemboursement(String emprunteurNom, String montantStr, String ref) =>
      'Le remboursement de <strong>$montantStr</strong> de <strong>$emprunteurNom</strong> '
      '(réf. $ref) a été <strong>annulé</strong>. La caisse a été corrigée.';

  static String msgVoteOuvert(String question) =>
      'Un nouveau vote a été ouvert :<br><strong>« $question »</strong><br><br>'
      'Connectez-vous pour exprimer votre voix.';

  static String msgVoteEnregistre(String question) =>
      'Un vote a été enregistré sur :<br><strong>« $question »</strong>';

  static String msgVoteClos(String question, bool adopte) =>
      adopte
        ? 'Le vote <strong>« $question »</strong> a été <strong>adopté ✅</strong>.'
        : 'Le vote <strong>« $question »</strong> a été <strong>rejeté ❌</strong>.';

  static String msgNouveauMembre(String membreNom) =>
      '<strong>$membreNom</strong> a été admis(e) dans la tontine suite au vote des membres.';

  static String msgNouveauCycle(int cycleNum, String tontineNom) =>
      'Le <strong>Cycle $cycleNum</strong> de la tontine <strong>$tontineNom</strong> '
      'vient de démarrer. Tour 1 en cours — les cotisations sont ouvertes.';
}
