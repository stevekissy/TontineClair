// ═══════════════════════════════════════════════════════════════════════════
// TontineClair — EmailService
// Service centralisé pour l'envoi de tous les e-mails professionnels.
// Délègue à l'Edge Function Supabase `send-email`.
// Jamais bloquant : les échecs sont loggés silencieusement.
// ═══════════════════════════════════════════════════════════════════════════

import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'supabase_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Types d'e-mails disponibles (miroir du TypeScript côté Edge Function)
// ─────────────────────────────────────────────────────────────────────────────
enum TypeEmail {
  codeVerification,
  pinReset,
  pinChangeConfirme,
  invitationTontine,
  demandePret,
  pretValide,
  pretRejete,
  rappelCotisation,
  cotisationEnregistree,
  retardPaiement,
  demandePremium,
  premiumActive,
  premiumExpire,
  kycValide,
  kycRejete,
  nouveauVote,
  resultatVote,
  alerteSecurite,
  messageSupport,
  resetMotDePasse;

  String get valeur => switch (this) {
    TypeEmail.codeVerification      => 'code_verification',
    TypeEmail.pinReset              => 'pin_reset',
    TypeEmail.pinChangeConfirme     => 'pin_change_confirme',
    TypeEmail.invitationTontine     => 'invitation_tontine',
    TypeEmail.demandePret           => 'demande_pret',
    TypeEmail.pretValide            => 'pret_valide',
    TypeEmail.pretRejete            => 'pret_rejete',
    TypeEmail.rappelCotisation      => 'rappel_cotisation',
    TypeEmail.cotisationEnregistree => 'cotisation_enregistree',
    TypeEmail.retardPaiement        => 'retard_paiement',
    TypeEmail.demandePremium        => 'demande_premium',
    TypeEmail.premiumActive         => 'premium_active',
    TypeEmail.premiumExpire         => 'premium_expire',
    TypeEmail.kycValide             => 'kyc_valide',
    TypeEmail.kycRejete             => 'kyc_rejete',
    TypeEmail.nouveauVote           => 'nouveau_vote',
    TypeEmail.resultatVote          => 'resultat_vote',
    TypeEmail.alerteSecurite        => 'alerte_securite',
    TypeEmail.messageSupport        => 'message_support',
    TypeEmail.resetMotDePasse       => 'reset_mot_de_passe',
  };
}

// ─────────────────────────────────────────────────────────────────────────────
// Résultat d'envoi
// ─────────────────────────────────────────────────────────────────────────────
class EmailResult {
  final bool   ok;
  final String? emailId;   // ID Resend si envoi réussi
  final String? logId;     // UUID du email_log Supabase
  final String? erreur;

  const EmailResult({required this.ok, this.emailId, this.logId, this.erreur});

  factory EmailResult.succes({String? emailId, String? logId}) =>
      EmailResult(ok: true, emailId: emailId, logId: logId);

  factory EmailResult.echec(String erreur) =>
      EmailResult(ok: false, erreur: erreur);

  @override
  String toString() => ok
      ? 'EmailResult.succes(id=$emailId)'
      : 'EmailResult.echec($erreur)';
}

// ─────────────────────────────────────────────────────────────────────────────
// EmailService — Singleton
// ─────────────────────────────────────────────────────────────────────────────
class EmailService {
  EmailService._();

  static final _edgeFunctionUrl = '${SupabaseService.supabaseUrl}/functions/v1/send-email';

