#!/usr/bin/env python3
"""
TontineClair — Exécuteur SQL direct via Supabase Management API
================================================================
Exécute admin_reset_pin_gestionnaire.sql dans Supabase via l'API Management.

Usage :
  python3 scripts/exec_sql_direct.py --token sbp_xxxx
  
  Ou définir :
  export SUPABASE_ACCESS_TOKEN=sbp_xxxx
  python3 scripts/exec_sql_direct.py

Obtenir le token :
  https://supabase.com/dashboard/account/tokens
  → New Token → copier sbp_xxxx
"""

import json, os, sys, urllib.request, urllib.error, argparse
from pathlib import Path

PROJECT_REF  = "ubrqtcxbxcmvmxleiglh"
SUPABASE_URL = "https://ubrqtcxbxcmvmxleiglh.supabase.co"
ANON_KEY = (
    "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
    ".eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InVicnF0Y3hieGNtdm14bGVpZ2xoIiwicm9sZSI"
    "6ImFub24iLCJpYXQiOjE3ODMyNzYwMzYsImV4cCI6MjA5ODg1MjAzNn0"
    ".GaCZwMG34cFcxR3lkLuq-7uMM7sQoc_VIqiDEzMgEq4"
)

G = "\033[92m"; R = "\033[91m"; Y = "\033[93m"; B = "\033[94m"; C = "\033[96m"; BOLD = "\033[1m"; RESET = "\033[0m"
def ok(m): print(f"{G}✅ {m}{RESET}")
def err(m): print(f"{R}❌ {m}{RESET}")
def warn(m): print(f"{Y}⚠️  {m}{RESET}")
def info(m): print(f"{C}ℹ️  {m}{RESET}")

