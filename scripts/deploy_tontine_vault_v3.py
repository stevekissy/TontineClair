#!/usr/bin/env python3
"""
deploy_tontine_vault_v3.py
==========================
Déploie TontineVaultV3 sur Polygon Mainnet et met à jour :
  - deployment.json
  - blockchain-tx/index.ts (TONTINE_CONTRACT_ADDRESS + SELECTORS)
  - Le secret Supabase TONTINE_CONTRACT_ADDRESS

Usage :
  python3 scripts/deploy_tontine_vault_v3.py \
    --private-key 0xTON_PRIVATE_KEY \
    --supabase-token sbp_XXXX

OU via variables d'environnement :
  export MASTER_WALLET_PRIVATE_KEY=0x...
  export SUPABASE_ACCESS_TOKEN=sbp_...
  python3 scripts/deploy_tontine_vault_v3.py
"""

import argparse, json, os, sys, time, urllib.request, urllib.error, re

# ── Config ─────────────────────────────────────────────────────────────────────
PROJECT_ROOT  = os.path.join(os.path.dirname(__file__), "..")
CONTRACT_SOL  = os.path.join(PROJECT_ROOT, "supabase/contracts/TontineVaultV3.sol")
BYTECODE_FILE = os.path.join(PROJECT_ROOT, "supabase/contracts/TontineVaultV3.bytecode")
ABI_FILE      = os.path.join(PROJECT_ROOT, "supabase/contracts/TontineVaultV3.abi.json")
SELECTORS_FILE= os.path.join(PROJECT_ROOT, "supabase/contracts/TontineVaultV3.selectors.json")
DEPLOY_JSON   = os.path.join(PROJECT_ROOT, "supabase/contracts/deployment.json")
EDGE_FUNC     = os.path.join(PROJECT_ROOT, "supabase/functions/blockchain-tx/index.ts")

ADMIN_ADDRESS = "0xf2C1019814425f46E743a5492153C1a25bdfEEfd"
PROJECT_REF   = "ubrqtcxbxcmvmxleiglh"

RPC_URLS = [
    "https://rpc-mainnet.matic.quiknode.pro",
    "https://rpc.ankr.com/polygon",
    "https://1rpc.io/matic",
]

# ── Helpers RPC ────────────────────────────────────────────────────────────────
def rpc_call(method: str, params: list, rpc_url: str = None) -> dict:
    for url in ([rpc_url] if rpc_url else RPC_URLS):
        try:
            data = json.dumps({"jsonrpc":"2.0","method":method,"params":params,"id":1}).encode()
            req  = urllib.request.Request(url, data=data, headers={"Content-Type":"application/json"})
            resp = urllib.request.urlopen(req, timeout=15)
            result = json.loads(resp.read())
            if "result" in result:
                return result
        except Exception as e:
            print(f"  RPC {url} échec: {e}")
    raise RuntimeError(f"Tous les RPC ont échoué pour {method}")

def eth_hex(n: int, bytes_len: int = 32) -> str:
    return n.to_bytes(bytes_len, "big").hex()

