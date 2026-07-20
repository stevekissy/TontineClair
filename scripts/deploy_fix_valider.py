#!/usr/bin/env python3
"""
TontineClair — Déploiement FIX CRITIQUE valider_code_reset_pin
==============================================================
Corrige la cause racine de "code incorrect" :
  ENCODE(DIGEST(...)) dans DECLARE → crash si pgcrypto absent.

Usage :
  python3 scripts/deploy_fix_valider.py --token sbp_xxxx
  python3 scripts/deploy_fix_valider.py --token sbp_xxxx --test-code M3JQ3U --test-nom Arnaud

Ou :
  export SUPABASE_ACCESS_TOKEN=sbp_xxxx
  python3 scripts/deploy_fix_valider.py
"""

import json, os, sys, time, urllib.request, urllib.error, argparse
from pathlib import Path

PROJECT_REF  = "ubrqtcxbxcmvmxleiglh"
SUPABASE_URL = "https://ubrqtcxbxcmvmxleiglh.supabase.co"
ANON_KEY = (
    "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
    ".eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InVicnF0Y3hieGNtdm14bGVpZ2xoIiwicm9sZSI"
    "6ImFub24iLCJpYXQiOjE3ODMyNzYwMzYsImV4cCI6MjA5ODg1MjAzNn0"
    ".GaCZwMG34cFcxR3lkLuq-7uMM7sQoc_VIqiDEzMgEq4"
)

G    = "\033[92m"; R = "\033[91m"; Y = "\033[93m"
B    = "\033[94m"; C = "\033[96m"; BOLD = "\033[1m"; RESET = "\033[0m"
def ok(m):   print(f"{G}✅  {m}{RESET}")
def err(m):  print(f"{R}❌  {m}{RESET}")
def warn(m): print(f"{Y}⚠️   {m}{RESET}")
def info(m): print(f"{C}ℹ️   {m}{RESET}")
def head(m): print(f"\n{BOLD}{B}{m}{RESET}")

