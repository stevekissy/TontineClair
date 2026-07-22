// ═══════════════════════════════════════════════════════════════════════════════
// blockchain-tx  —  Edge Function TontineClair Web2+Web3
// Phase 1 : journal blockchain + ancrage Polygon Amoy (testnet)
//
// Réseau  : Polygon Amoy (chainId 80002) via Alchemy RPC
// Token   : USDT ERC-20 sur Polygon
// Sécurité: clé privée wallet admin dans Supabase Secrets UNIQUEMENT
//           utilisateurs TontineClair ne voient JAMAIS la blockchain
//
// Actions disponibles :
//   enregistrer_operation  — crée une entrée blockchain_journal (async, non-bloquant)
//   verifier_tx            — vérifie le statut d'une TX on-chain
//   stats_journal          — statistiques globales du journal
//   lire_journal           — liste filtrée du journal
//   signer_payload         — HMAC-SHA256 d'un payload (audit)
//   taux_usdt              — taux de conversion XOF/USDT actuel
// ═══════════════════════════════════════════════════════════════════════════════

// ── Secrets Supabase (jamais exposés côté client) ────────────────────────────
const SUPABASE_URL   = Deno.env.get("SUPABASE_URL")              ?? "";
const SERVICE_KEY    = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const ALCHEMY_API    = Deno.env.get("ALCHEMY_POLYGON_AMOY_URL")  ?? "";
// Clé de signature HMAC pour le journal (différente de la clé wallet)
const JOURNAL_SECRET = Deno.env.get("BLOCKCHAIN_JOURNAL_SECRET") ?? "tc-journal-secret-2025";

// ── Configuration réseau ─────────────────────────────────────────────────────
const NETWORK = {
  name      : "polygon_amoy",
  chainId   : "0x13882",          // 80002 en hex
  rpcFallback: "https://rpc-amoy.polygon.technology",
  explorer  : "https://amoy.polygonscan.com/tx/",
  usdtAddr  : "0x41E94Eb019C0762f9Bfcf9Fb1E58725BfB0e7582", // USDT mock sur Amoy
};

const CORS = {
  "Access-Control-Allow-Origin" : "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

// ── Helpers ──────────────────────────────────────────────────────────────────
function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

function sbHeaders(): Record<string, string> {
  return {
    "Content-Type" : "application/json",
    "apikey"       : SERVICE_KEY,
    "Authorization": `Bearer ${SERVICE_KEY}`,
    "Prefer"       : "return=representation",
  };
}

async function sbFetch(path: string, method: string, body?: unknown): Promise<unknown> {
  const res = await fetch(`${SUPABASE_URL}${path}`, {
    method,
    headers: sbHeaders(),
    body   : body ? JSON.stringify(body) : undefined,
  });
  if (!res.ok) {
    const err = await res.text();
    throw new Error(`Supabase ${method} ${path} → ${res.status}: ${err}`);
  }
  return res.json().catch(() => ({}));
}

// ── Signature HMAC-SHA256 ────────────────────────────────────────────────────
async function hmacSha256(secret: string, payload: string): Promise<string> {
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw", encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false, ["sign"]
  );
  const sig = await crypto.subtle.sign("HMAC", key, encoder.encode(payload));
  return Array.from(new Uint8Array(sig)).map(b => b.toString(16).padStart(2, "0")).join("");
}

// ── Hash SHA-256 d'un payload ────────────────────────────────────────────────
async function sha256(data: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(data));
  return Array.from(new Uint8Array(buf)).map(b => b.toString(16).padStart(2, "0")).join("");
}

// ── Appel RPC Polygon (JSON-RPC 2.0) ────────────────────────────────────────
async function polygonRpc(method: string, params: unknown[]): Promise<unknown> {
  const rpcUrl = ALCHEMY_API || NETWORK.rpcFallback;
  const res = await fetch(rpcUrl, {
    method : "POST",
    headers: { "Content-Type": "application/json" },
    body   : JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
  });
  const data = await res.json() as { result?: unknown; error?: { message: string } };
  if (data.error) throw new Error(`Polygon RPC ${method}: ${data.error.message}`);
  return data.result;
}

// ── Taux XOF/USDT ────────────────────────────────────────────────────────────
// En Phase 1 on utilise un taux fixe issu de CoinPayments.
// Phase 3 : oracle Chainlink on-chain.
const TAUX_XOF_USDT_DEFAULT = 0.001613; // ~620 XOF = 1 USDT (approximatif)

async function getTauxUsdt(): Promise<number> {
  try {
    // Lire le dernier taux enregistré dans blockchain_taux
    const rows = await sbFetch(
      `/rest/v1/blockchain_taux?select=taux&order=created_at.desc&limit=1`,
      "GET"
    ) as Array<{ taux: number }>;
    if (rows?.length > 0) return parseFloat(String(rows[0].taux));
  } catch (_) { /* fallback */ }
  return TAUX_XOF_USDT_DEFAULT;
}

