#!/usr/bin/env python3
"""
TontineClair — Déploiement blockchain-tx v65 (opérations lisibles)
==================================================================
Cette version encode le libellé lisible en français dans les données
de chaque TX on-chain → visible sur PolygonScan sans vérification du contrat.

Usage :
  python3 scripts/deploy_readable_ops.py --token sbp_xxxx

Obtenir le token :
  https://supabase.com/dashboard/account/tokens → New Token
"""

import argparse, os, sys, json, io, zipfile, urllib.request, urllib.error

PROJECT_REF   = "ubrqtcxbxcmvmxleiglh"
FUNCTION_NAME = "blockchain-tx"
SOURCE_FILE   = os.path.join(
    os.path.dirname(__file__), "..",
    "supabase", "functions", "blockchain-tx", "index.ts"
)

G = "\033[92m"; R = "\033[91m"; Y = "\033[93m"; BOLD = "\033[1m"; RESET = "\033[0m"
def ok(m):   print(f"{G}✅ {m}{RESET}")
def err(m):  print(f"{R}❌ {m}{RESET}")
def info(m): print(f"   {m}")

def http_req(url, method, data, headers):
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()
    except Exception as ex:
        return -1, str(ex)

def deployer(token):
    print(f"\n{BOLD}📦 Lecture du source blockchain-tx...{RESET}")
    with open(SOURCE_FILE, "rb") as f:
        source = f.read()
    info(f"{len(source)} bytes")

    # Créer ZIP
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as zf:
        zf.writestr("index.ts", source)
    zip_data = buf.getvalue()
    info(f"ZIP: {len(zip_data)} bytes")

    url = f"https://api.supabase.com/v1/projects/{PROJECT_REF}/functions/{FUNCTION_NAME}"
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type":  "application/octet-stream",
        "x-slug":        FUNCTION_NAME,
    }

    print(f"\n{BOLD}🚀 Déploiement v65 → {url}...{RESET}")
    status, body = http_req(url, "PATCH", zip_data, headers)

    if status in (200, 201):
        ok(f"blockchain-tx v65 déployée !")
        try:
            resp = json.loads(body)
            info(f"version: {resp.get('version','?')}")
        except:
            pass
        return True
    elif status == 401:
        err("Token invalide ou expiré")
        print("  → Générer un nouveau token : https://supabase.com/dashboard/account/tokens")
        return False
    elif status == 404:
        # Essayer POST (création)
        print(f"{Y}⚠️  Function introuvable, tentative création...{RESET}")
        headers["x-verify-jwt"] = "true"
        s2, b2 = http_req(url, "POST", zip_data, headers)
        if s2 in (200, 201):
            ok("Function créée !")
            return True
        err(f"Création échouée ({s2}): {b2[:200]}")
        return False
    else:
        err(f"Déploiement échoué ({status}): {body[:300]}")
        return False

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--token", "-t", default="", help="Supabase PAT (sbp_xxxx)")
    args = parser.parse_args()

    token = args.token or os.environ.get("SUPABASE_ACCESS_TOKEN", "")
    if not token:
        err("Token requis !")
        print(f"\n{BOLD}Obtenir le token :{RESET}")
        print("  1. https://supabase.com/dashboard/account/tokens")
        print("  2. Cliquer 'New Token'")
        print(f"  3. {BOLD}python3 scripts/deploy_readable_ops.py --token sbp_XXXXXX{RESET}")
        sys.exit(1)

    if not deployer(token):
        sys.exit(1)
    print(f"\n{G}{BOLD}✅ Déploiement terminé ! Nouvelles TX contiendront les libellés lisibles.{RESET}")
