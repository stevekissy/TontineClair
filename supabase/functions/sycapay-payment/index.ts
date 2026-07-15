/**
 * Supabase Edge Function : sycapay-payment  (v3 — workflow robuste)
 *
 * Architecture sécurisée :
 *   Flutter → Edge Function → SycaPay API  (clés jamais exposées côté client)
 *
 * Actions :
 *   "payer"          : login + checkoutpay + persistance transaction pending
 *   "statut"         : GetStatus par numcommande (pas transactionId) + mise à jour DB
 *   "verifier_ref"   : cherche une transaction par référence interne dans Supabase
 *   "webhook"        : reçoit callback SycaPay → crédite la tontine (idempotent)
 *
 * Variables d'environnement Supabase :
 *   SYCAPAY_MARCHAND_ID  = C_6920BF93D3B14
 *   SYCAPAY_API_KEY      = pk_syca_d070448b386b84b1fffec1f925419278f41be0f7
 *   SYCAPAY_SECRET_KEY   = sk_syca_1915bd8a6c91b6d3c39edd35b26f68dce4caa7f8
 *   SUPABASE_URL         = (auto-injecté par Supabase)
 *   SUPABASE_SERVICE_ROLE_KEY = (auto-injecté par Supabase)
 */

const SYCAPAY_BASE  = "https://dev.sycapay.com/";
const MARCHAND_ID   = Deno.env.get("SYCAPAY_MARCHAND_ID")  ?? "";
const API_KEY       = Deno.env.get("SYCAPAY_API_KEY")      ?? "";
const SECRET_KEY    = Deno.env.get("SYCAPAY_SECRET_KEY")   ?? "";
const SUPABASE_URL  = Deno.env.get("SUPABASE_URL")         ?? "";
const SERVICE_KEY   = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

// CORS pour Flutter Web
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

// ── Client Supabase (service role — accès complet sans RLS) ──────────────────

