-- Migration v15 : Nouveau Cycle par Vote (version autonome finale)
-- IDEMPOTENT : CREATE OR REPLACE FUNCTION — safe a relancer
-- A EXECUTER : Supabase SQL Editor > New query > Run
-- DELIMITEURS : $func_XX$ au lieu de $$ pour eviter l'erreur 42601


-- ============================================================
-- SECTION 0 : Correction des donnees corrompues
-- Une tontine avec ordre[] VIDE ne peut pas etre "Cycle termine".
-- Corrige le bug "Cycle termine - 0 tour" visible dans l'UI.
-- ============================================================

UPDATE tontines
SET data = data || jsonb_build_object('cycleTermine', false)
WHERE
  jsonb_array_length(COALESCE(data->'ordre', '[]'::jsonb)) = 0
  AND COALESCE((data->>'cycleTermine')::boolean, false) = true
  AND jsonb_array_length(COALESCE(data->'historique', '[]'::jsonb)) = 0;

DO $report0$
DECLARE n int;
BEGIN
  GET DIAGNOSTICS n = ROW_COUNT;
  RAISE NOTICE 'Migration v15 - SECTION 0 - Donnees corrompues corrigees : % tontine(s)', n;
END;
$report0$;


-- ============================================================
-- SECTION 1 : Helper verifier_gestionnaire
-- 4 strategies PIN pour couvrir toutes les structures JSONB.
-- ============================================================

