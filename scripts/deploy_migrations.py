#!/usr/bin/env python3
"""
TontineClair — Script de déploiement des migrations SQL
Version 2 — Adapté à la vraie structure de la base de données

Ce script :
1. Exécute les migrations SQL via l'API Supabase Management (nécessite SUPABASE_MGMT_TOKEN)
2. Teste les fonctions RPC après déploiement
3. Teste le flux complet de reset PIN gestionnaire

Utilisation :
  python3 deploy_migrations.py [--token SUPABASE_MANAGEMENT_TOKEN]
  
  Ou définir : export SUPABASE_MGMT_TOKEN=sbp_...
"""

import os
import sys
import json
import time
import urllib.request
import urllib.error
import urllib.parse
from pathlib import Path

# ─── Configuration ─────────────────────────────────────────────────────────────
SUPABASE_URL   = "https://ubrqtcxbxcmvmxleiglh.supabase.co"
ANON_KEY       = (
    "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
    ".eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InVicnF0Y3hieGNtdm14bGVpZ2xoIiwicm9sZSI"
    6ImFub24iLCJpYXQiOjE3ODMyNzYwMzYsImV4cCI6MjA5ODg1MjAzNn0"
    ".GaCZwMG34cFcxR3lkLuq-7uMM7sQoc_VIqiDEzMgEq4"
)
PROJECT_REF    = "ubrqtcxbxcmvmxleiglh"
MIGRATIONS_DIR = Path(__file__).parent.parent / "supabase" / "migrations"

# Management API token (sbp_xxxx) — à obtenir dans Supabase Dashboard → Account → Access Tokens
MGMT_TOKEN = os.environ.get("SUPABASE_MGMT_TOKEN", "")

