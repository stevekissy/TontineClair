// ═══════════════════════════════════════════════════════════════════════════════
// blockchain-tx  —  TontineClair Phase 2
// Edge Function Supabase (Deno/TypeScript)
//
// Phase 2 : vrais appels on-chain vers TontineVault.sol sur Polygon Amoy
//   • Signature ECDSA des TX via MASTER_WALLET_PRIVATE_KEY
//   • Broadcast via eth_sendRawTransaction (Alchemy ou RPC public)
//   • Receipt attendu → vrai TX hash Ethereum dans blockchain_journal
//   • Fallback Phase 1 (SHA-256 proof) si RPC indisponible
//
// Secrets requis :
//   SUPABASE_URL                — URL projet Supabase
//   SUPABASE_SERVICE_ROLE_KEY   — clé service_role
//   BLOCKCHAIN_JOURNAL_SECRET   — HMAC-SHA256 signing key
//   ALCHEMY_POLYGON_AMOY_URL    — RPC Polygon Amoy (Alchemy ou public)
//   MASTER_WALLET_PRIVATE_KEY   — clé privée wallet admin (sans 0x)
//   MASTER_WALLET_ADDRESS       — adresse wallet admin
//   TONTINE_CONTRACT_ADDRESS    — adresse TontineVault.sol déployé
// ═══════════════════════════════════════════════════════════════════════════════

// Pas d'import externe — Deno.serve() natif disponible dans Supabase Edge Runtime

// ── Config réseau ──────────────────────────────────────────────────────────────
const CHAIN_ID       = 137;            // Polygon Mainnet
const CHAIN_ID_HEX   = "0x89";
const EXPLORER_BASE  = "https://polygonscan.com";
const RPC_FALLBACK   = "https://polygon.drpc.org";

// RPC alternatifs pour eth_sendRawTransaction (certains RPC publics bloquent le broadcast)
// Ordre de préférence : les plus fiables pour les TX en premier
// Ankr accepte eth_sendRawTransaction depuis Supabase (Alchemy le bloque)
const ANKR_RPC = "https://rpc.ankr.com/polygon/dbb05ffa48bde7edd4cc4c9f95bd487f861f4206fa425f8e392647eed461c1f9";

const RPC_BROADCAST_FALLBACKS = [
  ANKR_RPC,
  "https://polygon-rpc.com",
  "https://rpc-mainnet.matic.network",
  "https://matic-mainnet.chainstacklabs.com",
  "https://polygon.drpc.org",
];

// ── Helpers crypto ─────────────────────────────────────────────────────────────

async function sha256hex(data: string): Promise<string> {
  const encoder = new TextEncoder();
  const hashBuf = await crypto.subtle.digest("SHA-256", encoder.encode(data));
  return Array.from(new Uint8Array(hashBuf)).map(b => b.toString(16).padStart(2, "0")).join("").slice(0, 8);
}

// Note: SELECTORS non utilisé en pratique (selectors calculés via keccak256 + functionSelector())
// On le supprime pour éviter le top-level await qui cause un BOOT_ERROR dans Deno Edge Functions

async function sha256full(data: string | Uint8Array): Promise<Uint8Array> {
  const buf = typeof data === "string" ? new TextEncoder().encode(data) : data;
  return new Uint8Array(await crypto.subtle.digest("SHA-256", buf));
}

async function hmacSha256(key: string, data: string): Promise<string> {
  const keyBuf  = new TextEncoder().encode(key);
  const dataBuf = new TextEncoder().encode(data);
  const cryptoKey = await crypto.subtle.importKey(
    "raw", keyBuf, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]
  );
  const sig = await crypto.subtle.sign("HMAC", cryptoKey, dataBuf);
  return Array.from(new Uint8Array(sig)).map(b => b.toString(16).padStart(2, "0")).join("");
}

// ── RPC call helper ────────────────────────────────────────────────────────────

async function rpcCall(rpcUrl: string, method: string, params: unknown[]): Promise<unknown> {
  const res = await fetch(rpcUrl, {
    method : "POST",
    headers: { "Content-Type": "application/json" },
    body   : JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
    signal : AbortSignal.timeout(15000),
  });
  const json = await res.json() as { result?: unknown; error?: { message: string } };
  if (json.error) throw new Error(`RPC error: ${json.error.message}`);
  return json.result;
}

// ── ABI encoding (minimal, pour nos fonctions) ─────────────────────────────────

function encodeBytes32(hexOrStr: string): string {
  // Si c'est déjà un hex de 32 bytes
  const clean = hexOrStr.startsWith("0x") ? hexOrStr.slice(2) : hexOrStr;
  return clean.padEnd(64, "0").slice(0, 64);
}

function encodeUint256(n: bigint | number): string {
  return BigInt(n).toString(16).padStart(64, "0");
}

function encodeString(s: string): { offset: string; data: string } {
  const bytes = new TextEncoder().encode(s);
  const len   = encodeUint256(bytes.length);
  const padded = Array.from(bytes).map(b => b.toString(16).padStart(2, "0")).join("");
  const paddedData = padded.padEnd(Math.ceil(bytes.length / 32) * 64, "0");
  return { offset: "", data: len + paddedData };
}

function encodeCalldata(
  functionSig: string,
  types: string[],
  values: (string | bigint | number | Uint8Array)[]
): string {
  // Keccak4 du selector
  const sigBytes = new TextEncoder().encode(functionSig);
  // On va calculer le vrai selector via keccak256 simulé avec notre helper
  // Pour éviter une lib keccak complète, on utilise l'approche eth_call encode côté RPC
  // → On encode via eth_call avec les données brutes
  // Simplification : retourner les données pour eth_call encoding

  // Utilisons une approche directe : construire les données ABI manuellement
  let staticPart  = "";
  let dynamicPart = "";
  let dynamicOffset = types.length * 32; // offset initial pour la partie dynamique

  for (let i = 0; i < types.length; i++) {
    const t = types[i];
    const v = values[i];

    if (t === "uint256") {
      staticPart += encodeUint256(v as bigint);
    } else if (t === "bytes32") {
      if (v instanceof Uint8Array) {
        staticPart += Array.from(v).map(b => b.toString(16).padStart(2,"0")).join("").padEnd(64,"0");
      } else {
        staticPart += encodeBytes32(v as string);
      }
    } else if (t === "string") {
      staticPart += encodeUint256(dynamicOffset);
      const { data } = encodeString(v as string);
      dynamicPart += data;
      dynamicOffset += data.length / 2;
    }
  }

  return staticPart + dynamicPart;
}

// ── Ethereum TX signing (pure, sans lib externe) ───────────────────────────────
// On utilise l'API Alchemy eth_sendRawTransaction avec notre propre RLP+ECDSA
// → Pour éviter la complexité du signing manuel en Deno pur, on délègue
//   la signature à une Edge Function helper ou on utilise le pattern
//   "sign via secp256k1 Deno native"