CREATE OR REPLACE FUNCTION verifier_gestionnaire(
  p_code text,
  p_nom  text,
  p_pin  text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $func_vg$
DECLARE
  v_code text := upper(trim(p_code));
  v_data jsonb;
BEGIN
  SELECT data INTO v_data FROM tontines WHERE code = v_code;
  IF v_data IS NULL THEN RETURN false; END IF;

  -- Strategie A : data.gestionnaires (format principal Flutter)
  IF v_data->'gestionnaires' IS NOT NULL
     AND v_data->'gestionnaires' @> jsonb_build_array(
           jsonb_build_object('nom', p_nom, 'pin', p_pin))
  THEN RETURN true; END IF;

  -- Strategie B : colonne gestionnaires separee (containment)
  IF EXISTS (
    SELECT 1 FROM tontines
    WHERE code = v_code
      AND gestionnaires @> jsonb_build_array(
            jsonb_build_object('nom', p_nom, 'pin', p_pin))
  ) THEN RETURN true; END IF;

  -- Strategie C : champ par champ dans colonne gestionnaires
  IF EXISTS (
    SELECT 1 FROM tontines t,
           jsonb_array_elements(COALESCE(t.gestionnaires, '[]'::jsonb)) g
    WHERE t.code = v_code
      AND (g->>'nom') = p_nom
      AND (g->>'pin') = p_pin
  ) THEN RETURN true; END IF;

  -- Strategie D : champ par champ dans data.gestionnaires
  IF EXISTS (
    SELECT 1 FROM tontines t,
           jsonb_array_elements(COALESCE(t.data->'gestionnaires', '[]'::jsonb)) g
    WHERE t.code = v_code
      AND (g->>'nom') = p_nom
      AND (g->>'pin') = p_pin
  ) THEN RETURN true; END IF;

  RETURN false;
END;
$func_vg$;

GRANT EXECUTE ON FUNCTION verifier_gestionnaire(text, text, text) TO anon, authenticated;

DO $report1$
BEGIN
  RAISE NOTICE 'Migration v15 - SECTION 1 - verifier_gestionnaire : OK (4 strategies PIN)';
END;
$report1$;


-- ============================================================
-- SECTION 2 : RPC proposer_nouveau_cycle  <- FONCTION MANQUANTE
--
-- Parametres Flutter (supabase_service.dart) :
--   p_code     text  -- code tontine (converti majuscules)
--   p_nom      text  -- nom gestionnaire
--   p_pin      text  -- PIN gestionnaire
--   p_question text  -- question du vote (optionnel, valeur par defaut fournie)
--
-- Retourne : {ok: bool, vote_id?: text, erreur?: text}
-- ============================================================

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
  -- 1. Verifier le PIN gestionnaire
  SELECT verifier_gestionnaire(v_code, p_nom, p_pin) INTO v_ok;
  IF NOT v_ok THEN
    RETURN jsonb_build_object(
      'ok',     false,
      'erreur', 'PIN incorrect ou gestionnaire non autorise.'
    );
  END IF;

  -- 2. Lire la tontine
  SELECT data INTO v_data FROM tontines WHERE code = v_code;
  IF v_data IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Tontine introuvable.');
  END IF;

  -- 3. Verifier que le cycle est bien termine
  v_cycle_termine := COALESCE((v_data->>'cycleTermine')::boolean, false);
  IF NOT v_cycle_termine THEN
    RETURN jsonb_build_object(
      'ok',     false,
      'erreur', 'Le cycle n''est pas encore termine. Tous les membres doivent d''abord avoir recu leur cagnotte.'
    );
  END IF;

  -- 4. Verifier que le cycle a reellement demarre
  v_nb_tours      := jsonb_array_length(COALESCE(v_data->'ordre', '[]'::jsonb));
  v_nb_historique := jsonb_array_length(COALESCE(v_data->'historique', '[]'::jsonb));
  IF v_nb_tours = 0 AND v_nb_historique = 0 THEN
    RETURN jsonb_build_object(
      'ok',     false,
      'erreur', 'Impossible de proposer un nouveau cycle : la tontine n''a jamais demarre.'
    );
  END IF;

  -- 5. Verifier qu'aucun vote nouveau_cycle ouvert n'existe
  v_votes := COALESCE(v_data->'votes', '[]'::jsonb);
  FOR i IN 0 .. jsonb_array_length(v_votes) - 1 LOOP
    v_vote := v_votes->i;
    IF (v_vote->>'type') = 'nouveau_cycle'
       AND COALESCE((v_vote->>'clos')::boolean, false) = false
       AND COALESCE(v_vote->>'statut', 'ouvert') = 'ouvert'
    THEN
      RETURN jsonb_build_object(
        'ok',      false,
        'erreur',  'Un vote de redemarrage est deja en cours.',
        'vote_id', v_vote->>'id'
      );
    END IF;
  END LOOP;

  -- 6. Creer le vote
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
    'description',  'Vote de redemarrage - Cycle ' || v_cycle_num,
    'mode',         'securise',
    'quorum',       CEIL(v_nb_membres::float / 2)::int,
    'cycleRefConfig', jsonb_build_object(
      'montant',      COALESCE((v_data->>'montant')::int, 0),
      'periodicite',  COALESCE(v_data->>'periodicite', v_data->>'periode', 'mensuel'),
      'methodeOrdre', COALESCE(v_data->>'methodeOrdre', 'rotation')
    )
  );

  -- 7. Inserer le vote dans data + entree journal
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
    RETURN jsonb_build_object('ok', false, 'erreur', 'Echec de la sauvegarde.');
  END IF;

  RAISE NOTICE 'proposer_nouveau_cycle OK: code=% vote_id=%', v_code, v_vote_id;

  RETURN jsonb_build_object('ok', true, 'vote_id', v_vote_id);
END;
$func_pnc$;

GRANT EXECUTE ON FUNCTION proposer_nouveau_cycle(text, text, text, text) TO anon, authenticated;

DO $report2$
BEGIN
  RAISE NOTICE 'Migration v15 - SECTION 2 - proposer_nouveau_cycle : OK';
  RAISE NOTICE '  Signature : (p_code text, p_nom text, p_pin text, p_question text DEFAULT ...)';
  RAISE NOTICE '  Retourne  : {ok: bool, vote_id?: text, erreur?: text}';
END;
$report2$;


-- ============================================================
-- SECTION 3 : RPC lire_etat_cycle
-- Retourne l'etat du cycle + vote de redemarrage s'il existe.
-- ============================================================

