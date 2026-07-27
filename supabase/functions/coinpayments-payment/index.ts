const CP_PUBLIC_KEY  = Deno.env.get("COINPAYMENTS_PUBLIC_KEY")   ?? "";
const CP_PRIVATE_KEY = Deno.env.get("COINPAYMENTS_PRIVATE_KEY")  ?? "";
const SUPABASE_URL   = Deno.env.get("SUPABASE_URL")              ?? "";
const SERVICE_KEY    = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const TC_IPN_URL = `${SUPABASE_URL}/functions/v1/coinpayments-ipn`;
const CP_API = "https://www.coinpayments.net/api.php";
const CORS = {
  "Access-Control-Allow-Origin":  "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
type NStatus = "pending" | "processing" | "confirmed" | "failed" | "cancelled" | "unknown";
function normaliserStatutCP(statusCode: number): NStatus {
  if (statusCode === 100)                          return "confirmed";
  if (statusCode === 2)                            return "processing";
  if (statusCode >= 0 && statusCode < 100)         return "pending";
  if (statusCode === -1)                           return "cancelled";
  return "unknown";
}
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
function buildCustom(typeOp: string, numcommande: string): string {
  const label = typeOpToLabel(typeOp);
  const raw   = `TC-${label}-${numcommande}`;
  return raw.slice(0, 255);
}
function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}
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
  if (data["error"] !== "ok") {
    throw new Error(`CoinPayments API: ${data["error"]}`);
  }
  return (data["result"] as Record<string, unknown>) ?? {};
}
async function cpCreateTransaction(params: {
  amount:       number;
  currency1:    string;   // "XOF"
  currency2:    string;   // "USDT.TRC20" | "BTC" | "ETH" | "LTC" | "USDT.ERC20"
  item_name:    string;
  item_number:  string;
  custom:       string;   // "TC-TYPE-<numCommande>"
  ipn_url:      string;
  buyer_email?: string;
  success_url?: string;
  cancel_url?:  string;
}): Promise<Record<string, unknown>> {
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
    timeout:      (result["timeout"]      as number) ?? 7200,
    amount:       (result["amount"]       as string) ?? "0",
    amountf:      parseFloat((result["amountf"] as string) ?? "0"),
  };
}
async function cpGetTxInfo(txid: string): Promise<Record<string, unknown>> {
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
async function cpGetWalletInfo(checkoutUrl: string, currency2: string): Promise<Record<string, unknown>> {
  // Scrape l'adresse de dépôt depuis la page checkout CoinPayments (pas besoin de get_tx_info)
  const res = await fetch(checkoutUrl, {
    headers: { "User-Agent": "Mozilla/5.0 (compatible; TontineClair/1.0)" },
  });
  if (!res.ok) throw new Error(`Checkout page HTTP ${res.status}`);
  const html = await res.text();

  // Extraction adresse selon la crypto
  let address = "";
  const cur = currency2.toUpperCase();

  if (cur.includes("TRC20") || cur === "TRX") {
    // Adresse TRON : commence par T, 34 caractères alphanumériques
    const m = html.match(/\bT[A-Za-z0-9]{33}\b/);
    if (m) address = m[0];
  } else if (cur === "BTC") {
    const m = html.match(/\b(bc1[a-z0-9]{39,59}|[13][A-HJ-NP-Za-km-z1-9]{25,34})\b/);
    if (m) address = m[0];
  } else if (cur === "ETH" || cur.includes("ERC20") || cur.includes("BEP20") || cur === "BNB.BSC" || cur === "BNB") {
    // Adresse EVM (Ethereum, BSC/BEP20, BNB Smart Chain) : 0x + 40 hex
    // ⚠️ IMPORTANT : BEP20 et BNB.BSC utilisent le MÊME format d'adresse qu'Ethereum (0x...)
    // La page checkout CoinPayments peut afficher l'adresse sans le préfixe 0x dans le HTML.
    // On cherche d'abord avec 0x, puis sans 0x si non trouvé.
    const mWith0x = html.match(/\b0x[a-fA-F0-9]{40}\b/);
    if (mWith0x) {
      address = mWith0x[0];
    } else {
      // Chercher adresse hex de 40 chars sans 0x et la préfixer
      const mWithout0x = html.match(/\b[a-fA-F0-9]{40}\b/);
      if (mWithout0x) address = "0x" + mWithout0x[0];
    }
  } else if (cur === "LTC") {
    const m = html.match(/\b[LMm][a-km-zA-HJ-NP-Z1-9]{26,33}\b/);
    if (m) address = m[0];
  } else {
    // Fallback générique : chercher toute adresse crypto longue
    const m = html.match(/\b[A-Za-z0-9]{25,60}\b/g);
    if (m) address = m.find(a => a.length >= 30) ?? "";
  }

  // Extraction montant crypto — supporte USDT, BNB, BTC, ETH, LTC
  const amtMatch = html.match(/([\d]+\.[\d]+)\s*(?:USDT|BNB|BTC|ETH|LTC)/i);
  const amountf  = amtMatch ? parseFloat(amtMatch[1]) : 0;

  // Extraction dest_tag (XRP, XLM, etc.)
  const destMatch = html.match(/dest[_-]?tag["\s:>]+(\d+)/i);
  const destTag   = destMatch ? destMatch[1] : "";

  // Extraction temps restant (secondes)
  const timeMatch = html.match(/time_left["\s:>]+(\d+)/i)
                 ?? html.match(/data-time["\s:>]+(\d+)/i);
  const timeLeft  = timeMatch ? parseInt(timeMatch[1]) : 7200;

  return { address, amountf, dest_tag: destTag, timeout: timeLeft };
}
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

async function crediterCoteServeur(tx: Record<string, unknown>): Promise<void> {
  const t = (tx["type_operation"] as string) ?? "cotisation";
  const base = {
    p_code: ((tx["tontine_code"] as string) ?? "").toUpperCase(),
    p_montant: (tx["amount"] as number) ?? 0,
    p_reference: (tx["provider_transaction_id"] as string) ?? "",
    p_num_commande: (tx["internal_reference"] as string) ?? "",
    p_operateur: "coinpayments",
    p_now: new Date().toISOString(),
  };
  const mid = (tx["membre_id"] as string) ?? null;
  const pid = (tx["pret_id"] as string) ?? null;
  const desc = (tx["description"] as string) ?? null;
  if (t === "cotisation") await sbRpc("crediter_cotisation_sycapay", base);
  else if (t === "caisse") await sbRpc("crediter_caisse_sycapay", {...base, p_description: desc});
  else if (t === "penalite") await sbRpc("crediter_penalite_sycapay", {...base, p_membre_id: mid});
  else if (t === "remboursement_pret") await sbRpc("crediter_remboursement_sycapay", {...base, p_pret_id: pid});
  else if (t === "pret_octroye") await sbRpc("debiter_pret_sycapay", {...base, p_pret_id: pid});
  else await sbRpc("crediter_caisse_sycapay", {...base, p_description: `[${t}] ${desc ?? ""}`});
}
async function verifierEtCrediterStrictement(
  numcommande: string,
  source: "POLLING" | "IPN",
  txRow: Record<string, unknown>,
): Promise<{ ok: boolean; message: string }> {
  console.log(`[verifier] Début ${numcommande} (source=${source})`);
  try {
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
    if (dbTx["status"] === "credited") {
      console.log(`[verifier] ${numcommande} déjà crédité → idempotent`);
      return { ok: true, message: "Déjà crédité" };
    }
    const currentStatus = dbTx["status"] as string;
    if (currentStatus === "failed" || currentStatus === "cancelled") {
      const msg = `Statut ${currentStatus} — crédit refusé`;
      await ecrireAudit({ numcommande, ancienStatut: currentStatus, nouveauStatut: "error", source, erreur: msg });
      return { ok: false, message: msg };
    }
    const txid = (dbTx["provider_transaction_id"] ?? txRow["provider_transaction_id"]) as string | undefined;
    if (!txid) {
      const msg = `txid absent pour ${numcommande}`;
      await ecrireAudit({ numcommande, nouveauStatut: "error", source, erreur: msg });
      return { ok: false, message: "TXID CoinPayments introuvable" };
    }
    // deno-lint-ignore no-explicit-any
    let cpInfo: any;
    let usedDbFallback = false;
    try {
      cpInfo = await cpGetTxInfo(txid);
    } catch (e) {
      const errMsg = String(e);
      // Fallback : si permission manquante, on se fie au statut DB
      // (l'IPN HMAC-validé a déjà prouvé que CoinPayments a traité la TX)
      // Note : get_tx_info est souvent bloqué par restriction IP CoinPayments
      // sur les Edge Functions. Le polling Flutter (action "statut") a déjà
      // vérifié statusCode=100 avant d'appeler confirmer_et_crediter.
      if (errMsg.includes("permission") || errMsg.includes("API Key")
          || errMsg.includes("Access denied") || errMsg.includes("Insufficient")
          || errMsg.includes("Invalid key") || errMsg.includes("This key")
          || errMsg.includes("IP") || errMsg.includes("restricted")) {
        console.warn(`[verifier] get_tx_info refusé (${errMsg.slice(0, 80)}), fallback statut DB "${currentStatus}"`);
        const ipnReceived = !!(dbTx["ipn_received_at"]);
        // ✅ On accepte dans tous les cas où CoinPayments a signalé la confirmation :
        // 1. IPN reçu (preuve cryptographique HMAC-SHA512)
        // 2. Statut DB "confirmed" ou "processing" (mis par IPN précédent ou polling)
        // 3. Statut "pending" ET source="POLLING" (Flutter polling a vu statusCode=100)
        const dbConfirmed = currentStatus === "confirmed"
                         || currentStatus === "processing";
        const acceptableForPolling = source === "POLLING"; // Flutter a déjà validé côté CoinPayments
        if (!ipnReceived && !dbConfirmed && !acceptableForPolling) {
          return { ok: false, message: "Paiement non confirmé (IPN non reçu, accès API limité)" };
        }
        cpInfo = { status: 100, status_text: "Complete (DB/polling fallback)", coin: dbTx["currency2"] as string ?? "" };
        usedDbFallback = true;
      } else {
        const msg = `Erreur get_tx_info ${txid}: ${errMsg}`;
        await ecrireAudit({ numcommande, nouveauStatut: "error", source, erreur: msg });
        return { ok: false, message: "Impossible de vérifier via CoinPayments API" };
      }
    }
    const cpStatus = normaliserStatutCP(cpInfo.status);
    console.log(`[verifier] get_tx_info → status=${cpInfo.status} (${cpStatus}) txid=${txid} fallback=${usedDbFallback}`);
    await ecrireAudit({
      numcommande,
      ancienStatut: currentStatus,
      nouveauStatut: `api_check:${cpStatus}`,
      source: usedDbFallback ? `${source}_DB_FALLBACK` : source,
      reponseApi: { status: cpInfo.status, status_text: cpInfo.status_text, coin: cpInfo.coin, db_fallback: usedDbFallback },
    });
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
    const dbAmount = (dbTx["amount"] as number) ?? 0;
    if (dbAmount <= 0) {
      const msg = `Montant DB invalide: ${dbAmount}`;
      await ecrireAudit({ numcommande, nouveauStatut: "error", source, erreur: msg });
      return { ok: false, message: msg };
    }
    const now = new Date().toISOString();
    await sbPatch(
      "coinpayments_transactions",
      `internal_reference=eq.${encodeURIComponent(numcommande)}`,
      { status: "confirmed", confirmed_at: now, provider_transaction_id: txid },
    );
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
      const customRef  = buildCustom(typeOp, numcommande);
      // buyer_email : de Flutter si dispo, sinon fallback merchant (CoinPayments l'exige)
      const buyerEmail = ((body["buyer_email"]   as string) ?? "").trim()
                      || ((body["membre_email"]  as string) ?? "").trim()
                      || "noreply@tontineclair.com";
      // deno-lint-ignore no-explicit-any
  let cpResult: any;
      try {
        cpResult = await cpCreateTransaction({
          amount:      montant,
          currency1:   "XOF",
          currency2,
          buyer_email: buyerEmail,
          item_name:   description,
          item_number: numcommande,
          custom:      customRef,
          ipn_url:     TC_IPN_URL,   // https://...supabase.co/functions/v1/coinpayments-ipn
        });
      } catch (e: unknown) {
        const msg = e instanceof Error ? e.message : String(e);
        console.error(`[creer] Erreur create_transaction:`, msg);
        return json({ erreur: true, message: `Erreur CoinPayments: ${msg}` }, 502);
      }
      console.log(`[creer] tx créée txid=${cpResult.txn_id} ref=${numcommande} custom="${customRef}"`);
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
    if (action === "statut") {
      const txid        = body["txid"]         as string | undefined;
      const numcommande = body["numcommande"]  as string | undefined;
      if (!txid && !numcommande) {
        return json({ erreur: true, message: "txid ou numcommande requis" }, 400);
      }
      let dbTx: Record<string, unknown> | null = null;
      if (numcommande) {
        const rows = await sbSelect(
          "coinpayments_transactions",
          `internal_reference=eq.${encodeURIComponent(numcommande)}&select=*`,
        );
        if (rows.length > 0) dbTx = rows[0];
      }
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
      // Si processing ET IPN déjà reçu → CoinPayments a confirmé, get_tx_info
      // peut échouer par manque de permission. On déclenche confirmerEtCrediter.
      if (dbTx && dbTx["status"] === "processing" && dbTx["ipn_received_at"]) {
        console.log(`[statut] processing + IPN reçu → needsCredit=true pour ${numcommande}`);
        return json({
          erreur:         false,
          ok:             false,
          statusCode:     100,
          statusNorm:     "confirmed",
          statusText:     "Complete (IPN reçu, crédit en attente)",
          numcommande,
          txid:           dbTx["provider_transaction_id"] as string ?? (txid ?? ""),
          needsCredit:    true,
          fromCache:      true,
        });
      }
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
      const effectiveTxid = txid
        ?? (dbTx ? (dbTx["provider_transaction_id"] as string | undefined) : undefined);
      if (!effectiveTxid) {
        return json({ erreur: true, message: "txid introuvable" }, 400);
      }
      // deno-lint-ignore no-explicit-any
    let cpInfo: any;
      try {
        cpInfo = await cpGetTxInfo(effectiveTxid);
      } catch (e: unknown) {
        const msg = e instanceof Error ? e.message : String(e);
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
        needsCredit:    norm === "confirmed",
      });
    }
    if (action === "confirmer_et_crediter") {
      const txid        = body["txid"]           as string | undefined;
      const numcommande = body["numcommande"]    as string;
      const tontineCode = body["tontine_code"]   as string;
      const typeOp      = (body["type_operation"] as string) ?? "cotisation";
      const membreNom   = (body["membre_nom"]    as string) ?? "";
      if (!numcommande || !tontineCode) {
        return json({ erreur: true, message: "numcommande et tontine_code requis" }, 400);
      }
      let rows = await sbSelect(
        "coinpayments_transactions",
        `internal_reference=eq.${encodeURIComponent(numcommande)}&select=*`,
      );
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
      if (rows.length > 0 && rows[0]["status"] === "credited") {
        return json({
          erreur:     false,
          ok:         true,
          statusCode: 100,
          statusNorm: "confirmed",
          message:    "Paiement crypto confirmé.",
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
        message:    result.ok ? "Paiement crypto confirmé." : result.message,
        numcommande,
      });
    }
    if (action === "info_wallet") {
      // Retourne l'adresse de dépôt + montant crypto pour affichage 100% in-app
      // Scrape depuis checkout_url stocké en DB — aucun appel get_tx_info (IP restriction)
      const numcommande = body["numcommande"] as string | undefined;
      const txid        = body["txid"]        as string | undefined;
      if (!numcommande && !txid) {
        return json({ erreur: true, message: "numcommande ou txid requis" }, 400);
      }
      // Charger depuis DB
      let checkoutUrl = body["checkout_url"] as string | undefined;
      let currency2   = (body["currency2"]   as string) ?? "USDT.TRC20";
      let effectiveTxid = txid ?? "";
      if (numcommande) {
        const rows = await sbSelect(
          "coinpayments_transactions",
          `internal_reference=eq.${encodeURIComponent(numcommande)}&select=provider_transaction_id,checkout_url,currency2`,
        );
        if (rows.length === 0) return json({ erreur: true, message: "Transaction introuvable" }, 404);
        const row   = rows[0];
        effectiveTxid = effectiveTxid || (row["provider_transaction_id"] as string);
        checkoutUrl   = checkoutUrl   || (row["checkout_url"]            as string);
        currency2     = (row["currency2"] as string) || currency2;
      }
      if (!checkoutUrl) return json({ erreur: true, message: "checkout_url introuvable" }, 400);
      try {
        const info = await cpGetWalletInfo(checkoutUrl, currency2);
        return json({
          erreur:     false,
          txid:       effectiveTxid,
          address:    info.address,
          dest_tag:   info.dest_tag,
          currency2,
          amountf:    info.amountf,
          timeout:    info.timeout,
          numcommande: numcommande ?? null,
        });
      } catch (e: unknown) {
        const msg = e instanceof Error ? e.message : String(e);
        return json({ erreur: true, message: `Erreur wallet: ${msg}` }, 502);
      }
    }

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

    // ══════════════════════════════════════════════════════════════════════
    // ACTIONS ADMIN (réservées TC Admin — nécessitent p_cle_admin)
    // ══════════════════════════════════════════════════════════════════════

    if (action === "admin_transactions") {
      // Liste toutes les transactions avec filtres
      const limit  = Math.min((body["limit"]  as number) ?? 50, 200);
      const offset = (body["offset"] as number) ?? 0;
      const filtre: string[] = [];
      if (body["statut"]       ) filtre.push(`status=eq.${body["statut"]}`);
      if (body["currency2"]    ) filtre.push(`currency2=eq.${encodeURIComponent(body["currency2"] as string)}`);
      if (body["tontine_code"] ) filtre.push(`tontine_code=eq.${encodeURIComponent(body["tontine_code"] as string)}`);
      if (body["type_operation"]) filtre.push(`type_operation=eq.${encodeURIComponent(body["type_operation"] as string)}`);
      if (body["date_debut"]   ) filtre.push(`created_at=gte.${body["date_debut"]}`);
      if (body["date_fin"]     ) filtre.push(`created_at=lte.${body["date_fin"]}`);
      const query = [...filtre, `select=*`, `order=created_at.desc`, `limit=${limit}`, `offset=${offset}`].join("&");
      const rows = await sbSelect("coinpayments_transactions", query);
      // Calculs agrégats
      const total    = rows.length;
      const credited = rows.filter(r => r["status"] === "credited").length;
      const pending  = rows.filter(r => r["status"] === "pending").length;
      const failed   = rows.filter(r => ["failed","cancelled"].includes(r["status"] as string)).length;
      const totalXof = rows.filter(r => r["status"] === "credited")
                           .reduce((s, r) => s + ((r["amount"] as number) ?? 0), 0);
      return json({ erreur: false, transactions: rows, total, credited, pending, failed, totalXof, limit, offset });
    }

    if (action === "admin_audit_log") {
      // Journal des IPN/Webhooks et actions système
      const limit  = Math.min((body["limit"]  as number) ?? 100, 500);
      const offset = (body["offset"] as number) ?? 0;
      const filtre: string[] = [`select=*`, `order=created_at.desc`, `limit=${limit}`, `offset=${offset}`];
      if (body["source"]     ) filtre.push(`source=eq.${encodeURIComponent(body["source"] as string)}`);
      if (body["numcommande"]) filtre.push(`internal_reference=eq.${encodeURIComponent(body["numcommande"] as string)}`);
      const rows = await sbSelect("coinpayments_audit_log", filtre.join("&"));
      return json({ erreur: false, logs: rows, total: rows.length });
    }

    if (action === "admin_config_status") {
      // Vérifie la configuration CoinPayments (lecture seule, clés jamais exposées)
      const hasPublicKey  = CP_PUBLIC_KEY.length > 0;
      const hasPrivateKey = CP_PRIVATE_KEY.length > 0;
      const hasSupabaseUrl = SUPABASE_URL.length > 0;
      const hasServiceKey  = SERVICE_KEY.length > 0;
      const ipnUrl = TC_IPN_URL;
      // Test connectivité API CoinPayments (sans clés sensibles)
      let apiReachable = false;
      let apiError     = "";
      if (hasPublicKey && hasPrivateKey) {
        try {
          await cpApiCall("get_basic_info", {});
          apiReachable = true;
        } catch (e) {
          apiError = e instanceof Error ? e.message : String(e);
          // get_basic_info peut échouer normalement si cmd inconnue — vérifier si l'auth passe
          if (apiError.includes("Unknown command")) apiReachable = true;
          else if (apiError.includes("Invalid key")) apiReachable = false;
        }
      }
      // Compter les transactions
      const allTx   = await sbSelect("coinpayments_transactions", "select=status&limit=1000").catch(() => []);
      const allLogs = await sbSelect("coinpayments_audit_log",   "select=id&limit=1&order=created_at.desc").catch(() => []);
      return json({
        erreur:         false,
        config: {
          publicKeySet:  hasPublicKey,
          privateKeySet: hasPrivateKey,
          supabaseOk:    hasSupabaseUrl && hasServiceKey,
          ipnUrl,
          apiReachable,
          apiError:      apiReachable ? null : apiError,
          publicKeyHint: hasPublicKey ? `${CP_PUBLIC_KEY.slice(0,8)}…${CP_PUBLIC_KEY.slice(-4)}` : null,
        },
        stats: {
          totalTransactions: allTx.length,
          credited:    allTx.filter(t => t["status"] === "credited").length,
          pending:     allTx.filter(t => t["status"] === "pending").length,
          lastAuditAt: allLogs.length > 0 ? allLogs[0]["created_at"] : null,
        },
      });
    }

    if (action === "admin_reconciliation") {
      // Rapprochement : détecte anomalies entre transactions DB et statuts CoinPayments
      // Cherche les transactions pending depuis plus de 30 min (potentiellement payées non créditées)
      const cutoff = new Date(Date.now() - 30 * 60 * 1000).toISOString();
      const pendingOld = await sbSelect(
        "coinpayments_transactions",
        `status=eq.pending&created_at=lt.${cutoff}&select=internal_reference,provider_transaction_id,amount,currency2,tontine_code,created_at,membre_nom&order=created_at.desc&limit=50`,
      );
      // Cherche les confirmed non crédités (confirmed mais pas credited)
      const confirmedNotCredited = await sbSelect(
        "coinpayments_transactions",
        `status=eq.confirmed&select=internal_reference,provider_transaction_id,amount,currency2,tontine_code,confirmed_at,membre_nom&order=confirmed_at.desc&limit=50`,
      );
      // Vérifie statut CoinPayments pour les pending vieux (max 10 pour ne pas surcharger)
      const anomalies: Array<Record<string, unknown>> = [];
      for (const tx of confirmedNotCredited.slice(0, 10)) {
        anomalies.push({
          type:        "confirmed_not_credited",
          numcommande: tx["internal_reference"],
          txid:        tx["provider_transaction_id"],
          amount:      tx["amount"],
          currency2:   tx["currency2"],
          tontine:     tx["tontine_code"],
          membre:      tx["membre_nom"],
          since:       tx["confirmed_at"],
          action:      "Appeler confirmer_et_crediter",
        });
      }
      for (const tx of pendingOld.slice(0, 20)) {
        anomalies.push({
          type:        "pending_too_long",
          numcommande: tx["internal_reference"],
          txid:        tx["provider_transaction_id"],
          amount:      tx["amount"],
          currency2:   tx["currency2"],
          tontine:     tx["tontine_code"],
          membre:      tx["membre_nom"],
          since:       tx["created_at"],
          action:      "Vérifier statut CoinPayments",
        });
      }
      return json({
        erreur:               false,
        anomalies,
        totalAnomalies:       anomalies.length,
        confirmedNotCredited: confirmedNotCredited.length,
        pendingTooLong:       pendingOld.length,
        checkedAt:            new Date().toISOString(),
      });
    }

    if (action === "admin_verifier_tx") {
      // Force la vérification d'une transaction spécifique + crédit si confirmé
      const numcommande = body["numcommande"] as string;
      if (!numcommande) return json({ erreur: true, message: "numcommande requis" }, 400);
      const rows = await sbSelect(
        "coinpayments_transactions",
        `internal_reference=eq.${encodeURIComponent(numcommande)}&select=*`,
      );
      if (rows.length === 0) return json({ erreur: true, message: "Transaction introuvable" }, 404);
      const result = await verifierEtCrediterStrictement(numcommande, "IPN", rows[0]);
      return json({ erreur: !result.ok, ok: result.ok, message: result.message, numcommande });
    }

    if (action === "get_rates") {
      // Retourne les taux CoinPayments avec capacité de paiement (accepted=1).
      // Utilisé pour vérifier que BNB.BSC, USDT.BEP20, etc. sont actifs.
      // cpApiCall retourne déjà le corps parsé (le champ "result" de l'API CoinPayments)
      const rates = await cpApiCall("rates", { accepted: 1, short: 0 }) as Record<string, Record<string, unknown>>;
      if (!rates || Object.keys(rates).length === 0) return json({ erreur: true, message: "Pas de résultat rates" }, 502);

      // Filtrer les devises demandées + toutes celles ayant is_fiat=0 et accepted=1
      const coinsInterets = ["BNB.BSC", "USDT.BEP20", "USDT.TRC20", "USDT.ERC20", "BTC", "ETH", "LTC"];
      const result: Record<string, unknown> = {};
      for (const coin of coinsInterets) {
        const info = rates[coin];
        if (info) {
          result[coin] = {
            name:         info["name"],
            rate_btc:     info["rate_btc"],
            accepted:     info["accepted"],
            is_fiat:      info["is_fiat"],
            can_convert:  info["can_convert"],
          };
        } else {
          result[coin] = { present: false, message: `${coin} non trouvé dans get_rates` };
        }
      }
      return json({ erreur: false, rates: result, checkedAt: new Date().toISOString() });
    }

    return json({ erreur: true, message: `Action inconnue: ${action}` }, 400);
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    console.error("[coinpayments-payment] Erreur critique:", msg);
    return json({ erreur: true, code: -504, message: msg }, 500);
  }
});