-- =============================================================================
-- TontineClair — Migration 006 : RPCs Tontines (fonctions de base)
-- Ordre d'exécution : 6/10
-- Remplace (version finale de) : supabase-fix-v7.sql, supabase-fix-v8-periodicitee.sql,
--   supabase-fix-v9-nouveau-cycle.sql, supabase-fix-v10-cycle-logique.sql,
--   supabase-fix-v11-beneficiaire.sql, supabase-fix-v15-nouveau-cycle.sql,
--   supabase-fix-v18-voter-choix-minuscules.sql, supabase-v16-soft-delete.sql,
--   supabase-v17-fix-soft-delete.sql (sections tontines)
-- Note : chaque fonction ici est la version la plus récente appliquée.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- Helper interne
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION _tc_nom_membre(p_data jsonb, p_id text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT COALESCE(
    (SELECT m->>'nom' FROM jsonb_array_elements(p_data->'membres') m
     WHERE m->>'id' = p_id LIMIT 1),
    p_id
  );
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- lire_tontine — v16 (avec soft-delete)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION lire_tontine(p_code text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_code text := upper(trim(p_code));
  v_row  tontines%ROWTYPE;
BEGIN
  SELECT * INTO v_row FROM tontines WHERE code = v_code;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Tontine introuvable');
  END IF;
  IF v_row.status = 'deleted' OR v_row.deleted_at IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'TONTINE_DELETED',
      'message', 'Cette tontine a été supprimée.');
  END IF;
  RETURN jsonb_build_object('ok', true, 'data', v_row.data, 'code', v_code,
    'status', v_row.status, 'updated_at', v_row.updated_at);
END; $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- ecrire_tontine_sans_pin — écriture directe sans vérification PIN
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION ecrire_tontine_sans_pin(p_code text, p_data jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  UPDATE tontines SET data = p_data WHERE code = upper(trim(p_code));
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Code introuvable');
  END IF;
  RETURN jsonb_build_object('ok', true);
END; $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- verifier_gestionnaire — v15
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION verifier_gestionnaire(p_code text, p_nom text, p_pin text)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  RETURN EXISTS (
    SELECT 1 FROM tontines
    WHERE code = upper(trim(p_code))
      AND status != 'deleted'
      AND deleted_at IS NULL
      AND (
        gestionnaires @> jsonb_build_array(jsonb_build_object('nom', p_nom, 'pin', p_pin))
        OR data @> jsonb_build_object('gestionnaires',
              jsonb_build_array(jsonb_build_object('nom', p_nom, 'pin', p_pin)))
      )
  );
END; $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- check_invitation_code — v17 (version finale)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION check_invitation_code(p_code text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_code text := upper(trim(p_code));
  v_row  tontines%ROWTYPE;
BEGIN
  SELECT * INTO v_row FROM tontines WHERE code = v_code;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'CODE_INTROUVABLE',
      'message', 'Code de tontine invalide ou expiré.');
  END IF;
  IF v_row.status = 'deleted' OR v_row.deleted_at IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'TONTINE_DELETED',
      'message', 'Cette tontine a été supprimée. Son code d''invitation n''est plus valide.',
      'nom', COALESCE(v_row.data->>'nom', v_code));
  END IF;
  IF NOT COALESCE(v_row.invitation_code_active, true) THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'INVITATION_INACTIVE',
      'message', 'Le code d''invitation de cette tontine n''est plus actif.',
      'nom', COALESCE(v_row.data->>'nom', v_code));
  END IF;
  IF v_row.status = 'suspended' THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'TONTINE_SUSPENDED',
      'message', 'Cette tontine est suspendue.',
      'nom', COALESCE(v_row.data->>'nom', v_code));
  END IF;
  RETURN jsonb_build_object('ok', true, 'nom', COALESCE(v_row.data->>'nom', v_code));
END; $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- join_tontine_by_code — v17
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION join_tontine_by_code(p_code text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_code  text := upper(trim(p_code));
  v_check jsonb;
  v_row   tontines%ROWTYPE;
BEGIN
  v_check := check_invitation_code(v_code);
  IF (v_check->>'ok')::boolean = false THEN RETURN v_check; END IF;
  SELECT * INTO v_row FROM tontines WHERE code = v_code;
  IF NOT FOUND OR v_row.status = 'deleted' THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'TONTINE_DELETED');
  END IF;
  RETURN jsonb_build_object('ok', true, 'code', v_code,
    'nom', COALESCE(v_row.data->>'nom', v_code), 'data', v_row.data);
END; $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- delete_tontine — v16 (soft-delete)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION delete_tontine(p_code text, p_nom text, p_pin text, p_motif text DEFAULT '')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_code text := upper(trim(p_code));
  v_ok   boolean;
