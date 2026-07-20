/**
 * Supabase Edge Function : sycapay-payment  (v4 — crédit serveur-side)
 *
 * CORRECTIONS v4 vs v3 :
 *   1. GetStatus -1 traité comme TEMPORAIRE (pas échec définitif) pendant 3min
 *   2. ACTION "confirmer_et_crediter" : polling serveur-side + crédit DB-side
 *      → Flutter peut se fermer, le serveur finit le travail
 *   3. Webhook : crédite automatiquement la caisse/cotisation dans Supabase
 *   4. Meilleure extraction du transactionId (différents noms de champs SycaPay)
 *   5. Retry automatique sur erreurs réseau transitoires
 *
 * Architecture :
 *   Flutter → Edge Function → SycaPay API
 *                          → Supabase DB (sycapay_transactions)
 *                          → ecrire_tontine_sans_pin (RPC → crédit caisse)
 *
 * Actions :
 *   "payer"                  : login + checkoutpay + persistance pending
 *   "statut"                 : GetStatus multi-stratégie (numcommande + transactionId)
 *   "confirmer_et_crediter"  : polling serveur 3min → crédit DB → retour Flutter
 *   "verifier_ref"           : lookup Supabase par référence interne
 *   "marquer_credite"        : mark credited (anti double-crédit)
 *   webhook (GET/POST)       : callback SycaPay → update DB + crédit auto
 *
 * Variables d'environnement :
 *   SYCAPAY_MARCHAND_ID  SYCAPAY_API_KEY  SYCAPAY_SECRET_KEY
 *   SUPABASE_URL  SUPABASE_SERVICE_ROLE_KEY  (auto-injectés)
 */

const SYCAPAY_BASE = "https://dev.sycapay.com/";
const MARCHAND_ID  = Deno.env.get("SYCAPAY_MARCHAND_ID")       ?? "";
const API_KEY      = Deno.env.get("SYCAPAY_API_KEY")           ?? "";
const _SECRET_KEY  = Deno.env.get("SYCAPAY_SECRET_KEY")        ?? ""; // gardé pour signature future
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
 * GetStatus — essaie TOUJOURS les deux refs pour maximiser les chances.
 * SycaPay peut indexer par l'une ou l'autre selon l'opérateur.
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
        // -250 = ref introuvable → essayer transId. -1 peut être transitoire.
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
// CODES CONFIRMÉS (production) :
//   0    = succès confirmé
//  -1    = échec — ATTENTION : peut être TEMPORAIRE juste après checkoutpay
//           Orange Money prend 10-60s avant que GetStatus renvoie -1 définitif
//           vs 0. On traite -1 comme pending si < 3min après création.
//  -3    = solde insuffisant (définitif)
//  -4    = service indisponible
//  -5    = OTP incorrect
//  -7    = numéro invalide
//  -8    = session expirée
//  -9    = statut pas encore disponible (retry)
//  -14   = erreur auth
//  -200  = en attente (pending — confirmation USSD en cours)
//  -250  = référence introuvable (retry avec autre ref)
//  -400  = paramètre manquant
//  -500  = accès refusé

type NStatus = "confirmed" | "pending" | "failed" | "expired" | "unknown";

/**
 * Normaliser le code SycaPay.
 * @param code          Code SycaPay retourné
 * @param createdAt     Timestamp de création de la transaction (pour traiter -1 temporaire)
 */
