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
  // Compatible avec la fonction déployée qui attend {to, subject, html}
  // et retourne {success:true, data:{id}} ou {error:"message"}
  static Future<EmailResult> envoyer({
    required TypeEmail         type,
    required String            destinataire,
    required Map<String, String> variables,
    String? tontineCode,
    String? gestNom,
    String? logId,
  }) async {
    try {
      // Génère sujet + HTML côté Flutter selon le type
      final sujet = _sujetPourType(type, variables);
      final html  = _htmlPourType(type, variables);

      // Format attendu par la fonction déployée : {to, subject, html}
      final body = {
        'to':      destinataire,
        'subject': sujet,
        'html':    html,
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

      // Supporte les deux formats : {success:true} et {ok:true}
      final estSucces = json['success'] == true || json['ok'] == true;
      if (estSucces) {
        final id = (json['data'] as Map<String, dynamic>?)?['id'] as String?
            ?? json['id'] as String?;
        return EmailResult.succes(emailId: id);
      } else {
        final err = json['error'] as String? ?? 'Erreur inconnue';
        if (kDebugMode) debugPrint('[EmailService] Échec : $err');
        return EmailResult.echec(err);
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[EmailService] Exception : $e');
      return EmailResult.echec(e.toString());
    }
  }

  // ── Génère le sujet selon le type ─────────────────────────────────────
  static String _sujetPourType(TypeEmail type, Map<String, String> v) {
    switch (type) {
      case TypeEmail.codeVerification:
        return '[TontineClair] Votre code de vérification : ${v['code'] ?? ''}';
      case TypeEmail.pinReset:
        return '[TontineClair] Réinitialisation de votre PIN — Code : ${v['code'] ?? ''}';
      case TypeEmail.pinChangeConfirme:
        return '[TontineClair] Votre PIN de gestion a été modifié';
      case TypeEmail.invitationTontine:
        return '[TontineClair] Invitation à rejoindre "${v['tontine'] ?? ''}"';
      case TypeEmail.demandePret:
        return '[TontineClair] Demande de prêt reçue — ${v['tontine'] ?? ''}';
      case TypeEmail.pretValide:
        return '[TontineClair] ✅ Votre prêt de ${v['montant'] ?? ''} a été validé';
      case TypeEmail.pretRejete:
        return "[TontineClair] Votre demande de prêt n'a pas été accordée";
      case TypeEmail.rappelCotisation:
        return '[TontineClair] Rappel : votre cotisation est attendue';
      case TypeEmail.cotisationEnregistree:
        return '[TontineClair] ✅ Cotisation enregistrée — ${v['tontine'] ?? ''}';
      case TypeEmail.retardPaiement:
        return '[TontineClair] ⚠️ Retard de paiement — ${v['tontine'] ?? ''}';
      case TypeEmail.demandePremium:
        return "[TontineClair] Demande d'activation Premium reçue";
      case TypeEmail.premiumActive:
        return '[TontineClair] 🌟 Votre tontine est maintenant Premium !';
      case TypeEmail.premiumExpire:
        return '[TontineClair] Votre abonnement Premium arrive à expiration';
      case TypeEmail.kycValide:
        return "[TontineClair] ✅ Vérification d'identité validée";
      case TypeEmail.kycRejete:
        return "[TontineClair] Vérification d'identité — action requise";
      case TypeEmail.nouveauVote:
        return '[TontineClair] 🗳️ Nouveau vote ouvert — ${v['tontine'] ?? ''}';
      case TypeEmail.resultatVote:
        return '[TontineClair] Résultat du vote — ${v['tontine'] ?? ''}';
      case TypeEmail.alerteSecurite:
        return '[TontineClair] 🚨 Alerte de sécurité sur votre compte';
      case TypeEmail.messageSupport:
        return '[TontineClair] Votre message au support a été reçu';
      case TypeEmail.resetMotDePasse:
        return '[TontineClair] Réinitialisation de votre mot de passe';
    }
  }

  // ── Génère le HTML selon le type ──────────────────────────────────────
  static String _htmlPourType(TypeEmail type, Map<String, String> v) {
    final nom  = v['nom']  ?? 'Gestionnaire';
    final code = v['code'] ?? '';
    switch (type) {
      case TypeEmail.codeVerification:
        return _layoutBase(
          sujet: 'Code de vérification',
          contenu: '''
            <h2 style="color:#1C2447;margin-bottom:16px">🔐 Code de vérification</h2>
            <p style="font-size:15px;color:#374151;line-height:1.6;margin-bottom:16px">
              Bonjour <strong>$nom</strong>,<br><br>
              Voici votre code de vérification pour créer votre tontine TontineClair :
            </p>
            <div style="background:#F7F7F4;border:2px dashed #D99A2B;border-radius:12px;padding:24px;text-align:center;margin:24px 0">
              <div style="font-size:42px;font-weight:800;color:#1C2447;letter-spacing:10px;font-family:monospace">$code</div>
              <div style="font-size:12px;color:#6B7280;margin-top:8px">⏱ Valable 10 minutes</div>
            </div>
            <div style="background:#FDECEA;border-left:4px solid #C4453C;border-radius:8px;padding:14px 16px;margin:16px 0">
              <p style="color:#C4453C;font-size:14px;font-weight:600;margin:0">
                ⚠️ Ne partagez jamais ce code. TontineClair ne vous le demandera jamais par téléphone.
              </p>
            </div>
            <p style="font-size:13px;color:#6B7280;line-height:1.6">
              Si vous n'êtes pas à l'origine de cette demande, ignorez cet e-mail.
            </p>
          ''',
        );
      case TypeEmail.pinReset:
        return _layoutBase(
          sujet: 'Réinitialisation PIN',
          contenu: '''
            <h2 style="color:#1C2447;margin-bottom:16px">🔑 Réinitialisation de votre PIN</h2>
            <p style="font-size:15px;color:#374151;line-height:1.6;margin-bottom:16px">
              Bonjour <strong>$nom</strong>,<br><br>
              Voici votre code de réinitialisation PIN pour la tontine <strong>${v['tontine'] ?? ''}</strong> :
            </p>
            <div style="background:#F7F7F4;border:2px dashed #C4453C;border-radius:12px;padding:24px;text-align:center;margin:24px 0">
              <div style="font-size:42px;font-weight:800;color:#1C2447;letter-spacing:10px;font-family:monospace">$code</div>
              <div style="font-size:12px;color:#6B7280;margin-top:8px">⏱ Valable 10 minutes — usage unique</div>
            </div>
            <div style="background:#FDECEA;border-left:4px solid #C4453C;border-radius:8px;padding:14px 16px;margin:16px 0">
              <p style="color:#C4453C;font-size:14px;font-weight:600;margin:0">
                🚨 Si vous n'avez pas demandé cette réinitialisation, contactez support@tontineclair.com
              </p>
            </div>
          ''',
        );
      default:
        // Template générique pour tous les autres types
        return _layoutBase(
          sujet: _sujetPourType(type, v).replaceAll('[TontineClair] ', ''),
          contenu: '''
            <h2 style="color:#1C2447;margin-bottom:16px">${_sujetPourType(type, v).replaceAll('[TontineClair] ', '')}</h2>
            <p style="font-size:15px;color:#374151;line-height:1.6">
              Bonjour <strong>$nom</strong>,<br><br>
              ${v['message'] ?? 'Vous avez reçu une notification de TontineClair.'}
            </p>
          ''',
        );
    }
  }

  // ── Layout HTML de base ───────────────────────────────────────────────
  static String _layoutBase({required String sujet, required String contenu}) {
    return '''<!DOCTYPE html>
<html lang="fr"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>$sujet</title></head>
<body style="margin:0;padding:0;background:#F7F7F4;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif">
<div style="max-width:600px;margin:0 auto;padding:24px 16px 48px">
  <div style="background:#fff;border-radius:16px;overflow:hidden;box-shadow:0 2px 12px rgba(28,36,71,0.08)">
    <!-- Header -->
    <div style="background:#1C2447;padding:28px 32px;text-align:center">
      <div style="color:#fff;font-size:24px;font-weight:800">Tontine<span style="color:#D99A2B">Clair</span></div>
      <div style="color:rgba(255,255,255,0.6);font-size:11px;margin-top:4px">La tontine simple, transparente et sécurisée</div>
    </div>
    <div style="height:4px;background:linear-gradient(90deg,#D99A2B,#F5E6C5)"></div>
    <!-- Corps -->
    <div style="padding:36px 32px">
      $contenu
      <!-- Signature -->
      <hr style="border:none;border-top:1px solid #E8E8E4;margin:28px 0">
      <div style="font-size:14px;color:#1C2447;line-height:1.8">
        Cordialement,<br><br>
        <strong style="color:#D99A2B">L'équipe TontineClair</strong><br>
        <em>La tontine simple, transparente et sécurisée</em><br><br>
        📧 <a href="mailto:support@tontineclair.com" style="color:#D99A2B">support@tontineclair.com</a>
      </div>
    </div>
    <!-- Footer -->
    <div style="background:#1C2447;padding:20px 32px;text-align:center">
      <div style="color:rgba(255,255,255,0.5);font-size:11px">© ${DateTime.now().year} TontineClair – Tous droits réservés</div>
      <div style="color:rgba(255,255,255,0.4);font-size:11px;margin-top:6px;font-style:italic">Message automatique — merci de ne pas répondre directement.</div>
    </div>
  </div>
</div>
</body></html>''';
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