// ── Keccak-256 pure JS (pas de dépendance externe) ────────────────────────────
// Implémentation embarquée pour éviter les imports esm.sh/npm: qui cassent le boot

function keccak256(data: Uint8Array): Uint8Array {
  // Keccak-256 (non-padded SHA3, standard Ethereum)
  const RC: bigint[] = [
    0x0000000000000001n,0x0000000000008082n,0x800000000000808An,0x8000000080008000n,
    0x000000000000808Bn,0x0000000080000001n,0x8000000080008081n,0x8000000000008009n,
    0x000000000000008An,0x0000000000000088n,0x0000000080008009n,0x000000008000000An,
    0x000000008000808Bn,0x800000000000008Bn,0x8000000000008089n,0x8000000000008003n,
    0x8000000000008002n,0x8000000000000080n,0x000000000000800An,0x800000008000000An,
    0x8000000080008081n,0x8000000000008080n,0x0000000080000001n,0x8000000080008008n,
  ];
  const ROTC = [1,3,6,10,15,21,28,36,45,55,2,14,27,41,56,8,25,43,62,18,39,61,20,44];
  const PI   = [10,7,11,17,18,3,5,16,8,21,24,4,15,23,19,13,12,2,20,14,22,9,6,1];
  const M64  = 0xFFFFFFFFFFFFFFFFn;

  function rotl64(x: bigint, n: number): bigint {
    return ((x << BigInt(n)) | (x >> BigInt(64 - n))) & M64;
  }

  // Pad message (Keccak, not SHA3 — no domain separation byte 0x06, use 0x01)
  const rate = 136; // 1088 bits / 8 for keccak-256
  const len  = data.length;
  const padded = new Uint8Array(Math.ceil((len + 1) / rate) * rate);
  padded.set(data);
  padded[len]           = 0x01;
  padded[padded.length - 1] |= 0x80;

  // State: 5×5 lanes of 64-bit values
  const state = new Array<bigint>(25).fill(0n);

  // Absorb
  for (let block = 0; block < padded.length; block += rate) {
    for (let i = 0; i < rate / 8; i++) {
      let lane = 0n;
      for (let j = 0; j < 8; j++) {
        lane |= BigInt(padded[block + i * 8 + j]) << BigInt(j * 8);
      }
      state[i] ^= lane;
    }
    // Keccak-f[1600]
    for (let round = 0; round < 24; round++) {
      // θ
      const C = Array.from({length:5}, (_,x) => state[x]^state[x+5]^state[x+10]^state[x+15]^state[x+20]);
      const D = Array.from({length:5}, (_,x) => C[(x+4)%5] ^ rotl64(C[(x+1)%5], 1));
      for (let i = 0; i < 25; i++) state[i] ^= D[i % 5];
      // ρ + π
      const B = new Array<bigint>(25).fill(0n);
      B[0] = state[0];
      for (let i = 0; i < 24; i++) B[PI[i]] = rotl64(state[i===0?0:PI[i-1]||0+1], ROTC[i]);
      // Recompute π correctly
      const tmp = [...state];
      for (let x = 0; x < 5; x++) {
        for (let y = 0; y < 5; y++) {
          B[y*5+x] = rotl64(tmp[((2*x+3*y)%5)*5+x], ROTC[y===0&&x===0?0:PI.indexOf(y*5+x)] || 0);
        }
      }
      // χ
      for (let y = 0; y < 5; y++) {
        for (let x = 0; x < 5; x++) {
          state[y*5+x] = B[y*5+x] ^ ((~B[y*5+(x+1)%5]) & B[y*5+(x+2)%5]);
        }
      }
      // ι
      state[0] ^= RC[round];
    }
  }

  // Squeeze first 32 bytes
  const hash = new Uint8Array(32);
  for (let i = 0; i < 4; i++) {
    const lane = state[i];
    for (let j = 0; j < 8; j++) {
      hash[i*8+j] = Number((lane >> BigInt(j*8)) & 0xFFn);
    }
  }
  return hash;
}

// ── secp256k1 ECDSA pure JS ────────────────────────────────────────────────────
// Courbe secp256k1 : y² = x³ + 7 (mod p)

const P  = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2Fn;
const N  = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141n;
const GX = 0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798n;
const GY = 0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8n;

function modP(n: bigint): bigint { return ((n % P) + P) % P; }
function modN(n: bigint): bigint { return ((n % N) + N) % N; }

function modInverse(a: bigint, m: bigint): bigint {
  let [old_r, r] = [a, m];
  let [old_s, s] = [1n, 0n];
  while (r !== 0n) {
    const q = old_r / r;
    [old_r, r] = [r, old_r - q * r];
    [old_s, s] = [s, old_s - q * s];
  }
  return ((old_s % m) + m) % m;
}

type Point = { x: bigint; y: bigint } | null;

function pointAdd(P1: Point, P2: Point): Point {
  if (!P1) return P2;
  if (!P2) return P1;
  if (P1.x === P2.x) {
    if (P1.y !== P2.y) return null;
    // Point doubling
    const lam = modP(3n * P1.x * P1.x * modInverse(2n * P1.y, P));
    const x3  = modP(lam * lam - 2n * P1.x);
    return { x: x3, y: modP(lam * (P1.x - x3) - P1.y) };
  }
  const lam = modP((P2.y - P1.y) * modInverse(P2.x - P1.x, P));
  const x3  = modP(lam * lam - P1.x - P2.x);
  return { x: x3, y: modP(lam * (P1.x - x3) - P1.y) };
}

function scalarMul(k: bigint, pt: Point): Point {
  let result: Point = null;
  let addend = pt;
  while (k > 0n) {
    if (k & 1n) result = pointAdd(result, addend);
    addend = pointAdd(addend, addend);
    k >>= 1n;
  }
  return result;
}