function normaliserStatut(code: number, createdAt?: string): NStatus {
  if (code === 0)    return "confirmed";
  if (code === -200) return "pending";
  if (code === -9)   return "pending";
  if (code === -8)   return "expired";
  if (code === -250) return "unknown"; // ref introuvable → retry
  if (code === -999) return "unknown"; // erreur réseau → retry

  // -1 : peut être temporaire (Orange Money prend du temps à enregistrer)
  // SycaPay peut retourner -1 transitoire pendant jusqu'à 10min sur certains opérateurs.
  // On traite -1 comme pending si < 10min après création pour ne pas bloquer à tort.
  if (code === -1) {
    if (createdAt) {
      const ageMs = Date.now() - new Date(createdAt).getTime();
      if (ageMs < 10 * 60 * 1000) {
        console.log(`[normaliser] code=-1 transitoire (${Math.round(ageMs/1000)}s) → pending`);
        return "pending";
      }
    } else {
      // Pas de createdAt → traiter comme pending par précaution
      return "pending";
    }
  }

  // Codes définitivement échec
  if ([-3, -4, -5, -7, -14, -400, -500].includes(code)) return "failed";

  return "failed"; // par défaut
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

/** Extraire le transactionId depuis la réponse SycaPay (plusieurs noms possibles) */
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
// Crédit caisse/cotisation côté serveur (via RPC ecrire_tontine_sans_pin)
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Crédite la caisse ou la cotisation côté Supabase.
 * Appelé depuis le webhook ET depuis confirmer_et_crediter.
 * IDEMPOTENT : vérifie le statut 'credited' avant d'agir.
 */
async function crediterCoteServeur(tx: Record<string, unknown>): Promise<{ ok: boolean; message: string }> {
  const numcommande   = tx["internal_reference"] as string;
  const tontineCode   = tx["tontine_code"] as string;
  const amount        = tx["amount"] as number;
  const typeOp        = tx["type_operation"] as string;
  const operator      = tx["operator"] as string ?? "";
  const description   = tx["description"] as string ?? "";
  const membreId      = tx["membre_id"] as string ?? null;
  const membreNom     = tx["membre_nom"] as string ?? "";
  const providerTxId  = tx["provider_transaction_id"] as string ?? numcommande;

  // Guard : déjà crédité ?
  if (tx["status"] === "credited") {
    console.log(`[crediter] ${numcommande} déjà crédité → skip`);
    return { ok: true, message: "déjà crédité" };
  }

  const now = new Date().toISOString();
  const ref = providerTxId ?? numcommande;

  // Construire le mouvement à injecter dans le JSON de la tontine
  // On passe par ecrire_tontine_sans_pin qui reçoit le JSON complet.
  // Pour créditer côté serveur, on appelle une RPC spécialisée.
  try {
    if (typeOp === "caisse") {
      // Créditer la caisse via RPC (apport)
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
      // Créditer la caisse via RPC (pénalité) — débite le payeur, enregistre penalite dans JSON
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
      // Remboursement de prêt via SycaPay — crédite caisse + met à jour le prêt dans JSON
      const pretId        = tx["pret_id"]         as string ?? "";
      const emprunteurId  = tx["emprunteur_id"]   as string ?? membreId ?? "";
      const emprunteurNom = tx["emprunteur_nom"]  as string ?? membreNom;
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
      // Prêt octroyé via SycaPay — débite la caisse + crée le prêt dans JSON
      const emprunteurId  = tx["emprunteur_id"]   as string ?? membreId ?? "";
      const emprunteurNom = tx["emprunteur_nom"]  as string ?? membreNom;
      const taux          = (tx["taux"]           as number) ?? 0;
      const dureesMois    = (tx["durees_mois"]    as number) ?? 1;
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
      // Dépense caisse via SycaPay — débite la caisse
      const benefNom = tx["membre_nom"]  as string ?? membreNom ?? "";
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
      // Décaissement cagnotte (clôture tour) via SycaPay — débite la caisse + passe au tour suivant
      const beneficiaireId  = tx["emprunteur_id"]   as string ?? membreId ?? "";
      const beneficiaireNom = tx["emprunteur_nom"]  as string ?? membreNom;
      const numerTour       = (tx["numero_tour"]    as number) ?? 1;
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
      // Créditer la cotisation via RPC
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

    // Marquer l'erreur dans la DB (pas le statut — sera retenté)
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

  // ── Webhook SycaPay (GET ou POST depuis SycaPay serveurs) ─────────────────
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
    // Initie le paiement + persistance immédiate en pending
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

      // 0. Idempotence : déjà confirmed/credited → retourner immédiatement
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
            console.log(`[payer] ref ${numcommande} déjà pending`);
            // Ne pas relancer checkoutpay — retourner pending pour que Flutter polle
            return json({
              code:            -200,
              message:         "Transaction déjà en attente",
              idempotent:      true,
              transactionId:   tx["provider_transaction_id"],
              status:          "pending",
              statusNormalise: "pending",
              numcommande,
            });
          }
        }
      }

      // 1. Token SycaPay
      const token = await obtenirToken(montant);

      // 2. URL webhook
      const webhookUrl = `${SUPABASE_URL}/functions/v1/sycapay-payment?action=webhook&ref=${encodeURIComponent(numcommande)}`;

      // 3. Payload checkoutpay
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
        urlretour:   webhookUrl, // aussi sur urlretour pour certains opérateurs
      };

      const otp = body["otp"] as string | undefined;
      if (otp) payPayload["otp"] = otp;

      if (operateur.toLowerCase() === "wave") {
        payPayload["pays"]       = "CI";
        payPayload["operateurs"] = "WaveSN";
      }

      // 4. Checkoutpay
      const resultat = await checkoutPay(payPayload);
      const code     = (resultat["code"] as number) ?? -999;
      const txId     = extractTxId(resultat);

      console.log(`[payer] checkoutpay → code=${code} ref=${numcommande} txId=${txId ?? "n/a"}`, JSON.stringify(resultat).substring(0, 200));

      // 5. Persister dans Supabase (async — non bloquant pour la réponse Flutter)
      if (tontineCode) {
        const phoneMasked = telephone.length >= 4
          ? telephone.substring(0, 2) + "****" + telephone.slice(-4)
          : telephone;

        const txStatus = code === 0 ? "confirmed" : (code === -200 ? "pending" : "pending");
        // Note : on persiste même les "failed" comme pending initialement
        // car -1 peut être temporaire (Orange Money). Le polling serveur rectifiera.

        sbFetch("/rest/v1/sycapay_transactions", "POST", {
          tontine_code:            tontineCode,
          type_operation:          typeOp,
          internal_reference:      numcommande,
          sycapay_reference:       numcommande, // même chose côté nous
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
          confirmed_at:            code === 0 ? new Date().toISOString() : null,
        }).catch(async (e: Error) => {
          if (e.message.includes("23505") || e.message.includes("duplicate")) {
            // Conflit unique → update
            await sbPatch(
              "sycapay_transactions",
              `internal_reference=eq.${encodeURIComponent(numcommande)}`,
              {
                provider_transaction_id: txId ?? null,
                status:                  txStatus,
                confirmed_at:            code === 0 ? new Date().toISOString() : null,
              },
            ).catch(e2 => console.error("[payer] update fallback:", e2));
          } else {
            console.error("[payer] persistance:", e.message);
          }
        });
      }

      return json({
        ...resultat,
        code,
        message:         resultat["message"] ?? messageFr(code),
        messageFr:       messageFr(code),
        statusNormalise: code === 0 ? "confirmed" : "pending",
        numcommande,
        transactionId:   txId,
        urlWebhook:      tontineCode
          ? `${SUPABASE_URL}/functions/v1/sycapay-payment?action=webhook&ref=${encodeURIComponent(numcommande)}`
          : undefined,
      });
    }

    // ══════════════════════════════════════════════════════════════════════════
    // ACTION : confirmer_et_crediter
    // Polling serveur-side jusqu'à confirmation, puis crédit DB.
    // Flutter envoie cette action après initierPaiement et attend le résultat.
    // Timeout serveur : 170s (≤ 180s max Supabase Edge Function)
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
          operator:                body["operateur"] as string ?? "",
          status:                  "pending",
          membre_id:               body["membre_id"]       as string ?? null,
          membre_nom:              membreNomIn || null,
          pret_id:                 body["pret_id"]         as string ?? null,
          emprunteur_id:           body["emprunteur_id"]   as string ?? null,
          description:             body["description"]     as string ?? null,
        }).catch(e => console.error("[confirmer] création minimale:", e));

        rows = await sbSelect(
          "sycapay_transactions",
          `internal_reference=eq.${encodeURIComponent(numcommande)}&select=*`,
        );
      }

      // Si déjà credited → retourner succès immédiat
      if (rows.length > 0 && (rows[0]["status"] === "credited" || rows[0]["status"] === "confirmed")) {
        const tx = rows[0];
        if (tx["status"] === "credited") {
          return json({
            ok:              true,
            code:            0,
            statusNormalise: "confirmed",
            message:         "Paiement reçu avec succès. Votre apport a été enregistré.",
            numcommande,
            fromCache:       true,
          });
        }
        // confirmed mais pas credited → créditer maintenant
        const txEnriched = {
          ...tx,
          ...(membreNomIn      ? { membre_nom:     membreNomIn }                                : {}),
          ...(body["pret_id"]  ? { pret_id:        body["pret_id"]       as string }           : {}),
          ...(body["emprunteur_id"] ? { emprunteur_id: body["emprunteur_id"] as string }       : {}),
          ...(body["emprunteur_nom"] ? { emprunteur_nom: body["emprunteur_nom"] as string }    : {}),
        };
        const creditResult = await crediterCoteServeur(txEnriched);
        return json({
          ok:              creditResult.ok,
          code:            creditResult.ok ? 0 : -1,
          statusNormalise: creditResult.ok ? "confirmed" : "failed",
          message:         creditResult.ok
            ? "Paiement reçu avec succès. Votre apport a été enregistré."
            : `Paiement confirmé mais crédit échoué : ${creditResult.message}`,
          numcommande,
        });
      }

      const createdAt = rows.length > 0 ? (rows[0]["created_at"] as string) : new Date().toISOString();
      const dbTransId = rows.length > 0 ? (rows[0]["provider_transaction_id"] as string | undefined) : transId;

      // ── Polling serveur (30 tentatives × 5s = 150s max) ──────────────────
      const MAX_ATTEMPTS  = 30;
      const POLL_INTERVAL = 5_000; // 5 secondes

      let attempts        = 0;
      let lastCode        = -999;
      let lastStatus: NStatus = "unknown";
      let confirmedTxId   = dbTransId ?? transId;

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
          if (fresh[0]["provider_transaction_id"]) confirmedTxId = fresh[0]["provider_transaction_id"] as string;

          if (dbStatus === "credited") {
            return json({
              ok:              true,
              code:            0,
              statusNormalise: "confirmed",
              message:         "Paiement reçu avec succès. Votre apport a été enregistré.",
              numcommande,
              transactionId:   confirmedTxId,
              fromWebhook:     true,
            });
          }
          if (dbStatus === "confirmed") {
            // Le webhook a confirmé → créditer maintenant
            const fullTx = await sbSelect(
              "sycapay_transactions",
              `internal_reference=eq.${encodeURIComponent(numcommande)}&select=*`,
            );
            if (fullTx.length > 0) {
              const creditResult = await crediterCoteServeur({
                ...fullTx[0],
                ...(membreNomIn           ? { membre_nom:     membreNomIn }                                : {}),
                ...(body["pret_id"]       ? { pret_id:        body["pret_id"]       as string }           : {}),
                ...(body["emprunteur_id"] ? { emprunteur_id:  body["emprunteur_id"] as string }           : {}),
                ...(body["emprunteur_nom"]? { emprunteur_nom: body["emprunteur_nom"] as string }          : {}),
              });
              return json({
                ok:              creditResult.ok,
                code:            creditResult.ok ? 0 : -1,
                statusNormalise: "confirmed",
                message:         creditResult.ok
                  ? "Paiement reçu avec succès. Votre apport a été enregistré."
                  : `Confirmé SycaPay mais enregistrement échoué: ${creditResult.message}`,
                numcommande,
                transactionId:   confirmedTxId,
              });
            }
          }
          if (dbStatus === "failed" || dbStatus === "expired") {
            return json({
              ok:              false,
              code:            -1,
              statusNormalise: dbStatus as NStatus,
              message:         dbStatus === "expired"
                ? "Session SycaPay expirée. Veuillez réessayer."
                : "Paiement échoué.",
              numcommande,
            });
          }
        }

        // Appeler GetStatus SycaPay
        try {
          const gs = await getStatusMulti(numcommande, confirmedTxId);
          lastCode   = gs.code;
          lastStatus = normaliserStatut(gs.code, createdAt);
          if (gs.result["transactionId"]) confirmedTxId = extractTxId(gs.result);

          console.log(`[confirmer] Tentative ${attempts}/${MAX_ATTEMPTS} → code=${lastCode} status=${lastStatus}`);

          // Mettre à jour polling_attempts en DB
          await sbPatch(
            "sycapay_transactions",
            `internal_reference=eq.${encodeURIComponent(numcommande)}`,
            {
              polling_attempts:        attempts,
              provider_transaction_id: confirmedTxId ?? dbTransId ?? null,
            },
          ).catch(() => {});

          if (lastStatus === "confirmed") {
            // Confirmer dans DB
            await sbPatch(
              "sycapay_transactions",
              `internal_reference=eq.${encodeURIComponent(numcommande)}`,
              {
                status:                  "confirmed",
                confirmed_at:            new Date().toISOString(),
                provider_transaction_id: confirmedTxId ?? null,
              },
            ).catch(() => {});

            // Récupérer la transaction complète pour crédit
            const fullTx = await sbSelect(
              "sycapay_transactions",
              `internal_reference=eq.${encodeURIComponent(numcommande)}&select=*`,
            );
            if (fullTx.length > 0) {
              const creditResult = await crediterCoteServeur({
                ...fullTx[0],
                ...(membreNomIn           ? { membre_nom:     membreNomIn }                                : {}),
                ...(body["pret_id"]       ? { pret_id:        body["pret_id"]       as string }           : {}),
                ...(body["emprunteur_id"] ? { emprunteur_id:  body["emprunteur_id"] as string }           : {}),
                ...(body["emprunteur_nom"]? { emprunteur_nom: body["emprunteur_nom"] as string }          : {}),
              });
              return json({
                ok:              creditResult.ok,
                code:            creditResult.ok ? 0 : -1,
                statusNormalise: "confirmed",
                message:         creditResult.ok
                  ? "Paiement reçu avec succès. Votre apport a été enregistré."
                  : `Confirmé SycaPay mais enregistrement échoué: ${creditResult.message}`,
                numcommande,
                transactionId:   confirmedTxId,
              });
            }
          }

          if (lastStatus === "expired") {
            await sbPatch(
              "sycapay_transactions",
              `internal_reference=eq.${encodeURIComponent(numcommande)}`,
              { status: "expired" },
            ).catch(() => {});
            return json({
              ok:              false,
              code:            -8,
              statusNormalise: "expired",
              message:         "Session SycaPay expirée. Veuillez réessayer.",
              numcommande,
            });
          }

          // "failed" DÉFINITIF (solde insuf, OTP incorrect) — pas les -1 transitoires
          if (lastStatus === "failed" && [-3, -5, -7, -14].includes(lastCode)) {
            await sbPatch(
              "sycapay_transactions",
              `internal_reference=eq.${encodeURIComponent(numcommande)}`,
              { status: "failed", error_message: messageFr(lastCode) },
            ).catch(() => {});
            return json({
              ok:              false,
              code:            lastCode,
              statusNormalise: "failed",
              message:         messageFr(lastCode),
              numcommande,
            });
          }
          // -1, -200, -9, unknown → continuer à poller

        } catch (e) {
          console.error(`[confirmer] Tentative ${attempts} erreur GetStatus:`, e);
          // Erreur réseau transitoire → continuer
        }
      }

      // Timeout 150s atteint → retourner pending (Flutter affichera le bouton Vérifier)
      return json({
        ok:              false,
        code:            -200,
        statusNormalise: "pending",
        message:         "Délai de confirmation dépassé. Utilisez le bouton \"Vérifier mon paiement\".",
        numcommande,
        transactionId:   confirmedTxId,
        timeout:         true,
      });
    }

    // ══════════════════════════════════════════════════════════════════════════
    // ACTION : statut
    // Vérification ponctuelle (utilisé par le bouton "Vérifier mon paiement")
    // ══════════════════════════════════════════════════════════════════════════
    if (action === "statut") {
      const numcommande = body["numcommande"]  as string | undefined;
      const transId     = body["transactionId"] as string | undefined;
      const tontineCode = body["tontine_code"] as string | undefined;

      if (!numcommande && !transId) {
        return json({ erreur: true, code: -400, message: "numcommande ou transactionId requis" }, 400);
      }

      // 1. Chercher dans Supabase
      let dbTx: Record<string, unknown> | null = null;
      if (numcommande) {
        const rows = await sbSelect(
          "sycapay_transactions",
          `internal_reference=eq.${encodeURIComponent(numcommande)}&select=*`,
        );
        if (rows.length > 0) dbTx = rows[0];
      }

      // Cache hit : déjà credited/confirmed
      if (dbTx && (dbTx["status"] === "credited" || dbTx["status"] === "confirmed")) {
        const shouldCredit = dbTx["status"] === "confirmed";
        if (shouldCredit) {
          const creditResult = await crediterCoteServeur(dbTx);
          return json({
            code:            0,
            statusNormalise: "confirmed",
            message:         creditResult.ok
              ? "Paiement reçu avec succès. Votre apport a été enregistré."
              : "Paiement confirmé. Enregistrement en cours.",
            numcommande,
            fromCache:       true,
          });
        }
        return json({
          ok:              true,  // ✅ FIX: Flutter lit estSucces = (confirmed && ok) → doit être true
          code:            0,
          message:         "Paiement reçu avec succès. Votre cotisation a été enregistrée.",
          statusNormalise: "confirmed",
          numcommande,
          fromCache:       true,
        });
      }

      const createdAt = dbTx ? (dbTx["created_at"] as string) : undefined;
      const dbTransId = dbTx ? (dbTx["provider_transaction_id"] as string | undefined) : transId;

      // 2. GetStatus SycaPay multi-stratégie
      const gs = await getStatusMulti(numcommande, dbTransId ?? transId);
      const lastStatus = normaliserStatut(gs.code, createdAt);
      const newTxId    = extractTxId(gs.result) ?? dbTransId ?? transId;

      // 3. Mettre à jour DB
      if (dbTx && numcommande) {
        const updateData: Record<string, unknown> = {
          polling_attempts: ((dbTx["polling_attempts"] as number) ?? 0) + 1,
        };
        if (newTxId) updateData["provider_transaction_id"] = newTxId;

        if (lastStatus === "confirmed") {
          updateData["status"]       = "confirmed";
          updateData["confirmed_at"] = new Date().toISOString();
        } else if (lastStatus === "failed" && ![-1, -9, -200, -250, -999].includes(gs.code)) {
          updateData["status"]        = "failed";
          updateData["error_message"] = messageFr(gs.code);
        } else if (lastStatus === "expired") {
          updateData["status"] = "expired";
        }

        await sbPatch(
          "sycapay_transactions",
          `internal_reference=eq.${encodeURIComponent(numcommande)}`,
          updateData,
        ).catch(e => console.error("[statut] update:", e));
      }

      // 4. Si confirmé → créditer
      if (lastStatus === "confirmed" && dbTx) {
        const freshTx = { ...dbTx, status: "confirmed", provider_transaction_id: newTxId };
        const creditResult = await crediterCoteServeur(freshTx);
        // ok:true OBLIGATOIRE pour que Flutter détecte estSucces via fromJson
        return json({
          ok:              creditResult.ok,
          code:            0,
          statusNormalise: "confirmed",
          message:         creditResult.ok
            ? "Paiement reçu avec succès. Votre apport a été enregistré."
            : "Paiement confirmé. Enregistrement en cours.",
          numcommande,
          transactionId:   newTxId,
          fromCache:       true,
        });
      }

      return json({
        ok:              false,
        code:            gs.code,
        message:         messageFr(gs.code),
        statusNormalise: lastStatus,
        numcommande,
        transactionId:   newTxId,
      });
    }

    // ══════════════════════════════════════════════════════════════════════════
    // ACTION : verifier_ref
    // ══════════════════════════════════════════════════════════════════════════
    if (action === "verifier_ref") {
      const numcommande = body["numcommande"] as string;
      if (!numcommande) return json({ erreur: true, message: "numcommande requis" }, 400);

      const rows = await sbSelect(
        "sycapay_transactions",
        `internal_reference=eq.${encodeURIComponent(numcommande)}&select=*`,
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
        description:     tx["description"],
        type_operation:  tx["type_operation"],
      });
    }

    // ══════════════════════════════════════════════════════════════════════════
    // ACTION : marquer_credite (appelé par Flutter après écriture locale réussie)
    // ══════════════════════════════════════════════════════════════════════════
    if (action === "marquer_credite") {
      const numcommande = body["numcommande"] as string;
      if (!numcommande) return json({ erreur: true, message: "numcommande requis" }, 400);

      const rows = await sbSelect(
        "sycapay_transactions",
        `internal_reference=eq.${encodeURIComponent(numcommande)}&select=id,status`,
      );

      if (rows.length === 0) return json({ ok: false, message: "Transaction introuvable" });
      const tx = rows[0];
      if (tx["status"] === "credited") return json({ ok: false, dejaCredite: true, message: "Déjà crédité" });

      await sbPatch(
        "sycapay_transactions",
        `internal_reference=eq.${encodeURIComponent(numcommande)}`,
        { status: "credited", credited_at: new Date().toISOString() },
      );
      return json({ ok: true, message: "Transaction marquée comme créditée" });
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
// SycaPay POSTe sur urlnotif={SUPABASE_URL}/functions/v1/sycapay-payment?action=webhook&ref={numcommande}
// ─────────────────────────────────────────────────────────────────────────────

async function handleWebhook(req: Request): Promise<Response> {
  const url         = new URL(req.url);
  // SycaPay peut passer la ref via ?ref=... OU ?numcommande=... OU ?order_id=...
  const numcommande = url.searchParams.get("ref")
                   ?? url.searchParams.get("numcommande")
                   ?? url.searchParams.get("order_id")
                   ?? "";

  let payload: Record<string, unknown> = {};
  try {
    if (req.method === "POST") {
      const text = await req.text();
      try { payload = JSON.parse(text); } catch {
        // Certains opérateurs envoient application/x-www-form-urlencoded
        const params = new URLSearchParams(text);
        params.forEach((v, k) => { payload[k] = v; });
      }
    } else {
      // GET : SycaPay peut passer le statut dans l'URL
      url.searchParams.forEach((v, k) => { payload[k] = v; });
    }
  } catch { /* payload vide */ }

  console.log(`[webhook] Reçu method=${req.method} ref=${numcommande || "AUCUN"}`, JSON.stringify(payload).substring(0, 400));

  // Si pas de ref dans l'URL, chercher dans le payload
  const refEffective = numcommande
    || (payload["ref"] as string)
    || (payload["numcommande"] as string)
    || (payload["order_id"] as string)
    || "";

  if (!refEffective) {
    console.warn("[webhook] Pas de numcommande dans l'URL ni le payload → HTTP 200 quand même");
    return new Response("OK", { status: 200 });
  }

  // Rebind numcommande avec la ref effective
  const numcommandeFinal = refEffective;

  // Récupérer la transaction (utilise numcommandeFinal — ref enrichie du payload)
  const rows = await sbSelect(
    "sycapay_transactions",
    `internal_reference=eq.${encodeURIComponent(numcommandeFinal)}&select=*`,
  ).catch(() => [] as Array<Record<string, unknown>>);

  if (rows.length === 0) {
    console.warn(`[webhook] Transaction introuvable: ${numcommandeFinal} → HTTP 200 quand même`);
    return new Response("OK", { status: 200 });
  }

  const tx = rows[0];

  // Idempotence
  if (tx["status"] === "credited") {
    console.log(`[webhook] ${numcommandeFinal} déjà crédité → skip`);
    return new Response("OK", { status: 200 });
  }

  // Extraire le code du payload webhook
  // SycaPay peut envoyer: code=0, statut="success", status="SUCCESS", etc.
  let webhookCode: number = -1;
  if (typeof payload["code"] === "number") {
    webhookCode = payload["code"] as number;
  } else if (
    payload["statut"] === "success"  || payload["status"] === "success" ||
    payload["statut"] === "SUCCESS"  || payload["status"] === "SUCCESS" ||
    payload["statut"] === "completed"|| payload["status"] === "completed" ||
    payload["payment_status"] === "success" || payload["payment_status"] === "SUCCESS"
  ) {
    webhookCode = 0;
  } else if (
    payload["statut"] === "failed"   || payload["status"] === "failed" ||
    payload["statut"] === "FAILED"   || payload["status"] === "FAILED"
  ) {
    webhookCode = -1; // sera traité comme pending si < 10min
  }

  // Si payload quasi-vide (GET sans body ou body vide) → appeler GetStatus pour vrai statut
  const payloadSignificant = Object.keys(payload).filter(k => !['action','ref','numcommande'].includes(k)).length > 0;
  let txId = extractTxId(payload) ?? (tx["provider_transaction_id"] as string | undefined);

  if (!payloadSignificant && webhookCode === -1) {
    console.log(`[webhook] Payload vide/GET → GetStatus pour ${numcommandeFinal}`);
    try {
      const gs = await getStatusMulti(numcommandeFinal, txId);
      webhookCode = gs.code;
      const gsTxId = extractTxId(gs.result);
      if (gsTxId) txId = gsTxId;
      console.log(`[webhook] GetStatus fallback → code=${webhookCode} txId=${txId ?? "n/a"}`);
    } catch (e) {
      console.error("[webhook] GetStatus fallback échoué:", e);
    }
  }

  const webhookStatus = normaliserStatut(webhookCode, tx["created_at"] as string);

  console.log(`[webhook] code=${webhookCode} status=${webhookStatus} txId=${txId ?? "n/a"} numcommande=${numcommandeFinal}`);

  // Mettre à jour DB avec infos webhook
  const updateData: Record<string, unknown> = {
    webhook_received_at: new Date().toISOString(),
    // Ne pas stocker le payload brut pour éviter les gros blobs
    // webhook_payload: payload, — désactivé, infos dans les logs
  };
  if (txId) updateData["provider_transaction_id"] = txId;

  if (webhookStatus === "confirmed") {
    updateData["status"]       = "confirmed";
    updateData["confirmed_at"] = new Date().toISOString();
  } else if (webhookStatus === "failed" && ![-1, -9, -200, -250, -999].includes(webhookCode)) {
    // Seulement les échecs définitifs (pas les temporaires)
    updateData["status"]        = "failed";
    updateData["error_message"] = messageFr(webhookCode);
  } else if (webhookStatus === "expired") {
    updateData["status"] = "expired";
  }
  // pending / unknown → ne pas écraser le statut DB, juste webhook_received_at

  await sbPatch(
    "sycapay_transactions",
    `internal_reference=eq.${encodeURIComponent(numcommandeFinal)}`,
    updateData,
  ).catch(e => console.error("[webhook] update DB:", e));

  // Si confirmé → créditer côté serveur immédiatement
  if (webhookStatus === "confirmed") {
    const freshTx = { ...tx, ...updateData };
    const creditResult = await crediterCoteServeur(freshTx);
    console.log(`[webhook] ✅ Crédit résultat: ${creditResult.message}`);
  } else {
    console.log(`[webhook] Status=${webhookStatus} → pas de crédit (code=${webhookCode})`);
  }

  // TOUJOURS retourner HTTP 200 pour que SycaPay ne re-tente pas indéfiniment
  return new Response("OK", { status: 200 });
}
