-- ═══════════════════════════════════════════════════════════════════════════════
-- TontineClair — Migration v13 : Synchronisation Score de Confiance IA
-- ═══════════════════════════════════════════════════════════════════════════════
-- Problème corrigé :
--   La modification manuelle du score écrivait bien dans scores_historique
--   mais ScoreService.calculerScore() recalculait depuis data.stats[] en ignorant
--   le champ membres[].score → le nouveau score disparaissait immédiatement.
--
-- Solution :
--   1. RPC modifier_score_membre : transaction atomique qui écrit
--      • Le champ scoreOverride dans le JSONB tontines.data.membres[]
--      • Une entrée dans scores_historique
--      • Une entrée dans journal_audit
--   2. Le modèle Dart Membre ajoute scoreOverride
--   3. ScoreService.calculerScore() retourne scoreOverride en priorité
--
-- Idempotent : CREATE OR REPLACE / safe à relancer
-- À exécuter dans : Supabase › SQL Editor
-- ═══════════════════════════════════════════════════════════════════════════════


-- ══════════════════════════════════════════════════════════════════════════════
-- 1. RPC modifier_score_membre
--    Transaction atomique :
--      a) Vérifie le PIN gestionnaire
--      b) Écrit scoreOverride + motifOverride + dateOverride dans le JSONB
--         tontines.data.membres[] pour le membre ciblé
--      c) Écrit dans scores_historique (evenement = 'admin')
--      d) Écrit dans journal_audit (action = 'SCORE_MODIF')
--      e) Écrit dans audit (table principale, si elle existe)
--    Retourne : {ok: bool, ancien: int, nouveau: int, message: text}
-- ══════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION modifier_score_membre(
  p_code       text,
  p_nom        text,     -- nom du gestionnaire
  p_pin        text,     -- PIN du gestionnaire
  p_membre_id  text,     -- id du membre cible
  p_nouveau    integer,  -- nouveau score (0-100)
  p_motif      text      -- motif de la modification (obligatoire)
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_code        text    := upper(trim(p_code));
  v_ancien      integer := 50;
  v_data        jsonb;
  v_membres     jsonb;
  v_membre      jsonb;
  v_idx         integer;
  v_found       boolean := false;
  v_now         text    := to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"');
  v_msg         text;
BEGIN
  -- ── Validation de base ────────────────────────────────────────────────────
  IF p_nouveau < 0 OR p_nouveau > 100 THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Score invalide (0-100)');
  END IF;
  IF p_motif IS NULL OR length(trim(p_motif)) < 3 THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Motif obligatoire (min. 3 caractères)');
  END IF;

  -- ── Vérification PIN gestionnaire ─────────────────────────────────────────
  IF NOT EXISTS (
    SELECT 1 FROM tontines
    WHERE code = v_code
      AND gestionnaires @> jsonb_build_array(
            jsonb_build_object('nom', p_nom, 'pin', p_pin)
          )
  ) THEN
    RETURN jsonb_build_object('ok', false, 'message', 'PIN gestionnaire incorrect');
  END IF;

  -- ── Lire le JSONB actuel de la tontine ────────────────────────────────────
  SELECT data INTO v_data
  FROM tontines
  WHERE code = v_code;

  IF v_data IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Tontine introuvable');
  END IF;

  v_membres := coalesce(v_data->'membres', '[]'::jsonb);

  -- ── Trouver le membre et lire son ancien score ────────────────────────────
  v_idx := -1;
  FOR i IN 0 .. jsonb_array_length(v_membres) - 1 LOOP
    v_membre := v_membres->i;
    IF (v_membre->>'id') = p_membre_id THEN
      -- Priorité : lire scoreOverride, sinon score, sinon 50
      v_ancien := coalesce(
        (v_membre->>'scoreOverride')::integer,
        (v_membre->>'score')::integer,
        50
      );
      v_idx := i;
      v_found := true;
      EXIT;
    END IF;
  END LOOP;

  IF NOT v_found THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Membre introuvable dans cette tontine');
  END IF;

  -- ── Mettre à jour scoreOverride dans le JSONB ─────────────────────────────
  -- On écrit 3 champs : scoreOverride (le nouveau score forcé),
  --                     motifOverride (pour traçabilité UI),
  --                     dateOverride (horodatage de la modif)
  v_membres := jsonb_set(
    v_membres,
    ARRAY[v_idx::text],
    v_membres->v_idx
      || jsonb_build_object(
           'scoreOverride', p_nouveau,
           'motifOverride', trim(p_motif),
           'dateOverride',  v_now,
           'adminOverride', p_nom,
           'score',         p_nouveau   -- aussi dans score pour compatibilité
         ),
    false
  );

  -- Réécrire le JSONB dans tontines
  UPDATE tontines
  SET data = jsonb_set(v_data, '{membres}', v_membres, false)
  WHERE code = v_code;

  -- ── Historique des scores (table v6) ──────────────────────────────────────
  INSERT INTO scores_historique(
    code, membre_id, score, score_prec, evenement, description, gestionnaire
  )
  VALUES (
    v_code, p_membre_id, p_nouveau, v_ancien,
    'admin',
    'Modification manuelle par ' || p_nom || '. Motif : ' || trim(p_motif),
    p_nom
  );

  -- ── Journal d'audit v6 ────────────────────────────────────────────────────
  INSERT INTO journal_audit(
    code, gestionnaire, action, detail, membre_id, ancien_val, nouveau_val
  )
  VALUES (
    v_code, p_nom, 'SCORE_MODIF',
    'Motif : ' || trim(p_motif),
    p_membre_id,
    v_ancien::text,
    p_nouveau::text
  );

  -- ── Audit table principale (si elle existe) ────────────────────────────────
  BEGIN
    INSERT INTO audit(code, gestionnaire, empreinte)
    VALUES (
      v_code, p_nom,
      'SCORE_MODIFIE:' || p_membre_id
      || ':' || v_ancien || '->' || p_nouveau
      || ':' || left(trim(p_motif), 100)
    );
  EXCEPTION WHEN undefined_table THEN
    NULL; -- table audit absente — silencieux
  END;

  v_msg := 'Score modifié : ' || v_ancien || ' → ' || p_nouveau
           || ' (' || trim(p_motif) || ')';

  RETURN jsonb_build_object(
    'ok',      true,
    'ancien',  v_ancien,
    'nouveau', p_nouveau,
    'message', v_msg
  );
END;
$$;

GRANT EXECUTE ON FUNCTION modifier_score_membre(text, text, text, text, integer, text)
  TO anon;
GRANT EXECUTE ON FUNCTION modifier_score_membre(text, text, text, text, integer, text)
  TO authenticated;


-- ══════════════════════════════════════════════════════════════════════════════
-- 2. RPC lire_score_membre
--    Retourne le score effectif d'un membre en prioritisant scoreOverride.
--    Utilisé pour synchronisation temps réel après modification.
-- ══════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION lire_score_membre(
  p_code      text,
  p_membre_id text
)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT jsonb_build_object(
    'membre_id',     p_membre_id,
    'score',         coalesce(
                       (m->>'scoreOverride')::integer,
                       (m->>'score')::integer,
                       50
                     ),
    'scoreOverride', (m->>'scoreOverride')::integer,
    'motifOverride', m->>'motifOverride',
    'dateOverride',  m->>'dateOverride',
    'adminOverride', m->>'adminOverride'
  )
  FROM tontines t,
       jsonb_array_elements(coalesce(t.data->'membres', '[]'::jsonb)) AS m
  WHERE t.code = upper(p_code)
    AND (m->>'id') = p_membre_id
  LIMIT 1;
$$;

GRANT EXECUTE ON FUNCTION lire_score_membre(text, text) TO anon;
GRANT EXECUTE ON FUNCTION lire_score_membre(text, text) TO authenticated;


-- ══════════════════════════════════════════════════════════════════════════════
-- 3. RPC reinitialiser_score_override
--    Supprime l'override et laisse ScoreService recalculer librement.
-- ══════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION reinitialiser_score_override(
  p_code      text,
  p_nom       text,
  p_pin       text,
  p_membre_id text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_code    text := upper(trim(p_code));
  v_data    jsonb;
  v_membres jsonb;
  v_membre  jsonb;
  v_idx     integer;
BEGIN
  -- Vérification PIN
  IF NOT EXISTS (
    SELECT 1 FROM tontines
    WHERE code = v_code
      AND gestionnaires @> jsonb_build_array(
            jsonb_build_object('nom', p_nom, 'pin', p_pin)
          )
  ) THEN RETURN false; END IF;

  SELECT data INTO v_data FROM tontines WHERE code = v_code;
  IF v_data IS NULL THEN RETURN false; END IF;

  v_membres := coalesce(v_data->'membres', '[]'::jsonb);

  FOR i IN 0 .. jsonb_array_length(v_membres) - 1 LOOP
    IF (v_membres->i->>'id') = p_membre_id THEN
      v_idx := i;
      -- Retirer les champs override
      v_membre := (v_membres->i)
                  - 'scoreOverride'
                  - 'motifOverride'
                  - 'dateOverride'
                  - 'adminOverride';
      v_membres := jsonb_set(v_membres, ARRAY[i::text], v_membre, false);
      EXIT;
    END IF;
  END LOOP;

  UPDATE tontines
  SET data = jsonb_set(v_data, '{membres}', v_membres, false)
  WHERE code = v_code;

  RETURN true;
END;
$$;

GRANT EXECUTE ON FUNCTION reinitialiser_score_override(text, text, text, text)
  TO anon;
GRANT EXECUTE ON FUNCTION reinitialiser_score_override(text, text, text, text)
  TO authenticated;


-- ══════════════════════════════════════════════════════════════════════════════
-- 4. S'assurer que lire_tontine retourne bien scoreOverride dans membres[]
--    (vérification : aucun changement nécessaire car lire_tontine retourne
--     le JSONB complet de tontines.data, scoreOverride sera donc inclus)
-- ══════════════════════════════════════════════════════════════════════════════
-- Pas de modification nécessaire sur lire_tontine : il retourne data tel quel,
-- donc scoreOverride/motifOverride/dateOverride/adminOverride seront présents
-- dans la réponse Flutter après chargerTontine().


-- ══════════════════════════════════════════════════════════════════════════════
-- 5. Vérification post-migration
-- ══════════════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_fn1 boolean;
  v_fn2 boolean;
  v_fn3 boolean;
BEGIN
  SELECT EXISTS(SELECT 1 FROM pg_proc WHERE proname = 'modifier_score_membre')      INTO v_fn1;
  SELECT EXISTS(SELECT 1 FROM pg_proc WHERE proname = 'lire_score_membre')          INTO v_fn2;
  SELECT EXISTS(SELECT 1 FROM pg_proc WHERE proname = 'reinitialiser_score_override') INTO v_fn3;

  RAISE NOTICE '══════════════════════════════════════════════════════';
  RAISE NOTICE 'Migration v13 — TontineClair Score Sync';
  RAISE NOTICE '══════════════════════════════════════════════════════';
  RAISE NOTICE 'RPC modifier_score_membre        : %', CASE WHEN v_fn1 THEN '✅ OK' ELSE '❌ MANQUANT' END;
  RAISE NOTICE 'RPC lire_score_membre            : %', CASE WHEN v_fn2 THEN '✅ OK' ELSE '❌ MANQUANT' END;
  RAISE NOTICE 'RPC reinitialiser_score_override : %', CASE WHEN v_fn3 THEN '✅ OK' ELSE '❌ MANQUANT' END;
  RAISE NOTICE '══════════════════════════════════════════════════════';
  RAISE NOTICE 'Prérequis : supabase-v6.sql déjà exécuté';
  RAISE NOTICE '  (tables scores_historique + journal_audit requises)';
  RAISE NOTICE '══════════════════════════════════════════════════════';
END;
$$;