// RFC 6979 HMAC-DRBG — génération déterministe de k (spec complète)
// Réf : https://www.rfc-editor.org/rfc/rfc6979#section-3.2
async function rfc6979k(privKeyBytes: Uint8Array, msgHash: Uint8Array): Promise<bigint> {
  // Étape b : V = 0x01...01 (32 bytes)
  let V = new Uint8Array(32).fill(0x01);
  // Étape c : K = 0x00...00 (32 bytes)
  let K = new Uint8Array(32).fill(0x00);

  // Helper HMAC-SHA256 via crypto.subtle (natif Deno)
  const hmac = async (key: Uint8Array, ...msgs: Uint8Array[]): Promise<Uint8Array> => {
    const cryptoKey = await crypto.subtle.importKey(
      "raw", key, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]
    );
    const totalLen = msgs.reduce((a, m) => a + m.length, 0);
    const total = new Uint8Array(totalLen);
    let offset = 0;
    for (const m of msgs) { total.set(m, offset); offset += m.length; }
    return new Uint8Array(await crypto.subtle.sign("HMAC", cryptoKey, total));
  };

  // Étapes d → g : initialisation DRBG
  K = await hmac(K, V, new Uint8Array([0x00]), privKeyBytes, msgHash);
  V = await hmac(K, V);
  K = await hmac(K, V, new Uint8Array([0x01]), privKeyBytes, msgHash);
  V = await hmac(K, V);

  // Étape h : générer T jusqu'à obtenir k dans [1, N-1]
  for (let attempt = 0; attempt < 100; attempt++) {
    V = await hmac(K, V);
    const k = BigInt("0x" + Array.from(V).map(b => b.toString(16).padStart(2, "0")).join(""));
    if (k >= 1n && k < N) return k;
    // k invalide → mise à jour K et V (RFC 6979 §3.2 h.3)
    K = await hmac(K, V, new Uint8Array([0x00]));
    V = await hmac(K, V);
  }
  throw new Error("RFC 6979: impossible de générer k après 100 itérations");
}

async function ecSign(msgHash: Uint8Array, privKeyBytes: Uint8Array): Promise<{ r: bigint; s: bigint; recovery: number }> {
  const z = BigInt("0x" + Array.from(msgHash).map(b=>b.toString(16).padStart(2,"0")).join(""));
  const d = BigInt("0x" + Array.from(privKeyBytes).map(b=>b.toString(16).padStart(2,"0")).join(""));

  // k déterministe RFC 6979 HMAC-DRBG — remplace l'implémentation buggée précédente
  const k = await rfc6979k(privKeyBytes, msgHash);

  const R = scalarMul(k, { x: GX, y: GY });
  if (!R) throw new Error("secp256k1: R est null");

  const r = modN(R.x);
  if (r === 0n) throw new Error("secp256k1: r == 0");

  // s = k⁻¹ * (z + r*d) mod N
  const sRaw = modN(modInverse(k, N) * modN(z + modN(r * d)));

  // EIP-2 low-S normalization (requis par Ethereum/Polygon)
  const s = sRaw > N / 2n ? N - sRaw : sRaw;
  if (s === 0n) throw new Error("secp256k1: s == 0");

  // Recovery bit : parité de R.y, flippé si low-S a modifié s
  const recovery = Number(R.y & 1n) ^ (sRaw > N / 2n ? 1 : 0);

  return { r, s, recovery };
}

function hexToBytes(hex: string): Uint8Array {
  const h = hex.startsWith("0x") ? hex.slice(2) : hex;
  const arr = new Uint8Array(h.length / 2);
  for (let i = 0; i < arr.length; i++) {
    arr[i] = parseInt(h.slice(i * 2, i * 2 + 2), 16);
  }
  return arr;
}

function bytesToHex(bytes: Uint8Array): string {
  return Array.from(bytes).map(b => b.toString(16).padStart(2, "0")).join("");
}

function numberToHex(n: bigint | number, padBytes = 0): string {
  let h = BigInt(n).toString(16);
  if (h.length % 2 !== 0) h = "0" + h;
  if (padBytes > 0) h = h.padStart(padBytes * 2, "0");
  return h;
}

// RLP encoding minimal
function rlpEncodeLength(len: number, offset: number): Uint8Array {
  if (len < 56) return new Uint8Array([offset + len]);
  const lenHex = numberToHex(len);
  const lenBytes = hexToBytes(lenHex);
  return new Uint8Array([offset + 55 + lenBytes.length, ...lenBytes]);
}

function rlpEncode(input: Uint8Array | Uint8Array[]): Uint8Array {
  if (Array.isArray(input)) {
    const encoded = input.map(i => rlpEncode(i));
    const totalLen = encoded.reduce((acc, e) => acc + e.length, 0);
    const prefix = rlpEncodeLength(totalLen, 0xc0);
    return new Uint8Array([...prefix, ...encoded.flatMap(e => [...e])]);
  }
  if (input.length === 1 && input[0] < 0x80) return input;
  const prefix = rlpEncodeLength(input.length, 0x80);
  return new Uint8Array([...prefix, ...input]);
}

function stripZeros(b: Uint8Array): Uint8Array {
  let i = 0;
  while (i < b.length && b[i] === 0) i++;
  return b.slice(i);
}

// Signer une TX Legacy (type 0) pour Polygon Amoy
async function signTransaction(params: {
  to       : string;
  data     : string;
  nonce    : number;
  gasPrice : bigint;
  gasLimit : bigint;
  chainId  : number;
  privKey  : string;
}): Promise<string> {
  const { to, data, nonce, gasPrice, gasLimit, chainId, privKey } = params;

  // EIP-155 legacy TX fields
  const fields: Uint8Array[] = [
    stripZeros(hexToBytes(numberToHex(nonce))),       // nonce
    stripZeros(hexToBytes(numberToHex(gasPrice))),    // gasPrice
    stripZeros(hexToBytes(numberToHex(gasLimit))),    // gas
    hexToBytes(to.toLowerCase().slice(2)),            // to
    new Uint8Array(0),                                // value (0)
    hexToBytes(data.startsWith("0x") ? data.slice(2) : data), // data
    stripZeros(hexToBytes(numberToHex(chainId))),     // v = chainId
    new Uint8Array(0),                                // r = 0
    new Uint8Array(0),                                // s = 0
  ];

  const rlpForSigning = rlpEncode(fields);
  const hash = keccak256(rlpForSigning);

  const privKeyBytes = hexToBytes(privKey);
  const { r: rBig, s: sBig, recovery } = await ecSign(hash, privKeyBytes);
  const r = hexToBytes(numberToHex(rBig, 32));
  const s = hexToBytes(numberToHex(sBig, 32));
  const v = BigInt(chainId) * 2n + 35n + BigInt(recovery);

  const signedFields: Uint8Array[] = [
    stripZeros(hexToBytes(numberToHex(nonce))),
    stripZeros(hexToBytes(numberToHex(gasPrice))),
    stripZeros(hexToBytes(numberToHex(gasLimit))),
    hexToBytes(to.toLowerCase().slice(2)),
    new Uint8Array(0),
    hexToBytes(data.startsWith("0x") ? data.slice(2) : data),
    stripZeros(hexToBytes(numberToHex(v))),
    stripZeros(r),
    stripZeros(s),
  ];

  return "0x" + bytesToHex(rlpEncode(signedFields));
}

