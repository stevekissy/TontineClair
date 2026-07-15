/**
 * Supabase Edge Function : sycapay-payment
 *
 * Proxy sécurisé entre Flutter et l'API SycaPay Production.
 * Les clés SycaPay (MarchandID / API Key) ne transitent JAMAIS côté client.
 *
 * SycaPay Production : https://dev.sycapay.com/
 *
 * Actions supportées :
 *   - "payer"  : authentification + checkoutpay (initier un paiement)
 *   - "statut" : GetStatus (vérifier l'état d'une transaction)
 *
 * Variables d'environnement Supabase à configurer :
 *   SYCAPAY_MARCHAND_ID  = C_6920BF93D3B14
 *   SYCAPAY_API_KEY      = pk_syca_d070448b386b84b1fffec1f925419278f41be0f7
 *   SYCAPAY_SECRET_KEY   = sk_syca_1915bd8a6c91b6d3c39edd35b26f68dce4caa7f8
 */

const SYCAPAY_BASE = "https://dev.sycapay.com/";

const MARCHAND_ID  = Deno.env.get("SYCAPAY_MARCHAND_ID")  ?? "";
const API_KEY      = Deno.env.get("SYCAPAY_API_KEY")      ?? "";
// SECRET_KEY disponible pour signature HMAC future si SycaPay l'exige
// const SECRET_KEY = Deno.env.get("SYCAPAY_SECRET_KEY") ?? "";

// ── Headers CORS pour Flutter Web ────────────────────────────────────────────
const CORS = {
  "Access-Control-Allow-Origin":  "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

// ── Helpers HTTP ──────────────────────────────────────────────────────────────

async function sycaPost(endpoint: string, body: Record<string, unknown>): Promise<unknown> {
  const url = `${SYCAPAY_BASE}${endpoint}`;
  const res = await fetch(url, {
    method:  "POST",
    headers: { "Content-Type": "application/json" },
    body:    JSON.stringify(body),
    // Timeout via AbortController
    signal: AbortSignal.timeout(40_000),
  });
  if (!res.ok) {
    throw new Error(`SycaPay HTTP ${res.status} on ${endpoint}`);
  }
  return res.json();
}

// ── Authentification SycaPay (token valide 40 secondes) ──────────────────────

async function obtenirToken(montant: string): Promise<string> {
  const url = `${SYCAPAY_BASE}login.php`;
  const res = await fetch(url, {
    method: "POST",
    headers: {
      "X-SYCA-MERCHANDID":          MARCHAND_ID,
      "X-SYCA-APIKEY":              API_KEY,
      "X-SYCA-REQUEST-DATA-FORMAT": "JSON",
      "X-SYCA-RESPONSE-DATA-FORMAT":"JSON",
      "Content-Type":               "application/json",
    },
    body:   JSON.stringify({ montant, currency: "XOF" }),
    signal: AbortSignal.timeout(15_000),
  });

  if (!res.ok) throw new Error(`Auth SycaPay échouée: HTTP ${res.status}`);

  const data = await res.json() as { code: number; token?: string; desc?: string };
  if (data.code !== 0 || !data.token) {
    throw new Error(`Token SycaPay refusé: code=${data.code} desc=${data.desc}`);
  }
  return data.token;
}

// ── Handler principal ─────────────────────────────────────────────────────────

Deno.serve(async (req: Request) => {
  // Preflight CORS
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: CORS });
  }

  if (req.method !== "POST") {
    return new Response(JSON.stringify({ erreur: true, message: "Méthode non supportée" }), {
      status: 405, headers: { ...CORS, "Content-Type": "application/json" },
    });
  }

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return new Response(JSON.stringify({ erreur: true, message: "JSON invalide" }), {
      status: 400, headers: { ...CORS, "Content-Type": "application/json" },
    });
  }

  const action = body["action"] as string | undefined;

  try {
    // ── Action : payer ────────────────────────────────────────────────────────
    if (action === "payer") {
      const telephone  = body["telephone"]   as string;
      const montant    = body["montant"]     as string;
      const numcommande= body["numcommande"] as string;
      const operateur  = (body["operateur"]  as string | undefined) ?? "";

      if (!telephone || !montant || !numcommande) {
        return new Response(
          JSON.stringify({ erreur: true, code: -400, message: "Paramètres manquants: telephone, montant, numcommande requis" }),
          { status: 400, headers: { ...CORS, "Content-Type": "application/json" } },
        );
      }

      // 1. Obtenir le token (valide 40s)
      const token = await obtenirToken(montant);

      // 2. Construire le payload de paiement
      const payPayload: Record<string, unknown> = {
        marchandid:  MARCHAND_ID,
        token,
        telephone,
        montant,
        currency:    "XOF",
        numcommande,
        name:        body["name"]     ?? "",
        pname:       body["pname"]    ?? "",
        urlnotif:    body["urlnotif"] ?? "",
      };

      // Orange nécessite un OTP (#144*8*2#)
      const otp = body["otp"] as string | undefined;
      if (otp) payPayload["otp"] = otp;

      // Wave (CI) nécessite pays + operateurs
      if (operateur.toLowerCase() === "wave") {
        payPayload["pays"]      = "CI";
        payPayload["operateurs"]= "WaveSN";
      }

      // 3. Appel checkoutpay.php
      const resultat = await sycaPost("checkoutpay.php", payPayload);

      return new Response(JSON.stringify(resultat), {
        headers: { ...CORS, "Content-Type": "application/json" },
      });
    }

    // ── Action : statut ───────────────────────────────────────────────────────
    if (action === "statut") {
      const ref = body["ref"] as string | undefined;
      if (!ref) {
        return new Response(
          JSON.stringify({ erreur: true, code: -250, message: "Paramètre 'ref' manquant" }),
          { status: 400, headers: { ...CORS, "Content-Type": "application/json" } },
        );
      }

      const resultat = await sycaPost("GetStatus.php", { ref });

      return new Response(JSON.stringify(resultat), {
        headers: { ...CORS, "Content-Type": "application/json" },
      });
    }

    // ── Action inconnue ───────────────────────────────────────────────────────
    return new Response(
      JSON.stringify({ erreur: true, message: `Action inconnue: ${action}` }),
      { status: 400, headers: { ...CORS, "Content-Type": "application/json" } },
    );

  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    console.error("[sycapay-payment] Erreur:", msg);
    return new Response(
      JSON.stringify({ erreur: true, code: -504, message: msg }),
      { status: 500, headers: { ...CORS, "Content-Type": "application/json" } },
    );
  }
});
