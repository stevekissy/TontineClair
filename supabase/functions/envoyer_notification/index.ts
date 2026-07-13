// ─── Edge Function Supabase : envoyer_notification ───────────────────────────
// Appelée par l'app Flutter après chaque mouvement important.
// Elle récupère les tokens FCM des membres de la tontine et envoie
// une notification push via Firebase Cloud Messaging (FCM v1 API).
//
// Variables d'environnement requises (Supabase Dashboard → Settings → Edge Functions) :
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
  code: string;          // Code tontine (ex: "ABC123")
  type: string;          // "cotisation" | "vote" | "decaissement" | "membre" | "cycle"
  titre: string;         // Titre de la notification
  message: string;       // Corps de la notification
  donneesExtra?: Record<string, string>; // Données supplémentaires (navigation)
}

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

  const headerB64 = encode(header);
  const payloadB64 = encode(payload);
  const signingInput = `${headerB64}.${payloadB64}`;

  // Import clé privée RSA
  const pemKey = serviceAccount.private_key.replace(/\\n/g, "\n");
  const keyData = pemKey
    .replace("-----BEGIN PRIVATE KEY-----", "")
    .replace("-----END PRIVATE KEY-----", "")
    .replace(/\s/g, "");

  const binaryKey = Uint8Array.from(atob(keyData), (c) => c.charCodeAt(0));
  const cryptoKey = await crypto.subtle.importKey(
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
  return tokenData.access_token;
}

// ── Envoyer une notification FCM à un token ──────────────────────────────────
async function envoyerFCM(
  token: string,
  titre: string,
  message: string,
  data: Record<string, string>,
  projectId: string,
  accessToken: string
): Promise<boolean> {
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
          priority: "high",
          default_sound: true,
        },
      },
    },
  };

  const res = await fetch(url, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${accessToken}`,
    },
    body: JSON.stringify(body),
  });

  return res.ok;
}

// ── Handler principal ─────────────────────────────────────────────────────────
serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, {
      headers: {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
      },
    });
  }

  try {
    const payload: NotificationPayload = await req.json();
    const { code, type, titre, message, donneesExtra } = payload;

    if (!code || !titre || !message) {
      return new Response(JSON.stringify({ error: "Paramètres manquants" }), { status: 400 });
    }

    // Récupérer les variables d'environnement
    const projectId = Deno.env.get("FIREBASE_PROJECT_ID") ?? "tontineclair";
    const serviceAccountStr = Deno.env.get("FIREBASE_SERVICE_ACCOUNT");
    if (!serviceAccountStr) {
      return new Response(JSON.stringify({ error: "FIREBASE_SERVICE_ACCOUNT non configuré" }), { status: 500 });
    }
    const serviceAccount = JSON.parse(serviceAccountStr);

    // Connexion Supabase pour lire les tokens FCM
    const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
    const supabaseKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
    const supabase = createClient(supabaseUrl, supabaseKey);

    // Récupérer les tokens FCM de tous les membres de cette tontine
    const { data: tokens, error } = await supabase
      .from("fcm_tokens")
      .select("token")
      .eq("tontine_code", code.toUpperCase());

    if (error || !tokens || tokens.length === 0) {
      return new Response(JSON.stringify({ envoyes: 0, message: "Aucun token trouvé" }), { status: 200 });
    }

    // Obtenir l'access token FCM
    const accessToken = await getAccessToken(serviceAccount);

    // Données supplémentaires pour navigation dans l'app
    const data: Record<string, string> = {
      code: code.toUpperCase(),
      type: type ?? "info",
      ...donneesExtra,
    };

    // Envoyer à tous les tokens
    let envoyes = 0;
    for (const { token } of tokens) {
      const ok = await envoyerFCM(token, titre, message, data, projectId, accessToken);
      if (ok) envoyes++;
    }

    return new Response(
      JSON.stringify({ envoyes, total: tokens.length }),
      { headers: { "Content-Type": "application/json" }, status: 200 }
    );

  } catch (e) {
    return new Response(JSON.stringify({ error: String(e) }), { status: 500 });
  }
});
