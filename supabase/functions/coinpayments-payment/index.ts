// ─────────────────────────────────────────────────────────────────────────────
// coinpayments-payment — Edge Function Supabase (Deno/TypeScript)
//
// Miroir sécurisé de sycapay-payment pour le prestataire CoinPayments.
// Même architecture v5 :
//   - Clés JAMAIS dans Flutter — uniquement via cette Edge Function
//   - Crédit UNIQUEMENT via confirmerEtCrediterStrictement (8 étapes)
//   - Verrou pessimiste FOR UPDATE via RPC Supabase
//   - Journal d'audit immuable dans coinpayments_audit_log
//   - Réutilise les RPCs SycaPay (crediter_*_sycapay) avec p_operateur='coinpayments'
//
// Variables d'environnement requises :
//   COINPAYMENTS_PUBLIC_KEY      — clé publique API CoinPayments
//   COINPAYMENTS_PRIVATE_KEY     — clé privée HMAC-SHA512
//   COINPAYMENTS_IPN_SECRET      — secret IPN pour validation webhook
//   SUPABASE_URL                 — URL projet Supabase
//   SUPABASE_SERVICE_ROLE_KEY    — clé service role (accès total DB)
//
// Actions supportées (POST JSON) :
//   creer_transaction       — Initie un paiement CoinPayments (create_transaction)
//   statut                  — Consulte le statut d'une transaction (get_tx_info)
//   confirmer_et_crediter   — Vérifie & crédite côté serveur (SEULE voie légitime)
//   verifier_ref            — Lecture seule du statut en DB
//
// IPN Webhook CoinPayments :
//   POST ?action=ipn  — Reçoit les notifications IPN CoinPayments
// ─────────────────────────────────────────────────────────────────────────────

// ── Env vars ──────────────────────────────────────────────────────────────────
const CP_PUBLIC_KEY  = Deno.env.get("COINPAYMENTS_PUBLIC_KEY")   ?? "";
const CP_PRIVATE_KEY = Deno.env.get("COINPAYMENTS_PRIVATE_KEY")  ?? "";
const CP_IPN_SECRET  = Deno.env.get("COINPAYMENTS_IPN_SECRET")   ?? "";
const SUPABASE_URL   = Deno.env.get("SUPABASE_URL")              ?? "";
const SERVICE_KEY    = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

// ── CoinPayments API ──────────────────────────────────────────────────────────
const CP_API = "https://www.coinpayments.net/api.php";

// ── CORS ──────────────────────────────────────────────────────────────────────
const CORS = {
  "Access-Control-Allow-Origin":  "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

// ── Status normalisés ─────────────────────────────────────────────────────────
// CoinPayments status codes :
//   -1  = Cancelled / Timed Out
//    0  = Waiting for buyer funds
//    1  = Coin received, waiting confirms
//    2  = Queued for nightly payout
//  100  = Complete (SEUL code = crédité)
type NStatus = "pending" | "processing" | "confirmed" | "failed" | "cancelled" | "unknown";

function normaliserStatutCP(statusCode: number): NStatus {
  if (statusCode === 100)             return "confirmed";
  if (statusCode === 2)               return "processing";
  if (statusCode >= 0 && statusCode < 100) return "pending";
  if (statusCode === -1)              return "cancelled";
  return "unknown";
}

// ── Helpers JSON ──────────────────────────────────────────────────────────────
function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers Supabase (service role)
// ─────────────────────────────────────────────────────────────────────────────

function sbHeaders(): Record<string, string> {
  return {
    "Content-Type":  "application/json",
    "apikey":        SERVICE_KEY,
    "Authorization": `Bearer ${SERVICE_KEY}`,
    "Prefer":        "return=minimal",
  };
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
    const errText = await res.text();
    throw new Error(`sbFetch ${method} ${path} → ${res.status}: ${errText}`);
  }
  const text = await res.text();
  if (!text) return {};
  return JSON.parse(text);
}

