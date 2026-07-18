// ═══════════════════════════════════════════════════════════════════════════
// TontineClair — Edge Function : send-email
// Système centralisé d'envoi d'e-mails professionnels
// Compatible Resend / SMTP / Mailgun / SendGrid
// ═══════════════════════════════════════════════════════════════════════════

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// ─── Configuration ──────────────────────────────────────────────────────────
const RESEND_API_KEY      = Deno.env.get("RESEND_API_KEY")      ?? "";
const SUPABASE_URL        = Deno.env.get("SUPABASE_URL")        ?? "";
const SUPABASE_SERVICE_KEY= Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

const FROM_NOREPLY   = "TontineClair <no-reply@tontineclair.com>";
const FROM_SUPPORT   = "Support TontineClair <support@tontineclair.com>";
const FROM_SECURITE  = "Sécurité TontineClair <securite@tontineclair.com>";
const SITE_URL       = "https://www.tontineclair.com";
const ANNEE          = new Date().getFullYear();

// ─── Types ──────────────────────────────────────────────────────────────────
interface EmailRequest {
  type:        EmailType;
  destinataire: string;
  variables:   Record<string, string>;
  tontine_code?: string;
  gest_nom?:   string;
  log_id?:     string; // UUID du log à mettre à jour
}

type EmailType =
  | "code_verification"
  | "pin_reset"
  | "pin_change_confirme"
  | "invitation_tontine"
  | "demande_pret"
  | "pret_valide"
  | "pret_rejete"
  | "rappel_cotisation"
  | "cotisation_enregistree"
  | "retard_paiement"
  | "demande_premium"
  | "premium_active"
  | "premium_expire"
  | "kyc_valide"
  | "kyc_rejete"
  | "nouveau_vote"
  | "resultat_vote"
  | "alerte_securite"
  | "message_support"
  | "reset_mot_de_passe";

// ─── Palette TontineClair ────────────────────────────────────────────────────
const C = {
  encre:     "#1C2447",
  or:        "#D99A2B",
  orClair:   "#F5E6C5",
  succes:    "#2E7D5B",
  succesFond:"#E8F5EF",
  alerte:    "#C4453C",
  alerteFond:"#FDECEA",
  blanc:     "#FFFFFF",
  gris:      "#F7F7F4",
  grisDoux:  "#E8E8E4",
  texteDoux: "#6B7280",
};

