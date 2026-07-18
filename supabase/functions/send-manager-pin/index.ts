// ═══════════════════════════════════════════════════════════════════════════════
// TontineClair — Edge Function : send-manager-pin
// Envoi du code temporaire de réinitialisation PIN via SMTP Hostinger
//
// Secrets Supabase requis (jamais dans le code) :
//   SMTP_PASSWORD  → mot de passe SMTP support@tontineclair.com
//   SUPABASE_URL   → injecté automatiquement
//   SUPABASE_SERVICE_ROLE_KEY → injecté automatiquement
//
// Variables d'environnement (non secrètes, configurables) :
//   SMTP_HOST     → smtp.hostinger.com     (défaut)
//   SMTP_PORT     → 465                    (défaut)
//   SMTP_USERNAME → support@tontineclair.com (défaut)
//   FROM_EMAIL    → support@tontineclair.com (défaut)
//   FROM_NAME     → TontineClair            (défaut)
// ═══════════════════════════════════════════════════════════════════════════════

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { SmtpClient } from "https://deno.land/x/smtp@v0.7.0/mod.ts";

// ─── Configuration SMTP (secrets Supabase) ────────────────────────────────────
const SMTP_HOST     = Deno.env.get("SMTP_HOST")     ?? "smtp.hostinger.com";
const SMTP_PORT     = parseInt(Deno.env.get("SMTP_PORT") ?? "465");
const SMTP_SECURE   = (Deno.env.get("SMTP_SECURE")  ?? "true") === "true";
const SMTP_USERNAME = Deno.env.get("SMTP_USERNAME") ?? "support@tontineclair.com";
const SMTP_PASSWORD = Deno.env.get("SMTP_PASSWORD") ?? ""; // Secret obligatoire
const FROM_EMAIL    = Deno.env.get("FROM_EMAIL")    ?? "support@tontineclair.com";
const FROM_NAME     = Deno.env.get("FROM_NAME")     ?? "TontineClair";

// ─── Supabase client (service role — accès RLS bypass) ───────────────────────
const SUPABASE_URL  = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_KEY  = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