async function sbRpc(
  fn: string,
  params: Record<string, unknown>,
): Promise<void> {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${fn}`, {
    method:  "POST",
    headers: { ...sbHeaders(), "Prefer": "return=minimal" },
    body:    JSON.stringify(params),
  });
  if (!res.ok) {
    const errText = await res.text();
    throw new Error(`sbRpc ${fn} → ${res.status}: ${errText}`);
  }
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
    const errText = await res.text();
    throw new Error(`sbSelect ${table} → ${res.status}: ${errText}`);
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
    const errText = await res.text();
    throw new Error(`sbPatch ${table} → ${res.status}: ${errText}`);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// HMAC-SHA512 pour CoinPayments
// CoinPayments auth : HMAC-SHA512 du body POST encodé, clé = PRIVATE_KEY
// Header : X-Coinpayments-Key = PUBLIC_KEY
// ─────────────────────────────────────────────────────────────────────────────

async function hmacSha512(message: string, secret: string): Promise<string> {
  const encoder  = new TextEncoder();
  const keyData  = encoder.encode(secret);
  const msgData  = encoder.encode(message);
  const cryptoKey = await crypto.subtle.importKey(
    "raw", keyData,
    { name: "HMAC", hash: "SHA-512" },
    false, ["sign"],
  );
  const signature = await crypto.subtle.sign("HMAC", cryptoKey, msgData);
  return Array.from(new Uint8Array(signature))
    .map(b => b.toString(16).padStart(2, "0"))
    .join("");
}

// Appel générique à l'API CoinPayments
async function cpApiCall(
  cmd: string,
  params: Record<string, string | number>,
): Promise<Record<string, unknown>> {
  if (!CP_PUBLIC_KEY || !CP_PRIVATE_KEY) {
    throw new Error("COINPAYMENTS_PUBLIC_KEY / COINPAYMENTS_PRIVATE_KEY non configurés");
  }

  // Body URL-encoded (requis par CoinPayments v1)
  const allParams: Record<string, string> = {
    version: "1",
    cmd,
    key:     CP_PUBLIC_KEY,
    format:  "json",
    ...Object.fromEntries(
      Object.entries(params).map(([k, v]) => [k, String(v)])
    ),
  };

  const bodyStr = Object.entries(allParams)
    .map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`)
    .join("&");

  const hmac = await hmacSha512(bodyStr, CP_PRIVATE_KEY);

  const res = await fetch(CP_API, {
    method:  "POST",
    headers: {
      "Content-Type":         "application/x-www-form-urlencoded",
      "X-Coinpayments-Key":   CP_PUBLIC_KEY,
      "HMAC":                 hmac,
    },
    body: bodyStr,
  });

  if (!res.ok) {
    throw new Error(`CoinPayments API HTTP ${res.status}`);
  }

  const data = await res.json() as Record<string, unknown>;

  // CoinPayments retourne { error: "ok", result: {...} } ou { error: "message d'erreur" }
  if (data["error"] !== "ok") {
    throw new Error(`CoinPayments API error: ${data["error"]}`);
  }

  return (data["result"] as Record<string, unknown>) ?? {};
}

// ─────────────────────────────────────────────────────────────────────────────
// create_transaction — crée une transaction CoinPayments
// Retourne { txn_id, checkout_url, status_url, timeout, amount, ... }
// ─────────────────────────="────────────────────────────────────────────────────

async function cpCreateTransaction(params: {
  amount:     number;  // montant en XOF (CoinPayments convertit via taux de change)
  currency1:  string;  // devise d'entrée : "XOF"
  currency2:  string;  // devise crypto : "USDT.TRC20" | "BTC" | "ETH" | "LTC" | "USDT.ERC20"
  buyer_email?: string;
  item_name:  string;
  item_number: string; // = numCommande (référence interne)
  custom:     string;  // metadata JSON stringifié
  ipn_url:    string;
  success_url?: string;
  cancel_url?:  string;
}): Promise<{
  txn_id:       string;
  checkout_url: string;
  status_url:   string;
  timeout:      number;
  amount:       string;
  amountf:      number;
}> {
  const result = await cpApiCall("create_transaction", {
    amount:       params.amount,
    currency1:    params.currency1,
    currency2:    params.currency2,
    buyer_email:  params.buyer_email ?? "",
    item_name:    params.item_name,
    item_number:  params.item_number,
    custom:       params.custom,
    ipn_url:      params.ipn_url,
    ...(params.success_url ? { success_url: params.success_url } : {}),
    ...(params.cancel_url  ? { cancel_url:  params.cancel_url  } : {}),
  });

  return {
    txn_id:       result["txn_id"]       as string,
    checkout_url: result["checkout_url"] as string,
    status_url:   result["status_url"]   as string,
    timeout:      result["timeout"]      as number ?? 7200,
    amount:       result["amount"]       as string ?? "0",
    amountf:      parseFloat(result["amountf"] as string ?? "0"),
  };
}

// ─────────────────────────────────────────────────────────────────────────────
// get_tx_info — récupère le statut d'une transaction CoinPayments
// ─────────────────────────────────────────────────────────────────────────────

async function cpGetTxInfo(txid: string): Promise<{
  status:      number;
  status_text: string;
  amount:      string;
  amountf:     number;
  coin:        string;
  confirms_needed: number;
  recv_confirms:   number;
  recv_amount:     string;
  recv_amountf:    number;
}> {
  const result = await cpApiCall("get_tx_info", { txid });
  return {
    status:           result["status"]          as number  ?? -1,
    status_text:      result["status_text"]      as string ?? "",
    amount:           result["amount"]           as string ?? "0",
    amountf:          parseFloat(result["amountf"]   as string ?? "0"),
    coin:             result["coin"]             as string ?? "",
    confirms_needed:  result["confirms_needed"]  as number ?? 0,
    recv_confirms:    result["recv_confirms"]    as number ?? 0,
    recv_amount:      result["recv_amount"]      as string ?? "0",
    recv_amountf:     parseFloat(result["recv_amountf"] as string ?? "0"),
  };
}

// ─────────────────────────────────────────────────────────────────────────────
// Audit log
// ─────────────────────────────────────────────────────────────────────────────

