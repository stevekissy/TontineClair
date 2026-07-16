-- ═══════════════════════════════════════════════════════════════════════════════
-- Migration 011 — RPCs fondamentaux v1 (reconstruits)
-- ═══════════════════════════════════════════════════════════════════════════════
--
-- CONTEXTE :
--   Ces 10 fonctions constituent le noyau applicatif de TontineClair v1.
--   Elles ont été créées directement dans Supabase SQL Editor et n'ont
--   jamais été sauvegardées dans un fichier SQL source dans le dépôt.
--
--   Elles ont été reconstruites fidèlement à partir de :
--     • Les signatures d'appel exactes de lib/services/supabase_service.dart
--     • Les patterns établis dans les migrations 001–010
--     • Le schéma de la table tontines (colonne `data jsonb`, `gestionnaires jsonb`,
--       `membres_pins jsonb`, `plan text`, `plan_expire timestamptz`)
--     • La documentation inline dans les commentaires Dart
--
-- FONCTIONS RECONSTRUITES (10) :
--   1.  creer_tontine                  — Créer une nouvelle tontine
--   2.  ecrire_tontine                 — Écrire les données avec vérif PIN gestionnaire
--   3.  lire_voix_tontine              — Lister les voix d'une tontine
--   4.  lire_plan                      — Lire le plan Premium simplifié {plan, expire}
--   5.  membres_avec_pin               — Lister les IDs membres ayant un PIN
--   6.  definir_pin_membre             — Admin définit le PIN d'un membre
--   7.  changer_pin_membre             — Membre change son propre PIN
--   8.  admin_desactiver_premium       — Super admin désactive Premium
--   9.  sauvegarder_langue_appareil    — Sauvegarder langue préférée d'un appareil
--  10.  charger_langue_appareil        — Charger langue préférée d'un appareil
--
-- NOTE : Les fonctions de langue (9 & 10) s'appuient sur la table fcm_tokens
--        (migration 004) qui contient déjà une colonne `langue` (text).
--        Elles sont marquées « NEW FEATURE » car non encore déployées en prod.
--
-- IDEMPOTENT : CREATE OR REPLACE — safe à rejouer
-- ═══════════════════════════════════════════════════════════════════════════════


-- ══════════════════════════════════════════════════════════════════════════════
-- 1. creer_tontine
-- ══════════════════════════════════════════════════════════════════════════════
--
-- Appelé depuis Dart :
--   rpc('creer_tontine', {
--     'p_code':          code.toUpperCase(),
--     'p_gestionnaires': gestionnaires,   // List<Map> [{nom, pin}, ...]
--     'p_data':          data,            // Map<String,dynamic> (TontineData JSON)
--   })
--   Retourne : bool (true = OK, false/null = code déjà pris)
--
CREATE OR REPLACE FUNCTION public.creer_tontine(
  p_code          text,
  p_gestionnaires jsonb,
  p_data          jsonb
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_code text := upper(trim(p_code));
BEGIN
  -- Vérifie que le code n'existe pas encore
  IF EXISTS (SELECT 1 FROM tontines WHERE code = v_code) THEN
    RETURN false;
  END IF;

  INSERT INTO tontines(code, gestionnaires, data)
  VALUES (v_code, p_gestionnaires, p_data);

  INSERT INTO audit(code, gestionnaire, empreinte)
  VALUES (v_code, 'creer_tontine', md5(p_data::text));

  RETURN true;
END;
$$;

GRANT EXECUTE ON FUNCTION public.creer_tontine(text, jsonb, jsonb) TO anon, authenticated;


-- ══════════════════════════════════════════════════════════════════════════════
-- 2. ecrire_tontine
-- ══════════════════════════════════════════════════════════════════════════════
--
-- Appelé depuis Dart :
--   rpc('ecrire_tontine', {
--     'p_code': code.toUpperCase(),
--     'p_nom':  nom,
--     'p_pin':  pin,
--     'p_data': data,
--   })
--   Retourne : bool (true = OK, false = PIN incorrect ou tontine introuvable)
--
CREATE OR REPLACE FUNCTION public.ecrire_tontine(
  p_code text,
  p_nom  text,
  p_pin  text,
  p_data jsonb
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_code text := upper(trim(p_code));
  v_ok   boolean;
BEGIN
  -- Vérifier PIN gestionnaire
  SELECT verifier_gestionnaire(v_code, p_nom, p_pin) INTO v_ok;
  IF NOT v_ok THEN
    RETURN false;
  END IF;

  UPDATE tontines
     SET data       = p_data,
         modifie_le = now()
   WHERE code = v_code;

  IF FOUND THEN
    INSERT INTO audit(code, gestionnaire, empreinte)
    VALUES (v_code, p_nom, md5(p_data::text));
  END IF;

  RETURN FOUND;
END;
$$;

GRANT EXECUTE ON FUNCTION public.ecrire_tontine(text, text, text, jsonb) TO anon, authenticated;


-- ══════════════════════════════════════════════════════════════════════════════
-- 3. lire_voix_tontine
-- ══════════════════════════════════════════════════════════════════════════════
--
-- Appelé depuis Dart :
--   rpc('lire_voix_tontine', {'p_code': code.toUpperCase()})
--   Retourne : List (jsonb array) de toutes les voix de la tontine
--              [{code, vote_id, membre_id, choix, methode, appareil, vote_le}, ...]
--
CREATE OR REPLACE FUNCTION public.lire_voix_tontine(p_code text)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'id',        v.id,
        'code',      v.code,
        'vote_id',   v.vote_id,
        'membre_id', v.membre_id,
        'choix',     v.choix,
        'methode',   v.methode,
        'appareil',  v.appareil,
        'vote_le',   v.vote_le
      )
      ORDER BY v.vote_le ASC
    ),
    '[]'::jsonb
  )
  FROM voix v
  WHERE v.code = upper(trim(p_code));
