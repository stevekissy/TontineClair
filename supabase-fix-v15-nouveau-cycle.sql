-- ═══════════════════════════════════════════════════════════════════════════════
-- TontineClair — Migration v15 : Nouveau Cycle par Vote (version autonome finale)
-- ═══════════════════════════════════════════════════════════════════════════════
--
-- CAUSE EXACTE DE L'ERREUR :
--   "la fonction proposer_nouveau_cycle est introuvable dans la base"
--   Les migrations v9 et v10 créaient cette fonction mais n'ont probablement
--   jamais été exécutées dans Supabase, ou ont échoué silencieusement car
--   la fonction helper verifier_gestionnaire était absente.
--
-- CE QUE FAIT CETTE MIGRATION :
--   1. Corrige les données corrompues (cycleTermine=true sur tontines jamais lancées)
--   2. Crée verifier_gestionnaire (helper utilisé par toutes les RPCs cycle)
--   3. Crée proposer_nouveau_cycle (MANQUANTE — cause du bouton cassé)
--   4. Crée lire_etat_cycle
--   5. Crée demarrer_nouveau_cycle
--   6. Crée clore_vote_redemarrage
--   7. Ajoute les GRANT necessaires
--
-- IDEMPOTENT : CREATE OR REPLACE FUNCTION — safe à relancer
-- PRÉREQUIS  : aucun (autonome)
-- À EXÉCUTER : Supabase › SQL Editor › New query › Run
-- ═══════════════════════════════════════════════════════════════════════════════


-- ══════════════════════════════════════════════════════════════════════════════
-- SECTION 0 : Correction des données corrompues
-- Règle : une tontine avec ordre[] VIDE ne peut pas être "Cycle terminé".
-- Cela corrige le bug "Cycle terminé — 0 tour" visible dans l'UI.
-- ══════════════════════════════════════════════════════════════════════════════

-- Réinitialiser cycleTermine=false pour toutes les tontines où :
--   • ordre[] est vide ou absent
--   • ET cycleTermine était true (corruption)
--   • ET historique[] est vide (jamais lancée)
UPDATE tontines
SET data = data || jsonb_build_object('cycleTermine', false)
WHERE
  jsonb_array_length(COALESCE(data->'ordre', '[]'::jsonb)) = 0
  AND COALESCE((data->>'cycleTermine')::boolean, false) = true
  AND jsonb_array_length(COALESCE(data->'historique', '[]'::jsonb)) = 0;

DO $$
DECLARE n int;
BEGIN
  GET DIAGNOSTICS n = ROW_COUNT;
  RAISE NOTICE '════════════════════════════════════════════════════';
  RAISE NOTICE 'Migration v15 — TontineClair Nouveau Cycle';
  RAISE NOTICE '════════════════════════════════════════════════════';
  RAISE NOTICE 'SECTION 0 — Données corrompues corrigées : % tontine(s)', n;
  RAISE NOTICE '  (cycleTermine réinitialisé à false pour tontines jamais lancées)';
END $$;