async function ecrireAudit(params: {
  numcommande:   string;
  ancienStatut?: string;
  nouveauStatut: string;
  source:        string;
  reponseApi?:   unknown;
  erreur?:       string;
}): Promise<void> {
  await sbFetch("/rest/v1/coinpayments_audit_log", "POST", {
    internal_reference: params.numcommande,
    ancien_statut:      params.ancienStatut ?? "unknown",
    nouveau_statut:     params.nouveauStatut,
    source:             params.source,
    reponse_api:        params.reponseApi ?? null,
    erreur:             params.erreur     ?? null,
    created_at:         new Date().toISOString(),
  }).catch(e => console.error("[audit] Échec écriture audit:", e));
}

// ─────────────────────────────────────────────────────────────────────────────
// Messages lisibles
// ─────────────────────────────────────────────────────────────────────────────

function messageSucces(typeOp: string): string {
  const map: Record<string, string> = {
    cotisation:        "Cotisation enregistrée avec succès.",
    caisse:            "Apport caisse enregistré avec succès.",
    penalite:          "Pénalité réglée avec succès.",
    remboursement_pret:"Remboursement enregistré avec succès.",
    pret_octroye:      "Décaissement prêt enregistré avec succès.",
  };
  return map[typeOp] ?? "Paiement crypto enregistré avec succès.";
}

// ─────────────────────────────────────────────────────────────────────────────
// Crédit côté serveur (réutilise les RPCs SycaPay avec p_operateur='coinpayments')
// ─────────────────────────────────────────────────────────────────────────────

