-- ============================================================
-- Migration v17 : Correction soft delete + compteurs Admin
-- Idempotent : safe a relancer
-- A executer : Supabase SQL Editor > New query > Run
-- Prerequis  : v16 deja execute (colonnes status, deleted_at, etc.)
-- Delimiteurs nommes $func_XX$ pour eviter l'erreur 42601
-- ============================================================


-- ============================================================
-- SECTION 0 : Verification prerequis (colonnes v16)
-- ============================================================

DO $check_v16$
DECLARE
  v_has_status boolean;
  v_has_deleted_at boolean;
  v_has_invitation_code_active boolean;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'tontines' AND column_name = 'status'
  ) INTO v_has_status;

  SELECT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'tontines' AND column_name = 'deleted_at'
  ) INTO v_has_deleted_at;

  SELECT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'tontines' AND column_name = 'invitation_code_active'
  ) INTO v_has_invitation_code_active;

  IF NOT v_has_status OR NOT v_has_deleted_at OR NOT v_has_invitation_code_active THEN
    RAISE EXCEPTION
      'PREREQUIS MANQUANT : les colonnes v16 (status, deleted_at, invitation_code_active) '
      'sont absentes. Executez supabase-v16-soft-delete.sql AVANT cette migration.';
  END IF;

  RAISE NOTICE 'Migration v17 - SECTION 0 - Prerequis v16 OK';
END;
$check_v16$;


-- ============================================================
-- SECTION 1 : check_invitation_code (v17)
--
-- Verifie STRICTEMENT qu'un code est utilisable :
--   - existe
--   - status = 'active'
--   - deleted_at IS NULL
--   - invitation_code_active = true
--
-- Retourne : {ok: bool, erreur?: text, message?: text, nom?: text}
-- Codes d'erreur : CODE_INTROUVABLE, TONTINE_DELETED,
--                  INVITATION_INACTIVE, TONTINE_SUSPENDED
-- ============================================================

CREATE OR REPLACE FUNCTION check_invitation_code(p_code text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $func_cic$
DECLARE
  v_code text := upper(trim(p_code));
  v_row  tontines%ROWTYPE;
BEGIN
  SELECT * INTO v_row FROM tontines WHERE code = v_code;

  -- 1. Code inexistant
  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'ok',      false,
      'erreur',  'CODE_INTROUVABLE',
      'message', 'Code de tontine invalide ou expire. Verifiez le code puis reessayez.'
    );
  END IF;

  -- 2. Tontine supprimee (priorite absolue)
  --    Bloquer meme si invitation_code_active = true (cohérence defensive)
  IF v_row.status = 'deleted' OR v_row.deleted_at IS NOT NULL THEN
    RETURN jsonb_build_object(
      'ok',      false,
      'erreur',  'TONTINE_DELETED',
      'message', 'Cette tontine a ete supprimee par son gestionnaire. '
                 'Son code d''invitation n''est plus valide.',
      'nom',     COALESCE(v_row.data->>'nom', v_code)
    );
  END IF;

  -- 3. Code invitation desactive explicitement
  IF NOT v_row.invitation_code_active THEN
    RETURN jsonb_build_object(
      'ok',      false,
      'erreur',  'INVITATION_INACTIVE',
      'message', 'Le code d''invitation de cette tontine n''est plus actif. '
                 'Contactez le gestionnaire.',
      'nom',     COALESCE(v_row.data->>'nom', v_code)
    );
  END IF;

  -- 4. Tontine suspendue
  IF v_row.status = 'suspended' THEN
    RETURN jsonb_build_object(
      'ok',      false,
      'erreur',  'TONTINE_SUSPENDED',
      'message', 'Cette tontine est actuellement suspendue.',
      'nom',     COALESCE(v_row.data->>'nom', v_code)
    );
  END IF;

  -- 5. Tontine inactive
  IF v_row.status = 'inactive' THEN
    RETURN jsonb_build_object(
      'ok',      false,
      'erreur',  'TONTINE_INACTIVE',
      'message', 'Cette tontine n''est plus active.',
      'nom',     COALESCE(v_row.data->>'nom', v_code)
    );
  END IF;

  -- 6. OK : tontine active et code valide
  RETURN jsonb_build_object(
    'ok',  true,
    'nom', COALESCE(v_row.data->>'nom', v_code)
  );
END;
$func_cic$;

GRANT EXECUTE ON FUNCTION check_invitation_code(text) TO anon, authenticated;

DO $report1$
BEGIN
  RAISE NOTICE 'Migration v17 - SECTION 1 - check_invitation_code (v17) cree/remplace';
END;
$report1$;


-- ============================================================
-- SECTION 2 : join_tontine_by_code
--
-- RPC securisee pour "rejoindre une tontine".
-- Effectue TOUTES les verifications avant de retourner les donnees.
-- Ne retourne JAMAIS les donnees d'une tontine supprimee.
--
-- Retourne : {ok: bool, data?: jsonb, erreur?: text, message?: text}
-- ============================================================