def http_post(url, data, headers):
    body = json.dumps(data).encode("utf-8")
    req = urllib.request.Request(url, data=body, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            raw = resp.read().decode("utf-8", errors="replace")
            try: return resp.status, json.loads(raw), raw
            except: return resp.status, raw, raw
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", errors="replace")
        try: return e.code, json.loads(raw), raw
        except: return e.code, {"raw": raw}, raw

def http_get(url, headers):
    req = urllib.request.Request(url, headers=headers, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read().decode("utf-8", errors="replace")
            try: return resp.status, json.loads(raw), raw
            except: return resp.status, raw, raw
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", errors="replace")
        try: return e.code, json.loads(raw), raw
        except: return e.code, {"raw": raw}, raw

def exec_sql(sql: str, token: str) -> tuple:
    """Exécute du SQL via l'API Management Supabase."""
    url = f"https://api.supabase.com/v1/projects/{PROJECT_REF}/database/query"
    headers = {
        "Content-Type":  "application/json",
        "Authorization": f"Bearer {token}",
    }
    return http_post(url, {"query": sql}, headers)

def rpc_call(fn, params):
    url = f"{SUPABASE_URL}/rest/v1/rpc/{fn}"
    headers = {
        "Content-Type": "application/json",
        "apikey": ANON_KEY,
        "Authorization": f"Bearer {ANON_KEY}",
    }
    return http_post(url, params, headers)

def main():
    parser = argparse.ArgumentParser(description="Execute Supabase SQL migrations")
    parser.add_argument("--token", "-t", default="", help="Supabase access token (sbp_xxxx)")
    parser.add_argument("--admin-key", "-k", default="", help="App admin key (pour le test RPC)")
    args = parser.parse_args()

    token = args.token or os.environ.get("SUPABASE_ACCESS_TOKEN", "") or os.environ.get("SUPABASE_MGMT_TOKEN", "")
    admin_key = args.admin_key or os.environ.get("TONTINE_ADMIN_KEY", "")

    if not token:
        err("Token d'accès Supabase requis !")
        print(f"\n{BOLD}Comment obtenir le token :{RESET}")
        print("  1. Aller sur https://supabase.com/dashboard/account/tokens")
        print("  2. Cliquer 'New Token'")
        print("  3. Copier le token (commence par sbp_)")
        print(f"\n{BOLD}Puis relancer :{RESET}")
        print("  python3 scripts/exec_sql_direct.py --token sbp_XXXXXXXXXXXXXX")
        print("\nOu définir :")
        print("  export SUPABASE_ACCESS_TOKEN=sbp_XXXXXXXXXXXXXX")
        print("  python3 scripts/exec_sql_direct.py")
        sys.exit(1)

    print(f"\n{BOLD}{B}═══════════════════════════════════════════════════════{RESET}")
    print(f"{BOLD}TontineClair — Déploiement SQL + Test flux PIN Reset{RESET}")
    print(f"{BOLD}{B}═══════════════════════════════════════════════════════{RESET}\n")

    # ── Étape 1 : Vérifier le token ──────────────────────────────────────────
    print(f"{BOLD}[1/5] Vérification du token Supabase...{RESET}")
    st, bd, _ = http_get(
        f"https://api.supabase.com/v1/projects/{PROJECT_REF}",
        {"Authorization": f"Bearer {token}"}
    )
    if st == 200 and isinstance(bd, dict):
        ok(f"Token valide — projet : {bd.get('name', PROJECT_REF)}")
    elif st == 401:
        err("Token invalide ou expiré")
        print("  Générer un nouveau token sur : https://supabase.com/dashboard/account/tokens")
        sys.exit(1)
    else:
        warn(f"Impossible de vérifier le token — HTTP {st}")
        if isinstance(bd, dict): info(str(bd)[:200])

    # ── Étape 2 : Activer pgcrypto ────────────────────────────────────────────
    print(f"\n{BOLD}[2/5] Activation extension pgcrypto...{RESET}")
    st, bd, raw = exec_sql("CREATE EXTENSION IF NOT EXISTS pgcrypto;", token)
    if st == 200:
        ok("pgcrypto activée (ou déjà active)")
        info(f"Réponse: {str(bd)[:100]}")
    else:
        err(f"Échec activation pgcrypto — HTTP {st}")
        info(str(bd)[:300])
        warn("Continuons quand même...")

    # ── Étape 3 : Déployer la migration SQL ──────────────────────────────────
    print(f"\n{BOLD}[3/5] Déploiement admin_reset_pin_gestionnaire.sql...{RESET}")
    sql_file = Path(__file__).parent.parent / "supabase" / "migrations" / "admin_reset_pin_gestionnaire.sql"
    if not sql_file.exists():
        err(f"Fichier introuvable : {sql_file}")
        sys.exit(1)

    sql = sql_file.read_text(encoding="utf-8")
    info(f"Fichier : {sql_file.name} ({len(sql)} caractères)")

    st, bd, raw = exec_sql(sql, token)
    if st == 200:
        ok("Migration exécutée avec succès !")
        info(f"Réponse: {str(bd)[:200]}")
    elif st in (400, 422):
        # Erreurs SQL — afficher le détail
        err(f"Erreur SQL — HTTP {st}")
        if isinstance(bd, dict):
            print(f"  Message : {bd.get('message', '')}")
            print(f"  Détail  : {bd.get('detail', str(bd)[:400])}")
        else:
            print(f"  Raw: {raw[:500]}")

        # Essai de déploiement par morceaux (pgcrypto + tables + fonction séparément)
        warn("Tentative de déploiement en sections...")
        _deploy_by_sections(sql, token)
    else:
        err(f"Erreur inattendue — HTTP {st}")
        print(f"  Raw: {raw[:500]}")

    # ── Étape 4 : Vérifier le déploiement ────────────────────────────────────
    print(f"\n{BOLD}[4/5] Vérification du déploiement...{RESET}")
    st, bd, _ = rpc_call("admin_reinitialiser_pin_gestionnaire", {
        "p_cle": "verification_test",
        "p_code_tontine": "K93JAP",
        "p_nom_gest": "Kissy"
    })
    print(f"  RPC HTTP {st}")
    if st == 200 and isinstance(bd, dict):
        ok(f"Fonction déployée ! Réponse: {bd}")
        rpc_deployed = True
    elif st == 404:
        err("Fonction TOUJOURS absente — déploiement SQL échoué")
        rpc_deployed = False
    else:
        warn(f"HTTP {st}: {str(bd)[:200]}")
        rpc_deployed = (st == 200)

    # ── Étape 5 : Test flux complet ───────────────────────────────────────────
    print(f"\n{BOLD}[5/5] Test du flux complet (K93JAP / Kissy)...{RESET}")
    if not rpc_deployed:
        err("RPC non disponible — impossible de tester le flux")
        _print_manual_sql(sql_file)
        sys.exit(1)

    if not admin_key:
        warn("TONTINE_ADMIN_KEY non fournie — utilisation d'une clé de test")
        warn("Relancer avec --admin-key <cle_admin> pour un test authentifié")
        admin_key_test = "cle_admin_test"
    else:
        admin_key_test = admin_key
        ok(f"Clé admin fournie")

    # Appel RPC
    info(f"Appel admin_reinitialiser_pin_gestionnaire(K93JAP, Kissy)...")
    st, bd, _ = rpc_call("admin_reinitialiser_pin_gestionnaire", {
        "p_cle":          admin_key_test,
        "p_code_tontine": "K93JAP",
        "p_nom_gest":     "Kissy"
    })
    print(f"  HTTP {st} — {json.dumps(bd, ensure_ascii=False) if isinstance(bd, dict) else str(bd)[:300]}")

    if st == 200 and isinstance(bd, dict) and bd.get("ok") == True:
        email      = bd.get("email", "")
        code_clair = bd.get("code_clair", "")
        gest_nom   = bd.get("gest_nom", "Kissy")
        tont_code  = bd.get("tontine_code", "K93JAP")

        ok(f"RPC ok ! Email={email}, Code={code_clair}")

        # Appel Edge Function
        import time; time.sleep(0.5)
        info(f"Appel send-manager-pin → {email}...")
        ef_st, ef_bd, _ = http_post(
            f"{SUPABASE_URL}/functions/v1/send-manager-pin",
            {"email": email, "gestNom": gest_nom, "tontineCode": tont_code, "code": code_clair},
            {"Content-Type": "application/json", "apikey": ANON_KEY, "Authorization": f"Bearer {ANON_KEY}"}
        )
        print(f"  HTTP {ef_st} — {json.dumps(ef_bd, ensure_ascii=False) if isinstance(ef_bd, dict) else str(ef_bd)[:300]}")

        if ef_st == 200 and isinstance(ef_bd, dict) and ef_bd.get("success"):
            ok(f"✉️  EMAIL ENVOYÉ À {email} !")
            print(f"\n{BOLD}{G}🎉 FLUX COMPLET OPÉRATIONNEL !{RESET}")
        else:
            ef_error = ef_bd.get("error", "") if isinstance(ef_bd, dict) else str(ef_bd)
            if "smtp" in ef_error.lower() or "password" in ef_error.lower():
                err("SMTP_PASSWORD non configuré dans les secrets Supabase")
                _print_smtp_instructions()
            else:
                err(f"Edge Function échouée: {ef_error}")
    else:
        if isinstance(bd, dict):
            erreur = bd.get("erreur", bd.get("error", str(bd)))
            if "clé" in erreur.lower() or "cle" in erreur.lower():
                warn(f"Clé admin incorrecte: {erreur}")
                warn("Relancer avec --admin-key <vraie_cle_admin>")
            elif "introuvable" in erreur.lower():
                err(f"Erreur: {erreur}")
            else:
                warn(f"ok=false: {erreur}")

    print()

def _deploy_by_sections(sql: str, token: str):
    """Déploie le SQL section par section en cas d'erreur."""
    sections = []
    current = []
    for line in sql.split("\n"):
        if line.startswith("-- ═══") and current:
            block = "\n".join(current).strip()
            if block: sections.append(block)
            current = []
        current.append(line)
    if current:
        block = "\n".join(current).strip()
        if block: sections.append(block)

    # Exécuter section par section
    for i, section in enumerate(sections):
        if len(section.strip()) < 10: continue
        st, bd, _ = exec_sql(section, token)
        if st == 200:
            print(f"  Section {i+1}/{len(sections)} : OK")
        else:
            print(f"  Section {i+1}/{len(sections)} : ERREUR HTTP {st}")
            if isinstance(bd, dict): print(f"    {bd.get('message', str(bd)[:200])}")

def _print_smtp_instructions():
    print(f"\n{BOLD}SMTP_PASSWORD à configurer :{RESET}")
    print(f"  1. Aller sur : https://supabase.com/dashboard/project/ubrqtcxbxcmvmxleiglh/functions")
    print(f"  2. Cliquer sur 'send-manager-pin'")
    print(f"  3. Onglet 'Secrets'")
    print(f"  4. Ajouter : SMTP_PASSWORD = <mot_de_passe_SMTP_Hostinger>")
    print(f"  5. Re-déployer si nécessaire : supabase functions deploy send-manager-pin --project-ref ubrqtcxbxcmvmxleiglh")

def _print_manual_sql(sql_file):
    print(f"\n{BOLD}Copier-coller ce SQL dans Supabase SQL Editor :{RESET}")
    print(f"  URL : https://supabase.com/dashboard/project/ubrqtcxbxcmvmxleiglh/sql/new")
    print(f"  Fichier : {sql_file}")

if __name__ == "__main__":
    main()