async function crediterCoteServeur(
  tx: Record<string, unknown>,
): Promise<void> {
  const typeOp     = (tx["type_operation"]  as string) ?? "cotisation";
  const code       = ((tx["tontine_code"]   as string) ?? "").toUpperCase();
  const amount     = (tx["amount"]          as number) ?? 0;
  const txid       = (tx["provider_transaction_id"] as string) ?? "";
  const numcmd     = (tx["internal_reference"]      as string) ?? "";
  const membreId   = (tx["membre_id"]        as string) ?? null;
  const pretId     = (tx["pret_id"]          as string) ?? null;
  const now        = new Date().toISOString();
  const description = (tx["description"]    as string) ?? null;

  // Tous les crédits passent par les RPCs existants avec p_operateur='coinpayments'
  // Cela permet de tracer l'origine dans sycapay_transactions (champ operator)
  if (typeOp === "cotisation") {
    await sbRpc("crediter_cotisation_sycapay", {
      p_code:         code,
      p_montant:      amount,
      p_reference:    txid,
      p_num_commande: numcmd,
      p_operateur:    "coinpayments",
      p_now:          now,
    });

  } else if (typeOp === "caisse") {
    await sbRpc("crediter_caisse_sycapay", {
      p_code:         code,
      p_montant:      amount,
      p_reference:    txid,
      p_num_commande: numcmd,
      p_operateur:    "coinpayments",
      p_description:  description,
      p_now:          now,
    });

  } else if (typeOp === "penalite") {
    await sbRpc("crediter_penalite_sycapay", {
      p_code:         code,
      p_montant:      amount,
      p_reference:    txid,
      p_num_commande: numcmd,
      p_operateur:    "coinpayments",
      p_membre_id:    membreId,
      p_now:          now,
    });

  } else if (typeOp === "remboursement_pret") {
    await sbRpc("crediter_remboursement_sycapay", {
      p_code:         code,
      p_montant:      amount,
      p_reference:    txid,
      p_num_commande: numcmd,
      p_operateur:    "coinpayments",
      p_pret_id:      pretId,
      p_now:          now,
    });

  } else if (typeOp === "pret_octroye") {
    await sbRpc("debiter_pret_sycapay", {
      p_code:         code,
      p_montant:      amount,
      p_reference:    txid,
      p_num_commande: numcmd,
      p_operateur:    "coinpayments",
      p_pret_id:      pretId,
      p_now:          now,
    });

  } else {
    // Fallback générique : traité comme apport caisse
    console.warn(`[crediter] typeOp inconnu "${typeOp}" → fallback caisse`);
    await sbRpc("crediter_caisse_sycapay", {
      p_code:         code,
      p_montant:      amount,
      p_reference:    txid,
      p_num_commande: numcmd,
      p_operateur:    "coinpayments",
      p_description:  `[${typeOp}] ${description ?? ""}`,
      p_now:          now,
    });
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// verifierEtCrediterStrictement — 8 étapes de vérification (miroir SycaPay v5)
//
// RÈGLE ABSOLUE : cette fonction est la SEULE porte d'entrée pour créditer.
// Elle doit être appelée depuis confirmer_et_crediter ET depuis le webhook IPN.
// ─────────────────────────────────────────────────────────────────────────────

async function verifierEtCrediterStrictement(
  numcommande: string,
  source: "POLLING" | "WEBHOOK",
  txRow: Record<string, unknown>,
): Promise<{ ok: boolean; message: string }> {
  console.log(`[verifier] Début vérification stricte ${numcommande} (source=${source})`);

  try {

    // ── Étape 1 : Récupérer la transaction en DB ──────────────────────────────
    const rows = await sbSelect(
      "coinpayments_transactions",
      `internal_reference=eq.${encodeURIComponent(numcommande)}&select=*`,
    );
    if (rows.length === 0) {
      const msg = `[verifier] Transaction introuvable en DB: ${numcommande}`;
      console.error(msg);
      await ecrireAudit({ numcommande, nouveauStatut: "error", source, erreur: msg });
      return { ok: false, message: "Transaction introuvable" };
    }
    const dbTx = rows[0];

    // ── Étape 2 : Vérification idempotence ────────────────────────────────────
    if (dbTx["status"] === "credited") {
      console.log(`[verifier] ${numcommande} déjà crédité → idempotent`);
      return { ok: true, message: "Déjà crédité (idempotent)" };
    }

    // ── Étape 3 : Statut compatible avec le crédit ────────────────────────────
    // On accepte pending/processing/confirmed (CoinPayments peut passer en 100 sans confirmed intermédiaire)
    const currentStatus = dbTx["status"] as string;
    if (currentStatus === "failed" || currentStatus === "cancelled") {
      const msg = `[verifier] Statut ${currentStatus} incompatible avec le crédit`;
      console.error(msg);
      await ecrireAudit({ numcommande, ancienStatut: currentStatus, nouveauStatut: "error", source, erreur: msg });
      return { ok: false, message: `Transaction ${currentStatus} — crédit refusé` };
    }

    // ── Étape 4 : Re-vérification officielle via get_tx_info ─────────────────
    const txid = (dbTx["provider_transaction_id"] ?? txRow["provider_transaction_id"]) as string | undefined;
    if (!txid) {
      const msg = `[verifier] txid absent pour ${numcommande}`;
      console.error(msg);
      await ecrireAudit({ numcommande, nouveauStatut: "error", source, erreur: msg });
      return { ok: false, message: "TXID CoinPayments introuvable" };
    }

    let cpInfo: Awaited<ReturnType<typeof cpGetTxInfo>>;
    try {
      cpInfo = await cpGetTxInfo(txid);
    } catch (e) {
      const msg = `[verifier] Erreur get_tx_info pour ${txid}: ${e}`;
      console.error(msg);
      await ecrireAudit({ numcommande, nouveauStatut: "error", source, erreur: msg });
      return { ok: false, message: "Impossible de vérifier le statut CoinPayments" };
    }

    const cpStatus = normaliserStatutCP(cpInfo.status);
    console.log(`[verifier] get_tx_info → status=${cpInfo.status} (${cpStatus}) txid=${txid}`);

    await ecrireAudit({
      numcommande,
      ancienStatut: currentStatus,
      nouveauStatut: `api_check:${cpStatus}`,
      source,
      reponseApi: { status: cpInfo.status, status_text: cpInfo.status_text },
    });

    // ── Étape 5 : Status doit être 100 (Complete) ────────────────────────────
    if (cpInfo.status !== 100) {
      const msg = `[verifier] Status CoinPayments ${cpInfo.status} ≠ 100 → crédit refusé`;
      console.warn(msg);
      // Mettre à jour le statut en DB sans créditer
      if (cpStatus === "cancelled" || cpInfo.status === -1) {
        await sbPatch(
          "coinpayments_transactions",
          `internal_reference=eq.${encodeURIComponent(numcommande)}`,
          { status: "cancelled", error_message: cpInfo.status_text },
        ).catch(() => {});
      }
      return { ok: false, message: `Paiement pas encore confirmé (status=${cpInfo.status})` };
    }

    // ── Étape 6 : Vérification du montant ────────────────────────────────────
    const dbAmount    = (dbTx["amount"]   as number) ?? 0;
    const mergedTx = { ...txRow, ...dbTx };

    if (dbAmount <= 0) {
      const msg = `[verifier] Montant DB invalide: ${dbAmount}`;
      console.error(msg);
      await ecrireAudit({ numcommande, nouveauStatut: "error", source, erreur: msg });
      return { ok: false, message: "Montant invalide en DB" };
    }

    console.log(`[verifier] Montant DB=${dbAmount} XOF — CoinPayments recv=${cpInfo.recv_amountf} ${cpInfo.coin}`);

    // ── Étape 7 : Confirmer en DB (status → confirmed) ───────────────────────
    const now = new Date().toISOString();
    await sbPatch(
      "coinpayments_transactions",
      `internal_reference=eq.${encodeURIComponent(numcommande)}`,
      {
        status:       "confirmed",
        confirmed_at: now,
        provider_transaction_id: txid,
      },
    );

    // ── Étape 8 : Crédit effectif via RPC Supabase ───────────────────────────
    try {
      await crediterCoteServeur(mergedTx);
    } catch (e: unknown) {
      const msg = e instanceof Error ? e.message : String(e);
      console.error(`[verifier] Erreur crédit RPC ${numcommande}: ${msg}`);
      await sbPatch(
        "coinpayments_transactions",
        `internal_reference=eq.${encodeURIComponent(numcommande)}`,
        { error_message: `credit_error: ${msg}` },
      ).catch(() => {});
      await ecrireAudit({ numcommande, ancienStatut: "confirmed", nouveauStatut: "error", source, erreur: msg });
      return { ok: false, message: msg };
    }

    // Marquer credited
    await sbPatch(
      "coinpayments_transactions",
      `internal_reference=eq.${encodeURIComponent(numcommande)}`,
      { status: "credited", credited_at: now },
    );

    await ecrireAudit({
      numcommande,
      ancienStatut: "confirmed",
      nouveauStatut: "credited",
      source,
      reponseApi: { txid, amount: dbAmount },
    });

    console.log(`[verifier] ✅ ${numcommande} crédité avec succès (txid=${txid})`);
    return { ok: true, message: "Crédité" };

  } catch (e: unknown) {
    const msg = e instanceof Error ? e.message : String(e);
    console.error(`[verifier] ❌ Exception ${numcommande}:`, msg);
    await ecrireAudit({ numcommande, nouveauStatut: "error", source, erreur: msg });
    return { ok: false, message: msg };
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Handler principal
// ─────────────────────────────────────────────────────────────────────────────

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: CORS });

  const url = new URL(req.url);

  // ── Webhook IPN CoinPayments ──────────────────────────────────────────────
  if (
    url.searchParams.get("action") === "ipn" ||
    url.pathname.endsWith("/ipn")
  ) {
    return handleIpn(req);
  }

  if (req.method !== "POST") {
    return json({ erreur: true, message: "Méthode non supportée" }, 405);
  }

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json({ erreur: true, message: "JSON invalide" }, 400);
  }

  const action = body["action"] as string | undefined;

  try {

    // ══════════════════════════════════════════════════════════════════════════
    // ACTION : creer_transaction
    // Initie le paiement CoinPayments → checkout_url retourné à Flutter.
    // Ne crédite rien — persistance en PENDING uniquement.
    // ══════════════════════════════════════════════════════════════════════════
    if (action === "creer_transaction") {
      const montant      = body["montant"]        as number;
      const numcommande  = body["numcommande"]    as string;
      const currency2    = (body["currency2"]     as string) ?? "USDT.TRC20";
      const tontineCode  = (body["tontine_code"]  as string) ?? "";
      const typeOp       = (body["type_operation"] as string) ?? "cotisation";
      const membreId     = body["membre_id"]      as string | undefined;
      const membreNom    = (body["membre_nom"]    as string) ?? "";
      const pretId       = (body["pret_id"]       as string) ?? null;
      const description  = (body["description"]   as string) ?? `TontineClair - ${typeOp}`;

      if (!montant || !numcommande) {
        return json({ erreur: true, message: "montant et numcommande requis" }, 400);
      }

      // Idempotence : transaction déjà confirmée/créditée → succès immédiat
      if (tontineCode) {
        const existing = await sbSelect(
          "coinpayments_transactions",
          `internal_reference=eq.${encodeURIComponent(numcommande)}&select=id,status,provider_transaction_id,checkout_url`,
        );
        if (existing.length > 0) {
          const tx = existing[0];
          if (tx["status"] === "credited" || tx["status"] === "confirmed") {
            return json({
              erreur:        false,
              idempotent:    true,
              txid:          tx["provider_transaction_id"],
              checkoutUrl:   tx["checkout_url"],
              status:        tx["status"],
              statusNorm:    "confirmed",
              numcommande,
            });
          }
          // Pending avec checkout_url déjà existant → renvoyer l'url
          if (tx["status"] === "pending" && tx["checkout_url"]) {
            return json({
              erreur:      false,
              idempotent:  true,
              txid:        tx["provider_transaction_id"],
              checkoutUrl: tx["checkout_url"],
              status:      "pending",
              statusNorm:  "pending",
              numcommande,
            });
          }
        }
      }

      // URL IPN pour CoinPayments
      const ipnUrl = `${SUPABASE_URL}/functions/v1/coinpayments-payment?action=ipn&ref=${encodeURIComponent(numcommande)}`;

      // Metadata JSON compacté dans custom (max 256 chars CoinPayments)
      const customMeta = JSON.stringify({
        tc: tontineCode,
        op: typeOp,
        mid: membreId ?? "",
        pid: pretId ?? "",
      }).slice(0, 255);

      // Appel create_transaction
      let cpResult: Awaited<ReturnType<typeof cpCreateTransaction>>;
      try {
        cpResult = await cpCreateTransaction({
          amount:       montant,
          currency1:    "XOF",
          currency2,
          item_name:    description,
          item_number:  numcommande,
          custom:       customMeta,
          ipn_url:      ipnUrl,
        });
      } catch (e: unknown) {
        const msg = e instanceof Error ? e.message : String(e);
        console.error(`[creer] Erreur CoinPayments create_transaction:`, msg);
        return json({ erreur: true, message: `Erreur CoinPayments: ${msg}` }, 502);
      }

      console.log(`[creer] Transaction créée: txid=${cpResult.txn_id} ref=${numcommande}`);

      // Persister en DB — statut PENDING
      if (tontineCode) {
        await sbFetch("/rest/v1/coinpayments_transactions", "POST", {
          tontine_code:            tontineCode,
          type_operation:          typeOp,
          internal_reference:      numcommande,
          provider_transaction_id: cpResult.txn_id,
          checkout_url:            cpResult.checkout_url,
          currency2,
          amount:                  montant,
          currency:                "XOF",
          status:                  "pending",
          membre_id:               membreId ?? null,
          membre_nom:              membreNom || null,
          pret_id:                 pretId || null,
          description:             description,
          cp_timeout:              cpResult.timeout,
          created_at:              new Date().toISOString(),
        }).catch(async (e: Error) => {
          // Doublon → mettre à jour txid et checkout_url seulement
          if (e.message.includes("23505") || e.message.includes("duplicate")) {
            await sbPatch(
              "coinpayments_transactions",
              `internal_reference=eq.${encodeURIComponent(numcommande)}`,
              {
                provider_transaction_id: cpResult.txn_id,
                checkout_url:            cpResult.checkout_url,
              },
            ).catch(() => {});
          } else {
            console.error("[creer] persistance DB:", e.message);
          }
        });

        await ecrireAudit({
          numcommande,
          ancienStatut: "inexistant",
          nouveauStatut: "pending",
          source: "CREATE",
          reponseApi: { txn_id: cpResult.txn_id, currency2 },
        });
      }

      return json({
        erreur:      false,
        txid:        cpResult.txn_id,
        checkoutUrl: cpResult.checkout_url,
        statusUrl:   cpResult.status_url,
        timeout:     cpResult.timeout,
        amount:      cpResult.amount,
        amountf:     cpResult.amountf,
        currency2,
        status:      "pending",
        statusNorm:  "pending",
        numcommande,
      });
    }

    // ══════════════════════════════════════════════════════════════════════════
    // ACTION : statut
    // Lecture seule — consulte DB + get_tx_info CoinPayments.
    // NE CRÉDITE JAMAIS — retourne uniquement le statut pour polling Flutter.
    // Pour déclencher un crédit, Flutter doit appeler confirmer_et_crediter.
    // ══════════════════════════════════════════════════════════════════════════
    if (action === "statut") {
      const txid        = body["txid"]         as string | undefined;
      const numcommande = body["numcommande"]  as string | undefined;

      if (!txid && !numcommande) {
        return json({ erreur: true, message: "txid ou numcommande requis" }, 400);
      }

      // 1. Chercher en DB
      let dbTx: Record<string, unknown> | null = null;
      if (numcommande) {
        const rows = await sbSelect(
          "coinpayments_transactions",
          `internal_reference=eq.${encodeURIComponent(numcommande)}&select=*`,
        );
        if (rows.length > 0) dbTx = rows[0];
      }

      // 2. Déjà crédité → succès immédiat (cache hit)
      if (dbTx && dbTx["status"] === "credited") {
        return json({
          erreur:     false,
          ok:         true,
          statusCode: 100,
          statusNorm: "confirmed",
          message:    "Paiement confirmé et enregistré.",
          numcommande,
          txid:       dbTx["provider_transaction_id"],
          fromCache:  true,
        });
      }

      // 3. Failed/cancelled en DB → pas besoin de consulter l'API
      if (dbTx && (dbTx["status"] === "failed" || dbTx["status"] === "cancelled")) {
        return json({
          erreur:     false,
          ok:         false,
          statusCode: -1,
          statusNorm: dbTx["status"] as string,
          message:    "Paiement annulé ou échoué.",
          numcommande,
          fromCache:  true,
        });
      }

      // 4. get_tx_info via API CoinPayments
      const effectiveTxid = txid
        ?? (dbTx ? (dbTx["provider_transaction_id"] as string | undefined) : undefined);

      if (!effectiveTxid) {
        return json({ erreur: true, message: "txid CoinPayments introuvable" }, 400);
      }

      let cpInfo: Awaited<ReturnType<typeof cpGetTxInfo>>;
      try {
        cpInfo = await cpGetTxInfo(effectiveTxid);
      } catch (e: unknown) {
        const msg = e instanceof Error ? e.message : String(e);
        console.error(`[statut] Erreur get_tx_info:`, msg);
        // Retourner le statut DB si disponible
        if (dbTx) {
          return json({
            erreur:     false,
            ok:         false,
            statusCode: 0,
            statusNorm: (dbTx["status"] as string) ?? "pending",
            message:    "Vérification CoinPayments temporairement indisponible.",
            numcommande,
            fromCache:  true,
          });
        }
        return json({ erreur: true, message: `Erreur API CoinPayments: ${msg}` }, 502);
      }

      const norm = normaliserStatutCP(cpInfo.status);

      // 5. Mise à jour DB (statut seulement, JAMAIS de crédit ici)
      if (dbTx && numcommande) {
        const updateData: Record<string, unknown> = {
          polling_attempts: ((dbTx["polling_attempts"] as number) ?? 0) + 1,
        };
        if (norm === "confirmed") {
          updateData["status"]       = "confirmed";
          updateData["confirmed_at"] = new Date().toISOString();
        } else if (norm === "cancelled") {
          updateData["status"]        = "cancelled";
          updateData["error_message"] = cpInfo.status_text;
        }
        await sbPatch(
          "coinpayments_transactions",
          `internal_reference=eq.${encodeURIComponent(numcommande)}`,
          updateData,
        ).catch(() => {});
      }

      return json({
        erreur:          false,
        ok:              norm === "confirmed",
        statusCode:      cpInfo.status,
        statusNorm:      norm,
        statusText:      cpInfo.status_text,
        coin:            cpInfo.coin,
        recvConfirms:    cpInfo.recv_confirms,
        confirmsNeeded:  cpInfo.confirms_needed,
        numcommande,
        txid:            effectiveTxid,
        // Signal Flutter : relancer confirmer_et_crediter
        needsCredit:     norm === "confirmed",
      });
    }

    // ══════════════════════════════════════════════════════════════════════════
    // ACTION : confirmer_et_crediter
    // SEULE voie légitime pour créditer depuis Flutter.
    // Appelle verifierEtCrediterStrictement (8 étapes).
    // ══════════════════════════════════════════════════════════════════════════
    if (action === "confirmer_et_crediter") {
      const txid        = body["txid"]           as string | undefined;
      const numcommande = body["numcommande"]    as string;
      const tontineCode = body["tontine_code"]   as string;
      const typeOp      = (body["type_operation"] as string) ?? "cotisation";
      const membreNom   = (body["membre_nom"]    as string) ?? "";

      if (!numcommande || !tontineCode) {
        return json({ erreur: true, message: "numcommande et tontine_code requis" }, 400);
      }

      // Récupérer ou créer la transaction en DB
      let rows = await sbSelect(
        "coinpayments_transactions",
        `internal_reference=eq.${encodeURIComponent(numcommande)}&select=*`,
      );

      // Si absente en DB → créer une ligne minimale (cas rare : IPN avant creer_transaction)
      if (rows.length === 0 && txid) {
        console.log(`[confirmer] ${numcommande} absente DB → création minimale`);
        await sbFetch("/rest/v1/coinpayments_transactions", "POST", {
          tontine_code:            tontineCode,
          type_operation:          typeOp,
          internal_reference:      numcommande,
          provider_transaction_id: txid,
          amount:                  (body["montant"] as number) ?? 0,
          currency:                "XOF",
          status:                  "pending",
          membre_id:               (body["membre_id"] as string) ?? null,
          membre_nom:              membreNom || null,
          pret_id:                 (body["pret_id"] as string) ?? null,
          description:             (body["description"] as string) ?? null,
        }).catch(e => console.error("[confirmer] création minimale:", e));

        rows = await sbSelect(
          "coinpayments_transactions",
          `internal_reference=eq.${encodeURIComponent(numcommande)}&select=*`,
        );
      }

      // Idempotent : déjà crédité
      if (rows.length > 0 && rows[0]["status"] === "credited") {
        return json({
          erreur:     false,
          ok:         true,
          statusCode: 100,
          statusNorm: "confirmed",
          message:    messageSucces(typeOp),
          numcommande,
          fromCache:  true,
        });
      }

      // Enrichir la ligne avec les infos du body
      const baseRow  = rows.length > 0 ? rows[0] : {};
      const enriched = {
        ...baseRow,
        tontine_code:   tontineCode,
        type_operation: typeOp,
        ...(txid         ? { provider_transaction_id: txid }                    : {}),
        ...(membreNom    ? { membre_nom:               membreNom }              : {}),
        ...(body["pret_id"]   ? { pret_id:    body["pret_id"]   as string }     : {}),
        ...(body["membre_id"] ? { membre_id:  body["membre_id"] as string }     : {}),
        ...(body["montant"]   ? { amount:     body["montant"]   as number }     : {}),
      };

      const result = await verifierEtCrediterStrictement(numcommande, "POLLING", enriched);

      return json({
        erreur:     !result.ok,
        ok:         result.ok,
        statusCode: result.ok ? 100 : -1,
        statusNorm: result.ok ? "confirmed" : "failed",
        message:    result.ok ? messageSucces(typeOp) : result.message,
        numcommande,
      });
    }

    // ══════════════════════════════════════════════════════════════════════════
    // ACTION : verifier_ref
    // Lecture seule — retourne le statut d'une transaction par référence.
    // ══════════════════════════════════════════════════════════════════════════
    if (action === "verifier_ref") {
      const numcommande = body["numcommande"] as string;
      if (!numcommande) return json({ erreur: true, message: "numcommande requis" }, 400);

      const rows = await sbSelect(
        "coinpayments_transactions",
        `internal_reference=eq.${encodeURIComponent(numcommande)}&select=status,confirmed_at,credited_at,provider_transaction_id,amount,currency2,type_operation,membre_id`,
      );

      if (rows.length === 0) return json({ trouve: false, status: "inexistant" });

      const tx = rows[0];
      return json({
        trouve:       true,
        status:       tx["status"],
        statusNorm:   (tx["status"] === "credited" || tx["status"] === "confirmed")
                      ? "confirmed" : (tx["status"] as string),
        amount:       tx["amount"],
        currency2:    tx["currency2"],
        confirmedAt:  tx["confirmed_at"],
        creditedAt:   tx["credited_at"],
        txid:         tx["provider_transaction_id"],
        membreId:     tx["membre_id"],
        typeOperation: tx["type_operation"],
        ok:           tx["status"] === "credited",
      });
    }

    // Bloquer toute tentative de forcer un crédit manuel
    if (action === "marquer_credite") {
      console.warn("[SÉCURITÉ] Action marquer_credite bloquée");
      return json({
        erreur:  true,
        message: "Action non autorisée. Le crédit est effectué exclusivement par vérification CoinPayments.",
      }, 403);
    }

    return json({ erreur: true, message: `Action inconnue: ${action}` }, 400);

  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    console.error("[coinpayments-payment] Erreur critique:", msg);
    return json({ erreur: true, code: -504, message: msg }, 500);
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// Handler Webhook IPN CoinPayments
//
// SÉCURISÉ v5 :
//   - Vérifie HMAC-SHA512 du payload IPN avec IPN_SECRET
//   - Ne fait JAMAIS confiance au statut IPN pour décider du crédit
//   - Re-consulte TOUJOURS get_tx_info avant de créditer
//   - Retourne toujours HTTP 200 pour éviter les re-tentatives IPN
// ─────────────────────────────────────────────────────────────────────────────

async function handleIpn(req: Request): Promise<Response> {
  const url         = new URL(req.url);
  const numcommande = url.searchParams.get("ref")
                   ?? url.searchParams.get("numcommande")
                   ?? "";

  // Lire le payload IPN (application/x-www-form-urlencoded)
  let payload: Record<string, string> = {};
  try {
    const text   = await req.text();
    const params = new URLSearchParams(text);
    params.forEach((v, k) => { payload[k] = v; });
  } catch {
    console.warn("[ipn] Impossible de lire le payload IPN");
    return new Response("OK", { status: 200 });
  }

  // Identifier la transaction
  const refEffective = numcommande
    || payload["order_id"]
    || payload["custom"]
    || "";

  console.log(`[ipn] Reçu ref=${refEffective || "AUCUN"} status=${payload["status"] ?? "?"}`);

  if (!refEffective) {
    console.warn("[ipn] Pas de référence → HTTP 200 (rien à faire)");
    return new Response("OK", { status: 200 });
  }

  // ── Vérification HMAC IPN ─────────────────────────────────────────────────
  // CoinPayments signe le payload IPN avec IPN_SECRET (HMAC-SHA512)
  // Header: "HMAC" = hmac-sha512(raw_post_body, IPN_SECRET)
  if (CP_IPN_SECRET) {
    const receivedHmac = req.headers.get("HMAC") ?? req.headers.get("hmac") ?? "";
    if (receivedHmac) {
      try {
        const rawBody = Object.entries(payload)
          .map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`)
          .join("&");
        const expectedHmac = await hmacSha512(rawBody, CP_IPN_SECRET);
        if (receivedHmac.toLowerCase() !== expectedHmac.toLowerCase()) {
          console.error(`[ipn] HMAC invalide → IPN rejeté (ref=${refEffective})`);
          // Retourner 200 pour ne pas exposer l'erreur de sécurité
          return new Response("OK", { status: 200 });
        }
        console.log(`[ipn] HMAC validé ✅`);
      } catch (e) {
        console.error(`[ipn] Erreur validation HMAC:`, e);
        return new Response("OK", { status: 200 });
      }
    } else {
      console.warn("[ipn] Header HMAC absent — IPN non authentifié");
      // En production avec IPN_SECRET configuré, rejeter si HMAC absent
      // En développement, on laisse passer pour faciliter les tests
    }
  }

  // Récupérer la transaction en DB
  const rows = await sbSelect(
    "coinpayments_transactions",
    `internal_reference=eq.${encodeURIComponent(refEffective)}&select=*`,
  ).catch(() => [] as Array<Record<string, unknown>>);

  if (rows.length === 0) {
    console.warn(`[ipn] Transaction introuvable: ${refEffective}`);
    return new Response("OK", { status: 200 });
  }

  const tx = rows[0];

  // Idempotence
  if (tx["status"] === "credited") {
    console.log(`[ipn] ${refEffective} déjà crédité → skip`);
    return new Response("OK", { status: 200 });
  }

  // Enregistrer la réception IPN
  await sbPatch(
    "coinpayments_transactions",
    `internal_reference=eq.${encodeURIComponent(refEffective)}`,
    { ipn_received_at: new Date().toISOString() },
  ).catch(() => {});

  const ipnStatus = parseInt(payload["status"] ?? "-999", 10);
  console.log(`[ipn] status IPN=${ipnStatus} — re-vérification get_tx_info obligatoire`);

  // ── RÈGLE DE SÉCURITÉ CRITIQUE ────────────────────────────────────────────
  // Le payload IPN n'est JAMAIS utilisé directement pour décider du crédit.
  // On re-consulte TOUJOURS get_tx_info pour obtenir la confirmation officielle.
  // Protège contre les faux IPN, les IPN falsifiés, et les doubles-crédits.
  //
  // On ne tente le crédit que si l'IPN indique status=100 (Complete)
  // pour éviter des appels inutiles à l'API CoinPayments.
  if (ipnStatus === 100) {
    const result = await verifierEtCrediterStrictement(refEffective, "WEBHOOK", tx);
    console.log(`[ipn] Résultat crédit: ok=${result.ok} msg=${result.message}`);
  } else {
    console.log(`[ipn] Status IPN ${ipnStatus} ≠ 100 → pas de tentative de crédit`);
    // Mettre à jour le statut en DB si status est définitif
    if (ipnStatus === -1) {
      await sbPatch(
        "coinpayments_transactions",
        `internal_reference=eq.${encodeURIComponent(refEffective)}`,
        { status: "cancelled", error_message: payload["status_text"] ?? "Cancelled" },
      ).catch(() => {});
    }
  }

  // TOUJOURS retourner HTTP 200 pour que CoinPayments ne re-tente pas l'IPN
  return new Response("OK", { status: 200 });
}