# ── Signer et envoyer TX ───────────────────────────────────────────────────────
def deploy_contract(private_key: str, bytecode_hex: str) -> tuple[str, int]:
    """Déploie le contrat. Retourne (tx_hash, block_number)."""
    from eth_account import Account
    from eth_account.signers.local import LocalAccount

    acct: LocalAccount = Account.from_key(private_key)
    print(f"  Wallet: {acct.address}")

    # Nonce
    nonce_r = rpc_call("eth_getTransactionCount", [acct.address, "latest"])
    nonce   = int(nonce_r["result"], 16)
    print(f"  Nonce: {nonce}")

    # Gas price (legacy)
    gp_r    = rpc_call("eth_gasPrice", [])
    gas_price = int(int(gp_r["result"], 16) * 1.2)  # +20% pour priorité
    print(f"  Gas price: {gas_price / 1e9:.2f} Gwei")

    # Estimate gas
    deploy_data = "0x" + bytecode_hex
    eg_r = rpc_call("eth_estimateGas", [{
        "from": acct.address,
        "data": deploy_data,
    }])
    gas_limit = int(int(eg_r["result"], 16) * 1.3)  # +30% marge
    print(f"  Gas estimé: {gas_limit:,}")

    cost_matic = gas_limit * gas_price / 1e18
    print(f"  Coût estimé: {cost_matic:.4f} MATIC")

    # Construire TX
    tx = {
        "nonce":    nonce,
        "gasPrice": gas_price,
        "gas":      gas_limit,
        "to":       None,   # None = déploiement
        "value":    0,
        "data":     deploy_data,
        "chainId":  137,    # Polygon Mainnet
    }

    # Signer
    signed = acct.sign_transaction(tx)
    raw_tx = signed.raw_transaction.hex()

    # Broadcast
    print("  Envoi de la TX de déploiement...")
    for url in RPC_URLS:
        try:
            data = json.dumps({
                "jsonrpc": "2.0",
                "method":  "eth_sendRawTransaction",
                "params":  ["0x" + raw_tx],
                "id":      1
            }).encode()
            req  = urllib.request.Request(url, data=data, headers={"Content-Type":"application/json"})
            resp = json.loads(urllib.request.urlopen(req, timeout=30).read())
            if "result" in resp and resp["result"]:
                tx_hash = resp["result"]
                print(f"  TX envoyée: {tx_hash}")
                break
            elif "error" in resp:
                print(f"  Erreur RPC {url}: {resp['error']}")
        except Exception as e:
            print(f"  RPC {url} broadcast échec: {e}")
    else:
        raise RuntimeError("Échec du broadcast sur tous les RPC")

    # Attendre confirmation
    print("  Attente de confirmation (max 120s)...")
    contract_address = None
    block_number     = 0
    for i in range(24):
        time.sleep(5)
        try:
            receipt_r = rpc_call("eth_getTransactionReceipt", [tx_hash])
            receipt   = receipt_r.get("result")
            if receipt and receipt.get("contractAddress"):
                contract_address = receipt["contractAddress"]
                block_number     = int(receipt["blockNumber"], 16)
                status           = int(receipt.get("status", "0x0"), 16)
                print(f"  ✅ Confirmé! Bloc {block_number}, status={status}")
                print(f"  Adresse contrat: {contract_address}")
                if status == 0:
                    raise RuntimeError("TX échouée (status=0)")
                break
            print(f"  Attente... ({(i+1)*5}s)")
        except RuntimeError:
            raise
        except Exception as e:
            print(f"  Polling erreur: {e}")

    if not contract_address:
        raise RuntimeError(f"Timeout — TX {tx_hash} non confirmée en 120s")

    return tx_hash, block_number, contract_address

# ── Mettre à jour deployment.json ─────────────────────────────────────────────
def update_deployment_json(tx_hash: str, block_number: int, contract_address: str, gas_used: int = 0):
    deploy = {
        "contract_address": contract_address,
        "contract_address_v2": "0xdD3aa7dcd20f3C5321CbFFf6EF2dc2a278cBA26a",  # ancien
        "tx_hash":          tx_hash.replace("0x", ""),
        "block_number":     block_number,
        "admin_address":    ADMIN_ADDRESS,
        "network":          "polygon-mainnet",
        "chain_id":         137,
        "deployed_at":      time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "version":          "3.0.0",
        "polygonscan":      f"https://polygonscan.com/address/{contract_address}",
        "gas_used":         gas_used,
        "deploy_cost_matic": round(gas_used * 30e-9, 6),
    }
    with open(DEPLOY_JSON, "w") as f:
        json.dump(deploy, f, indent=2)
    print(f"  deployment.json mis à jour ✅")

