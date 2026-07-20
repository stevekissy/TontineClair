-- ═══════════════════════════════════════════════════════════════════════════
-- FIX v19 — Correction double bug vote nouveau cycle
-- ═══════════════════════════════════════════════════════════════════════════
--
-- BUG 1 : proposer_nouveau_cycle introuvable
--   La production a une ancienne signature (p_vote_id au lieu de p_question)
--   retournant boolean. Flutter envoie p_question (text), ce qui provoque
--   "fonction introuvable" (PostgreSQL fait une résolution exacte des types).
--   FIX : Recréer la fonction avec la signature v15 (p_question, retourne jsonb)
--         + DROP de l'ancienne signature boolean si elle existe.
--
-- BUG 2 : clore_vote_redemarrage retourne 0 oui / 0 non / 0 abstention
--   voter() (v18) écrit dans la TABLE `voix` (relationnel).
--   clore_vote_redemarrage() lit depuis data->'votes'->i->'voix' (JSONB).
--   Ces deux chemins ne se parlent pas → comptage toujours à 0/0/0.
--   FIX : clore_vote_redemarrage compte depuis la table `voix`
--         ET met à jour le champ voix JSONB pour cohérence UI.
--
-- ⚠️  EXÉCUTER dans Supabase Dashboard → SQL Editor → New Query → Run
-- ═══════════════════════════════════════════════════════════════════════════


-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 0 : Supprimer l'ancienne signature boolean de proposer_nouveau_cycle
-- PostgreSQL distingue les surcharges par les types d'arguments.
-- L'ancienne signature était : (text, text, text, text) → boolean
-- La nouvelle signature est  : (text, text, text, text) → jsonb
-- Elles ont la MÊME signature d'arguments → DROP + CREATE OR REPLACE suffit.
-- ─────────────────────────────────────────────────────────────────────────────

DO $drop_old$
BEGIN
  -- Supprimer toutes les surcharges de proposer_nouveau_cycle pour repartir propre
  -- (évite le conflit de type de retour boolean vs jsonb)
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
    RAISE NOTICE 'FIX v19 - SECTION 0 : Ancienne proposer_nouveau_cycle (boolean) supprimée';
  ELSE
    RAISE NOTICE 'FIX v19 - SECTION 0 : Pas d''ancienne version boolean à supprimer';
  END IF;
END;
$drop_old$;


-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 1 : Recréer proposer_nouveau_cycle
-- Signature : (p_code text, p_nom text, p_pin text, p_question text DEFAULT ...)
-- Retourne  : jsonb {ok: bool, vote_id?: text, erreur?: text}
-- ─────────────────────────────────────────────────────────────────────────────

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
  -- 1. Vérifier le PIN gestionnaire
  SELECT verifier_gestionnaire(v_code, p_nom, p_pin) INTO v_ok;
  IF NOT v_ok THEN
    RETURN jsonb_build_object(
      'ok',     false,
      'erreur', 'PIN incorrect ou gestionnaire non autorisé.'
    );
  END IF;

  -- 2. Lire la tontine
  SELECT data INTO v_data FROM tontines WHERE code = v_code;
  IF v_data IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Tontine introuvable.');
  END IF;

  -- 3. Vérifier que le cycle est bien terminé
  v_cycle_termine := COALESCE((v_data->>'cycleTermine')::boolean, false);
  IF NOT v_cycle_termine THEN
    RETURN jsonb_build_object(
      'ok',     false,
      'erreur', 'Le cycle n''est pas encore terminé. Tous les membres doivent d''abord avoir reçu leur cagnotte.'
    );
  END IF;

  -- 4. Vérifier que le cycle a réellement démarré (pas une tontine vierge)
  v_nb_tours      := jsonb_array_length(COALESCE(v_data->'ordre', '[]'::jsonb));
  v_nb_historique := jsonb_array_length(COALESCE(v_data->'historique', '[]'::jsonb));
  IF v_nb_tours = 0 AND v_nb_historique = 0 THEN
    RETURN jsonb_build_object(
      'ok',     false,
      'erreur', 'Impossible de proposer un nouveau cycle : la tontine n''a jamais démarré.'
    );
  END IF;

  -- 5. Vérifier qu'aucun vote nouveau_cycle ouvert n'existe
  v_votes := COALESCE(v_data->'votes', '[]'::jsonb);
  FOR i IN 0 .. jsonb_array_length(v_votes) - 1 LOOP
    v_vote := v_votes->i;
    IF (v_vote->>'type') = 'nouveau_cycle'
       AND COALESCE((v_vote->>'clos')::boolean, false) = false
       AND COALESCE(v_vote->>'statut', 'ouvert') = 'ouvert'
    THEN
      RETURN jsonb_build_object(
        'ok',      false,
        'erreur',  'Un vote de redémarrage est déjà en cours.',
        'vote_id', v_vote->>'id'
      );
    END IF;
  END LOOP;

  -- 6. Créer le vote
  v_vote_id    := 'NC-' || to_char(now(), 'YYYYMMDDHH24MISS')
                  || '-' || substr(md5(random()::text), 1, 6);
  v_now        := to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD') || 'T'
                  || to_char(now() AT TIME ZONE 'UTC', 'HH24:MI:SS') || '.000Z';
  v_nb_membres := COALESCE(jsonb_array_length(v_data->'membres'), 0);
  v_cycle_num  := COALESCE((v_data->>'cycleNum')::int,
                           (v_data->>'cycleNumero')::int, 1);

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

  -- 7. Insérer le vote dans data + entrée journal
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

  -- 8. Sauvegarder
  UPDATE tontines SET data = v_data WHERE code = v_code;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Échec de la sauvegarde.');
  END IF;

  RAISE NOTICE 'proposer_nouveau_cycle OK: code=% vote_id=%', v_code, v_vote_id;

  RETURN jsonb_build_object('ok', true, 'vote_id', v_vote_id);
