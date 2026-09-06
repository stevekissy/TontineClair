// deploy-contract/index.ts
// Edge Function temporaire pour déployer TontineVaultV4 sur Polygon Mainnet
// Utilise le MASTER_WALLET_PRIVATE_KEY déjà stocké dans les secrets Supabase

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";

// ── ABI encoding helpers (copiés depuis blockchain-tx) ──────────────────────
function encodeUint256(n: number | bigint): string {
  return BigInt(n).toString(16).padStart(64, "0");
}
function bytesToHex(b: Uint8Array): string {
  return Array.from(b).map(x => x.toString(16).padStart(2, "0")).join("");
}

// ── Bytecode compilé de TontineVaultV4 ──────────────────────────────────────
// Compilé avec solc 0.8.20 --optimize --optimize-runs=200
// Source: supabase/contracts/TontineVaultV4.sol
const BYTECODE = "PLACEHOLDER_BYTECODE";

// ── ABI minimal pour le déploiement ─────────────────────────────────────────
// constructor() — pas de paramètres
const CONSTRUCTOR_ARGS = ""; // pas d'args

// ── RPC helpers ─────────────────────────────────────────────────────────────
async function rpcCall(url: string, method: string, params: unknown[]): Promise<unknown> {
  const res = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
  });
  const data = await res.json() as { result?: unknown; error?: unknown };
  if (data.error) throw new Error(`RPC error: ${JSON.stringify(data.error)}`);
  return data.result;
}

// ── Keccak256 (pour signature) ───────────────────────────────────────────────
async function keccak256(data: Uint8Array): Promise<Uint8Array> {
  // Deno n'a pas keccak natif — on utilise une implémentation JS
  // Utiliser le même helper que blockchain-tx
  const { default: { keccak256: k } } = await import("https://esm.sh/@noble/hashes@1.3.2/sha3");
  return k(data);
}