-- ══════════════════════════════════════════════════════════════════════════════
-- SECTION 1 : Helper verifier_gestionnaire
-- Vérifie qu'un gestionnaire existe dans la tontine avec le bon PIN.
-- Utilisé par toutes les RPCs du module Nouveau Cycle.
-- 3 stratégies pour couvrir les différentes structures JSONB possibles.
-- ══════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION verifier_gestionnaire(
  p_code text,
  p_nom  text,
  p_pin  text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_code text := upper(trim(p_code));
  v_data jsonb;
BEGIN
  SELECT data INTO v_data FROM tontines WHERE code = v_code;
  IF v_data IS NULL THEN RETURN false; END IF;

  -- Stratégie A : gestionnaires dans tontines.data (format principal)
  IF v_data->'gestionnaires' IS NOT NULL
     AND v_data->'gestionnaires' @> jsonb_build_array(
           jsonb_build_object('nom', p_nom, 'pin', p_pin))
  THEN RETURN true; END IF;

  -- Stratégie B : colonne gestionnaires séparée
  IF EXISTS (
    SELECT 1 FROM tontines
    WHERE code = v_code
      AND gestionnaires @> jsonb_build_array(
            jsonb_build_object('nom', p_nom, 'pin', p_pin))
  ) THEN RETURN true; END IF;

  -- Stratégie C : comparaison champ par champ dans colonne gestionnaires
  IF EXISTS (
    SELECT 1 FROM tontines t,
           jsonb_array_elements(COALESCE(t.gestionnaires, '[]'::jsonb)) g
    WHERE t.code = v_code
      AND (g->>'nom') = p_nom
      AND (g->>'pin') = p_pin
  ) THEN RETURN true; END IF;

  -- Stratégie D : comparaison champ par champ dans data.gestionnaires
  IF EXISTS (
    SELECT 1 FROM tontines t,
           jsonb_array_elements(COALESCE(t.data->'gestionnaires', '[]'::jsonb)) g
    WHERE t.code = v_code
      AND (g->>'nom') = p_nom
      AND (g->>'pin') = p_pin
  ) THEN RETURN true; END IF;

  RETURN false;
END;
$$;

GRANT EXECUTE ON FUNCTION verifier_gestionnaire(text, text, text) TO anon, authenticated;

DO $$ BEGIN
  RAISE NOTICE 'SECTION 1 — verifier_gestionnaire : ✅ OK (4 stratégies PIN)';
END $$;


-- ══════════════════════════════════════════════════════════════════════════════
-- SECTION 2 : RPC proposer_nouveau_cycle  ← FONCTION MANQUANTE
--
-- Paramètres Flutter (supabase_service.dart ligne ~681) :
--   p_code     text  — code tontine (converti en majuscules)
--   p_nom      text  — nom du gestionnaire
--   p_pin      text  — PIN du gestionnaire
--   p_question text  — question du vote (optionnel, a une valeur par défaut)
--
-- Retourne : {ok: bool, vote_id?: text, erreur?: text}
--
-- Règles métier :
--   1. PIN gestionnaire valide
--   2. Tontine existante
--   3. cycleTermine = true (le cycle doit être réellement terminé)
--   4. Cycle a réellement démarré (ordre non vide OU historique non vide)
--   5. Aucun vote 'nouveau_cycle' déjà ouvert
--   6. Crée le vote et l'ajoute dans data['votes']
-- ══════════════════════════════════════════════════════════════════════════════

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
AS $$
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
  -- ── 1. Vérifier le PIN gestionnaire ───────────────────────────────────────
  SELECT verifier_gestionnaire(v_code, p_nom, p_pin) INTO v_ok;
  IF NOT v_ok THEN
    RETURN jsonb_build_object(
      'ok',     false,
      'erreur', 'PIN incorrect ou gestionnaire non autorisé.'
    );
  END IF;

  -- ── 2. Lire la tontine ────────────────────────────────────────────────────
  SELECT data INTO v_data FROM tontines WHERE code = v_code;
  IF v_data IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Tontine introuvable.');
  END IF;

  -- ── 3. Vérifier que le cycle est bien terminé ─────────────────────────────
  v_cycle_termine := COALESCE((v_data->>'cycleTermine')::boolean, false);
  IF NOT v_cycle_termine THEN
    RETURN jsonb_build_object(
      'ok',     false,
      'erreur', 'Le cycle n''est pas encore terminé. Tous les membres doivent d''abord avoir reçu leur cagnotte.'
    );
  END IF;

  -- ── 4. Vérifier que le cycle a réellement démarré ────────────────────────
  --    (empêche de proposer sur une tontine jamais lancée avec cycleTermine=true corrompu)
  v_nb_tours      := jsonb_array_length(COALESCE(v_data->'ordre', '[]'::jsonb));
  v_nb_historique := jsonb_array_length(COALESCE(v_data->'historique', '[]'::jsonb));
  IF v_nb_tours = 0 AND v_nb_historique = 0 THEN
    RETURN jsonb_build_object(
      'ok',     false,
      'erreur', 'Impossible de proposer un nouveau cycle : la tontine n''a jamais démarré. Lancez d''abord le premier cycle.'
    );
  END IF;

  -- ── 5. Vérifier qu'aucun vote 'nouveau_cycle' ouvert n'existe ────────────
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

  -- ── 6. Créer le vote ──────────────────────────────────────────────────────
  v_vote_id    := 'NC-' || to_char(now(), 'YYYYMMDDHH24MISS')
                  || '-' || substr(md5(random()::text), 1, 6);
  v_now        := to_char(now() AT TIME ZONE 'UTC',
                          'YYYY-MM-DD"T"HH24:MI:SS".000Z"');
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
    'description',  'Vote de redémarrage — Cycle ' || v_cycle_num,
    'mode',         'securise',
    'quorum',       CEIL(v_nb_membres::float / 2)::int,
    'cycleRefConfig', jsonb_build_object(
      'montant',      COALESCE((v_data->>'montant')::int, 0),
      'periodicite',  COALESCE(v_data->>'periodicite', v_data->>'periode', 'mensuel'),
      'methodeOrdre', COALESCE(v_data->>'methodeOrdre', 'rotation')
    )
  );

  -- ── 7. Insérer le vote dans data + entrée journal ──────────────────────
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

  -- ── 8. Sauvegarder ───────────────────────────────────────────────────────
  UPDATE tontines SET data = v_data WHERE code = v_code;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Échec de la sauvegarde.');
  END IF;

  RAISE NOTICE 'proposer_nouveau_cycle OK: code=% vote_id=%', v_code, v_vote_id;

  RETURN jsonb_build_object('ok', true, 'vote_id', v_vote_id);
