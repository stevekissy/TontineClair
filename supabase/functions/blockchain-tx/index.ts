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

// Import npm:ethereum-cryptography — keccak256 et secp256k1 certifiés Ethereum
import { keccak256 as ethKeccak256 } from "npm:ethereum-cryptography@2.2.1/keccak.js";
import { secp256k1 } from "npm:ethereum-cryptography@2.2.1/secp256k1.js";

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
  ANKR_RPC,                                          // ✅ testé OK
  "https://polygon-bor-rpc.publicnode.com",          // ✅ testé OK
  "https://1rpc.io/matic",                           // ✅ testé OK
  "https://polygon.drpc.org",                        // ✅ testé OK
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

// ── Keccak-256 certifié Ethereum (via npm:ethereum-cryptography) ───────────────
// Remplace l'implémentation pure JS maison qui produisait des hash incorrects
// (le bug de la version maison était documenté ligne 438 pour les selectors —
//  il affectait aussi le hash de signing RLP → signatures invalides → TX rejetées)

function keccak256(data: Uint8Array): Uint8Array {
  return ethKeccak256(data);
}

// ── secp256k1 ECDSA (via npm:ethereum-cryptography) ───────────────────────────
// Remplace l'implémentation pure JS maison (recovery bit incorrect → "invalid sender")
// ethereum-cryptography utilise @noble/secp256k1 — identique à ethers.js / web3.js

// Wrapper ecSign utilisant @noble/secp256k1 (via ethereum-cryptography)
// Produit des signatures EIP-2 low-S avec recovery bit correct
async function ecSign(msgHash: Uint8Array, privKeyBytes: Uint8Array): Promise<{ r: bigint; s: bigint; recovery: number }> {
  // secp256k1.sign() : RFC 6979 déterministe, low-S normalisé, recovery bit correct
  const sig = secp256k1.sign(msgHash, privKeyBytes, { lowS: true });
  return {
    r        : sig.r,
    s        : sig.s,
    recovery : sig.recovery ?? 0,
  };
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
  to       : string;  // "" ou "0x" pour création de contrat
  data     : string;
  nonce    : number;
  gasPrice : bigint;
  gasLimit : bigint;
  chainId  : number;
  privKey  : string;
}): Promise<string> {
  const { to, data, nonce, gasPrice, gasLimit, chainId, privKey } = params;

  // `to` vide = création de contrat (EIP-155)
  const toBytes = (to && to !== "0x" && to.replace("0x","").length === 40)
    ? hexToBytes(to.toLowerCase().slice(2))
    : new Uint8Array(0);  // ← adresse vide pour deploy

  // EIP-155 legacy TX fields
  const fields: Uint8Array[] = [
    stripZeros(hexToBytes(numberToHex(nonce))),       // nonce
    stripZeros(hexToBytes(numberToHex(gasPrice))),    // gasPrice
    stripZeros(hexToBytes(numberToHex(gasLimit))),    // gas
    toBytes,                                          // to (vide si deploy)
    new Uint8Array(0),                                // value (0)
    hexToBytes(data.startsWith("0x") ? data.slice(2) : data), // data/bytecode
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
    toBytes,
    new Uint8Array(0),
    hexToBytes(data.startsWith("0x") ? data.slice(2) : data),
    stripZeros(hexToBytes(numberToHex(v))),
    stripZeros(r),
    stripZeros(s),
  ];

  return "0x" + bytesToHex(rlpEncode(signedFields));
}

// ── Keccak4 selector ────────────────────────────────────────────────────────────
// TontineVaultV4 — sélecteurs calculés (keccak256 des signatures ABI)
// NOUVEAUTÉ v4 : fonctions financières ont `string devise` après uint256 montant
// → PolygonScan affiche "montant" + "devise" séparément (lisible par devise réelle)