// ── Signer une TX (EIP-155) ─────────────────────────────────────────────────
// On réutilise le même code de signature que blockchain-tx
async function signAndSendTx(
  rpcUrl: string,
  privKeyHex: string,
  fromAddr: string,
  to: string | null,
  data: string,
  chainId: number = 137
): Promise<{ txHash: string; contractAddress?: string }> {
  // Récupérer le nonce
  const nonce = parseInt(await rpcCall(rpcUrl, "eth_getTransactionCount", [fromAddr, "latest"]) as string, 16);
  
  // Gas price (legacy)
  const gasPrice = BigInt(await rpcCall(rpcUrl, "eth_gasPrice", []) as string);
  const gasPriceWith20pct = gasPrice * 120n / 100n; // +20% pour rapidité

  // Estimer le gas
  const gasEstimate = parseInt(await rpcCall(rpcUrl, "eth_estimateGas", [{
    from: fromAddr,
    to: to,
    data: data,
  }]) as string, 16);
  const gasLimit = Math.ceil(gasEstimate * 1.3); // +30% marge

  console.log(`[deploy] nonce=${nonce} gasPrice=${gasPriceWith20pct} gasLimit=${gasLimit}`);

  // Construire la TX RLP (EIP-155)
  // Importer rlp + secp256k1 via esm.sh
  const { RLP } = await import("https://esm.sh/@ethereumjs/rlp@5.0.2");
  const { secp256k1 } = await import("https://esm.sh/@noble/curves@1.4.0/secp256k1");

  const txData = [
    nonce === 0 ? "0x" : "0x" + nonce.toString(16),
    "0x" + gasPriceWith20pct.toString(16),
    "0x" + gasLimit.toString(16),
    to || "0x",           // "" pour création de contrat
    "0x0",                // value = 0
    data,                 // bytecode
    "0x" + chainId.toString(16),  // v = chainId pour EIP-155
    "0x",
    "0x",
  ];

  // Encoder pour signature
  const encoded = RLP.encode(txData.map(x => {
    if (x === "0x" || x === "") return new Uint8Array(0);
    const hex = x.startsWith("0x") ? x.slice(2) : x;
    if (hex === "0") return new Uint8Array(0);
    const padded = hex.length % 2 === 0 ? hex : "0" + hex;
    return Uint8Array.from(padded.match(/.{2}/g)!.map(b => parseInt(b, 16)));
  }));

  const msgHash = await keccak256(encoded);

  // Signer
  const privKey = Uint8Array.from(
    privKeyHex.replace("0x", "").match(/.{2}/g)!.map(b => parseInt(b, 16))
  );
  const sig = secp256k1.sign(msgHash, privKey);
  const r = sig.r.toString(16).padStart(64, "0");
  const s = sig.s.toString(16).padStart(64, "0");
  const v = 27 + sig.recovery + chainId * 2 + 8; // EIP-155

  // TX signée
  const signedTxData = [
    nonce === 0 ? new Uint8Array(0) : Uint8Array.from(nonce.toString(16).padStart(2,"0").match(/.{2}/g)!.map(b=>parseInt(b,16))),
    Uint8Array.from(gasPriceWith20pct.toString(16).padStart(2,"0").padStart(gasPriceWith20pct.toString(16).length%2===0?gasPriceWith20pct.toString(16).length:gasPriceWith20pct.toString(16).length+1,"0").match(/.{2}/g)!.map(b=>parseInt(b,16))),
    Uint8Array.from(gasLimit.toString(16).padStart(gasLimit.toString(16).length%2===0?gasLimit.toString(16).length:gasLimit.toString(16).length+1,"0").match(/.{2}/g)!.map(b=>parseInt(b,16))),
    to ? Uint8Array.from(to.replace("0x","").match(/.{2}/g)!.map(b=>parseInt(b,16))) : new Uint8Array(0),
    new Uint8Array(0),
    Uint8Array.from(data.replace("0x","").match(/.{2}/g)!.map(b=>parseInt(b,16))),
    Uint8Array.from([v]),
    Uint8Array.from(r.match(/.{2}/g)!.map(b=>parseInt(b,16))),
    Uint8Array.from(s.match(/.{2}/g)!.map(b=>parseInt(b,16))),
  ];

  const signedEncoded = RLP.encode(signedTxData);
  const rawTx = "0x" + bytesToHex(signedEncoded);

  const txHash = await rpcCall(rpcUrl, "eth_sendRawTransaction", [rawTx]) as string;
  console.log(`[deploy] TX envoyée: ${txHash}`);

  // Attendre le reçu
  for (let i = 0; i < 60; i++) {
    await new Promise(r => setTimeout(r, 3000));
    const receipt = await rpcCall(rpcUrl, "eth_getTransactionReceipt", [txHash]) as Record<string,string>|null;
    if (receipt) {
      console.log(`[deploy] Contrat déployé à: ${receipt.contractAddress}`);
      return { txHash, contractAddress: receipt.contractAddress };
    }
    console.log(`[deploy] Attente confirmation... (${i+1}/60)`);
  }

  return { txHash };
}

serve(async (req) => {
  // Sécurité : vérifier un token d'autorisation
  const authHeader = req.headers.get("Authorization") || "";
  const expectedToken = Deno.env.get("DEPLOY_SECRET") || "";
  if (expectedToken && !authHeader.includes(expectedToken)) {
    return new Response(JSON.stringify({ error: "Unauthorized" }), { status: 401 });
  }

  try {
    const rpcUrl    = Deno.env.get("ALCHEMY_POLYGON_AMOY_URL") || "https://polygon.drpc.org";
    const privKey   = Deno.env.get("MASTER_WALLET_PRIVATE_KEY") || "";
    const fromAddr  = Deno.env.get("MASTER_WALLET_ADDRESS") || "";

    if (!privKey || !fromAddr) {
      return new Response(JSON.stringify({ error: "MASTER_WALLET secrets manquants" }), { status: 500 });
    }
    if (BYTECODE === "PLACEHOLDER_BYTECODE") {
      return new Response(JSON.stringify({ error: "Bytecode non compilé — voir instructions" }), { status: 500 });
    }

    const deployData = BYTECODE + CONSTRUCTOR_ARGS;
    const result = await signAndSendTx(rpcUrl, privKey, fromAddr, null, deployData, 137);

    return new Response(JSON.stringify({ success: true, ...result }), {
      headers: { "Content-Type": "application/json" },
    });

  } catch (err) {
    console.error("[deploy-contract] Error:", err);
    return new Response(JSON.stringify({ error: String(err) }), { status: 500 });
  }
});