// ── Enregistrer une opération dans blockchain_journal ────────────────────────
async function enregistrerOperation(body: Record<string, unknown>): Promise<Record<string, unknown>> {
  const {
    tontine_code,
    type_operation,
    membre_id,
    membre_nom,
    montant_xof,
    ref_coinpayments,
    ref_interne,
    wallet_tontine,
    wallet_membre,
    metadata = {},
  } = body;

  if (!tontine_code || !type_operation) {
    throw new Error("tontine_code et type_operation sont requis");
  }

  const now       = new Date().toISOString();
  const taux      = await getTauxUsdt();
  const montantN  = montant_xof ? Number(montant_xof) : null;
  const montantU  = montantN ? parseFloat((montantN * taux).toFixed(6)) : null;

  // Construire le payload à signer
  const payloadStr = [
    tontine_code,
    type_operation,
    String(montant_xof ?? "0"),
    String(membre_id ?? ""),
    now,
  ].join("|");

  const [signature, payloadHash] = await Promise.all([
    hmacSha256(JOURNAL_SECRET, payloadStr),
    sha256(payloadStr),
  ]);

  // Insérer dans blockchain_journal
  const row = {
    tontine_code,
    type_operation,
    membre_id    : membre_id   ?? null,
    membre_nom   : membre_nom  ?? null,
    montant_xof  : montantN,
    montant_usdt : montantU,
    taux_xof_usdt: taux,
    reseau       : NETWORK.name,
    wallet_tontine: wallet_tontine ?? null,
    wallet_membre : wallet_membre  ?? null,
    ref_coinpayments: ref_coinpayments ?? null,
    ref_interne  : ref_interne ?? null,
    statut       : "pending",
    signature,
    payload_hash : payloadHash,
    metadata,
    created_at   : now,
    updated_at   : now,
  };

  const inserted = await sbFetch("/rest/v1/blockchain_journal", "POST", row) as Array<Record<string, unknown>>;
  const journalId = (inserted as Array<Record<string, unknown>>)?.[0]?.id ?? null;

  // ── Phase 1 : on inscrit "pending" dans Supabase immédiatement.
  // L'ancrage Polygon réel sera fait en Phase 2 via le smart contract.
  // Pour Phase 1, on simule un tx_hash pour démonstration (Amoy testnet).
  // En production Phase 2+, ce hash sera le vrai hash de TX Polygon.
  let txHash: string | null = null;
  let blockNumber: number | null = null;

  try {
    // Obtenir le numéro de bloc actuel (preuve de l'horodatage blockchain)
    const blockHex = await polygonRpc("eth_blockNumber", []) as string;
    blockNumber = parseInt(blockHex, 16);

    // En Phase 1 : on génère un hash de preuve (SHA-256 du payload + block)
    // Ce n'est PAS une vraie TX on-chain — c'est un ancrage de preuve d'existence.
    // Phase 2 : remplacé par une vraie TX `recordOperation()` dans TontineVault.sol
    txHash = "0x" + await sha256(`${payloadHash}:${blockNumber}:${JOURNAL_SECRET}`);

    // Mettre à jour le journal avec le hash et le statut
    await sbFetch(`/rest/v1/blockchain_journal?id=eq.${journalId}`, "PATCH", {
      tx_hash     : txHash,
      block_number: blockNumber,
      statut      : "confirmed",
      confirmed_at: new Date().toISOString(),
    });

    // Enregistrer le taux utilisé
    await sbFetch("/rest/v1/blockchain_taux", "POST", {
      paire : "XOF/USDT",
      taux,
      source: "tontineclair_static",
    }).catch(() => {});

  } catch (e) {
    // Echec blockchain non-bloquant : l'opération TC reste valide
    console.error("[blockchain-tx] Ancrage Polygon échoué (non-bloquant):", e);
    if (journalId) {
      await sbFetch(`/rest/v1/blockchain_journal?id=eq.${journalId}`, "PATCH", {
        statut  : "failed",
        metadata: { ...metadata as object, erreur_blockchain: String(e) },
      }).catch(() => {});
    }
  }

  return {
    ok          : true,
    journal_id  : journalId,
    tx_hash     : txHash,
    block_number: blockNumber,
    reseau      : NETWORK.name,
    explorer_url: txHash ? `${NETWORK.explorer}${txHash}` : null,
    montant_usdt: montantU,
    taux_xof_usdt: taux,
    signature,
    payload_hash: payloadHash,
    statut      : txHash ? "confirmed" : "failed",
    message     : "Opération enregistrée dans le journal blockchain TontineClair",
  };
}

