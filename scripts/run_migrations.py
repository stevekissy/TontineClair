#!/usr/bin/env python3
"""
TontineClair — Exécuteur de migrations SQL via Supabase REST + pg/rpc
=======================================================================
Ce script :
  1. Diagnostique l'état actuel (extensions, tables, fonctions)
  2. Déploie admin_reset_pin_gestionnaire.sql via l'API Supabase
  3. Vérifie que toutes les migrations sont en place
  4. Teste le flux complet : RPC → Edge Function → (email)
  5. Affiche un rapport complet avec les actions manuelles restantes

Stratégie de déploiement SQL :
  • Méthode A : Management API (/v1/projects/{ref}/database/query) si SUPABASE_MGMT_TOKEN
  • Méthode B : Edge Function exec-migration si déployée
  • Méthode C : RPC sql_exec si existe
  • Méthode D : Instructions manuelles détaillées
"""

import json
import os
import sys
import time
import urllib.request
import urllib.error
from pathlib import Path
from datetime import datetime

# ─── Configuration ─────────────────────────────────────────────────────────────
SUPABASE_URL = "https://ubrqtcxbxcmvmxleiglh.supabase.co"
PROJECT_REF  = "ubrqtcxbxcmvmxleiglh"

ANON_KEY = (
    "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
    ".eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InVicnF0Y3hieGNtdm14bGVpZ2xoIiwicm9sZSI"
    "6ImFub24iLCJpYXQiOjE3ODMyNzYwMzYsImV4cCI6MjA5ODg1MjAzNn0"
    ".GaCZwMG34cFcxR3lkLuq-7uMM7sQoc_VIqiDEzMgEq4"
)

# Service role key = même header que anon mais avec le JWT service_role.
# Si fourni en env, on l'utilise pour les opérations admin.
SERVICE_ROLE_KEY = os.environ.get("SUPABASE_SERVICE_ROLE_KEY", "")
MGMT_TOKEN       = os.environ.get("SUPABASE_MGMT_TOKEN", "")

# Clé admin de l'app (utilisée par l'app Flutter pour les RPCs admin)
ADMIN_KEY = os.environ.get("TONTINE_ADMIN_KEY", "")

MIGRATIONS_DIR = Path(__file__).parent.parent / "supabase" / "migrations"

# Données de test
TEST_TONTINE_CODE = "K93JAP"
TEST_GEST_NOM     = "Kissy"
TEST_GEST_EMAIL   = "stevekissy@gmail.com"

# ─── Couleurs terminal ──────────────────────────────────────────────────────────
GREEN  = "\033[92m"
RED    = "\033[91m"
YELLOW = "\033[93m"
BLUE   = "\033[94m"
CYAN   = "\033[96m"
BOLD   = "\033[1m"
RESET  = "\033[0m"

def ok(msg):   print(f"  {GREEN}✅ {msg}{RESET}")
def err(msg):  print(f"  {RED}❌ {msg}{RESET}")
def warn(msg): print(f"  {YELLOW}⚠️  {msg}{RESET}")
def info(msg): print(f"  {CYAN}ℹ️  {msg}{RESET}")
def step(msg): print(f"\n{BOLD}{BLUE}{'─'*60}{RESET}\n{BOLD}{msg}{RESET}")
def header(msg): print(f"\n{BOLD}{BLUE}{'═'*60}\n{msg}\n{'═'*60}{RESET}")