$$;

GRANT EXECUTE ON FUNCTION public.lire_voix_tontine(text) TO anon, authenticated;


-- ══════════════════════════════════════════════════════════════════════════════
-- 4. lire_plan
-- ══════════════════════════════════════════════════════════════════════════════
--
-- Appelé depuis Dart (deux endroits) :
--   rpc('lire_plan', {'p_code': code.toUpperCase()})
--   Retourne : Map {'plan': 'free'|'premium_monthly'|'premium_yearly'|'premium',
--                   'expire': ISO8601 string | null}
--   Fallback Flutter: {'plan': 'free', 'expire': null} si exception
--
-- Simplifie lire_abonnement_tontine pour l'usage Flutter (format plus court).
--
CREATE OR REPLACE FUNCTION public.lire_plan(p_code text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_code     text := upper(trim(p_code));
  v_plan     text := 'free';
  v_expire   timestamptz;
  v_sub_plan text;
  v_sub_exp  timestamptz;
  v_sub_stat text;
BEGIN
  -- 1. Chercher dans la table subscriptions (source de vérité v7+)
  SELECT plan, expires_at, status
    INTO v_sub_plan, v_sub_exp, v_sub_stat
  FROM subscriptions
  WHERE code = v_code
    AND status IN ('active', 'grace_period', 'pending')
  ORDER BY cree_le DESC
  LIMIT 1;

  IF FOUND THEN
    RETURN jsonb_build_object(
      'plan',   v_sub_plan,
      'expire', CASE WHEN v_sub_exp IS NOT NULL
                     THEN to_char(v_sub_exp AT TIME ZONE 'UTC',
                                  'YYYY-MM-DD"T"HH24:MI:SS"Z"')
                     ELSE NULL END
    );
  END IF;

  -- 2. Fallback : colonne tontines.plan (v5/v6)
  BEGIN
    SELECT t.plan, t.plan_expire
      INTO v_plan, v_expire
    FROM tontines t
    WHERE t.code = v_code
    LIMIT 1;
  EXCEPTION WHEN others THEN
    NULL;
  END;

  IF v_plan IN ('premium', 'premium_monthly', 'premium_yearly') THEN
    RETURN jsonb_build_object(
      'plan',   v_plan,
      'expire', CASE WHEN v_expire IS NOT NULL
                     THEN to_char(v_expire AT TIME ZONE 'UTC',
                                  'YYYY-MM-DD"T"HH24:MI:SS"Z"')
                     ELSE NULL END
    );
  END IF;

  -- 3. Gratuit par défaut
  RETURN jsonb_build_object('plan', 'free', 'expire', NULL);
END;
$$;

GRANT EXECUTE ON FUNCTION public.lire_plan(text) TO anon, authenticated;


-- ══════════════════════════════════════════════════════════════════════════════
-- 5. membres_avec_pin
-- ══════════════════════════════════════════════════════════════════════════════
--
-- Appelé depuis Dart :
--   rpc('membres_avec_pin', {'p_code': code.toUpperCase()})
--   Retourne : List<String> — liste des IDs membres ayant un PIN défini
--   (membres_pins est une colonne jsonb de tontines : [{id, pin}, ...])
--
CREATE OR REPLACE FUNCTION public.membres_avec_pin(p_code text)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(
    jsonb_agg(mp->>'id' ORDER BY (mp->>'id'))
    FILTER (WHERE (mp->>'pin') IS NOT NULL AND length(trim(mp->>'pin')) > 0),
    '[]'::jsonb
  )
  FROM tontines t,
       jsonb_array_elements(COALESCE(t.membres_pins, '[]'::jsonb)) AS mp
  WHERE t.code = upper(trim(p_code));
$$;

GRANT EXECUTE ON FUNCTION public.membres_avec_pin(text) TO anon, authenticated;


-- ══════════════════════════════════════════════════════════════════════════════
-- 6. definir_pin_membre
-- ══════════════════════════════════════════════════════════════════════════════
--
-- Appelé depuis Dart :
--   rpc('definir_pin_membre', {
--     'p_code':       code.toUpperCase(),
--     'p_nom':        gestNom,
--     'p_pin':        gestPin,
--     'p_membre_id':  membreId,
--     'p_pin_membre': nouveauPin,
--   })
--   Retourne : bool (true = OK, false = PIN gestionnaire incorrect)
--
-- Le gestionnaire admin définit ou réinitialise le PIN d'un membre.
-- membres_pins est stockée dans la colonne membres_pins jsonb de tontines.
--
CREATE OR REPLACE FUNCTION public.definir_pin_membre(
  p_code       text,
  p_nom        text,
  p_pin        text,
  p_membre_id  text,
  p_pin_membre text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_code     text := upper(trim(p_code));
  v_ok       boolean;
  v_pins     jsonb;
  v_new_pins jsonb;
  v_found    boolean := false;
  v_entry    jsonb;
  i          integer;
BEGIN
  -- Vérifier PIN gestionnaire
  SELECT verifier_gestionnaire(v_code, p_nom, p_pin) INTO v_ok;
  IF NOT v_ok THEN
    RETURN false;
  END IF;

  -- Lire membres_pins actuels
  SELECT COALESCE(membres_pins, '[]'::jsonb)
    INTO v_pins
  FROM tontines
  WHERE code = v_code;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  -- Chercher si p_membre_id existe déjà dans membres_pins
  v_new_pins := '[]'::jsonb;
  FOR i IN 0 .. jsonb_array_length(v_pins) - 1 LOOP
    v_entry := v_pins->i;
    IF (v_entry->>'id') = p_membre_id THEN
      -- Remplacer le PIN existant
      v_new_pins := v_new_pins || jsonb_build_array(
        jsonb_build_object('id', p_membre_id, 'pin', p_pin_membre)
      );
      v_found := true;
    ELSE
      v_new_pins := v_new_pins || jsonb_build_array(v_entry);
    END IF;
  END LOOP;

  -- Ajouter si non trouvé
  IF NOT v_found THEN
    v_new_pins := v_new_pins || jsonb_build_array(
      jsonb_build_object('id', p_membre_id, 'pin', p_pin_membre)
    );
  END IF;

  UPDATE tontines
     SET membres_pins = v_new_pins,
         modifie_le   = now()
   WHERE code = v_code;

  INSERT INTO audit(code, gestionnaire, empreinte)
  VALUES (v_code, p_nom, 'PIN_DEFINI:' || p_membre_id);

  RETURN true;
END;
$$;

GRANT EXECUTE ON FUNCTION public.definir_pin_membre(text, text, text, text, text) TO anon, authenticated;


-- ══════════════════════════════════════════════════════════════════════════════
-- 7. changer_pin_membre
-- ══════════════════════════════════════════════════════════════════════════════
--
-- Appelé depuis Dart :
--   rpc('changer_pin_membre', {
--     'p_code':      code.toUpperCase(),
--     'p_membre_id': membreId,
--     'p_ancien':    ancienPin,
--     'p_nouveau':   nouveauPin,
--   })
--   Retourne : bool (true = OK, false = ancien PIN incorrect ou membre introuvable)
--
-- Le membre change lui-même son PIN en fournissant l'ancien.
--
CREATE OR REPLACE FUNCTION public.changer_pin_membre(
  p_code      text,
  p_membre_id text,
  p_ancien    text,
  p_nouveau   text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_code     text := upper(trim(p_code));
  v_pins     jsonb;
  v_new_pins jsonb;
  v_found    boolean := false;
  v_entry    jsonb;
  i          integer;
BEGIN
  -- Vérifier que le membre existe et que l'ancien PIN correspond
  SELECT COALESCE(membres_pins, '[]'::jsonb)
    INTO v_pins
  FROM tontines
  WHERE code = v_code
    AND membres_pins @> jsonb_build_array(
          jsonb_build_object('id', p_membre_id, 'pin', p_ancien)
        );

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  -- Remplacer le PIN
  v_new_pins := '[]'::jsonb;
  FOR i IN 0 .. jsonb_array_length(v_pins) - 1 LOOP
    v_entry := v_pins->i;
    IF (v_entry->>'id') = p_membre_id THEN
      v_new_pins := v_new_pins || jsonb_build_array(
        jsonb_build_object('id', p_membre_id, 'pin', p_nouveau)
      );
      v_found := true;
    ELSE
      v_new_pins := v_new_pins || jsonb_build_array(v_entry);
    END IF;
  END LOOP;

  IF NOT v_found THEN
    RETURN false;
  END IF;

  UPDATE tontines
     SET membres_pins = v_new_pins,
         modifie_le   = now()
   WHERE code = v_code;

  INSERT INTO audit(code, gestionnaire, empreinte)
  VALUES (v_code, 'MEMBRE:' || p_membre_id, 'PIN_CHANGE');

  RETURN true;
END;
$$;

GRANT EXECUTE ON FUNCTION public.changer_pin_membre(text, text, text, text) TO anon, authenticated;


-- ══════════════════════════════════════════════════════════════════════════════
-- 8. admin_desactiver_premium
-- ══════════════════════════════════════════════════════════════════════════════
--
-- Appelé depuis Dart :
--   rpc('admin_desactiver_premium', {
--     'p_cle':  cle,
--     'p_code': code.toUpperCase(),
--   })
--   Retourne : bool (true = OK, false = clé invalide ou tontine introuvable)
--
-- Super admin désactive manuellement le Premium d'une tontine.
-- Remet plan = 'free', annule l'abonnement actif dans subscriptions.
--
CREATE OR REPLACE FUNCTION public.admin_desactiver_premium(
  p_cle  text,
  p_code text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_code        text := upper(trim(p_code));
  v_cle_ok      boolean;
BEGIN
  -- Vérifier clé admin (réutilise _verif_admin_cle si elle existe)
  BEGIN
    SELECT _verif_admin_cle(p_cle) INTO v_cle_ok;
  EXCEPTION WHEN undefined_function THEN
    -- Fallback direct si _verif_admin_cle n'existe pas encore
    SELECT (p_cle = (SELECT cle FROM admin_config LIMIT 1)) INTO v_cle_ok;
  END;

  IF NOT COALESCE(v_cle_ok, false) THEN
    RETURN false;
  END IF;

  -- Mettre à jour la table tontines (colonne plan — rétrocompatibilité v5/v6)
  UPDATE tontines
     SET plan        = 'free',
         plan_expire = NULL,
         modifie_le  = now()
   WHERE code = v_code;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  -- Annuler les abonnements actifs dans subscriptions (v7+)
  UPDATE subscriptions
     SET status     = 'expired',
         modifie_le = now()
   WHERE code   = v_code
     AND status IN ('active', 'grace_period', 'pending');

  -- Journal d'audit
  BEGIN
    INSERT INTO audit(code, gestionnaire, empreinte)
    VALUES (v_code, 'SUPER_ADMIN', 'PREMIUM_DESACTIVE:' || v_code);
  EXCEPTION WHEN others THEN NULL;
  END;

  RETURN true;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_desactiver_premium(text, text) TO anon, authenticated;


-- ══════════════════════════════════════════════════════════════════════════════
-- 9. sauvegarder_langue_appareil  [NEW FEATURE — pas encore en prod]
-- ══════════════════════════════════════════════════════════════════════════════
--
-- Appelé depuis Dart :
--   rpc('sauvegarder_langue_appareil', {
--     'p_token':  token,      // fcm_token ou identifiant appareil
--     'p_langue': langueCode, // ex: 'fr', 'en', 'ar'
--   })
--   Retourne : void (silencieux — erreur non bloquante côté Flutter)
--
-- Utilise la table fcm_tokens (migration 004) — colonne langue text.
-- ALTER TABLE guard : ajoute la colonne si elle n'existe pas encore.
--
DO $lang_col$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'fcm_tokens' AND column_name = 'langue'
  ) THEN
    ALTER TABLE fcm_tokens ADD COLUMN langue text;
  END IF;
END;
$lang_col$;

CREATE OR REPLACE FUNCTION public.sauvegarder_langue_appareil(
  p_token  text,
  p_langue text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Upsert : met à jour la ligne existante ou insère une nouvelle
  UPDATE fcm_tokens
     SET langue     = p_langue,
         modifie_le = now()
   WHERE token = p_token;

  -- Si le token n'est pas encore dans fcm_tokens, on l'insère sans user_id
  -- (le token sera mis à jour lors du prochain sauvegarder_token)
  IF NOT FOUND THEN
    BEGIN
      INSERT INTO fcm_tokens(token, langue)
      VALUES (p_token, p_langue);
    EXCEPTION WHEN others THEN
      -- Ignorer les erreurs d'insertion (contrainte NOT NULL user_id, etc.)
      NULL;
    END;
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION public.sauvegarder_langue_appareil(text, text) TO anon, authenticated;


-- ══════════════════════════════════════════════════════════════════════════════
-- 10. charger_langue_appareil  [NEW FEATURE — pas encore en prod]
-- ══════════════════════════════════════════════════════════════════════════════
--
-- Appelé depuis Dart :
--   rpc('charger_langue_appareil', {'p_token': token})
--   Retourne : Map {'langue': 'fr'|'en'|...} ou null si non trouvé
--   Fallback Flutter: null → SharedPreferences prend le relais
--
CREATE OR REPLACE FUNCTION public.charger_langue_appareil(p_token text)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT CASE
    WHEN f.langue IS NOT NULL AND length(trim(f.langue)) > 0
    THEN jsonb_build_object('langue', f.langue)
    ELSE NULL
  END
  FROM fcm_tokens f
  WHERE f.token = p_token
  LIMIT 1;
$$;

GRANT EXECUTE ON FUNCTION public.charger_langue_appareil(text) TO anon, authenticated;


-- ══════════════════════════════════════════════════════════════════════════════
-- VÉRIFICATION POST-MIGRATION
-- ══════════════════════════════════════════════════════════════════════════════

DO $verify011$
DECLARE
  v_creer_tontine               boolean;
  v_ecrire_tontine              boolean;
  v_lire_voix_tontine           boolean;
  v_lire_plan                   boolean;
  v_membres_avec_pin            boolean;
  v_definir_pin_membre          boolean;
  v_changer_pin_membre          boolean;
  v_admin_desactiver_premium    boolean;
  v_sauvegarder_langue_appareil boolean;
  v_charger_langue_appareil     boolean;
BEGIN
  SELECT EXISTS(SELECT 1 FROM pg_proc WHERE proname = 'creer_tontine')
    INTO v_creer_tontine;
  SELECT EXISTS(SELECT 1 FROM pg_proc WHERE proname = 'ecrire_tontine')
    INTO v_ecrire_tontine;
  SELECT EXISTS(SELECT 1 FROM pg_proc WHERE proname = 'lire_voix_tontine')
    INTO v_lire_voix_tontine;
  SELECT EXISTS(SELECT 1 FROM pg_proc WHERE proname = 'lire_plan')
    INTO v_lire_plan;
  SELECT EXISTS(SELECT 1 FROM pg_proc WHERE proname = 'membres_avec_pin')
    INTO v_membres_avec_pin;
  SELECT EXISTS(SELECT 1 FROM pg_proc WHERE proname = 'definir_pin_membre')
    INTO v_definir_pin_membre;
  SELECT EXISTS(SELECT 1 FROM pg_proc WHERE proname = 'changer_pin_membre')
    INTO v_changer_pin_membre;
  SELECT EXISTS(SELECT 1 FROM pg_proc WHERE proname = 'admin_desactiver_premium')
    INTO v_admin_desactiver_premium;
  SELECT EXISTS(SELECT 1 FROM pg_proc WHERE proname = 'sauvegarder_langue_appareil')
    INTO v_sauvegarder_langue_appareil;
  SELECT EXISTS(SELECT 1 FROM pg_proc WHERE proname = 'charger_langue_appareil')
    INTO v_charger_langue_appareil;

  RAISE NOTICE '══════════════════════════════════════════════════════';
  RAISE NOTICE 'Migration 011 — RPCs fondamentaux v1 (reconstruits)';
  RAISE NOTICE '══════════════════════════════════════════════════════';
  RAISE NOTICE 'creer_tontine                : %', CASE WHEN v_creer_tontine               THEN '✅ OK' ELSE '❌ MANQUANT' END;
  RAISE NOTICE 'ecrire_tontine               : %', CASE WHEN v_ecrire_tontine              THEN '✅ OK' ELSE '❌ MANQUANT' END;
  RAISE NOTICE 'lire_voix_tontine            : %', CASE WHEN v_lire_voix_tontine           THEN '✅ OK' ELSE '❌ MANQUANT' END;
  RAISE NOTICE 'lire_plan                    : %', CASE WHEN v_lire_plan                   THEN '✅ OK' ELSE '❌ MANQUANT' END;
  RAISE NOTICE 'membres_avec_pin             : %', CASE WHEN v_membres_avec_pin            THEN '✅ OK' ELSE '❌ MANQUANT' END;
  RAISE NOTICE 'definir_pin_membre           : %', CASE WHEN v_definir_pin_membre          THEN '✅ OK' ELSE '❌ MANQUANT' END;
  RAISE NOTICE 'changer_pin_membre           : %', CASE WHEN v_changer_pin_membre          THEN '✅ OK' ELSE '❌ MANQUANT' END;
  RAISE NOTICE 'admin_desactiver_premium     : %', CASE WHEN v_admin_desactiver_premium    THEN '✅ OK' ELSE '❌ MANQUANT' END;
  RAISE NOTICE 'sauvegarder_langue_appareil  : %', CASE WHEN v_sauvegarder_langue_appareil THEN '✅ OK' ELSE '❌ MANQUANT' END;
  RAISE NOTICE 'charger_langue_appareil      : %', CASE WHEN v_charger_langue_appareil     THEN '✅ OK' ELSE '❌ MANQUANT' END;
  RAISE NOTICE '══════════════════════════════════════════════════════';
  RAISE NOTICE 'NOTE : sauvegarder/charger_langue_appareil sont des';
  RAISE NOTICE '       nouvelles fonctionnalités (pas encore en prod).';
  RAISE NOTICE '       Elles nécessitent ALTER TABLE fcm_tokens ADD COLUMN langue.';
  RAISE NOTICE '══════════════════════════════════════════════════════';
END;
$verify011$;