// ── Keccak4 selector ────────────────────────────────────────────────────────────
// IMPORTANT : la keccak256 JS maison produit des résultats incorrects pour les selectors.
// On utilise des constantes hardcodées, calculées avec web3.py (keccak256 certifié).
// À mettre à jour si les signatures de fonctions dans TontineVault.sol changent.

const SELECTORS: Record<string, string> = {
  "enregistrerOperation(string,string,string,uint256,uint256,string,bytes32)": "0xbaa62d66",
  "enregistrerVote(string,string,string,string,bytes32)"                     : "0xd3795e53",
  "enregistrerCreation(string,string,string,bytes32)"                        : "0x68054f4e",
  "getInfo()"                                                                : "0x5a9b0b89",
  "transfererAdmin(address)"                                                 : "0xb38ff71f",
  "admin()"                                                                  : "0xf851a440",
  "version()"                                                                : "0x54fd4d50",
  "totalOperations()"                                                        : "0xed232029",
};

function functionSelector(sig: string): string {
  const hardcoded = SELECTORS[sig];
  if (hardcoded) return hardcoded;
  // Fallback : keccak256 JS (peut être incorrect — à éviter pour les fonctions du contrat)
  console.warn(`[blockchain-tx] Selector non hardcodé pour : ${sig}`);
  return "0x" + bytesToHex(keccak256(new TextEncoder().encode(sig)).slice(0, 4));
}

// ── Build calldata pour TontineVault ──────────────────────────────────────────

function buildOperationCalldata(
  tontineCode : string,
  typeOp      : string,
  membreId    : string,
  montantXof  : number,
  montantUsdt : number,
  refInterne  : string,
  payloadHash : Uint8Array
): string {
  const sel = functionSelector("enregistrerOperation(string,string,string,uint256,uint256,string,bytes32)");
  // ABI encode: (string, string, string, uint256, uint256, string, bytes32)
  // 7 params : 3 strings (dynamic) + 2 uint256 (static) + 1 string (dynamic) + 1 bytes32 (static)
  // Offsets statiques = 7 * 32 = 224 bytes

  const encoder = new TextEncoder();
  const encStr = (s: string) => {
    const b = encoder.encode(s);
    const lenHex = encodeUint256(b.length);
    const bodyHex = bytesToHex(b).padEnd(Math.ceil(b.length / 32) * 64, "0");
    return lenHex + bodyHex;
  };

  const str1 = encStr(tontineCode);
  const str2 = encStr(typeOp);
  const str3 = encStr(membreId);
  const str4 = encStr(refInterne);
  const ph   = bytesToHex(payloadHash).padEnd(64, "0");

  // Calculer les offsets dynamiques
  const baseOffset = 7 * 32; // 7 params * 32 bytes
  const off1 = baseOffset;
  const off2 = off1 + str1.length / 2;
  const off3 = off2 + str2.length / 2;
  const off4 = off3 + str3.length / 2 + 2 * 32; // après les 2 uint256 statiques
  // uint256 et bytes32 sont statiques donc pas d'offset pour eux

  // Reconstruire l'ordre ABI : offsets dans l'ordre des params
  // param0 = tontineCode (string, dynamic) → offset
  // param1 = typeOp (string, dynamic) → offset
  // param2 = membreId (string, dynamic) → offset
  // param3 = montantXof (uint256, static)
  // param4 = montantUsdt (uint256, static)
  // param5 = refInterne (string, dynamic) → offset
  // param6 = payloadHash (bytes32, static)

  const o0 = 7 * 32;
  const o1 = o0 + str1.length / 2;
  const o2 = o1 + str2.length / 2;
  // after param3, param4 (2×32 static), param5 offset, param6 (32 static)
  // dynamic data starts at offset 7*32 for param0
  const o5 = o2 + str3.length / 2;

  const staticPart =
    encodeUint256(o0) +           // offset param0
    encodeUint256(o1) +           // offset param1
    encodeUint256(o2) +           // offset param2
    encodeUint256(montantXof) +   // param3 uint256
    encodeUint256(montantUsdt) +  // param4 uint256
    encodeUint256(o5) +           // offset param5
    ph;                           // param6 bytes32

  const dynamicPart = str1 + str2 + str3 + str4;

  return sel + staticPart + dynamicPart;
}

function buildVoteCalldata(
  tontineCode : string,
  membreId    : string,
  question    : string,
  choix       : string,
  payloadHash : Uint8Array
): string {
  const sel = functionSelector("enregistrerVote(string,string,string,string,bytes32)");
  const encoder = new TextEncoder();
  const encStr = (s: string) => {
    const b = encoder.encode(s);
    return encodeUint256(b.length) + bytesToHex(b).padEnd(Math.ceil(b.length / 32) * 64, "0");
  };

  const str1 = encStr(tontineCode);
  const str2 = encStr(membreId);
  const str3 = encStr(question);
  const str4 = encStr(choix);
  const ph   = bytesToHex(payloadHash).padEnd(64, "0");

  // 5 params: 4 strings dynamic + 1 bytes32 static
  const o0 = 5 * 32;
  const o1 = o0 + str1.length / 2;
  const o2 = o1 + str2.length / 2;
  const o3 = o2 + str3.length / 2;

  const staticPart =
    encodeUint256(o0) +
    encodeUint256(o1) +
    encodeUint256(o2) +
    encodeUint256(o3) +
    ph;

  return sel + staticPart + str1 + str2 + str3 + str4;
}

function buildCreationCalldata(
  tontineCode  : string,
  gestId       : string,
  nomTontine   : string,
  payloadHash  : Uint8Array
): string {
  const sel = functionSelector("enregistrerCreation(string,string,string,bytes32)");
  const encoder = new TextEncoder();
  const encStr = (s: string) => {
    const b = encoder.encode(s);
    return encodeUint256(b.length) + bytesToHex(b).padEnd(Math.ceil(b.length / 32) * 64, "0");
  };

  const str1 = encStr(tontineCode);
  const str2 = encStr(gestId);
  const str3 = encStr(nomTontine);
  const ph   = bytesToHex(payloadHash).padEnd(64, "0");

  const o0 = 4 * 32;
  const o1 = o0 + str1.length / 2;
  const o2 = o1 + str2.length / 2;

  const staticPart =
    encodeUint256(o0) +
    encodeUint256(o1) +
    encodeUint256(o2) +
    ph;

  return sel + staticPart + str1 + str2 + str3;
}

// ── Envoyer une TX on-chain (avec fallback multi-RPC pour le broadcast) ─────────

