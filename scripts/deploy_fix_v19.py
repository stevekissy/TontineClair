#!/usr/bin/env python3
"""
TontineClair — Déploiement FIX v19 (bug vote nouveau cycle)
===========================================================
Corrige 2 bugs critiques via Supabase Management API :
  BUG 1 : proposer_nouveau_cycle introuvable (mauvaise signature en prod)
  BUG 2 : clore_vote_redemarrage retourne 0/0/0 (lit JSONB au lieu de table voix)

Usage :
  python3 scripts/deploy_fix_v19.py --token sbp_xxxx

Obtenir le token :
  https://supabase.com/dashboard/account/tokens → New Token
"""

import json, os, sys, urllib.request, urllib.error, argparse, time
from pathlib import Path

PROJECT_REF  = "ubrqtcxbxcmvmxleiglh"
SUPABASE_URL = "https://ubrqtcxbxcmvmxleiglh.supabase.co"
ANON_KEY = (
    "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
    ".eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InVicnF0Y3hieGNtdm14bGVpZ2xoIiwicm9sZSI"
    "6ImFub24iLCJpYXQiOjE3ODMyNzYwMzYsImV4cCI6MjA5ODg1MjAzNn0"
    ".GaCZwMG34cFcxR3lkLuq-7uMM7sQoc_VIqiDEzMgEq4"
)

G = "\033[92m"; R = "\033[91m"; Y = "\033[93m"; B = "\033[94m"; C = "\033[96m"
BOLD = "\033[1m"; RESET = "\033[0m"
def ok(m):   print(f"{G}✅ {m}{RESET}")
def err(m):  print(f"{R}❌ {m}{RESET}")
def warn(m): print(f"{Y}⚠️  {m}{RESET}")
def info(m): print(f"{C}ℹ️  {m}{RESET}")
def step(n, t): print(f"\n{BOLD}[{n}] {t}{RESET}")

