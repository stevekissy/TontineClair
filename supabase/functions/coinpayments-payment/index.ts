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
      const customRef = buildCustom(typeOp, numcommande);
      // deno-lint-ignore no-explicit-any
  let cpResult: any;
      try {
        cpResult = await cpCreateTransaction({
          amount:      montant,
          currency1:   "XOF",
          currency2,
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

    return json({ erreur: true, message: `Action inconnue: ${action}` }, 400);
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    console.error("[coinpayments-payment] Erreur critique:", msg);
    return json({ erreur: true, code: -504, message: msg }, 500);
  }
});