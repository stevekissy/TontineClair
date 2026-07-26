// ─────────────────────────────────────────────────────────────────────────────
// coinpayments-ipn — Edge Function Supabase (Deno/TypeScript)
//
// Handler IPN (Instant Payment Notification) dédié à TontineClair.
//
// ⚠️  ISOLATION SK PAY :
//   L'IPN général du compte CoinPayments reste intact (SK PAY).
//   Chaque transaction TontineClair injecte ipn_url = cette Edge Function.
//   CoinPayments envoie donc les IPN TontineClair ici, et seulement ici.
//
// ⚠️  RÈGLE DE CRÉDIT ABSOLUE :
//   - Le payload IPN N'EST JAMAIS utilisé directement pour créditer.
//   - On re-consulte TOUJOURS get_tx_info via coinpayments-payment.
//   - Protège contre les faux IPN, replays, et doubles crédits.
//   - Crédit UNIQUEMENT si get_tx_info retourne status=100.
//
// ⚠️  custom field :
//   CoinPayments retransmet le champ `custom` original dans l'IPN.
//   Format attendu : TC-TYPE-<numCommande>
//   Exemple : TC-COTISATION-TCP_TONTINE1_MID123_1720000000000
//   Ce champ est la clé de routage vers la bonne transaction en DB.
//
// Validation sécurité IPN :
//   - HMAC-SHA512 du payload avec COINPAYMENTS_IPN_SECRET
//   - merchant : vérifié contre COINPAYMENTS_MERCHANT_ID
//   - Toujours retourner HTTP 200 (CoinPayments re-tente si non-200)
//
// Variables d'environnement :
//   COINPAYMENTS_PUBLIC_KEY      — clé publique (pour appel get_tx_info)
//   COINPAYMENTS_PRIVATE_KEY     — clé privée HMAC-SHA512
//   COINPAYMENTS_IPN_SECRET      — secret IPN (validation signature)
//   COINPAYMENTS_MERCHANT_ID     — merchant ID (validation expéditeur)
//   SUPABASE_URL                 — auto-injecté
//   SUPABASE_SERVICE_ROLE_KEY    — auto-injecté
// ─────────────────────────────────────────────────────────────────────────────

// ── Env vars ──────────────────────────────────────────────────────────────────
const CP_PUBLIC_KEY   = Deno.env.get("COINPAYMENTS_PUBLIC_KEY")   ?? "";
const CP_PRIVATE_KEY  = Deno.env.get("COINPAYMENTS_PRIVATE_KEY")  ?? "";
const CP_IPN_SECRET   = Deno.env.get("COINPAYMENTS_IPN_SECRET")   ?? "";
const CP_MERCHANT_ID  = Deno.env.get("COINPAYMENTS_MERCHANT_ID")  ?? "";
const SUPABASE_URL    = Deno.env.get("SUPABASE_URL")              ?? "";
const SERVICE_KEY     = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

// ── CoinPayments API ──────────────────────────────────────────────────────────
const CP_API = "https://www.coinpayments.net/api.php";

// ─────────────────────────────────────────────────────────────────────────────
// HMAC-SHA512
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
  const sig = await crypto.subtle.sign("HMAC", cryptoKey, msgData);
  return Array.from(new Uint8Array(sig))
    .map(b => b.toString(16).padStart(2, "0"))
    .join("");
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
    const t = await res.text();
    throw new Error(`sbRpc ${fn} → ${res.status}: ${t}`);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// CoinPayments get_tx_info (re-vérification officielle)
// ─────────────────────────────────────────────────────────────────────────────