BEGIN
  v_ok := verifier_gestionnaire(v_code, p_nom, p_pin);
  IF NOT v_ok THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'PIN incorrect ou non-gestionnaire');
  END IF;
  UPDATE tontines
  SET status = 'deleted', deleted_at = NOW(), deleted_by = p_nom,
      deletion_reason = p_motif, invitation_code_active = false
  WHERE code = v_code;
  RETURN jsonb_build_object('ok', true);
END; $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- restore_deleted_tontine — v16
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION restore_deleted_tontine(
  p_cle text, p_code text, p_motif text DEFAULT ''
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_admin_key text := 'TONTINE_ADMIN_2024';
  v_new_code  text;
BEGIN
  IF p_cle != v_admin_key THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Clé admin invalide');
  END IF;
  v_new_code := upper(substr(md5(random()::text), 1, 6));
  UPDATE tontines
  SET status = 'active', deleted_at = NULL, deleted_by = NULL,
      deletion_reason = NULL, invitation_code_active = true,
      code = v_new_code
  WHERE code = upper(trim(p_code)) AND status = 'deleted';
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Tontine non trouvée ou non supprimée');
  END IF;
  RETURN jsonb_build_object('ok', true, 'nouveau_code', v_new_code);
END; $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- maj_echeance — v8
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION maj_echeance(p_code text, p_nom text, p_pin text, p_echeance text)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF NOT verifier_gestionnaire(p_code, p_nom, p_pin) THEN RETURN false; END IF;
  UPDATE tontines
  SET data = jsonb_set(data, '{echeance}', to_jsonb(p_echeance))
  WHERE code = upper(trim(p_code));
  RETURN FOUND;
END; $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- lire_config_tontine — v8
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION lire_config_tontine(p_code text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_data jsonb;
BEGIN
  SELECT data INTO v_data FROM tontines WHERE code = upper(trim(p_code));
  IF NOT FOUND THEN RETURN NULL; END IF;
  RETURN jsonb_build_object(
    'montant',      v_data->>'montant',
    'periodicite',  v_data->>'periodicite',
    'echeance',     v_data->>'echeance',
    'nbMembresMax', v_data->>'nbMembresMax',
    'devise',       COALESCE(v_data->>'devise', 'XOF')
  );
END; $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- voter — v18 (choix minuscules)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION voter(
  p_code    text, p_vote_id text, p_membre_id text,
  p_nom     text, p_choix   text
) RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_choix text := lower(trim(p_choix));
  v_row   tontines%ROWTYPE;
  v_data  jsonb; v_votes jsonb; v_vote jsonb; v_voix jsonb; v_idx int;
BEGIN
  IF v_choix NOT IN ('pour','contre','abstention') THEN RETURN false; END IF;
  SELECT * INTO v_row FROM tontines WHERE code = upper(trim(p_code));
  IF NOT FOUND THEN RETURN false; END IF;
  v_data  := v_row.data;
  v_votes := COALESCE(v_data->'votes', '[]'::jsonb);
  -- Trouver le vote
  FOR v_idx IN 0..jsonb_array_length(v_votes)-1 LOOP
    IF v_votes->v_idx->>'id' = p_vote_id THEN
      v_vote := v_votes->v_idx;
      v_voix := COALESCE(v_vote->'voix', '[]'::jsonb);
      -- Retirer vote existant du membre
      v_voix := (SELECT jsonb_agg(x) FROM jsonb_array_elements(v_voix) x
                 WHERE x->>'membreId' != p_membre_id);
      v_voix := COALESCE(v_voix, '[]'::jsonb);
      -- Ajouter nouveau vote
      v_voix := v_voix || jsonb_build_array(
        jsonb_build_object('membreId', p_membre_id, 'nom', p_nom, 'choix', v_choix,
                           'quand', now()::text));
      v_vote := jsonb_set(v_vote, '{voix}', v_voix);
      v_votes := jsonb_set(v_votes, ARRAY[v_idx::text], v_vote);
      UPDATE tontines SET data = jsonb_set(v_data, '{votes}', v_votes)
      WHERE code = v_row.code;
      RETURN true;
    END IF;
  END LOOP;
  RETURN false;
END; $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- cloturer_tour — v11 (version finale avec anti-doublon + beneficiaireNom)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION cloturer_tour(p_code text, p_pin text, p_gest text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_row         tontines%ROWTYPE;
  v_data        jsonb;
  v_ordre       jsonb; v_membres jsonb;
  v_tour_actuel int;  v_nb_tours int;
  v_benef_id    text; v_benef_nom text;
  v_paiements   jsonb; v_historique jsonb;
  v_nb_payes    int;  v_total_recu int;
  v_montant     int;  v_est_dernier boolean;
  v_new_tour    int;  v_payes_ids jsonb;
  v_ref         text; v_now text;
  v_gestionnaire text; v_doublons boolean;
BEGIN
  SELECT * INTO v_row FROM tontines WHERE code = p_code;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'erreur', 'Tontine introuvable'); END IF;

  v_data        := v_row.data;
  v_ordre       := COALESCE(v_data->'ordre', '[]'::jsonb);
  v_membres     := COALESCE(v_data->'membres', '[]'::jsonb);
  v_tour_actuel := COALESCE((v_data->>'tourActuel')::int, 0);
  v_nb_tours    := jsonb_array_length(v_ordre);
  v_montant     := COALESCE((v_data->>'montant')::int, 0);
  v_paiements   := COALESCE(v_data->'paiements', '{}'::jsonb);
  v_historique  := COALESCE(v_data->'historique', '[]'::jsonb);
  v_now         := now()::text;
  v_ref         := upper(substring(md5(random()::text) FROM 1 FOR 8));
  v_gestionnaire := COALESCE(p_gest, 'gestionnaire');

  IF (v_data->>'cycleTermine')::boolean = true THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Le cycle est déjà terminé'); END IF;
  IF v_nb_tours = 0 THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Aucun ordre de passage défini'); END IF;
  IF v_tour_actuel >= v_nb_tours THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Tous les tours ont été clôturés'); END IF;

  v_benef_id  := v_ordre->>v_tour_actuel;
  v_benef_nom := _tc_nom_membre(v_data, v_benef_id);

  -- Anti-doublon
  SELECT EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_historique) h
    WHERE (h->>'beneficiaireId') = v_benef_id OR (h->>'beneficiaire') = v_benef_nom
  ) INTO v_doublons;
  IF v_doublons THEN
    RETURN jsonb_build_object('ok', false, 'erreur',
      'Ce membre a déjà été servi dans ce cycle'); END IF;

  -- Compter paiements reçus
  SELECT COUNT(*), COALESCE(SUM((v_paiements->m->>'montant')::int), 0),
         jsonb_agg(m)
  INTO v_nb_payes, v_total_recu, v_payes_ids
  FROM jsonb_object_keys(v_paiements) m
  WHERE (v_paiements->m->>'statut') IN ('payé','paye','confirmed','completed');

  v_new_tour    := v_tour_actuel + 1;
  v_est_dernier := v_new_tour >= v_nb_tours;

  -- Ajouter entrée historique
  v_historique := v_historique || jsonb_build_array(jsonb_build_object(
    'ref', v_ref, 'tour', v_tour_actuel, 'beneficiaire', v_benef_nom,
    'beneficiaireId', v_benef_id, 'montantDistribue', v_total_recu,
    'nbPayants', v_nb_payes, 'date', v_now, 'gestionnaire', v_gestionnaire));

  -- Mettre à jour tontine
  UPDATE tontines SET data = v_data
    || jsonb_build_object('tourActuel',   v_new_tour)
    || jsonb_build_object('cycleTermine', v_est_dernier)
    || jsonb_build_object('historique',   v_historique)
    || jsonb_build_object('paiements',    '{}'::jsonb)
  WHERE code = v_row.code;

  RETURN jsonb_build_object('ok', true, 'beneficiaire', v_benef_nom,
    'beneficiaireId', v_benef_id, 'montant', v_total_recu,
    'cycleTermine', v_est_dernier, 'nouveauTour', v_new_tour);