END;
$$;

GRANT EXECUTE ON FUNCTION proposer_nouveau_cycle(text, text, text, text) TO anon, authenticated;

DO $$ BEGIN
  RAISE NOTICE 'SECTION 2 — proposer_nouveau_cycle : ✅ OK';
  RAISE NOTICE '  Signature : (p_code text, p_nom text, p_pin text, p_question text DEFAULT ...)';
  RAISE NOTICE '  Retourne  : {ok: bool, vote_id?: text, erreur?: text}';
END $$;


-- ══════════════════════════════════════════════════════════════════════════════
-- SECTION 3 : RPC lire_etat_cycle
-- Retourne l'état complet du cycle + le vote de redémarrage s'il existe.
-- Appelée par : SupabaseService.lireEtatCycle(code)
-- ══════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION lire_etat_cycle(p_code text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_code          text := upper(trim(p_code));
  v_data          jsonb;
  v_votes         jsonb;
  v_vote          jsonb;
  v_vote_redemarrage jsonb := NULL;
  v_cycle_termine boolean;
  v_nb_membres    int;
  v_nb_tours      int;
  v_tour_actuel   int;
  v_cycle_num     int;
  i               int;
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

  -- Trouver le vote de redémarrage le plus récent
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
      AND (v_nb_tours > 0 OR jsonb_array_length(COALESCE(v_data->'historique','[]'::jsonb)) > 0)
      AND (v_vote_redemarrage IS NULL OR COALESCE((v_vote_redemarrage->>'clos')::boolean, false) = true)
    ),
    'voteRedemarrage', v_vote_redemarrage
  );
END;
$$;

GRANT EXECUTE ON FUNCTION lire_etat_cycle(text) TO anon, authenticated;

DO $$ BEGIN
  RAISE NOTICE 'SECTION 3 — lire_etat_cycle : ✅ OK';
END $$;