# ── Mettre à jour l'Edge Function blockchain-tx/index.ts ──────────────────────
def update_edge_function(contract_address: str):
    with open(EDGE_FUNC) as f:
        content = f.read()

    with open(SELECTORS_FILE) as f:
        selectors = json.load(f)

    # 1. Remplacer le bloc SELECTORS existant par le nouveau
    new_selectors_block = "const SELECTORS: Record<string, string> = {\n"
    for sig, sel in selectors.items():
        new_selectors_block += f'  "{sig}": "{sel}",\n'
    new_selectors_block += "};"

    # Regex pour remplacer le bloc SELECTORS complet
    content = re.sub(
        r'const SELECTORS: Record<string, string> = \{[^}]+\};',
        new_selectors_block,
        content,
        flags=re.DOTALL
    )

    # 2. Remplacer le routage typeOp dans actionEnregistrerOperation
    # Nouveau bloc de routage complet
    new_routing = '''  // ── Phase 2 : vraie TX on-chain ──────────────────────────────────────────────
  if (phase2Ready) {
    try {
      let calldata: string;
      const typeOp = String(type_operation);

      // Routing v3 : une fonction par action métier → noms lisibles sur PolygonScan
      switch (typeOp) {
        // ── Votes ──────────────────────────────────────────────────────────────
        case "vote_cree":
          calldata = buildVoteCalldata_v3(tontine_code, membre_id, membre_nom, ref_interne || "", "enregistrerVoteCree", payloadBytes); break;
        case "vote_clos":
          calldata = buildVoteCalldata_v3(tontine_code, membre_id, membre_nom, ref_interne || "", "enregistrerVoteClos", payloadBytes); break;
        case "vote":
          calldata = buildVoteCalldata_v3(tontine_code, membre_id, membre_nom, ref_interne || "", "enregistrerVoteIndividuel", payloadBytes); break;
        case "retrait_propose":
          calldata = buildVoteCalldata_v3(tontine_code, membre_id, membre_nom, ref_interne || "", "enregistrerRetraitPropose", payloadBytes); break;
        // ── Système ────────────────────────────────────────────────────────────
        case "creation":
          calldata = buildCreationCalldata_v3(tontine_code, membre_id, membre_nom, String(body.nom_tontine || tontine_code), payloadBytes); break;
        case "upgrade_pro":
          calldata = buildSysCalldata_v3(tontine_code, membre_id, membre_nom, "", "enregistrerUpgradePro", payloadBytes); break;
        case "nouveau_cycle":
          calldata = buildSysCalldata_v3(tontine_code, membre_id, membre_nom, ref_interne || "", "enregistrerNouveauCycle", payloadBytes); break;
        case "score_modifie":
          calldata = buildSysCalldata_v3(tontine_code, membre_id, membre_nom, ref_interne || "", "enregistrerScoreModifie", payloadBytes); break;
        // ── Finances ───────────────────────────────────────────────────────────
        case "cotisation":
          calldata = buildFinanceCalldata_v3(tontine_code, membre_id, membre_nom, montantXof, montantUsdt, ref_interne || "", "enregistrerCotisation", payloadBytes); break;
        case "distribution":
          calldata = buildFinanceCalldata_v3(tontine_code, membre_id, membre_nom, montantXof, montantUsdt, ref_interne || "", "enregistrerDistribution", payloadBytes); break;
        case "decaissement":
          calldata = buildFinanceCalldata_v3(tontine_code, membre_id, membre_nom, montantXof, montantUsdt, ref_interne || "", "enregistrerDecaissement", payloadBytes); break;
        case "depot":
          calldata = buildFinanceCalldata_v3(tontine_code, membre_id, membre_nom, montantXof, montantUsdt, ref_interne || "", "enregistrerDepot", payloadBytes); break;
        case "pret":
          calldata = buildFinanceCalldata_v3(tontine_code, membre_id, membre_nom, montantXof, montantUsdt, ref_interne || "", "enregistrerPret", payloadBytes); break;
        case "remboursement":
        case "remboursement_pret":
          calldata = buildFinanceCalldata_v3(tontine_code, membre_id, membre_nom, montantXof, montantUsdt, ref_interne || "", "enregistrerRemboursement", payloadBytes); break;
        case "penalite":
          calldata = buildFinanceCalldata_v3(tontine_code, membre_id, membre_nom, montantXof, montantUsdt, ref_interne || "", "enregistrerPenalite", payloadBytes); break;
        case "retrait":
          calldata = buildFinanceCalldata_v3(tontine_code, membre_id, membre_nom, montantXof, montantUsdt, ref_interne || "", "enregistrerRetrait", payloadBytes); break;
        case "apport":
          calldata = buildFinanceCalldata_v3(tontine_code, membre_id, membre_nom, montantXof, montantUsdt, ref_interne || "", "enregistrerApport", payloadBytes); break;
        case "sync_balance":
        case "synchronisation":
          calldata = buildFinanceCalldata_v3(tontine_code, membre_id, membre_nom, montantXof, montantUsdt, ref_interne || "", "enregistrerSynchronisation", payloadBytes); break;
        default:
          // Fallback : opération inconnue → enregistrerSynchronisation
          calldata = buildFinanceCalldata_v3(tontine_code, membre_id, membre_nom, montantXof, montantUsdt, ref_interne || "", "enregistrerSynchronisation", payloadBytes); break;
      }'''

    # Remplacer l'ancien bloc if/else par le nouveau switch
    old_routing_pattern = r'  // ── Phase 2 : vraie TX on-chain ──────────+\n  if \(phase2Ready\) \{\n    try \{[\s\S]+?} else \{\n        calldata = buildOperationCalldata\([\s\S]+?\);\n      \}'
    if re.search(old_routing_pattern, content):
        content = re.sub(old_routing_pattern, new_routing, content)
        print("  Routing typeOp remplacé ✅")
    else:
        print("  ⚠️  Pattern routing non trouvé — insertion manuelle nécessaire")

    with open(EDGE_FUNC, "w") as f:
        f.write(content)
    print(f"  Edge Function mise à jour ✅")

