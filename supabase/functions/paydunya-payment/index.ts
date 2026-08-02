// ─────────────────────────────────────────────────────────────────────────────
// paydunya-payment — Edge Function Supabase (Deno/TypeScript)
//
// Gestion des paiements Mobile Money via PayDunya (API PAR — Paiement Avec Redirection).
//
// Actions exposées :
//   creer_invoice     — Crée une facture checkout PayDunya → retourne checkout_url + token
//   statut            — Vérifie le statut d'une invoice via token
//   confirmer_et_crediter — Vérifie + crédite Supabase (après retour utilisateur)
//   verifier_ref      — Lookup rapide depuis DB interne
//
// Variables d'environnement requises :
//   PAYDUNYA_MASTER_KEY      — Master Key PayDunya (header PAYDUNYA-MASTER-KEY)
//   PAYDUNYA_PRIVATE_KEY     — Private Key PayDunya (header PAYDUNYA-PRIVATE-KEY)
//   PAYDUNYA_TOKEN           — Token PayDunya (header PAYDUNYA-TOKEN)
//   PAYDUNYA_SANDBOX         — "true" pour sandbox, "false" pour production
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

// ── PayDunya API endpoints ────────────────────────────────────────────────────
const PD_BASE        = PD_SANDBOX
  ? "https://app.paydunya.com/sandbox-api/v1"
  : "https://app.paydunya.com/api/v1";

const TC_IPN_URL     = `${SUPABASE_URL}/functions/v1/paydunya-ipn`;

// ── Opérateurs Mobile Money CI + Afrique de l'Ouest ─────────────────────────
// Côte d'Ivoire (priorité TontineClair)
const CHANNELS_CI = [
  "orange-money-ci",
  "wave-ci",
  "mtn-ci",
  "moov-ci",
  "djamo-ci",
];

// ── CORS ─────────────────────────────────────────────────────────────────────
const CORS = {
  "Access-Control-Allow-Origin":  "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

// ─────────────────────────────────────────────────────────────────────────────
// Helpers JSON / Supabase
// ─────────────────────────────────────────────────────────────────────────────

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
    const t = await res.text();
    throw new Error(`sbFetch ${method} ${path} → ${res.status}: ${t}`);
  }
  const text = await res.text();
  if (!text) return {};
  return JSON.parse(text);
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

// ─────────────────────────────────────────────────────────────────────────────
// PayDunya API helpers
// ─────────────────────────────────────────────────────────────────────────────

function pdHeaders(): Record<string, string> {
  return {
    "Content-Type":          "application/json",
    "PAYDUNYA-MASTER-KEY":   PD_MASTER_KEY,
    "PAYDUNYA-PRIVATE-KEY":  PD_PRIVATE_KEY,
    "PAYDUNYA-TOKEN":        PD_TOKEN,
  };
}

// ── Générer référence commande unique PayDunya ────────────────────────────────
// Format : TDP_[CODE]_[SUFFIX]_[TIMESTAMP]  (TDP = TontineClair Dunya Payment)
function genererNumCommande(codeTontine: string, suffix: string): string {
  const ts = Date.now();
  const safeSuffix = suffix.replace(/[^A-Za-z0-9]/g, "").toUpperCase().slice(0, 20);
  return `TDP_${codeTontine.toUpperCase()}_${safeSuffix}_${ts}`;
}

// ── Libellé opération → label lisible ────────────────────────────────────────
function typeOpToLabel(typeOp: string): string {
  const map: Record<string, string> = {
    cotisation:         "Cotisation",
    caisse:             "Apport en caisse",
    penalite:           "Pénalité",
    remboursement_pret: "Remboursement de prêt",
    pret_octroye:       "Prêt octroyé",
    depense_caisse:     "Dépense de caisse",
  };
  return map[typeOp] ?? typeOp.replace(/_/g, " ");
}