-- ══════════════════════════════════════════════════════════════════════════════
-- SECTION 4 : RPC clore_vote_redemarrage
-- Clôture le vote et calcule le résultat (adopté / refusé).
-- Appelée par : SupabaseService.cloreVoteRedemarrage(...)
--
-- Paramètres Flutter :
--   p_code    text — code tontine
--   p_nom     text — nom gestionnaire
--   p_pin     text — PIN gestionnaire
--   p_vote_id text — ID du vote à clôturer
--
-- Retourne : {ok: bool, adopte?: bool, oui?: int, non?: int, abstention?: int, erreur?: text}
-- ══════════════════════════════════════════════════════════════════════════════

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
AS $$
DECLARE
  v_code    text    := upper(trim(p_code));
  v_ok      boolean;
  v_data    jsonb;
  v_votes   jsonb;
  v_vote    jsonb;
  v_idx     int := -1;
  v_found   boolean := false;
  v_now     text;
  v_oui     int := 0;
  v_non     int := 0;
  v_abst    int := 0;
  v_total   int;
  v_quorum  int;
  v_adopte  boolean;
  v_voix    jsonb;
  v_clef    text;
  v_voix_val text;
  i         int;
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
  v_now   := to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS".000Z"');

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
    RETURN jsonb_build_object('ok', false, 'erreur', 'Ce vote est déjà clôturé.');
  END IF;

  -- 4. Compter les voix
  v_voix  := COALESCE(v_vote->'voix', '{}'::jsonb);
  v_quorum := COALESCE((v_vote->>'quorum')::int, 1);

  FOR v_clef IN SELECT jsonb_object_keys(v_voix) LOOP
    v_voix_val := v_voix->>v_clef;
    IF v_voix_val = 'oui'        THEN v_oui  := v_oui  + 1;
    ELSIF v_voix_val = 'non'     THEN v_non  := v_non  + 1;
    ELSIF v_voix_val = 'abstention' THEN v_abst := v_abst + 1;
    END IF;
  END LOOP;

  v_total  := v_oui + v_non + v_abst;
  -- Adopté si : quorum atteint ET majorité absolue des votants pour "oui"
  v_adopte := (v_total >= v_quorum) AND (v_oui > (v_non + v_abst));

  -- 5. Mettre à jour le vote
  v_vote := v_vote || jsonb_build_object(
    'clos',       true,
    'statut',     'clos',
    'closLe',     v_now,
    'adopte',     v_adopte,
    'decompte',   jsonb_build_object('oui', v_oui, 'non', v_non, 'abstention', v_abst),
    'closPar',    p_nom
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
      'resultat',     CASE WHEN v_adopte THEN 'ACCEPTÉ' ELSE 'REFUSÉ' END
    )) || COALESCE(v_data->'journal', '[]'::jsonb)
  );

  UPDATE tontines SET data = v_data WHERE code = v_code;

  RAISE NOTICE 'clore_vote_redemarrage OK: % vote=% adopte=%',
    v_code, p_vote_id, v_adopte;

  RETURN jsonb_build_object(
    'ok',         true,
    'adopte',     v_adopte,
    'oui',        v_oui,
    'non',        v_non,
    'abstention', v_abst,
    'total',      v_total
  );
END;
$$;

GRANT EXECUTE ON FUNCTION clore_vote_redemarrage(text, text, text, text) TO anon, authenticated;

DO $$ BEGIN
  RAISE NOTICE 'SECTION 4 — clore_vote_redemarrage : ✅ OK';
END $$;