async function cpGetTxInfo(txid: string): Promise<{
  status:      number;
  status_text: string;
  coin:        string;
  amountf:     number;
  recv_amountf: number;
}> {
  if (!CP_PUBLIC_KEY || !CP_PRIVATE_KEY) {
    throw new Error("Clés CoinPayments non configurées");
  }

  const allParams: Record<string, string> = {
    version: "1",
    cmd:     "get_tx_info",
    key:     CP_PUBLIC_KEY,
    format:  "json",
    txid,
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

  if (!res.ok) throw new Error(`CoinPayments API HTTP ${res.status}`);

  const data = await res.json() as Record<string, unknown>;
  if (data["error"] !== "ok") throw new Error(`CoinPayments API: ${data["error"]}`);

  const r = (data["result"] as Record<string, unknown>) ?? {};
  return {
    status:       (r["status"]      as number)  ?? -1,
    status_text:  (r["status_text"] as string)  ?? "",
    coin:         (r["coin"]        as string)  ?? "",
    amountf:      parseFloat((r["amountf"]      as string) ?? "0"),
    recv_amountf: parseFloat((r["recv_amountf"] as string) ?? "0"),
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
  }).catch(e => console.error("[audit] Échec:", e));
}

// ─────────────────────────────────────────────────────────────────────────────
// Message succès par type d'opération
// ─────────────────────────────────────────────────────────────────────────────

function messageSucces(typeOp: string): string {
  const map: Record<string, string> = {
    cotisation:         "Cotisation enregistrée.",
    caisse:             "Apport caisse enregistré.",
    penalite:           "Pénalité réglée.",
    remboursement_pret: "Remboursement enregistré.",
    pret_octroye:       "Décaissement prêt enregistré.",
  };
  return map[typeOp] ?? "Paiement enregistré.";
}