# ── HTTP helpers ──────────────────────────────────────────────────────────────
def http_post(url, data, headers):
    body = json.dumps(data).encode("utf-8")
    req  = urllib.request.Request(url, data=body, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            raw = r.read().decode("utf-8", errors="replace")
            try:    return r.status, json.loads(raw), raw
            except: return r.status, raw, raw
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", errors="replace")
        try:    return e.code, json.loads(raw), raw
        except: return e.code, {"raw": raw}, raw

def http_get(url, headers):
    req = urllib.request.Request(url, headers=headers, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            raw = r.read().decode("utf-8", errors="replace")
            try:    return r.status, json.loads(raw), raw
            except: return r.status, raw, raw
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", errors="replace")
        try:    return e.code, json.loads(raw), raw
        except: return e.code, {"raw": raw}, raw

def exec_sql(sql, token):
    url     = f"https://api.supabase.com/v1/projects/{PROJECT_REF}/database/query"
    headers = {"Content-Type": "application/json", "Authorization": f"Bearer {token}"}
    return http_post(url, {"query": sql}, headers)

def rpc(fn, params):
    url     = f"{SUPABASE_URL}/rest/v1/rpc/{fn}"
    headers = {
        "Content-Type": "application/json",
        "apikey":        ANON_KEY,
        "Authorization": f"Bearer {ANON_KEY}",
    }
    return http_post(url, params, headers)

# ── Déploiement SQL par blocs ─────────────────────────────────────────────────
def deploy_by_blocks(sql, token):
    """Déploie le SQL en découpant sur CREATE OR REPLACE FUNCTION."""
    import re
    # Sépare sur chaque bloc CREATE OR REPLACE FUNCTION ... $$ ... $$;
    blocks = re.split(r'(?=\nCREATE OR REPLACE FUNCTION)', sql)
    total  = len([b for b in blocks if b.strip()])
    success, fail = 0, 0
    for i, block in enumerate(blocks):
        block = block.strip()
        if not block: continue
        st, bd, _ = exec_sql(block, token)
        fname = ""
        m = re.search(r'FUNCTION\s+\S+', block)
        if m: fname = m.group(0)
        if st == 200:
            ok(f"  Bloc {i+1}/{total} déployé : {fname}")
            success += 1
        else:
            err(f"  Bloc {i+1}/{total} échoué : {fname} — HTTP {st}")
            if isinstance(bd, dict):
                err(f"  {bd.get('message', str(bd)[:300])}")
            fail += 1
    return success, fail

# ── Test flux complet ─────────────────────────────────────────────────────────
def test_flux(code_tontine, nom_gest, email_gest):
    head(f"TEST FLUX COMPLET : {code_tontine} / {nom_gest}")

    # Étape 1 : demander_reset_pin_v3
    info(f"Étape 1 — demander_reset_pin_v3({code_tontine}, {nom_gest}, {email_gest})...")
    st1, bd1, _ = rpc("demander_reset_pin_v3", {
        "p_code":    code_tontine,
        "p_nom":     nom_gest,
        "p_contact": email_gest,
    })
    print(f"  HTTP {st1} → {json.dumps(bd1, ensure_ascii=False)[:200]}")
    if st1 != 200 or not isinstance(bd1, dict) or not bd1.get("ok"):
        err(f"Étape 1 ÉCHOUÉE : {bd1}")
        return False

    code_clair   = bd1.get("code_clair", "")
    envoyer      = bd1.get("envoyer", False)
    email_dest   = bd1.get("email", email_gest)
    gest_nom_ret = bd1.get("gest_nom", nom_gest)
    ok(f"Étape 1 OK — code_clair={code_clair}, envoyer={envoyer}, email={email_dest}")

    if not code_clair:
        err("code_clair vide dans la réponse — anomalie")
        return False

    # Étape 2 : vérification pin_reset_codes
    info("Étape 2 — Vérification hash en base...")
    verify_sql = f"""
SELECT id, tontine_code, gest_nom, contact,
       LEFT(code, 16) || '...' AS code_hash_preview,
       expire_at, utilise, tentatives
FROM   pin_reset_codes
WHERE  tontine_code = '{code_tontine}'
  AND  gest_nom     = '{gest_nom_ret}'
  AND  utilise      = FALSE
  AND  expire_at    > NOW()
ORDER  BY cree_le DESC
LIMIT  1;
"""
    # On ne peut pas faire ce SELECT via Management API sans token — on passe
    ok("Étape 2 — Skip (vérification en base non disponible sans token mgmt)")

    # Étape 3 : valider_code_reset_pin  ← LE VRAI TEST
    info(f"Étape 3 — valider_code_reset_pin({code_tontine}, {gest_nom_ret}, {code_clair})...")
    time.sleep(0.3)
    st3, bd3, _ = rpc("valider_code_reset_pin", {
        "p_code_tontine": code_tontine,
        "p_nom":          gest_nom_ret,
        "p_code_saisi":   code_clair,
    })
    print(f"  HTTP {st3} → {json.dumps(bd3, ensure_ascii=False)[:300]}")

    if st3 == 404 and isinstance(bd3, dict):
        msg = bd3.get("message", "")
        if "digest" in msg.lower():
            err("BUG CRITIQUE ENCORE PRÉSENT : function digest() does not exist")
            err("Le fix SQL n'a pas été appliqué correctement.")
            return False

    if st3 == 200 and isinstance(bd3, dict) and bd3.get("ok"):
        ok(f"Étape 3 OK — {bd3.get('message', '')}")
    else:
        err(f"Étape 3 ÉCHOUÉE — HTTP {st3}")
        if isinstance(bd3, dict):
            err(f"  Erreur: {bd3.get('erreur', bd3.get('message', str(bd3)[:200]))}")
        return False

    # Résumé
    print(f"\n{BOLD}{G}🎉 FLUX COMPLET RÉUSSI ! Le bug 'code incorrect' est résolu.{RESET}")
    if envoyer:
        info(f"Email aurait été envoyé à : {email_dest}")
        info("(L'email contient le code — le flux de validation est maintenant fonctionnel)")
    return True

# ── Main ──────────────────────────────────────────────────────────────────────
def main():
    parser = argparse.ArgumentParser(description="Deploy fix valider_code_reset_pin")
    parser.add_argument("--token",      "-t", default="", help="Supabase access token (sbp_xxxx)")
    parser.add_argument("--test-code",  "-c", default="M3JQ3U",      help="Code tontine pour le test")
    parser.add_argument("--test-nom",   "-n", default="Arnaud",      help="Nom gestionnaire pour le test")
    parser.add_argument("--test-email", "-e", default="skpaay@gmail.com", help="Email gestionnaire pour le test")
    parser.add_argument("--no-test",          action="store_true",   help="Déployer sans tester")
    args = parser.parse_args()

    token = (args.token
             or os.environ.get("SUPABASE_ACCESS_TOKEN", "")
             or os.environ.get("SUPABASE_MGMT_TOKEN", ""))

    print(f"\n{BOLD}{B}╔══════════════════════════════════════════════════════════╗{RESET}")
    print(f"{BOLD}{B}║  TontineClair — FIX CRITIQUE : valider_code_reset_pin   ║{RESET}")
    print(f"{BOLD}{B}╚══════════════════════════════════════════════════════════╝{RESET}\n")

    if not token:
        err("Token Supabase requis !")
        print(f"\n{BOLD}Comment l'obtenir :{RESET}")
        print("  1. https://supabase.com/dashboard/account/tokens")
        print("  2. Cliquer 'New Token'")
        print("  3. python3 scripts/deploy_fix_valider.py --token sbp_XXXXXX")
        sys.exit(1)

    # ── Étape 1 : Vérifier le token ───────────────────────────────────────────
    head("[1/4] Vérification du token Supabase...")
    st, bd, _ = http_get(
        f"https://api.supabase.com/v1/projects/{PROJECT_REF}",
        {"Authorization": f"Bearer {token}"}
    )
    if st == 200 and isinstance(bd, dict):
        ok(f"Token valide — projet : {bd.get('name', PROJECT_REF)}")
    elif st == 401:
        err("Token invalide ou expiré.")
        print("  Générer un nouveau token : https://supabase.com/dashboard/account/tokens")
        sys.exit(1)
    else:
        warn(f"Impossible de vérifier le token — HTTP {st}, on continue...")

    # ── Étape 2 : Activer pgcrypto (optionnel, ne crashe pas si échoue) ───────
    head("[2/4] Tentative activation pgcrypto...")
    st2, bd2, _ = exec_sql("CREATE EXTENSION IF NOT EXISTS pgcrypto;", token)
    if st2 == 200:
        ok("pgcrypto activée (ou déjà active) — DIGEST() sera disponible")
    else:
        warn(f"pgcrypto non activable — HTTP {st2}")
        info("→ Le fix utilise sha256() natif comme fallback, c'est OK")

    # ── Étape 3 : Déployer le fix SQL ─────────────────────────────────────────
    head("[3/4] Déploiement du fix SQL...")
    sql_file = Path(__file__).parent.parent / "supabase" / "migrations" / "fix_valider_code_reset_pin_v2.sql"
    if not sql_file.exists():
        err(f"Fichier introuvable : {sql_file}")
        sys.exit(1)

    sql = sql_file.read_text(encoding="utf-8")
    info(f"Fichier : {sql_file.name} ({len(sql)} caractères)")
    info("Fonctions à déployer : hash_sha256_safe, valider_code_reset_pin, reinitialiser_pin, modifier_pin")

    # Tentative en un seul bloc
    st3, bd3, raw3 = exec_sql(sql, token)
    if st3 == 200:
        ok("Migration déployée en un bloc !")
    else:
        warn(f"Déploiement monobloc échoué (HTTP {st3}) — déploiement par blocs...")
        if isinstance(bd3, dict):
            info(f"Erreur: {bd3.get('message', str(bd3)[:200])}")
        success, fail = deploy_by_blocks(sql, token)
        if fail > 0:
            err(f"{fail} bloc(s) ont échoué — vérifiez les messages ci-dessus")
            print(f"\n{BOLD}Action manuelle requise :{RESET}")
            print(f"  1. Aller sur : https://supabase.com/dashboard/project/{PROJECT_REF}/sql/new")
            print(f"  2. Copier-coller le contenu de : {sql_file}")
            print(f"  3. Cliquer Run")
            sys.exit(1)
        else:
            ok(f"Tous les blocs déployés ({success} fonctions)")

    # ── Étape 4 : Test du flux complet ───────────────────────────────────────
    if not args.no_test:
        head("[4/4] Test flux complet end-to-end...")
        success = test_flux(args.test_code, args.test_nom, args.test_email)
        if not success:
            print(f"\n{BOLD}{R}Le flux échoue encore — vérifiez les erreurs ci-dessus.{RESET}")
            sys.exit(1)
    else:
        info("Test ignoré (--no-test)")

    print(f"\n{BOLD}{G}✅ TERMINÉ — Le processus de réinitialisation PIN est maintenant opérationnel.{RESET}\n")

if __name__ == "__main__":
    main()