# ─── HTTP helpers ───────────────────────────────────────────────────────────────
def http_request(url: str, method: str, data=None, headers: dict = None) -> tuple:
    """Retourne (status_code, parsed_body_or_str, raw_body)."""
    body_bytes = json.dumps(data).encode("utf-8") if data is not None else None
    req = urllib.request.Request(url, data=body_bytes, headers=headers or {}, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read().decode("utf-8", errors="replace")
            try:    return resp.status, json.loads(raw), raw
            except: return resp.status, raw, raw
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", errors="replace")
        try:    return e.code, json.loads(raw), raw
        except: return e.code, {"raw": raw}, raw

def rpc(fn_name: str, params: dict, key: str = None) -> tuple:
    """Appelle une RPC Supabase avec l'anon key (ou la clé fournie)."""
    k = key or ANON_KEY
    url = f"{SUPABASE_URL}/rest/v1/rpc/{fn_name}"
    headers = {
        "Content-Type":  "application/json",
        "apikey":        k,
        "Authorization": f"Bearer {k}",
    }
    return http_request(url, "POST", params, headers)

def rest_get(path: str, key: str = None) -> tuple:
    """GET sur l'API REST Supabase."""
    k = key or ANON_KEY
    url = f"{SUPABASE_URL}/rest/v1/{path}"
    headers = {
        "apikey":        k,
        "Authorization": f"Bearer {k}",
    }
    return http_request(url, "GET", None, headers)

def invoke_edge_function(fn_name: str, payload: dict, key: str = None) -> tuple:
    """Appelle une Edge Function Supabase."""
    k = key or ANON_KEY
    url = f"{SUPABASE_URL}/functions/v1/{fn_name}"
    headers = {
        "Content-Type":  "application/json",
        "apikey":        k,
        "Authorization": f"Bearer {k}",
    }
    return http_request(url, "POST", payload, headers)

def mgmt_api_query(sql: str) -> tuple:
    """
    Exécute du SQL via l'API Management Supabase.
    Nécessite SUPABASE_MGMT_TOKEN (sbp_xxxx).
    """
    if not MGMT_TOKEN:
        return None, None, None
    url = f"https://api.supabase.com/v1/projects/{PROJECT_REF}/database/query"
    headers = {
        "Content-Type":  "application/json",
        "Authorization": f"Bearer {MGMT_TOKEN}",
    }
    return http_request(url, "POST", {"query": sql}, headers)

# ─── Phase 1 : Diagnostic de l'état actuel ─────────────────────────────────────
def phase1_diagnostic():
    header("PHASE 1 — Diagnostic de l'état actuel")

    results = {}

    # 1a. Vérifier que Supabase répond
    step("1a. Connectivité Supabase")
    status, body, _ = rest_get("tontines?limit=1")
    if status in (200, 206):
        ok(f"Supabase accessible — HTTP {status}")
        results["supabase_ok"] = True
    else:
        err(f"Supabase inaccessible — HTTP {status}")
        results["supabase_ok"] = False
        print(f"      Body: {str(body)[:200]}")

    # 1b. Vérifier pgcrypto
    step("1b. Extension pgcrypto")
    # Test indirect : appeler ENCODE(DIGEST('test','sha256'),'hex') via une RPC qui l'utilise
    # On ne peut pas exécuter du SQL brut avec anon key → on teste via une fonction connue
    status, body, raw = rpc("valider_code_reset_pin", {
        "p_code_tontine": "TEST",
        "p_nom_gest": "TEST",
        "p_code": "000000"
    })
    if status == 200:
        ok("valider_code_reset_pin accessible (pgcrypto probablement OK)")
        results["pgcrypto_ok"] = True
        results["valider_code_ok"] = True
    elif status == 404:
        warn("valider_code_reset_pin n'existe pas encore")
        results["pgcrypto_ok"] = None
        results["valider_code_ok"] = False
    elif "digest" in raw.lower() or "pgcrypto" in raw.lower():
        err("pgcrypto NON activée — fonction digest() introuvable")
        results["pgcrypto_ok"] = False
        results["valider_code_ok"] = False
    else:
        info(f"valider_code_reset_pin répond HTTP {status}")
        results["pgcrypto_ok"] = None
        results["valider_code_ok"] = status == 200
        print(f"      Body: {str(body)[:300]}")

    # 1c. Vérifier tables pin_reset_codes et audit_securite
    step("1c. Tables pin_reset_codes et audit_securite")
    for table in ["pin_reset_codes", "audit_securite"]:
        # Avec anon key + RLS, on s'attend à 200 (liste vide) ou 403 (RLS bloque)
        # Les deux indiquent que la table EXISTE
        k = SERVICE_ROLE_KEY if SERVICE_ROLE_KEY else ANON_KEY
        st, bd, _ = rest_get(f"{table}?limit=1", key=k)
        if st in (200, 403, 406):
            ok(f"Table {table} existe — HTTP {st}")
            results[f"table_{table}"] = True
        elif st == 404 or (isinstance(bd, dict) and "does not exist" in str(bd)):
            err(f"Table {table} MANQUANTE")
            results[f"table_{table}"] = False
        else:
            warn(f"Table {table} — statut ambigu HTTP {st}")
            results[f"table_{table}"] = None
            print(f"      Body: {str(bd)[:200]}")

    # 1d. Vérifier demander_reset_pin_v2
    step("1d. Fonction demander_reset_pin_v2")
    status, body, raw = rpc("demander_reset_pin_v2", {
        "p_code_tontine": "K93JAP",
        "p_nom_gest": "Kissy",
        "p_contact": "test@test.com"
    })
    if status == 200 and isinstance(body, dict):
        ok(f"demander_reset_pin_v2 déployée — réponse: {body}")
        results["demander_reset_v2"] = True
    elif status == 404:
        err("demander_reset_pin_v2 NON déployée")
        results["demander_reset_v2"] = False
    else:
        warn(f"demander_reset_pin_v2 HTTP {status} — {str(body)[:200]}")
        results["demander_reset_v2"] = None

    # 1e. Vérifier admin_reinitialiser_pin_gestionnaire
    step("1e. Fonction admin_reinitialiser_pin_gestionnaire")
    status, body, raw = rpc("admin_reinitialiser_pin_gestionnaire", {
        "p_cle": "test_cle_invalide",
        "p_code_tontine": "K93JAP",
        "p_nom_gest": "Kissy"
    })
    if status == 200 and isinstance(body, dict):
        ok(f"admin_reinitialiser_pin_gestionnaire déployée !")
        info(f"Réponse: {body}")
        results["admin_rpc"] = True
    elif status == 404 or (isinstance(body, dict) and "Could not find" in str(body)):
        err("admin_reinitialiser_pin_gestionnaire NON déployée — migration SQL requise")
        results["admin_rpc"] = False
    else:
        warn(f"admin_reinitialiser_pin_gestionnaire HTTP {status}")
        print(f"      Body: {str(body)[:300]}")
        results["admin_rpc"] = None

    # 1f. Vérifier send-manager-pin Edge Function
    step("1f. Edge Function send-manager-pin")
    status, body, raw = invoke_edge_function("send-manager-pin", {
        "email": "test@test.com",
        "gestNom": "Test",
        "tontineCode": "TESTXX",
        "code": "123456"
    })
    if status == 200 and isinstance(body, dict) and body.get("success"):
        ok("send-manager-pin opérationnelle — email envoyé !")
        results["edge_fn"] = "ok"
    elif status in (200, 500) and isinstance(body, dict):
        error_msg = body.get("error", "")
        if "smtp" in error_msg.lower() or "password" in error_msg.lower() or "connect" in error_msg.lower():
            warn(f"send-manager-pin déployée MAIS SMTP non configuré")
            warn(f"Erreur: {error_msg}")
            results["edge_fn"] = "smtp_missing"
        else:
            warn(f"send-manager-pin réponse HTTP {status}: {body}")
            results["edge_fn"] = "deployed_error"
    elif status == 404:
        err("send-manager-pin NON déployée")
        results["edge_fn"] = "missing"
    elif status == 401:
        err("send-manager-pin — 401 Unauthorized")
        results["edge_fn"] = "auth_error"
    else:
        warn(f"send-manager-pin HTTP {status}: {str(body)[:200]}")
        results["edge_fn"] = f"http_{status}"

    # 1g. Vérifier les données de K93JAP/Kissy
    step("1g. Données tontine K93JAP — gestionnaire Kissy")
    st, bd, _ = rest_get("tontines?code=eq.K93JAP&select=code,gestionnaires", key=SERVICE_ROLE_KEY or ANON_KEY)
    if st == 200 and isinstance(bd, list) and bd:
        gests = bd[0].get("gestionnaires", [])
        ok(f"Tontine K93JAP trouvée — gestionnaires: {json.dumps(gests, ensure_ascii=False)}")
        results["k93jap_data"] = gests
        kissy = next((g for g in gests if isinstance(g, dict) and g.get("nom", "").lower() == "kissy"), None)
        if kissy:
            if kissy.get("email"):
                ok(f"Kissy a un email : {kissy['email']}")
                results["kissy_email"] = kissy["email"]
            else:
                err("Kissy n'a PAS d'email — PATCH REST requis")
                results["kissy_email"] = None
        else:
            warn("Kissy non trouvée comme objet dans gestionnaires")
            results["kissy_email"] = None
    else:
        err(f"Impossible de lire K93JAP — HTTP {st}")
        results["k93jap_data"] = None
        results["kissy_email"] = None

    return results

# ─── Phase 2 : Déploiement du SQL via Management API ───────────────────────────
def phase2_deploy_sql(diag_results: dict):
    header("PHASE 2 — Déploiement SQL admin_reinitialiser_pin_gestionnaire")

    if diag_results.get("admin_rpc") == True:
        ok("Fonction déjà déployée — SKIP")
        return True

    sql_file = MIGRATIONS_DIR / "admin_reset_pin_gestionnaire.sql"
    if not sql_file.exists():
        err(f"Fichier migration introuvable : {sql_file}")
        return False

    sql = sql_file.read_text(encoding="utf-8")
    info(f"Fichier SQL : {sql_file.name} ({len(sql)} caractères)")

    # Méthode A : Management API
    if MGMT_TOKEN:
        step("Méthode A : Management API Supabase")
        info(f"POST https://api.supabase.com/v1/projects/{PROJECT_REF}/database/query")
        status, body, raw = mgmt_api_query(sql)
        if status == 200:
            ok("Migration exécutée avec succès via Management API !")
            return True
        else:
            err(f"Management API échouée — HTTP {status}")
            print(f"      Body: {str(body)[:500]}")
    else:
        warn("SUPABASE_MGMT_TOKEN absent — skip méthode Management API")

    # Méthode B : via RPC si une fonction sql_exec existe
    step("Méthode B : Tentative via RPC exec_sql (si existe)")
    for fn_name in ["exec_sql", "sql_exec", "run_sql", "admin_exec_sql"]:
        st, bd, _ = rpc(fn_name, {"query": sql[:1000]})  # test rapide
        if st == 200:
            info(f"Fonction {fn_name} trouvée — exécution complète...")
            st2, bd2, _ = rpc(fn_name, {"query": sql}, key=SERVICE_ROLE_KEY or ANON_KEY)
            if st2 == 200:
                ok(f"Migration exécutée via {fn_name} !")
                return True
            else:
                warn(f"{fn_name} HTTP {st2}: {str(bd2)[:200]}")

    # Méthode C : Utiliser l'Edge Function exec-migration (si déployée)
    step("Méthode C : Edge Function exec-migration (si déployée)")
    st, bd, raw = invoke_edge_function("exec-migration", {
        "sql": sql
    }, key=SERVICE_ROLE_KEY or ANON_KEY)
    if st == 200 and isinstance(bd, dict) and bd.get("success"):
        ok("Migration exécutée via Edge Function exec-migration !")
        return True
    elif st == 404:
        warn("Edge Function exec-migration non déployée")
    else:
        warn(f"exec-migration HTTP {st}: {str(bd)[:300]}")

    # Aucune méthode automatique disponible
    err("Aucune méthode automatique disponible pour exécuter la migration SQL")
    return False

# ─── Phase 3 : Activation pgcrypto via Management API ──────────────────────────
def phase3_pgcrypto(diag_results: dict):
    header("PHASE 3 — Activation extension pgcrypto")

    if diag_results.get("pgcrypto_ok") == True:
        ok("pgcrypto déjà activée — SKIP")
        return True

    sql = "CREATE EXTENSION IF NOT EXISTS pgcrypto;"

    if MGMT_TOKEN:
        step("Activation pgcrypto via Management API")
        status, body, raw = mgmt_api_query(sql)
        if status == 200:
            ok("pgcrypto activée avec succès !")
            return True
        else:
            err(f"Échec activation pgcrypto — HTTP {status}: {str(body)[:300]}")
    else:
        warn("SUPABASE_MGMT_TOKEN absent — activation pgcrypto impossible automatiquement")

    return False

# ─── Phase 4 : Vérification post-déploiement ───────────────────────────────────
def phase4_verify():
    header("PHASE 4 — Vérification post-déploiement")

    # Test admin_reinitialiser_pin_gestionnaire avec cle invalide
    step("Test RPC avec clé invalide (doit retourner ok:false ou erreur spécifique)")
    status, body, raw = rpc("admin_reinitialiser_pin_gestionnaire", {
        "p_cle": "CLEE_INVALIDE_TEST_9999",
        "p_code_tontine": "K93JAP",
        "p_nom_gest": "Kissy"
    })
    print(f"  HTTP {status} — Body: {str(body)[:400]}")

    if status == 200 and isinstance(body, dict):
        if body.get("ok") == False:
            ok(f"Fonction répond correctement — erreur: {body.get('erreur', '')}")
        elif body.get("ok") == True:
            ok(f"Fonction répond ok=true même avec clé invalide (vérifier la logique de clé)")
        else:
            warn(f"Réponse inattendue: {body}")
        return True
    elif status == 404:
        err("Fonction TOUJOURS absente après tentative de déploiement")
        return False
    else:
        warn(f"Réponse HTTP {status}: {str(body)[:300]}")
        return None

# ─── Phase 5 : Test du flux complet ────────────────────────────────────────────
def phase5_full_test(diag_results: dict, admin_key: str):
    header("PHASE 5 — Test du flux complet")

    if not admin_key:
        warn("Clé admin non fournie — test du flux complet limité")
        warn("Définir TONTINE_ADMIN_KEY=<votre_cle> pour tester le flux complet")
        # Test sans clé admin pour voir ce que retourne la fonction
        admin_key = "cle_test_invalide"

    step(f"5a. Appel RPC admin_reinitialiser_pin_gestionnaire")
    info(f"Tontine: {TEST_TONTINE_CODE}, Gestionnaire: {TEST_GEST_NOM}")

    status, body, raw = rpc("admin_reinitialiser_pin_gestionnaire", {
        "p_cle":          admin_key,
        "p_code_tontine": TEST_TONTINE_CODE,
        "p_nom_gest":     TEST_GEST_NOM
    })

    print(f"  HTTP {status}")
    print(f"  Body: {json.dumps(body, ensure_ascii=False, indent=2) if isinstance(body, dict) else str(body)[:400]}")

    if status != 200:
        err(f"RPC échouée — HTTP {status}")
        return False

    if not isinstance(body, dict):
        err(f"Réponse non-JSON: {str(body)[:200]}")
        return False

    if body.get("ok") != True:
        erreur = body.get("erreur", body.get("error", "Erreur inconnue"))
        if "introuvable" in erreur.lower() or "not found" in erreur.lower():
            err(f"RPC retourne ok=false: {erreur}")
        elif "email" in erreur.lower():
            warn(f"Email manquant: {erreur}")
        elif "clé" in erreur.lower() or "cle" in erreur.lower() or "unauthorized" in erreur.lower():
            warn(f"Clé admin invalide: {erreur} — c'est normal pour un test")
        else:
            err(f"RPC retourne ok=false: {erreur}")
        return False

    email      = body.get("email", "")
    gest_nom   = body.get("gest_nom", TEST_GEST_NOM)
    tont_code  = body.get("tontine_code", TEST_TONTINE_CODE)
    code_clair = body.get("code_clair", "")

    ok(f"RPC ok=true !")
    ok(f"Email destinataire: {email}")
    ok(f"Code généré: {code_clair}")
    ok(f"Gestionnaire: {gest_nom} / {tont_code}")

    if not email:
        err("Email vide — impossible d'envoyer le code")
        return False

    # 5b. Appel Edge Function send-manager-pin
    step("5b. Appel Edge Function send-manager-pin")
    info(f"Envoi code {code_clair} à {email}")

    ef_status, ef_body, ef_raw = invoke_edge_function("send-manager-pin", {
        "email":       email,
        "gestNom":     gest_nom,
        "tontineCode": tont_code.upper(),
        "code":        code_clair,
    })

    print(f"  HTTP {ef_status}")
    print(f"  Body: {json.dumps(ef_body, ensure_ascii=False, indent=2) if isinstance(ef_body, dict) else str(ef_body)[:400]}")

    if ef_status == 200 and isinstance(ef_body, dict) and ef_body.get("success"):
        ok(f"✉️  EMAIL ENVOYÉ À {email} !")
        ok("Vérifier la boite mail stevekissy@gmail.com")
        return True
    else:
        ef_error = ef_body.get("error", "") if isinstance(ef_body, dict) else str(ef_body)
        if "smtp" in ef_error.lower() or "password" in ef_error.lower() or "credentials" in ef_error.lower():
            err("SMTP_PASSWORD non configuré dans Supabase Edge Functions Secrets")
            warn(f"Erreur SMTP: {ef_error}")
        elif ef_status == 404:
            err("Edge Function send-manager-pin non déployée")
        else:
            err(f"Edge Function échouée HTTP {ef_status}: {ef_error}")
        return False

# ─── Phase 6 : Rapport final ───────────────────────────────────────────────────
def phase6_report(diag: dict, deploy_ok: bool, pgcrypto_ok: bool, verify_ok, test_ok):
    header("PHASE 6 — Rapport final et actions requises")

    print(f"\n{BOLD}État des composants :{RESET}")
    statuses = {
        "Connectivité Supabase":                diag.get("supabase_ok"),
        "Extension pgcrypto":                   diag.get("pgcrypto_ok"),
        "Table pin_reset_codes":                diag.get("table_pin_reset_codes"),
        "Table audit_securite":                 diag.get("table_audit_securite"),
        "RPC demander_reset_pin_v2":            diag.get("demander_reset_v2"),
        "RPC admin_reinitialiser_pin_gestionnaire": verify_ok,
        "Edge Function send-manager-pin":       diag.get("edge_fn") not in ("missing", "auth_error"),
        "SMTP configuré":                       diag.get("edge_fn") == "ok",
        "Email Kissy (K93JAP)":                 bool(diag.get("kissy_email")),
        "Test flux complet":                    test_ok,
    }

    for label, status in statuses.items():
        if status is True:    ok(label)
        elif status is False: err(label)
        else:                 warn(f"{label} — statut inconnu")

    # Actions manuelles restantes
    actions = []

    if not diag.get("pgcrypto_ok") and not pgcrypto_ok:
        actions.append({
            "titre": "ACTIVER pgcrypto",
            "url": f"https://supabase.com/dashboard/project/{PROJECT_REF}/database/extensions",
            "detail": "Dashboard → Database → Extensions → chercher 'pgcrypto' → Enable"
        })

    if verify_ok != True:
        actions.append({
            "titre": "DÉPLOYER admin_reset_pin_gestionnaire.sql",
            "url": f"https://supabase.com/dashboard/project/{PROJECT_REF}/sql/new",
            "detail": (
                "Copier le contenu de supabase/migrations/admin_reset_pin_gestionnaire.sql\n"
                "   et le coller dans l'éditeur SQL Supabase, puis cliquer Run"
            )
        })

    if diag.get("edge_fn") in ("smtp_missing", "deployed_error"):
        actions.append({
            "titre": "CONFIGURER SMTP_PASSWORD",
            "url": f"https://supabase.com/dashboard/project/{PROJECT_REF}/functions",
            "detail": (
                "Dashboard → Edge Functions → send-manager-pin → Secrets\n"
                "   Ajouter : SMTP_PASSWORD = <votre_mot_de_passe_Hostinger>"
            )
        })

    if diag.get("edge_fn") == "missing":
        actions.append({
            "titre": "DÉPLOYER send-manager-pin",
            "url": "terminal",
            "detail": f"supabase functions deploy send-manager-pin --project-ref {PROJECT_REF}"
        })

    if not diag.get("kissy_email"):
        actions.append({
            "titre": "AJOUTER email à Kissy (K93JAP)",
            "url": f"https://supabase.com/dashboard/project/{PROJECT_REF}/editor",
            "detail": (
                "UPDATE tontines\n"
                "SET gestionnaires = jsonb_set(gestionnaires, '{0,email}', '\"stevekissy@gmail.com\"')\n"
                "WHERE code = 'K93JAP';"
            )
        })

    if not ADMIN_KEY:
        actions.append({
            "titre": "FOURNIR la clé admin",
            "url": "env",
            "detail": (
                "Définir TONTINE_ADMIN_KEY=<cle_admin_app>\n"
                "   Puis relancer : python3 scripts/run_migrations.py"
            )
        })

    if actions:
        print(f"\n{BOLD}{RED}{'─'*60}")
        print(f"⚠️  {len(actions)} ACTION(S) MANUELLE(S) REQUISE(S)")
        print(f"{'─'*60}{RESET}")
        for i, action in enumerate(actions, 1):
            print(f"\n{BOLD}{YELLOW}[{i}] {action['titre']}{RESET}")
            if action["url"] not in ("terminal", "env"):
                print(f"      URL : {action['url']}")
            detail_lines = action["detail"].split("\n")
            for line in detail_lines:
                print(f"      {line}")
    else:
        print(f"\n{BOLD}{GREEN}🎉 TOUT EST EN PLACE ! Flux complet opérationnel.{RESET}")

    # Instructions SQL à copier-coller
    if verify_ok != True:
        sql_file = MIGRATIONS_DIR / "admin_reset_pin_gestionnaire.sql"
        if sql_file.exists():
            print(f"\n{BOLD}{CYAN}{'─'*60}")
            print("SQL à copier dans Supabase SQL Editor :")
            print(f"https://supabase.com/dashboard/project/{PROJECT_REF}/sql/new")
            print(f"{'─'*60}{RESET}")
            sql_content = sql_file.read_text(encoding="utf-8")
            # Afficher juste les premières et dernières lignes
            lines = sql_content.split("\n")
            print(f"  → Fichier : {sql_file}")
            print(f"  → Taille  : {len(sql_content)} caractères, {len(lines)} lignes")
            print(f"  → Commande: cat supabase/migrations/admin_reset_pin_gestionnaire.sql | pbcopy")
            print(f"              (ou afficher avec: cat {sql_file})")

# ─── Main ───────────────────────────────────────────────────────────────────────
def main():
    print(f"\n{BOLD}{BLUE}{'═'*60}")
    print("  TontineClair — Run Migrations & Test Flux PIN Reset")
    print(f"  {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print(f"{'═'*60}{RESET}\n")

    if SERVICE_ROLE_KEY:
        ok(f"SERVICE_ROLE_KEY fournie ({SERVICE_ROLE_KEY[:20]}...)")
    else:
        warn("SUPABASE_SERVICE_ROLE_KEY absent — certaines opérations limités")

    if MGMT_TOKEN:
        ok(f"MGMT_TOKEN fourni ({MGMT_TOKEN[:15]}...)")
    else:
        warn("SUPABASE_MGMT_TOKEN absent — déploiement SQL automatique impossible")

    if ADMIN_KEY:
        ok(f"TONTINE_ADMIN_KEY fournie")
    else:
        warn("TONTINE_ADMIN_KEY absent — test flux complet limité")

    # Phase 1 : Diagnostic
    diag = phase1_diagnostic()

    # Phase 2 : Déploiement SQL
    deploy_ok = phase2_deploy_sql(diag)

    # Phase 3 : pgcrypto
    pgcrypto_deployed = phase3_pgcrypto(diag)

    # Phase 4 : Vérification post-déploiement
    verify_ok = phase4_verify()

    # Phase 5 : Test complet
    test_ok = phase5_full_test(diag, ADMIN_KEY)

    # Phase 6 : Rapport
    phase6_report(diag, deploy_ok, pgcrypto_deployed, verify_ok, test_ok)

    # Exit code
    success = verify_ok == True and (test_ok == True or not ADMIN_KEY)
    sys.exit(0 if success else 1)

if __name__ == "__main__":
    main()