CREATE OR REPLACE FUNCTION lire_etat_cycle(p_code text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $func_lec$
DECLARE
  v_code             text := upper(trim(p_code));
  v_data             jsonb;
  v_votes            jsonb;
  v_vote             jsonb;
  v_vote_redemarrage jsonb := NULL;
  v_cycle_termine    boolean;
  v_nb_membres       int;
  v_nb_tours         int;
  v_tour_actuel      int;
  v_cycle_num        int;
  i                  int;
BEGIN
  SELECT data INTO v_data FROM tontines WHERE code = v_code;
  IF v_data IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Tontine introuvable.');
  END IF;

  v_cycle_termine := COALESCE((v_data->>'cycleTermine')::boolean, false);
  v_nb_membres    := COALESCE(jsonb_array_length(v_data->'membres'), 0);
  v_nb_tours      := COALESCE(jsonb_array_length(v_data->'ordre'), 0);
  v_tour_actuel   := COALESCE((v_data->>'tourActuel')::int, 0);
  v_cycle_num     := COALESCE((v_data->>'cycleNum')::int,
                              (v_data->>'cycleNumero')::int, 1);

  -- Trouver le vote de redemarrage le plus recent
  v_votes := COALESCE(v_data->'votes', '[]'::jsonb);
  FOR i IN 0 .. jsonb_array_length(v_votes) - 1 LOOP
    v_vote := v_votes->i;
    IF (v_vote->>'type') = 'nouveau_cycle' THEN
      IF v_vote_redemarrage IS NULL OR
         (v_vote->>'dateCreation') > (v_vote_redemarrage->>'dateCreation')
      THEN
        v_vote_redemarrage := v_vote;
      END IF;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'ok',              true,
    'cycleTermine',    v_cycle_termine,
    'cycleNum',        v_cycle_num,
    'tourActuel',      v_tour_actuel,
    'nbMembres',       v_nb_membres,
    'nbTours',         v_nb_tours,
    'peutProposer',    (
      v_cycle_termine
      AND (v_nb_tours > 0 OR
           jsonb_array_length(COALESCE(v_data->'historique', '[]'::jsonb)) > 0)
      AND (v_vote_redemarrage IS NULL OR
           COALESCE((v_vote_redemarrage->>'clos')::boolean, false) = true)
    ),
    'voteRedemarrage', v_vote_redemarrage
  );
END;
$func_lec$;

GRANT EXECUTE ON FUNCTION lire_etat_cycle(text) TO anon, authenticated;

DO $report3$
BEGIN
  RAISE NOTICE 'Migration v15 - SECTION 3 - lire_etat_cycle : OK';
END;
$report3$;


-- ============================================================
-- SECTION 4 : RPC clore_vote_redemarrage
-- Cloture le vote et calcule le resultat (adopte / refuse).
-- Parametres : p_code text, p_nom text, p_pin text, p_vote_id text
-- Retourne : {ok: bool, adopte?: bool, oui?: int, non?: int, abstention?: int, erreur?: text}
-- ============================================================

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
  v_voix     jsonb;
  v_clef     text;
  v_voix_val text;
  i          int;