END;
$func_pnc$;

GRANT EXECUTE ON FUNCTION proposer_nouveau_cycle(text, text, text, text) TO anon, authenticated;

DO $r1$
BEGIN
  RAISE NOTICE 'FIX v19 - SECTION 1 : proposer_nouveau_cycle (jsonb) : OK';
END;
$r1$;


-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 2 : Corriger clore_vote_redemarrage
--
-- PROBLÈME RACINE :
--   voter() (v18) insère dans la TABLE `voix` (relationnel).
--   clore_vote_redemarrage() lit depuis data->'votes'->i->'voix' (JSONB).
--   → Le JSONB voix est toujours {} → comptage 0/0/0 → vote toujours REFUSÉ.
--
-- FIX :
--   1. Compter depuis la table `voix` WHERE code=v_code AND vote_id=p_vote_id
--   2. Reconstruire le JSONB voix depuis la table pour cohérence UI
--   3. Mettre à jour data avec les compteurs corrects
-- ─────────────────────────────────────────────────────────────────────────────

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
  v_code     text    := upper(trim(p_code));
  v_ok       boolean;
  v_data     jsonb;
  v_votes    jsonb;
  v_vote     jsonb;
  v_idx      int := -1;
  v_found    boolean := false;
  v_now      text;
  v_oui      int := 0;
  v_non      int := 0;
  v_abst     int := 0;
  v_total    int;
  v_quorum   int;
  v_adopte   boolean;
  v_voix_jsonb jsonb := '{}'::jsonb;
  -- Pour reconstruire le JSONB voix depuis la table
  v_row      record;
  i          int;
