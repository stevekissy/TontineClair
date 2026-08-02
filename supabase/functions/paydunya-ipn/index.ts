// ─────────────────────────────────────────────────────────────────────────────
// paydunya-ipn — Edge Function Supabase (Deno/TypeScript)
//
// Handler IPN (Instant Payment Notification) PayDunya pour TontineClair.
//
// PayDunya envoie un POST JSON à ce endpoint lors de tout changement de statut
// d'une invoice (completed, cancelled, failed).
//
// Sécurité :
//   - Vérification du hash SHA-512 du Master Key (champ "hash" du payload)
//   - Règle de crédit absolue : on re-vérifie TOUJOURS le statut via
//     checkout-invoice/confirm/[token] avant tout crédit
//   - Idempotence : si déjà crédité → skip silencieux
//
// Variables d'environnement requises :
//   PAYDUNYA_MASTER_KEY      — pour vérification hash IPN
//   PAYDUNYA_PRIVATE_KEY     — pour appels API
//   PAYDUNYA_TOKEN           — pour appels API
//   PAYDUNYA_SANDBOX         — "true" pour sandbox
//   SUPABASE_URL             — auto-injecté
//   SUPABASE_SERVICE_ROLE_KEY — auto-injecté
// ─────────────────────────────────────────────────────────────────────────────

// ── Env vars ──────────────────────────────────────────────────────────────────
const PD_MASTER_KEY  = Deno.env.get("PAYDUNYA_MASTER_KEY")       ?? "";
const PD_PRIVATE_KEY = Deno.env.get("PAYDUNYA_PRIVATE_KEY")      ?? "";
const PD_TOKEN       = Deno.env.get("PAYDUNYA_TOKEN")             ?? "";
const PD_SANDBOX     = (Deno.env.get("PAYDUNYA_SANDBOX") ?? "true") !== "false";
const SUPABASE_URL   = Deno.env.get("SUPABASE_URL")               ?? "";
const SERVICE_KEY    = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")  ?? "";

// ── PayDunya API ──────────────────────────────────────────────────────────────
const PD_BASE = PD_SANDBOX
  ? "https://app.paydunya.com/sandbox-api/v1"
  : "https://app.paydunya.com/api/v1";

// ─────────────────────────────────────────────────────────────────────────────
// SHA-512 du Master Key (vérification hash IPN PayDunya)
// ─────────────────────────────────────────────────────────────────────────────

async function sha512(message: string): Promise<string> {
  const encoder  = new TextEncoder();
  const data     = encoder.encode(message);
  const hashBuf  = await crypto.subtle.digest("SHA-512", data);
  return Array.from(new Uint8Array(hashBuf))
    .map(b => b.toString(16).padStart(2, "0"))
    .join("");
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers Supabase
// ─────────────────────────────────────────────────────────────────────────────

function sbHeaders(): Record<string, string> {
  return {
    "Content-Type":  "application/json",
    "apikey":        SERVICE_KEY,
    "Authorization": `Bearer ${SERVICE_KEY}`,
    "Prefer":        "return=minimal",
  };
}

async function sbSelect(
  table: string,
  query: string,
): Promise<Array<Record<string, unknown>>> {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/${table}?${query}`, {
    method:  "GET",
    headers: { ...sbHeaders(), "Prefer": "return=representation" },
  });
  if (!res.ok) {
    const t = await res.text();
    throw new Error(`sbSelect ${table} → ${res.status}: ${t}`);
  }
  return res.json();
}

async function sbPatch(
  table: string,
  query: string,
  data:  Record<string, unknown>,
): Promise<void> {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/${table}?${query}`, {
    method:  "PATCH",
    headers: { ...sbHeaders(), "Prefer": "return=minimal" },
    body:    JSON.stringify(data),
  });
  if (!res.ok) {
    const t = await res.text();
    throw new Error(`sbPatch ${table} → ${res.status}: ${t}`);
  }
}