CREATE OR REPLACE FUNCTION join_tontine_by_code(p_code text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $func_jtbc$
DECLARE
  v_code   text := upper(trim(p_code));
  v_check  jsonb;
  v_row    tontines%ROWTYPE;
BEGIN
  -- Reutiliser check_invitation_code pour la validation
  v_check := check_invitation_code(v_code);

  IF (v_check->>'ok')::boolean = false THEN
    RETURN v_check; -- Propager l'erreur (TONTINE_DELETED, etc.)
  END IF;

  -- Tontine valide : lire la ligne complete
  SELECT * INTO v_row FROM tontines WHERE code = v_code;

  -- Double verification defensive (ne devrait jamais arriver)
  IF NOT FOUND OR v_row.status = 'deleted' OR v_row.deleted_at IS NOT NULL THEN
    RETURN jsonb_build_object(
      'ok',     false,
      'erreur', 'TONTINE_DELETED',
      'message','Cette tontine n''est pas accessible.'
    );
  END IF;

  -- Retourner les donnees de la tontine (sans les champs sensibles)
  RETURN jsonb_build_object(
    'ok',   true,
    'code', v_code,
    'nom',  COALESCE(v_row.data->>'nom', v_code),
    'data', v_row.data
  );
END;
$func_jtbc$;

GRANT EXECUTE ON FUNCTION join_tontine_by_code(text) TO anon, authenticated;

DO $report2$
BEGIN
  RAISE NOTICE 'Migration v17 - SECTION 2 - join_tontine_by_code cree';
END;
$report2$;


-- ============================================================
-- SECTION 3 : admin_tontine_counts (source unique de verite)
--
-- Calcule TOUS les compteurs depuis une seule requete SQL.
-- Utilise la meme logique de categorisation que Flutter.
-- Evite les incoherences entre badge, filtres et liste.
--
-- Retourne un objet JSON avec :
--   total, actives, premium, gratuites, inactives,
--   suspendues, expirees, supprimees, demandes_en_attente
-- ============================================================

CREATE OR REPLACE FUNCTION admin_tontine_counts(p_cle text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $func_atc$
DECLARE
  v_admin_key text := 'TONTINE_ADMIN_2024';
  v_counts    jsonb;
  v_demandes  int := 0;
BEGIN
  -- Verifier la cle admin
  IF p_cle != v_admin_key THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Cle admin incorrecte.');
  END IF;

  -- Compteurs par categorie (logique identique a Flutter _categorie())
  WITH cats AS (
    SELECT
      code,
      CASE
        WHEN status = 'deleted' OR deleted_at IS NOT NULL THEN 'deleted'
        WHEN status = 'suspended'                          THEN 'suspended'
        WHEN status = 'inactive'                           THEN 'inactive'
        -- Premium expire = premium dont plan_expire < now()
        WHEN plan = 'premium'
             AND data->>'planExpire' IS NOT NULL
             AND (data->>'planExpire')::timestamptz < now() THEN 'expire'
        WHEN plan = 'premium' THEN 'premium'
        ELSE 'gratuit'
      END AS cat
    FROM tontines
  )
  SELECT jsonb_build_object(
    'total',      COUNT(*) FILTER (WHERE cat != 'deleted'),
    'actives',    COUNT(*) FILTER (WHERE cat IN ('gratuit','premium')),
    'premium',    COUNT(*) FILTER (WHERE cat = 'premium'),
    'gratuites',  COUNT(*) FILTER (WHERE cat = 'gratuit'),
    'inactives',  COUNT(*) FILTER (WHERE cat = 'inactive'),
    'suspendues', COUNT(*) FILTER (WHERE cat = 'suspended'),
    'expirees',   COUNT(*) FILTER (WHERE cat = 'expire'),
    'supprimees', COUNT(*) FILTER (WHERE cat = 'deleted')
  )
  INTO v_counts
  FROM cats;

  -- Demandes Premium en attente (table premium_requests si existe)
  BEGIN
    SELECT COUNT(*) INTO v_demandes
    FROM premium_requests
    WHERE statut IN ('en_attente', 'en attente', 'pending');
  EXCEPTION WHEN undefined_table THEN
    v_demandes := 0;
  END;

  RETURN v_counts || jsonb_build_object(
    'ok',                  true,
    'demandes_en_attente', v_demandes
  );
END;
$func_atc$;

GRANT EXECUTE ON FUNCTION admin_tontine_counts(text) TO anon, authenticated;

DO $report3$
BEGIN
  RAISE NOTICE 'Migration v17 - SECTION 3 - admin_tontine_counts cree';
END;
$report3$;


-- ============================================================
-- SECTION 4 : Mise a jour admin_lister_tontines (v17)
--
-- Ajoute les champs manquants pour la carte Admin :
--   nom, code, gestionnaire/president, nb_membres,
--   status, deleted_at, deleted_by, deletion_reason,
--   plan, plan_expire (depuis data JSONB), cree
-- ============================================================

CREATE OR REPLACE FUNCTION admin_lister_tontines(p_cle text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $func_alt$
DECLARE
  v_admin_key text := 'TONTINE_ADMIN_2024';
  v_result    jsonb;
BEGIN
  IF p_cle != v_admin_key THEN
    RETURN '[]'::jsonb;
  END IF;

  SELECT jsonb_agg(
    jsonb_build_object(
      -- Identification
      'code',             t.code,
      'nom',              COALESCE(
                            NULLIF(trim(t.data->>'nom'), ''),
                            'Tontine sans nom'
                          ),
      -- Gestionnaire : essayer plusieurs champs du JSONB
      'president',        COALESCE(
                            t.data->'gestionnaire'->>'nom',
                            t.data->>'gestionnaire',
                            t.data->>'president',
                            t.data->>'created_by',
                            t.data->>'owner'
                          ),
      -- Membres (jsonb array)
      'membres',          COALESCE(
                            jsonb_array_length(t.data->'membres'),
                            0
                          ),
      -- Plan
      'plan',             COALESCE(t.plan, 'free'),
      'plan_expire',      t.data->>'planExpire',
      -- Dates
      'cree',             to_char(t.created_at, 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
      -- Soft delete
      'status',           COALESCE(t.status, 'active'),
      'deleted_at',       CASE WHEN t.deleted_at IS NOT NULL
                               THEN to_char(t.deleted_at, 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
                               ELSE NULL END,
      'deleted_by',       t.deleted_by,
      'deletion_reason',  t.deletion_reason,
      'invitation_active', t.invitation_code_active
    )
    ORDER BY
      CASE WHEN COALESCE(t.status,'active') = 'deleted' THEN 1 ELSE 0 END ASC,
      t.created_at DESC
  )
  INTO v_result
  FROM tontines t;

  RETURN COALESCE(v_result, '[]'::jsonb);
END;
$func_alt$;

GRANT EXECUTE ON FUNCTION admin_lister_tontines(text) TO anon, authenticated;

DO $report4$
BEGIN
  RAISE NOTICE 'Migration v17 - SECTION 4 - admin_lister_tontines (v17) mis a jour';
END;
$report4$;


-- ============================================================
-- SECTION 5 : Triggeriser updated_at automatiquement
-- ============================================================

CREATE OR REPLACE FUNCTION tontines_set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $func_sua$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$func_sua$;

DROP TRIGGER IF EXISTS trg_tontines_updated_at ON tontines;

CREATE TRIGGER trg_tontines_updated_at
  BEFORE UPDATE ON tontines
  FOR EACH ROW
  EXECUTE FUNCTION tontines_set_updated_at();

DO $report5$
BEGIN
  RAISE NOTICE 'Migration v17 - SECTION 5 - trigger updated_at cree';
END;
$report5$;


-- ============================================================
-- SECTION 6 : Verification finale
-- ============================================================

DO $verify17$
DECLARE
  v_check_cic  boolean;
  v_check_jtbc boolean;
  v_check_atc  boolean;
  v_check_alt  boolean;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM pg_proc WHERE proname = 'check_invitation_code'
  ) INTO v_check_cic;

  SELECT EXISTS (
    SELECT 1 FROM pg_proc WHERE proname = 'join_tontine_by_code'
  ) INTO v_check_jtbc;

  SELECT EXISTS (
    SELECT 1 FROM pg_proc WHERE proname = 'admin_tontine_counts'
  ) INTO v_check_atc;

  SELECT EXISTS (
    SELECT 1 FROM pg_proc WHERE proname = 'admin_lister_tontines'
  ) INTO v_check_alt;

  RAISE NOTICE '=== MIGRATION v17 TERMINEE ===';
  RAISE NOTICE 'check_invitation_code  : %', CASE WHEN v_check_cic  THEN 'OK' ELSE 'MANQUANT' END;
  RAISE NOTICE 'join_tontine_by_code   : %', CASE WHEN v_check_jtbc THEN 'OK' ELSE 'MANQUANT' END;
  RAISE NOTICE 'admin_tontine_counts   : %', CASE WHEN v_check_atc  THEN 'OK' ELSE 'MANQUANT' END;
  RAISE NOTICE 'admin_lister_tontines  : %', CASE WHEN v_check_alt  THEN 'OK' ELSE 'MANQUANT' END;

  IF NOT (v_check_cic AND v_check_jtbc AND v_check_atc AND v_check_alt) THEN
    RAISE EXCEPTION 'Migration v17 INCOMPLETE — verifiez les erreurs ci-dessus.';
  END IF;

  RAISE NOTICE 'migration_v17_ok: true';
END;
$verify17$;