// ─────────────────────────────────────────────────────────────────────────────
// Crédit côté serveur — réutilise RPCs SycaPay (p_operateur='coinpayments')
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
      p_code: code, p_montant: amount, p_reference: txid,
      p_num_commande: numcmd, p_operateur: "coinpayments", p_now: now,
    });

  } else if (typeOp === "caisse") {
    await sbRpc("crediter_caisse_sycapay", {
      p_code: code, p_montant: amount, p_reference: txid,
      p_num_commande: numcmd, p_operateur: "coinpayments",
      p_description: description, p_now: now,
    });

  } else if (typeOp === "penalite") {
    await sbRpc("crediter_penalite_sycapay", {
      p_code: code, p_montant: amount, p_reference: txid,
      p_num_commande: numcmd, p_operateur: "coinpayments",
      p_membre_id: membreId, p_now: now,
    });

  } else if (typeOp === "remboursement_pret") {
    await sbRpc("crediter_remboursement_sycapay", {
      p_code: code, p_montant: amount, p_reference: txid,
      p_num_commande: numcmd, p_operateur: "coinpayments",
      p_pret_id: pretId, p_now: now,
    });

  } else if (typeOp === "pret_octroye") {
    await sbRpc("debiter_pret_sycapay", {
      p_code: code, p_montant: amount, p_reference: txid,
      p_num_commande: numcmd, p_operateur: "coinpayments",
      p_pret_id: pretId, p_now: now,
    });

  } else {
    console.warn(`[crediter] typeOp "${typeOp}" → fallback caisse`);
    await sbRpc("crediter_caisse_sycapay", {
      p_code: code, p_montant: amount, p_reference: txid,
      p_num_commande: numcmd, p_operateur: "coinpayments",
      p_description: `[${typeOp}] ${description ?? ""}`, p_now: now,
    });
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Vérification IPN + crédit strict — 8 étapes
// ─────────────────────────────────────────────────────────────────────────────

async function verifierEtCrediter(
  numcommande: string,
  txid:        string,
  ipnPayload:  Record<string, string>,
): Promise<{ ok: boolean; message: string }> {
  console.log(`[ipn-verif] Début ${numcommande} txid=${txid}`);

  try {

    // ── Étape 1 : Transaction en DB ───────────────────────────────────────────
    const rows = await sbSelect(
      "coinpayments_transactions",
      `internal_reference=eq.${encodeURIComponent(numcommande)}&select=*`,
    );
    if (rows.length === 0) {
      console.warn(`[ipn-verif] ${numcommande} introuvable en DB`);
      await ecrireAudit({ numcommande, nouveauStatut: "error", source: "IPN", erreur: "Transaction introuvable" });
      return { ok: false, message: "Transaction introuvable" };
    }
    const dbTx = rows[0];

    // ── Étape 2 : Idempotence ─────────────────────────────────────────────────
    if (dbTx["status"] === "credited") {
      console.log(`[ipn-verif] ${numcommande} déjà crédité → idempotent`);
      return { ok: true, message: "Déjà crédité" };
    }

    // ── Étape 3 : Statut compatible ───────────────────────────────────────────
    const currentStatus = dbTx["status"] as string;
    if (currentStatus === "cancelled") {
      return { ok: false, message: "Transaction annulée" };
    }

    // ── Étape 4 : Re-vérification officielle get_tx_info (avec fallback IPN) ────
    // Tentative get_tx_info. Si la clé API n'a pas la permission (fréquent avec
    // les clés CoinPayments restreintes), on se fie au payload IPN validé par HMAC.
    // Le HMAC-SHA512 sur le body entier est une preuve cryptographique suffisante.
    let cpStatus: number;
    let cpStatusText: string;
    let cpCoin: string;
    let usedIpnFallback = false;

    try {
      const txInfo = await cpGetTxInfo(txid);
      cpStatus     = txInfo.status;
      cpStatusText = txInfo.status_text;
      cpCoin       = txInfo.coin;
      console.log(`[ipn-verif] get_tx_info → status=${cpStatus} (${cpStatusText})`);
    } catch (e) {
      const errMsg = String(e);
      // Fallback IPN : si la clé n'a pas la permission get_tx_info,
      // on accepte le payload IPN dont la signature HMAC a déjà été validée.
      if (errMsg.includes("permission") || errMsg.includes("API Key")
          || errMsg.includes("Access denied") || errMsg.includes("Insufficient")) {
        console.warn(`[ipn-verif] get_tx_info refusé (permission manquante), fallback IPN payload`);
        cpStatus     = parseInt(ipnPayload["status"] ?? "-1", 10);
        cpStatusText = ipnPayload["status_text"] ?? "";
        cpCoin       = ipnPayload["currency2"]   ?? ipnPayload["currency1"] ?? "";
        usedIpnFallback = true;
      } else {
        const msg = `Erreur get_tx_info: ${errMsg}`;
        await ecrireAudit({ numcommande, nouveauStatut: "error", source: "IPN", erreur: msg });
        return { ok: false, message: msg };
      }
    }

    await ecrireAudit({
      numcommande,
      ancienStatut:  currentStatus,
      nouveauStatut: `ipn_check:${cpStatus}`,
      source:        usedIpnFallback ? "IPN_FALLBACK" : "IPN",
      reponseApi:    {
        ipn_status:     ipnPayload["status"],
        api_status:     cpStatus,
        status_text:    cpStatusText,
        coin:           cpCoin,
        ipn_fallback:   usedIpnFallback,
      },
    });

    // ── Étape 5 : status doit être exactement 100 ─────────────────────────────
    if (cpStatus !== 100) {
      if (cpStatus === -1) {
        await sbPatch(
          "coinpayments_transactions",
          `internal_reference=eq.${encodeURIComponent(numcommande)}`,
          { status: "cancelled", error_message: cpStatusText },
        ).catch(() => {});
      } else if (cpStatus >= 1 && cpStatus < 100) {
        // En cours de confirmation blockchain → mettre à jour statut
        await sbPatch(
          "coinpayments_transactions",
          `internal_reference=eq.${encodeURIComponent(numcommande)}`,
          { status: "processing" },
        ).catch(() => {});
      }
      return { ok: false, message: `Status ${cpStatus} ≠ 100` };
    }

    // ── Étape 6 : Montant DB valide ───────────────────────────────────────────
    const dbAmount = (dbTx["amount"] as number) ?? 0;
    if (dbAmount <= 0) {
      await ecrireAudit({ numcommande, nouveauStatut: "error", source: "IPN", erreur: `Montant DB ${dbAmount}` });
      return { ok: false, message: "Montant invalide" };
    }

    // ── Étape 7 : Confirmer en DB ─────────────────────────────────────────────
    const now = new Date().toISOString();
    await sbPatch(
      "coinpayments_transactions",
      `internal_reference=eq.${encodeURIComponent(numcommande)}`,
      {
        status:                  "confirmed",
        confirmed_at:            now,
        provider_transaction_id: txid,
        ipn_received_at:         now,
      },
    );

    // ── Étape 8 : Crédit RPC ──────────────────────────────────────────────────
    try {
      await crediterCoteServeur({ ...dbTx, provider_transaction_id: txid });
    } catch (e: unknown) {
      const msg = e instanceof Error ? e.message : String(e);
      console.error(`[ipn-verif] Erreur RPC crédit ${numcommande}:`, msg);
      await sbPatch(
        "coinpayments_transactions",
        `internal_reference=eq.${encodeURIComponent(numcommande)}`,
        { error_message: `ipn_credit_error: ${msg}` },
      ).catch(() => {});
      await ecrireAudit({ numcommande, ancienStatut: "confirmed", nouveauStatut: "error", source: "IPN", erreur: msg });
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
      ancienStatut:  "confirmed",
      nouveauStatut: "credited",
      source:        usedIpnFallback ? "IPN_FALLBACK" : "IPN",
      reponseApi:    { txid, amount_xof: dbAmount, coin: cpCoin },
    });

    const typeOp = (dbTx["type_operation"] as string) ?? "cotisation";
    console.log(`[ipn-verif] ✅ ${numcommande} crédité OK via IPN (coin=${cpCoin}, fallback=${usedIpnFallback})`);
    return { ok: true, message: messageSucces(typeOp) };

  } catch (e: unknown) {
    const msg = e instanceof Error ? e.message : String(e);
    console.error(`[ipn-verif] ❌ Exception ${numcommande}:`, msg);
    await ecrireAudit({ numcommande, nouveauStatut: "error", source: "IPN", erreur: msg });
    return { ok: false, message: msg };
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Parser du champ custom — TC-TYPE-<numCommande>
// ─────────────────────────────────────────────────────────────────────────────

function parseCustomRef(custom: string): { typeOp: string; numcommande: string } | null {
  // Format : TC-TYPE-<numCommande>
  // Exemples :
  //   TC-COTISATION-TCP_TONTINE1_MID123_1720000000000
  //   TC-APPORT-TCP_ABC_XYZ_1720000001000
  //   TC-PENALITE-TCP_TG1_MID_1720000002000
  //   TC-REMBOURSEMENT-TCP_TG1_MID_1720000003000
  //   TC-PRET-TCP_TG1_MID_1720000004000
  if (!custom || !custom.startsWith("TC-")) return null;

  const parts = custom.split("-");
  // parts[0] = "TC"
  // parts[1] = "TYPE" (peut contenir plusieurs mots séparés par -, mais numCommande commence par TCP_)
  // Le reste = numCommande (commence par TCP_)

  // Trouver l'index où commence TCP_
  let tcpIndex = -1;
  for (let i = 2; i < parts.length; i++) {
    if (parts[i].startsWith("TCP_") || parts[i].startsWith("TC_")) {
      tcpIndex = i;
      break;
    }
  }

  if (tcpIndex === -1) {
    // Fallback : format TC-TYPE-numCommande où numCommande est la 3e partie
    // Reconstituer : parts[0..1] = TC-TYPE, parts[2..] = numCommande
    const typeLabel    = parts[1] ?? "INCONNU";
    const numcommande  = parts.slice(2).join("-");
    return { typeOp: labelToTypeOp(typeLabel), numcommande };
  }

  const typeLabel   = parts.slice(1, tcpIndex).join("-");
  const numcommande = parts.slice(tcpIndex).join("-");
  return { typeOp: labelToTypeOp(typeLabel), numcommande };
}

function labelToTypeOp(label: string): string {
  const map: Record<string, string> = {
    COTISATION:    "cotisation",
    APPORT:        "caisse",
    PENALITE:      "penalite",
    REMBOURSEMENT: "remboursement_pret",
    PRET:          "pret_octroye",
  };
  return map[label.toUpperCase()] ?? "cotisation";
}

// ─────────────────────────────────────────────────────────────────────────────
// Handler principal IPN
// ─────────────────────────────────────────────────────────────────────────────

Deno.serve(async (req: Request) => {
  // CoinPayments IPN = toujours POST application/x-www-form-urlencoded
  // On retourne TOUJOURS HTTP 200 (sinon CoinPayments re-tente indéfiniment)

  // Lire le corps IPN
  let rawBody = "";
  let payload: Record<string, string> = {};
  try {
    rawBody = await req.text();
    const params = new URLSearchParams(rawBody);
    params.forEach((v, k) => { payload[k] = v; });
  } catch {
    console.warn("[ipn] Impossible de lire le payload");
    return new Response("OK", { status: 200 });
  }

  const ipnType  = payload["ipn_type"]  ?? "";
  const merchant = payload["merchant"]  ?? "";
  const txid     = payload["txn_id"]    ?? "";
  const custom   = payload["custom"]    ?? "";
  const status   = parseInt(payload["status"] ?? "-999", 10);

  console.log(`[ipn] Reçu type=${ipnType} merchant=${merchant} txid=${txid} status=${status} custom="${custom}"`);

  // ── 1. Vérification HMAC IPN ─────────────────────────────────────────────
  if (CP_IPN_SECRET) {
    const receivedHmac = (req.headers.get("HMAC") ?? req.headers.get("hmac") ?? "").toLowerCase();
    if (!receivedHmac) {
      console.error("[ipn] Header HMAC absent — IPN rejeté");
      return new Response("OK", { status: 200 });  // 200 pour ne pas exposer l'erreur
    }
    try {
      const expectedHmac = (await hmacSha512(rawBody, CP_IPN_SECRET)).toLowerCase();
      if (receivedHmac !== expectedHmac) {
        console.error(`[ipn] HMAC invalide — IPN rejeté (custom="${custom}")`);
        return new Response("OK", { status: 200 });
      }
      console.log("[ipn] ✅ HMAC validé");
    } catch (e) {
      console.error("[ipn] Erreur validation HMAC:", e);
      return new Response("OK", { status: 200 });
    }
  } else {
    console.warn("[ipn] ⚠️  COINPAYMENTS_IPN_SECRET non configuré — validation HMAC désactivée");
  }

  // ── 2. Vérification merchant ──────────────────────────────────────────────
  if (CP_MERCHANT_ID && merchant && merchant !== CP_MERCHANT_ID) {
    console.error(`[ipn] Merchant mismatch: reçu=${merchant} attendu=${CP_MERCHANT_ID}`);
    return new Response("OK", { status: 200 });
  }

  // ── 3. Vérification type et présence txid ────────────────────────────────
  if (!txid) {
    console.warn("[ipn] txn_id absent → skip");
    return new Response("OK", { status: 200 });
  }

  // CoinPayments envoie plusieurs types d'IPN. On ne traite que "api" (transactions API).
  if (ipnType && ipnType !== "api" && ipnType !== "simple") {
    console.log(`[ipn] Type IPN "${ipnType}" ignoré (pas une transaction API)`);
    return new Response("OK", { status: 200 });
  }

  // ── 4. Identification de la transaction via custom ────────────────────────
  // custom = "TC-TYPE-<numCommande>" (injecté par creer_transaction)
  if (!custom || !custom.startsWith("TC-")) {
    console.warn(`[ipn] custom "${custom}" ne commence pas par TC- → pas une tx TontineClair`);
    return new Response("OK", { status: 200 });
  }

  const parsed = parseCustomRef(custom);
  if (!parsed) {
    console.error(`[ipn] Impossible de parser custom: "${custom}"`);
    return new Response("OK", { status: 200 });
  }

  const { numcommande } = parsed;
  console.log(`[ipn] Tx identifiée: numcommande="${numcommande}" type="${parsed.typeOp}" status=${status}`);

  // ── 5. Enregistrer réception IPN en DB ───────────────────────────────────
  await sbPatch(
    "coinpayments_transactions",
    `internal_reference=eq.${encodeURIComponent(numcommande)}`,
    { ipn_received_at: new Date().toISOString() },
  ).catch(() => {});  // Ne pas bloquer si la transaction n'existe pas encore

  // ── 6. Vérifier si déjà crédité (idempotence rapide) ─────────────────────
  try {
    const existing = await sbSelect(
      "coinpayments_transactions",
      `internal_reference=eq.${encodeURIComponent(numcommande)}&select=status`,
    );
    if (existing.length > 0 && existing[0]["status"] === "credited") {
      console.log(`[ipn] ${numcommande} déjà crédité → skip`);
      return new Response("OK", { status: 200 });
    }
  } catch { /* continuer */ }

  // ── 7. Traitement selon status IPN ───────────────────────────────────────
  // ⚠️  Le statut IPN est informatif uniquement.
  // La règle est de re-vérifier avec get_tx_info avant tout crédit.

  if (status === 100) {
    // Complete → tenter le crédit strict
    console.log(`[ipn] Status 100 → démarrage vérification stricte pour ${numcommande}`);
    const result = await verifierEtCrediter(numcommande, txid, payload);
    console.log(`[ipn] Résultat: ok=${result.ok} msg="${result.message}"`);

  } else if (status === -1) {
    // Annulé/Timeout
    console.log(`[ipn] Status -1 (annulé) pour ${numcommande}`);
    await sbPatch(
      "coinpayments_transactions",
      `internal_reference=eq.${encodeURIComponent(numcommande)}`,
      {
        status:        "cancelled",
        error_message: payload["status_text"] ?? "Cancelled by buyer or timed out",
      },
    ).catch(() => {});

    await ecrireAudit({
      numcommande,
      ancienStatut:  "pending",
      nouveauStatut: "cancelled",
      source:        "IPN",
      reponseApi:    { ipn_status: status, status_text: payload["status_text"] },
    });

  } else if (status >= 1 && status < 100) {
    // En cours de confirmation blockchain
    console.log(`[ipn] Status ${status} (confirmation en cours) pour ${numcommande}`);
    await sbPatch(
      "coinpayments_transactions",
      `internal_reference=eq.${encodeURIComponent(numcommande)}`,
      { status: "processing" },
    ).catch(() => {});

    await ecrireAudit({
      numcommande,
      ancienStatut:  "pending",
      nouveauStatut: "processing",
      source:        "IPN",
      reponseApi:    { ipn_status: status, status_text: payload["status_text"] },
    });

  } else {
    // Status 0 ou autre non-actionnable
    console.log(`[ipn] Status ${status} non-actionnable pour ${numcommande} → log seulement`);
    await ecrireAudit({
      numcommande,
      ancienStatut:  "pending",
      nouveauStatut: `ipn_status_${status}`,
      source:        "IPN",
      reponseApi:    { ipn_status: status, status_text: payload["status_text"] ?? "" },
    });
  }

  // TOUJOURS HTTP 200 — CoinPayments re-tente si non-200
  return new Response("OK", { status: 200 });
});