BEGIN
  -- 1. Verifier gestionnaire
  SELECT verifier_gestionnaire(v_code, p_nom, p_pin) INTO v_ok;
  IF NOT v_ok THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'PIN incorrect ou gestionnaire non autorise.');
  END IF;

  -- 2. Lire la tontine
  SELECT data INTO v_data FROM tontines WHERE code = v_code;
  IF v_data IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Tontine introuvable.');
  END IF;

  v_votes := COALESCE(v_data->'votes', '[]'::jsonb);
  v_now   := to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD') || 'T'
             || to_char(now() AT TIME ZONE 'UTC', 'HH24:MI:SS') || '.000Z';

  -- 3. Trouver le vote
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
    RETURN jsonb_build_object('ok', false, 'erreur', 'Ce vote est deja cloture.');
  END IF;

  -- 4. Compter les voix
  v_voix   := COALESCE(v_vote->'voix', '{}'::jsonb);
  v_quorum := COALESCE((v_vote->>'quorum')::int, 1);

  FOR v_clef IN SELECT jsonb_object_keys(v_voix) LOOP
    v_voix_val := v_voix->>v_clef;
    IF v_voix_val = 'oui'           THEN v_oui  := v_oui  + 1;
    ELSIF v_voix_val = 'non'        THEN v_non  := v_non  + 1;
    ELSIF v_voix_val = 'abstention' THEN v_abst := v_abst + 1;
    END IF;
  END LOOP;

  v_total  := v_oui + v_non + v_abst;
  v_adopte := (v_total >= v_quorum) AND (v_oui > (v_non + v_abst));

  -- 5. Mettre a jour le vote
  v_vote := v_vote || jsonb_build_object(
    'clos',     true,
    'statut',   'clos',
    'closLe',   v_now,
    'adopte',   v_adopte,
    'decompte', jsonb_build_object('oui', v_oui, 'non', v_non, 'abstention', v_abst),
    'closPar',  p_nom
  );

  v_votes := jsonb_set(v_votes, ARRAY[v_idx::text], v_vote, false);

  -- 6. Sauvegarder
  v_data := v_data || jsonb_build_object(
    'votes',   v_votes,
    'journal', jsonb_build_array(jsonb_build_object(
      'quoi',         'VOTE_CLOS',
      'gestionnaire', p_nom,
      'quand',        v_now,
      'reference',    p_vote_id,
      'resultat',     CASE WHEN v_adopte THEN 'ACCEPTE' ELSE 'REFUSE' END
    )) || COALESCE(v_data->'journal', '[]'::jsonb)
  );

  UPDATE tontines SET data = v_data WHERE code = v_code;

  RAISE NOTICE 'clore_vote_redemarrage OK: % vote=% adopte=%', v_code, p_vote_id, v_adopte;

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

DO $report4$
BEGIN
  RAISE NOTICE 'Migration v15 - SECTION 4 - clore_vote_redemarrage : OK';
END;
$report4$;


-- ============================================================
-- SECTION 5 : RPC demarrer_nouveau_cycle
-- Demarre le nouveau cycle apres un vote favorable.
--
-- Parametres Flutter :
--   p_code          text     -- code tontine (obligatoire)
--   p_nom           text     -- nom gestionnaire (obligatoire)
--   p_pin           text     -- PIN gestionnaire (obligatoire)
--   p_vote_id       text     -- ID du vote accepte (obligatoire)
--   p_montant       integer  -- nouveau montant (NULL = conserver)
--   p_periodicite   text     -- nouvelle periodicite (NULL = conserver)
--   p_echeance      text     -- 1ere echeance ISO 8601 (NULL = calculer auto)
--   p_methode_ordre text     -- methode d'ordre (NULL = conserver)
--
-- Retourne : {ok: bool, cycleNum?: int, message?: text, erreur?: text}
-- ============================================================

