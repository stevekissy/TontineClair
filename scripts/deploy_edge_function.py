#!/usr/bin/env python3
"""
Déploie la Edge Function sycapay-payment sur Supabase via Management API.

Usage:
  python3 scripts/deploy_edge_function.py --token sbp_xxxx
  export SUPABASE_ACCESS_TOKEN=sbp_xxxx && python3 scripts/deploy_edge_function.py

Obtenir le token :
  https://supabase.com/dashboard/account/tokens → New Token
"""

import argparse
import os
import sys
import json
import base64
import zipfile
import io
import urllib.request
import urllib.error

PROJECT_REF   = "ubrqtcxbxcmvmxleiglh"
FUNCTION_NAME = "sycapay-payment"
SOURCE_FILE   = os.path.join(
    os.path.dirname(__file__), "..",
    "supabase", "functions", "sycapay-payment", "index.ts"
)

def lire_source() -> bytes:
    with open(SOURCE_FILE, "rb") as f:
        return f.read()

def zipper_source(source: bytes) -> bytes:
    """Crée un ZIP en mémoire contenant index.ts."""
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as zf:
        zf.writestr("index.ts", source)
    return buf.getvalue()

def http_request(url: str, method: str, data: bytes | None, headers: dict) -> tuple:
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            body = r.read().decode()
            return r.status, body
    except urllib.error.HTTPError as e:
        body = e.read().decode()
        return e.code, body
    except Exception as ex:
        return -1, str(ex)

def deployer(token: str) -> bool:
    print(f"📦 Lecture de {SOURCE_FILE}...")
    source = lire_source()
    print(f"   {len(source)} bytes lus")

    zip_data = zipper_source(source)
    print(f"   ZIP : {len(zip_data)} bytes")

    url = f"https://api.supabase.com/v1/projects/{PROJECT_REF}/functions/{FUNCTION_NAME}"
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type":  "application/octet-stream",
        "x-slug":        FUNCTION_NAME,
    }

    print(f"🚀 Déploiement vers {url}...")
    status, body = http_request(url, "PATCH", zip_data, headers)

    if status in (200, 201):
        print(f"✅ Edge Function '{FUNCTION_NAME}' déployée avec succès !")
        try:
            resp = json.loads(body)
            print(f"   version: {resp.get('version', '?')}")
            print(f"   status:  {resp.get('status', '?')}")
        except Exception:
            pass
        return True
    elif status == 404:
        # Fonction n'existe pas encore → POST pour créer
        print(f"   Fonction non trouvée (404) → tentative de création...")
        create_url = f"https://api.supabase.com/v1/projects/{PROJECT_REF}/functions"
        s2, b2 = http_request(create_url, "POST", zip_data, headers)
        if s2 in (200, 201):
            print(f"✅ Edge Function '{FUNCTION_NAME}' créée avec succès !")
            return True
        else:
            print(f"❌ Création échouée ({s2}): {b2[:500]}")
            return False
    else:
        print(f"❌ Déploiement échoué ({status}): {body[:500]}")
        return False

def main():
    parser = argparse.ArgumentParser(description="Déploie sycapay-payment Edge Function")
    parser.add_argument("--token", "-t", default="", help="Supabase access token (sbp_xxxx)")
    args = parser.parse_args()

    token = (args.token
             or os.environ.get("SUPABASE_ACCESS_TOKEN", "")
             or os.environ.get("SUPABASE_MGMT_TOKEN", ""))

    if not token:
        print("❌ Token requis.")
        print("   Usage  : python3 scripts/deploy_edge_function.py --token sbp_xxxx")
        print("   Ou env : export SUPABASE_ACCESS_TOKEN=sbp_xxxx")
        sys.exit(1)

    ok = deployer(token)
    sys.exit(0 if ok else 1)

if __name__ == "__main__":
    main()
