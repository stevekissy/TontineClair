// ─────────────────────────────────────────────────────────────────────────────
// coinpayments-payment — Edge Function Supabase (Deno/TypeScript)
//
// Architecture sécurisée v5 — miroir de sycapay-payment.
//
// ⚠️  RÈGLES DE CRÉDIT :
//   - Crédit UNIQUEMENT après réception + validation IPN (status=100)
//   - IPN dédié TontineClair : coinpayments-ipn (per-transaction ipn_url)
//   - success_url / retour utilisateur NE CRÉDITE JAMAIS
//   - confirmer_et_crediter = appel serveur-side avec get_tx_info (8 étapes)
//
// ⚠️  IPN :
//   - Le compte CoinPayments conserve son IPN général SK PAY intact
//   - Chaque transaction TontineClair injecte ipn_url = coinpayments-ipn
//   - CoinPayments envoie l'IPN de cette transaction à coinpayments-ipn
//
// ⚠️  custom field :
//   - Format : TC-TYPE-<numCommande>   (ex: TC-COTISATION-TCP_ABC_xyz_1234567890)
//   - Parsé par coinpayments-ipn pour retrouver la transaction en DB
//
// Variables d'environnement (Supabase secrets) :
//   COINPAYMENTS_PUBLIC_KEY      — clé publique API
//   COINPAYMENTS_PRIVATE_KEY     — clé privée HMAC-SHA512
//   COINPAYMENTS_IPN_SECRET      — secret IPN (validé dans coinpayments-ipn)
//   SUPABASE_URL                 — auto-injecté
//   SUPABASE_SERVICE_ROLE_KEY    — auto-injecté
//
// Actions (POST JSON) :
//   creer_transaction     — create_transaction CP → checkout_url + txid
//   statut                — get_tx_info CP → lecture seule
//   confirmer_et_crediter — polling serveur + crédit strict (SEULE voie Flutter)
//   verifier_ref          — lecture seule DB
// ─────────────────────────────────────────────────────────────────────────────

// ── Env vars ──────────────────────────────────────────────────────────────────
const CP_PUBLIC_KEY  = Deno.env.get("COINPAYMENTS_PUBLIC_KEY")   ?? "";
const CP_PRIVATE_KEY = Deno.env.get("COINPAYMENTS_PRIVATE_KEY")  ?? "";
const SUPABASE_URL   = Deno.env.get("SUPABASE_URL")              ?? "";
const SERVICE_KEY    = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

// ── IPN dédié TontineClair ────────────────────────────────────────────────────
// Chaque transaction reçoit cette URL dans ipn_url — isole TontineClair de SK PAY
const TC_IPN_URL = `${SUPABASE_URL}/functions/v1/coinpayments-ipn`;

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
  if (statusCode === 100)                          return "confirmed";
  if (statusCode === 2)                            return "processing";
  if (statusCode >= 0 && statusCode < 100)         return "pending";
  if (statusCode === -1)                           return "cancelled";
  return "unknown";
}

// ── Custom field : format TC-TYPE-<numCommande> ───────────────────────────────
// Converti typeOperation en label majuscule lisible dans l'IPN
function typeOpToLabel(typeOp: string): string {
  const map: Record<string, string> = {
    cotisation:         "COTISATION",
    caisse:             "APPORT",
    penalite:           "PENALITE",
    remboursement_pret: "REMBOURSEMENT",
    pret_octroye:       "PRET",
  };
  return map[typeOp] ?? typeOp.toUpperCase().replace(/_/g, "-");
}