// ─── Layout HTML de base ─────────────────────────────────────────────────────
function baseLayout(params: {
  sujet:       string;
  contenu:     string;
  couleurAccent?: string;
  from_type?:  "noreply" | "support" | "securite";
}): string {
  const accent = params.couleurAccent ?? C.or;
  return `<!DOCTYPE html>
<html lang="fr">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <meta http-equiv="X-UA-Compatible" content="IE=edge">
  <title>${params.sujet}</title>
  <!--[if mso]><noscript><xml><o:OfficeDocumentSettings><o:PixelsPerInch>96</o:PixelsPerInch></o:OfficeDocumentSettings></xml></noscript><![endif]-->
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, sans-serif; background-color: ${C.gris}; color: ${C.encre}; -webkit-text-size-adjust: 100%; }
    .wrapper { width: 100%; max-width: 600px; margin: 0 auto; padding: 24px 16px 48px; }
    .card { background: ${C.blanc}; border-radius: 16px; overflow: hidden; box-shadow: 0 2px 12px rgba(28,36,71,0.08); }
    .header { background: ${C.encre}; padding: 28px 32px; text-align: center; }
    .logo-text { color: ${C.blanc}; font-size: 24px; font-weight: 800; letter-spacing: -0.5px; }
    .logo-clair { color: ${C.or}; }
    .logo-tag { color: rgba(255,255,255,0.6); font-size: 11px; margin-top: 4px; }
    .accent-bar { height: 4px; background: linear-gradient(90deg, ${accent} 0%, ${C.or} 100%); }
    .body { padding: 36px 32px; }
    .h1 { font-size: 22px; font-weight: 800; color: ${C.encre}; margin-bottom: 16px; line-height: 1.3; }
    .p { font-size: 15px; color: #374151; line-height: 1.65; margin-bottom: 16px; }
    .p-light { font-size: 13px; color: ${C.texteDoux}; line-height: 1.6; margin-bottom: 12px; }
    .code-box { background: ${C.gris}; border: 2px dashed ${accent}; border-radius: 12px; padding: 20px; text-align: center; margin: 24px 0; }
    .code-val { font-size: 40px; font-weight: 800; color: ${C.encre}; letter-spacing: 8px; font-family: 'Courier New', monospace; }
    .code-exp { font-size: 12px; color: ${C.texteDoux}; margin-top: 8px; }
    .btn { display: inline-block; background: ${C.encre}; color: ${C.blanc} !important; text-decoration: none; padding: 14px 32px; border-radius: 10px; font-weight: 700; font-size: 15px; margin: 20px 0; }
    .btn-or { background: ${C.or}; }
    .btn-succes { background: ${C.succes}; }
    .alert-box { background: ${C.alerteFond}; border-left: 4px solid ${C.alerte}; border-radius: 8px; padding: 14px 16px; margin: 20px 0; }
    .alert-box p { color: ${C.alerte}; font-size: 14px; font-weight: 600; margin: 0; }
    .succes-box { background: ${C.succesFond}; border-left: 4px solid ${C.succes}; border-radius: 8px; padding: 14px 16px; margin: 20px 0; }
    .succes-box p { color: ${C.succes}; font-size: 14px; font-weight: 600; margin: 0; }
    .info-grid { background: ${C.gris}; border-radius: 10px; padding: 16px; margin: 20px 0; }
    .info-row { display: flex; justify-content: space-between; padding: 6px 0; border-bottom: 1px solid ${C.grisDoux}; font-size: 14px; }
    .info-row:last-child { border-bottom: none; }
    .info-label { color: ${C.texteDoux}; }
    .info-val { font-weight: 600; color: ${C.encre}; }
    .divider { height: 1px; background: ${C.grisDoux}; margin: 28px 0; }
    .signature { font-size: 14px; color: ${C.encre}; line-height: 1.8; }
    .signature strong { color: ${C.encre}; }
    .signature .team { color: ${C.or}; font-weight: 700; }
    .footer { background: ${C.encre}; padding: 24px 32px; text-align: center; }
    .footer a { color: rgba(255,255,255,0.7); font-size: 12px; text-decoration: none; margin: 0 8px; }
    .footer a:hover { color: ${C.or}; }
    .footer-copy { color: rgba(255,255,255,0.5); font-size: 11px; margin-top: 12px; }
    .footer-auto { color: rgba(255,255,255,0.4); font-size: 11px; margin-top: 8px; font-style: italic; }
    @media (max-width: 480px) {
      .body { padding: 24px 20px; }
      .header { padding: 20px; }
      .btn { width: 100%; text-align: center; padding: 14px 20px; }
      .code-val { font-size: 32px; }
    }
  </style>
</head>
<body>
<div class="wrapper">
  <div class="card">
    <!-- En-tête -->
    <div class="header">
      <div class="logo-text">Tontine<span class="logo-clair">Clair</span></div>
      <div class="logo-tag">La tontine simple, transparente et sécurisée</div>
    </div>
    <div class="accent-bar"></div>
    <!-- Corps -->
    <div class="body">
      ${params.contenu}
      <!-- Signature -->
      <div class="divider"></div>
      <div class="signature">
        Cordialement,<br><br>
        <strong class="team">L'équipe TontineClair</strong><br>
        <em>La tontine simple, transparente et sécurisée</em><br><br>
        📧 <a href="mailto:support@tontineclair.com" style="color:${C.or}">support@tontineclair.com</a><br>
        🌐 <a href="${SITE_URL}" style="color:${C.or}">www.tontineclair.com</a>
      </div>
    </div>
    <!-- Pied de page -->
    <div class="footer">
      <div>
        <a href="${SITE_URL}/confidentialite">Politique de confidentialité</a>
        <a href="${SITE_URL}/conditions">Conditions d'utilisation</a>
        <a href="mailto:support@tontineclair.com">Support</a>
      </div>
      <div class="footer-copy">© ${ANNEE} TontineClair – Tous droits réservés</div>
      <div class="footer-auto">Ce message a été envoyé automatiquement. Merci de ne pas répondre directement.</div>
    </div>
  </div>
</div>
</body>
</html>`;
}