CREATE OR REPLACE FUNCTION demarrer_nouveau_cycle(
  p_code          text,
  p_nom           text,
  p_pin           text,
  p_vote_id       text,
  p_montant       integer DEFAULT NULL,
  p_periodicite   text    DEFAULT NULL,
  p_echeance      text    DEFAULT NULL,
  p_methode_ordre text    DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $func_dnc$
DECLARE
  v_code          text := upper(trim(p_code));
  v_ok            boolean;
  v_data          jsonb;
  v_votes         jsonb;
  v_vote          jsonb;
  v_vote_found    boolean := false;
  v_cycle_termine boolean;
  v_old_cycle     jsonb;
  v_cycle_num     int;
  v_new_cycle_num int;
  v_membres       jsonb;
  v_archives      jsonb;
  v_now           text;
  v_montant       int;
  v_periodicite   text;
  v_methode_ordre text;
  i               int;
BEGIN
  -- 1. Verifier gestionnaire
  SELECT verifier_gestionnaire(v_code, p_nom, p_pin) INTO v_ok;
  IF NOT v_ok THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'PIN incorrect ou gestionnaire non autorise.');
  END IF;

  -- 2. Lire la tontine
  SELECT data INTO v_data FROM tontines WHERE code = v_code;
  IF v_data IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Tontine introuvable.');
  END IF;

  -- 3. Verifier que le cycle est termine
  v_cycle_termine := COALESCE((v_data->>'cycleTermine')::boolean, false);
  IF NOT v_cycle_termine THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Le cycle actuel n''est pas encore termine.');
  END IF;

  -- 4. Verifier que le vote existe, est clos et adopte
  v_votes := COALESCE(v_data->'votes', '[]'::jsonb);
  FOR i IN 0 .. jsonb_array_length(v_votes) - 1 LOOP
    v_vote := v_votes->i;
    IF (v_vote->>'id') = p_vote_id THEN
      v_vote_found := true;
      EXIT;
    END IF;
  END LOOP;

  IF NOT v_vote_found THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Vote introuvable : ' || p_vote_id);
  END IF;
  IF NOT COALESCE((v_vote->>'clos')::boolean, false) THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Le vote n''est pas encore cloture.');
  END IF;
  IF NOT COALESCE((v_vote->>'adopte')::boolean, false) THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Le vote n''a pas ete accepte.');
  END IF;

  v_now           := to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD') || 'T'
                     || to_char(now() AT TIME ZONE 'UTC', 'HH24:MI:SS') || '.000Z';
  v_cycle_num     := COALESCE((v_data->>'cycleNum')::int,
                              (v_data->>'cycleNumero')::int, 1);
  v_new_cycle_num := v_cycle_num + 1;

  -- 5. Parametres du nouveau cycle (NULL = conserver anciens)
  v_montant       := COALESCE(p_montant,       (v_data->>'montant')::int, 5000);
  v_periodicite   := COALESCE(p_periodicite,   v_data->>'periodicite',
                              v_data->>'periode', 'mensuel');
  v_methode_ordre := COALESCE(p_methode_ordre, v_data->>'methodeOrdre', 'rotation');

  -- 6. Archiver le cycle termine
  v_archives := COALESCE(v_data->'cyclesArchives', '[]'::jsonb);
  v_old_cycle := jsonb_build_object(
    'cycleNum',  v_cycle_num,
    'closLe',    v_now,
    'closePar',  p_nom,
    'nbMembres', COALESCE(jsonb_array_length(v_data->'membres'), 0),
    'nbTours',   COALESCE(jsonb_array_length(v_data->'ordre'), 0),
    'montant',   (v_data->>'montant')::int,
    'voteId',    p_vote_id
  );
  v_archives := v_archives || jsonb_build_array(v_old_cycle);

  -- 7. Reinitialiser les membres (paye=false, effacer datePaiement)
  v_membres := COALESCE(v_data->'membres', '[]'::jsonb);
  FOR i IN 0 .. jsonb_array_length(v_membres) - 1 LOOP
    v_membres := jsonb_set(
      v_membres,
      ARRAY[i::text],
      (v_membres->i) || jsonb_build_object('paye', false, 'datePaiement', NULL),
      false
    );
  END LOOP;

  -- 8. Construire le nouveau data (reset du cycle)
  v_data := v_data || jsonb_build_object(
    'cycleNum',         v_new_cycle_num,
    'cycleNumero',      v_new_cycle_num,
    'cycleTermine',     false,
    'tourActuel',       0,
    'ordre',            '[]'::jsonb,
    'paiements',        '{}'::jsonb,
    'historique',       '[]'::jsonb,
    'membres',          v_membres,
    'montant',          v_montant,
    'periodicite',      v_periodicite,
    'periode',          v_periodicite,
    'methodeOrdre',     v_methode_ordre,
    'cyclesArchives',   v_archives,
    'votes',            '[]'::jsonb,
    -- ── Reset tirage : le nouveau cycle nécessite un nouveau tirage ──────
    'ordreVerrouille',  false,
    'ordreMeta',        jsonb_build_object(
                          'verrouille', false,
                          'methode',    v_methode_ordre,
                          'tirage',     null
                        ),
    'journal',          jsonb_build_array(jsonb_build_object(
      'quoi',         'NOUVEAU_CYCLE_DEMARRE',
      'gestionnaire', p_nom,
      'quand',        v_now,
      'cycleNum',     v_new_cycle_num,
      'voteId',       p_vote_id
    )) || COALESCE(v_data->'journal', '[]'::jsonb)
  );

  -- Ajouter la 1ere echeance si fournie
  IF p_echeance IS NOT NULL THEN
    v_data := v_data || jsonb_build_object('echeance', p_echeance);
  END IF;

  -- 9. Sauvegarder
  UPDATE tontines SET data = v_data WHERE code = v_code;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Echec de la sauvegarde.');
  END IF;

  RAISE NOTICE 'demarrer_nouveau_cycle OK: % cycle %->%', v_code, v_cycle_num, v_new_cycle_num;

  RETURN jsonb_build_object(
    'ok',       true,
    'cycleNum', v_new_cycle_num,
    'message',  'Cycle ' || v_new_cycle_num || ' demarre avec succes.'
  );