def http_post(url: str, data: dict, headers: dict) -> tuple[int, dict]:
    """Effectue un POST HTTP et retourne (status_code, response_body)."""
    body = json.dumps(data).encode("utf-8")
    req  = urllib.request.Request(url, data=body, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.status, json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        body_str = e.read().decode("utf-8", errors="replace")
        try:
            return e.code, json.loads(body_str)
        except Exception:
            return e.code, {"raw": body_str}

def rpc_call(fn_name: str, params: dict) -> tuple[int, any]:
    """Appelle une RPC Supabase."""
    url = f"{SUPABASE_URL}/rest/v1/rpc/{fn_name}"
    headers = {
        "Content-Type": "application/json",
        "apikey":        ANON_KEY,
        "Authorization": f"Bearer {ANON_KEY}",
    }
    status, body = http_post(url, params, headers)
    return status, body

def execute_sql_via_mgmt(sql: str, token: str) -> tuple[int, dict]:
    """Exécute du SQL via l'API Management Supabase."""
    url = f"https://api.supabase.com/v1/projects/{PROJECT_REF}/database/query"
    headers = {
        "Content-Type":  "application/json",
        "Authorization": f"Bearer {token}",
    }
    return http_post(url, {"query": sql}, headers)

def print_section(title: str):
    print(f"\n{'='*60}")
    print(f"  {title}")
    print(f"{'='*60}")

def print_ok(msg: str):
    print(f"  ✅ {msg}")

def print_err(msg: str):
    print(f"  ❌ {msg}")

def print_warn(msg: str):
    print(f"  ⚠️  {msg}")

def print_info(msg: str):
    print(f"  ℹ️  {msg}")

# ─── Phase 1 : Vérification des prérequis ──────────────────────────────────────
print_section("Phase 1 : Vérification de l'état actuel")

# Test 1.1 : Connexion Supabase
status, body = rpc_call("demander_reset_pin_v2", {
    "p_code": "TEST", "p_nom": "TEST", "p_contact": "test@test.com"
})
if status == 200 and isinstance(body, dict) and body.get("ok") is True:
    print_ok("demander_reset_pin_v2 → déployée ✓")
else:
    print_err(f"demander_reset_pin_v2 → status={status}, body={body}")

# Test 1.2 : valider_code_reset_pin
status, body = rpc_call("valider_code_reset_pin", {
    "p_code_tontine": "TEST", "p_nom": "TEST", "p_code_saisi": "000000"
})
if status == 200 and isinstance(body, dict):
    if "ok" in body:
        print_ok("valider_code_reset_pin → déployée ✓")
    elif "message" in body and "digest" in str(body).lower():
        print_err("valider_code_reset_pin → pgcrypto MANQUANTE (DIGEST introuvable)")
    else:
        print_warn(f"valider_code_reset_pin → status={status}, body={body}")
else:
    print_err(f"valider_code_reset_pin → status={status}, body={body}")

# Test 1.3 : admin_reinitialiser_pin_gestionnaire
status, body = rpc_call("admin_reinitialiser_pin_gestionnaire", {
    "p_cle": "test", "p_code_tontine": "TEST", "p_nom_gest": "TEST"
})
if status == 200:
    print_ok("admin_reinitialiser_pin_gestionnaire → déjà déployée ✓")
    ADMIN_RPC_EXISTS = True
else:
    print_warn("admin_reinitialiser_pin_gestionnaire → PAS ENCORE déployée")
    ADMIN_RPC_EXISTS = False

# Test 1.4 : Tables
import urllib.request as ureq

def check_table(name: str) -> bool:
    url = f"{SUPABASE_URL}/rest/v1/{name}?limit=1"
    req = ureq.Request(url, headers={
        "apikey":        ANON_KEY,
        "Authorization": f"Bearer {ANON_KEY}",
    })
    try:
        with ureq.urlopen(req, timeout=10) as r:
            body = r.read().decode()
            data = json.loads(body)
            if isinstance(data, list):
                return True
            if isinstance(data, dict) and data.get("code") in ("PGRST205", "42P01"):
                return False
            return True
    except:
        return False

for tbl in ["pin_reset_codes", "audit_securite"]:
    if check_table(tbl):
        print_ok(f"Table {tbl} → existe ✓")
    else:
        print_err(f"Table {tbl} → n'existe pas")

# ─── Phase 2 : Déploiement via Management API ──────────────────────────────────
print_section("Phase 2 : Déploiement des migrations SQL")

if not MGMT_TOKEN:
    print_warn("SUPABASE_MGMT_TOKEN non défini — déploiement automatique impossible")
    print_info("Pour déployer automatiquement, obtenez un token dans :")
    print_info("  Supabase Dashboard → Account → Access Tokens")
    print_info("  Puis : export SUPABASE_MGMT_TOKEN=sbp_xxxx")
    print_info("  Puis relancez : python3 scripts/deploy_migrations.py")
    print("")
    print_info("Instructions pour déploiement MANUEL (copier-coller dans SQL Editor) :")
    
    migrations_to_deploy = []
    
    if not ADMIN_RPC_EXISTS:
        admin_sql_path = MIGRATIONS_DIR / "admin_reset_pin_gestionnaire.sql"
        if admin_sql_path.exists():
            migrations_to_deploy.append(("admin_reset_pin_gestionnaire.sql", admin_sql_path))
    
    if migrations_to_deploy:
        print("")
        for name, path in migrations_to_deploy:
            print(f"\n{'─'*60}")
            print(f"  📄 {name}")
            print(f"{'─'*60}")
            print("  Copiez le contenu suivant dans Supabase → SQL Editor :")
            print(f"  Lien direct : https://supabase.com/dashboard/project/{PROJECT_REF}/sql/new")
            print(f"\n  [Fichier: {path}]")
    else:
        print_ok("Toutes les migrations semblent déjà déployées !")
else:
    print_info(f"Token Management API disponible → déploiement automatique")
    
    migrations = [
        ("admin_reset_pin_gestionnaire.sql", not ADMIN_RPC_EXISTS),
    ]
    
    for filename, needs_deploy in migrations:
        sql_path = MIGRATIONS_DIR / filename
        if not sql_path.exists():
            print_err(f"{filename} → fichier introuvable à {sql_path}")
            continue
        
        if not needs_deploy:
            print_ok(f"{filename} → déjà déployée, skip")
            continue
        
        sql_content = sql_path.read_text(encoding="utf-8")
        print_info(f"Déploiement de {filename} ({len(sql_content)} caractères)...")
        
        status, body = execute_sql_via_mgmt(sql_content, MGMT_TOKEN)
        if status in (200, 201):
            print_ok(f"{filename} → déployée avec succès !")
        else:
            print_err(f"{filename} → échec (status={status})")
            print_err(f"  Réponse : {str(body)[:300]}")

# ─── Phase 3 : Test complet du flux PIN reset ──────────────────────────────────
print_section("Phase 3 : Test du flux complet — Reset PIN Gestionnaire")

# 3.1 : Vérifier que K93JAP / Kissy a bien un email
url = f"{SUPABASE_URL}/rest/v1/tontines?select=code,gestionnaires&code=eq.K93JAP"
req = ureq.Request(url, headers={
    "apikey":        ANON_KEY,
    "Authorization": f"Bearer {ANON_KEY}",
})
try:
    with ureq.urlopen(req, timeout=10) as r:
        tontines = json.loads(r.read().decode())
        if tontines:
            gests = tontines[0].get("gestionnaires", [])
            kissy = next((g for g in gests if isinstance(g, dict) and g.get("nom") == "Kissy"), None)
            if kissy and kissy.get("email"):
                print_ok(f"K93JAP/Kissy → email={kissy['email']} ✓")
                TEST_CODE = "K93JAP"
                TEST_NOM  = "Kissy"
                TEST_EMAIL = kissy["email"]
            else:
                print_warn("K93JAP/Kissy → pas d'email enregistré")
                TEST_CODE = TEST_NOM = TEST_EMAIL = None
        else:
            print_err("Tontine K93JAP introuvable")
            TEST_CODE = TEST_NOM = TEST_EMAIL = None
except Exception as e:
    print_err(f"Erreur lecture tontines: {e}")
    TEST_CODE = TEST_NOM = TEST_EMAIL = None

# 3.2 : Test admin_reinitialiser_pin_gestionnaire (si déployée)
if TEST_CODE:
    print_info(f"Test admin_reinitialiser_pin_gestionnaire(K93JAP, Kissy)...")
    status, body = rpc_call("admin_reinitialiser_pin_gestionnaire", {
        "p_cle":          "admin-tontineclair",
        "p_code_tontine": TEST_CODE,
        "p_nom_gest":     TEST_NOM,
    })
    
    if status == 200 and isinstance(body, dict):
        if body.get("ok") is True and body.get("code_clair"):
            email     = body.get("email", "?")
            gest_nom  = body.get("gest_nom", "?")
            code_clr  = body.get("code_clair", "?")
            print_ok(f"RPC réussie → email={email}, gest_nom={gest_nom}, code_clair={code_clr}")
            
            # 3.3 : Appeler send-manager-pin avec le code reçu
            print_info(f"Appel Edge Function send-manager-pin pour {email}...")
            snd_url = f"{SUPABASE_URL}/functions/v1/send-manager-pin"
            payload = {
                "email":       email,
                "gestNom":     gest_nom,
                "tontineCode": TEST_CODE,
                "code":        code_clr,
            }
            snd_status, snd_body = http_post(snd_url, payload, {
                "Content-Type":  "application/json",
                "Authorization": f"Bearer {ANON_KEY}",
                "apikey":        ANON_KEY,
            })
            
            print_info(f"Edge Function → HTTP {snd_status}")
            print_info(f"Edge Function → Body: {snd_body}")
            
            if snd_status == 200 and isinstance(snd_body, dict) and snd_body.get("success") is True:
                print_ok(f"🎉 E-MAIL ENVOYÉ ! Vérifiez {email}")
                print_ok(f"   Supabase Logs → Edge Functions → send-manager-pin → Invocations")
            else:
                err = snd_body.get("error", "?") if isinstance(snd_body, dict) else str(snd_body)
                print_err(f"Edge Function échouée : {err}")
                if "smtp" in str(snd_body).lower() or "password" in str(snd_body).lower():
                    print_warn("→ Vérifier SMTP_PASSWORD dans Supabase Secrets")
                    print_warn("  Dashboard → Edge Functions → Secrets → SMTP_PASSWORD")
        elif body.get("ok") is False:
            erreur = body.get("erreur", "?")
            print_err(f"RPC échouée : {erreur}")
            if "introuvable" in erreur:
                print_warn("→ La migration admin_reset_pin_gestionnaire.sql n'est pas déployée")
                print_warn(f"  Déployez-la ici : https://supabase.com/dashboard/project/{PROJECT_REF}/sql/new")
        else:
            print_warn(f"Réponse inattendue : {body}")
    else:
        print_err(f"RPC non disponible (status={status})")
        if status == 404 or (isinstance(body, dict) and "PGRST202" in str(body.get("code", ""))):
            print_warn("→ La migration admin_reset_pin_gestionnaire.sql n'est pas déployée")

# ─── Phase 4 : Résumé et instructions ─────────────────────────────────────────
print_section("Phase 4 : Résumé et actions requises")

print("""
📋 ÉTAT DU DÉPLOIEMENT :

  ✅ demander_reset_pin_v2        → déployée (utilisée pour le flux utilisateur)
  ❓ valider_code_reset_pin       → déployée mais pgcrypto peut manquer
  ❓ admin_reinitialiser_pin_gestionnaire → vérifier ci-dessus
  ✅ send-manager-pin             → déployée (retourne 500 = SMTP_PASSWORD absent)

🚨 ACTIONS MANUELLES REQUISES dans Supabase Dashboard :

  1. ACTIVER pgcrypto (si pas fait) :
     Dashboard → Database → Extensions → Activer pgcrypto
     Ou SQL Editor : CREATE EXTENSION IF NOT EXISTS pgcrypto;

  2. DÉPLOYER la migration SQL :
     Fichier : supabase/migrations/admin_reset_pin_gestionnaire.sql
     URL     : https://supabase.com/dashboard/project/ubrqtcxbxcmvmxleiglh/sql/new

  3. CONFIGURER le secret SMTP :
     Dashboard → Edge Functions → Secrets
     Ajouter : SMTP_PASSWORD = <votre_mot_de_passe_SMTP_Hostinger>

  4. VÉRIFIER le déploiement de send-manager-pin :
     Dashboard → Edge Functions → send-manager-pin → Invocations
     Si absent : supabase functions deploy send-manager-pin --project-ref ubrqtcxbxcmvmxleiglh

  5. TEST FINAL :
     Relancez ce script : python3 scripts/deploy_migrations.py
     Ou testez via l'espace admin de l'app → tontine K93JAP → Réinitialiser le PIN
""")
