#!/usr/bin/env python3
"""
Déploie envoyer_notification v3 (FCM Topics) sur Supabase.
Usage:
  export SUPABASE_ACCESS_TOKEN=sbp_xxxx && python3 scripts/deploy_notif_v3.py
"""
import os, sys, json, zipfile, io, urllib.request, urllib.error

PROJECT_REF   = "ubrqtcxbxcmvmxleiglh"
FUNCTION_NAME = "envoyer_notification"
SOURCE_FILE   = os.path.join(os.path.dirname(__file__), "..", "supabase", "functions", "envoyer_notification", "index.ts")

def deployer(token):
    with open(SOURCE_FILE, "rb") as f:
        source = f.read()
    print(f"📦 Source: {len(source)} bytes")

    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as zf:
        zf.writestr("index.ts", source)
    zip_data = buf.getvalue()

    url = f"https://api.supabase.com/v1/projects/{PROJECT_REF}/functions/{FUNCTION_NAME}"
    headers = {"Authorization": f"Bearer {token}", "Content-Type": "application/octet-stream", "x-slug": FUNCTION_NAME}

    req = urllib.request.Request(url, data=zip_data, headers=headers, method="PATCH")
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            body = r.read().decode()
            status = r.status
    except urllib.error.HTTPError as e:
        body = e.read().decode()
        status = e.code

    if status in (200, 201):
        print(f"✅ '{FUNCTION_NAME}' déployée !")
        try:
            resp = json.loads(body)
            print(f"   version: {resp.get('version', '?')}, status: {resp.get('status', '?')}")
        except: pass
        return True
    else:
        print(f"❌ Échec ({status}): {body[:300]}")
        return False

token = os.environ.get("SUPABASE_ACCESS_TOKEN", "")
if not token:
    print("❌ export SUPABASE_ACCESS_TOKEN=sbp_xxxx")
    sys.exit(1)

sys.exit(0 if deployer(token) else 1)