// Construit le champ custom : TC-TYPE-<numCommande>
// CoinPayments limite custom à 255 caractères
function buildCustom(typeOp: string, numcommande: string): string {
  const label = typeOpToLabel(typeOp);
  const raw   = `TC-${label}-${numcommande}`;
  return raw.slice(0, 255);
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
// HMAC-SHA512 — authentification CoinPayments API
// Auth : HMAC-SHA512(body_url_encoded, PRIVATE_KEY)
// Header : HMAC + X-Coinpayments-Key = PUBLIC_KEY
// ─────────────────────────────────────────────────────────────────────────────

async function hmacSha512(message: string, secret: string): Promise<string> {
  const encoder   = new TextEncoder();
  const keyData   = encoder.encode(secret);
  const msgData   = encoder.encode(message);
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

// Appel générique API CoinPayments v1
async function cpApiCall(
  cmd: string,
  params: Record<string, string | number>,
): Promise<Record<string, unknown>> {
  if (!CP_PUBLIC_KEY || !CP_PRIVATE_KEY) {
    throw new Error("Clés CoinPayments non configurées (COINPAYMENTS_PUBLIC_KEY / COINPAYMENTS_PRIVATE_KEY)");
  }

  const allParams: Record<string, string> = {
    version: "1",
    cmd,
    key:     CP_PUBLIC_KEY,
    format:  "json",
    ...Object.fromEntries(
      Object.entries(params).map(([k, v]) => [k, String(v)])
    ),
  };

  // CoinPayments API v1 : body application/x-www-form-urlencoded
  const bodyStr = Object.entries(allParams)
    .map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`)
    .join("&");

  const hmac = await hmacSha512(bodyStr, CP_PRIVATE_KEY);

  const res = await fetch(CP_API, {
    method:  "POST",
    headers: {
      "Content-Type":       "application/x-www-form-urlencoded",
      "X-Coinpayments-Key": CP_PUBLIC_KEY,
      "HMAC":               hmac,
    },
    body: bodyStr,
  });

  if (!res.ok) {
    throw new Error(`CoinPayments API HTTP ${res.status}`);
  }

  const data = await res.json() as Record<string, unknown>;

  // CoinPayments retourne { error: "ok", result: {...} } en succès
  // ou { error: "message d'erreur" } en échec
  if (data["error"] !== "ok") {
    throw new Error(`CoinPayments API: ${data["error"]}`);
  }

  return (data["result"] as Record<string, unknown>) ?? {};
}

// ── create_transaction ────────────────────────────────────────────────────────

async function cpCreateTransaction(params: {
  amount:       number;   // montant XOF (CoinPayments convertit en crypto via taux)
  currency1:    string;   // "XOF"
  currency2:    string;   // "USDT.TRC20" | "BTC" | "ETH" | "LTC" | "USDT.ERC20"
  item_name:    string;
  item_number:  string;   // = numCommande
  custom:       string;   // "TC-TYPE-<numCommande>"
  ipn_url:      string;   // = TC_IPN_URL (coinpayments-ipn)
  buyer_email?: string;
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
    ipn_url:      params.ipn_url,       // ← IPN dédié TontineClair per-transaction
    ...(params.success_url ? { success_url: params.success_url } : {}),
    ...(params.cancel_url  ? { cancel_url:  params.cancel_url  } : {}),
  });

  return {
    txn_id:       result["txn_id"]       as string,
    checkout_url: result["checkout_url"] as string,
    status_url:   result["status_url"]   as string,
    timeout:      (result["timeout"]      as number) ?? 7200,
    amount:       (result["amount"]       as string) ?? "0",
    amountf:      parseFloat((result["amountf"] as string) ?? "0"),
  };
}

// ── get_tx_info ───────────────────────────────────────────────────────────────

async function cpGetTxInfo(txid: string): Promise<{
  status:          number;
  status_text:     string;
  amount:          string;
  amountf:         number;
  coin:            string;
  confirms_needed: number;
  recv_confirms:   number;
  recv_amount:     string;
  recv_amountf:    number;
}> {
  const result = await cpApiCall("get_tx_info", { txid });
  return {
    status:           (result["status"]          as number)  ?? -1,
    status_text:      (result["status_text"]      as string) ?? "",
    amount:           (result["amount"]           as string) ?? "0",
    amountf:          parseFloat((result["amountf"]   as string) ?? "0"),
    coin:             (result["coin"]             as string) ?? "",
    confirms_needed:  (result["confirms_needed"]  as number) ?? 0,
    recv_confirms:    (result["recv_confirms"]    as number) ?? 0,
    recv_amount:      (result["recv_amount"]      as string) ?? "0",
    recv_amountf:     parseFloat((result["recv_amountf"] as string) ?? "0"),
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
  }).catch(e => console.error("[audit] Échec écriture:", e));
}

// ─────────────────────────────────────────────────────────────────────────────
// Messages lisibles par type d'opération
// ─────────────────────────────────────────────────────────────────────────────

function messageSucces(typeOp: string): string {
  const map: Record<string, string> = {
    cotisation:         "Cotisation enregistrée avec succès.",
    caisse:             "Apport caisse enregistré avec succès.",
    penalite:           "Pénalité réglée avec succès.",
    remboursement_pret: "Remboursement enregistré avec succès.",
    pret_octroye:       "Décaissement prêt enregistré avec succès.",
  };
  return map[typeOp] ?? "Paiement crypto enregistré avec succès.";
}

// ─────────────────────────────────────────────────────────────────────────────
// Crédit côté serveur — réutilise les RPCs SycaPay avec p_operateur='coinpayments'
// ─────────────────────────────────────────────────────────────────────────────

async function crediterCoteServeur(tx: Record<string, unknown>): Promise<void> {
  const typeOp      = (tx["type_operation"]          as string) ?? "cotisation";
  const code        = ((tx["tontine_code"]            as string) ?? "").toUpperCase();
  const amount      = (tx["amount"]                  as number) ?? 0;
  const txid        = (tx["provider_transaction_id"] as string) ?? "";
  const numcmd      = (tx["internal_reference"]      as string) ?? "";
  const membreId    = (tx["membre_id"]               as string) ?? null;
  const pretId      = (tx["pret_id"]                 as string) ?? null;
  const description = (tx["description"]             as string) ?? null;
  const now         = new Date().toISOString();

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
// verifierEtCrediterStrictement — 8 étapes (miroir SycaPay v5)
//
// RÈGLE ABSOLUE : seule porte d'entrée pour tout crédit CoinPayments.
// Appelée par confirmer_et_crediter ET par coinpayments-ipn.
// ─────────────────────────────────────────────────────────────────────────────

async function verifierEtCrediterStrictement(
  numcommande: string,
  source: "POLLING" | "IPN",
  txRow: Record<string, unknown>,
): Promise<{ ok: boolean; message: string }> {
  console.log(`[verifier] Début ${numcommande} (source=${source})`);

  try {

    // ── Étape 1 : Transaction en DB ───────────────────────────────────────────
    const rows = await sbSelect(
      "coinpayments_transactions",
      `internal_reference=eq.${encodeURIComponent(numcommande)}&select=*`,
    );
    if (rows.length === 0) {
      const msg = `Transaction introuvable: ${numcommande}`;
      await ecrireAudit({ numcommande, nouveauStatut: "error", source, erreur: msg });
      return { ok: false, message: msg };
    }
    const dbTx = rows[0];

    // ── Étape 2 : Idempotence ─────────────────────────────────────────────────
    if (dbTx["status"] === "credited") {
      console.log(`[verifier] ${numcommande} déjà crédité → idempotent`);
      return { ok: true, message: "Déjà crédité" };
    }

    // ── Étape 3 : Statut compatible ───────────────────────────────────────────
    const currentStatus = dbTx["status"] as string;
    if (currentStatus === "failed" || currentStatus === "cancelled") {
      const msg = `Statut ${currentStatus} — crédit refusé`;
      await ecrireAudit({ numcommande, ancienStatut: currentStatus, nouveauStatut: "error", source, erreur: msg });
      return { ok: false, message: msg };
    }

    // ── Étape 4 : Re-vérification get_tx_info (JAMAIS créditer sans ça) ───────
    const txid = (dbTx["provider_transaction_id"] ?? txRow["provider_transaction_id"]) as string | undefined;
    if (!txid) {
      const msg = `txid absent pour ${numcommande}`;
      await ecrireAudit({ numcommande, nouveauStatut: "error", source, erreur: msg });
      return { ok: false, message: "TXID CoinPayments introuvable" };
    }

    let cpInfo: Awaited<ReturnType<typeof cpGetTxInfo>>;
    try {
      cpInfo = await cpGetTxInfo(txid);
    } catch (e) {
      const msg = `Erreur get_tx_info ${txid}: ${e}`;
      await ecrireAudit({ numcommande, nouveauStatut: "error", source, erreur: msg });
      return { ok: false, message: "Impossible de vérifier via CoinPayments API" };
    }

    const cpStatus = normaliserStatutCP(cpInfo.status);
    console.log(`[verifier] get_tx_info → status=${cpInfo.status} (${cpStatus}) txid=${txid}`);

    await ecrireAudit({
      numcommande,
      ancienStatut: currentStatus,
      nouveauStatut: `api_check:${cpStatus}`,
      source,
      reponseApi: { status: cpInfo.status, status_text: cpInfo.status_text, coin: cpInfo.coin },
    });

    // ── Étape 5 : status doit être 100 (Complete) ─────────────────────────────
    if (cpInfo.status !== 100) {
      if (cpInfo.status === -1) {
        await sbPatch(
          "coinpayments_transactions",
          `internal_reference=eq.${encodeURIComponent(numcommande)}`,
          { status: "cancelled", error_message: cpInfo.status_text },
        ).catch(() => {});
      }
      return { ok: false, message: `Paiement pas encore confirmé (status=${cpInfo.status}: ${cpInfo.status_text})` };
    }

    // ── Étape 6 : Vérification montant ────────────────────────────────────────
    const dbAmount = (dbTx["amount"] as number) ?? 0;
    if (dbAmount <= 0) {
      const msg = `Montant DB invalide: ${dbAmount}`;
      await ecrireAudit({ numcommande, nouveauStatut: "error", source, erreur: msg });
      return { ok: false, message: msg };
    }

    // ── Étape 7 : Marquer confirmed en DB ─────────────────────────────────────
    const now = new Date().toISOString();
    await sbPatch(
      "coinpayments_transactions",
      `internal_reference=eq.${encodeURIComponent(numcommande)}`,
      { status: "confirmed", confirmed_at: now, provider_transaction_id: txid },
    );

    // ── Étape 8 : Crédit via RPC Supabase (verrou FOR UPDATE) ─────────────────
    const mergedTx = { ...txRow, ...dbTx };
    try {
      await crediterCoteServeur(mergedTx);
    } catch (e: unknown) {
      const msg = e instanceof Error ? e.message : String(e);
      console.error(`[verifier] Erreur RPC crédit ${numcommande}:`, msg);
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
      reponseApi: { txid, amount_xof: dbAmount, coin: cpInfo.coin },
    });

    console.log(`[verifier] ✅ ${numcommande} crédité OK (txid=${txid}, ${cpInfo.coin})`);
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
    // Appelle create_transaction CoinPayments.
    // ipn_url = TC_IPN_URL (coinpayments-ipn, dédié TontineClair per-transaction)
    // custom  = TC-TYPE-<numCommande>
    // Persiste en PENDING — NE CRÉDITE JAMAIS ici.
    // ══════════════════════════════════════════════════════════════════════════
    if (action === "creer_transaction") {
      const montant     = (body["montant"] as number) ?? (body["montant_xof"] as number);
      const numcommande = body["numcommande"]    as string;
      const currency2   = (body["currency2"]     as string) ?? "USDT.TRC20";
      const tontineCode = (body["tontine_code"]  as string) ?? "";
      const typeOp      = (body["type_operation"] as string) ?? "cotisation";
      const membreId    = body["membre_id"]      as string | undefined;
      const membreNom   = (body["membre_nom"]    as string) ?? "";
      const pretId      = (body["pret_id"]       as string) ?? null;
      const description = (body["description"]   as string)
                          ?? `TontineClair - ${typeOpToLabel(typeOp)}`;

      if (!montant || !numcommande) {
        return json({ erreur: true, message: "montant et numcommande requis" }, 400);
      }

      // Idempotence : transaction existante
      if (tontineCode) {
        const existing = await sbSelect(
          "coinpayments_transactions",
          `internal_reference=eq.${encodeURIComponent(numcommande)}&select=id,status,provider_transaction_id,checkout_url`,
        );
        if (existing.length > 0) {
          const tx = existing[0];
          if (tx["status"] === "credited" || tx["status"] === "confirmed") {
            return json({
              erreur:      false,
              idempotent:  true,
              txid:        tx["provider_transaction_id"],
              checkoutUrl: tx["checkout_url"],
              status:      tx["status"],
              statusNorm:  "confirmed",
              numcommande,
            });
          }
          // Pending avec checkout_url → renvoyer directement
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

      // custom = TC-TYPE-<numCommande> (retrouvé par coinpayments-ipn pour matcher la transaction)
      const customRef = buildCustom(typeOp, numcommande);

      // Appel create_transaction — ipn_url pointe vers coinpayments-ipn (TontineClair seulement)
      let cpResult: Awaited<ReturnType<typeof cpCreateTransaction>>;
      try {
        cpResult = await cpCreateTransaction({
          amount:      montant,
          currency1:   "XOF",
          currency2,
          item_name:   description,
          item_number: numcommande,
          custom:      customRef,    // TC-COTISATION-TCP_ABC_xyz_123
          ipn_url:     TC_IPN_URL,   // https://...supabase.co/functions/v1/coinpayments-ipn
        });
      } catch (e: unknown) {
        const msg = e instanceof Error ? e.message : String(e);
        console.error(`[creer] Erreur create_transaction:`, msg);
        return json({ erreur: true, message: `Erreur CoinPayments: ${msg}` }, 502);
      }

      console.log(`[creer] tx créée txid=${cpResult.txn_id} ref=${numcommande} custom="${customRef}"`);

      // Persister en PENDING
      if (tontineCode) {
        await sbFetch("/rest/v1/coinpayments_transactions", "POST", {
          tontine_code:            tontineCode,
          type_operation:          typeOp,
          internal_reference:      numcommande,
          provider_transaction_id: cpResult.txn_id,
          checkout_url:            cpResult.checkout_url,
          currency2,
          custom_ref:              customRef,
          amount:                  montant,
          currency:                "XOF",
          status:                  "pending",
          membre_id:               membreId ?? null,
          membre_nom:              membreNom || null,
          pret_id:                 pretId || null,
          description,
          cp_timeout:              cpResult.timeout,
          created_at:              new Date().toISOString(),
        }).catch(async (e: Error) => {
          if (e.message.includes("23505") || e.message.includes("duplicate")) {
            await sbPatch(
              "coinpayments_transactions",
              `internal_reference=eq.${encodeURIComponent(numcommande)}`,
              {
                provider_transaction_id: cpResult.txn_id,
                checkout_url:            cpResult.checkout_url,
                custom_ref:              customRef,
              },
            ).catch(() => {});
          } else {
            console.error("[creer] persistance DB:", e.message);
          }
        });

        await ecrireAudit({
          numcommande,
          ancienStatut:  "inexistant",
          nouveauStatut: "pending",
          source:        "CREATE",
          reponseApi:    { txn_id: cpResult.txn_id, currency2, custom: customRef, ipn_url: TC_IPN_URL },
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
        customRef,
        status:      "pending",
        statusNorm:  "pending",
        numcommande,
      });
    }

    // ══════════════════════════════════════════════════════════════════════════
    // ACTION : statut
    // Lecture seule — consulte DB + get_tx_info.
    // NE CRÉDITE JAMAIS — retourne le statut pour l'affichage Flutter.
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

      // 2. Déjà crédité
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

      // 3. Annulé/échoué en DB
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

      // 4. get_tx_info CoinPayments
      const effectiveTxid = txid
        ?? (dbTx ? (dbTx["provider_transaction_id"] as string | undefined) : undefined);

      if (!effectiveTxid) {
        return json({ erreur: true, message: "txid introuvable" }, 400);
      }

      let cpInfo: Awaited<ReturnType<typeof cpGetTxInfo>>;
      try {
        cpInfo = await cpGetTxInfo(effectiveTxid);
      } catch (e: unknown) {
        const msg = e instanceof Error ? e.message : String(e);
        // En cas d'erreur API, retourner le statut DB si disponible
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

      // 5. Mise à jour DB (statut seulement — pas de crédit)
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
        erreur:         false,
        ok:             norm === "confirmed",
        statusCode:     cpInfo.status,
        statusNorm:     norm,
        statusText:     cpInfo.status_text,
        coin:           cpInfo.coin,
        recvConfirms:   cpInfo.recv_confirms,
        confirmsNeeded: cpInfo.confirms_needed,
        numcommande,
        txid:           effectiveTxid,
        // Signal Flutter : relancer confirmer_et_crediter si confirmé
        needsCredit:    norm === "confirmed",
      });
    }

    // ══════════════════════════════════════════════════════════════════════════
    // ACTION : confirmer_et_crediter
    // SEULE voie de crédit depuis Flutter.
    // Appelle verifierEtCrediterStrictement (8 étapes).
    // NE JAMAIS APPELER depuis success_url ou retour utilisateur.
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

      // Récupérer / créer la transaction en DB
      let rows = await sbSelect(
        "coinpayments_transactions",
        `internal_reference=eq.${encodeURIComponent(numcommande)}&select=*`,
      );

      // Ligne absente (cas rare : polling avant IPN) → créer minimale
      if (rows.length === 0 && txid) {
        await sbFetch("/rest/v1/coinpayments_transactions", "POST", {
          tontine_code:            tontineCode,
          type_operation:          typeOp,
          internal_reference:      numcommande,
          provider_transaction_id: txid,
          custom_ref:              buildCustom(typeOp, numcommande),
          amount:                  (body["montant"] as number) ?? (body["montant_xof"] as number) ?? 0,
          currency:                "XOF",
          status:                  "pending",
          membre_id:               (body["membre_id"]  as string) ?? null,
          membre_nom:              membreNom || null,
          pret_id:                 (body["pret_id"]    as string) ?? null,
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

      const baseRow  = rows.length > 0 ? rows[0] : {};
      const enriched = {
        ...baseRow,
        tontine_code:   tontineCode,
        type_operation: typeOp,
        ...(txid             ? { provider_transaction_id: txid }                   : {}),
        ...(membreNom        ? { membre_nom:  membreNom }                          : {}),
        ...(body["pret_id"]   ? { pret_id:    body["pret_id"]   as string }        : {}),
        ...(body["membre_id"] ? { membre_id:  body["membre_id"] as string }        : {}),
        ...(body["montant"] || body["montant_xof"]
          ? { amount: (body["montant"] ?? body["montant_xof"]) as number }
          : {}),
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
    // ACTION : verifier_ref — lecture seule DB
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
        trouve:        true,
        status:        tx["status"],
        statusNorm:    (tx["status"] === "credited" || tx["status"] === "confirmed")
                       ? "confirmed" : (tx["status"] as string),
        amount:        tx["amount"],
        currency2:     tx["currency2"],
        confirmedAt:   tx["confirmed_at"],
        creditedAt:    tx["credited_at"],
        txid:          tx["provider_transaction_id"],
        membreId:      tx["membre_id"],
        typeOperation: tx["type_operation"],
        ok:            tx["status"] === "credited",
      });
    }

    // Bloquer tentative de crédit manuel
    if (action === "marquer_credite") {
      console.warn("[SÉCURITÉ] Action marquer_credite bloquée");
      return json({
        erreur:  true,
        message: "Action non autorisée.",
      }, 403);
    }

    return json({ erreur: true, message: `Action inconnue: ${action}` }, 400);

  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    console.error("[coinpayments-payment] Erreur critique:", msg);
    return json({ erreur: true, code: -504, message: msg }, 500);
  }
});
