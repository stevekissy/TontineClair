-- ╔══════════════════════════════════════════════════════════════════════╗
-- ║  TontineClair — v14 Score Override — COLLER UNIQUEMENT CE FICHIER  ║
-- ║  NE PAS COLLER LES INSTRUCTIONS — COLLER UNIQUEMENT CE SQL         ║
-- ╚══════════════════════════════════════════════════════════════════════╝

CREATE OR REPLACE FUNCTION modifier_score_membre(
  p_code       text,
  p_nom        text,
  p_pin        text,
  p_membre_id  text,
  p_nouveau    integer,
  p_motif      text
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
  v_idx         integer := -1;
  v_found       boolean := false;
  v_now         text    := to_char(now() AT TIME ZONE 'UTC',
                              'YYYY-MM-DD"T"HH24:MI:SS"Z"');
  v_msg         text;
  i             integer;
BEGIN
  IF p_nouveau < 0 OR p_nouveau > 100 THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Score invalide (0-100)');
  END IF;
  IF p_motif IS NULL OR length(trim(p_motif)) < 3 THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Motif obligatoire (min. 3 caracteres)');
  END IF;

  SELECT data INTO v_data FROM tontines WHERE code = v_code;
  IF v_data IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Tontine introuvable : ' || v_code);
  END IF;

  -- Verification PIN : 3 strategies
  IF NOT (
    (
      v_data->'gestionnaires' IS NOT NULL
      AND v_data->'gestionnaires' @> jsonb_build_array(
            jsonb_build_object('nom', p_nom, 'pin', p_pin))
    )
    OR
    EXISTS (
      SELECT 1 FROM tontines
      WHERE code = v_code
        AND gestionnaires @> jsonb_build_array(
              jsonb_build_object('nom', p_nom, 'pin', p_pin))
    )
    OR
    EXISTS (
      SELECT 1 FROM tontines t,
             jsonb_array_elements(COALESCE(t.gestionnaires, '[]'::jsonb)) g
      WHERE t.code = v_code
        AND (g->>'nom') = p_nom
        AND (g->>'pin') = p_pin
    )
  ) THEN
    RETURN jsonb_build_object('ok', false, 'message', 'PIN gestionnaire incorrect');
  END IF;

  v_membres := coalesce(v_data->'membres', '[]'::jsonb);

  FOR i IN 0 .. jsonb_array_length(v_membres) - 1 LOOP
    v_membre := v_membres->i;
    IF (v_membre->>'id') = p_membre_id THEN
      v_ancien := COALESCE(
        (v_membre->>'scoreOverride')::integer,
        (v_membre->>'score')::integer,
        50
      );
      v_idx   := i;
      v_found := true;
      EXIT;
    END IF;
  END LOOP;

  IF NOT v_found THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Membre introuvable : ' || p_membre_id);
  END IF;

  v_membres := jsonb_set(
    v_membres,
    ARRAY[v_idx::text],
    (v_membres->v_idx) || jsonb_build_object(
      'scoreOverride', p_nouveau,
      'motifOverride', trim(p_motif),
      'dateOverride',  v_now,
      'adminOverride', p_nom,
      'score',         p_nouveau
    ),
    false
  );

  UPDATE tontines
  SET data = jsonb_set(v_data, '{membres}', v_membres, false)
  WHERE code = v_code;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Echec mise a jour tontine');
  END IF;

  BEGIN
    INSERT INTO scores_historique(
      code, membre_id, score, score_prec,
      evenement, description, gestionnaire
    ) VALUES (
      v_code, p_membre_id, p_nouveau, v_ancien,
      'admin',
      'Modification manuelle par ' || p_nom || '. Motif : ' || trim(p_motif),
      p_nom
    );
  EXCEPTION WHEN others THEN
    RAISE NOTICE 'scores_historique insert warning: %', SQLERRM;
  END;

  BEGIN
    INSERT INTO journal_audit(
      code, gestionnaire, action, detail,
      membre_id, ancien_val, nouveau_val
    ) VALUES (
      v_code, p_nom, 'SCORE_MODIF',
      'Motif : ' || trim(p_motif),
      p_membre_id,
      v_ancien::text,
      p_nouveau::text
    );
  EXCEPTION WHEN others THEN
    RAISE NOTICE 'journal_audit insert warning: %', SQLERRM;
  END;

  BEGIN
    INSERT INTO audit(code, gestionnaire, empreinte)
    VALUES (
      v_code, p_nom,
      'SCORE_MODIFIE:' || p_membre_id
        || ':' || v_ancien || '->' || p_nouveau
        || ':' || left(trim(p_motif), 100)
    );
  EXCEPTION WHEN others THEN NULL;
  END;

  v_msg := 'Score modifie : ' || v_ancien || ' -> ' || p_nouveau
           || ' (' || trim(p_motif) || ')';

  RAISE NOTICE 'modifier_score_membre OK: % membre=% %->%',
    v_code, p_membre_id, v_ancien, p_nouveau;

  RETURN jsonb_build_object(
    'ok',      true,
    'ancien',  v_ancien,
    'nouveau', p_nouveau,
    'message', v_msg
  );
END;
$$;

GRANT EXECUTE ON FUNCTION modifier_score_membre(text, text, text, text, integer, text)
  TO anon, authenticated;


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
    'score',         COALESCE(
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
       jsonb_array_elements(COALESCE(t.data->'membres', '[]'::jsonb)) AS m
  WHERE t.code = upper(p_code)
    AND (m->>'id') = p_membre_id
  LIMIT 1;
$$;

GRANT EXECUTE ON FUNCTION lire_score_membre(text, text) TO anon, authenticated;


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
  i         integer;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM tontines t,
           jsonb_array_elements(COALESCE(t.gestionnaires, '[]'::jsonb)) g
    WHERE t.code = v_code
      AND (g->>'nom') = p_nom
      AND (g->>'pin') = p_pin
  ) THEN RETURN false; END IF;

  SELECT data INTO v_data FROM tontines WHERE code = v_code;
  IF v_data IS NULL THEN RETURN false; END IF;

  v_membres := COALESCE(v_data->'membres', '[]'::jsonb);

  FOR i IN 0 .. jsonb_array_length(v_membres) - 1 LOOP
    IF (v_membres->i->>'id') = p_membre_id THEN
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
  TO anon, authenticated;


DO $$
DECLARE
  v1 boolean; v2 boolean; v3 boolean;
BEGIN
  SELECT EXISTS(SELECT 1 FROM pg_proc WHERE proname = 'modifier_score_membre')         INTO v1;
  SELECT EXISTS(SELECT 1 FROM pg_proc WHERE proname = 'lire_score_membre')             INTO v2;
  SELECT EXISTS(SELECT 1 FROM pg_proc WHERE proname = 'reinitialiser_score_override')  INTO v3;
  RAISE NOTICE '==============================================';
  RAISE NOTICE 'v14 Score Override — Resultat';
  RAISE NOTICE '==============================================';
  RAISE NOTICE 'modifier_score_membre        : %', CASE WHEN v1 THEN 'OK' ELSE 'MANQUANT' END;
  RAISE NOTICE 'lire_score_membre            : %', CASE WHEN v2 THEN 'OK' ELSE 'MANQUANT' END;
  RAISE NOTICE 'reinitialiser_score_override : %', CASE WHEN v3 THEN 'OK' ELSE 'MANQUANT' END;
  RAISE NOTICE '==============================================';
END;
$$;