# ── Mettre à jour le secret TONTINE_CONTRACT_ADDRESS dans Supabase ─────────────
def update_supabase_secret(supabase_token: str, contract_address: str):
    url  = f"https://api.supabase.com/v1/projects/{PROJECT_REF}/secrets"
    data = json.dumps([{"name": "TONTINE_CONTRACT_ADDRESS", "value": contract_address}]).encode()
    req  = urllib.request.Request(url, data=data, method="POST", headers={
        "Authorization": f"Bearer {supabase_token}",
        "Content-Type": "application/json",
    })
    try:
        resp = urllib.request.urlopen(req, timeout=15)
        print(f"  Secret TONTINE_CONTRACT_ADDRESS mis à jour ✅")
    except urllib.error.HTTPError as e:
        print(f"  ⚠️  Erreur mise à jour secret: {e.read().decode()}")

# ── MAIN ───────────────────────────────────────────────────────────────────────
def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--private-key",    default=os.getenv("MASTER_WALLET_PRIVATE_KEY", ""))
    parser.add_argument("--supabase-token", default=os.getenv("SUPABASE_ACCESS_TOKEN", ""))
    args = parser.parse_args()

    if not args.private_key:
        print("❌ Clé privée manquante!")
        print("   --private-key 0x... OU export MASTER_WALLET_PRIVATE_KEY=0x...")
        sys.exit(1)

    print("\n╔══════════════════════════════════════════════════════╗")
    print("║    Déploiement TontineVaultV3 — Polygon Mainnet      ║")
    print("╚══════════════════════════════════════════════════════╝\n")

    # Lire le bytecode compilé
    with open(BYTECODE_FILE) as f:
        bytecode = f.read().strip()
    print(f"✅ Bytecode chargé: {len(bytecode)//2} bytes")

    # Déployer
    print("\n📡 Déploiement sur Polygon Mainnet...")
    tx_hash, block_number, contract_address = deploy_contract(args.private_key, bytecode)

    print(f"\n✅ Contrat déployé!")
    print(f"   Adresse : {contract_address}")
    print(f"   TX Hash : {tx_hash}")
    print(f"   Bloc    : {block_number}")
    print(f"   PolygonScan : https://polygonscan.com/address/{contract_address}")

    # Mettre à jour deployment.json
    print("\n📝 Mise à jour deployment.json...")
    update_deployment_json(tx_hash, block_number, contract_address)

    # Mettre à jour l'Edge Function
    print("\n⚙️  Mise à jour Edge Function blockchain-tx...")
    update_edge_function(contract_address)

    # Mettre à jour le secret Supabase (si token disponible)
    if args.supabase_token:
        print("\n🔑 Mise à jour secret Supabase...")
        update_supabase_secret(args.supabase_token, contract_address)
    else:
        print("\n⚠️  Token Supabase non fourni — mettre à jour manuellement:")
        print(f"   TONTINE_CONTRACT_ADDRESS = {contract_address}")

    print("\n╔══════════════════════════════════════════════════════╗")
    print("║    DÉPLOIEMENT TERMINÉ ✅                            ║")
    print("╠══════════════════════════════════════════════════════╣")
    print(f"║  Contrat v3 : {contract_address[:42]}  ║")
    print("║                                                      ║")
    print("║  Prochaines étapes :                                 ║")
    print("║  1. Déployer l'Edge Function blockchain-tx           ║")
    print("║  2. Vérifier le contrat sur PolygonScan              ║")
    print("╚══════════════════════════════════════════════════════╝\n")

if __name__ == "__main__":
    main()
