// ─── Edge Function Supabase : envoyer_notification ───────────────────────────
// Appelée par l'app Flutter après chaque mouvement important.
// Elle récupère les tokens FCM de TOUS les membres de la tontine et envoie
// une notification push via Firebase Cloud Messaging (FCM v1 API).
//
// FIX BROADCAST v2 :
//   - Supprime automatiquement les tokens UNREGISTERED / expirés de la table
//   - Logs détaillés pour diagnostic
//   - sender_token optionnel : exclut l'émetteur si souhaité (désactivé par défaut)
//
// Variables d'environnement (Supabase Dashboard → Settings → Edge Functions) :
//   FIREBASE_PROJECT_ID     = tontineclair
//   FIREBASE_SERVICE_ACCOUNT = { ... JSON complet de la clé de service Firebase ... }
//
// Déploiement :
//   supabase functions deploy envoyer_notification
// ─────────────────────────────────────────────────────────────────────────────

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// ── Types ────────────────────────────────────────────────────────────────────
interface NotificationPayload {
  code: string;            // Code tontine (ex: "ABC123")
  type: string;            // "cotisation" | "vote" | "decaissement" | ...
  titre: string;           // Titre de la notification
  message: string;         // Corps de la notification
  donneesExtra?: Record<string, string>; // Données supplémentaires (navigation)
  sender_token?: string;   // Token FCM de l'émetteur (optionnel — non utilisé actuellement)
}

// Codes d'erreur FCM qui signalent un token définitivement invalide
const FCM_CODES_TOKEN_INVALIDE = [
  "UNREGISTERED",           // token révoqué (désinstallation, changement de compte)
  "INVALID_ARGUMENT",       // token malformé
  "registration-token-not-registered", // variante v1
];

// ── Générer un JWT signé pour l'API FCM v1 ───────────────────────────────────
async function getAccessToken(serviceAccount: Record<string, string>): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const header = { alg: "RS256", typ: "JWT" };
  const payload = {
    iss: serviceAccount.client_email,
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: "https://oauth2.googleapis.com/token",
    iat: now,
    exp: now + 3600,
  };

  const encode = (obj: object) =>
    btoa(JSON.stringify(obj)).replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");

  const headerB64  = encode(header);
  const payloadB64 = encode(payload);
  const signingInput = `${headerB64}.${payloadB64}`;

  // Import clé privée RSA
  const pemKey  = serviceAccount.private_key.replace(/\\n/g, "\n");
  const keyData = pemKey
    .replace("-----BEGIN PRIVATE KEY-----", "")
    .replace("-----END PRIVATE KEY-----", "")
    .replace(/\s/g, "");

  const binaryKey  = Uint8Array.from(atob(keyData), (c) => c.charCodeAt(0));
  const cryptoKey  = await crypto.subtle.importKey(
    "pkcs8",
    binaryKey,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"]
  );

  const signature = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    cryptoKey,
    new TextEncoder().encode(signingInput)
  );

  const signatureB64 = btoa(String.fromCharCode(...new Uint8Array(signature)))
    .replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");

  const jwt = `${signingInput}.${signatureB64}`;

  // Échanger le JWT contre un access token OAuth2
  const tokenResponse = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: `grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=${jwt}`,
  });

  const tokenData = await tokenResponse.json();
  if (!tokenData.access_token) {
    throw new Error(`OAuth2 failed: ${JSON.stringify(tokenData)}`);
  }
  return tokenData.access_token;
}

// ── Envoyer une notification FCM à un token ──────────────────────────────────
// Retourne : { ok: boolean, tokenInvalide: boolean, erreur?: string }
async function envoyerFCM(
  token: string,
  titre: string,
  message: string,
  data: Record<string, string>,
  projectId: string,
  accessToken: string
): Promise<{ ok: boolean; tokenInvalide: boolean; erreur?: string }> {
  const url = `https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`;

  const body = {
    message: {
      token,
      notification: { title: titre, body: message },
      data,
      android: {
        priority: "high",
        notification: {
          channel_id: "tontineclair_mouvements",
          priority:   "high",
          default_sound: true,
        },
      },
    },
  };

  const res  = await fetch(url, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization:  `Bearer ${accessToken}`,
    },
    body: JSON.stringify(body),
  });

  if (res.ok) return { ok: true, tokenInvalide: false };

  // Analyser l'erreur FCM
  let erreurCode = "";
  try {
    const errJson = await res.json();
    erreurCode = errJson?.error?.details?.[0]?.errorCode
      ?? errJson?.error?.status
      ?? errJson?.error?.message
      ?? "";
  } catch (_) {
    erreurCode = `HTTP_${res.status}`;
  }

  const tokenInvalide = FCM_CODES_TOKEN_INVALIDE.some((code) =>
    erreurCode.toUpperCase().includes(code.toUpperCase())
  );

  return { ok: false, tokenInvalide, erreur: erreurCode };
}