// ── Vérifier le statut d'une TX on-chain ────────────────────────────────────
async function verifierTx(txHash: string): Promise<Record<string, unknown>> {
  if (!txHash) throw new Error("tx_hash requis");

  // En Phase 1 (preuve d'existence locale) : lire depuis blockchain_journal
  const rows = await sbFetch(
    `/rest/v1/blockchain_journal?tx_hash=eq.${encodeURIComponent(txHash)}&select=*&limit=1`,
    "GET"
  ) as Array<Record<string, unknown>>;

  if (!rows?.length) {
    return { ok: false, statut: "introuvable", tx_hash: txHash };
  }

  const entry = rows[0];

  // En Phase 2+ : vérifier on-chain via eth_getTransactionReceipt
  let onChainStatus: string | null = null;
  try {
    const receipt = await polygonRpc("eth_getTransactionReceipt", [txHash]) as Record<string, unknown> | null;
    if (receipt) {
      onChainStatus = receipt.status === "0x1" ? "confirmed" : "failed";
    }
  } catch (_) { /* Phase 1 : pas de vraie TX on-chain */ }

  return {
    ok             : true,
    tx_hash        : txHash,
    statut         : onChainStatus ?? entry.statut,
    journal_id     : entry.id,
    tontine_code   : entry.tontine_code,
    type_operation : entry.type_operation,
    montant_xof    : entry.montant_xof,
    montant_usdt   : entry.montant_usdt,
    block_number   : entry.block_number,
    confirmed_at   : entry.confirmed_at,
    explorer_url   : `${NETWORK.explorer}${txHash}`,
    signature      : entry.signature,
    reseau         : NETWORK.name,
  };
}

// ── Stats journal ─────────────────────────────────────────────────────────────
async function statsJournal(): Promise<Record<string, unknown>> {
  const [confirmed, pending, failed, total] = await Promise.all([
    sbFetch("/rest/v1/blockchain_journal?select=id&statut=eq.confirmed", "GET"),
    sbFetch("/rest/v1/blockchain_journal?select=id&statut=in.(pending,submitted)", "GET"),
    sbFetch("/rest/v1/blockchain_journal?select=id&statut=eq.failed", "GET"),
    sbFetch("/rest/v1/blockchain_journal?select=id", "GET"),
  ]).then(r => r.map(x => (x as unknown[]).length));

  const blockHex = await polygonRpc("eth_blockNumber", []).catch(() => "0x0") as string;

  return {
    ok               : true,
    reseau           : NETWORK.name,
    block_actuel     : parseInt(blockHex, 16),
    total_operations : total,
    confirmed,
    pending,
    failed,
    explorer         : NETWORK.explorer,
  };
}

// ── Lire le journal ───────────────────────────────────────────────────────────
async function lireJournal(body: Record<string, unknown>): Promise<Record<string, unknown>> {
  const { tontine_code, statut, type_operation, limit = 50, offset = 0 } = body;

  let url = `/rest/v1/blockchain_journal?select=*&order=created_at.desc&limit=${limit}&offset=${offset}`;
  if (tontine_code) url += `&tontine_code=eq.${encodeURIComponent(String(tontine_code))}`;
  if (statut)       url += `&statut=eq.${encodeURIComponent(String(statut))}`;
  if (type_operation) url += `&type_operation=eq.${encodeURIComponent(String(type_operation))}`;

  const rows = await sbFetch(url, "GET") as Array<Record<string, unknown>>;

  return {
    ok   : true,
    total: rows?.length ?? 0,
    rows : rows ?? [],
  };
}

// ── Taux USDT ─────────────────────────────────────────────────────────────────
async function getTauxAction(): Promise<Record<string, unknown>> {
  const taux = await getTauxUsdt();
  return {
    ok         : true,
    paire      : "XOF/USDT",
    taux,
    taux_inverse: parseFloat((1 / taux).toFixed(2)),
    source     : "tontineclair",
    reseau     : NETWORK.name,
  };
}

// ── Handler principal ─────────────────────────────────────────────────────────
Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === "OPTIONS") return new Response(null, { headers: CORS });
  if (req.method !== "POST")   return json({ erreur: true, message: "POST uniquement" }, 405);

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json({ erreur: true, message: "Corps JSON invalide" }, 400);
  }

  const action = (body.action as string) ?? "";

  try {
    switch (action) {
      case "enregistrer_operation":
        return json(await enregistrerOperation(body));

      case "verifier_tx":
        return json(await verifierTx(body.tx_hash as string));

      case "stats_journal":
        return json(await statsJournal());

      case "lire_journal":
        return json(await lireJournal(body));

      case "taux_usdt":
        return json(await getTauxAction());

      case "signer_payload": {
        const payload = body.payload as string ?? "";
        const sig = await hmacSha256(JOURNAL_SECRET, payload);
        const hash = await sha256(payload);
        return json({ ok: true, signature: sig, payload_hash: hash });
      }

      default:
        return json({
          erreur  : true,
          message : `Action inconnue: "${action}"`,
          actions : ["enregistrer_operation","verifier_tx","stats_journal","lire_journal","taux_usdt","signer_payload"],
        }, 400);
    }
  } catch (e) {
    console.error(`[blockchain-tx] Action="${action}" erreur:`, e);
    return json({
      erreur : true,
      message: e instanceof Error ? e.message : String(e),
      action,
    }, 500);
  }
});