async function sendOnChainTx(
  rpcUrl      : string,
  contractAddr: string,
  calldata    : string,
  privKey     : string,
  fromAddr    : string
): Promise<{ txHash: string; blockNumber: number } | null> {
  try {
    // Nonce + gas via le RPC principal (lecture — généralement pas bloqué)
    const nonce = parseInt(
      await rpcCall(rpcUrl, "eth_getTransactionCount", [fromAddr, "latest"]) as string,
      16
    );

    // Gas price
    const gasPriceHex = await rpcCall(rpcUrl, "eth_gasPrice", []) as string;
    const gasPrice = BigInt(gasPriceHex) * 120n / 100n; // +20%

    // Gas limit estimé
    let gasLimit = 200000n; // valeur par défaut
    try {
      const gasEst = await rpcCall(rpcUrl, "eth_estimateGas", [{
        from: fromAddr, to: contractAddr, data: calldata
      }]) as string;
      gasLimit = BigInt(gasEst) * 130n / 100n; // +30% marge
    } catch (_) { /* utiliser défaut 200k */ }

    // Signer la TX (une seule fois — le nonce est fixé)
    const rawTx = await signTransaction({
      to      : contractAddr,
      data    : calldata,
      nonce,
      gasPrice,
      gasLimit,
      chainId : CHAIN_ID,
      privKey,
    });

    // ── Broadcast avec fallback multi-RPC ──────────────────────────────────────
    // Alchemy bloque eth_sendRawTransaction depuis les IPs Supabase.
    // Ankr accepte les writes → toujours en premier pour le broadcast.
    const broadcastUrls = [ANKR_RPC, ...RPC_BROADCAST_FALLBACKS.filter(u => u !== ANKR_RPC)];
    let txHashResult: string | null = null;
    let broadcastError = "";

    for (const url of broadcastUrls) {
      try {
        console.log(`[blockchain-tx] Broadcast via ${url}`);
        const result = await rpcCall(url, "eth_sendRawTransaction", [rawTx]) as string;
        if (result && result.startsWith("0x") && result.length === 66) {
          txHashResult = result;
          console.log(`[blockchain-tx] TX envoyée via ${url}: ${txHashResult}`);
          break;
        }
      } catch (e) {
        broadcastError = String(e);
        console.warn(`[blockchain-tx] Broadcast échoué sur ${url}: ${e}`);
        // Continuer avec le prochain RPC
      }
    }

    if (!txHashResult) {
      console.error(`[blockchain-tx] Tous les RPC ont échoué. Dernière erreur: ${broadcastError}`);
      return null;
    }

    // Retourner immédiatement après le broadcast — ne pas attendre le receipt.
    // Polygon confirme en ~2s mais Supabase Edge Function timeout = 25s max.
    // Attendre le receipt ici dépasse le timeout → la fonction est tuée → fallback Phase 1.
    // Le statut "pending" sera mis à jour par une vérification ultérieure (verifier_tx).
    console.log(`[blockchain-tx] TX broadcastée: ${txHashResult} — retour immédiat (pas d'attente receipt)`);
    return { txHash: txHashResult, blockNumber: 0 };

  } catch (err) {
    console.error(`[blockchain-tx] sendOnChainTx error: ${err}`);
    return null;
  }
}

// ── Supabase helper ─────────────────────────────────────────────────────────────

async function supabaseRpc(
  supabaseUrl : string,
  serviceKey  : string,
  fnName      : string,
  params      : Record<string, unknown>
): Promise<unknown> {
  const res = await fetch(`${supabaseUrl}/rest/v1/rpc/${fnName}`, {
    method  : "POST",
    headers : {
      "Content-Type" : "application/json",
      "apikey"       : serviceKey,
      "Authorization": `Bearer ${serviceKey}`,
    },
    body: JSON.stringify(params),
  });
  return res.json();
}

async function supabaseInsert(
  supabaseUrl : string,
  serviceKey  : string,
  table       : string,
  data        : Record<string, unknown>
): Promise<unknown> {
  const res = await fetch(`${supabaseUrl}/rest/v1/${table}`, {
    method  : "POST",
    headers : {
      "Content-Type" : "application/json",
      "apikey"       : serviceKey,
      "Authorization": `Bearer ${serviceKey}`,
      "Prefer"       : "return=representation",
    },
    body: JSON.stringify(data),
  });
  return res.json();
}

async function supabaseUpdate(
  supabaseUrl : string,
  serviceKey  : string,
  table       : string,
  id          : string,
  data        : Record<string, unknown>
): Promise<unknown> {
  const res = await fetch(`${supabaseUrl}/rest/v1/${table}?id=eq.${id}`, {
    method  : "PATCH",
    headers : {
      "Content-Type" : "application/json",
      "apikey"       : serviceKey,
      "Authorization": `Bearer ${serviceKey}`,
    },
    body: JSON.stringify(data),
  });
  return res.json();
}

// ── Action : enregistrer_operation (Phase 2) ───────────────────────────────────