// ── Créer une invoice PayDunya (API PAR) ──────────────────────────────────────
async function pdCreerInvoice(params: {
  montant:       number;
  description:   string;
  numcommande:   string;
  membreNom?:    string;
  membreEmail?:  string;
  membrePhone?:  string;
  tontineCode:   string;
  membreId?:     string;
  typeOp:        string;
  pretId?:       string;
}): Promise<{ checkoutUrl: string; token: string }> {

  if (!PD_MASTER_KEY || !PD_PRIVATE_KEY || !PD_TOKEN) {
    throw new Error(
      "Clés PayDunya non configurées (PAYDUNYA_MASTER_KEY / PAYDUNYA_PRIVATE_KEY / PAYDUNYA_TOKEN)"
    );
  }

  const returnUrl = `tontineclair://paydunya/retour?ref=${encodeURIComponent(params.numcommande)}`;
  const cancelUrl = `tontineclair://paydunya/annulation?ref=${encodeURIComponent(params.numcommande)}`;

  const body = {
    invoice: {
      total_amount: params.montant,
      description:  params.description,
      customer: {
        name:  params.membreNom  ?? "Membre TontineClair",
        email: params.membreEmail ?? "noreply@tontineclair.com",
        phone: params.membrePhone ?? "",
      },
      // Canaux Mobile Money CI disponibles
      channels: CHANNELS_CI,
    },
    store: {
      name:    "TontineClair",
      tagline: "Tontines digitales sécurisées",
      logo_url: "https://tontineclair.com/icon.png",
    },
    custom_data: {
      tontine_code:   params.tontineCode,
      membre_id:      params.membreId   ?? "",
      type_flux:      params.typeOp,
      numcommande:    params.numcommande,
      pret_id:        params.pretId     ?? "",
    },
    actions: {
      callback_url: TC_IPN_URL,
      return_url:   returnUrl,
      cancel_url:   cancelUrl,
    },
  };

  const res = await fetch(`${PD_BASE}/checkout-invoice/create`, {
    method:  "POST",
    headers: pdHeaders(),
    body:    JSON.stringify(body),
  });

  const data = await res.json() as Record<string, unknown>;
  console.log(`[pdCreer] response_code=${data["response_code"]} description=${data["description"]}`);

  if (data["response_code"] !== "00") {
    throw new Error(
      `PayDunya API: ${data["response_text"] ?? data["description"] ?? "Erreur inconnue"}`
    );
  }

  return {
    checkoutUrl: data["response_text"] as string,
    token:       data["token"]         as string,
  };
}

// ── Vérifier statut d'une invoice PayDunya ────────────────────────────────────
async function pdVerifierStatut(token: string): Promise<{
  status:      string;   // "pending" | "completed" | "cancelled" | "failed"
  ok:          boolean;  // true si completed
  montant?:    number;
  operateur?:  string;
  receiptUrl?: string;
  rawData?:    unknown;
}> {
  const res = await fetch(`${PD_BASE}/checkout-invoice/confirm/${token}`, {
    method:  "GET",
    headers: pdHeaders(),
  });

  const data = await res.json() as Record<string, unknown>;

  if (data["response_code"] !== "00") {
    throw new Error(
      `PayDunya statut: ${data["response_text"] ?? data["description"] ?? "Erreur"}`
    );
  }

  const status    = (data["status"]      as string) ?? "pending";
  const invoice   = (data["invoice"]     as Record<string, unknown>) ?? {};
  const customer  = (data["customer"]    as Record<string, unknown>) ?? {};
  const montant   = (invoice["total_amount"] as number) ?? 0;
  const receiptUrl = (data["receipt_url"] as string) ?? "";

  // Opérateur utilisé (dans les données de paiement)
  const paymentData = (data["payment_data"] as Record<string, unknown>) ?? {};
  const operateur   = (paymentData["channel"] as string) ?? "";

  return {
    status,
    ok:         status === "completed",
    montant,
    operateur,
    receiptUrl,
    rawData:    data,
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
  }).catch(e => console.error("[audit] Échec écriture:", e));
}

// ─────────────────────────────────────────────────────────────────────────────
// Crédit Supabase (même RPCs que CoinPayments / SycaPay)
// ─────────────────────────────────────────────────────────────────────────────

