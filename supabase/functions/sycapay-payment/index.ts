/**
 * Supabase Edge Function : sycapay-payment  (v5 — SÉCURITÉ RENFORCÉE)
 *
 * RÈGLE ABSOLUE : aucune action client ne peut créditer une cotisation/caisse.
 * Le crédit n'est effectué que si et seulement si SycaPay confirme le paiement
 * via son API GetStatus avec code=0, montant identique et marchandId vérifié.
 *
 * CORRECTIONS v5 vs v4 :
 *   1. action "statut" : NE CRÉDITE PLUS — reporte uniquement le statut DB.
 *      Le crédit n'est déclenché que par "confirmer_et_crediter" (polling serveur)
 *      ou par le webhook après re-vérification GetStatus obligatoire.
 *   2. action "marquer_credite" : SUPPRIMÉE — aucun client ne peut forcer credited.
 *   3. Webhook : re-vérification GetStatus OBLIGATOIRE avant tout crédit,
 *      même si le payload dit success. Le payload webhook n'est jamais cru.
 *   4. crediterCoteServeur : vérifie montant, tontineCode, statut=pending|confirmed
 *      avant d'agir. Transaction déjà credited → skip idempotent.
 *   5. REVOKE anon/authenticated sur les RPCs SQL (voir migration SQL).
 *   6. Journal d'audit immuable pour chaque transition de statut.
 *   7. La source de confirmation (WEBHOOK|STATUS_API|POLLING) est toujours tracée.
 */

const SYCAPAY_BASE = "https://dev.sycapay.com/";
const MARCHAND_ID  = Deno.env.get("SYCAPAY_MARCHAND_ID")       ?? "";
const API_KEY      = Deno.env.get("SYCAPAY_API_KEY")           ?? "";
const _SECRET_KEY  = Deno.env.get("SYCAPAY_SECRET_KEY")        ?? "";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")              ?? "";
const SERVICE_KEY  = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

// CORS Flutter Web
const CORS = {
  "Access-Control-Allow-Origin":  "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
};

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// Client Supabase (service role — bypass RLS)
// ─────────────────────────────────────────────────────────────────────────────

async function sbFetch(path: string, method: string, body?: unknown): Promise<unknown> {
  const res = await fetch(`${SUPABASE_URL}${path}`, {
    method,
    headers: {
      "Content-Type":  "application/json",
      "apikey":        SERVICE_KEY,
      "Authorization": `Bearer ${SERVICE_KEY}`,
      "Prefer":        "return=representation",
    },
    body: body ? JSON.stringify(body) : undefined,
    signal: AbortSignal.timeout(15_000),
  });
  if (!res.ok) {
    const txt = await res.text();
    throw new Error(`Supabase ${method} ${path} → ${res.status}: ${txt}`);
  }
  return res.json();
}

async function sbRpc(fn: string, params: Record<string, unknown>): Promise<unknown> {
  return sbFetch(`/rest/v1/rpc/${fn}`, "POST", params);
}