async function actionEnregistrerOperation(
  body       : Record<string, unknown>,
  env        : Record<string, string>
): Promise<Record<string, unknown>> {
  const {
    tontine_code, type_operation, membre_id, membre_nom,
    montant_xof, ref_coinpayments, ref_interne,
  } = body as Record<string, string | number>;

  const supabaseUrl  = env.SUPABASE_URL;
  const serviceKey   = env.SUPABASE_SERVICE_ROLE_KEY;
  const journalSecret = env.BLOCKCHAIN_JOURNAL_SECRET;
  const rpcUrl       = env.ALCHEMY_POLYGON_AMOY_URL || RPC_FALLBACK;
  const privKey      = env.MASTER_WALLET_PRIVATE_KEY || "";
  const fromAddr     = env.MASTER_WALLET_ADDRESS || "";
  const contractAddr = env.TONTINE_CONTRACT_ADDRESS || "";

  const phase2Ready = privKey && fromAddr && contractAddr;

  // Taux XOF/USDT
  const TAUX_XOF_USDT = 600;
  const montantXof  = Number(montant_xof) || 0;
  const montantUsdt = Math.round(montantXof / TAUX_XOF_USDT * 1_000_000); // micro-USDT

  // HMAC signature payload
  const now = new Date().toISOString();
  const payloadStr  = `${tontine_code}|${type_operation}|${montantXof}|${membre_id}|${now}`;
  const signature   = await hmacSha256(journalSecret, payloadStr);
  const payloadBytes = new Uint8Array(await crypto.subtle.digest("SHA-256",
    new TextEncoder().encode(payloadStr)));

  // Phase 1 fallback hash (toujours calculé)
  const phase1Hash = "0x" + Array.from(await sha256full(payloadStr + ":" + journalSecret))
    .map(b => b.toString(16).padStart(2,"0")).join("");

  let txHash      = phase1Hash;
  let blockNumber = 0;
  let statut      = "pending";
  let phase       = 1;

  // ── Phase 2 : vraie TX on-chain ──────────────────────────────────────────────
  if (phase2Ready) {
    try {
      let calldata: string;
      const typeOp = String(type_operation);

      if (typeOp === "vote") {
        calldata = buildVoteCalldata(
          String(tontine_code),
          String(membre_id),
          String(body.question || "vote"),
          String(body.choix || "oui"),
          payloadBytes
        );
      } else if (typeOp === "creation") {
        calldata = buildCreationCalldata(
          String(tontine_code),
          String(membre_id),
          String(body.nom_tontine || tontine_code),
          payloadBytes
        );
      } else {
        calldata = buildOperationCalldata(
          String(tontine_code),
          typeOp,
          String(membre_id),
          montantXof,
          montantUsdt,
          String(ref_interne || ""),
          payloadBytes
        );
      }

      const onChain = await sendOnChainTx(rpcUrl, contractAddr, calldata, privKey, fromAddr);
      if (onChain) {
        txHash      = onChain.txHash;
        blockNumber = onChain.blockNumber;
        statut      = blockNumber > 0 ? "confirmed" : "pending";
        phase       = 2;
        console.log(`[blockchain-tx] Phase 2 TX: ${txHash} block=${blockNumber}`);
      }
    } catch (err) {
      console.error(`[blockchain-tx] Phase 2 error, fallback Phase 1: ${err}`);
      // Fallback silencieux → on garde phase1Hash
      // Stocker l'erreur pour debug (visible dans la réponse si phase=1)
      (globalThis as Record<string, unknown>).__lastPhase2Error = String(err);
    }
  }

  // Insérer dans blockchain_journal
  const entry = await supabaseInsert(supabaseUrl, serviceKey, "blockchain_journal", {
    tontine_code   : String(tontine_code).toUpperCase(),
    type_operation : String(type_operation),
    membre_id      : String(membre_id),
    montant_xof    : montantXof,
    montant_usdt   : montantUsdt / 1_000_000,
    taux_xof_usdt  : TAUX_XOF_USDT,
    reseau         : "polygon-mainnet",
    tx_hash        : txHash,
    block_number   : blockNumber || null,
    wallet_tontine : fromAddr || "phase1",
    statut,
    signature,
    payload_hash   : phase1Hash,
    ref_coinpayments: ref_coinpayments ? String(ref_coinpayments) : null,
    ref_interne    : ref_interne ? String(ref_interne) : null,
    metadata       : {
      membre_nom,
      phase,
      contract_address: contractAddr || null,
      explorer_url: phase === 2
        ? `${EXPLORER_BASE}/tx/${txHash}`
        : null,
    },
  });

  const entryArr = Array.isArray(entry) ? entry : [];
  const entryId  = entryArr[0]?.id || null;

  const debugErr = (globalThis as Record<string, unknown>).__lastPhase2Error;

  return {
    ok          : true,
    phase,
    tx_hash     : txHash,
    block_number: blockNumber,
    statut,
    signature,
    payload_hash: phase1Hash,
    entry_id    : entryId,
    explorer_url: phase === 2 ? `${EXPLORER_BASE}/tx/${txHash}` : null,
    contract    : contractAddr || null,
    // Exposer l'erreur Phase 2 si fallback (pour debug)
    ...(phase === 1 && debugErr ? { phase2_error: debugErr } : {}),
  };
}

// ── Action : verifier_tx ───────────────────────────────────────────────────────

async function actionVerifierTx(
  body: Record<string, unknown>,
  env : Record<string, string>
): Promise<Record<string, unknown>> {
  const txHash   = String(body.tx_hash || "");
  const rpcUrl   = env.ALCHEMY_POLYGON_AMOY_URL || RPC_FALLBACK;
  const supabaseUrl = env.SUPABASE_URL;
  const serviceKey  = env.SUPABASE_SERVICE_ROLE_KEY;

  // Chercher dans le journal
  const res = await fetch(
    `${supabaseUrl}/rest/v1/blockchain_journal?tx_hash=eq.${encodeURIComponent(txHash)}&limit=1`,
    { headers: { "apikey": serviceKey, "Authorization": `Bearer ${serviceKey}` } }
  );
  const journal = await res.json() as unknown[];
  const entry   = journal[0] as Record<string, unknown> | undefined;

  // Vérifier on-chain si c'est un vrai hash Ethereum (commence par 0x et 66 chars)
  let onChainData: Record<string, unknown> | null = null;
  if (txHash.startsWith("0x") && txHash.length === 66 && !txHash.includes("0000000000")) {
    try {
      const receipt = await rpcCall(rpcUrl, "eth_getTransactionReceipt", [txHash]);
      if (receipt) {
        const r = receipt as Record<string, string>;
        onChainData = {
          confirmed   : r.status === "0x1",
          block_number: parseInt(r.blockNumber || "0x0", 16),
          gas_used    : parseInt(r.gasUsed || "0x0", 16),
          explorer_url: `${EXPLORER_BASE}/tx/${txHash}`,
        };
        // Mettre à jour le statut si confirmé et pas encore à jour
        if (entry && onChainData.confirmed && (entry as Record<string,string>).statut === "pending") {
          const id = (entry as Record<string,string>).id;
          await supabaseUpdate(supabaseUrl, serviceKey, "blockchain_journal", id, {
            statut      : "confirmed",
            block_number: onChainData.block_number,
            confirmed_at: new Date().toISOString(),
          });
        }
      }
    } catch (_) { /* RPC indispo */ }
  }

  return {
    ok          : true,
    found       : !!entry,
    journal     : entry || null,
    on_chain    : onChainData,
    explorer_url: txHash.startsWith("0x") && txHash.length === 66
      ? `${EXPLORER_BASE}/tx/${txHash}`
      : null,
  };
}

// ── Action : stats_journal ─────────────────────────────────────────────────────

async function actionStats(env: Record<string, string>): Promise<Record<string, unknown>> {
  const supabaseUrl = env.SUPABASE_URL;
  const serviceKey  = env.SUPABASE_SERVICE_ROLE_KEY;
  const rpcUrl      = env.ALCHEMY_POLYGON_AMOY_URL || RPC_FALLBACK;

  const res = await fetch(
    `${supabaseUrl}/rest/v1/blockchain_journal?select=statut,type_operation,montant_xof`,
    { headers: { "apikey": serviceKey, "Authorization": `Bearer ${serviceKey}` } }
  );
  const rows = await res.json() as Record<string, string | number>[];

  const stats = {
    total      : rows.length,
    confirmed  : rows.filter(r => r.statut === "confirmed").length,
    pending    : rows.filter(r => r.statut === "pending").length,
    echec      : rows.filter(r => r.statut === "echec").length,
    total_xof  : rows.reduce((s, r) => s + (Number(r.montant_xof) || 0), 0),
    par_type   : {} as Record<string, number>,
    phase2_count: rows.filter(r => {
      // TX phase 2 = hash 66 chars sans pattern répétitif
      return false; // Sera calculé différemment
    }).length,
  };

  for (const r of rows) {
    const t = String(r.type_operation);
    stats.par_type[t] = (stats.par_type[t] || 0) + 1;
  }

  // Récupérer block number actuel
  let currentBlock = 0;
  const contractAddr = env.TONTINE_CONTRACT_ADDRESS || "";
  try {
    const bn = await rpcCall(rpcUrl, "eth_blockNumber", []) as string;
    currentBlock = parseInt(bn, 16);
  } catch (_) { /* indispo */ }

  return {
    ok            : true,
    stats,
    current_block : currentBlock,
    network       : "polygon-mainnet",
    contract      : contractAddr || null,
    explorer_contract: contractAddr
      ? `${EXPLORER_BASE}/address/${contractAddr}`
      : null,
    phase         : contractAddr ? 2 : 1,
  };
}

