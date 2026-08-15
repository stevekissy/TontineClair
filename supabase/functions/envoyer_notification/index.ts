// ─── Edge Function Supabase : envoyer_notification ───────────────────────────
// Envoie une notification push à TOUS les membres d'une tontine via FCM TOPIC.
//
// ARCHITECTURE TOPIC (v3 — broadcast garanti) :
//   ┌─────────────────────────────────────────────────────────────────────┐
//   │  Chaque appareil s'abonne au topic "tontine_CODE" au démarrage.    │
//   │  Cette fonction envoie au topic → FCM livre à TOUS les abonnés.    │
//   │  Même si un token individuel est expiré ou manquant → ça marche.  │
//   └─────────────────────────────────────────────────────────────────────┘
//
//   AVANT (v2 — tokens individuels) :
//     → Cherche tous les tokens dans fcm_tokens
//     → Envoie token par token
//     → Si un membre n'a pas ouvert l'app récemment → son token manque → pas de notif
//
//   MAINTENANT (v3 — FCM Topic) :
//     → Envoie à /topics/tontine_CODE
//     → FCM livre à TOUS les appareils abonnés à ce topic
//     → Garantit que chaque membre reçoit la notification
//
// Variables d'environnement :
//   FIREBASE_PROJECT_ID      = tontineclair
//   FIREBASE_SERVICE_ACCOUNT = { JSON complet de la clé de service Firebase }
//
// Déploiement :
//   supabase functions deploy envoyer_notification
// ─────────────────────────────────────────────────────────────────────────────

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

interface NotificationPayload {
  code: string;
  type: string;
  titre: string;
  message: string;
  donneesExtra?: Record<string, string>;
  sender_token?: string; // non utilisé en mode topic
}

// ── Générer un JWT signé pour l'API FCM v1 ────────────────────────────────────
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