async function sbRpc(fn: string, params: Record<string, unknown>): Promise<void> {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${fn}`, {
    method:  "POST",
    headers: { ...sbHeaders(), "Prefer": "return=minimal" },
    body:    JSON.stringify(params),
  });
  if (!res.ok) {
    const t = await res.text();
    throw new Error(`sbRpc ${fn} → ${res.status}: ${t}`);
  }
}

async function sbFetch(
  path: string,
  method: string,
  body?: unknown,
): Promise<Record<string, unknown>> {
  const res = await fetch(`${SUPABASE_URL}${path}`, {
    method,
    headers: sbHeaders(),
    body: body ? JSON.stringify(body) : undefined,
  });
  if (!res.ok) {
    const t = await res.text();
    throw new Error(`sbFetch ${method} ${path} → ${res.status}: ${t}`);
  }
  const text = await res.text();
  if (!text) return {};
  return JSON.parse(text);
}

// ─────────────────────────────────────────────────────────────────────────────
// PayDunya API — Vérification statut invoice
// ─────────────────────────────────────────────────────────────────────────────

async function pdVerifierStatut(token: string): Promise<{
  status:    string;
  ok:        boolean;
  montant?:  number;
  operateur?: string;
  receiptUrl?: string;
}> {
  const res = await fetch(`${PD_BASE}/checkout-invoice/confirm/${token}`, {
    method: "GET",
    headers: {
      "Content-Type":          "application/json",
      "PAYDUNYA-MASTER-KEY":   PD_MASTER_KEY,
      "PAYDUNYA-PRIVATE-KEY":  PD_PRIVATE_KEY,
      "PAYDUNYA-TOKEN":        PD_TOKEN,
    },
  });

  const data = await res.json() as Record<string, unknown>;

  if (data["response_code"] !== "00") {
    throw new Error(`PayDunya confirm: ${data["response_text"] ?? data["description"]}`);
  }

  const status      = (data["status"]      as string) ?? "pending";
  const invoice     = (data["invoice"]     as Record<string, unknown>) ?? {};
  const paymentData = (data["payment_data"] as Record<string, unknown>) ?? {};

  return {
    status,
    ok:         status === "completed",
    montant:    (invoice["total_amount"] as number) ?? 0,
    operateur:  (paymentData["channel"]  as string) ?? "",
    receiptUrl: (data["receipt_url"]     as string) ?? "",
  };
}

// ─────────────────────────────────────────────────────────────────────────────
// Audit log PayDunya
// ─────────────────────────────────────────────────────────────────────────────

async function ecrireAudit(params: {
  numcommande:   string;
  ancienStatut?: string;
  nouveauStatut: string;
  source:        string;
  reponseApi?:   unknown;
  erreur?:       string;
}): Promise<void> {
  await sbFetch("/rest/v1/paydunya_audit_log", "POST", {
    internal_reference: params.numcommande,
    ancien_statut:      params.ancienStatut  ?? "unknown",
    nouveau_statut:     params.nouveauStatut,
    source:             params.source,
    reponse_api:        params.reponseApi    ?? null,
    erreur:             params.erreur        ?? null,
    created_at:         new Date().toISOString(),
  }).catch(e => console.error("[audit-ipn] Échec:", e));
}

// ─────────────────────────────────────────────────────────────────────────────
// Crédit Supabase (mêmes RPCs que CoinPayments / SycaPay)
// ─────────────────────────────────────────────────────────────────────────────

async function crediterCoteServeur(tx: Record<string, unknown>): Promise<void> {
  const t    = (tx["type_operation"] as string) ?? "cotisation";
  const base = {
    p_code:         ((tx["tontine_code"]      as string) ?? "").toUpperCase(),
    p_montant:      (tx["amount"]             as number) ?? 0,
    p_reference:    (tx["pd_token"]           as string) ?? "",
    p_num_commande: (tx["internal_reference"] as string) ?? "",
    p_operateur:    "paydunya",
    p_now:          new Date().toISOString(),
  };
  const mid  = (tx["membre_id"]  as string) ?? null;
  const pid  = (tx["pret_id"]    as string) ?? null;
  const desc = (tx["description"] as string) ?? null;

  if      (t === "cotisation")         await sbRpc("crediter_cotisation_sycapay",    base);
  else if (t === "caisse")             await sbRpc("crediter_caisse_sycapay",        { ...base, p_description: desc });
  else if (t === "penalite")           await sbRpc("crediter_penalite_sycapay",      { ...base, p_membre_id: mid });
  else if (t === "remboursement_pret") await sbRpc("crediter_remboursement_sycapay", { ...base, p_pret_id: pid });
  else if (t === "pret_octroye")       await sbRpc("debiter_pret_sycapay",           { ...base, p_pret_id: pid });
  else                                 await sbRpc("crediter_caisse_sycapay",        { ...base, p_description: `[${t}] ${desc ?? ""}` });
}

// ─────────────────────────────────────────────────────────────────────────────
// Vérification + crédit strict (idempotent)
// ─────────────────────────────────────────────────────────────────────────────

async function verifierEtCrediter(
  numcommande: string,
  token: string,
  ipnPayload: Record<string, unknown>,
): Promise<{ ok: boolean; message: string }> {
  console.log(`[ipn-verifier] Début ${numcommande}`);

  try {
    const rows = await sbSelect(
      "paydunya_transactions",
      `internal_reference=eq.${encodeURIComponent(numcommande)}&select=*`,
    );

    if (rows.length === 0) {
      const msg = `Transaction PayDunya introuvable en DB: ${numcommande}`;
      await ecrireAudit({ numcommande, nouveauStatut: "error", source: "IPN", erreur: msg });
      return { ok: false, message: msg };
    }

    const dbTx = rows[0];

    // Idempotence
    if (dbTx["status"] === "credited") {
      console.log(`[ipn-verifier] ${numcommande} déjà crédité → skip`);
      return { ok: true, message: "Déjà crédité" };
    }

    if (dbTx["status"] === "cancelled" || dbTx["status"] === "failed") {
      return { ok: false, message: `Statut ${dbTx["status"]} — crédit refusé` };
    }

    // Re-vérifier PayDunya API (règle absolue — on ne se fie pas au payload IPN seul)
    const effectiveToken = token || (dbTx["pd_token"] as string);
    if (!effectiveToken) {
      return { ok: false, message: "Token PayDunya absent" };
    }

    let pdInfo: Awaited<ReturnType<typeof pdVerifierStatut>>;
    try {
      pdInfo = await pdVerifierStatut(effectiveToken);
    } catch (e: unknown) {
      const msg = String(e);
      console.error(`[ipn-verifier] Erreur vérif API PayDunya:`, msg);
      await ecrireAudit({
        numcommande, ancienStatut: dbTx["status"] as string,
        nouveauStatut: "error", source: "IPN", erreur: msg,
      });
      return { ok: false, message: `Vérif PayDunya échouée: ${msg}` };
    }

    console.log(`[ipn-verifier] PayDunya statut=${pdInfo.status} ok=${pdInfo.ok}`);

    await ecrireAudit({
      numcommande,
      ancienStatut:  dbTx["status"] as string,
      nouveauStatut: `api_check:${pdInfo.status}`,
      source:        "IPN",
      reponseApi:    { status: pdInfo.status, operateur: pdInfo.operateur, token: effectiveToken },
    });

    if (!pdInfo.ok) {
      if (pdInfo.status === "cancelled" || pdInfo.status === "failed") {
        await sbPatch(
          "paydunya_transactions",
          `internal_reference=eq.${encodeURIComponent(numcommande)}`,
          { status: pdInfo.status },
        ).catch(() => {});
        await ecrireAudit({
          numcommande,
          ancienStatut:  dbTx["status"] as string,
          nouveauStatut: pdInfo.status,
          source:        "IPN",
          reponseApi:    ipnPayload,
        });
      }
      return { ok: false, message: `Paiement non complété: status=${pdInfo.status}` };
    }

    const dbAmount = (dbTx["amount"] as number) ?? 0;
    if (dbAmount <= 0) {
      return { ok: false, message: `Montant DB invalide: ${dbAmount}` };
    }

    const now = new Date().toISOString();

    await sbPatch(
      "paydunya_transactions",
      `internal_reference=eq.${encodeURIComponent(numcommande)}`,
      {
        status:          "confirmed",
        confirmed_at:    now,
        ipn_received_at: now,
        operateur:       pdInfo.operateur ?? null,
        receipt_url:     pdInfo.receiptUrl ?? null,
      },
    );

    try {
      await crediterCoteServeur({ ...dbTx });
    } catch (e: unknown) {
      const msg = e instanceof Error ? e.message : String(e);
      console.error(`[ipn-verifier] Erreur RPC crédit:`, msg);
      await sbPatch(
        "paydunya_transactions",
        `internal_reference=eq.${encodeURIComponent(numcommande)}`,
        { error_message: `credit_error: ${msg}` },
      ).catch(() => {});
      await ecrireAudit({
        numcommande, ancienStatut: "confirmed",
        nouveauStatut: "error", source: "IPN", erreur: msg,
      });
      return { ok: false, message: msg };
    }

    await sbPatch(
      "paydunya_transactions",
      `internal_reference=eq.${encodeURIComponent(numcommande)}`,
      { status: "credited", credited_at: now },
    );

    await ecrireAudit({
      numcommande,
      ancienStatut:  "confirmed",
      nouveauStatut: "credited",
      source:        "IPN",
      reponseApi:    { token: effectiveToken, amount_xof: dbAmount, operateur: pdInfo.operateur },
    });

    console.log(`[ipn-verifier] ✅ ${numcommande} crédité OK`);
    return { ok: true, message: "Crédité" };

  } catch (e: unknown) {
    const msg = e instanceof Error ? e.message : String(e);
    console.error(`[ipn-verifier] ❌ Exception:`, msg);
    await ecrireAudit({ numcommande, nouveauStatut: "error", source: "IPN", erreur: msg });
    return { ok: false, message: msg };
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Handler IPN principal
// ─────────────────────────────────────────────────────────────────────────────

Deno.serve(async (req: Request) => {
  // PayDunya IPN = POST JSON
  // On retourne TOUJOURS HTTP 200 (PayDunya re-tente si non-200)

  if (req.method !== "POST") {
    return new Response("OK", { status: 200 });
  }

  let payload: Record<string, unknown> = {};
  try {
    payload = await req.json();
  } catch {
    console.warn("[ipn] Payload JSON invalide");
    return new Response("OK", { status: 200 });
  }

  const status     = (payload["status"]     as string) ?? "";
  const token      = (payload["token"]      as string) ?? "";
  const hash       = (payload["hash"]       as string) ?? "";
  const customData = (payload["custom_data"] as Record<string, unknown>) ?? {};

  console.log(`[ipn] Reçu status=${status} token=${token} hash=${hash.slice(0, 16)}...`);

  // ── 1. Vérification hash SHA-512 (PAYDUNYA_MASTER_KEY) ────────────────────
  // PayDunya envoie hash = SHA-512(MasterKey)
  if (PD_MASTER_KEY) {
    if (!hash) {
      console.error("[ipn] hash absent — IPN rejeté");
      return new Response("OK", { status: 200 });
    }
    try {
      const expectedHash = (await sha512(PD_MASTER_KEY)).toLowerCase();
      if (hash.toLowerCase() !== expectedHash) {
        console.error(`[ipn] Hash invalide — IPN rejeté (token=${token})`);
        return new Response("OK", { status: 200 });
      }
      console.log("[ipn] ✅ Hash SHA-512 validé");
    } catch (e) {
      console.error("[ipn] Erreur validation hash:", e);
      return new Response("OK", { status: 200 });
    }
  } else {
    console.warn("[ipn] ⚠️  PAYDUNYA_MASTER_KEY non configuré — validation hash désactivée");
  }

  // ── 2. Extraire numcommande depuis custom_data ─────────────────────────────
  // custom_data.numcommande est injecté lors de la création de l'invoice
  const numcommande = (customData["numcommande"] as string) ?? "";

  if (!numcommande || !numcommande.startsWith("TDP_")) {
    console.warn(`[ipn] numcommande absent ou invalide dans custom_data: "${numcommande}"`);
    // Essayer de retrouver via token en DB
    if (token) {
      try {
        const rows = await sbSelect(
          "paydunya_transactions",
          `pd_token=eq.${encodeURIComponent(token)}&select=internal_reference`,
        );
        if (rows.length > 0) {
          const ref = rows[0]["internal_reference"] as string;
          console.log(`[ipn] Trouvé via token → numcommande="${ref}"`);
          // Continuer avec ce ref
          await sbPatch(
            "paydunya_transactions",
            `pd_token=eq.${encodeURIComponent(token)}`,
            { ipn_received_at: new Date().toISOString() },
          ).catch(() => {});

          if (status === "completed") {
            await verifierEtCrediter(ref, token, payload);
          } else if (status === "cancelled" || status === "failed") {
            await sbPatch(
              "paydunya_transactions",
              `internal_reference=eq.${encodeURIComponent(ref)}`,
              { status },
            ).catch(() => {});
          }
        }
      } catch (e) {
        console.error("[ipn] Lookup par token échoué:", e);
      }
    }
    return new Response("OK", { status: 200 });
  }

  console.log(`[ipn] Tx identifiée: numcommande="${numcommande}" status="${status}"`);

  // ── 3. Enregistrer réception IPN ─────────────────────────────────────────
  await sbPatch(
    "paydunya_transactions",
    `internal_reference=eq.${encodeURIComponent(numcommande)}`,
    { ipn_received_at: new Date().toISOString() },
  ).catch(() => {});

  // ── 4. Vérifier idempotence rapide ────────────────────────────────────────
  try {
    const existing = await sbSelect(
      "paydunya_transactions",
      `internal_reference=eq.${encodeURIComponent(numcommande)}&select=status`,
    );
    if (existing.length > 0 && existing[0]["status"] === "credited") {
      console.log(`[ipn] ${numcommande} déjà crédité → skip`);
      return new Response("OK", { status: 200 });
    }
  } catch { /* continuer */ }

  // ── 5. Traiter selon statut IPN ───────────────────────────────────────────
  if (status === "completed") {
    console.log(`[ipn] completed → vérification stricte pour ${numcommande}`);
    const result = await verifierEtCrediter(numcommande, token, payload);
    console.log(`[ipn] Résultat: ok=${result.ok} msg="${result.message}"`);

  } else if (status === "cancelled" || status === "failed") {
    console.log(`[ipn] ${status} pour ${numcommande}`);
    await sbPatch(
      "paydunya_transactions",
      `internal_reference=eq.${encodeURIComponent(numcommande)}`,
      { status },
    ).catch(() => {});
    await ecrireAudit({
      numcommande,
      ancienStatut:  "pending",
      nouveauStatut: status,
      source:        "IPN",
      reponseApi:    { ipn_status: status, token },
    });

  } else if (status === "pending") {
    console.log(`[ipn] pending (en attente de paiement) pour ${numcommande} — log seulement`);
    await ecrireAudit({
      numcommande,
      ancienStatut:  "pending",
      nouveauStatut: "ipn_pending",
      source:        "IPN",
      reponseApi:    { ipn_status: status, token },
    });

  } else {
    console.log(`[ipn] Status "${status}" non géré pour ${numcommande} — log seulement`);
    await ecrireAudit({
      numcommande,
      ancienStatut:  "pending",
      nouveauStatut: `ipn_status_${status}`,
      source:        "IPN",
      reponseApi:    { ipn_status: status, token },
    });
  }

  // TOUJOURS HTTP 200
  return new Response("OK", { status: 200 });
});