// ─── Modèles d'e-mails ───────────────────────────────────────────────────────
const TEMPLATES: Record<EmailType, (v: Record<string, string>) => {
  sujet: string; html: string; from: string;
}> = {

  code_verification: (v) => ({
    from: FROM_SECURITE,
    sujet: `[TontineClair] Votre code de vérification : ${v.code}`,
    html: baseLayout({ sujet: "Code de vérification", couleurAccent: C.encre, contenu: `
      <h1 class="h1">🔐 Code de vérification</h1>
      <p class="p">Bonjour <strong>${v.nom ?? "Gestionnaire"}</strong>,</p>
      <p class="p">Vous avez demandé un code de vérification pour votre compte TontineClair. Utilisez le code ci-dessous :</p>
      <div class="code-box">
        <div class="code-val">${v.code}</div>
        <div class="code-exp">⏱ Ce code expire dans <strong>10 minutes</strong></div>
      </div>
      <div class="alert-box"><p>⚠️ Ne partagez jamais ce code. TontineClair ne vous le demandera jamais par téléphone.</p></div>
      <p class="p-light">Si vous n'êtes pas à l'origine de cette demande, ignorez cet e-mail.</p>
    `}),
  }),

  pin_reset: (v) => ({
    from: FROM_SECURITE,
    sujet: `[TontineClair] Réinitialisation de votre PIN — Code : ${v.code}`,
    html: baseLayout({ sujet: "Réinitialisation PIN", couleurAccent: C.alerte, contenu: `
      <h1 class="h1">🔑 Réinitialisation de votre PIN de gestion</h1>
      <p class="p">Bonjour <strong>${v.nom ?? "Gestionnaire"}</strong>,</p>
      <p class="p">Vous avez demandé la réinitialisation de votre PIN de gestion pour la tontine <strong>${v.tontine ?? ""}</strong>.</p>
      <p class="p">Voici votre code de vérification à usage unique :</p>
      <div class="code-box">
        <div class="code-val">${v.code}</div>
        <div class="code-exp">⏱ Ce code expire dans <strong>10 minutes</strong></div>
      </div>
      <div class="alert-box">
        <p>🚨 Si vous n'avez pas demandé cette réinitialisation, contactez immédiatement notre support à <a href="mailto:securite@tontineclair.com">securite@tontineclair.com</a></p>
      </div>
      <p class="p-light">Pour des raisons de sécurité, ce code ne peut être utilisé qu'une seule fois et expire après 10 minutes.</p>
    `}),
  }),

  pin_change_confirme: (v) => ({
    from: FROM_SECURITE,
    sujet: "[TontineClair] Votre PIN de gestion a été modifié",
    html: baseLayout({ sujet: "PIN modifié", couleurAccent: C.succes, contenu: `
      <h1 class="h1">✅ Modification du PIN confirmée</h1>
      <p class="p">Bonjour <strong>${v.nom ?? "Gestionnaire"}</strong>,</p>
      <div class="succes-box"><p>✅ Votre PIN de gestion TontineClair a été modifié avec succès.</p></div>
      <div class="info-grid">
        <div class="info-row"><span class="info-label">Tontine</span><span class="info-val">${v.tontine ?? "—"}</span></div>
        <div class="info-row"><span class="info-label">Date</span><span class="info-val">${v.date ?? new Date().toLocaleString("fr-FR")}</span></div>
        <div class="info-row"><span class="info-label">Action</span><span class="info-val">Modification du PIN de gestion</span></div>
      </div>
      <div class="alert-box">
        <p>🚨 Si vous n'êtes pas à l'origine de cette modification, contactez immédiatement notre support : <a href="mailto:securite@tontineclair.com">securite@tontineclair.com</a></p>
      </div>
      <p class="p-light">Pour votre sécurité, ne communiquez jamais votre PIN à quiconque, y compris l'équipe TontineClair.</p>
    `}),
  }),

  invitation_tontine: (v) => ({
    from: FROM_NOREPLY,
    sujet: `[TontineClair] ${v.gestionnaire} vous invite à rejoindre "${v.tontine}"`,
    html: baseLayout({ sujet: "Invitation tontine", couleurAccent: C.or, contenu: `
      <h1 class="h1">🤝 Invitation à rejoindre une tontine</h1>
      <p class="p">Bonjour <strong>${v.nom ?? ""}</strong>,</p>
      <p class="p"><strong>${v.gestionnaire}</strong> vous invite à rejoindre la tontine <strong>"${v.tontine}"</strong> sur TontineClair.</p>
      <div class="info-grid">
        <div class="info-row"><span class="info-label">Tontine</span><span class="info-val">${v.tontine}</span></div>
        <div class="info-row"><span class="info-label">Code d'accès</span><span class="info-val">${v.code ?? "—"}</span></div>
        <div class="info-row"><span class="info-label">Cotisation</span><span class="info-val">${v.montant ?? "—"}</span></div>
        <div class="info-row"><span class="info-label">Périodicité</span><span class="info-val">${v.periodicite ?? "—"}</span></div>
      </div>
      <div style="text-align:center">
        <a href="${SITE_URL}" class="btn btn-or">Rejoindre la tontine</a>
      </div>
      <p class="p-light">Utilisez le code <strong>${v.code ?? ""}</strong> pour accéder à la tontine depuis l'application TontineClair.</p>
    `}),
  }),

  demande_pret: (v) => ({
    from: FROM_NOREPLY,
    sujet: `[TontineClair] Demande de prêt reçue — ${v.tontine}`,
    html: baseLayout({ sujet: "Demande de prêt", contenu: `
      <h1 class="h1">💳 Demande de prêt reçue</h1>
      <p class="p">Bonjour <strong>${v.nom ?? ""}</strong>,</p>
      <p class="p">Votre demande de prêt sur la tontine <strong>${v.tontine}</strong> a bien été enregistrée.</p>
      <div class="info-grid">
        <div class="info-row"><span class="info-label">Montant demandé</span><span class="info-val">${v.montant ?? "—"}</span></div>
        <div class="info-row"><span class="info-label">Durée</span><span class="info-val">${v.duree ?? "—"}</span></div>
        <div class="info-row"><span class="info-label">Taux</span><span class="info-val">${v.taux ?? "—"}</span></div>
        <div class="info-row"><span class="info-label">Statut</span><span class="info-val">En attente de validation</span></div>
      </div>
      <p class="p">Le gestionnaire de la tontine examinera votre demande. Vous recevrez une notification dès validation.</p>
    `}),
  }),

  pret_valide: (v) => ({
    from: FROM_NOREPLY,
    sujet: `[TontineClair] ✅ Votre prêt de ${v.montant} a été validé`,
    html: baseLayout({ sujet: "Prêt validé", couleurAccent: C.succes, contenu: `
      <h1 class="h1">✅ Prêt approuvé</h1>
      <p class="p">Bonjour <strong>${v.nom ?? ""}</strong>,</p>
      <div class="succes-box"><p>Votre demande de prêt a été approuvée par le gestionnaire de la tontine <strong>${v.tontine}</strong>.</p></div>
      <div class="info-grid">
        <div class="info-row"><span class="info-label">Montant accordé</span><span class="info-val">${v.montant ?? "—"}</span></div>
        <div class="info-row"><span class="info-label">Durée</span><span class="info-val">${v.duree ?? "—"}</span></div>
        <div class="info-row"><span class="info-label">Remboursement</span><span class="info-val">${v.echeance ?? "—"}</span></div>
      </div>
      <p class="p">Connectez-vous à l'application TontineClair pour consulter les détails de votre prêt.</p>
    `}),
  }),

  pret_rejete: (v) => ({
    from: FROM_NOREPLY,
    sujet: `[TontineClair] Votre demande de prêt n'a pas été accordée`,
    html: baseLayout({ sujet: "Prêt refusé", couleurAccent: C.alerte, contenu: `
      <h1 class="h1">❌ Demande de prêt non accordée</h1>
      <p class="p">Bonjour <strong>${v.nom ?? ""}</strong>,</p>
      <p class="p">Votre demande de prêt sur la tontine <strong>${v.tontine}</strong> n'a pas pu être accordée.</p>
      ${v.motif ? `<div class="alert-box"><p>Motif : ${v.motif}</p></div>` : ""}
      <p class="p">Vous pouvez contacter le gestionnaire de la tontine pour plus d'informations.</p>
    `}),
  }),

  rappel_cotisation: (v) => ({
    from: FROM_NOREPLY,
    sujet: `[TontineClair] Rappel : votre cotisation pour "${v.tontine}" est attendue`,
    html: baseLayout({ sujet: "Rappel cotisation", contenu: `
      <h1 class="h1">⏰ Rappel de cotisation</h1>
      <p class="p">Bonjour <strong>${v.nom ?? ""}</strong>,</p>
      <p class="p">Votre cotisation pour la tontine <strong>${v.tontine}</strong> est attendue prochainement.</p>
      <div class="info-grid">
        <div class="info-row"><span class="info-label">Montant</span><span class="info-val">${v.montant ?? "—"}</span></div>
        <div class="info-row"><span class="info-label">Date limite</span><span class="info-val">${v.echeance ?? "—"}</span></div>
        <div class="info-row"><span class="info-label">Tour</span><span class="info-val">${v.tour ?? "—"}</span></div>
      </div>
      <p class="p">Connectez-vous à l'application pour effectuer votre paiement à temps.</p>
    `}),
  }),

  cotisation_enregistree: (v) => ({
    from: FROM_NOREPLY,
    sujet: `[TontineClair] ✅ Cotisation enregistrée — ${v.tontine}`,
    html: baseLayout({ sujet: "Cotisation enregistrée", couleurAccent: C.succes, contenu: `
      <h1 class="h1">✅ Cotisation enregistrée</h1>
      <p class="p">Bonjour <strong>${v.nom ?? ""}</strong>,</p>
      <div class="succes-box"><p>Votre cotisation a bien été enregistrée sur la tontine <strong>${v.tontine}</strong>.</p></div>
      <div class="info-grid">
        <div class="info-row"><span class="info-label">Montant</span><span class="info-val">${v.montant ?? "—"}</span></div>
        <div class="info-row"><span class="info-label">Tour</span><span class="info-val">${v.tour ?? "—"}</span></div>
        <div class="info-row"><span class="info-label">Date</span><span class="info-val">${v.date ?? new Date().toLocaleDateString("fr-FR")}</span></div>
      </div>
    `}),
  }),

  retard_paiement: (v) => ({
    from: FROM_NOREPLY,
    sujet: `[TontineClair] ⚠️ Retard de paiement — ${v.tontine}`,
    html: baseLayout({ sujet: "Retard paiement", couleurAccent: C.alerte, contenu: `
      <h1 class="h1">⚠️ Retard de paiement détecté</h1>
      <p class="p">Bonjour <strong>${v.nom ?? ""}</strong>,</p>
      <div class="alert-box"><p>Votre cotisation pour la tontine <strong>${v.tontine}</strong> est en retard.</p></div>
      <div class="info-grid">
        <div class="info-row"><span class="info-label">Montant dû</span><span class="info-val">${v.montant ?? "—"}</span></div>
        <div class="info-row"><span class="info-label">Échéance dépassée</span><span class="info-val">${v.echeance ?? "—"}</span></div>
        <div class="info-row"><span class="info-label">Jours de retard</span><span class="info-val">${v.jours_retard ?? "—"}</span></div>
      </div>
      <p class="p">Régularisez votre situation au plus vite pour éviter des pénalités.</p>
    `}),
  }),

  demande_premium: (v) => ({
    from: FROM_NOREPLY,
    sujet: `[TontineClair] Demande d'activation Premium reçue`,
    html: baseLayout({ sujet: "Demande Premium", couleurAccent: C.or, contenu: `
      <h1 class="h1">⭐ Demande d'activation Premium</h1>
      <p class="p">Bonjour <strong>${v.nom ?? ""}</strong>,</p>
      <p class="p">Votre demande d'activation Premium pour la tontine <strong>${v.tontine}</strong> a bien été reçue.</p>
      <div class="info-grid">
        <div class="info-row"><span class="info-label">Formule</span><span class="info-val">${v.formule ?? "—"}</span></div>
        <div class="info-row"><span class="info-label">Contact</span><span class="info-val">${v.contact ?? "—"}</span></div>
        <div class="info-row"><span class="info-label">Statut</span><span class="info-val">En cours de traitement</span></div>
      </div>
      <p class="p">L'équipe TontineClair vous contactera pour finaliser l'activation.</p>
    `}),
  }),

  premium_active: (v) => ({
    from: FROM_NOREPLY,
    sujet: `[TontineClair] 🌟 Votre tontine "${v.tontine}" est maintenant Premium !`,
    html: baseLayout({ sujet: "Premium activé", couleurAccent: C.or, contenu: `
      <h1 class="h1">🌟 Félicitations ! Premium activé</h1>
      <p class="p">Bonjour <strong>${v.nom ?? ""}</strong>,</p>
      <div class="succes-box"><p>La tontine <strong>${v.tontine}</strong> bénéficie désormais du plan Premium TontineClair !</p></div>
      <div class="info-grid">
        <div class="info-row"><span class="info-label">Plan</span><span class="info-val">Premium ⭐</span></div>
        <div class="info-row"><span class="info-label">Activation</span><span class="info-val">${v.date ?? new Date().toLocaleDateString("fr-FR")}</span></div>
        <div class="info-row"><span class="info-label">Expiration</span><span class="info-val">${v.expiration ?? "—"}</span></div>
      </div>
      <p class="p">Profitez de toutes les fonctionnalités avancées : Mobile Money, décaissements automatiques, KYC, et plus encore.</p>
    `}),
  }),

  premium_expire: (v) => ({
    from: FROM_NOREPLY,
    sujet: `[TontineClair] Votre abonnement Premium arrive à expiration`,
    html: baseLayout({ sujet: "Expiration Premium", couleurAccent: C.alerte, contenu: `
      <h1 class="h1">⏰ Abonnement Premium bientôt expiré</h1>
      <p class="p">Bonjour <strong>${v.nom ?? ""}</strong>,</p>
      <div class="alert-box"><p>L'abonnement Premium de la tontine <strong>${v.tontine}</strong> expire le <strong>${v.expiration ?? "—"}</strong>.</p></div>
      <p class="p">Renouvelez votre abonnement pour continuer à profiter de toutes les fonctionnalités Premium.</p>
      <div style="text-align:center">
        <a href="${SITE_URL}" class="btn btn-or">Renouveler mon abonnement</a>
      </div>
    `}),
  }),

  kyc_valide: (v) => ({
    from: FROM_NOREPLY,
    sujet: `[TontineClair] ✅ Vérification d'identité validée`,
    html: baseLayout({ sujet: "KYC validé", couleurAccent: C.succes, contenu: `
      <h1 class="h1">✅ Identité vérifiée avec succès</h1>
      <p class="p">Bonjour <strong>${v.nom ?? ""}</strong>,</p>
      <div class="succes-box"><p>Votre vérification d'identité (KYC) a été validée avec succès.</p></div>
      <p class="p">Vous avez désormais accès à toutes les fonctionnalités sécurisées de TontineClair, y compris les décaissements et prêts importants.</p>
      <div class="info-grid">
        <div class="info-row"><span class="info-label">Statut</span><span class="info-val">Identité vérifiée ✓</span></div>
        <div class="info-row"><span class="info-label">Date</span><span class="info-val">${v.date ?? new Date().toLocaleDateString("fr-FR")}</span></div>
      </div>
    `}),
  }),

  kyc_rejete: (v) => ({
    from: FROM_NOREPLY,
    sujet: `[TontineClair] Vérification d'identité — action requise`,
    html: baseLayout({ sujet: "KYC rejeté", couleurAccent: C.alerte, contenu: `
      <h1 class="h1">❌ Vérification d'identité non concluante</h1>
      <p class="p">Bonjour <strong>${v.nom ?? ""}</strong>,</p>
      <p class="p">Votre vérification d'identité n'a pas pu être validée.</p>
      ${v.motif ? `<div class="alert-box"><p>Motif : ${v.motif}</p></div>` : ""}
      <p class="p">Vous pouvez recommencer la procédure depuis l'application TontineClair en vous assurant que :</p>
      <ul style="padding-left:20px;margin:12px 0;color:#374151;font-size:15px;line-height:2">
        <li>Votre document est lisible et non expiré</li>
        <li>Votre selfie est net et bien éclairé</li>
        <li>Le document appartient bien à la personne sur le selfie</li>
      </ul>
    `}),
  }),

  nouveau_vote: (v) => ({
    from: FROM_NOREPLY,
    sujet: `[TontineClair] 🗳️ Nouveau vote ouvert — ${v.tontine}`,
    html: baseLayout({ sujet: "Nouveau vote", contenu: `
      <h1 class="h1">🗳️ Un vote est en cours</h1>
      <p class="p">Bonjour <strong>${v.nom ?? ""}</strong>,</p>
      <p class="p">Un nouveau vote a été ouvert sur la tontine <strong>${v.tontine}</strong>.</p>
      <div class="info-grid">
        <div class="info-row"><span class="info-label">Sujet</span><span class="info-val">${v.sujet_vote ?? "—"}</span></div>
        <div class="info-row"><span class="info-label">Clôture</span><span class="info-val">${v.cloture ?? "—"}</span></div>
      </div>
      <p class="p">Votre avis compte ! Participez au vote depuis l'application TontineClair.</p>
    `}),
  }),

  resultat_vote: (v) => ({
    from: FROM_NOREPLY,
    sujet: `[TontineClair] Résultat du vote — ${v.tontine}`,
    html: baseLayout({ sujet: "Résultat vote", contenu: `
      <h1 class="h1">📊 Résultat du vote</h1>
      <p class="p">Bonjour <strong>${v.nom ?? ""}</strong>,</p>
      <p class="p">Le vote sur la tontine <strong>${v.tontine}</strong> est terminé.</p>
      <div class="info-grid">
        <div class="info-row"><span class="info-label">Sujet</span><span class="info-val">${v.sujet_vote ?? "—"}</span></div>
        <div class="info-row"><span class="info-label">Résultat</span><span class="info-val">${v.resultat ?? "—"}</span></div>
        <div class="info-row"><span class="info-label">Pour</span><span class="info-val">${v.votes_pour ?? "0"}</span></div>
        <div class="info-row"><span class="info-label">Contre</span><span class="info-val">${v.votes_contre ?? "0"}</span></div>
      </div>
    `}),
  }),

  alerte_securite: (v) => ({
    from: FROM_SECURITE,
    sujet: `[TontineClair] 🚨 Alerte de sécurité — action détectée sur votre compte`,
    html: baseLayout({ sujet: "Alerte sécurité", couleurAccent: C.alerte, contenu: `
      <h1 class="h1">🚨 Alerte de sécurité</h1>
      <p class="p">Bonjour <strong>${v.nom ?? ""}</strong>,</p>
      <div class="alert-box"><p>${v.message ?? "Une action de sécurité a été détectée sur votre compte TontineClair."}</p></div>
      <div class="info-grid">
        <div class="info-row"><span class="info-label">Action</span><span class="info-val">${v.action ?? "—"}</span></div>
        <div class="info-row"><span class="info-label">Date</span><span class="info-val">${v.date ?? new Date().toLocaleString("fr-FR")}</span></div>
        <div class="info-row"><span class="info-label">Tontine</span><span class="info-val">${v.tontine ?? "—"}</span></div>
      </div>
      <p class="p">Si vous n'êtes pas à l'origine de cette action, contactez immédiatement notre équipe sécurité :</p>
      <div style="text-align:center">
        <a href="mailto:securite@tontineclair.com" class="btn" style="background:${C.alerte}">Contacter la sécurité</a>
      </div>
    `}),
  }),

  message_support: (v) => ({
    from: FROM_SUPPORT,
    sujet: `[TontineClair Support] ${v.sujet ?? "Réponse à votre demande"}`,
    html: baseLayout({ sujet: "Message support", contenu: `
      <h1 class="h1">💬 Réponse du support TontineClair</h1>
      <p class="p">Bonjour <strong>${v.nom ?? ""}</strong>,</p>
      <p class="p">L'équipe support TontineClair vous répond concernant votre demande <strong>#${v.ticket_id ?? "—"}</strong>.</p>
      <div style="background:${C.gris};border-radius:10px;padding:16px 20px;margin:20px 0;border-left:4px solid ${C.or}">
        <p style="font-size:15px;color:#374151;line-height:1.65">${v.message ?? "—"}</p>
      </div>
      <p class="p-light">Pour répondre à ce message, utilisez la section Support de l'application TontineClair.</p>
    `}),
  }),

  reset_mot_de_passe: (v) => ({
    from: FROM_SECURITE,
    sujet: `[TontineClair] Réinitialisation de votre mot de passe`,
    html: baseLayout({ sujet: "Réinitialisation mot de passe", couleurAccent: C.alerte, contenu: `
      <h1 class="h1">🔐 Réinitialisation de mot de passe</h1>
      <p class="p">Bonjour <strong>${v.nom ?? ""}</strong>,</p>
      <p class="p">Vous avez demandé la réinitialisation de votre mot de passe TontineClair.</p>
      <div style="text-align:center">
        <a href="${v.lien ?? SITE_URL}" class="btn" style="background:${C.encre}">Réinitialiser mon mot de passe</a>
      </div>
      <p class="p-light">Ce lien est valide pendant <strong>${v.expiration ?? "24 heures"}</strong>. Si vous n'avez pas demandé cette réinitialisation, ignorez cet e-mail.</p>
      <div class="alert-box"><p>🚨 Ne partagez jamais ce lien. TontineClair ne vous demandera jamais votre mot de passe.</p></div>
    `}),
  }),
};