// ── Envoyer au topic FCM (broadcast vers TOUS les membres) ───────────────────
async function envoyerAuTopic(
  topic: string,
  titre: string,
  message: string,
  data: Record<string, string>,
  projectId: string,
  accessToken: string
): Promise<{ ok: boolean; erreur?: string }> {
  const url = `https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`;

  const body = {
    message: {
      topic,                                // ← broadcast topic (pas un token individuel)
      notification: { title: titre, body: message },
      data,
      android: {
        priority: "high",
        ttl: "86400s",                      // ← expiration 24h (au lieu de 4 semaines par défaut)
        collapse_key: `tontine_${topic}`,   // ← déduplique : si 10 notifs en attente → 1 seule livrée
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

  if (res.ok) {
    const resData = await res.json();
    console.log(`[notif] ✅ Topic broadcast OK → name: ${resData.name}`);
    return { ok: true };
  }

  let erreurCode = "";
  try {
    const errJson = await res.json();
    erreurCode = errJson?.error?.message ?? errJson?.error?.status ?? `HTTP_${res.status}`;
  } catch (_) {
    erreurCode = `HTTP_${res.status}`;
  }

  console.error(`[notif] ❌ Topic broadcast ERREUR: ${erreurCode}`);
  return { ok: false, erreur: erreurCode };
}

// ── Fallback : envoyer aux tokens individuels (si topic échoue) ──────────────
const FCM_CODES_TOKEN_INVALIDE = [
  "UNREGISTERED",
  "INVALID_ARGUMENT",
  "registration-token-not-registered",
];

async function envoyerAuxTokens(
  tokens: string[],
  titre: string,
  message: string,
  data: Record<string, string>,
  projectId: string,
  accessToken: string,
  supabase: ReturnType<typeof createClient>,
  codeUp: string
): Promise<{ envoyes: number; echecs: number; tokens_purges: number }> {
  let envoyes = 0;
  let echecs = 0;
  const tokensASupprimer: string[] = [];

  for (const token of tokens) {
    if (!token) continue;

    const url = `https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`;
    const body = {
      message: {
        token,
        notification: { title: titre, body: message },
        data,
        android: {
          priority: "high",
          ttl: "86400s",                    // ← expiration 24h
          collapse_key: `tontine_${codeUp}`,// ← déduplique les notifs en attente par tontine
          notification: { channel_id: "tontineclair_mouvements", priority: "high", default_sound: true },
        },
      },
    };

    const res = await fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${accessToken}` },
      body: JSON.stringify(body),
    });

    if (res.ok) {
      envoyes++;
      console.log(`[notif/fallback] ✅ Envoyé → ${token.substring(0, 20)}...`);
    } else {
      echecs++;
      let erreurCode = "";
      try {
        const errJson = await res.json();
        erreurCode = errJson?.error?.details?.[0]?.errorCode ?? errJson?.error?.status ?? "";
      } catch (_) {}
      const tokenInvalide = FCM_CODES_TOKEN_INVALIDE.some((c) =>
        erreurCode.toUpperCase().includes(c.toUpperCase())
      );
      if (tokenInvalide) tokensASupprimer.push(token);
      console.warn(`[notif/fallback] ❌ Échec → ${token.substring(0, 20)}... — ${erreurCode}`);
    }
  }

  // Purge tokens invalides
  let tokens_purges = 0;
  if (tokensASupprimer.length > 0) {
    await supabase.from("fcm_tokens").delete().eq("tontine_code", codeUp).in("token", tokensASupprimer);
    tokens_purges = tokensASupprimer.length;
    console.log(`[notif] 🗑️ ${tokens_purges} token(s) périmé(s) purgé(s)`);
  }

  return { envoyes, echecs, tokens_purges };
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
      return new Response(
        JSON.stringify({ error: "Paramètres manquants: code, titre, message requis" }),
        { status: 400, headers: { "Content-Type": "application/json" } }
      );
    }

    const projectId         = Deno.env.get("FIREBASE_PROJECT_ID") ?? "tontineclair";
    const serviceAccountStr = Deno.env.get("FIREBASE_SERVICE_ACCOUNT");
    if (!serviceAccountStr) {
      return new Response(
        JSON.stringify({ error: "FIREBASE_SERVICE_ACCOUNT non configuré" }),
        { status: 500, headers: { "Content-Type": "application/json" } }
      );
    }
    const serviceAccount = JSON.parse(serviceAccountStr);

    const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
    const supabaseKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
    const supabase    = createClient(supabaseUrl, supabaseKey);

    const codeUp = code.toUpperCase();

    const data: Record<string, string> = {
      code: codeUp,
      type: type ?? "info",
      ...donneesExtra,
    };

    // Obtenir l'access token OAuth2
    const accessToken = await getAccessToken(serviceAccount);

    // ── MÉCANISME PRINCIPAL : FCM TOPIC broadcast ─────────────────────────────
    // Le topic "tontine_49LJP3" contient TOUS les membres de la tontine.
    // FCM livre à chaque appareil abonné — peu importe si le token a changé.
    const topic = `tontine_${codeUp}`;
    console.log(`[notif] → Broadcast topic: ${topic} | type: ${type}`);

    const topicResult = await envoyerAuTopic(topic, titre, message, data, projectId, accessToken);

    if (topicResult.ok) {
      // Topic broadcast réussi → répondre immédiatement
      return new Response(
        JSON.stringify({
          methode: "topic",
          topic,
          envoyes: 1,        // 1 = le topic a été envoyé (FCM gère la livraison)
          total: 1,
          tokens_purges: 0,
          message: `Broadcast topic ${topic} envoyé avec succès`,
        }),
        { headers: { "Content-Type": "application/json" }, status: 200 }
      );
    }

    // ── FALLBACK : tokens individuels (si le topic échoue) ───────────────────
    // Exemple : FIREBASE_PROJECT_ID incorrect, permissions manquantes, etc.
    console.warn(`[notif] ⚠️ Topic broadcast échoué (${topicResult.erreur}) → fallback tokens individuels`);

    const { data: tokensRows, error: errLecture } = await supabase
      .from("fcm_tokens")
      .select("token")
      .eq("tontine_code", codeUp);

    if (errLecture || !tokensRows || tokensRows.length === 0) {
      console.warn(`[notif] Aucun token FCM pour ${codeUp} et topic échoué — aucune notification envoyée`);
      return new Response(
        JSON.stringify({ methode: "fallback", envoyes: 0, total: 0, tokens_purges: 0,
          erreur_topic: topicResult.erreur }),
        { status: 200, headers: { "Content-Type": "application/json" } }
      );
    }

    const tokens = tokensRows.map((r: { token: string }) => r.token).filter(Boolean);
    console.log(`[notif] Fallback: ${tokens.length} token(s) pour ${codeUp}`);

    const fallbackResult = await envoyerAuxTokens(
      tokens, titre, message, data, projectId, accessToken, supabase, codeUp
    );

    return new Response(
      JSON.stringify({
        methode: "fallback_tokens",
        ...fallbackResult,
        total: tokens.length,
        erreur_topic: topicResult.erreur,
      }),
      { headers: { "Content-Type": "application/json" }, status: 200 }
    );

  } catch (e) {
    console.error("[notif] Exception non gérée:", e);
    return new Response(JSON.stringify({ error: String(e) }), {
      status: 500, headers: { "Content-Type": "application/json" },
    });
  }
});