const SELECTORS: Record<string, string> = {
  // ── Admin / lecture ────────────────────────────────────────────────────────
  "admin()": "0xf851a440",
  "getInfo()": "0x5a9b0b89",
  "totalOperations()": "0xed232029",
  "transfererAdmin(address)": "0xb38ff71f",
  "version()": "0x54fd4d50",
  // ── Finances V4 (string,string,string,uint256,string,string,bytes32) ───────
  // Paramètres: tontineCode, membreId, membreNom, montant, devise, refInterne, payloadHash
  "enregistrerCotisation(string,string,string,uint256,string,string,bytes32)": "0x4aaf7eb7",
  "enregistrerDistribution(string,string,string,uint256,string,string,bytes32)": "0x2d024ca9",
  "enregistrerDecaissement(string,string,string,uint256,string,string,bytes32)": "0x309cf62d",
  "enregistrerDepot(string,string,string,uint256,string,string,bytes32)": "0x4eb4f9b2",
  "enregistrerPret(string,string,string,uint256,string,string,bytes32)": "0x80a8d536",
  "enregistrerRemboursement(string,string,string,uint256,string,string,bytes32)": "0x3f83aea8",
  "enregistrerPenalite(string,string,string,uint256,string,string,bytes32)": "0xbf24a357",
  "enregistrerRetrait(string,string,string,uint256,string,string,bytes32)": "0xc438e7d5",
  "enregistrerApport(string,string,string,uint256,string,string,bytes32)": "0x9f8dae2b",
  "enregistrerSynchronisation(string,string,string,uint256,string,string,bytes32)": "0x95bf6b66",
  // ── Votes (inchangées — même signature V3) ─────────────────────────────────
  "enregistrerVoteCree(string,string,string,string,bytes32)": "0x05797094",
  "enregistrerVoteClos(string,string,string,string,bytes32)": "0xf4ef3be9",
  "enregistrerVoteIndividuel(string,string,string,string,bytes32)": "0xace3c9ee",
  "enregistrerRetraitPropose(string,string,string,string,bytes32)": "0x49b4279e",
  // ── Système (inchangées — même signature V3) ───────────────────────────────
  "enregistrerCreation(string,string,string,string,bytes32)": "0x69d1a0f8",
  "enregistrerUpgradePro(string,string,string,bytes32)": "0x0496be90",
  "enregistrerNouveauCycle(string,string,string,string,bytes32)": "0x19c2cd10",
  "enregistrerScoreModifie(string,string,string,string,bytes32)": "0x89808c56",
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

// ══════════════════════════════════════════════════════════════════════════════
// BUILD CALLDATA — TontineVaultV3 (une fonction par action métier)
// ══════════════════════════════════════════════════════════════════════════════

// Helper ABI encoder commun
function _encStr(s: string): string {
  const encoder = new TextEncoder();
  const b = encoder.encode(s);
  return encodeUint256(b.length) + bytesToHex(b).padEnd(Math.ceil(b.length / 32) * 64, "0");
}

/**
 * Finance V4 : (string tontineCode, string membreId, string membreNom,
 *               uint256 montant, string devise, string refInterne, bytes32 payloadHash)
 *
 * NOUVEAUTÉ v4 : `devise` est un paramètre string séparé → PolygonScan affiche :
 *   - param3 "montant"   : 9900          ← valeur numérique
 *   - param4 "devise"    : "EUR"         ← devise réelle de la tontine ✅
 *   - param5 "refInterne": "JX9FKY | Cotisation | Jean | 9900 EUR"
 *
 * Utilisé par : enregistrerCotisation, enregistrerDistribution, enregistrerDecaissement,
 *               enregistrerDepot, enregistrerPret, enregistrerRemboursement,
 *               enregistrerPenalite, enregistrerRetrait, enregistrerApport,
 *               enregistrerSynchronisation
 */
function buildFinanceCalldata_v4(
  tontineCode : string | number,
  membreId    : string | number,
  membreNom   : string | number,
  montant     : number,
  devise      : string,          // ← NOUVEAU : "EUR", "USD", "XOF", "NGN"…
  montantUsdt : number,          // non utilisé dans le contrat — gardé pour compatibilité interne
  refInterne  : string,
  funcName    : string,
  payloadHash : Uint8Array
): string {
  // Signature V4 : 7 params (string×3 + uint256 + string×2 + bytes32)
  const sig = `${funcName}(string,string,string,uint256,string,string,bytes32)`;
  const sel = functionSelector(sig);

  const s1  = _encStr(String(tontineCode));
  const s2  = _encStr(String(membreId));
  const s3  = _encStr(String(membreNom || ""));
  const s4  = _encStr(devise || "XOF");  // devise string (param4 = dynamic)
  const s5  = _encStr(refInterne);       // refInterne string (param5 = dynamic)
  const ph  = bytesToHex(payloadHash).padEnd(64, "0");

  // 7 params: string(dyn) string(dyn) string(dyn) uint256(static) string(dyn) string(dyn) bytes32(static)
  // Slots tête: 7 × 32 = 224 bytes
  // param0 offset, param1 offset, param2 offset, montant (uint256), param4 offset, param5 offset, payloadHash (bytes32)
  const base = 7 * 32;  // 224 bytes = 7 slots
  const o0   = base;
  const o1   = o0 + s1.length / 2;
  const o2   = o1 + s2.length / 2;
  // param3 = uint256 montant (static — pas d'offset)
  const o4   = o2 + s3.length / 2;  // offset de devise (après param3 static)
  const o5   = o4 + s4.length / 2;  // offset de refInterne

  const staticPart =
    encodeUint256(o0) +     // param0: tontineCode offset
    encodeUint256(o1) +     // param1: membreId offset
    encodeUint256(o2) +     // param2: membreNom offset
    encodeUint256(montant) + // param3: montant (static uint256)
    encodeUint256(o4) +     // param4: devise offset
    encodeUint256(o5) +     // param5: refInterne offset
    ph;                     // param6: payloadHash (static bytes32)

  return sel + staticPart + s1 + s2 + s3 + s4 + s5;
}

/**
 * Vote v3 : (string tontineCode, string membreId, string membreNom,
 *            string refVote, bytes32 payloadHash)
 * Utilisé par : enregistrerVoteCree, enregistrerVoteClos,
 *               enregistrerVoteIndividuel, enregistrerRetraitPropose
 */
function buildVoteCalldata_v3(
  tontineCode : string | number,
  membreId    : string | number,
  membreNom   : string | number,
  refVote     : string,
  funcName    : string,
  payloadHash : Uint8Array
): string {
  const sig = `${funcName}(string,string,string,string,bytes32)`;
  const sel = functionSelector(sig);

  const s1  = _encStr(String(tontineCode));
  const s2  = _encStr(String(membreId));
  const s3  = _encStr(String(membreNom || ""));
  const s4  = _encStr(refVote);
  const ph  = bytesToHex(payloadHash).padEnd(64, "0");

  // 5 params: string(dyn) string(dyn) string(dyn) string(dyn) bytes32(static)
  const base = 5 * 32;  // 160 bytes
  const o0   = base;
  const o1   = o0 + s1.length / 2;
  const o2   = o1 + s2.length / 2;
  const o3   = o2 + s3.length / 2;

  const staticPart =
    encodeUint256(o0) +
    encodeUint256(o1) +
    encodeUint256(o2) +
    encodeUint256(o3) +
    ph;

  return sel + staticPart + s1 + s2 + s3 + s4;
}

/**
 * Création v3 : (string tontineCode, string gestionnaireId, string gestionnaireNom,
 *                string nomTontine, bytes32 payloadHash)
 */
function buildCreationCalldata_v3(
  tontineCode : string | number,
  gestId      : string | number,
  gestNom     : string | number,
  nomTontine  : string,
  payloadHash : Uint8Array
): string {
  return buildVoteCalldata_v3(tontineCode, gestId, gestNom, nomTontine, "enregistrerCreation", payloadHash);
}

/**
 * Système v3 : (string tontineCode, string membreId, string membreNom,
 *               string details, bytes32 payloadHash)
 * Utilisé par : enregistrerNouveauCycle, enregistrerScoreModifie
 *
 * UpgradePro : (string tontineCode, string gestionnaireId, string gestionnaireNom,
 *               bytes32 payloadHash)  — 4 params seulement
 */
function buildSysCalldata_v3(
  tontineCode : string | number,
  membreId    : string | number,
  membreNom   : string | number,
  details     : string,
  funcName    : string,
  payloadHash : Uint8Array
): string {
  if (funcName === "enregistrerUpgradePro") {
    // Signature spéciale : 4 params (string,string,string,bytes32)
    const sig = "enregistrerUpgradePro(string,string,string,bytes32)";
    const sel = functionSelector(sig);

    const s1 = _encStr(String(tontineCode));
    const s2 = _encStr(String(membreId));
    const s3 = _encStr(String(membreNom || ""));
    const ph = bytesToHex(payloadHash).padEnd(64, "0");

    const base = 4 * 32;
    const o0   = base;
    const o1   = o0 + s1.length / 2;
    const o2   = o1 + s2.length / 2;

    return sel + encodeUint256(o0) + encodeUint256(o1) + encodeUint256(o2) + ph + s1 + s2 + s3;
  }
  // Autres : 5 params (string,string,string,string,bytes32)
  return buildVoteCalldata_v3(tontineCode, membreId, membreNom, details, funcName, payloadHash);
}

// ── Envoyer une TX on-chain (avec fallback multi-RPC pour le broadcast) ─────────

async function sendOnChainTx(
  rpcUrl      : string,
  contractAddr: string,
  calldata    : string,
  privKey     : string,
  fromAddr    : string
): Promise<{ txHash: string; blockNumber: number; broadcastError?: string } | null> {
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
      // Retourner l'erreur pour diagnostic (au lieu de null silencieux)
      return { txHash: "", blockNumber: 0, broadcastError };
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
  // FIX: utiliser ?? "" pour éviter "undefined" JavaScript quand la clé est absente du body
  // Flutter envoie les clés uniquement si la valeur est non-null (if (membreId != null))
  // → si membreId est null côté Flutter, la clé n'arrive pas → JS destructuring = undefined
  const tontine_code     = String(body.tontine_code    ?? "").toUpperCase();
  const type_operation   = String(body.type_operation  ?? "");
  const membre_id        = String(body.membre_id        ?? "");   // ← jamais "undefined"
  const membre_nom       = String(body.membre_nom       ?? "");   // ← jamais vide par erreur
  const montant_xof      = body.montant_xof;
  const ref_coinpayments = body.ref_coinpayments;
  const ref_interne      = body.ref_interne;

  // Devise réelle de la tontine — lue depuis body.devise OU body.metadata.devise
  // Envoyée par Flutter dans _enregistrer() → affichée dans Polygonscan Input Data
  // devise lue depuis body.devise (racine — priorité) ou body.metadata.devise (fallback)
  const metadataBody = body.metadata as Record<string, unknown> | undefined;
  const devise = String(body.devise ?? metadataBody?.devise ?? "").trim().toUpperCase();

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

      // ── Routing v3 : une fonction métier par type → noms lisibles sur PolygonScan ──
      const memNom = String(body.membre_nom || membre_nom || "");
      const refBrut = String(ref_interne || "");

      // ── Libellés lisibles en français — encodés dans le champ refInterne ──────────
      // Visibles directement sur PolygonScan dans les paramètres de la TX,
      // même sans vérification du contrat (onglet "Input Data" → décodage UTF-8).
      // Format : "[NOM_OPERATION] | membre | ref_optionnelle"
      const LIBELLES: Record<string, string> = {
        "cotisation"      : "Cotisation",
        "distribution"    : "Distribution du tour",
        "decaissement"    : "Décaissement",
        "depot"           : "Dépôt",
        "pret"            : "Prêt accordé",
        "remboursement"   : "Remboursement de prêt",
        "remboursement_pret": "Remboursement de prêt",
        "penalite"        : "Pénalité",
        "retrait"         : "Retrait",
        "apport"          : "Apport en caisse",
        "sync_balance"    : "Synchronisation solde",
        "synchronisation" : "Synchronisation solde",
        "vote"            : "Vote",
        "vote_cree"       : "Vote ouvert",
        "vote_clos"       : "Vote clôturé",
        "retrait_propose" : "Retrait proposé",
        "creation"        : "Création tontine",
        "upgrade_pro"     : "Passage Pro",
        "nouveau_cycle"   : "Nouveau cycle",
        "score_modifie"   : "Score modifié",
      };

      // Construire le refInterne lisible — visible dans "Input Data" sur PolygonScan
      // Format : "CODE_TONTINE | Libellé opération | Membre | ref_optionnelle | montant DEVISE"
      // Le code tontine EN PREMIER garantit qu'on sait immédiatement de quelle tontine
      // il s'agit en lisant les paramètres de la TX sur PolygonScan, même sans contrat vérifié.
      const libelle = LIBELLES[typeOp] || typeOp.replace(/_/g, " ");
      const codeStr = String(tontine_code).toUpperCase();
      const refParts: string[] = [codeStr, libelle];  // ← code tontine en tête
      if (memNom) refParts.push(memNom);
      if (refBrut && refBrut !== memNom) refParts.push(refBrut);
      // ── Montant + Devise visible sur PolygonScan ─────────────────────────
      // Point 4 fix : afficher "montantEUR=9900" au lieu de "montantXof=9900"
      // pour les tontines en devise non-XOF dans le champ refInterne.
      // La clé ABI du contrat est fixe (montant uint256) mais refInterne est
      // une string libre → on y encode la clé dynamique montant${DEVISE}.
      // Ex: "JX9FKY | Cotisation | Jean Dupont | montantEUR=9900"
      //     "JX9FKY | Cotisation | Jean Dupont | montantXOF=5000"
      //     "JX9FKY | Cotisation | Jean Dupont | montantNGN=100"
      const deviseKey = devise ? `montant${devise}` : "montantXOF";
      if (montantXof > 0 && devise) {
        refParts.push(`${deviseKey}=${montantXof}`);
      } else if (montantXof > 0) {
        // Pas de devise connue — on affiche montantXOF pour compatibilité
        refParts.push(`montantXOF=${montantXof}`);
      } else if (devise) {
        // Montant nul (sync, vote…) — on affiche quand même la devise de la tontine
        refParts.push(devise);
      }
      const ref = refParts.join(" | ");

      switch (typeOp) {
        // ── Votes ────────────────────────────────────────────────────────────
        case "vote_cree":
          calldata = buildVoteCalldata_v3(tontine_code, membre_id, memNom, ref, "enregistrerVoteCree", payloadBytes); break;
        case "vote_clos":
          calldata = buildVoteCalldata_v3(tontine_code, membre_id, memNom, ref, "enregistrerVoteClos", payloadBytes); break;
        case "vote":
          calldata = buildVoteCalldata_v3(tontine_code, membre_id, memNom, String(body.question || ref), "enregistrerVoteIndividuel", payloadBytes); break;
        case "retrait_propose":
          calldata = buildVoteCalldata_v3(tontine_code, membre_id, memNom, ref, "enregistrerRetraitPropose", payloadBytes); break;
        // ── Système ──────────────────────────────────────────────────────────
        case "creation":
          calldata = buildCreationCalldata_v3(tontine_code, membre_id, memNom, String(body.nom_tontine || tontine_code), payloadBytes); break;
        case "upgrade_pro":
          calldata = buildSysCalldata_v3(tontine_code, membre_id, memNom, ref, "enregistrerUpgradePro", payloadBytes); break;
        case "nouveau_cycle":
          calldata = buildSysCalldata_v3(tontine_code, membre_id, memNom, ref, "enregistrerNouveauCycle", payloadBytes); break;
        case "score_modifie":
          calldata = buildSysCalldata_v3(tontine_code, membre_id, memNom, ref, "enregistrerScoreModifie", payloadBytes); break;
        // ── Finances V4 (avec devise) ─────────────────────────────────────────
        // buildFinanceCalldata_v4 encode: tontineCode, membreId, membreNom,
        //   montant (uint256), devise (string), refInterne (string), payloadHash
        // → PolygonScan affiche: montant=9900 | devise="EUR" | refInterne="JX9FKY|..."
        case "cotisation":
          calldata = buildFinanceCalldata_v4(tontine_code, membre_id, memNom, montantXof, devise, montantUsdt, ref, "enregistrerCotisation", payloadBytes); break;
        case "distribution":
          calldata = buildFinanceCalldata_v4(tontine_code, membre_id, memNom, montantXof, devise, montantUsdt, ref, "enregistrerDistribution", payloadBytes); break;
        case "decaissement":
          calldata = buildFinanceCalldata_v4(tontine_code, membre_id, memNom, montantXof, devise, montantUsdt, ref, "enregistrerDecaissement", payloadBytes); break;
        case "depot":
          calldata = buildFinanceCalldata_v4(tontine_code, membre_id, memNom, montantXof, devise, montantUsdt, ref, "enregistrerDepot", payloadBytes); break;
        case "pret":
          calldata = buildFinanceCalldata_v4(tontine_code, membre_id, memNom, montantXof, devise, montantUsdt, ref, "enregistrerPret", payloadBytes); break;
        case "remboursement":
        case "remboursement_pret":
          calldata = buildFinanceCalldata_v4(tontine_code, membre_id, memNom, montantXof, devise, montantUsdt, ref, "enregistrerRemboursement", payloadBytes); break;
        case "penalite":
          calldata = buildFinanceCalldata_v4(tontine_code, membre_id, memNom, montantXof, devise, montantUsdt, ref, "enregistrerPenalite", payloadBytes); break;
        case "retrait":
          calldata = buildFinanceCalldata_v4(tontine_code, membre_id, memNom, montantXof, devise, montantUsdt, ref, "enregistrerRetrait", payloadBytes); break;
        case "apport":
          calldata = buildFinanceCalldata_v4(tontine_code, membre_id, memNom, montantXof, devise, montantUsdt, ref, "enregistrerApport", payloadBytes); break;
        case "sync_balance":
        case "synchronisation":
          calldata = buildFinanceCalldata_v4(tontine_code, membre_id, memNom, montantXof, devise, montantUsdt, ref, "enregistrerSynchronisation", payloadBytes); break;
        default:
          // Fallback : type inconnu → enregistrerSynchronisation
          calldata = buildFinanceCalldata_v4(tontine_code, membre_id, memNom, montantXof, devise, montantUsdt, ref, "enregistrerSynchronisation", payloadBytes); break;
      }

      const onChain = await sendOnChainTx(rpcUrl, contractAddr, calldata, privKey, fromAddr);
      if (onChain && onChain.txHash && onChain.txHash.startsWith("0x") && onChain.txHash.length === 66) {
        txHash      = onChain.txHash;
        blockNumber = onChain.blockNumber;
        statut      = blockNumber > 0 ? "confirmed" : "pending";
        phase       = 2;
        console.log(`[blockchain-tx] Phase 2 TX: ${txHash} block=${blockNumber}`);
      } else if (onChain?.broadcastError) {
        // Broadcast échoué — stocker l'erreur pour diagnostic
        (globalThis as Record<string, unknown>).__lastPhase2Error = `broadcast_failed: ${onChain.broadcastError}`;
        console.error(`[blockchain-tx] Broadcast échoué: ${onChain.broadcastError}`);
      }
    } catch (err) {
      console.error(`[blockchain-tx] Phase 2 error, fallback Phase 1: ${err}`);
      // Fallback silencieux → on garde phase1Hash
      // Stocker l'erreur pour debug (visible dans la réponse si phase=1)
      (globalThis as Record<string, unknown>).__lastPhase2Error = String(err);
    }
  }

  // Insérer dans blockchain_journal
  // FIX: membre_nom stocké à la fois dans la colonne directe ET dans metadata
  // (colonne directe = lu par Flutter via j['membre_nom'] pour descriptionMetier)
  const membreNomStr = membre_nom ? String(membre_nom) : null;
  const entry = await supabaseInsert(supabaseUrl, serviceKey, "blockchain_journal", {
    tontine_code   : String(tontine_code).toUpperCase(),
    type_operation : String(type_operation),
    membre_id      : String(membre_id ?? ''),  // FIX: évite "undefined" quand membre_id absent
    membre_nom     : membreNomStr,            // ← FIX: colonne directe (était absent)
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
      membre_nom  : membreNomStr,             // ← conservé pour rétrocompatibilité
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

  const limit   = Math.min(Number(body.limit) || 20, 500);
  const offset  = Number(body.offset) || 0;
  const tontine = body.tontine_code ? `&tontine_code=eq.${body.tontine_code}` : "";
  const statut  = body.statut && body.statut !== "tous" ? `&statut=eq.${body.statut}` : "";
  const typeOp  = body.type_operation && body.type_operation !== "tous" ? `&type_operation=eq.${body.type_operation}` : "";

  const url = `${supabaseUrl}/rest/v1/blockchain_journal?select=*&order=created_at.desc&limit=${limit}&offset=${offset}${tontine}${statut}${typeOp}`;
  const res = await fetch(url, {
    headers: { "apikey": serviceKey, "Authorization": `Bearer ${serviceKey}` }
  });
  const rows = await res.json() as unknown[];

  // Enrichir avec explorer_url + récupérer membre_nom depuis metadata si absent
  // (rétrocompatibilité : anciennes entrées n'ont pas membre_nom en colonne directe)
  const enriched = (rows as Record<string, unknown>[]).map(r => {
    const meta = (r.metadata as Record<string, unknown> | null) ?? {};

    // Récupérer membre_nom : colonne directe en priorité, sinon metadata
    const membreNom = r.membre_nom
      || meta["membre_nom"]
      || null;

    return {
      ...r,
      membre_nom    : membreNom,   // ← FIX: garantit que Flutter reçoit le nom
      explorer_url  : r.tx_hash && String(r.tx_hash).length === 66
        ? `${EXPLORER_BASE}/tx/${r.tx_hash}`
        : null,
      explorer_contract: env.TONTINE_CONTRACT_ADDRESS
        ? `${EXPLORER_BASE}/address/${env.TONTINE_CONTRACT_ADDRESS}`
        : null,
    };
  });

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

// ── Action : verifier_contrat_polygonscan ─────────────────────────────────────
// Soumet le code source de TontineVaultV4 à PolygonScan pour vérification.
// Une fois vérifié : PolygonScan affiche le nom des fonctions ("enregistrerCotisation"
// au lieu de "0x4aaf7eb7") ET les noms des paramètres (tontineCode, membreId, montant, devise…)
// Nécessite un secret POLYGONSCAN_API_KEY dans Supabase.
async function actionVerifierContratPolygonscan(
  env: Record<string, string>
): Promise<Record<string, unknown>> {
  const contractAddr   = env.TONTINE_CONTRACT_ADDRESS || "";
  const polygonscanKey = env.POLYGONSCAN_API_KEY || "";

  if (!contractAddr) {
    return { ok: false, erreur: "TONTINE_CONTRACT_ADDRESS non configuré" };
  }

  // Code source de TontineVaultV4 — doit correspondre exactement au bytecode déployé
  // compilé avec: solc 0.8.20 --optimize --runs 200
  const sourceCode = `// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract TontineVaultV4 {

    address public admin;
    string  public version = "4.0.0";
    uint256 public totalOperations;

    event OperationEnregistree(
        string indexed tontineCode,
        string typeOperation,
        string membreId,
        string membreNom,
        uint256 montant,
        string devise,
        string refInterne,
        bytes32 payloadHash,
        uint256 timestamp
    );

    event AdminTransfere(address indexed ancien, address indexed nouveau, uint256 timestamp);

    modifier onlyAdmin() {
        require(msg.sender == admin, "Acces refuse: admin uniquement");
        _;
    }

    constructor() {
        admin = msg.sender;
        emit AdminTransfere(address(0), msg.sender, block.timestamp);
    }

    function _enregistrer(
        string memory tontineCode,
        string memory typeOperation,
        string memory membreId,
        string memory membreNom,
        uint256 montant,
        string memory devise,
        string memory refInterne,
        bytes32 payloadHash
    ) internal {
        totalOperations++;
        emit OperationEnregistree(tontineCode, typeOperation, membreId, membreNom, montant, devise, refInterne, payloadHash, block.timestamp);
    }

    function enregistrerCotisation(string memory tontineCode, string memory membreId, string memory membreNom, uint256 montant, string memory devise, string memory refInterne, bytes32 payloadHash) external {
        _enregistrer(tontineCode, "cotisation", membreId, membreNom, montant, devise, refInterne, payloadHash);
    }
    function enregistrerDistribution(string memory tontineCode, string memory membreId, string memory membreNom, uint256 montant, string memory devise, string memory refInterne, bytes32 payloadHash) external {
        _enregistrer(tontineCode, "distribution", membreId, membreNom, montant, devise, refInterne, payloadHash);
    }
    function enregistrerDecaissement(string memory tontineCode, string memory membreId, string memory membreNom, uint256 montant, string memory devise, string memory refInterne, bytes32 payloadHash) external {
        _enregistrer(tontineCode, "decaissement", membreId, membreNom, montant, devise, refInterne, payloadHash);
    }
    function enregistrerDepot(string memory tontineCode, string memory membreId, string memory membreNom, uint256 montant, string memory devise, string memory refInterne, bytes32 payloadHash) external {
        _enregistrer(tontineCode, "depot", membreId, membreNom, montant, devise, refInterne, payloadHash);
    }
    function enregistrerPret(string memory tontineCode, string memory membreId, string memory membreNom, uint256 montant, string memory devise, string memory refInterne, bytes32 payloadHash) external {
        _enregistrer(tontineCode, "pret", membreId, membreNom, montant, devise, refInterne, payloadHash);
    }
    function enregistrerRemboursement(string memory tontineCode, string memory membreId, string memory membreNom, uint256 montant, string memory devise, string memory refInterne, bytes32 payloadHash) external {
        _enregistrer(tontineCode, "remboursement", membreId, membreNom, montant, devise, refInterne, payloadHash);
    }
    function enregistrerPenalite(string memory tontineCode, string memory membreId, string memory membreNom, uint256 montant, string memory devise, string memory refInterne, bytes32 payloadHash) external {
        _enregistrer(tontineCode, "penalite", membreId, membreNom, montant, devise, refInterne, payloadHash);
    }
    function enregistrerRetrait(string memory tontineCode, string memory membreId, string memory membreNom, uint256 montant, string memory devise, string memory refInterne, bytes32 payloadHash) external {
        _enregistrer(tontineCode, "retrait", membreId, membreNom, montant, devise, refInterne, payloadHash);
    }
    function enregistrerApport(string memory tontineCode, string memory membreId, string memory membreNom, uint256 montant, string memory devise, string memory refInterne, bytes32 payloadHash) external {
        _enregistrer(tontineCode, "apport", membreId, membreNom, montant, devise, refInterne, payloadHash);
    }
    function enregistrerSynchronisation(string memory tontineCode, string memory membreId, string memory membreNom, uint256 montant, string memory devise, string memory refInterne, bytes32 payloadHash) external {
        _enregistrer(tontineCode, "synchronisation", membreId, membreNom, montant, devise, refInterne, payloadHash);
    }
    function enregistrerVoteCree(string memory tontineCode, string memory membreId, string memory membreNom, string memory refVote, bytes32 payloadHash) external {
        _enregistrer(tontineCode, "vote_cree", membreId, membreNom, 0, "", refVote, payloadHash);
    }
    function enregistrerVoteClos(string memory tontineCode, string memory membreId, string memory membreNom, string memory refVote, bytes32 payloadHash) external {
        _enregistrer(tontineCode, "vote_clos", membreId, membreNom, 0, "", refVote, payloadHash);
    }
    function enregistrerVoteIndividuel(string memory tontineCode, string memory membreId, string memory membreNom, string memory refVote, bytes32 payloadHash) external {
        _enregistrer(tontineCode, "vote", membreId, membreNom, 0, "", refVote, payloadHash);
    }
    function enregistrerRetraitPropose(string memory tontineCode, string memory membreId, string memory membreNom, string memory refVote, bytes32 payloadHash) external {
        _enregistrer(tontineCode, "retrait_propose", membreId, membreNom, 0, "", refVote, payloadHash);
    }
    function enregistrerCreation(string memory tontineCode, string memory membreId, string memory membreNom, string memory nomTontine, bytes32 payloadHash) external {
        _enregistrer(tontineCode, "creation", membreId, membreNom, 0, "", nomTontine, payloadHash);
    }
    function enregistrerUpgradePro(string memory tontineCode, string memory membreId, string memory membreNom, bytes32 payloadHash) external {
        _enregistrer(tontineCode, "upgrade_pro", membreId, membreNom, 0, "", "", payloadHash);
    }
    function enregistrerNouveauCycle(string memory tontineCode, string memory membreId, string memory membreNom, string memory details, bytes32 payloadHash) external {
        _enregistrer(tontineCode, "nouveau_cycle", membreId, membreNom, 0, "", details, payloadHash);
    }
    function enregistrerScoreModifie(string memory tontineCode, string memory membreId, string memory membreNom, string memory details, bytes32 payloadHash) external {
        _enregistrer(tontineCode, "score_modifie", membreId, membreNom, 0, "", details, payloadHash);
    }

    function transfererAdmin(address nouvelAdmin) external onlyAdmin {
        require(nouvelAdmin != address(0), "Adresse invalide");
        emit AdminTransfere(admin, nouvelAdmin, block.timestamp);
        admin = nouvelAdmin;
    }

    function getInfo() external view returns (address, string memory, uint256, uint256) {
        return (admin, version, totalOperations, block.timestamp);
    }
}`;

  try {
    const body = new URLSearchParams({
      apikey             : polygonscanKey || "YourApiKeyToken",
      module             : "contract",
      action             : "verifysourcecode",
      contractaddress    : contractAddr,
      sourceCode,
      codeformat         : "solidity-single-file",
      contractname       : "TontineVaultV4",
      compilerversion    : "v0.8.20+commit.a1b79de6",
      optimizationUsed   : "1",
      runs               : "200",
      licenseType        : "3",  // MIT
    });

    const resp = await fetch("https://api.polygonscan.com/api", {
      method : "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body   : body.toString(),
      signal : AbortSignal.timeout(30000),
    });

    const result = await resp.json() as { status: string; message: string; result: string };

    if (result.status === "1") {
      // Vérification soumise — PolygonScan va vérifier de façon asynchrone
      return {
        ok     : true,
        guid   : result.result,  // GUID pour vérifier le statut
        message: "Vérification soumise à PolygonScan. Vérifiez le statut dans 1-2 minutes.",
        check_status_url: `https://api.polygonscan.com/api?module=contract&action=checkverifystatus&guid=${result.result}&apikey=${polygonscanKey || "YourApiKeyToken"}`,
        explorer: `${EXPLORER_BASE}/address/${contractAddr}#code`,
      };
    } else {
      return {
        ok     : false,
        erreur : result.result || result.message,
        conseil: result.result?.includes("Already Verified")
          ? "Le contrat est déjà vérifié sur PolygonScan ✅"
          : "Vérifier que le bytecode compilé correspond au contrat déployé",
      };
    }
  } catch (err) {
    return { ok: false, erreur: String(err) };
  }
}

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


// ── Action : deploy_v4 — Déploie TontineVaultV4 sur Polygon Mainnet ───────────
// Bytecode compilé de TontineVaultV4.sol (solc 0.8.20 --optimize 200)
// NOUVEAUTÉ v4 : param `montant` (uint256) + `devise` (string) dans les fonctions
// financières → PolygonScan affiche la devise réelle de chaque tontine.
const TONTINE_VAULT_V4_BYTECODE = "0x60c060405260056080908152640342e302e360dc1b60a05260019062000026908262000123565b5034801562000033575f80fd5b505f80546001600160a01b0319163390811782556040514281529091907f017157264e61ac54ef1bcfc8259e7eb3473c3d76e3461c0c0d360a140233b7c89060200160405180910390a3620001eb565b634e487b7160e01b5f52604160045260245ffd5b600181811c90821680620000ac57607f821691505b602082108103620000cb57634e487b7160e01b5f52602260045260245ffd5b50919050565b601f8211156200011e575f81815260208120601f850160051c81016020861015620000f95750805b601f850160051c820191505b818110156200011a5782815560010162000105565b5050505b505050565b81516001600160401b038111156200013f576200013f62000083565b620001578162000150845462000097565b84620000d1565b602080601f8311600181146200018d575f8415620001755750858301515b5f19600386901b1c1916600185901b1785556200011a565b5f85815260208120601f198616915b82811015620001bd578886015182559484019460019091019084016200019c565b5085821015620001db57878501515f19600388901b60f8161c191681555b5050505050600190811b01905550565b61183480620001f95f395ff3fe608060405234801561000f575f80fd5b5060043610610148575f3560e01c806369d1a0f8116100bf578063b38ff71f11610079578063b38ff71f146102a1578063bf24a357146102b4578063c438e7d5146102c7578063ed232029146102da578063f4ef3be9146102f1578063f851a44014610304575f80fd5b806369d1a0f81461022f57806380a8d5361461024257806389808c561461025557806395bf6b66146102685780639f8dae2b1461027b578063ace3c9ee1461028e575f80fd5b80633f83aea8116101105780633f83aea8146101ad57806349b4279e146101c05780634aaf7eb7146101d35780634eb4f9b2146101e657806354fd4d50146101f95780635a9b0b8914610217575f80fd5b80630496be901461014c578063057970941461016157806319c2cd10146101745780632d024ca914610187578063309cf62d1461019a575b5f80fd5b61015f61015a366004610ef3565b61032e565b005b61015f61016f366004610f8e565b6103c3565b61015f610182366004610f8e565b610455565b61015f610195366004611050565b6104d4565b61015f6101a8366004611050565b61056f565b61015f6101bb366004611050565b6105f4565b61015f6101ce366004610f8e565b610679565b61015f6101e1366004611050565b6106f8565b61015f6101f4366004611050565b61077d565b610201610802565b60405161020e91906111aa565b60405180910390f35b61021f61088e565b60405161020e94939291906111c3565b61015f61023d366004610f8e565b610949565b61015f610250366004611050565b6109c8565b61015f610263366004610f8e565b610a4d565b61015f610276366004611050565b610acc565b61015f610289366004611050565b610b51565b61015f61029c366004610f8e565b610bd6565b61015f6102af3660046111f9565b610c55565b61015f6102c2366004611050565b610d25565b61015f6102d5366004611050565b610daa565b6102e360025481565b60405190815260200161020e565b61015f6102ff366004610f8e565b610e2f565b5f54610316906001600160a01b031681565b6040516001600160a01b03909116815260200161020e565b5f546001600160a01b031633146103605760405162461bcd60e51b81526004016103579061121f565b60405180910390fd5b60028054905f61036f83611256565b9190505550868660405161038492919061127a565b60405180910390205f805160206117df8339815191528686868686426040516103b2969594939291906112b1565b60405180910390a250505050505050565b5f546001600160a01b031633146103ec5760405162461bcd60e51b81526004016103579061121f565b60028054905f6103fb83611256565b9190505550888860405161041092919061127a565b60405180910390205f8051602061179f8339815191528888888888888842604051610442989796959493929190611320565b60405180910390a2505050505050505050565b5f546001600160a01b0316331461047e5760405162461bcd60e51b81526004016103579061121f565b60028054905f61048d83611256565b919050555088886040516104a292919061127a565b60405180910390205f805160206117df8339815191528888888888888842604051610442989796959493929190611396565b5f546001600160a01b031633146104fd5760405162461bcd60e51b81526004016103579061121f565b60028054905f61050c83611256565b91905055508b8b60405161052192919061127a565b60405180910390205f805160206117bf8339815191528b8b8b8b8b8b8b8b8b8b426040516105599b9a999897969594939291906113ce565b60405180910390a2505050505050505050505050565b5f546001600160a01b031633146105985760405162461bcd60e51b81526004016103579061121f565b60028054905f6105a783611256565b91905055508b8b6040516105bc92919061127a565b60405180910390205f805160206117bf8339815191528b8b8b8b8b8b8b8b8b8b426040516105599b9a99989796959493929190611467565b5f546001600160a01b0316331461061d5760405162461bcd60e51b81526004016103579061121f565b60028054905f61062c83611256565b91905055508b8b60405161064192919061127a565b60405180910390205f805160206117bf8339815191528b8b8b8b8b8b8b8b8b8b426040516105599b9a999897969594939291906114a2565b5f546001600160a01b031633146106a25760405162461bcd60e51b81526004016103579061121f565b60028054905f6106b183611256565b919050555088886040516106c692919061127a565b60405180910390205f8051602061179f83398151915288888888888888426040516104429897969594939291906114de565b5f546001600160a01b031633146107215760405162461bcd60e51b81526004016103579061121f565b60028054905f61073083611256565b91905055508b8b60405161074592919061127a565b60405180910390205f805160206117bf8339815191528b8b8b8b8b8b8b8b8b8b426040516105599b9a99989796959493929190611518565b5f546001600160a01b031633146107a65760405162461bcd60e51b81526004016103579061121f565b60028054905f6107b583611256565b91905055508b8b6040516107ca92919061127a565b60405180910390205f805160206117bf8339815191528b8b8b8b8b8b8b8b8b8b426040516105599b9a99989796959493929190611551565b6001805461080f90611585565b80601f016020809104026020016040519081016040528092919081815260200182805461083b90611585565b80156108865780601f1061085d57610100808354040283529160200191610886565b820191905f5260205f20905b81548152906001019060200180831161086957829003601f168201915b505050505081565b5f60605f805f4690505f8054906101000a90046001600160a01b03166001600254838280546108bc90611585565b80601f01602080910402602001604051908101604052809291908181526020018280546108e890611585565b80156109335780601f1061090a57610100808354040283529160200191610933565b820191905f5260205f20905b81548152906001019060200180831161091657829003601f168201915b5050505050925094509450945094505090919293565b5f546001600160a01b031633146109725760405162461bcd60e51b81526004016103579061121f565b60028054905f61098183611256565b9190505550888860405161099692919061127a565b60405180910390205f805160206117df83398151915288888888888888426040516104429897969594939291906115bd565b5f546001600160a01b031633146109f15760405162461bcd60e51b81526004016103579061121f565b60028054905f610a0083611256565b91905055508b8b604051610a1592919061127a565b60405180910390205f805160206117bf8339815191528b8b8b8b8b8b8b8b8b8b426040516105599b9a999897969594939291906115f0565b5f546001600160a01b03163314610a765760405162461bcd60e51b81526004016103579061121f565b60028054905f610a8583611256565b91905055508888604051610a9a92919061127a565b60405180910390205f805160206117df8339815191528888888888888842604051610442989796959493929190611623565b5f546001600160a01b03163314610af55760405162461bcd60e51b81526004016103579061121f565b60028054905f610b0483611256565b91905055508b8b604051610b1992919061127a565b60405180910390205f805160206117bf8339815191528b8b8b8b8b8b8b8b8b8b426040516105599b9a9998979695949392919061165b565b5f546001600160a01b03163314610b7a5760405162461bcd60e51b81526004016103579061121f565b60028054905f610b8983611256565b91905055508b8b604051610b9e92919061127a565b60405180910390205f805160206117bf8339815191528b8b8b8b8b8b8b8b8b8b426040516105599b9a99989796959493929190611699565b5f546001600160a01b03163314610bff5760405162461bcd60e51b81526004016103579061121f565b60028054905f610c0e83611256565b91905055508888604051610c2392919061127a565b60405180910390205f8051602061179f83398151915288888888888888426040516104429897969594939291906116ce565b5f546001600160a01b03163314610c7e5760405162461bcd60e51b81526004016103579061121f565b6001600160a01b038116610cc35760405162461bcd60e51b815260206004820152600c60248201526b7a65726f206164647265737360a01b6044820152606401610357565b5f80546001600160a01b038381166001600160a01b0319831681179093556040519116919082907f017157264e61ac54ef1bcfc8259e7eb3473c3d76e3461c0c0d360a140233b7c890610d199042815260200190565b60405180910390a35050565b5f546001600160a01b03163314610d4e5760405162461bcd60e51b81526004016103579061121f565b60028054905f610d5d83611256565b91905055508b8b604051610d7292919061127a565b60405180910390205f805160206117bf8339815191528b8b8b8b8b8b8b8b8b8b426040516105599b9a999897969594939291906116fd565b5f546001600160a01b03163314610dd35760405162461bcd60e51b81526004016103579061121f565b60028054905f610de283611256565b91905055508b8b604051610df792919061127a565b60405180910390205f805160206117bf8339815191528b8b8b8b8b8b8b8b8b8b426040516105599b9a99989796959493929190611734565b5f546001600160a01b03163314610e585760405162461bcd60e51b81526004016103579061121f565b60028054905f610e6783611256565b91905055508888604051610e7c92919061127a565b60405180910390205f8051602061179f833981519152888888888888884260405161044298979695949392919061176a565b5f8083601f840112610ebe575f80fd5b50813567ffffffffffffffff811115610ed5575f80fd5b602083019150836020828501011115610eec575f80fd5b9250929050565b5f805f805f805f6080888a031215610f09575f80fd5b873567ffffffffffffffff80821115610f20575f80fd5b610f2c8b838c01610eae565b909950975060208a0135915080821115610f44575f80fd5b610f508b838c01610eae565b909750955060408a0135915080821115610f68575f80fd5b50610f758a828b01610eae565b989b979a50959894979596606090950135949350505050565b5f805f805f805f805f60a08a8c031215610fa6575f80fd5b893567ffffffffffffffff80821115610fbd575f80fd5b610fc98d838e01610eae565b909b50995060208c0135915080821115610fe1575f80fd5b610fed8d838e01610eae565b909950975060408c0135915080821115611005575f80fd5b6110118d838e01610eae565b909750955060608c0135915080821115611029575f80fd5b506110368c828d01610eae565b9a9d999c50979a9699959894979660800135949350505050565b5f805f805f805f805f805f8060e08d8f03121561106b575f80fd5b67ffffffffffffffff8d351115611080575f80fd5b61108d8e8e358f01610eae565b909c509a5067ffffffffffffffff60208e013511156110aa575f80fd5b6110ba8e60208f01358f01610eae565b909a50985067ffffffffffffffff60408e013511156110d7575f80fd5b6110e78e60408f01358f01610eae565b909850965060608d0135955067ffffffffffffffff60808e0135111561110b575f80fd5b61111b8e60808f01358f01610eae565b909550935067ffffffffffffffff60a08e01351115611138575f80fd5b6111488e60a08f01358f01610eae565b819450809350505060c08d013590509295989b509295989b509295989b565b5f81518084525f5b8181101561118b5760208185018101518683018201520161116f565b505f602082860101526020601f19601f83011685010191505092915050565b602081525f6111bc6020830184611167565b9392505050565b6001600160a01b03851681526080602082018190525f906111e690830186611167565b6040830194909452506060015292915050565b5f60208284031215611209575f80fd5b81356001600160a01b03811681146111bc575f80fd5b60208082526017908201527f546f6e74696e655661756c743a206e6f742061646d696e000000000000000000604082015260600190565b5f6001820161127357634e487b7160e01b5f52601160045260245ffd5b5060010190565b818382375f9101908152919050565b81835281816020850137505f828201602090810191909152601f909101601f19169091010190565b60c08152600b60c08201526a757067726164655f70726f60a81b60e08201525f6101008060208401526112e7818401898b611289565b905082810360408401526112fc818789611289565b83810360608501525f81526080840195909552505060a00152602001949350505050565b60c08152600960c082015268766f74655f6372656560b81b60e08201525f6101008060208401526113548184018b8d611289565b9050828103604084015261136981898b611289565b9050828103606084015261137e818789611289565b6080840195909552505060a001529695505050505050565b60c08152600d60c08201526c6e6f75766561755f6379636c6560981b60e08201525f6101008060208401526113548184018b8d611289565b6101008152600c6101008201526b3234b9ba3934b13aba34b7b760a11b61012082015261014060208201525f61140961014083018d8f611289565b828103604084015261141c818c8e611289565b9050896060840152828103608084015261143781898b611289565b905082810360a084015261144c818789611289565b60c0840195909552505060e001529998505050505050505050565b6101008152600c6101008201526b191958d85a5cdcd95b595b9d60a21b61012082015261014060208201525f61140961014083018d8f611289565b6101008152600d6101008201526c1c995b589bdd5c9cd95b595b9d609a1b61012082015261014060208201525f61140961014083018d8f611289565b60c08152600f60c08201526e726574726169745f70726f706f736560881b60e08201525f6101008060208401526113548184018b8d611289565b6101008152600a6101008201526931b7ba34b9b0ba34b7b760b11b61012082015261014060208201525f61140961014083018d8f611289565b610100815260056101008201526419195c1bdd60da1b61012082015261014060208201525f61140961014083018d8f611289565b600181811c9082168061159957607f821691505b6020821081036115b757634e487b7160e01b5f52602260045260245ffd5b50919050565b60c08152600860c08201526731b932b0ba34b7b760c11b60e08201525f6101008060208401526113548184018b8d611289565b61010081526004610100820152631c1c995d60e21b61012082015261014060208201525f61140961014083018d8f611289565b60c08152600d60c08201526c73636f72655f6d6f646966696560981b60e08201525f6101008060208401526113548184018b8d611289565b6101008152600f6101008201526e39bcb731b43937b734b9b0ba34b7b760891b61012082015261014060208201525f61140961014083018d8f611289565b6101008152600661010082015265185c1c1bdc9d60d21b61012082015261014060208201525f61140961014083018d8f611289565b60c08152600460c082015263766f746560e01b60e08201525f6101008060208401526113548184018b8d611289565b610100815260086101008201526770656e616c69746560c01b61012082015261014060208201525f61140961014083018d8f611289565b61010081526007610100820152661c995d1c985a5d60ca1b61012082015261014060208201525f61140961014083018d8f611289565b60c08152600960c082015268766f74655f636c6f7360b81b60e08201525f6101008060208401526113548184018b8d61128956feb797f5a1c298e9fa465cc27d238378a854bac85755795e076f88e9417977c2712f03445ddef18283f6e86f77b12ac2062698069b0fc835265fd66dfc27bac473f0c94a9cb604f1f3df367f16e0972fe815912af7e137fc0749c8194084751f3ea2646970667358221220cf2c18587a8cdbe22e9e68e7085fea7b717d18183fd32933126f23f442e5c5f464736f6c63430008140033";

async function actionDeployV4(env: Record<string, string>): Promise<Record<string, unknown>> {
  const rpcUrl   = env.ALCHEMY_POLYGON_AMOY_URL || RPC_FALLBACK;
  const privKey  = env.MASTER_WALLET_PRIVATE_KEY || "";
  const fromAddr = env.MASTER_WALLET_ADDRESS || "";

  if (!privKey || !fromAddr) {
    return { ok: false, erreur: "MASTER_WALLET secrets manquants" };
  }

  try {
    // Nonce
    const nonce = parseInt(
      await rpcCall(rpcUrl, "eth_getTransactionCount", [fromAddr, "latest"]) as string, 16
    );

    // Gas price +20%
    const gasPriceHex = await rpcCall(rpcUrl, "eth_gasPrice", []) as string;
    const gasPrice = BigInt(gasPriceHex) * 120n / 100n;

    // Gas limit estimation pour déploiement (pas de `to`)
    let gasLimit = 3_000_000n; // valeur par défaut généreuse pour déploiement
    try {
      const gasEst = await rpcCall(rpcUrl, "eth_estimateGas", [{
        from: fromAddr,
        data: TONTINE_VAULT_V4_BYTECODE,
      }]) as string;
      gasLimit = BigInt(gasEst) * 130n / 100n;
      console.log(`[deploy_v4] Gas estimé: ${gasEst} → limite: ${gasLimit}`);
    } catch (e) {
      console.warn(`[deploy_v4] Gas estimation échouée, utilisation du défaut 3M: ${e}`);
    }

    // Signer la TX de déploiement (to = "" = création de contrat)
    const rawTx = await signTransaction({
      to      : "",  // ← création de contrat
      data    : TONTINE_VAULT_V4_BYTECODE,
      nonce,
      gasPrice,
      gasLimit,
      chainId : CHAIN_ID,
      privKey,
    });

    // Broadcast via Ankr (accepte les writes depuis Supabase)
    const broadcastUrls = [ANKR_RPC, ...RPC_BROADCAST_FALLBACKS];
    let txHash = "";
    let broadcastError = "";

    for (const url of broadcastUrls) {
      try {
        console.log(`[deploy_v4] Broadcast via ${url}`);
        const result = await rpcCall(url, "eth_sendRawTransaction", [rawTx]) as string;
        if (result && result.startsWith("0x") && result.length === 66) {
          txHash = result;
          console.log(`[deploy_v4] ✅ TX envoyée: ${txHash}`);
          break;
        }
      } catch (e) {
        broadcastError = String(e);
        console.warn(`[deploy_v4] Broadcast échoué sur ${url}: ${e}`);
      }
    }

    if (!txHash) {
      return { ok: false, erreur: `Broadcast échoué: ${broadcastError}` };
    }

    // Attendre le receipt (déploiement — on attend jusqu'à 30s max)
    let contractAddress = "";
    for (let i = 0; i < 10; i++) {
      await new Promise(r => setTimeout(r, 3000));
      try {
        const receipt = await rpcCall(rpcUrl, "eth_getTransactionReceipt", [txHash]) as Record<string, string> | null;
        if (receipt && receipt.contractAddress) {
          contractAddress = receipt.contractAddress;
          console.log(`[deploy_v4] ✅ Contrat déployé à: ${contractAddress}`);
          break;
        }
      } catch (_) { /* pas encore miné */ }
      console.log(`[deploy_v4] Attente confirmation... (${i+1}/10)`);
    }

    return {
      ok              : true,
      tx_hash         : txHash,
      contract_address: contractAddress || "(en attente — vérifier le tx_hash sur PolygonScan)",
      explorer_tx     : `${EXPLORER_BASE}/tx/${txHash}`,
      explorer_contract: contractAddress ? `${EXPLORER_BASE}/address/${contractAddress}` : "",
      note            : contractAddress
        ? "✅ TontineVaultV4 déployé! Mettre TONTINE_CONTRACT_ADDRESS dans les secrets Supabase."
        : "⏳ TX broadcastée — vérifier PolygonScan pour l'adresse du contrat.",
    };

  } catch (err) {
    console.error(`[deploy_v4] Erreur: ${err}`);
    return { ok: false, erreur: String(err) };
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
  const DEPLOYED_VERSION = "v11-tontine-vault-v4";  // V4: montant+devise sur PolygonScan

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
      case "deploy_v4":
        // 🚀 Déploie TontineVaultV4 sur Polygon Mainnet
        result = await actionDeployV4(env);
        break;
      case "verifier_contrat":
        // 🔍 Vérifie TontineVaultV4 sur PolygonScan → noms fonctions + paramètres lisibles
        // Nécessite secret POLYGONSCAN_API_KEY dans Supabase
        result = await actionVerifierContratPolygonscan(env);
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