async function supabaseFetch(
  path: string,
  method: string,
  body?: unknown,
): Promise<unknown> {
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

async function supabaseRpc(fn: string, params: Record<string, unknown>): Promise<unknown> {
  return supabaseFetch(`/rest/v1/rpc/${fn}`, "POST", params);
}

async function supabaseSelect(table: string, filter: string): Promise<unknown[]> {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/${table}?${filter}`, {
    headers: {
      "apikey":        SERVICE_KEY,
      "Authorization": `Bearer ${SERVICE_KEY}`,
    },
    signal: AbortSignal.timeout(10_000),
  });
  if (!res.ok) return [];
  return res.json() as Promise<unknown[]>;
}

async function supabaseUpdate(
  table: string,
  filter: string,
  data: Record<string, unknown>,
): Promise<void> {
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

// ── Auth SycaPay (token valide ~40s) ─────────────────────────────────────────

async function obtenirToken(montant: string): Promise<string> {
  const res = await fetch(`${SYCAPAY_BASE}login.php`, {
    method: "POST",
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

// ── Appel checkoutpay.php ─────────────────────────────────────────────────────

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

// ── Appel GetStatus.php ───────────────────────────────────────────────────────
// SycaPay GetStatus accepte le numcommande OU le transactionId selon les cas.
// On essaie les deux pour maximiser les chances de retrouver la transaction.

async function getStatus(ref: string): Promise<Record<string, unknown>> {
  const res = await fetch(`${SYCAPAY_BASE}GetStatus.php`, {
    method:  "POST",
    headers: { "Content-Type": "application/json" },
    body:    JSON.stringify({ ref }),
    signal:  AbortSignal.timeout(20_000),
  });
  if (!res.ok) throw new Error(`GetStatus HTTP ${res.status}`);
  return res.json() as Promise<Record<string, unknown>>;
}

// ── Normaliser le code SycaPay en statut lisible ──────────────────────────────
// Codes confirmés de l'API SycaPay :
//   0    = succès (paiement initié ou confirmé)
//   -1   = échec général
//   -3   = solde insuffisant
//   -4   = service indisponible
//   -5   = OTP incorrect
//   -7   = numéro invalide
//   -8   = session expirée
//   -9   = statut pas encore disponible (retry)
//   -14  = erreur auth
//   -200 = en attente (pending)
//   -250 = référence introuvable
//   -400 = paramètre manquant
//   -500 = accès refusé

type NormalizedStatus = "confirmed" | "pending" | "failed" | "expired" | "unknown";

function normaliserStatut(code: number): NormalizedStatus {
  if (code === 0)    return "confirmed";
  if (code === -200) return "pending";
  if (code === -9)   return "pending";   // statut pas encore dispo → retry
  if (code === -8)   return "expired";   // session expirée
  if (code === -250) return "unknown";   // référence introuvable (retry avec autre ref)
  return "failed";
}

function messageFr(code: number): string {
  switch (code) {
    case 0:    return "Paiement confirmé.";
    case -1:   return "Paiement échoué. Réessayez.";
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
    default:   return `Erreur SycaPay (code ${code}).`;
  }
}

// ── Handler principal ─────────────────────────────────────────────────────────

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: CORS });
  }

  // ── Webhook SycaPay (GET ou POST depuis SycaPay) ──────────────────────────
  // SycaPay appelle urlnotif avec les données de confirmation
  const url = new URL(req.url);
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
    // ────────────────────────────────────────────────────────────────────────
    // ACTION : payer
    // ────────────────────────────────────────────────────────────────────────
    if (action === "payer") {
      const telephone   = body["telephone"]   as string;
      const montant     = body["montant"]     as string;
      const numcommande = body["numcommande"] as string;
      const operateur   = (body["operateur"]  as string) ?? "";
      const tontineCode = (body["tontine_code"] as string) ?? "";
      const typeOp      = (body["type_operation"] as string) ?? "cotisation";
      const membreId    = (body["membre_id"] as string | undefined);
      const description = (body["description"] as string | undefined);

      if (!telephone || !montant || !numcommande) {
        return json({ erreur: true, code: -400, message: "Paramètres manquants" }, 400);
      }

      // 0. Vérifier idempotence : si déjà confirmed/credited → refuser
      if (tontineCode && numcommande) {
        const existing = await supabaseSelect(
          "sycapay_transactions",
          `internal_reference=eq.${encodeURIComponent(numcommande)}&select=id,status`,
        ) as Array<{ id: string; status: string }>;

        if (existing.length > 0) {
          const tx = existing[0];
          if (tx.status === "credited" || tx.status === "confirmed") {
            console.log(`[payer] Idempotence: ref ${numcommande} déjà ${tx.status}`);
            return json({
              code: 0,
              message: "Transaction déjà confirmée",
              idempotent: true,
              transactionId: tx.id,
              status: tx.status,
            });
          }
          // pending → on peut vérifier son statut mais pas relancer le paiement
          if (tx.status === "pending") {
            console.log(`[payer] Ref ${numcommande} déjà pending — vérification statut`);
            // On continue pour relancer le checkout si nécessaire
          }
        }
      }

      // 1. Obtenir le token SycaPay
      const token = await obtenirToken(montant);

      // 2. URL de webhook
      const webhookUrl = `${SUPABASE_URL}/functions/v1/sycapay-payment?action=webhook&ref=${encodeURIComponent(numcommande)}`;

      // 3. Payload checkout
      const payPayload: Record<string, unknown> = {
        marchandid:  MARCHAND_ID,
        token,
        telephone,
        montant,
        currency:    "XOF",
        numcommande,
        name:        body["name"]  ?? "",
        pname:       body["pname"] ?? "",
        urlnotif:    webhookUrl,
      };

      const otp = body["otp"] as string | undefined;
      if (otp) payPayload["otp"] = otp;

      if (operateur.toLowerCase() === "wave") {
        payPayload["pays"]       = "CI";
        payPayload["operateurs"] = "WaveSN";
      }

      // 4. Appel checkoutpay.php
      const resultat = await checkoutPay(payPayload) as Record<string, unknown>;
      const code     = (resultat["code"] as number) ?? -999;

      console.log(`[payer] checkoutpay → code=${code} ref=${numcommande}`, JSON.stringify(resultat));

      // 5. Persister la transaction dans Supabase (si tontineCode fourni)
      if (tontineCode) {
        const phoneMasked = telephone.length >= 4
          ? telephone.substring(0, 2) + "****" + telephone.slice(-4)
          : telephone;

        try {
          const txId = resultat["transactionId"] as string
                    ?? resultat["transactionID"] as string
                    ?? resultat["orderId"] as string
                    ?? null;

          // Créer ou récupérer la transaction
          await supabaseFetch("/rest/v1/sycapay_transactions", "POST", {
            tontine_code:           tontineCode,
            type_operation:         typeOp,
            internal_reference:     numcommande,
            provider_transaction_id: txId,
            phone_number_masked:    phoneMasked,
            amount:                 parseInt(montant, 10),
            currency:               "XOF",
            operator:               operateur,
            status:                 code === 0 ? "confirmed" : (code === -200 ? "pending" : "failed"),
            membre_id:              membreId ?? null,
            description:            description ?? null,
            confirmed_at:           code === 0 ? new Date().toISOString() : null,
          }).catch(async (e: Error) => {
            // Si conflit unique → update
            if (e.message.includes("23505") || e.message.includes("duplicate")) {
              await supabaseUpdate(
                "sycapay_transactions",
                `internal_reference=eq.${encodeURIComponent(numcommande)}`,
                {
                  provider_transaction_id: txId,
                  status: code === 0 ? "confirmed" : (code === -200 ? "pending" : "failed"),
                  confirmed_at: code === 0 ? new Date().toISOString() : null,
                },
              );
            } else {
              console.error("[payer] Erreur persistance:", e.message);
            }
          });
        } catch (pe) {
          console.error("[payer] Persistance non critique:", pe);
          // Ne pas bloquer le retour Flutter
        }
      }

      // 6. Retourner le résultat SycaPay enrichi
      return json({
        ...resultat,
        code,
        message:         resultat["message"] ?? messageFr(code),
        messageFr:       messageFr(code),
        statusNormalise: normaliserStatut(code),
        numcommande,      // ← CRITIQUE : Flutter doit garder cette ref pour le polling
      });
    }

    // ────────────────────────────────────────────────────────────────────────
    // ACTION : statut
    // Vérifie le statut par numcommande (interne) ET transactionId (SycaPay)
    // Met à jour la DB et retourne le résultat normalisé
    // ────────────────────────────────────────────────────────────────────────
    if (action === "statut") {
      const numcommande = body["numcommande"] as string | undefined;
      const transId     = body["transactionId"] as string | undefined;
      const tontineCode = body["tontine_code"] as string | undefined;

      if (!numcommande && !transId) {
        return json({ erreur: true, code: -400, message: "numcommande ou transactionId requis" }, 400);
      }

      // 1. Chercher dans Supabase d'abord (source de vérité)
      let dbTx: Record<string, unknown> | null = null;
      if (numcommande && tontineCode) {
        const rows = await supabaseSelect(
          "sycapay_transactions",
          `internal_reference=eq.${encodeURIComponent(numcommande)}&select=*`,
        ) as Array<Record<string, unknown>>;
        if (rows.length > 0) dbTx = rows[0];
      }

      // Si déjà crédité dans notre DB → retourner directement sans appeler SycaPay
      if (dbTx && (dbTx["status"] === "credited" || dbTx["status"] === "confirmed")) {
        return json({
          code:            0,
          message:         "Paiement confirmé",
          messageFr:       "Paiement confirmé.",
          statusNormalise: dbTx["status"] === "credited" ? "credited" : "confirmed",
          transactionId:   dbTx["provider_transaction_id"],
          numcommande,
          fromCache:       true,
        });
      }

      // 2. Appeler GetStatus avec numcommande (ref principale)
      let sycaresult: Record<string, unknown> = {};
      let sycastatus: NormalizedStatus = "unknown";
      let syscacode = -999;

      // Essai 1 : avec numcommande
      if (numcommande) {
        try {
          const r = await getStatus(numcommande);
          syscacode  = (r["code"] as number) ?? -999;
          sycastatus = normaliserStatut(syscacode);
          sycaresult = r;
          console.log(`[statut] GetStatus(numcommande=${numcommande}) → code=${syscacode}`);
        } catch (e) {
          console.error("[statut] GetStatus par numcommande échoué:", e);
        }
      }

      // Essai 2 : avec transactionId si numcommande a retourné unknown/-250
      if ((sycastatus === "unknown" || syscacode === -250) && transId) {
        try {
          const r = await getStatus(transId);
          syscacode  = (r["code"] as number) ?? syscacode;
          sycastatus = normaliserStatut(syscacode);
          sycaresult = r;
          console.log(`[statut] GetStatus(transId=${transId}) → code=${syscacode}`);
        } catch (e) {
          console.error("[statut] GetStatus par transId échoué:", e);
        }
      }

      // 3. Mettre à jour la DB avec le nouveau statut
      if (dbTx && numcommande) {
        const updateData: Record<string, unknown> = {
          polling_attempts: ((dbTx["polling_attempts"] as number) ?? 0) + 1,
        };
        if (sycastatus === "confirmed") {
          updateData["status"]       = "confirmed";
          updateData["confirmed_at"] = new Date().toISOString();
          const tid = sycaresult["transactionId"] as string
                   ?? sycaresult["transactionID"] as string;
          if (tid) updateData["provider_transaction_id"] = tid;
        } else if (sycastatus === "failed") {
          updateData["status"]        = "failed";
          updateData["error_message"] = messageFr(syscacode);
        } else if (sycastatus === "expired") {
          updateData["status"] = "expired";
        }

        await supabaseUpdate(
          "sycapay_transactions",
          `internal_reference=eq.${encodeURIComponent(numcommande)}`,
          updateData,
        ).catch(e => console.error("[statut] Update DB:", e));
      }

      return json({
        ...sycaresult,
        code:            syscacode,
        message:         sycaresult["message"] ?? messageFr(syscacode),
        messageFr:       messageFr(syscacode),
        statusNormalise: sycastatus,
        numcommande,
      });
    }

    // ────────────────────────────────────────────────────────────────────────
    // ACTION : verifier_ref
    // Cherche une transaction par référence interne dans Supabase
    // Utilisé au redémarrage de l'app pour retrouver les pending
    // ────────────────────────────────────────────────────────────────────────
    if (action === "verifier_ref") {
      const numcommande = body["numcommande"] as string;
      if (!numcommande) {
        return json({ erreur: true, message: "numcommande requis" }, 400);
      }

      const rows = await supabaseSelect(
        "sycapay_transactions",
        `internal_reference=eq.${encodeURIComponent(numcommande)}&select=*`,
      ) as Array<Record<string, unknown>>;

      if (rows.length === 0) {
        return json({ trouve: false, status: "inexistant" });
      }

      const tx = rows[0];
      return json({
        trouve:          true,
        status:          tx["status"],
        statusNormalise: tx["status"] === "credited" || tx["status"] === "confirmed"
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

    // ────────────────────────────────────────────────────────────────────────
    // ACTION : marquer_credite
    // Appelé par Flutter après avoir réussi l'écriture Supabase (ecrireTontineSansPIN)
    // Marque la transaction comme 'credited' pour éviter le double crédit
    // ────────────────────────────────────────────────────────────────────────
    if (action === "marquer_credite") {
      const numcommande = body["numcommande"] as string;
      if (!numcommande) {
        return json({ erreur: true, message: "numcommande requis" }, 400);
      }

      // Vérifier que la transaction n'est pas déjà créditée
      const rows = await supabaseSelect(
        "sycapay_transactions",
        `internal_reference=eq.${encodeURIComponent(numcommande)}&select=id,status`,
      ) as Array<{ id: string; status: string }>;

      if (rows.length === 0) {
        return json({ ok: false, message: "Transaction introuvable" });
      }

      const tx = rows[0];
      if (tx.status === "credited") {
        return json({ ok: false, dejaCredite: true, message: "Déjà crédité" });
      }

      await supabaseUpdate(
        "sycapay_transactions",
        `internal_reference=eq.${encodeURIComponent(numcommande)}`,
        {
          status:     "credited",
          credited_at: new Date().toISOString(),
        },
      );

      return json({ ok: true, message: "Transaction marquée comme créditée" });
    }

    // ────────────────────────────────────────────────────────────────────────
    // ACTION inconnue
    // ────────────────────────────────────────────────────────────────────────
    return json({ erreur: true, message: `Action inconnue: ${action}` }, 400);

  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    console.error("[sycapay-payment] Erreur critique:", msg);
    return json({ erreur: true, code: -504, message: msg }, 500);
  }
});

// ── Handler Webhook SycaPay ───────────────────────────────────────────────────
// SycaPay POSTe sur urlnotif={SUPABASE_URL}/functions/v1/sycapay-payment?action=webhook&ref={numcommande}
// avec le payload de confirmation.

async function handleWebhook(req: Request): Promise<Response> {
  const url         = new URL(req.url);
  const numcommande = url.searchParams.get("ref") ?? "";

  let payload: Record<string, unknown> = {};
  try {
    if (req.method === "POST") {
      payload = await req.json();
    } else {
      // Certains providers envoient en GET avec query params
      url.searchParams.forEach((v, k) => { payload[k] = v; });
    }
  } catch {
    // payload vide — on continue avec numcommande depuis query string
  }

  console.log(`[webhook] Reçu pour ref=${numcommande}`, JSON.stringify(payload));

  if (!numcommande) {
    console.warn("[webhook] Pas de numcommande dans l'URL");
    return new Response("OK", { status: 200 }); // Toujours 200 pour SycaPay
  }

  // Récupérer la transaction dans Supabase
  const rows = await supabaseSelect(
    "sycapay_transactions",
    `internal_reference=eq.${encodeURIComponent(numcommande)}&select=*`,
  ).catch(() => [] as unknown[]) as Array<Record<string, unknown>>;

  if (rows.length === 0) {
    console.warn(`[webhook] Transaction introuvable pour ref=${numcommande}`);
    return new Response("OK", { status: 200 });
  }

  const tx = rows[0];

  // Idempotence : si déjà crédité → ignorer
  if (tx["status"] === "credited") {
    console.log(`[webhook] Transaction ${numcommande} déjà créditée → ignoré`);
    return new Response("OK", { status: 200 });
  }

  // Extraire le code du payload webhook
  const webhookCode = (payload["code"] as number)
                   ?? (payload["statut"] === "success" ? 0 : -1);
  const webhookStatus = normaliserStatut(webhookCode);
  const transId = payload["transactionId"] as string
               ?? payload["transactionID"] as string
               ?? payload["ref"] as string;

  console.log(`[webhook] code=${webhookCode} status=${webhookStatus} transId=${transId}`);

  // Mettre à jour la DB
  const updateData: Record<string, unknown> = {
    webhook_received_at: new Date().toISOString(),
    webhook_payload:     payload,
  };

  if (webhookStatus === "confirmed") {
    updateData["status"]       = "confirmed";
    updateData["confirmed_at"] = new Date().toISOString();
    if (transId) updateData["provider_transaction_id"] = transId;
  } else if (webhookStatus === "failed") {
    updateData["status"]        = "failed";
    updateData["error_message"] = messageFr(webhookCode);
  } else if (webhookStatus === "expired") {
    updateData["status"] = "expired";
  }

  await supabaseUpdate(
    "sycapay_transactions",
    `internal_reference=eq.${encodeURIComponent(numcommande)}`,
    updateData,
  ).catch(e => console.error("[webhook] Update DB:", e));

  // Note : Le crédit réel de la tontine se fait côté Flutter lors du polling.
  // Le webhook sert uniquement à mettre à jour le statut dans la DB,
  // que Flutter détectera lors de son prochain polling.
  // Cela évite de dupliquer la logique de crédit dans l'Edge Function.

  return new Response("OK", { status: 200 });
}