END;
$func_dnc$;

GRANT EXECUTE ON FUNCTION demarrer_nouveau_cycle(text,text,text,text,integer,text,text,text)
  TO anon, authenticated;

DO $report5$
BEGIN
  RAISE NOTICE 'Migration v15 - SECTION 5 - demarrer_nouveau_cycle : OK';
END;
$report5$;


-- ============================================================
-- SECTION 6 : Verification post-migration
-- ============================================================

DO $verify15$
DECLARE
  v_vg  boolean;
  v_pnc boolean;
  v_lec boolean;
  v_dnc boolean;
  v_cvr boolean;
  v_corrupted int;
BEGIN
  SELECT EXISTS(SELECT 1 FROM pg_proc WHERE proname = 'verifier_gestionnaire')    INTO v_vg;
  SELECT EXISTS(SELECT 1 FROM pg_proc WHERE proname = 'proposer_nouveau_cycle')   INTO v_pnc;
  SELECT EXISTS(SELECT 1 FROM pg_proc WHERE proname = 'lire_etat_cycle')          INTO v_lec;
  SELECT EXISTS(SELECT 1 FROM pg_proc WHERE proname = 'demarrer_nouveau_cycle')   INTO v_dnc;
  SELECT EXISTS(SELECT 1 FROM pg_proc WHERE proname = 'clore_vote_redemarrage')   INTO v_cvr;

  SELECT COUNT(*) INTO v_corrupted
  FROM tontines
  WHERE jsonb_array_length(COALESCE(data->'ordre', '[]'::jsonb)) = 0
    AND COALESCE((data->>'cycleTermine')::boolean, false) = true
    AND jsonb_array_length(COALESCE(data->'historique', '[]'::jsonb)) = 0;

  RAISE NOTICE '================================================';
  RAISE NOTICE 'Migration v15 - Resultat final';
  RAISE NOTICE '================================================';
  RAISE NOTICE 'verifier_gestionnaire    : %', CASE WHEN v_vg  THEN 'OK' ELSE 'MANQUANT' END;
  RAISE NOTICE 'proposer_nouveau_cycle   : %', CASE WHEN v_pnc THEN 'OK' ELSE 'MANQUANT' END;
  RAISE NOTICE 'lire_etat_cycle          : %', CASE WHEN v_lec THEN 'OK' ELSE 'MANQUANT' END;
  RAISE NOTICE 'demarrer_nouveau_cycle   : %', CASE WHEN v_dnc THEN 'OK' ELSE 'MANQUANT' END;
  RAISE NOTICE 'clore_vote_redemarrage   : %', CASE WHEN v_cvr THEN 'OK' ELSE 'MANQUANT' END;
  RAISE NOTICE '------------------------------------------------';
  RAISE NOTICE 'Donnees corrompues restantes : %', v_corrupted;
  RAISE NOTICE '================================================';
END;
$verify15$;