END; $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- proposer_nouveau_cycle / lire_etat_cycle / clore_vote_redemarrage /
-- demarrer_nouveau_cycle — v15 (version finale)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION proposer_nouveau_cycle(
  p_code text, p_nom text, p_pin text, p_vote_id text
) RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF NOT verifier_gestionnaire(p_code, p_nom, p_pin) THEN RETURN false; END IF;
  UPDATE tontines SET data = jsonb_set(
    jsonb_set(data, '{cycleTermine}', 'true'),
    '{voteRedemarrage}',
    jsonb_build_object('voteId', p_vote_id, 'propose_par', p_nom,
                       'quand', now()::text, 'statut', 'en_attente')
  ) WHERE code = upper(trim(p_code));
  RETURN FOUND;
END; $$;

CREATE OR REPLACE FUNCTION lire_etat_cycle(p_code text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_data jsonb;
BEGIN
  SELECT data INTO v_data FROM tontines WHERE code = upper(trim(p_code));
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false); END IF;
  RETURN jsonb_build_object(
    'ok', true,
    'cycleTermine',    COALESCE((v_data->>'cycleTermine')::boolean, false),
    'tourActuel',      COALESCE((v_data->>'tourActuel')::int, 0),
    'voteRedemarrage', v_data->'voteRedemarrage',
    'historique',      COALESCE(v_data->'historique', '[]'::jsonb)
  );