async function crediterCoteServeur(tx: Record<string, unknown>): Promise<void> {
  const t    = (tx["type_operation"] as string) ?? "cotisation";
  const base = {
    p_code:         ((tx["tontine_code"]  as string) ?? "").toUpperCase(),
    p_montant:      (tx["amount"]         as number) ?? 0,
    p_reference:    (tx["pd_token"]       as string) ?? "",
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
// Vérification et crédit stricts (idempotent)
// ─────────────────────────────────────────────────────────────────────────────

async function verifierEtCrediterStrictement(
  numcommande: string,
  source: "POLLING" | "IPN",
  txRow: Record<string, unknown>,
): Promise<{ ok: boolean; message: string }> {
  console.log(`[verifier] Début ${numcommande} (source=${source})`);

  try {
    const rows = await sbSelect(
      "paydunya_transactions",
      `internal_reference=eq.${encodeURIComponent(numcommande)}&select=*`,
    );

    if (rows.length === 0) {
      const msg = `Transaction PayDunya introuvable: ${numcommande}`;
      await ecrireAudit({ numcommande, nouveauStatut: "error", source, erreur: msg });
      return { ok: false, message: msg };
    }

    const dbTx         = rows[0];
    const currentStatus = dbTx["status"] as string;

    // Idempotence
    if (dbTx["status"] === "credited") {
      console.log(`[verifier] ${numcommande} déjà crédité → idempotent`);
      return { ok: true, message: "Déjà crédité" };
    }

    if (currentStatus === "failed" || currentStatus === "cancelled") {
      return { ok: false, message: `Statut ${currentStatus} — crédit refusé` };
    }

    // Re-vérifier le statut PayDunya via API
    const token = (dbTx["pd_token"] ?? txRow["pd_token"]) as string | undefined;
    if (!token) {
      const msg = `Token PayDunya absent pour ${numcommande}`;
      await ecrireAudit({ numcommande, nouveauStatut: "error", source, erreur: msg });
      return { ok: false, message: msg };
    }

    let pdInfo: Awaited<ReturnType<typeof pdVerifierStatut>>;
    try {
      pdInfo = await pdVerifierStatut(token);
    } catch (e: unknown) {
      const msg = String(e);
      await ecrireAudit({ numcommande, nouveauStatut: "error", source, erreur: msg });
      return { ok: false, message: `Impossible de vérifier via PayDunya API: ${msg}` };
    }

    console.log(`[verifier] PayDunya statut=${pdInfo.status} (ok=${pdInfo.ok})`);

    await ecrireAudit({
      numcommande,
      ancienStatut:  currentStatus,
      nouveauStatut: `api_check:${pdInfo.status}`,
      source,
      reponseApi:    { status: pdInfo.status, operateur: pdInfo.operateur },
    });

    if (!pdInfo.ok) {
      if (pdInfo.status === "cancelled" || pdInfo.status === "failed") {
        await sbPatch(
          "paydunya_transactions",
          `internal_reference=eq.${encodeURIComponent(numcommande)}`,
          { status: pdInfo.status },
        ).catch(() => {});
      }
      return { ok: false, message: `Paiement pas encore confirmé (status=${pdInfo.status})` };
    }

    // Vérifier montant en DB
    const dbAmount = (dbTx["amount"] as number) ?? 0;
    if (dbAmount <= 0) {
      return { ok: false, message: `Montant DB invalide: ${dbAmount}` };
    }

    const now = new Date().toISOString();

    // Marquer confirmed
    await sbPatch(
      "paydunya_transactions",
      `internal_reference=eq.${encodeURIComponent(numcommande)}`,
      {
        status:       "confirmed",
        confirmed_at: now,
        operateur:    pdInfo.operateur ?? null,
        receipt_url:  pdInfo.receiptUrl ?? null,
      },
    );

    // Créditer Supabase
    const mergedTx = { ...txRow, ...dbTx };
    try {
      await crediterCoteServeur(mergedTx);
    } catch (e: unknown) {
      const msg = e instanceof Error ? e.message : String(e);
      console.error(`[verifier] Erreur RPC crédit ${numcommande}:`, msg);
      await sbPatch(
        "paydunya_transactions",
        `internal_reference=eq.${encodeURIComponent(numcommande)}`,
        { error_message: `credit_error: ${msg}` },
      ).catch(() => {});
      await ecrireAudit({
        numcommande, ancienStatut: "confirmed", nouveauStatut: "error", source, erreur: msg,
      });
      return { ok: false, message: msg };
    }

    // Marquer crédité
    await sbPatch(
      "paydunya_transactions",
      `internal_reference=eq.${encodeURIComponent(numcommande)}`,
      { status: "credited", credited_at: now },
    );

    await ecrireAudit({
      numcommande,
      ancienStatut:  "confirmed",
      nouveauStatut: "credited",
      source,
      reponseApi:    { token, amount_xof: dbAmount, operateur: pdInfo.operateur },
    });

    console.log(`[verifier] ✅ ${numcommande} crédité OK (token=${token})`);
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
    // ACTION : creer_invoice
    // Crée une facture checkout PayDunya → retourne checkout_url + token
    // ══════════════════════════════════════════════════════════════════════════
    if (action === "creer_invoice") {
      const montant     = (body["montant"]      as number) ?? (body["montant_xof"] as number);
      const tontineCode = (body["tontine_code"] as string) ?? "";
      const typeOp      = (body["type_operation"] as string) ?? "cotisation";
      const membreId    = body["membre_id"]     as string | undefined;
      const membreNom   = (body["membre_nom"]   as string) ?? "";
      const membreEmail = (body["membre_email"] as string) ?? "";
      const membrePhone = (body["telephone"]    as string) ?? "";
      const pretId      = (body["pret_id"]      as string) ?? null;
      const description = (body["description"]  as string)
                          ?? `TontineClair - ${typeOpToLabel(typeOp)}`;

      if (!montant || !tontineCode) {
        return json({ erreur: true, message: "montant et tontine_code requis" }, 400);
      }

      // Générer référence unique
      const suffix      = membreId ?? membreNom.slice(0, 10).replace(/\s/g, "") ?? "MBR";
      const numcommande = genererNumCommande(tontineCode, suffix);

      // Vérifier idempotence (si ref déjà existante pending)
      const existing = await sbSelect(
        "paydunya_transactions",
        `internal_reference=eq.${encodeURIComponent(numcommande)}&select=id,status,pd_token,checkout_url`,
      );
      if (existing.length > 0) {
        const tx = existing[0];
        if (tx["status"] === "credited" || tx["status"] === "confirmed") {
          return json({
            erreur:      false,
            idempotent:  true,
            token:       tx["pd_token"],
            checkoutUrl: tx["checkout_url"],
            status:      tx["status"],
            numcommande,
          });
        }
        if (tx["status"] === "pending" && tx["checkout_url"]) {
          return json({
            erreur:      false,
            idempotent:  true,
            token:       tx["pd_token"],
            checkoutUrl: tx["checkout_url"],
            status:      "pending",
            numcommande,
          });
        }
      }

      // Appeler PayDunya API PAR
      let pdResult: { checkoutUrl: string; token: string };
      try {
        pdResult = await pdCreerInvoice({
          montant,
          description,
          numcommande,
          membreNom:   membreNom  || undefined,
          membreEmail: membreEmail || undefined,
          membrePhone: membrePhone || undefined,
          tontineCode,
          membreId,
          typeOp,
          pretId:      pretId     || undefined,
        });
      } catch (e: unknown) {
        const msg = e instanceof Error ? e.message : String(e);
        console.error("[creer_invoice] Erreur PayDunya:", msg);
        return json({ erreur: true, message: `Erreur PayDunya: ${msg}` }, 502);
      }

      console.log(`[creer_invoice] Invoice créée token=${pdResult.token} ref=${numcommande}`);

      // Persister en DB
      await sbFetch("/rest/v1/paydunya_transactions", "POST", {
        tontine_code:       tontineCode,
        type_operation:     typeOp,
        internal_reference: numcommande,
        pd_token:           pdResult.token,
        checkout_url:       pdResult.checkoutUrl,
        amount:             montant,
        currency:           "XOF",
        status:             "pending",
        membre_id:          membreId   ?? null,
        membre_nom:         membreNom  || null,
        pret_id:            pretId     || null,
        description,
        sandbox:            PD_SANDBOX,
        created_at:         new Date().toISOString(),
      }).catch(async (e: Error) => {
        if (e.message.includes("23505") || e.message.includes("duplicate")) {
          await sbPatch(
            "paydunya_transactions",
            `internal_reference=eq.${encodeURIComponent(numcommande)}`,
            { pd_token: pdResult.token, checkout_url: pdResult.checkoutUrl },
          ).catch(() => {});
        } else {
          console.error("[creer_invoice] persistance DB:", e.message);
        }
      });

      await ecrireAudit({
        numcommande,
        ancienStatut:  "inexistant",
        nouveauStatut: "pending",
        source:        "CREATE",
        reponseApi:    {
          token:       pdResult.token,
          checkoutUrl: pdResult.checkoutUrl,
          sandbox:     PD_SANDBOX,
          channels:    CHANNELS_CI,
        },
      });

      return json({
        erreur:      false,
        token:       pdResult.token,
        checkoutUrl: pdResult.checkoutUrl,
        status:      "pending",
        numcommande,
        sandbox:     PD_SANDBOX,
      });
    }

    // ══════════════════════════════════════════════════════════════════════════
    // ACTION : statut
    // Vérifie le statut d'une invoice PayDunya
    // ══════════════════════════════════════════════════════════════════════════
    if (action === "statut") {
      const token        = body["token"]        as string | undefined;
      const numcommande  = body["numcommande"]  as string | undefined;

      if (!token && !numcommande) {
        return json({ erreur: true, message: "token ou numcommande requis" }, 400);
      }

      // Chercher en DB d'abord
      let dbTx: Record<string, unknown> | null = null;
      let effectiveToken = token;

      if (numcommande) {
        const rows = await sbSelect(
          "paydunya_transactions",
          `internal_reference=eq.${encodeURIComponent(numcommande)}&select=*`,
        );
        if (rows.length > 0) {
          dbTx          = rows[0];
          effectiveToken = effectiveToken ?? (dbTx["pd_token"] as string);
        }
      }

      // Réponse rapide depuis cache DB
      if (dbTx && dbTx["status"] === "credited") {
        return json({
          erreur:    false,
          ok:        true,
          status:    "completed",
          message:   "Paiement confirmé et enregistré.",
          numcommande,
          token:     dbTx["pd_token"],
          fromCache: true,
        });
      }
      if (dbTx && (dbTx["status"] === "cancelled" || dbTx["status"] === "failed")) {
        return json({
          erreur:    false,
          ok:        false,
          status:    dbTx["status"] as string,
          message:   "Paiement annulé ou échoué.",
          numcommande,
          fromCache: true,
        });
      }

      if (!effectiveToken) {
        return json({ erreur: true, message: "token introuvable" }, 400);
      }

      // Interroger PayDunya
      let pdInfo: Awaited<ReturnType<typeof pdVerifierStatut>>;
      try {
        pdInfo = await pdVerifierStatut(effectiveToken);
      } catch (e: unknown) {
        const msg = String(e);
        if (dbTx) {
          return json({
            erreur:    false,
            ok:        false,
            status:    (dbTx["status"] as string) ?? "pending",
            message:   "Vérification PayDunya temporairement indisponible.",
            numcommande,
            fromCache: true,
          });
        }
        return json({ erreur: true, message: `Erreur PayDunya: ${msg}` }, 502);
      }

      // Mettre à jour DB si statut change
      if (dbTx && numcommande && pdInfo.status !== "pending") {
        await sbPatch(
          "paydunya_transactions",
          `internal_reference=eq.${encodeURIComponent(numcommande)}`,
          { status: pdInfo.ok ? "confirmed" : pdInfo.status },
        ).catch(() => {});
      }

      return json({
        erreur:      false,
        ok:          pdInfo.ok,
        status:      pdInfo.status,
        montant:     pdInfo.montant,
        operateur:   pdInfo.operateur,
        receiptUrl:  pdInfo.receiptUrl,
        numcommande,
        token:       effectiveToken,
        needsCredit: pdInfo.ok,
      });
    }

    // ══════════════════════════════════════════════════════════════════════════
    // ACTION : confirmer_et_crediter
    // Vérifie le statut PayDunya + crédite Supabase (idempotent)
    // ══════════════════════════════════════════════════════════════════════════
    if (action === "confirmer_et_crediter") {
      const numcommande = body["numcommande"] as string;
      const tontineCode = body["tontine_code"] as string;
      const typeOp      = (body["type_operation"] as string) ?? "cotisation";
      const membreNom   = (body["membre_nom"] as string) ?? "";

      if (!numcommande || !tontineCode) {
        return json({ erreur: true, message: "numcommande et tontine_code requis" }, 400);
      }

      // Vérifier cache crédité
      const rows = await sbSelect(
        "paydunya_transactions",
        `internal_reference=eq.${encodeURIComponent(numcommande)}&select=*`,
      );
      if (rows.length > 0 && rows[0]["status"] === "credited") {
        return json({
          erreur:  false,
          ok:      true,
          status:  "completed",
          message: "Paiement Mobile Money confirmé.",
          numcommande,
          fromCache: true,
        });
      }

      const baseRow  = rows.length > 0 ? rows[0] : {};
      const enriched = {
        ...baseRow,
        tontine_code:   tontineCode,
        type_operation: typeOp,
        ...(membreNom        ? { membre_nom:  membreNom }                          : {}),
        ...(body["pret_id"]   ? { pret_id:    body["pret_id"]   as string }        : {}),
        ...(body["membre_id"] ? { membre_id:  body["membre_id"] as string }        : {}),
        ...(body["montant"] || body["montant_xof"]
          ? { amount: (body["montant"] ?? body["montant_xof"]) as number }
          : {}),
      };

      const result = await verifierEtCrediterStrictement(numcommande, "POLLING", enriched);

      return json({
        erreur:  !result.ok,
        ok:      result.ok,
        status:  result.ok ? "completed" : "pending",
        message: result.ok ? "Paiement Mobile Money confirmé." : result.message,
        numcommande,
      });
    }

    // ══════════════════════════════════════════════════════════════════════════
    // ACTION : verifier_ref
    // Lookup rapide depuis DB
    // ══════════════════════════════════════════════════════════════════════════
    if (action === "verifier_ref") {
      const numcommande = body["numcommande"] as string;
      if (!numcommande) return json({ erreur: true, message: "numcommande requis" }, 400);

      const rows = await sbSelect(
        "paydunya_transactions",
        `internal_reference=eq.${encodeURIComponent(numcommande)}&select=status,confirmed_at,credited_at,pd_token,amount,type_operation,membre_id,operateur,receipt_url`,
      );
      if (rows.length === 0) return json({ trouve: false, status: "inexistant" });

      const tx = rows[0];
      return json({
        trouve:        true,
        status:        tx["status"],
        ok:            tx["status"] === "credited",
        amount:        tx["amount"],
        operateur:     tx["operateur"],
        receiptUrl:    tx["receipt_url"],
        confirmedAt:   tx["confirmed_at"],
        creditedAt:    tx["credited_at"],
        token:         tx["pd_token"],
        membreId:      tx["membre_id"],
        typeOperation: tx["type_operation"],
      });
    }

    return json({ erreur: true, message: `Action inconnue: ${action}` }, 400);

  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    console.error("[paydunya-payment] Erreur critique:", msg);
    return json({ erreur: true, code: -504, message: msg }, 500);
  }
});