// ── Handler principal ─────────────────────────────────────────────────────────
serve(async (req) => {
  // CORS preflight
  if (req.method === "OPTIONS") {
    return new Response(null, {
      headers: {
        "Access-Control-Allow-Origin":  "*",
        "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
      },
    });
  }

  try {
    const payload: NotificationPayload = await req.json();
    const { code, type, titre, message, donneesExtra } = payload;
    // sender_token : réservé pour exclure l'émetteur dans une future version
    // const senderToken = payload.sender_token ?? null;

    if (!code || !titre || !message) {
      return new Response(JSON.stringify({ error: "Paramètres manquants: code, titre, message requis" }), {
        status: 400, headers: { "Content-Type": "application/json" },
      });
    }

    // Récupérer les variables d'environnement
    const projectId         = Deno.env.get("FIREBASE_PROJECT_ID") ?? "tontineclair";
    const serviceAccountStr = Deno.env.get("FIREBASE_SERVICE_ACCOUNT");
    if (!serviceAccountStr) {
      return new Response(JSON.stringify({ error: "FIREBASE_SERVICE_ACCOUNT non configuré" }), {
        status: 500, headers: { "Content-Type": "application/json" },
      });
    }
    const serviceAccount = JSON.parse(serviceAccountStr);

    // Connexion Supabase (service role pour lecture + suppression de tokens)
    const supabaseUrl = Deno.env.get("SUPABASE_URL")              ?? "";
    const supabaseKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
    const supabase    = createClient(supabaseUrl, supabaseKey);

    const codeUp = code.toUpperCase();

    // ── Récupérer TOUS les tokens FCM de cette tontine ────────────────────────
    const { data: tokensRows, error: errLecture } = await supabase
      .from("fcm_tokens")
      .select("token")
      .eq("tontine_code", codeUp);

    if (errLecture) {
      console.error(`[notif] Erreur lecture fcm_tokens pour ${codeUp}:`, errLecture.message);
      return new Response(JSON.stringify({ error: errLecture.message }), {
        status: 500, headers: { "Content-Type": "application/json" },
      });
    }

    if (!tokensRows || tokensRows.length === 0) {
      console.warn(`[notif] Aucun token FCM pour la tontine ${codeUp} — aucune notification envoyée`);
      return new Response(JSON.stringify({
        envoyes: 0, total: 0,
        message: `Aucun appareil enregistré pour la tontine ${codeUp}`,
      }), { status: 200, headers: { "Content-Type": "application/json" } });
    }

    console.log(`[notif] ${tokensRows.length} token(s) trouvé(s) pour ${codeUp} — type: ${type}`);

    // Obtenir l'access token FCM OAuth2
    const accessToken = await getAccessToken(serviceAccount);

    // Données supplémentaires pour navigation dans l'app
    const data: Record<string, string> = {
      code: codeUp,
      type: type ?? "info",
      ...donneesExtra,
    };

    // ── Envoyer à chaque appareil ─────────────────────────────────────────────
    let envoyes        = 0;
    let echecs         = 0;
    const tokensASupprimer: string[] = [];

    for (const { token } of tokensRows) {
      if (!token) continue;

      const result = await envoyerFCM(token, titre, message, data, projectId, accessToken);

      if (result.ok) {
        envoyes++;
        console.log(`[notif] ✅ Envoyé → ${token.substring(0, 20)}...`);
      } else {
        echecs++;
        console.warn(`[notif] ❌ Échec → ${token.substring(0, 20)}... — ${result.erreur}`);

        // Marquer pour suppression si token définitivement invalide
        if (result.tokenInvalide) {
          tokensASupprimer.push(token);
          console.log(`[notif] 🗑️  Token UNREGISTERED marqué pour suppression: ${token.substring(0, 20)}...`);
        }
      }
    }

    // ── Nettoyage des tokens invalides ────────────────────────────────────────
    // Supprime les tokens UNREGISTERED de la table pour éviter les faux-négatifs
    // lors des prochains envois
    if (tokensASupprimer.length > 0) {
      const { error: errSupp } = await supabase
        .from("fcm_tokens")
        .delete()
        .eq("tontine_code", codeUp)
        .in("token", tokensASupprimer);

      if (errSupp) {
        console.error(`[notif] Erreur suppression tokens périmés:`, errSupp.message);
      } else {
        console.log(`[notif] 🗑️  ${tokensASupprimer.length} token(s) périmé(s) supprimé(s) pour ${codeUp}`);
      }
    }

    const reponse = {
      envoyes,
      echecs,
      total:          tokensRows.length,
      tokens_purges:  tokensASupprimer.length,
    };

    console.log(`[notif] Résumé ${codeUp}: ${envoyes}/${tokensRows.length} envoyés, ${tokensASupprimer.length} tokens purgés`);

    return new Response(JSON.stringify(reponse), {
      headers: { "Content-Type": "application/json" },
      status:  200,
    });

  } catch (e) {
    console.error("[notif] Exception non gérée:", e);
    return new Response(JSON.stringify({ error: String(e) }), {
      status: 500, headers: { "Content-Type": "application/json" },
    });
  }
});