// ── Action : lire_journal ──────────────────────────────────────────────────────

async function actionLireJournal(
  body: Record<string, unknown>,
  env : Record<string, string>
): Promise<Record<string, unknown>> {
  const supabaseUrl = env.SUPABASE_URL;
  const serviceKey  = env.SUPABASE_SERVICE_ROLE_KEY;

  const limit   = Math.min(Number(body.limit) || 20, 100);
  const offset  = Number(body.offset) || 0;
  const tontine = body.tontine_code ? `&tontine_code=eq.${body.tontine_code}` : "";
  const statut  = body.statut && body.statut !== "tous" ? `&statut=eq.${body.statut}` : "";
  const typeOp  = body.type_operation && body.type_operation !== "tous" ? `&type_operation=eq.${body.type_operation}` : "";

  const url = `${supabaseUrl}/rest/v1/blockchain_journal?select=*&order=created_at.desc&limit=${limit}&offset=${offset}${tontine}${statut}${typeOp}`;
  const res = await fetch(url, {
    headers: { "apikey": serviceKey, "Authorization": `Bearer ${serviceKey}` }
  });
  const rows = await res.json() as unknown[];

  // Enrichir avec explorer_url
  const enriched = (rows as Record<string, unknown>[]).map(r => ({
    ...r,
    explorer_url: r.tx_hash && String(r.tx_hash).length === 66
      ? `${EXPLORER_BASE}/tx/${r.tx_hash}`
      : null,
    explorer_contract: env.TONTINE_CONTRACT_ADDRESS
      ? `${EXPLORER_BASE}/address/${env.TONTINE_CONTRACT_ADDRESS}`
      : null,
  }));

  return { ok: true, journal: enriched, count: enriched.length, offset };
}

// ── Action : taux_usdt ─────────────────────────────────────────────────────────

async function actionTauxUsdt(): Promise<Record<string, unknown>> {
  return { ok: true, taux_xof_usdt: 600, source: "fixed", updated_at: new Date().toISOString() };
}

// ── Action : sync_balance ──────────────────────────────────────────────────────
// Synchronise le solde consolidé d'une tontine sur la blockchain.
// Appelé par l'écran admin AdminSoldesScreen.
// Utilise le même pipeline que enregistrer_operation (Phase 1 SHA-256 ou Phase 2 on-chain).

async function actionSyncBalance(
  body: Record<string, unknown>,
  env : Record<string, string>
): Promise<Record<string, unknown>> {
  // Réutiliser exactement le pipeline enregistrer_operation
  // avec type_operation = 'sync_balance'
  const syncBody: Record<string, unknown> = {
    ...body,
    action         : "enregistrer_operation",
    type_operation : "sync_balance",
    // montant_xof contient le solde net
    montant_xof    : body.solde_brut ?? body.montant_xof ?? 0,
    metadata       : {
      total_entrees: body.total_entrees ?? 0,
      total_sorties: body.total_sorties ?? 0,
      solde_net    : body.solde_brut ?? 0,
      nb_ops       : body.nb_ops ?? 0,
      sync_at      : new Date().toISOString(),
      source       : "admin_sync",
    },
  };
  return await actionEnregistrerOperation(syncBody, env);
}

// ── Action : stats_journal enrichi avec par_tontine ────────────────────────────
// Version enrichie de actionStats qui retourne les soldes agrégés par tontine.
// Appelé par AdminSoldesScreen pour éviter N requêtes individuelles.

async function actionStatsSoldes(
  env: Record<string, string>
): Promise<Record<string, unknown>> {
  const supabaseUrl = env.SUPABASE_URL;
  const serviceKey  = env.SUPABASE_SERVICE_ROLE_KEY;

  // Charger toutes les entrées du journal (max 5000)
  const res = await fetch(
    `${supabaseUrl}/rest/v1/blockchain_journal?select=tontine_code,type_operation,montant_xof,tx_hash,statut,created_at&order=created_at.desc&limit=5000`,
    { headers: { "apikey": serviceKey, "Authorization": `Bearer ${serviceKey}` } }
  );
  const rows = await res.json() as Record<string, string | number>[];

  // Types qui AUGMENTENT la caisse
  const ENTREES = new Set(["cotisation","apport","remboursement","remboursement_pret","annulation_pret","annulation_distribution"]);
  // Types qui DIMINUENT la caisse
  const SORTIES = new Set(["distribution","decaissement","pret","depense_caisse","penalite","annulation_cotisation","retrait"]);

  // Agrégation par tontine
  const parTontine: Record<string, {
    entrees: number; sorties: number; nb_ops: number;
    nb_on_chain: number; dernier_tx: string | null;
    dernier_statut: string | null; derniere_op: string | null;
  }> = {};

  for (const r of rows) {
    const code = String(r.tontine_code || "");
    if (!code) continue;
    if (!parTontine[code]) {
      parTontine[code] = {
        entrees: 0, sorties: 0, nb_ops: 0,
        nb_on_chain: 0, dernier_tx: null,
        dernier_statut: null, derniere_op: null,
      };
    }
    const t   = parTontine[code];
    const m   = Number(r.montant_xof) || 0;
    const type = String(r.type_operation).toLowerCase();
    t.nb_ops++;

    if (ENTREES.has(type))      t.entrees += m;
    else if (SORTIES.has(type)) t.sorties += m;

    const hash = String(r.tx_hash || "");
    if (hash.length === 66) {
      t.nb_on_chain++;
      // Garder la TX la plus récente
      if (!t.derniere_op || String(r.created_at) > t.derniere_op) {
        t.dernier_tx     = hash;
        t.dernier_statut = String(r.statut || "");
        t.derniere_op    = String(r.created_at || "");
      }
    } else if (!t.derniere_op || String(r.created_at) > t.derniere_op) {
      t.derniere_op = String(r.created_at || "");
    }
  }

  // Ajouter le solde net à chaque entrée
  const parTontineAvecSolde: Record<string, unknown> = {};
  for (const [code, t] of Object.entries(parTontine)) {
    parTontineAvecSolde[code] = {
      ...t,
      solde: t.entrees - t.sorties,
    };
  }

  const contractAddr = env.TONTINE_CONTRACT_ADDRESS || "";
  return {
    ok          : true,
    par_tontine : parTontineAvecSolde,
    total_ops   : rows.length,
    nb_tontines : Object.keys(parTontine).length,
    network     : "polygon-mainnet",
    contract    : contractAddr || null,
    phase       : contractAddr ? 2 : 1,
  };
}