END; $$;

CREATE OR REPLACE FUNCTION clore_vote_redemarrage(
  p_code text, p_nom text, p_pin text, p_statut text
) RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF NOT verifier_gestionnaire(p_code, p_nom, p_pin) THEN RETURN false; END IF;
  UPDATE tontines SET data = jsonb_set(
    data, '{voteRedemarrage}',
    COALESCE(data->'voteRedemarrage', '{}'::jsonb)
    || jsonb_build_object('statut', p_statut, 'clos_le', now()::text)
  ) WHERE code = upper(trim(p_code));
  RETURN FOUND;
END; $$;

CREATE OR REPLACE FUNCTION demarrer_nouveau_cycle(p_code text, p_nom text, p_pin text)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_data jsonb; v_membres jsonb; v_ordre jsonb; v_ids jsonb; v_i int;
BEGIN
  IF NOT verifier_gestionnaire(p_code, p_nom, p_pin) THEN RETURN false; END IF;
  SELECT data INTO v_data FROM tontines WHERE code = upper(trim(p_code));
  v_membres := COALESCE(v_data->'membres', '[]'::jsonb);
  v_ids     := '[]'::jsonb;
  FOR v_i IN 0..jsonb_array_length(v_membres)-1 LOOP
    v_ids := v_ids || jsonb_build_array(v_membres->v_i->>'id');
  END LOOP;
  UPDATE tontines SET data = v_data
    || jsonb_build_object('cycleTermine', false)
    || jsonb_build_object('tourActuel', 0)
    || jsonb_build_object('ordre', v_ids)
    || jsonb_build_object('paiements', '{}'::jsonb)
    || jsonb_build_object('voteRedemarrage', NULL)
  WHERE code = upper(trim(p_code));
  RETURN FOUND;
END; $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- demander_premium — v12 (version finale)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION demander_premium(
  p_code text, p_nom text, p_pin text,
  p_contact text DEFAULT NULL, p_formule text DEFAULT 'mensuel'
) RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_code text := upper(trim(p_code));
BEGIN
  INSERT INTO demandes_premium (code, gestionnaire, nom, contact, formule, statut, quand)
  VALUES (v_code, p_nom, p_nom, p_contact, p_formule, 'en attente', NOW())
  ON CONFLICT (code) DO UPDATE
    SET gestionnaire = EXCLUDED.gestionnaire, nom = EXCLUDED.nom,
        contact = EXCLUDED.contact, formule = EXCLUDED.formule,
        statut = 'en attente', quand = NOW();
  RETURN true;
EXCEPTION WHEN OTHERS THEN RETURN false;
END; $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- Permissions
-- ─────────────────────────────────────────────────────────────────────────────
GRANT EXECUTE ON FUNCTION lire_tontine(text)                              TO anon;
GRANT EXECUTE ON FUNCTION ecrire_tontine_sans_pin(text, jsonb)            TO anon;
GRANT EXECUTE ON FUNCTION verifier_gestionnaire(text, text, text)         TO anon;
GRANT EXECUTE ON FUNCTION check_invitation_code(text)                     TO anon;
GRANT EXECUTE ON FUNCTION join_tontine_by_code(text)                      TO anon;
GRANT EXECUTE ON FUNCTION delete_tontine(text, text, text, text)          TO anon;
GRANT EXECUTE ON FUNCTION restore_deleted_tontine(text, text, text)       TO anon;
GRANT EXECUTE ON FUNCTION maj_echeance(text, text, text, text)            TO anon;
GRANT EXECUTE ON FUNCTION lire_config_tontine(text)                       TO anon;
GRANT EXECUTE ON FUNCTION voter(text, text, text, text, text)             TO anon;
GRANT EXECUTE ON FUNCTION cloturer_tour(text, text, text)                 TO anon;
GRANT EXECUTE ON FUNCTION proposer_nouveau_cycle(text, text, text, text)  TO anon;
GRANT EXECUTE ON FUNCTION lire_etat_cycle(text)                           TO anon;
GRANT EXECUTE ON FUNCTION clore_vote_redemarrage(text, text, text, text)  TO anon;
GRANT EXECUTE ON FUNCTION demarrer_nouveau_cycle(text, text, text)        TO anon;
GRANT EXECUTE ON FUNCTION demander_premium(text, text, text, text, text)  TO anon;