  // ── Méthode principale : envoyer un e-mail ─────────────────────────────
  static Future<EmailResult> envoyer({
    required TypeEmail         type,
    required String            destinataire,
    required Map<String, String> variables,
    String? tontineCode,
    String? gestNom,
    String? logId,
  }) async {
    try {
      final body = {
        'type':         type.valeur,
        'destinataire': destinataire,
        'variables':    variables,
        if (tontineCode != null) 'tontine_code': tontineCode,
        if (gestNom    != null) 'gest_nom':      gestNom,
        if (logId      != null) 'log_id':        logId,
      };

      final resp = await http.post(
        Uri.parse(_edgeFunctionUrl),
        headers: {
          'Content-Type':  'application/json',
          'Authorization': 'Bearer ${SupabaseService.supabaseAnonKey}',
          'apikey':        SupabaseService.supabaseAnonKey,
        },
        body: jsonEncode(body),
      ).timeout(const Duration(seconds: 15));

      final json = jsonDecode(resp.body) as Map<String, dynamic>;

      if (json['ok'] == true) {
        return EmailResult.succes(
          emailId: json['id'] as String?,
          logId:   json['log_id'] as String?,
        );
      } else {
        final err = json['error'] as String? ?? 'Erreur inconnue';
        if (kDebugMode) debugPrint('[EmailService] Échec : $err');
        return EmailResult.echec(err);
      }
    } catch (e) {
      // Jamais bloquant : on logue l'erreur et on retourne un résultat d'échec
      if (kDebugMode) debugPrint('[EmailService] Exception : $e');
      return EmailResult.echec(e.toString());
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Méthodes spécialisées — une par type d'e-mail
  // ══════════════════════════════════════════════════════════════════════════

  // ── Code de vérification ──────────────────────────────────────────────
  static Future<EmailResult> envoyerCodeVerification({
    required String destinataire,
    required String nom,
    required String code,
  }) => envoyer(
    type:         TypeEmail.codeVerification,
    destinataire: destinataire,
    variables:    {'nom': nom, 'code': code},
  );

  // ── Réinitialisation PIN ──────────────────────────────────────────────
  static Future<EmailResult> envoyerPinReset({
    required String destinataire,
    required String nom,
    required String code,
    required String tontine,
    String?  tontineCode,
  }) => envoyer(
    type:         TypeEmail.pinReset,
    destinataire: destinataire,
    variables:    {'nom': nom, 'code': code, 'tontine': tontine},
    tontineCode:  tontineCode,
    gestNom:      nom,
  );

  // ── PIN modifié confirmé ──────────────────────────────────────────────
  static Future<EmailResult> envoyerPinChangeConfirme({
    required String destinataire,
    required String nom,
    required String tontine,
    String?  tontineCode,
    String?  date,
  }) => envoyer(
    type:         TypeEmail.pinChangeConfirme,
    destinataire: destinataire,
    variables:    {
      'nom':     nom,
      'tontine': tontine,
      'date':    date ?? _formatDate(DateTime.now()),
    },
    tontineCode:  tontineCode,
    gestNom:      nom,
  );

  // ── Invitation tontine ─────────────────────────────────────────────────
  static Future<EmailResult> envoyerInvitation({
    required String destinataire,
    required String nomInvite,
    required String gestionnaire,
    required String tontine,
    required String code,
    String?  montant,
    String?  periodicite,
  }) => envoyer(
    type:         TypeEmail.invitationTontine,
    destinataire: destinataire,
    variables:    {
      'nom':         nomInvite,
      'gestionnaire':gestionnaire,
      'tontine':     tontine,
      'code':        code,
      'montant':     montant ?? '—',
      'periodicite': periodicite ?? '—',
    },
    tontineCode:  code,
  );

  // ── Demande de prêt ────────────────────────────────────────────────────
  static Future<EmailResult> envoyerDemandePret({
    required String destinataire,
    required String nom,
    required String tontine,
    required String montant,
    String?  duree,
    String?  taux,
    String?  tontineCode,
  }) => envoyer(
    type:         TypeEmail.demandePret,
    destinataire: destinataire,
    variables:    {
      'nom':     nom,
      'tontine': tontine,
      'montant': montant,
      'duree':   duree ?? '—',
      'taux':    taux  ?? '—',
    },
    tontineCode: tontineCode,
    gestNom:     nom,
  );

  // ── Prêt validé ───────────────────────────────────────────────────────
  static Future<EmailResult> envoyerPretValide({
    required String destinataire,
    required String nom,
    required String tontine,
    required String montant,
    String?  duree,
    String?  echeance,
    String?  tontineCode,
  }) => envoyer(
    type:         TypeEmail.pretValide,
    destinataire: destinataire,
    variables:    {
      'nom': nom, 'tontine': tontine, 'montant': montant,
      'duree': duree ?? '—', 'echeance': echeance ?? '—',
    },
    tontineCode: tontineCode,
  );

  // ── Prêt rejeté ───────────────────────────────────────────────────────
  static Future<EmailResult> envoyerPretRejete({
    required String destinataire,
    required String nom,
    required String tontine,
    String?  motif,
    String?  tontineCode,
  }) => envoyer(
    type:         TypeEmail.pretRejete,
    destinataire: destinataire,
    variables:    {'nom': nom, 'tontine': tontine, 'motif': motif ?? ''},
    tontineCode:  tontineCode,
  );

  // ── Rappel cotisation ─────────────────────────────────────────────────
  static Future<EmailResult> envoyerRappelCotisation({
    required String destinataire,
    required String nom,
    required String tontine,
    required String montant,
    String?  echeance,
    String?  tour,
    String?  tontineCode,
  }) => envoyer(
    type:         TypeEmail.rappelCotisation,
    destinataire: destinataire,
    variables:    {
      'nom': nom, 'tontine': tontine, 'montant': montant,
      'echeance': echeance ?? '—', 'tour': tour ?? '—',
    },
    tontineCode: tontineCode,
  );

  // ── Cotisation enregistrée ────────────────────────────────────────────
  static Future<EmailResult> envoyerCotisationEnregistree({
    required String destinataire,
    required String nom,
    required String tontine,
    required String montant,
    String?  tour,
    String?  tontineCode,
  }) => envoyer(
    type:         TypeEmail.cotisationEnregistree,
    destinataire: destinataire,
    variables:    {
      'nom': nom, 'tontine': tontine, 'montant': montant,
      'tour': tour ?? '—', 'date': _formatDate(DateTime.now()),
    },
    tontineCode: tontineCode,
  );

  // ── Retard de paiement ────────────────────────────────────────────────
  static Future<EmailResult> envoyerRetardPaiement({
    required String destinataire,
    required String nom,
    required String tontine,
    required String montant,
    String?  echeance,
    String?  joursRetard,
    String?  tontineCode,
  }) => envoyer(
    type:         TypeEmail.retardPaiement,
    destinataire: destinataire,
    variables:    {
      'nom': nom, 'tontine': tontine, 'montant': montant,
      'echeance': echeance ?? '—', 'jours_retard': joursRetard ?? '—',
    },
    tontineCode: tontineCode,
  );

  // ── Demande Premium ───────────────────────────────────────────────────
  static Future<EmailResult> envoyerDemandePremium({
    required String destinataire,
    required String nom,
    required String tontine,
    required String formule,
    required String contact,
    String?  tontineCode,
  }) => envoyer(
    type:         TypeEmail.demandePremium,
    destinataire: destinataire,
    variables:    {
      'nom': nom, 'tontine': tontine, 'formule': formule, 'contact': contact,
    },
    tontineCode: tontineCode,
    gestNom:     nom,
  );

  // ── Premium activé ────────────────────────────────────────────────────
  static Future<EmailResult> envoyerPremiumActive({
    required String destinataire,
    required String nom,
    required String tontine,
    String?  expiration,
    String?  tontineCode,
  }) => envoyer(
    type:         TypeEmail.premiumActive,
    destinataire: destinataire,
    variables:    {
      'nom': nom, 'tontine': tontine,
      'date': _formatDate(DateTime.now()), 'expiration': expiration ?? '—',
    },
    tontineCode: tontineCode,
  );

  // ── Premium expiré ────────────────────────────────────────────────────
  static Future<EmailResult> envoyerPremiumExpire({
    required String destinataire,
    required String nom,
    required String tontine,
    required String expiration,
    String?  tontineCode,
  }) => envoyer(
    type:         TypeEmail.premiumExpire,
    destinataire: destinataire,
    variables:    {'nom': nom, 'tontine': tontine, 'expiration': expiration},
    tontineCode: tontineCode,
  );

  // ── KYC validé ────────────────────────────────────────────────────────
  static Future<EmailResult> envoyerKycValide({
    required String destinataire,
    required String nom,
  }) => envoyer(
    type:         TypeEmail.kycValide,
    destinataire: destinataire,
    variables:    {'nom': nom, 'date': _formatDate(DateTime.now())},
    gestNom:      nom,
  );

  // ── KYC rejeté ────────────────────────────────────────────────────────
  static Future<EmailResult> envoyerKycRejete({
    required String destinataire,
    required String nom,
    String?  motif,
  }) => envoyer(
    type:         TypeEmail.kycRejete,
    destinataire: destinataire,
    variables:    {'nom': nom, 'motif': motif ?? ''},
    gestNom:      nom,
  );

  // ── Nouveau vote ──────────────────────────────────────────────────────
  static Future<EmailResult> envoyerNouveauVote({
    required String destinataire,
    required String nom,
    required String tontine,
    required String sujetVote,
    String?  cloture,
    String?  tontineCode,
  }) => envoyer(
    type:         TypeEmail.nouveauVote,
    destinataire: destinataire,
    variables:    {
      'nom': nom, 'tontine': tontine,
      'sujet_vote': sujetVote, 'cloture': cloture ?? '—',
    },
    tontineCode: tontineCode,
  );

  // ── Résultat vote ─────────────────────────────────────────────────────
  static Future<EmailResult> envoyerResultatVote({
    required String destinataire,
    required String nom,
    required String tontine,
    required String sujetVote,
    required String resultat,
    String?  votesPour,
    String?  votesContre,
    String?  tontineCode,
  }) => envoyer(
    type:         TypeEmail.resultatVote,
    destinataire: destinataire,
    variables:    {
      'nom': nom, 'tontine': tontine, 'sujet_vote': sujetVote,
      'resultat': resultat,
      'votes_pour': votesPour ?? '0', 'votes_contre': votesContre ?? '0',
    },
    tontineCode: tontineCode,
  );

  // ── Alerte de sécurité ────────────────────────────────────────────────
  static Future<EmailResult> envoyerAlerteSecurite({
    required String destinataire,
    required String nom,
    required String action,
    required String message,
    String?  tontine,
    String?  tontineCode,
    String?  gestNom,
  }) => envoyer(
    type:         TypeEmail.alerteSecurite,
    destinataire: destinataire,
    variables:    {
      'nom':     nom,
      'action':  action,
      'message': message,
      'tontine': tontine ?? '—',
      'date':    _formatDate(DateTime.now()),
    },
    tontineCode: tontineCode,
    gestNom:     gestNom ?? nom,
  );

  // ── Message support ───────────────────────────────────────────────────
  static Future<EmailResult> envoyerMessageSupport({
    required String destinataire,
    required String nom,
    required String sujetMessage,
    required String message,
    String?  ticketId,
  }) => envoyer(
    type:         TypeEmail.messageSupport,
    destinataire: destinataire,
    variables:    {
      'nom':       nom,
      'sujet':     sujetMessage,
      'message':   message,
      'ticket_id': ticketId ?? '—',
    },
  );

  // ── Réinitialisation mot de passe ─────────────────────────────────────
  static Future<EmailResult> envoyerResetMotDePasse({
    required String destinataire,
    required String nom,
    required String lien,
    String?  expiration,
  }) => envoyer(
    type:         TypeEmail.resetMotDePasse,
    destinataire: destinataire,
    variables:    {
      'nom':        nom,
      'lien':       lien,
      'expiration': expiration ?? '24 heures',
    },
  );

  // ─── Utilitaire formatage date ─────────────────────────────────────────
  static String _formatDate(DateTime dt) {
    final j = dt.day.toString().padLeft(2, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final h = dt.hour.toString().padLeft(2, '0');
    final min = dt.minute.toString().padLeft(2, '0');
    return '$j/$m/${dt.year} à $h:$min';
  }
}