def http_post(url, data, headers):
    body = json.dumps(data).encode("utf-8")
    req = urllib.request.Request(url, data=body, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            raw = resp.read().decode("utf-8", errors="replace")
            try:    return resp.status, json.loads(raw), raw
            except: return resp.status, raw, raw
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", errors="replace")
        try:    return e.code, json.loads(raw), raw
        except: return e.code, {"raw": raw}, raw

def http_get(url, headers):
    req = urllib.request.Request(url, headers=headers, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read().decode("utf-8", errors="replace")
            try:    return resp.status, json.loads(raw), raw
            except: return resp.status, raw, raw
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", errors="replace")
        try:    return e.code, json.loads(raw), raw
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
        "Content-Type":  "application/json",
        "apikey":        ANON_KEY,
        "Authorization": f"Bearer {ANON_KEY}",
    }
    return http_post(url, params, headers)

# ── SQL des 3 sections à déployer ─────────────────────────────────────────────

SQL_SECTION_0_DROP_OLD = """
DO $drop_old$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'proposer_nouveau_cycle'
      AND pg_get_function_result(p.oid) = 'boolean'
  ) THEN
    EXECUTE (
      SELECT 'DROP FUNCTION public.' || p.proname || '(' ||
             pg_get_function_arguments(p.oid) || ') CASCADE'
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public'
        AND p.proname = 'proposer_nouveau_cycle'
        AND pg_get_function_result(p.oid) = 'boolean'
      LIMIT 1
    );
    RAISE NOTICE 'FIX v19 - Ancienne proposer_nouveau_cycle (boolean) supprimée';
  ELSE
    RAISE NOTICE 'FIX v19 - Pas ancienne version boolean à supprimer';
  END IF;
END;
$drop_old$;
"""

SQL_SECTION_1_PNC = """
CREATE OR REPLACE FUNCTION proposer_nouveau_cycle(
  p_code      text,
  p_nom       text,
  p_pin       text,
  p_question  text DEFAULT 'Souhaitez-vous recommencer un nouveau cycle de tontine ?'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $func_pnc$
DECLARE
  v_code          text    := upper(trim(p_code));
  v_ok            boolean;
  v_data          jsonb;
  v_votes         jsonb;
  v_vote          jsonb;
  v_vote_id       text;
  v_now           text;
  v_nb_membres    int;
  v_cycle_termine boolean;
  v_nb_tours      int;
  v_nb_historique int;
  v_cycle_num     int;
  i               int;
BEGIN
  SELECT verifier_gestionnaire(v_code, p_nom, p_pin) INTO v_ok;
  IF NOT v_ok THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'PIN incorrect ou gestionnaire non autorisé.');
  END IF;

  SELECT data INTO v_data FROM tontines WHERE code = v_code;
  IF v_data IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Tontine introuvable.');
  END IF;

  v_cycle_termine := COALESCE((v_data->>'cycleTermine')::boolean, false);
  IF NOT v_cycle_termine THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Le cycle n''est pas encore terminé.');
  END IF;

  v_nb_tours      := jsonb_array_length(COALESCE(v_data->'ordre', '[]'::jsonb));
  v_nb_historique := jsonb_array_length(COALESCE(v_data->'historique', '[]'::jsonb));
  IF v_nb_tours = 0 AND v_nb_historique = 0 THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'La tontine n''a jamais démarré.');
  END IF;

  v_votes := COALESCE(v_data->'votes', '[]'::jsonb);
  FOR i IN 0 .. jsonb_array_length(v_votes) - 1 LOOP
    v_vote := v_votes->i;
    IF (v_vote->>'type') = 'nouveau_cycle'
       AND COALESCE((v_vote->>'clos')::boolean, false) = false
       AND COALESCE(v_vote->>'statut', 'ouvert') = 'ouvert'
    THEN
      RETURN jsonb_build_object('ok', false, 'erreur', 'Un vote de redémarrage est déjà en cours.', 'vote_id', v_vote->>'id');
    END IF;
  END LOOP;

  v_vote_id    := 'NC-' || to_char(now(), 'YYYYMMDDHH24MISS') || '-' || substr(md5(random()::text), 1, 6);
  v_now        := to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD') || 'T'
                  || to_char(now() AT TIME ZONE 'UTC', 'HH24:MI:SS') || '.000Z';
  v_nb_membres := COALESCE(jsonb_array_length(v_data->'membres'), 0);
  v_cycle_num  := COALESCE((v_data->>'cycleNum')::int, (v_data->>'cycleNumero')::int, 1);

  v_vote := jsonb_build_object(
    'id',           v_vote_id,
    'type',         'nouveau_cycle',
    'sujet',        p_question,
    'question',     p_question,
    'creePar',      p_nom,
    'createur',     p_nom,
    'le',           v_now,
    'dateCreation', v_now,
    'statut',       'ouvert',
    'clos',         false,
    'voix',         '{}'::jsonb,
    'decompte',     jsonb_build_object('oui', 0, 'non', 0, 'abstention', 0),
    'description',  'Vote de redémarrage - Cycle ' || v_cycle_num,
    'mode',         'securise',
    'quorum',       CEIL(v_nb_membres::float / 2)::int,
    'cycleRefConfig', jsonb_build_object(
      'montant',      COALESCE((v_data->>'montant')::int, 0),
      'periodicite',  COALESCE(v_data->>'periodicite', v_data->>'periode', 'mensuel'),
      'methodeOrdre', COALESCE(v_data->>'methodeOrdre', 'rotation')
    )
  );

  v_data := v_data || jsonb_build_object(
    'votes',   v_votes || jsonb_build_array(v_vote),
    'journal', jsonb_build_array(jsonb_build_object(
      'quoi',         'VOTE_NOUVEAU_CYCLE',
      'gestionnaire', p_nom,
      'quand',        v_now,
      'reference',    v_vote_id,
      'description',  'Proposition de nouveau cycle par ' || p_nom
    )) || COALESCE(v_data->'journal', '[]'::jsonb)
  );

  UPDATE tontines SET data = v_data WHERE code = v_code;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Échec de la sauvegarde.');
  END IF;

  RETURN jsonb_build_object('ok', true, 'vote_id', v_vote_id);
END;
$func_pnc$;

GRANT EXECUTE ON FUNCTION proposer_nouveau_cycle(text, text, text, text) TO anon, authenticated;
"""

SQL_SECTION_2_CVR = """
CREATE OR REPLACE FUNCTION clore_vote_redemarrage(
  p_code    text,
  p_nom     text,
  p_pin     text,
  p_vote_id text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $func_cvr$
DECLARE
  v_code       text    := upper(trim(p_code));
  v_ok         boolean;
  v_data       jsonb;
  v_votes      jsonb;
  v_vote       jsonb;
  v_idx        int := -1;
  v_found      boolean := false;
  v_now        text;
  v_oui        int := 0;
  v_non        int := 0;
  v_abst       int := 0;
  v_total      int;
  v_quorum     int;
  v_adopte     boolean;
  v_voix_jsonb jsonb := '{}'::jsonb;
  v_row        record;
  v_clef       text;
  v_voix_val   text;
  v_voix_old   jsonb;
  i            int;
BEGIN
  SELECT verifier_gestionnaire(v_code, p_nom, p_pin) INTO v_ok;
  IF NOT v_ok THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'PIN incorrect ou gestionnaire non autorisé.');
  END IF;

  SELECT data INTO v_data FROM tontines WHERE code = v_code;
  IF v_data IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Tontine introuvable.');
  END IF;

  v_votes := COALESCE(v_data->'votes', '[]'::jsonb);
  v_now   := to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD') || 'T'
             || to_char(now() AT TIME ZONE 'UTC', 'HH24:MI:SS') || '.000Z';

  FOR i IN 0 .. jsonb_array_length(v_votes) - 1 LOOP
    IF (v_votes->i->>'id') = p_vote_id THEN
      v_vote  := v_votes->i;
      v_idx   := i;
      v_found := true;
      EXIT;
    END IF;
  END LOOP;

  IF NOT v_found THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Vote introuvable : ' || p_vote_id);
  END IF;

  IF COALESCE((v_vote->>'clos')::boolean, false) THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Ce vote est déjà clôturé.');
  END IF;

  v_quorum := COALESCE((v_vote->>'quorum')::int, 1);

  -- SOURCE PRIMAIRE : table voix (voter() v18 écrit ici)
  SELECT
    COUNT(*) FILTER (WHERE choix = 'oui')       AS nb_oui,
    COUNT(*) FILTER (WHERE choix = 'non')        AS nb_non,
    COUNT(*) FILTER (WHERE choix = 'abstention') AS nb_abst
  INTO v_oui, v_non, v_abst
  FROM voix
  WHERE code = v_code AND vote_id = p_vote_id;

  -- FALLBACK : JSONB voix (compatibilité anciens votes)
  IF (v_oui + v_non + v_abst) = 0 THEN
    v_voix_old := COALESCE(v_vote->'voix', '{}'::jsonb);
    FOR v_clef IN SELECT jsonb_object_keys(v_voix_old) LOOP
      v_voix_val := v_voix_old->>v_clef;
      IF    v_voix_val = 'oui'        THEN v_oui  := v_oui  + 1;
      ELSIF v_voix_val = 'non'        THEN v_non  := v_non  + 1;
      ELSIF v_voix_val = 'abstention' THEN v_abst := v_abst + 1;
      END IF;
    END LOOP;
  END IF;

  -- Reconstruire JSONB voix depuis la table (pour cohérence UI)
  FOR v_row IN
    SELECT membre_id, choix FROM voix
    WHERE code = v_code AND vote_id = p_vote_id
  LOOP
    v_voix_jsonb := jsonb_set(v_voix_jsonb, ARRAY[v_row.membre_id], to_jsonb(v_row.choix), true);
  END LOOP;

  v_total  := v_oui + v_non + v_abst;
  v_adopte := (v_total >= v_quorum) AND (v_oui > (v_non + v_abst));

  v_vote := v_vote || jsonb_build_object(
    'clos',     true,
    'statut',   'clos',
    'closLe',   v_now,
    'adopte',   v_adopte,
    'voix',     v_voix_jsonb,
    'decompte', jsonb_build_object('oui', v_oui, 'non', v_non, 'abstention', v_abst),
    'closPar',  p_nom
  );

  v_votes := jsonb_set(v_votes, ARRAY[v_idx::text], v_vote, false);

  v_data := v_data || jsonb_build_object(
    'votes',   v_votes,
    'journal', jsonb_build_array(jsonb_build_object(
      'quoi',         'VOTE_CLOS',
      'gestionnaire', p_nom,
      'quand',        v_now,
      'reference',    p_vote_id,
      'resultat',     CASE WHEN v_adopte THEN 'ACCEPTE' ELSE 'REFUSE' END,
      'oui',          v_oui,
      'non',          v_non,
      'abstention',   v_abst
    )) || COALESCE(v_data->'journal', '[]'::jsonb)
  );

  UPDATE tontines SET data = v_data WHERE code = v_code;

  RETURN jsonb_build_object(
    'ok', true, 'adopte', v_adopte,
    'oui', v_oui, 'non', v_non, 'abstention', v_abst, 'total', v_total
  );
END;
$func_cvr$;

GRANT EXECUTE ON FUNCTION clore_vote_redemarrage(text, text, text, text) TO anon, authenticated;
"""

SQL_VERIFY = """
SELECT
  p.proname AS fonction,
  pg_get_function_result(p.oid) AS retourne,
  CASE WHEN pg_get_function_result(p.oid) = 'jsonb' THEN '✅ OK' ELSE '❌ PROBLÈME' END AS statut
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN ('proposer_nouveau_cycle', 'clore_vote_redemarrage')
ORDER BY p.proname;
"""

def main():
    parser = argparse.ArgumentParser(description="Deploy FIX v19 to Supabase")
    parser.add_argument("--token", "-t", default="", help="Supabase access token (sbp_xxxx)")
    args = parser.parse_args()

    token = args.token or os.environ.get("SUPABASE_ACCESS_TOKEN", "") or os.environ.get("SUPABASE_MGMT_TOKEN", "")

    if not token:
        err("Token d'accès Supabase requis !")
        print(f"\n{BOLD}Comment obtenir le token :{RESET}")
        print("  1. https://supabase.com/dashboard/account/tokens")
        print("  2. Cliquer 'New Token'")
        print("  3. Copier le token (commence par sbp_)")
        print(f"\n{BOLD}Puis relancer :{RESET}")
        print("  python3 scripts/deploy_fix_v19.py --token sbp_XXXXXXXXXXXXXX")
        sys.exit(1)

    print(f"\n{BOLD}{B}══════════════════════════════════════════════════════{RESET}")
    print(f"{BOLD}  TontineClair — FIX v19 : Bug vote nouveau cycle{RESET}")
    print(f"{BOLD}{B}══════════════════════════════════════════════════════{RESET}\n")

    # ── Étape 1 : Vérifier le token ──────────────────────────────────────────
    step("1/5", "Vérification du token Supabase...")
    st, bd, _ = http_get(
        f"https://api.supabase.com/v1/projects/{PROJECT_REF}",
        {"Authorization": f"Bearer {token}"}
    )
    if st == 200 and isinstance(bd, dict):
        ok(f"Token valide — projet : {bd.get('name', PROJECT_REF)}")
    elif st == 401:
        err("Token invalide ou expiré")
        print("  → https://supabase.com/dashboard/account/tokens")
        sys.exit(1)
    else:
        warn(f"Vérification token HTTP {st} — on continue quand même")

    # ── Étape 2 : Section 0 — Drop ancienne signature boolean ────────────────
    step("2/5", "Section 0 : suppression ancienne proposer_nouveau_cycle (boolean)...")
    st, bd, raw = exec_sql(SQL_SECTION_0_DROP_OLD, token)
    if st == 200:
        ok("Section 0 OK")
    else:
        warn(f"Section 0 — HTTP {st}")
        if isinstance(bd, dict): info(f"  {bd.get('message', str(bd)[:200])}")

    time.sleep(0.3)

    # ── Étape 3 : Section 1 — proposer_nouveau_cycle (jsonb) ─────────────────
    step("3/5", "Section 1 : proposer_nouveau_cycle → jsonb (signature p_question)...")
    st, bd, raw = exec_sql(SQL_SECTION_1_PNC, token)
    if st == 200:
        ok("proposer_nouveau_cycle déployée !")
    else:
        err(f"ÉCHEC — HTTP {st}")
        if isinstance(bd, dict):
            print(f"  Message : {bd.get('message', '')}")
            print(f"  Détail  : {bd.get('detail', str(bd)[:400])}")
        else:
            print(f"  Raw: {raw[:500]}")
        err("Arrêt — Section 1 critique")
        sys.exit(1)

    time.sleep(0.3)

    # ── Étape 4 : Section 2 — clore_vote_redemarrage ─────────────────────────
    step("4/5", "Section 2 : clore_vote_redemarrage → lit depuis TABLE voix...")
    st, bd, raw = exec_sql(SQL_SECTION_2_CVR, token)
    if st == 200:
        ok("clore_vote_redemarrage déployée !")
    else:
        err(f"ÉCHEC — HTTP {st}")
        if isinstance(bd, dict):
            print(f"  Message : {bd.get('message', '')}")
            print(f"  Détail  : {bd.get('detail', str(bd)[:400])}")
        else:
            print(f"  Raw: {raw[:500]}")
        err("Arrêt — Section 2 critique")
        sys.exit(1)

    time.sleep(0.5)

    # ── Étape 5 : Vérification ───────────────────────────────────────────────
    step("5/5", "Vérification finale des signatures...")
    st, bd, raw = exec_sql(SQL_VERIFY, token)
    if st == 200 and isinstance(bd, list):
        print()
        for row in bd:
            fn  = row.get("fonction", "?")
            ret = row.get("retourne", "?")
            sta = row.get("statut", "?")
            print(f"  {sta}  {fn}  →  {ret}")
        print()

        all_ok = all(r.get("retourne") == "jsonb" for r in bd)
        if all_ok and len(bd) == 2:
            ok("BUG 1 CORRIGÉ : proposer_nouveau_cycle retourne jsonb")
            ok("BUG 2 CORRIGÉ : clore_vote_redemarrage lit depuis table voix")
            print(f"\n{BOLD}{G}🎉 FIX v19 déployé avec succès !{RESET}")
            print(f"\n{BOLD}Prochaine étape :{RESET}")
            print("  Tester sur l'app : Nouveau Cycle → Proposer → Voter → Clôturer")
            print("  Les résultats doivent maintenant afficher le vrai décompte oui/non/abstention")
        else:
            warn("Résultats inattendus — vérifier manuellement")
            info(f"Raw: {raw[:300]}")
    else:
        warn(f"Vérification HTTP {st}")
        if isinstance(bd, list):
            for row in bd: info(str(row))
        else:
            info(str(bd)[:300])

        # Vérification alternative via RPC
        info("Test alternatif : appel RPC proposer_nouveau_cycle avec p_question...")
        st2, bd2, _ = rpc_call("proposer_nouveau_cycle", {
            "p_code": "TEST_INEXISTANT",
            "p_nom": "test",
            "p_pin": "0000",
            "p_question": "test?"
        })
        if st2 == 200:
            ok(f"RPC proposer_nouveau_cycle OK — réponse: {bd2}")
        elif "PGRST202" in str(bd2):
            err("RPC encore introuvable — déploiement SQL a peut-être échoué")
        else:
            info(f"RPC HTTP {st2} : {str(bd2)[:200]}")

if __name__ == "__main__":
    main()