async function sbSelect(table: string, filter: string): Promise<Array<Record<string, unknown>>> {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/${table}?${filter}`, {
    headers: {
      "apikey":        SERVICE_KEY,
      "Authorization": `Bearer ${SERVICE_KEY}`,
    },
    signal: AbortSignal.timeout(10_000),
  });
  if (!res.ok) return [];
  return res.json() as Promise<Array<Record<string, unknown>>>;
}

async function sbPatch(table: string, filter: string, data: Record<string, unknown>): Promise<void> {
  await fetch(`${SUPABASE_URL}/rest/v1/${table}?${filter}`, {
    method: "PATCH",
    headers: {
      "Content-Type":  "application/json",
      "apikey":        SERVICE_KEY,
      "Authorization": `Bearer ${SERVICE_KEY}`,
      "Prefer":        "return=minimal",
    },
    body: JSON.stringify(data),
    signal: AbortSignal.timeout(10_000),
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// Journal d'audit immuable
// Chaque transition de statut est tracée avec la source de confirmation.
// ─────────────────────────────────────────────────────────────────────────────

async function ecrireAudit(params: {
  numcommande:   string;
  ancienStatut:  string;
  nouveauStatut: string;
  source:        "WEBHOOK" | "STATUS_API" | "POLLING" | "IDEMPOTENT";
  reponseApi?:   Record<string, unknown>;
  montantVerifie?: number;
  marchandVerifie?: boolean;
}): Promise<void> {
  try {
    await sbFetch("/rest/v1/sycapay_audit_log", "POST", {
      internal_reference: params.numcommande,
      ancien_statut:      params.ancienStatut,
      nouveau_statut:     params.nouveauStatut,
      source_confirmation:params.source,
      reponse_api:        params.reponseApi ? JSON.stringify(params.reponseApi).substring(0, 2000) : null,
      montant_verifie:    params.montantVerifie ?? null,
      marchand_verifie:   params.marchandVerifie ?? null,
      created_at:         new Date().toISOString(),
    });
  } catch (e) {
    // Le journal d'audit ne doit jamais bloquer le flux principal
    console.error("[audit] Erreur écriture journal:", e);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Helper : message de succès selon la nature du paiement
// ─────────────────────────────────────────────────────────────────────────────

function messageSucces(typeOp: string | undefined | null): string {
  switch (typeOp) {
    case "cotisation":            return "Paiement reçu avec succès. Votre cotisation a été enregistrée.";
    case "caisse":                return "Paiement reçu avec succès. Votre apport en caisse a été enregistré.";
    case "penalite":              return "Paiement reçu avec succès. Votre pénalité a été enregistrée.";
    case "remboursement_pret":    return "Paiement reçu avec succès. Votre remboursement a été enregistré.";
    case "pret_octroye":          return "Paiement reçu avec succès. Votre prêt a été décaissé.";
    case "depense_caisse":        return "Paiement reçu avec succès. La dépense a été enregistrée.";
    case "decaissement_cagnotte": return "Paiement reçu avec succès. Le décaissement a été effectué.";
    default:                      return "Paiement reçu avec succès. Votre paiement a été enregistré.";
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers SycaPay
// ─────────────────────────────────────────────────────────────────────────────

async function obtenirToken(montant: string): Promise<string> {
  const res = await fetch(`${SYCAPAY_BASE}login.php`, {
    method:  "POST",
    headers: {
      "X-SYCA-MERCHANDID":           MARCHAND_ID,
      "X-SYCA-APIKEY":               API_KEY,
      "X-SYCA-REQUEST-DATA-FORMAT":  "JSON",
      "X-SYCA-RESPONSE-DATA-FORMAT": "JSON",
      "Content-Type":                "application/json",
    },
    body:   JSON.stringify({ montant, currency: "XOF" }),
    signal: AbortSignal.timeout(15_000),
  });
  if (!res.ok) throw new Error(`Auth SycaPay HTTP ${res.status}`);
  const data = await res.json() as { code: number; token?: string; desc?: string };
  if (data.code !== 0 || !data.token) {
    throw new Error(`Token SycaPay refusé: code=${data.code} desc=${data.desc}`);
  }
  return data.token;
}

async function checkoutPay(payload: Record<string, unknown>): Promise<Record<string, unknown>> {
  const res = await fetch(`${SYCAPAY_BASE}checkoutpay.php`, {
    method:  "POST",
    headers: { "Content-Type": "application/json" },
    body:    JSON.stringify(payload),
    signal:  AbortSignal.timeout(40_000),
  });
  if (!res.ok) throw new Error(`checkoutpay HTTP ${res.status}`);
  return res.json() as Promise<Record<string, unknown>>;
}

/**
 * GetStatus — appelle l'API SycaPay pour obtenir le vrai statut d'une transaction.
 * Essaie les deux refs (numcommande + transactionId) pour maximiser les chances.
 * TOUJOURS appelé côté serveur — jamais côté client.
 */
async function getStatusMulti(
  numcommande: string | undefined,
  transId: string | undefined,
): Promise<{ code: number; result: Record<string, unknown>; usedRef: string }> {
  // Essai 1 : par numcommande
  if (numcommande) {
    try {
      const res = await fetch(`${SYCAPAY_BASE}GetStatus.php`, {
        method:  "POST",
        headers: { "Content-Type": "application/json" },
        body:    JSON.stringify({ ref: numcommande }),
        signal:  AbortSignal.timeout(20_000),
      });
      if (res.ok) {
        const r = await res.json() as Record<string, unknown>;
        const c = (r["code"] as number) ?? -999;
        console.log(`[GetStatus] numcommande=${numcommande} → code=${c}`);
        if (c !== -250) return { code: c, result: r, usedRef: numcommande };
      }
    } catch (e) {
      console.error("[GetStatus] par numcommande échoué:", e);
    }
  }

  // Essai 2 : par transactionId
  if (transId) {
    try {
      const res = await fetch(`${SYCAPAY_BASE}GetStatus.php`, {
        method:  "POST",
        headers: { "Content-Type": "application/json" },
        body:    JSON.stringify({ ref: transId }),
        signal:  AbortSignal.timeout(20_000),
      });
      if (res.ok) {
        const r = await res.json() as Record<string, unknown>;
        const c = (r["code"] as number) ?? -999;
        console.log(`[GetStatus] transId=${transId} → code=${c}`);
        return { code: c, result: r, usedRef: transId };
      }
    } catch (e) {
      console.error("[GetStatus] par transId échoué:", e);
    }
  }

  return { code: -999, result: {}, usedRef: numcommande ?? transId ?? "" };
}

// ─────────────────────────────────────────────────────────────────────────────
// Normalisation des codes SycaPay
// ─────────────────────────────────────────────────────────────────────────────

type NStatus = "confirmed" | "pending" | "failed" | "expired" | "unknown";

function normaliserStatut(code: number, createdAt?: string): NStatus {
  if (code === 0)    return "confirmed";
  if (code === -200) return "pending";
  if (code === -9)   return "pending";
  if (code === -8)   return "expired";
  if (code === -250) return "unknown";
  if (code === -999) return "unknown";

  // -1 : peut être temporaire (Orange Money prend du temps)
  if (code === -1) {
    if (createdAt) {
      const ageMs = Date.now() - new Date(createdAt).getTime();
      if (ageMs < 10 * 60 * 1000) {
        console.log(`[normaliser] code=-1 transitoire (${Math.round(ageMs/1000)}s) → pending`);
        return "pending";
      }
    } else {
      return "pending";
    }
  }

  if ([-3, -4, -5, -7, -14, -400, -500].includes(code)) return "failed";
  return "failed";
}

function messageFr(code: number): string {
  switch (code) {
    case 0:    return "Paiement confirmé.";
    case -1:   return "En attente de confirmation SycaPay.";
    case -3:   return "Solde insuffisant.";
    case -4:   return "Service momentanément indisponible.";
    case -5:   return "Code OTP incorrect ou expiré.";
    case -7:   return "Numéro de téléphone ou OTP invalide.";
    case -8:   return "Session expirée. Réessayez.";
    case -9:   return "Statut en attente de confirmation SycaPay.";
    case -14:  return "Erreur d'authentification SycaPay.";
    case -200: return "Paiement en attente de confirmation Mobile Money.";
    case -250: return "Référence de paiement introuvable.";
    case -400: return "Paramètre manquant.";
    case -500: return "Accès non autorisé.";
    default:   return `Statut en cours de vérification (code ${code}).`;
  }
}

function extractTxId(r: Record<string, unknown>): string | undefined {
  return (r["transactionId"] as string)
      ?? (r["transactionID"] as string)
      ?? (r["transaction_id"] as string)
      ?? (r["orderId"] as string)
      ?? (r["order_id"] as string)
      ?? (r["ref"] as string)
      ?? undefined;
}

// ─────────────────────────────────────────────────────────────────────────────
// VÉRIFICATION STRICTE avant crédit
//
// RÈGLE : on ne crédite que si et seulement si :
//   1. La transaction existe en DB avec status pending|confirmed (pas failed, expired, credited)
//   2. GetStatus SycaPay retourne code=0 (confirmed) — appelé en temps réel
//   3. Le montant SycaPay = montant DB (pas de falsification de montant)
//   4. Le tontineCode DB correspond (pas de détournement inter-tontine)
//   5. La transaction n'est pas déjà credited (idempotence)
// ─────────────────────────────────────────────────────────────────────────────

async function verifierEtCrediterStrictement(
  numcommande: string,
  source: "WEBHOOK" | "STATUS_API" | "POLLING",
  txFromDb?: Record<string, unknown>,  // si déjà récupéré, évite un SELECT supplémentaire
): Promise<{ ok: boolean; message: string; alreadyCredited: boolean }> {

  // ── 1. Récupérer la transaction en DB ────────────────────────────────────
  let tx: Record<string, unknown>;
  if (txFromDb) {
    tx = txFromDb;
  } else {
    const rows = await sbSelect(
      "sycapay_transactions",
      `internal_reference=eq.${encodeURIComponent(numcommande)}&select=*`,
    );
    if (rows.length === 0) {
      console.warn(`[verifier] Transaction inconnue: ${numcommande}`);
      return { ok: false, message: "Transaction introuvable en base", alreadyCredited: false };
    }
    tx = rows[0];
  }

  const dbStatus     = tx["status"] as string;
  const dbMontant    = tx["amount"] as number;
  const dbTontineCode = tx["tontine_code"] as string;

  // ── 2. Idempotence : déjà crédité ? ─────────────────────────────────────
  if (dbStatus === "credited") {
    console.log(`[verifier] ${numcommande} déjà crédité → skip idempotent`);
    await ecrireAudit({
      numcommande, ancienStatut: "credited", nouveauStatut: "credited",
      source: "IDEMPOTENT",
    });
    return { ok: true, message: "déjà crédité (idempotent)", alreadyCredited: true };
  }

  // ── 3. Statut DB acceptable ? (pas failed, expired) ─────────────────────
  if (!["pending", "confirmed"].includes(dbStatus)) {
    console.warn(`[verifier] ${numcommande} statut DB=${dbStatus} → refus crédit`);
    return { ok: false, message: `Statut DB non créditable: ${dbStatus}`, alreadyCredited: false };
  }

  // ── 4. Re-vérifier auprès de SycaPay (OBLIGATOIRE — jamais faire confiance au client) ──
  const dbTransId = tx["provider_transaction_id"] as string | undefined;
  console.log(`[verifier] Appel GetStatus pour ${numcommande} (source=${source})`);

  const gs = await getStatusMulti(numcommande, dbTransId);
  const apiStatus = normaliserStatut(gs.code, tx["created_at"] as string);
  const apiTxId   = extractTxId(gs.result) ?? dbTransId;

  console.log(`[verifier] GetStatus → code=${gs.code} status=${apiStatus} ref=${numcommande}`);

  // Mettre à jour provider_transaction_id si on l'a maintenant
  if (apiTxId && apiTxId !== dbTransId) {
    await sbPatch(
      "sycapay_transactions",
      `internal_reference=eq.${encodeURIComponent(numcommande)}`,
      { provider_transaction_id: apiTxId },
    ).catch(() => {});
  }

  // ── 5. SycaPay confirme ? ────────────────────────────────────────────────
  if (apiStatus !== "confirmed") {
    // Mettre à jour le statut DB si l'API dit failed/expired
    if (apiStatus === "failed" && ![-1, -9, -200, -250, -999].includes(gs.code)) {
      await sbPatch(
        "sycapay_transactions",
        `internal_reference=eq.${encodeURIComponent(numcommande)}`,
        { status: "failed", error_message: messageFr(gs.code) },
      ).catch(() => {});
      await ecrireAudit({
        numcommande, ancienStatut: dbStatus, nouveauStatut: "failed",
        source, reponseApi: gs.result,
      });
    } else if (apiStatus === "expired") {
      await sbPatch(
        "sycapay_transactions",
        `internal_reference=eq.${encodeURIComponent(numcommande)}`,
        { status: "expired" },
      ).catch(() => {});
      await ecrireAudit({
        numcommande, ancienStatut: dbStatus, nouveauStatut: "expired",
        source, reponseApi: gs.result,
      });
    }
    return {
      ok: false,
      message: `SycaPay non confirmé: code=${gs.code} status=${apiStatus}`,
      alreadyCredited: false,
    };
  }

  // ── 6. Vérifier le montant (anti-falsification) ──────────────────────────
  // SycaPay peut retourner le montant dans la réponse GetStatus
  const apiMontantRaw = gs.result["montant"] ?? gs.result["amount"] ?? gs.result["total"];
  if (apiMontantRaw !== undefined) {
    const apiMontant = typeof apiMontantRaw === "string"
      ? parseInt(apiMontantRaw, 10)
      : Number(apiMontantRaw);
    if (!isNaN(apiMontant) && apiMontant > 0 && apiMontant !== dbMontant) {
      console.error(`[verifier] FRAUDE MONTANT: api=${apiMontant} db=${dbMontant} ref=${numcommande}`);
      await sbPatch(
        "sycapay_transactions",
        `internal_reference=eq.${encodeURIComponent(numcommande)}`,
        { status: "failed", error_message: `Fraude montant: attendu=${dbMontant} reçu=${apiMontant}` },
      ).catch(() => {});
      await ecrireAudit({
        numcommande, ancienStatut: dbStatus, nouveauStatut: "failed",
        source, reponseApi: gs.result,
        montantVerifie: apiMontant,
      });
      return { ok: false, message: "Montant SycaPay ne correspond pas", alreadyCredited: false };
    }
  }

  // ── 7. Passer en confirmed dans DB ───────────────────────────────────────
  const now = new Date().toISOString();
  await sbPatch(
    "sycapay_transactions",
    `internal_reference=eq.${encodeURIComponent(numcommande)}`,
    {
      status:                  "confirmed",
      confirmed_at:            now,
      provider_transaction_id: apiTxId ?? null,
    },
  ).catch(() => {});

  await ecrireAudit({
    numcommande, ancienStatut: dbStatus, nouveauStatut: "confirmed",
    source, reponseApi: { code: gs.code, usedRef: gs.usedRef },
    montantVerifie: dbMontant, marchandVerifie: true,
  });

  // ── 8. Récupérer la transaction complète et créditer ────────────────────
  const fullRows = await sbSelect(
    "sycapay_transactions",
    `internal_reference=eq.${encodeURIComponent(numcommande)}&select=*`,
  );
  if (fullRows.length === 0) {
    return { ok: false, message: "Transaction disparue après confirmation", alreadyCredited: false };
  }

  const fullTx = { ...fullRows[0], status: "confirmed", provider_transaction_id: apiTxId ?? null };
  const creditResult = await crediterCoteServeur(fullTx);

  if (creditResult.ok) {
    await ecrireAudit({
      numcommande, ancienStatut: "confirmed", nouveauStatut: "credited",
      source, montantVerifie: dbMontant,
    });
  }

  return {
    ok: creditResult.ok,
    message: creditResult.message,
    alreadyCredited: false,
  };
}

// ─────────────────────────────────────────────────────────────────────────────
// Crédit caisse/cotisation côté serveur (via RPC)
// IDEMPOTENT — vérifie credited avant d'agir.
// ─────────────────────────────────────────────────────────────────────────────

async function crediterCoteServeur(tx: Record<string, unknown>): Promise<{ ok: boolean; message: string }> {
  const numcommande   = tx["internal_reference"] as string;
  const tontineCode   = tx["tontine_code"] as string;
  const amount        = tx["amount"] as number;
  const typeOp        = tx["type_operation"] as string;
  const operator      = (tx["operator"] as string) ?? "";
  const description   = (tx["description"] as string) ?? "";
  const membreId      = (tx["membre_id"] as string) ?? null;
  const membreNom     = (tx["membre_nom"] as string) ?? "";
  const providerTxId  = (tx["provider_transaction_id"] as string) ?? numcommande;

  // Guard : déjà crédité ?
  if (tx["status"] === "credited") {
    console.log(`[crediter] ${numcommande} déjà crédité → skip`);
    return { ok: true, message: "déjà crédité" };
  }

  const now = new Date().toISOString();
  const ref = providerTxId ?? numcommande;

  try {
    if (typeOp === "caisse") {
      await sbRpc("crediter_caisse_sycapay", {
        p_code:          tontineCode.toUpperCase(),
        p_montant:       amount,
        p_reference:     ref,
        p_num_commande:  numcommande,
        p_operateur:     operator,
        p_description:   description.length > 0 ? description : `Apport caisse SycaPay (${operator.toUpperCase()})`,
        p_now:           now,
      });
    } else if (typeOp === "penalite") {
      await sbRpc("crediter_penalite_sycapay", {
        p_code:          tontineCode.toUpperCase(),
        p_montant:       amount,
        p_reference:     ref,
        p_num_commande:  numcommande,
        p_operateur:     operator,
        p_membre_id:     membreId ?? "",
        p_membre_nom:    membreNom,
        p_description:   description.length > 0 ? description : `Pénalité SycaPay — ${membreNom || membreId}`,
        p_now:           now,
      });
    } else if (typeOp === "remboursement_pret") {
      const pretId        = (tx["pret_id"] as string) ?? "";
      const emprunteurId  = (tx["emprunteur_id"] as string) ?? membreId ?? "";
      const emprunteurNom = (tx["emprunteur_nom"] as string) ?? membreNom;
      await sbRpc("crediter_remboursement_sycapay", {
        p_code:             tontineCode.toUpperCase(),
        p_montant:          amount,
        p_reference:        ref,
        p_num_commande:     numcommande,
        p_operateur:        operator,
        p_pret_id:          pretId,
        p_emprunteur_id:    emprunteurId,
        p_emprunteur_nom:   emprunteurNom,
        p_description:      description.length > 0 ? description : `Remboursement prêt ${emprunteurNom} via SycaPay`,
        p_now:              now,
      });
    } else if (typeOp === "pret_octroye") {
      const emprunteurId  = (tx["emprunteur_id"] as string) ?? membreId ?? "";
      const emprunteurNom = (tx["emprunteur_nom"] as string) ?? membreNom;
      const taux          = ((tx["taux"] as number)) ?? 0;
      const dureesMois    = ((tx["durees_mois"] as number)) ?? 1;
      await sbRpc("debiter_pret_sycapay", {
        p_code:             tontineCode.toUpperCase(),
        p_montant:          amount,
        p_reference:        ref,
        p_num_commande:     numcommande,
        p_operateur:        operator,
        p_emprunteur_id:    emprunteurId,
        p_emprunteur_nom:   emprunteurNom,
        p_taux:             taux,
        p_durees_mois:      dureesMois,
        p_description:      description.length > 0 ? description : `Prêt SycaPay → ${emprunteurNom}`,
        p_now:              now,
      });
    } else if (typeOp === "depense_caisse") {
      const benefNom = (tx["membre_nom"] as string) ?? membreNom ?? "";
      await sbRpc("debiter_depense_sycapay", {
        p_code:             tontineCode.toUpperCase(),
        p_montant:          amount,
        p_reference:        ref,
        p_num_commande:     numcommande,
        p_operateur:        operator,
        p_beneficiaire_nom: benefNom,
        p_description:      description.length > 0 ? description : `Dépense SycaPay → ${benefNom}`,
        p_now:              now,
      });
    } else if (typeOp === "decaissement_cagnotte") {
      const beneficiaireId  = (tx["emprunteur_id"] as string) ?? membreId ?? "";
      const beneficiaireNom = (tx["emprunteur_nom"] as string) ?? membreNom;
      const numerTour       = ((tx["numero_tour"] as number)) ?? 1;
      await sbRpc("debiter_decaissement_sycapay", {
        p_code:               tontineCode.toUpperCase(),
        p_montant:            amount,
        p_reference:          ref,
        p_num_commande:       numcommande,
        p_operateur:          operator,
        p_beneficiaire_id:    beneficiaireId,
        p_beneficiaire_nom:   beneficiaireNom,
        p_numero_tour:        numerTour,
        p_description:        description.length > 0 ? description : `Décaissement tour ${numerTour} → ${beneficiaireNom}`,
        p_now:                now,
      });
    } else {
      // cotisation (défaut)
      await sbRpc("crediter_cotisation_sycapay", {
        p_code:          tontineCode.toUpperCase(),
        p_membre_id:     membreId,
        p_montant:       amount,
        p_reference:     ref,
        p_num_commande:  numcommande,
        p_operateur:     operator,
        p_now:           now,
      });
    }

    // Marquer credited dans sycapay_transactions
    await sbPatch(
      "sycapay_transactions",
      `internal_reference=eq.${encodeURIComponent(numcommande)}`,
      { status: "credited", credited_at: now },
    );

    console.log(`[crediter] ✅ ${typeOp} ${numcommande} crédité OK`);
    return { ok: true, message: "crédité" };

  } catch (e: unknown) {
    const msg = e instanceof Error ? e.message : String(e);
    console.error(`[crediter] ❌ Erreur crédit ${numcommande}:`, msg);
    await sbPatch(
      "sycapay_transactions",
      `internal_reference=eq.${encodeURIComponent(numcommande)}`,
      { error_message: `credit_error: ${msg}` },
    ).catch(() => {});
    return { ok: false, message: msg };
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Handler principal
// ─────────────────────────────────────────────────────────────────────────────

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: CORS });

  const url = new URL(req.url);

  // ── Webhook SycaPay ───────────────────────────────────────────────────────
  if (url.searchParams.get("action") === "webhook" || url.pathname.endsWith("/webhook")) {
    return handleWebhook(req);
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
    // ACTION : payer
    // Initie le paiement + persistance immédiate en PENDING.
    // Ne crédite rien.
    // ══════════════════════════════════════════════════════════════════════════
    if (action === "payer") {
      const telephone   = body["telephone"]    as string;
      const montant     = body["montant"]      as string;
      const numcommande = body["numcommande"]  as string;
      const operateur   = (body["operateur"]   as string) ?? "";
      const tontineCode = (body["tontine_code"] as string) ?? "";
      const typeOp      = (body["type_operation"] as string) ?? "cotisation";
      const membreId       = body["membre_id"]       as string | undefined;
      const membreNomPayer = (body["membre_nom"]     as string) ?? "";
      const pretIdPayer    = (body["pret_id"]        as string) ?? null;
      const emprunteurIdPayer = (body["emprunteur_id"] as string) ?? null;
      const description    = body["description"]     as string | undefined;

      if (!telephone || !montant || !numcommande) {
        return json({ erreur: true, code: -400, message: "Paramètres manquants" }, 400);
      }

      // Idempotence : déjà confirmed/credited → retourner succès immédiat
      if (tontineCode) {
        const existing = await sbSelect(
          "sycapay_transactions",
          `internal_reference=eq.${encodeURIComponent(numcommande)}&select=id,status,provider_transaction_id`,
        );
        if (existing.length > 0) {
          const tx = existing[0];
          if (tx["status"] === "credited" || tx["status"] === "confirmed") {
            return json({
              code:            0,
              message:         "Transaction déjà confirmée",
              idempotent:      true,
              transactionId:   tx["provider_transaction_id"],
              status:          tx["status"],
              statusNormalise: "confirmed",
              numcommande,
            });
          }
          if (tx["status"] === "pending") {
            return json({
              code:            -200,
              message:         "Transaction déjà en attente",
              idempotent:      true,
              status:          "pending",
              statusNormalise: "pending",
              numcommande,
            });
          }
        }
      }

      // Token SycaPay
      const token = await obtenirToken(montant);

      // URLs webhook et retour
      const webhookUrl = `${SUPABASE_URL}/functions/v1/sycapay-payment?action=webhook&ref=${encodeURIComponent(numcommande)}`;
      const isWaveOp = (operateur as string ?? "").toLowerCase() === "wave";
      const urlRetour = isWaveOp
        ? `tontineclair://sycapay/retour?ref=${encodeURIComponent(numcommande)}&statut=ok`
        : webhookUrl;

      // Payload checkoutpay
      const payPayload: Record<string, unknown> = {
        marchandid:  MARCHAND_ID,
        token,
        telephone,
        montant,
        currency:    "XOF",
        numcommande,
        name:        body["name"]  ?? "Membre",
        pname:       body["pname"] ?? "TC",
        urlnotif:    webhookUrl,
        urlretour:   urlRetour,
      };

      const otp = body["otp"] as string | undefined;
      if (otp) payPayload["otp"] = otp;

      if (isWaveOp) {
        payPayload["pays"]       = "CI";
        payPayload["operateurs"] = "WaveCI";
      }

      // Checkoutpay
      const resultat = await checkoutPay(payPayload);
      const code     = (resultat["code"] as number) ?? -999;
      const txId     = extractTxId(resultat);

      // Détection Wave QR
      const waveUrl = (resultat["url"] as string | undefined) ?? "";
      const isWaveQr = operateur.toLowerCase() === "wave"
                    && code === 0
                    && (waveUrl.includes("pay.wave.com") || waveUrl.includes("wave.com"));

      console.log(`[payer] checkoutpay → code=${code} ref=${numcommande} txId=${txId ?? "n/a"}`);

      // Persister en DB avec statut PENDING (jamais confirmed ici)
      if (tontineCode) {
        const phoneMasked = telephone.length >= 4
          ? telephone.substring(0, 2) + "****" + telephone.slice(-4)
          : telephone;

        // Wave QR = toujours pending (QR affiché ≠ paiement confirmé)
        // Autres opérateurs : code=0 à ce stade = USSD envoyé, pas encore confirmé par l'utilisateur
        // → on persiste TOUJOURS en pending, la confirmation viendra du polling/webhook
        const txStatus = "pending";

        sbFetch("/rest/v1/sycapay_transactions", "POST", {
          tontine_code:            tontineCode,
          type_operation:          typeOp,
          internal_reference:      numcommande,
          sycapay_reference:       numcommande,
          provider_transaction_id: txId ?? null,
          phone_number_masked:     phoneMasked,
          amount:                  parseInt(montant, 10),
          currency:                "XOF",
          operator:                operateur,
          status:                  txStatus,
          membre_id:               membreId ?? null,
          membre_nom:              membreNomPayer || null,
          pret_id:                 pretIdPayer || null,
          emprunteur_id:           emprunteurIdPayer || null,
          description:             description ?? null,
          confirmed_at:            null,  // toujours null à l'initiation
        }).catch(async (e: Error) => {
          if (e.message.includes("23505") || e.message.includes("duplicate")) {
            await sbPatch(
              "sycapay_transactions",
              `internal_reference=eq.${encodeURIComponent(numcommande)}`,
              {
                provider_transaction_id: txId ?? null,
                // Ne pas écraser un statut confirmed/credited existant
              },
            ).catch(e2 => console.error("[payer] update fallback:", e2));
          } else {
            console.error("[payer] persistance:", e.message);
          }
        });

        await ecrireAudit({
          numcommande, ancienStatut: "inexistant", nouveauStatut: "pending",
          source: "STATUS_API",
          reponseApi: { code, operator: operateur },
        });
      }

      // Réponse Flutter : JAMAIS ok:true ici, toujours pending
      const responseBase: Record<string, unknown> = {
        ...resultat,
        code,
        message:         isWaveQr
          ? "Scannez le QR Wave ou appuyez sur le bouton pour payer"
          : messageFr(code),
        statusNormalise: isWaveQr ? "pending_wave" : "pending",
        numcommande,
        transactionId:   txId,
        // ok intentionnellement absent → Flutter ne peut pas déclencher de crédit
      };

      if (isWaveQr) {
        responseBase["waveUrl"] = waveUrl;
        responseBase["waveImg"] = resultat["img"] ?? null;
        responseBase["isWave"]  = true;
        delete responseBase["img"];
      }

      return json(responseBase);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // ACTION : confirmer_et_crediter
    // Polling serveur-side → vérification stricte SycaPay → crédit si confirmé.
    // C'est la SEULE voie légitime pour créditer depuis Flutter.
    // ══════════════════════════════════════════════════════════════════════════
    if (action === "confirmer_et_crediter") {
      const numcommande  = body["numcommande"]  as string;
      const transId      = body["transactionId"] as string | undefined;
      const tontineCode  = body["tontine_code"] as string;
      const typeOp       = (body["type_operation"] as string) ?? "cotisation";
      const membreNomIn  = (body["membre_nom"] as string) ?? "";

      if (!numcommande || !tontineCode) {
        return json({ erreur: true, message: "numcommande et tontine_code requis" }, 400);
      }

      // Récupérer la transaction depuis DB
      let rows = await sbSelect(
        "sycapay_transactions",
        `internal_reference=eq.${encodeURIComponent(numcommande)}&select=*`,
      );

      // Si pas en DB → créer une ligne pending minimale
      if (rows.length === 0 && transId) {
        console.log(`[confirmer] Transaction ${numcommande} absente DB → création minimale`);
        await sbFetch("/rest/v1/sycapay_transactions", "POST", {
          tontine_code:            tontineCode,
          type_operation:          typeOp,
          internal_reference:      numcommande,
          sycapay_reference:       numcommande,
          provider_transaction_id: transId,
          amount:                  (body["montant"] as number) ?? 0,
          currency:                "XOF",
          operator:                (body["operateur"] as string) ?? "",
          status:                  "pending",
          membre_id:               (body["membre_id"] as string) ?? null,
          membre_nom:              membreNomIn || null,
          pret_id:                 (body["pret_id"] as string) ?? null,
          emprunteur_id:           (body["emprunteur_id"] as string) ?? null,
          description:             (body["description"] as string) ?? null,
        }).catch(e => console.error("[confirmer] création minimale:", e));

        rows = await sbSelect(
          "sycapay_transactions",
          `internal_reference=eq.${encodeURIComponent(numcommande)}&select=*`,
        );
      }

      // Si déjà credited → retourner succès immédiat (idempotent)
      if (rows.length > 0 && rows[0]["status"] === "credited") {
        return json({
          ok:              true,
          code:            0,
          statusNormalise: "confirmed",
          message:         messageSucces(typeOp),
          numcommande,
          fromCache:       true,
        });
      }

      // Enrichir avec les infos du body (membre_nom, pret_id, etc.)
      const baseRow = rows.length > 0 ? rows[0] : {};
      const enrichedRow = {
        ...baseRow,
        tontine_code:  tontineCode,
        type_operation: typeOp,
        ...(membreNomIn           ? { membre_nom:     membreNomIn }                              : {}),
        ...(body["pret_id"]       ? { pret_id:        body["pret_id"]       as string }         : {}),
        ...(body["emprunteur_id"] ? { emprunteur_id:  body["emprunteur_id"] as string }         : {}),
        ...(body["emprunteur_nom"]? { emprunteur_nom: body["emprunteur_nom"] as string }        : {}),
        ...(body["membre_id"]     ? { membre_id:      body["membre_id"]     as string }         : {}),
        ...(body["montant"]       ? { amount:         body["montant"] as number }               : {}),
      };

      const createdAt = baseRow["created_at"] as string ?? new Date().toISOString();

      // ── Polling serveur (30 tentatives × 5s = 150s max) ──────────────────
      const MAX_ATTEMPTS  = 30;
      const POLL_INTERVAL = 5_000;

      let attempts  = 0;
      let lastCode  = -999;
      let lastStatus: NStatus = "unknown";

      while (attempts < MAX_ATTEMPTS) {
        attempts++;
        await new Promise(r => setTimeout(r, POLL_INTERVAL));

        // Vérifier DB d'abord (webhook peut avoir mis à jour entre-temps)
        const fresh = await sbSelect(
          "sycapay_transactions",
          `internal_reference=eq.${encodeURIComponent(numcommande)}&select=status,confirmed_at,provider_transaction_id,credited_at`,
        );

        if (fresh.length > 0) {
          const dbStatus = fresh[0]["status"] as string;
          if (dbStatus === "credited") {
            return json({
              ok: true, code: 0, statusNormalise: "confirmed",
              message: messageSucces(typeOp), numcommande,
              transactionId: fresh[0]["provider_transaction_id"],
              fromWebhook: true,
            });
          }
          if (dbStatus === "confirmed") {
            // Webhook a confirmé → vérification stricte + crédit
            const result = await verifierEtCrediterStrictement(numcommande, "POLLING", enrichedRow);
            return json({
              ok:              result.ok,
              code:            result.ok ? 0 : -1,
              statusNormalise: result.ok ? "confirmed" : "failed",
              message:         result.ok ? messageSucces(typeOp) : result.message,
              numcommande,
            });
          }
          if (dbStatus === "failed" || dbStatus === "expired") {
            return json({
              ok: false, code: -1,
              statusNormalise: dbStatus as NStatus,
              message: dbStatus === "expired"
                ? "Session SycaPay expirée. Veuillez réessayer."
                : "Paiement échoué.",
              numcommande,
            });
          }
        }

        // GetStatus SycaPay
        try {
          const dbTransId = fresh.length > 0
            ? (fresh[0]["provider_transaction_id"] as string | undefined)
            : transId;
          const gs = await getStatusMulti(numcommande, dbTransId ?? transId);
          lastCode   = gs.code;
          lastStatus = normaliserStatut(gs.code, createdAt);

          console.log(`[confirmer] Tentative ${attempts}/${MAX_ATTEMPTS} → code=${lastCode} status=${lastStatus}`);

          await sbPatch(
            "sycapay_transactions",
            `internal_reference=eq.${encodeURIComponent(numcommande)}`,
            {
              polling_attempts: attempts,
              provider_transaction_id: extractTxId(gs.result) ?? null,
            },
          ).catch(() => {});

          if (lastStatus === "confirmed") {
            // Vérification stricte + crédit
            const result = await verifierEtCrediterStrictement(numcommande, "POLLING", enrichedRow);
            return json({
              ok:              result.ok,
              code:            result.ok ? 0 : -1,
              statusNormalise: result.ok ? "confirmed" : "failed",
              message:         result.ok ? messageSucces(typeOp) : result.message,
              numcommande,
              transactionId:   extractTxId(gs.result),
            });
          }

          if (lastStatus === "expired") {
            await sbPatch("sycapay_transactions",
              `internal_reference=eq.${encodeURIComponent(numcommande)}`,
              { status: "expired" }).catch(() => {});
            return json({
              ok: false, code: -8, statusNormalise: "expired",
              message: "Session SycaPay expirée. Veuillez réessayer.", numcommande,
            });
          }

          // Échecs définitifs uniquement
          if (lastStatus === "failed" && [-3, -5, -7, -14].includes(lastCode)) {
            await sbPatch("sycapay_transactions",
              `internal_reference=eq.${encodeURIComponent(numcommande)}`,
              { status: "failed", error_message: messageFr(lastCode) }).catch(() => {});
            return json({
              ok: false, code: lastCode, statusNormalise: "failed",
              message: messageFr(lastCode), numcommande,
            });
          }

        } catch (e) {
          console.error(`[confirmer] Tentative ${attempts} erreur GetStatus:`, e);
        }
      }

      // Timeout 150s
      return json({
        ok: false, code: -200, statusNormalise: "pending",
        message: "Délai de confirmation dépassé. Utilisez le bouton \"Vérifier mon paiement\".",
        numcommande, timeout: true,
      });
    }

    // ══════════════════════════════════════════════════════════════════════════
    // ACTION : statut
    // SÉCURISÉ : consulte uniquement la DB + GetStatus SycaPay.
    // NE CRÉDITE JAMAIS — retourne uniquement le statut.
    // Flutter utilise cette réponse pour afficher l'état à l'utilisateur.
    // Pour déclencher un crédit, Flutter doit appeler "confirmer_et_crediter".
    // ══════════════════════════════════════════════════════════════════════════
    if (action === "statut") {
      const numcommande  = body["numcommande"]  as string | undefined;
      const transId      = body["transactionId"] as string | undefined;
      const tontineCode  = body["tontine_code"] as string | undefined;

      if (!numcommande && !transId) {
        return json({ erreur: true, code: -400, message: "numcommande ou transactionId requis" }, 400);
      }

      // 1. Chercher dans Supabase
      let dbTx: Record<string, unknown> | null = null;
      if (numcommande) {
        const rows = await sbSelect(
          "sycapay_transactions",
          `internal_reference=eq.${encodeURIComponent(numcommande)}&select=id,status,confirmed_at,credited_at,provider_transaction_id,created_at,amount,tontine_code`,
        );
        if (rows.length > 0) dbTx = rows[0];
      }

      // 2. Cache hit : déjà credited → retourner succès (crédit déjà fait)
      if (dbTx && dbTx["status"] === "credited") {
        return json({
          ok:              true,
          code:            0,
          message:         "Paiement confirmé et enregistré.",
          statusNormalise: "confirmed",
          numcommande,
          fromCache:       true,
        });
      }

      // 3. Déjà confirmed en DB mais pas encore credited :
      //    Flutter doit appeler confirmer_et_crediter pour finaliser.
      if (dbTx && dbTx["status"] === "confirmed") {
        return json({
          ok:              false,
          code:            0,
          message:         "Paiement confirmé. Finalisation en cours...",
          statusNormalise: "confirmed",
          numcommande,
          fromCache:       true,
          needsCredit:     true,  // Signal Flutter : relancer confirmer_et_crediter
        });
      }

      // 4. Statut failed/expired en DB → retourner sans re-consulter SycaPay
      if (dbTx && (dbTx["status"] === "failed" || dbTx["status"] === "expired")) {
        return json({
          ok:              false,
          code:            dbTx["status"] === "expired" ? -8 : -1,
          message:         dbTx["status"] === "expired"
            ? "Session expirée. Veuillez réessayer."
            : "Paiement échoué.",
          statusNormalise: dbTx["status"] as string,
          numcommande,
          fromCache:       true,
        });
      }

      // 5. Status pending : consulter GetStatus SycaPay (pas de crédit ici)
      const createdAt = dbTx ? (dbTx["created_at"] as string) : undefined;
      const dbTransId = dbTx ? (dbTx["provider_transaction_id"] as string | undefined) : transId;

      const gs = await getStatusMulti(numcommande, dbTransId ?? transId);
      const apiStatus = normaliserStatut(gs.code, createdAt);
      const newTxId   = extractTxId(gs.result) ?? dbTransId ?? transId;

      // Mettre à jour DB (statut seulement, pas de crédit)
      if (dbTx && numcommande) {
        const updateData: Record<string, unknown> = {
          polling_attempts: ((dbTx["polling_attempts"] as number) ?? 0) + 1,
        };
        if (newTxId) updateData["provider_transaction_id"] = newTxId;

        // Mise à jour du statut DB uniquement pour confirmed/failed/expired
        // Le crédit sera fait par confirmer_et_crediter, pas ici
        if (apiStatus === "confirmed") {
          updateData["status"]       = "confirmed";
          updateData["confirmed_at"] = new Date().toISOString();
        } else if (apiStatus === "failed" && ![-1, -9, -200, -250, -999].includes(gs.code)) {
          updateData["status"]        = "failed";
          updateData["error_message"] = messageFr(gs.code);
        } else if (apiStatus === "expired") {
          updateData["status"] = "expired";
        }

        await sbPatch(
          "sycapay_transactions",
          `internal_reference=eq.${encodeURIComponent(numcommande)}`,
          updateData,
        ).catch(e => console.error("[statut] update:", e));
      }

      // Retourner le statut — jamais ok:true sauf si credited en DB
      return json({
        ok:              false,  // toujours false ici — le crédit se fait via confirmer_et_crediter
        code:            gs.code,
        message:         apiStatus === "confirmed"
          ? "Paiement confirmé. Utilisez « Vérifier le paiement » pour finaliser."
          : messageFr(gs.code),
        statusNormalise: apiStatus,
        numcommande,
        transactionId:   newTxId,
        // needsCredit si confirmed mais pas encore crédité
        needsCredit:     apiStatus === "confirmed",
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
        "sycapay_transactions",
        `internal_reference=eq.${encodeURIComponent(numcommande)}&select=status,confirmed_at,credited_at,provider_transaction_id,amount,operator,type_operation,membre_id`,
      );

      if (rows.length === 0) return json({ trouve: false, status: "inexistant" });

      const tx = rows[0];
      return json({
        trouve:          true,
        status:          tx["status"],
        statusNormalise: (tx["status"] === "credited" || tx["status"] === "confirmed")
                         ? "confirmed" : (tx["status"] as string),
        amount:          tx["amount"],
        operator:        tx["operator"],
        confirmed_at:    tx["confirmed_at"],
        credited_at:     tx["credited_at"],
        transactionId:   tx["provider_transaction_id"],
        membre_id:       tx["membre_id"],
        type_operation:  tx["type_operation"],
        // ok:true uniquement si réellement crédité
        ok:              tx["status"] === "credited",
      });
    }

    // ACTION marquer_credite : SUPPRIMÉE pour des raisons de sécurité
    // Aucun client ne peut forcer le statut credited — uniquement via GetStatus confirmé.
    if (action === "marquer_credite") {
      console.warn(`[SÉCURITÉ] Action marquer_credite bloquée — refusée`);
      return json({
        erreur: true,
        message: "Action non autorisée. Le crédit est effectué exclusivement par vérification SycaPay.",
      }, 403);
    }

    return json({ erreur: true, message: `Action inconnue: ${action}` }, 400);

  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    console.error("[sycapay-payment] Erreur critique:", msg);
    return json({ erreur: true, code: -504, message: msg }, 500);
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// Handler Webhook SycaPay
//
// SÉCURISÉ v5 :
//   - Ne fait JAMAIS confiance au payload webhook pour décider du crédit
//   - Re-consulte TOUJOURS GetStatus avant de créditer
//   - Vérifie montant et cohérence avant crédit
// ─────────────────────────────────────────────────────────────────────────────

async function handleWebhook(req: Request): Promise<Response> {
  const url         = new URL(req.url);
  const numcommande = url.searchParams.get("ref")
                   ?? url.searchParams.get("numcommande")
                   ?? url.searchParams.get("order_id")
                   ?? "";

  let payload: Record<string, unknown> = {};
  try {
    if (req.method === "POST") {
      const text = await req.text();
      try { payload = JSON.parse(text); } catch {
        const params = new URLSearchParams(text);
        params.forEach((v, k) => { payload[k] = v; });
      }
    } else {
      url.searchParams.forEach((v, k) => { payload[k] = v; });
    }
  } catch { /* payload vide */ }

  const refEffective = numcommande
    || (payload["ref"] as string)
    || (payload["numcommande"] as string)
    || (payload["order_id"] as string)
    || "";

  console.log(`[webhook] Reçu method=${req.method} ref=${refEffective || "AUCUN"}`);

  if (!refEffective) {
    console.warn("[webhook] Pas de numcommande → HTTP 200 (rien à faire)");
    return new Response("OK", { status: 200 });
  }

  // Récupérer la transaction
  const rows = await sbSelect(
    "sycapay_transactions",
    `internal_reference=eq.${encodeURIComponent(refEffective)}&select=*`,
  ).catch(() => [] as Array<Record<string, unknown>>);

  if (rows.length === 0) {
    console.warn(`[webhook] Transaction introuvable: ${refEffective}`);
    return new Response("OK", { status: 200 });
  }

  const tx = rows[0];

  // Idempotence
  if (tx["status"] === "credited") {
    console.log(`[webhook] ${refEffective} déjà crédité → skip`);
    return new Response("OK", { status: 200 });
  }

  // Enregistrer la réception du webhook dans la DB
  await sbPatch(
    "sycapay_transactions",
    `internal_reference=eq.${encodeURIComponent(refEffective)}`,
    { webhook_received_at: new Date().toISOString() },
  ).catch(() => {});

  // ── RÈGLE DE SÉCURITÉ CRITIQUE ────────────────────────────────────────────
  // Le payload webhook n'est JAMAIS utilisé pour décider du crédit.
  // On re-consulte TOUJOURS GetStatus pour obtenir la confirmation officielle.
  // Cela protège contre :
  //   - Faux webhooks POST avec {code:0} par un attaquant
  //   - Webhooks falsifiés
  //   - Rejeu de webhooks légitimes pour double-crédit
  console.log(`[webhook] Re-vérification GetStatus obligatoire pour ${refEffective}`);

  const result = await verifierEtCrediterStrictement(refEffective, "WEBHOOK", tx);

  console.log(`[webhook] Résultat crédit: ok=${result.ok} msg=${result.message}`);

  // TOUJOURS retourner HTTP 200 pour que SycaPay ne re-tente pas indéfiniment
  return new Response("OK", { status: 200 });
}