-- ══════════════════════════════════════════════════════════════════════════════
-- SECTION 5 : RPC demarrer_nouveau_cycle
-- Démarre le nouveau cycle après un vote favorable.
-- Appelée par : SupabaseService.demarrerNouveauCycle(...)
--
-- Paramètres Flutter (supabase_service.dart) :
--   p_code          text     — code tontine (obligatoire)
--   p_nom           text     — nom gestionnaire (obligatoire)
--   p_pin           text     — PIN gestionnaire (obligatoire)
--   p_vote_id       text     — ID du vote accepté (obligatoire)
--   p_montant       integer  — nouveau montant (optionnel, NULL = conserver)
--   p_periodicite   text     — nouvelle périodicité (optionnel, NULL = conserver)
--   p_echeance      text     — 1ère échéance ISO 8601 (optionnel, NULL = calculer auto)
--   p_methode_ordre text     — méthode d'ordre (optionnel, NULL = conserver)
--
-- Retourne : {ok: bool, cycleNum?: int, message?: text, erreur?: text}
-- ══════════════════════════════════════════════════════════════════════════════

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
AS $$
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

  -- 3. Vérifier que le cycle est terminé
  v_cycle_termine := COALESCE((v_data->>'cycleTermine')::boolean, false);
  IF NOT v_cycle_termine THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Le cycle actuel n''est pas encore terminé.');
  END IF;

  -- 4. Vérifier que le vote existe, est clos et adopté
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
    RETURN jsonb_build_object('ok', false, 'erreur', 'Le vote n''est pas encore clôturé.');
  END IF;
  IF NOT COALESCE((v_vote->>'adopte')::boolean, false) THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Le vote n''a pas été accepté.');
  END IF;

  v_now           := to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS".000Z"');
  v_cycle_num     := COALESCE((v_data->>'cycleNum')::int,
                              (v_data->>'cycleNumero')::int, 1);
  v_new_cycle_num := v_cycle_num + 1;

  -- 5. Paramètres du nouveau cycle (NULL → conserver anciens)
  v_montant       := COALESCE(p_montant,       (v_data->>'montant')::int, 5000);
  v_periodicite   := COALESCE(p_periodicite,   v_data->>'periodicite',
                              v_data->>'periode', 'mensuel');
  v_methode_ordre := COALESCE(p_methode_ordre, v_data->>'methodeOrdre', 'rotation');

  -- 6. Archiver le cycle terminé
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

  -- 7. Réinitialiser les membres pour le nouveau cycle
  --    (remettre paye=false, effacer datePaiement, etc.)
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
    'cycleNum',       v_new_cycle_num,
    'cycleNumero',    v_new_cycle_num,
    'cycleTermine',   false,
    'tourActuel',     0,
    'ordre',          '[]'::jsonb,          -- ordre réinitialisé (nouveau tirage requis)
    'paiements',      '{}'::jsonb,
    'historique',     '[]'::jsonb,
    'membres',        v_membres,
    'montant',        v_montant,
    'periodicite',    v_periodicite,
    'periode',        v_periodicite,
    'methodeOrdre',   v_methode_ordre,
    'cyclesArchives', v_archives,
    'votes',          '[]'::jsonb,          -- votes réinitialisés
    'journal',        jsonb_build_array(jsonb_build_object(
      'quoi',         'NOUVEAU_CYCLE_DEMARRE',
      'gestionnaire', p_nom,
      'quand',        v_now,
      'cycleNum',     v_new_cycle_num,
      'voteId',       p_vote_id
    )) || COALESCE(v_data->'journal', '[]'::jsonb)
  );

  -- Ajouter la 1ère échéance si fournie
  IF p_echeance IS NOT NULL THEN
    v_data := v_data || jsonb_build_object('echeance', p_echeance);
  END IF;

  -- 9. Sauvegarder
  UPDATE tontines SET data = v_data WHERE code = v_code;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Échec de la sauvegarde.');
  END IF;

  RAISE NOTICE 'demarrer_nouveau_cycle OK: % cycle %→%',
    v_code, v_cycle_num, v_new_cycle_num;

  RETURN jsonb_build_object(
    'ok',       true,
    'cycleNum', v_new_cycle_num,
    'message',  'Cycle ' || v_new_cycle_num || ' démarré avec succès.'
  );
END;
$$;

GRANT EXECUTE ON FUNCTION demarrer_nouveau_cycle(text,text,text,text,integer,text,text,text)
  TO anon, authenticated;

DO $$ BEGIN
  RAISE NOTICE 'SECTION 5 — demarrer_nouveau_cycle : ✅ OK';
END $$;


-- ══════════════════════════════════════════════════════════════════════════════
-- SECTION 6 : RLS Policies
-- Les tontines sont accessibles via RPC SECURITY DEFINER → pas de RLS direct.
-- On s'assure juste que les fonctions ont les bons droits d'accès.
-- ══════════════════════════════════════════════════════════════════════════════