// ─── Headers CORS ─────────────────────────────────────────────────────────────
const CORS = {
  "Access-Control-Allow-Origin":  "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

// ─── Palette TontineClair ─────────────────────────────────────────────────────
const BLEU_NUIT = "#1C2447";
const DORE      = "#D99A2B";
const ANNEE     = new Date().getFullYear();

// ─────────────────────────────────────────────────────────────────────────────
// Génère le HTML de l'e-mail code PIN
// ─────────────────────────────────────────────────────────────────────────────
function genererEmailPin(params: {
  gestNom:    string;
  tontineCode: string;
  code:       string;
}): { sujet: string; html: string } {
  const { gestNom, tontineCode, code } = params;

  const sujet = `[TontineClair] Votre code de réinitialisation PIN — ${tontineCode.toUpperCase()}`;

  const html = `<!DOCTYPE html>
<html lang="fr">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>${sujet}</title>
  <style>
    @media (max-width: 480px) {
      .container { padding: 16px 12px !important; }
      .code-box  { font-size: 36px !important; letter-spacing: 8px !important; }
      .btn       { width: 100% !important; display: block !important; }
    }
  </style>
</head>
<body style="margin:0;padding:0;background-color:#F4F5F7;font-family:'Helvetica Neue',Helvetica,Arial,sans-serif;">

  <!-- Wrapper -->
  <table width="100%" cellpadding="0" cellspacing="0" style="background-color:#F4F5F7;padding:32px 0;">
    <tr>
      <td align="center">
        <table class="container" width="100%" style="max-width:580px;background:#ffffff;border-radius:16px;overflow:hidden;box-shadow:0 4px 24px rgba(28,36,71,0.10);">

          <!-- ── En-tête avec logo ───────────────────────────────────────── -->
          <tr>
            <td style="background:${BLEU_NUIT};padding:32px 40px;text-align:center;">
              <table width="100%" cellpadding="0" cellspacing="0">
                <tr>
                  <td align="center">
                    <!-- Logo texte TontineClair -->
                    <div style="display:inline-block;margin-bottom:8px;">
                      <span style="font-size:28px;font-weight:900;color:#ffffff;letter-spacing:-0.5px;">Tontine</span><span style="font-size:28px;font-weight:900;color:${DORE};letter-spacing:-0.5px;">Clair</span>
                    </div>
                    <p style="margin:0;color:rgba(255,255,255,0.65);font-size:13px;letter-spacing:0.5px;">Gestion de tontines en toute clarté</p>
                  </td>
                </tr>
              </table>
            </td>
          </tr>

          <!-- ── Bandeau doré ───────────────────────────────────────────── -->
          <tr>
            <td style="background:${DORE};height:4px;"></td>
          </tr>

          <!-- ── Corps principal ────────────────────────────────────────── -->
          <tr>
            <td class="container" style="padding:40px 40px 32px;">

              <!-- Icône verrou -->
              <div style="text-align:center;margin-bottom:24px;">
                <div style="display:inline-block;width:72px;height:72px;background:rgba(28,36,71,0.06);border-radius:50%;line-height:72px;font-size:36px;">🔐</div>
              </div>

              <!-- Titre -->
              <h1 style="margin:0 0 8px;font-size:22px;font-weight:800;color:${BLEU_NUIT};text-align:center;">
                Code de vérification PIN
              </h1>
              <p style="margin:0 0 24px;font-size:14px;color:#6B7280;text-align:center;line-height:1.6;">
                Bonjour <strong style="color:${BLEU_NUIT};">${gestNom}</strong>,<br>
                vous avez demandé la réinitialisation de votre PIN de gestion<br>
                pour la tontine <strong style="color:${BLEU_NUIT};">${tontineCode.toUpperCase()}</strong>.
              </p>

              <!-- Séparateur -->
              <hr style="border:none;border-top:1px solid #E5E7EB;margin:0 0 28px;">

              <!-- Code PIN -->
              <div style="background:#F8F9FF;border:2px dashed ${BLEU_NUIT};border-radius:14px;padding:28px 20px;text-align:center;margin-bottom:28px;">
                <p style="margin:0 0 8px;font-size:12px;font-weight:700;color:#6B7280;text-transform:uppercase;letter-spacing:1.5px;">Votre code à usage unique</p>
                <div class="code-box" style="font-size:44px;font-weight:900;color:${BLEU_NUIT};letter-spacing:14px;font-family:'Courier New',monospace;margin:8px 0;">
                  ${code}
                </div>
                <p style="margin:8px 0 0;font-size:12px;color:#9CA3AF;">
                  ⏱&nbsp; Valable <strong>10 minutes</strong> · Utilisation unique
                </p>
              </div>

              <!-- Avertissement sécurité -->
              <div style="background:#FFF8E7;border-left:4px solid ${DORE};border-radius:0 10px 10px 0;padding:14px 16px;margin-bottom:28px;">
                <p style="margin:0;font-size:13px;color:#92400E;line-height:1.6;">
                  <strong>⚠️ Sécurité :</strong> Ne communiquez jamais ce code à qui que ce soit. TontineClair ne vous demandera jamais votre code de vérification.
                </p>
              </div>

              <!-- Infos techniques -->
              <div style="background:#F9FAFB;border-radius:10px;padding:16px;margin-bottom:28px;">
                <table width="100%" cellpadding="0" cellspacing="0">
                  <tr>
                    <td style="font-size:12px;color:#6B7280;padding:3px 0;">
                      📅&nbsp; <strong>Date :</strong> ${new Date().toLocaleDateString("fr-FR", { weekday: "long", year: "numeric", month: "long", day: "numeric" })}
                    </td>
                  </tr>
                  <tr>
                    <td style="font-size:12px;color:#6B7280;padding:3px 0;">
                      🕐&nbsp; <strong>Heure :</strong> ${new Date().toLocaleTimeString("fr-FR", { hour: "2-digit", minute: "2-digit" })} (UTC)
                    </td>
                  </tr>
                  <tr>
                    <td style="font-size:12px;color:#6B7280;padding:3px 0;">
                      🏦&nbsp; <strong>Tontine :</strong> ${tontineCode.toUpperCase()}
                    </td>
                  </tr>
                </table>
              </div>

              <p style="margin:0;font-size:13px;color:#6B7280;line-height:1.7;text-align:center;">
                Si vous n'avez pas demandé cette réinitialisation,<br>
                ignorez cet e-mail. Votre PIN reste inchangé.
              </p>

            </td>
          </tr>

          <!-- ── Séparateur doré ─────────────────────────────────────────── -->
          <tr>
            <td style="background:${DORE};height:3px;"></td>
          </tr>

          <!-- ── Footer officiel ─────────────────────────────────────────── -->
          <tr>
            <td style="background:#F8F9FB;padding:28px 40px;text-align:center;">
              <p style="margin:0 0 6px;font-size:13px;font-weight:700;color:${BLEU_NUIT};">
                <span style="color:${BLEU_NUIT};">Tontine</span><span style="color:${DORE};">Clair</span>
              </p>
              <p style="margin:0 0 12px;font-size:11px;color:#9CA3AF;">
                Gestion de tontines en toute clarté
              </p>
              <p style="margin:0 0 14px;">
                <a href="https://tontineclair.com/confidentialite" style="color:#6B7280;font-size:11px;text-decoration:none;margin:0 8px;">Politique de confidentialité</a>
                <span style="color:#D1D5DB;">|</span>
                <a href="https://tontineclair.com/cgu" style="color:#6B7280;font-size:11px;text-decoration:none;margin:0 8px;">CGU</a>
                <span style="color:#D1D5DB;">|</span>
                <a href="mailto:support@tontineclair.com" style="color:#6B7280;font-size:11px;text-decoration:none;margin:0 8px;">Support</a>
              </p>
              <p style="margin:0;font-size:10px;color:#C7CBD4;">
                © ${ANNEE} TontineClair — Tous droits réservés<br>
                Cet e-mail est automatique, merci de ne pas y répondre.
              </p>
            </td>
          </tr>

        </table>
      </td>
    </tr>
  </table>

</body>
</html>`;

  return { sujet, html };
}

// ─────────────────────────────────────────────────────────────────────────────
// Envoi SMTP via SmtpClient (Hostinger port 465 SSL)
// ─────────────────────────────────────────────────────────────────────────────
async function envoyerSmtp(params: {
  to:      string;
  toName?: string;
  sujet:   string;
  html:    string;
}): Promise<{ ok: boolean; erreur?: string }> {
  if (!SMTP_PASSWORD) {
    console.error("[send-manager-pin] SMTP_PASSWORD manquant dans les secrets Supabase.");
    return { ok: false, erreur: "SMTP_PASSWORD non configuré." };
  }

  const client = new SmtpClient();

  try {
    await client.connectTLS({
      hostname: SMTP_HOST,
      port:     SMTP_PORT,
      username: SMTP_USERNAME,
      password: SMTP_PASSWORD,
    });

    await client.send({
      from:    `${FROM_NAME} <${FROM_EMAIL}>`,
      to:      params.toName ? `${params.toName} <${params.to}>` : params.to,
      subject: params.sujet,
      html:    params.html,
      content: "auto",
    });

    await client.close();
    console.log(`[send-manager-pin] ✅ E-mail envoyé → ${params.to}`);
    return { ok: true };

  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    console.error(`[send-manager-pin] ❌ Erreur SMTP → ${params.to} :`, msg);
    try { await client.close(); } catch (_) { /* ignore */ }
    return { ok: false, erreur: msg };
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Handler principal
// ─────────────────────────────────────────────────────────────────────────────
serve(async (req: Request) => {
  // Preflight CORS
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: CORS });
  }

  if (req.method !== "POST") {
    return new Response(JSON.stringify({ success: false, error: "Méthode non autorisée." }), {
      status: 405, headers: { ...CORS, "Content-Type": "application/json" },
    });
  }

  // ── Parse body ──────────────────────────────────────────────────────────────
  let body: {
    email:       string;
    gestNom:     string;
    tontineCode: string;
    code:        string;          // Code 6 chiffres en clair — stocké hashé en DB par la RPC
  };

  try {
    body = await req.json();
  } catch {
    return new Response(JSON.stringify({ success: false, error: "Corps JSON invalide." }), {
      status: 400, headers: { ...CORS, "Content-Type": "application/json" },
    });
  }

  const { email, gestNom, tontineCode, code } = body;

  // ── Validation des champs ───────────────────────────────────────────────────
  if (!email || !gestNom || !tontineCode || !code) {
    console.error("[send-manager-pin] Champs manquants :", { email: !!email, gestNom: !!gestNom, tontineCode: !!tontineCode, code: !!code });
    return new Response(JSON.stringify({ success: false, error: "Champs requis manquants." }), {
      status: 400, headers: { ...CORS, "Content-Type": "application/json" },
    });
  }

  // Validation basique de l'email
  const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
  if (!emailRegex.test(email)) {
    console.error("[send-manager-pin] Email invalide :", email);
    return new Response(JSON.stringify({ success: false, error: "Adresse e-mail invalide." }), {
      status: 400, headers: { ...CORS, "Content-Type": "application/json" },
    });
  }

  // Validation du code (6 chiffres)
  if (!/^\d{6}$/.test(code)) {
    console.error("[send-manager-pin] Code invalide :", code.length, "chars");
    return new Response(JSON.stringify({ success: false, error: "Code invalide." }), {
      status: 400, headers: { ...CORS, "Content-Type": "application/json" },
    });
  }

  // ── Log Supabase (audit) ────────────────────────────────────────────────────
  const supabase = createClient(SUPABASE_URL, SUPABASE_KEY);
  const logId: string | null = null;

  try {
    // Log de tentative d'envoi (statut pending)
    await supabase.from("email_logs").insert({
      destinataire: email,
      type_email:   "pin_reset",
      sujet:        `Code PIN reset — ${tontineCode.toUpperCase()}`,
      tontine_code: tontineCode.toUpperCase(),
      gest_nom:     gestNom,
      statut:       "pending",
    });
  } catch (logErr) {
    // Non bloquant — on continue l'envoi même si le log échoue
    console.warn("[send-manager-pin] Log Supabase échoué :", logErr);
  }

  // ── Génération HTML ─────────────────────────────────────────────────────────
  const { sujet, html } = genererEmailPin({ gestNom, tontineCode, code });

  // ── Envoi SMTP ──────────────────────────────────────────────────────────────
  const result = await envoyerSmtp({
    to:      email,
    toName:  gestNom,
    sujet,
    html,
  });

  // ── Mise à jour statut log ──────────────────────────────────────────────────
  if (logId) {
    try {
      await supabase.from("email_logs").update({
        statut:      result.ok ? "envoye" : "echoue",
        motif_echec: result.ok ? null : result.erreur,
      }).eq("id", logId);
    } catch (_) { /* non bloquant */ }
  }

  // ── Réponse ─────────────────────────────────────────────────────────────────
  if (result.ok) {
    return new Response(JSON.stringify({ success: true }), {
      status: 200, headers: { ...CORS, "Content-Type": "application/json" },
    });
  } else {
    // Retourner l'erreur SMTP précise pour permettre le diagnostic.
    // En production, on peut re-masquer ce champ si nécessaire.
    const erreurDetail = result.erreur ?? "Erreur SMTP inconnue";
    console.error(`[send-manager-pin] Échec envoi → ${email} : ${erreurDetail}`);

    // Catégoriser l'erreur pour le client Flutter
    let messageClient = "Impossible d'envoyer le code. Réessayez.";
    if (!SMTP_PASSWORD) {
      messageClient = "Configuration email manquante (SMTP_PASSWORD). Contacter l'administrateur.";
    } else if (erreurDetail.toLowerCase().includes("authentication") ||
               erreurDetail.toLowerCase().includes("credentials") ||
               erreurDetail.toLowerCase().includes("535") ||
               erreurDetail.toLowerCase().includes("password")) {
      messageClient = "Erreur d'authentification SMTP. Vérifier SMTP_PASSWORD dans les secrets.";
    } else if (erreurDetail.toLowerCase().includes("timeout") ||
               erreurDetail.toLowerCase().includes("connect")) {
      messageClient = "Serveur email inaccessible. Réessayez dans quelques instants.";
    } else if (erreurDetail.toLowerCase().includes("invalid") ||
               erreurDetail.toLowerCase().includes("550")) {
      messageClient = "Adresse email destinataire invalide.";
    }

    return new Response(JSON.stringify({
      success:       false,
      error:         messageClient,
      error_detail:  erreurDetail, // Détail technique pour diagnostic
    }), {
      status: 500, headers: { ...CORS, "Content-Type": "application/json" },
    });
  }
});