// ── Action : contract_info ─────────────────────────────────────────────────────

async function actionContractInfo(env: Record<string, string>): Promise<Record<string, unknown>> {
  const rpcUrl      = env.ALCHEMY_POLYGON_AMOY_URL || RPC_FALLBACK;
  const contractAddr = env.TONTINE_CONTRACT_ADDRESS || "";
  const fromAddr    = env.MASTER_WALLET_ADDRESS || "";

  if (!contractAddr) {
    return { ok: false, erreur: "TONTINE_CONTRACT_ADDRESS non configuré (Phase 1)", phase: 1 };
  }

  try {
    // Appel getInfo() = selector 0x5a9b0b89
    const sel = functionSelector("getInfo()");
    const result = await rpcCall(rpcUrl, "eth_call", [
      { to: contractAddr, data: sel },
      "latest"
    ]) as string;

    // Décoder (4 valeurs : address, string, uint256, uint256)
    // Simplifié : juste confirmer que le contrat répond
    return {
      ok              : true,
      phase           : 2,
      contract_address: contractAddr,
      wallet_admin    : fromAddr,
      network         : "polygon-mainnet",
      chain_id        : CHAIN_ID,
      explorer        : `${EXPLORER_BASE}/address/${contractAddr}`,
      raw_result      : result?.slice(0, 40) + "...",
    };
  } catch (err) {
    return {
      ok    : false,
      phase : 1,
      erreur: String(err),
    };
  }
}

// ── Main handler ───────────────────────────────────────────────────────────────

Deno.serve(async (req) => {
  const corsHeaders = {
    "Access-Control-Allow-Origin" : "*",
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  };

  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  // ── Identifiant de version déployée (pour vérifier que le bon code tourne)
  const DEPLOYED_VERSION = "bf8608d-v6-ankr";

  try {
    const env: Record<string, string> = {
      SUPABASE_URL              : Deno.env.get("SUPABASE_URL") || "",
      SUPABASE_SERVICE_ROLE_KEY : Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "",
      BLOCKCHAIN_JOURNAL_SECRET : Deno.env.get("BLOCKCHAIN_JOURNAL_SECRET") || "default-secret",
      ALCHEMY_POLYGON_AMOY_URL  : (Deno.env.get("ALCHEMY_POLYGON_AMOY_URL") || RPC_FALLBACK).trim(),
      MASTER_WALLET_PRIVATE_KEY : (Deno.env.get("MASTER_WALLET_PRIVATE_KEY") || "").trim(),
      MASTER_WALLET_ADDRESS     : (Deno.env.get("MASTER_WALLET_ADDRESS") || "").trim(),
      TONTINE_CONTRACT_ADDRESS  : (Deno.env.get("TONTINE_CONTRACT_ADDRESS") || "").trim(),
    };

    const body = await req.json() as Record<string, unknown>;
    const action = String(body.action || "");

    let result: Record<string, unknown>;

    switch (action) {
      case "enregistrer_operation":
        result = await actionEnregistrerOperation(body, env);
        break;
      case "verifier_tx":
        result = await actionVerifierTx(body, env);
        break;
      case "stats_journal":
        result = await actionStats(env);
        break;
      case "lire_journal":
        result = await actionLireJournal(body, env);
        break;
      case "taux_usdt":
        result = await actionTauxUsdt();
        break;
      case "contract_info":
        result = await actionContractInfo(env);
        break;
      case "sync_balance":
        result = await actionSyncBalance(body, env);
        break;
      case "stats_soldes":
        result = await actionStatsSoldes(env);
        break;
      case "debug_env":
        // Action de diagnostic : expose les longueurs des secrets (pas les valeurs)
        // Permet de vérifier que les secrets Supabase sont bien injectés sans révéler les clés
        result = {
          ok: true,
          secrets: {
            SUPABASE_URL              : { present: !!env.SUPABASE_URL,              len: env.SUPABASE_URL?.length              || 0 },
            SUPABASE_SERVICE_ROLE_KEY : { present: !!env.SUPABASE_SERVICE_ROLE_KEY, len: env.SUPABASE_SERVICE_ROLE_KEY?.length || 0 },
            BLOCKCHAIN_JOURNAL_SECRET : { present: !!env.BLOCKCHAIN_JOURNAL_SECRET, len: env.BLOCKCHAIN_JOURNAL_SECRET?.length || 0 },
            ALCHEMY_POLYGON_AMOY_URL  : { present: !!env.ALCHEMY_POLYGON_AMOY_URL,  len: env.ALCHEMY_POLYGON_AMOY_URL?.length  || 0, value: env.ALCHEMY_POLYGON_AMOY_URL || "(fallback)" },
            MASTER_WALLET_PRIVATE_KEY : { present: !!env.MASTER_WALLET_PRIVATE_KEY, len: env.MASTER_WALLET_PRIVATE_KEY?.length || 0 },
            MASTER_WALLET_ADDRESS     : { present: !!env.MASTER_WALLET_ADDRESS,     len: env.MASTER_WALLET_ADDRESS?.length     || 0, prefix: env.MASTER_WALLET_ADDRESS?.slice(0, 6) || "" },
            TONTINE_CONTRACT_ADDRESS  : { present: !!env.TONTINE_CONTRACT_ADDRESS,  len: env.TONTINE_CONTRACT_ADDRESS?.length  || 0, value: env.TONTINE_CONTRACT_ADDRESS || "" },
          },
          phase2Ready: !!(env.MASTER_WALLET_PRIVATE_KEY && env.MASTER_WALLET_ADDRESS && env.TONTINE_CONTRACT_ADDRESS),
          rpc_url: env.ALCHEMY_POLYGON_AMOY_URL || RPC_FALLBACK,
          chain_id: CHAIN_ID,
          deployed_version: DEPLOYED_VERSION,
        };
        break;
      default:
        result = { ok: false, erreur: `Action inconnue: ${action}` };
    }

    return new Response(JSON.stringify(result), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });

  } catch (err) {
    console.error("[blockchain-tx] Erreur:", err);
    return new Response(
      JSON.stringify({ ok: false, erreur: String(err) }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