-- Assurer que anon peut lire les tontines via les RPCs (si RLS activé)
DO $$
BEGIN
  -- Vérifier si RLS est activé sur tontines
  IF EXISTS (
    SELECT 1 FROM pg_tables
    WHERE schemaname = 'public' AND tablename = 'tontines' AND rowsecurity = true
  ) THEN
    RAISE NOTICE 'SECTION 6 — RLS activé sur tontines';
    RAISE NOTICE '  Les RPCs utilisent SECURITY DEFINER → RLS contourné correctement.';
  ELSE
    RAISE NOTICE 'SECTION 6 — RLS désactivé sur tontines (pas de policy nécessaire).';
  END IF;
END $$;


-- ══════════════════════════════════════════════════════════════════════════════
-- SECTION 7 : Vérification post-migration complète
-- ══════════════════════════════════════════════════════════════════════════════

DO $$
DECLARE
  v_vg   boolean;
  v_pnc  boolean;
  v_lec  boolean;
  v_dnc  boolean;
  v_cvr  boolean;
  v_corrupted int;
BEGIN
  SELECT EXISTS(SELECT 1 FROM pg_proc WHERE proname = 'verifier_gestionnaire')
    INTO v_vg;
  SELECT EXISTS(SELECT 1 FROM pg_proc WHERE proname = 'proposer_nouveau_cycle')
    INTO v_pnc;
  SELECT EXISTS(SELECT 1 FROM pg_proc WHERE proname = 'lire_etat_cycle')
    INTO v_lec;
  SELECT EXISTS(SELECT 1 FROM pg_proc WHERE proname = 'demarrer_nouveau_cycle')
    INTO v_dnc;
  SELECT EXISTS(SELECT 1 FROM pg_proc WHERE proname = 'clore_vote_redemarrage')
    INTO v_cvr;

  -- Vérifier s'il reste des données corrompues
  SELECT COUNT(*) INTO v_corrupted
  FROM tontines
  WHERE
    jsonb_array_length(COALESCE(data->'ordre', '[]'::jsonb)) = 0
    AND COALESCE((data->>'cycleTermine')::boolean, false) = true
    AND jsonb_array_length(COALESCE(data->'historique', '[]'::jsonb)) = 0;

  RAISE NOTICE '════════════════════════════════════════════════════';
  RAISE NOTICE 'Migration v15 — Résultat final';
  RAISE NOTICE '════════════════════════════════════════════════════';
  RAISE NOTICE 'Helper verifier_gestionnaire    : %', CASE WHEN v_vg  THEN '✅ OK' ELSE '❌ MANQUANT' END;
  RAISE NOTICE 'RPC proposer_nouveau_cycle      : %', CASE WHEN v_pnc THEN '✅ OK' ELSE '❌ MANQUANT' END;
  RAISE NOTICE 'RPC lire_etat_cycle             : %', CASE WHEN v_lec THEN '✅ OK' ELSE '❌ MANQUANT' END;
  RAISE NOTICE 'RPC demarrer_nouveau_cycle      : %', CASE WHEN v_dnc THEN '✅ OK' ELSE '❌ MANQUANT' END;
  RAISE NOTICE 'RPC clore_vote_redemarrage      : %', CASE WHEN v_cvr THEN '✅ OK' ELSE '❌ MANQUANT' END;
  RAISE NOTICE '────────────────────────────────────────────────────';
  RAISE NOTICE 'Données corrompues restantes    : %', v_corrupted;
  IF v_corrupted > 0 THEN
    RAISE NOTICE '  ⚠️  % tontine(s) encore corrompues — vérifier manuellement.', v_corrupted;
  ELSE
    RAISE NOTICE '  ✅ Aucune donnée corrompue.';
  END IF;
  RAISE NOTICE '════════════════════════════════════════════════════';
  RAISE NOTICE 'TEST SQL POST-MIGRATION (copier-coller dans SQL Editor) :';
  RAISE NOTICE '';
  RAISE NOTICE 'SELECT routine_name FROM information_schema.routines';
  RAISE NOTICE 'WHERE routine_name = ''proposer_nouveau_cycle'';';
  RAISE NOTICE '';
  RAISE NOTICE 'RÉSULTAT ATTENDU : 1 ligne avec "proposer_nouveau_cycle"';
  RAISE NOTICE '════════════════════════════════════════════════════';
END $$;