// ─── Envoi via Resend ────────────────────────────────────────────────────────
async function envoyerViaResend(params: {
  from: string;
  to:   string;
  sujet: string;
  html: string;
}): Promise<{ ok: boolean; error?: string; id?: string }> {
  if (!RESEND_API_KEY) {
    console.warn("[send-email] RESEND_API_KEY non configurée — e-mail simulé");
    return { ok: true, id: "MOCK-" + Date.now() };
  }

  const resp = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${RESEND_API_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      from:    params.from,
      to:      [params.to],
      subject: params.sujet,
      html:    params.html,
    }),
  });

  if (!resp.ok) {
    const err = await resp.text();
    return { ok: false, error: err };
  }

  const data = await resp.json();
  return { ok: true, id: data.id };
}

// ─── Handler principal ───────────────────────────────────────────────────────
serve(async (req) => {
  const headers = {
    "Access-Control-Allow-Origin":  "*",
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Content-Type": "application/json",
  };

  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers });
  }

  try {
    const body: EmailRequest = await req.json();
    const { type, destinataire, variables, tontine_code, gest_nom, log_id } = body;

    if (!type || !destinataire) {
      return new Response(
        JSON.stringify({ ok: false, error: "type et destinataire requis" }),
        { status: 400, headers },
      );
    }

    // Récupérer le template
    const templateFn = TEMPLATES[type];
    if (!templateFn) {
      return new Response(
        JSON.stringify({ ok: false, error: `Type inconnu : ${type}` }),
        { status: 400, headers },
      );
    }

    const { sujet, html, from } = templateFn(variables ?? {});

    // Client Supabase pour les logs
    const supabase = SUPABASE_URL && SUPABASE_SERVICE_KEY
      ? createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY)
      : null;

    // Enregistrer le log si pas déjà existant
    let emailLogId = log_id;
    if (supabase && !emailLogId) {
      const { data: logData } = await supabase.rpc("enregistrer_email_log", {
        p_destinataire: destinataire,
        p_type_email:   type,
        p_sujet:        sujet,
        p_tontine_code: tontine_code ?? null,
        p_gest_nom:     gest_nom ?? null,
        p_statut:       "pending",
      });
      emailLogId = logData;
    }

    // Envoyer
    const result = await envoyerViaResend({ from, to: destinataire, sujet, html });

    // Mettre à jour le log
    if (supabase && emailLogId) {
      await supabase.rpc("maj_email_log", {
        p_id:     emailLogId,
        p_statut: result.ok ? "envoye" : "echoue",
        p_motif:  result.ok ? null : result.error,
      });
    }

    return new Response(
      JSON.stringify({ ok: result.ok, id: result.id, log_id: emailLogId }),
      { status: result.ok ? 200 : 500, headers },
    );

  } catch (err) {
    console.error("[send-email] Erreur :", err);
    return new Response(
      JSON.stringify({ ok: false, error: String(err) }),
      { status: 500, headers },
    );
  }
});