BEGIN
  -- 1. Vérifier gestionnaire
  SELECT verifier_gestionnaire(v_code, p_nom, p_pin) INTO v_ok;
  IF NOT v_ok THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'PIN incorrect ou gestionnaire non autorisé.');
  END IF;

  -- 2. Lire la tontine
  SELECT data INTO v_data FROM tontines WHERE code = v_code;
  IF v_data IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Tontine introuvable.');
  END IF;

  v_votes := COALESCE(v_data->'votes', '[]'::jsonb);
  v_now   := to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD') || 'T'
             || to_char(now() AT TIME ZONE 'UTC', 'HH24:MI:SS') || '.000Z';

  -- 3. Trouver le vote dans le JSONB
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

  -- ─────────────────────────────────────────────────────────────────────────
  -- 4. COMPTER LES VOIX DEPUIS LA TABLE `voix` (source de vérité v18)
  --    voter() écrit dans la table `voix`, pas dans le JSONB.
  --    C'est ici le fix principal du bug 0/0/0.
  -- ─────────────────────────────────────────────────────────────────────────
  SELECT
    COUNT(*) FILTER (WHERE choix = 'oui')        AS nb_oui,
    COUNT(*) FILTER (WHERE choix = 'non')         AS nb_non,
    COUNT(*) FILTER (WHERE choix = 'abstention')  AS nb_abst
  INTO v_oui, v_non, v_abst
  FROM voix
  WHERE code     = v_code
    AND vote_id  = p_vote_id;

  -- 4b. Si la table voix ne contient rien, fallback sur le JSONB voix
  --     (compatibilité avec d'éventuels anciens votes enregistrés en JSONB)
  IF (v_oui + v_non + v_abst) = 0 THEN
    DECLARE
      v_clef     text;
      v_voix_val text;
      v_voix_jsonb_old jsonb;
    BEGIN
      v_voix_jsonb_old := COALESCE(v_vote->'voix', '{}'::jsonb);
      FOR v_clef IN SELECT jsonb_object_keys(v_voix_jsonb_old) LOOP
        v_voix_val := v_voix_jsonb_old->>v_clef;
        IF v_voix_val = 'oui'           THEN v_oui  := v_oui  + 1;
        ELSIF v_voix_val = 'non'        THEN v_non  := v_non  + 1;
        ELSIF v_voix_val = 'abstention' THEN v_abst := v_abst + 1;
        END IF;
      END LOOP;
    END;
  END IF;

  -- 4c. Reconstruire le JSONB voix depuis la table pour cohérence UI
  --     (permet à Flutter d'afficher les choix individuels par membre)
  FOR v_row IN
    SELECT membre_id, choix FROM voix
    WHERE code = v_code AND vote_id = p_vote_id
  LOOP
    v_voix_jsonb := jsonb_set(
      v_voix_jsonb,
      ARRAY[v_row.membre_id],
      to_jsonb(v_row.choix),
      true
    );
  END LOOP;

  -- 5. Calculer le résultat
  v_total  := v_oui + v_non + v_abst;
  v_adopte := (v_total >= v_quorum) AND (v_oui > (v_non + v_abst));

  -- 6. Mettre à jour le vote dans le JSONB
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

  -- 7. Sauvegarder
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

  RAISE NOTICE 'clore_vote_redemarrage OK: % vote=% oui=% non=% abst=% adopte=%',
    v_code, p_vote_id, v_oui, v_non, v_abst, v_adopte;

  RETURN jsonb_build_object(
    'ok',         true,
    'adopte',     v_adopte,
    'oui',        v_oui,
    'non',        v_non,
    'abstention', v_abst,
    'total',      v_total
  );
END;
$func_cvr$;

GRANT EXECUTE ON FUNCTION clore_vote_redemarrage(text, text, text, text) TO anon, authenticated;

DO $r2$
BEGIN
  RAISE NOTICE 'FIX v19 - SECTION 2 : clore_vote_redemarrage : OK (lit depuis table voix)';
END;
$r2$;


-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 3 : Vérification post-migration
-- ─────────────────────────────────────────────────────────────────────────────

DO $verify19$
DECLARE
  v_pnc_sig  text;
  v_cvr_sig  text;
  v_voix_ok  boolean;
BEGIN
  -- Vérifier que proposer_nouveau_cycle retourne jsonb (pas boolean)
  SELECT pg_get_function_result(p.oid) INTO v_pnc_sig
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'proposer_nouveau_cycle'
  LIMIT 1;

  -- Vérifier que clore_vote_redemarrage existe
  SELECT pg_get_function_result(p.oid) INTO v_cvr_sig
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'clore_vote_redemarrage'
  LIMIT 1;

  -- Vérifier que la table voix existe
  SELECT EXISTS(
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'voix'
  ) INTO v_voix_ok;

  RAISE NOTICE '════════════════════════════════════════════════';
  RAISE NOTICE 'FIX v19 — Résultat final';
  RAISE NOTICE '════════════════════════════════════════════════';
  RAISE NOTICE 'proposer_nouveau_cycle  retourne : %', COALESCE(v_pnc_sig, 'MANQUANT');
  RAISE NOTICE '  → attendu : jsonb';
  RAISE NOTICE 'clore_vote_redemarrage  retourne : %', COALESCE(v_cvr_sig, 'MANQUANT');
  RAISE NOTICE '  → attendu : jsonb';
  RAISE NOTICE 'Table voix              existe   : %', CASE WHEN v_voix_ok THEN 'OUI' ELSE 'NON ← PROBLÈME' END;
  RAISE NOTICE '────────────────────────────────────────────────';
  IF v_pnc_sig = 'jsonb' THEN
    RAISE NOTICE '✅ BUG 1 CORRIGÉ : proposer_nouveau_cycle retourne jsonb';
  ELSE
    RAISE WARNING '❌ BUG 1 NON CORRIGÉ : vérifier les erreurs ci-dessus';
  END IF;
  IF v_cvr_sig IS NOT NULL AND v_voix_ok THEN
    RAISE NOTICE '✅ BUG 2 CORRIGÉ : clore_vote_redemarrage lit depuis table voix';
  ELSE
    RAISE WARNING '❌ BUG 2 : vérifier clore_vote_redemarrage et table voix';
  END IF;
  RAISE NOTICE '════════════════════════════════════════════════';
END;
$verify19$;
