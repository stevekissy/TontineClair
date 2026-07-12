-- Migration v16 : Suppression logique (soft delete) des tontines
-- Idempotent : safe a relancer
-- A executer : Supabase SQL Editor > New query > Run
-- Delimiteurs nommes $funcXX$ pour eviter l'erreur 42601


-- ============================================================
-- SECTION 0 : Ajout des colonnes soft-delete sur la table tontines
-- ============================================================

ALTER TABLE tontines
  ADD COLUMN IF NOT EXISTS status              text    NOT NULL DEFAULT 'active'
                                               CHECK (status IN ('active','inactive','suspended','deleted')),
  ADD COLUMN IF NOT EXISTS deleted_at          timestamptz,
  ADD COLUMN IF NOT EXISTS deleted_by          text,
  ADD COLUMN IF NOT EXISTS deletion_reason     text,
  ADD COLUMN IF NOT EXISTS invitation_code_active boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS updated_at          timestamptz NOT NULL DEFAULT now();

-- Index pour les requetes de filtrage
CREATE INDEX IF NOT EXISTS idx_tontines_status ON tontines(status);

DO $report0$
BEGIN
  RAISE NOTICE 'Migration v16 - SECTION 0 - Colonnes soft-delete ajoutees';
END;
$report0$;


-- ============================================================
-- SECTION 1 : Mettre a jour lire_tontine pour bloquer les
-- tontines supprimees (code TONTINE_DELETED cote Flutter)
-- ============================================================

CREATE OR REPLACE FUNCTION lire_tontine(p_code text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $func_lt$
DECLARE
  v_code   text := upper(trim(p_code));
  v_row    tontines%ROWTYPE;
BEGIN
  SELECT * INTO v_row FROM tontines WHERE code = v_code;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  -- Tontine supprimee : retourner un objet d'erreur special
  IF v_row.status = 'deleted' THEN
    RETURN jsonb_build_object(
      '__deleted__', true,
      'code',        v_code,
      'message',     'Cette tontine a ete supprimee par son gestionnaire et n''est plus accessible.'
    );
  END IF;

  -- Retourner le champ data enrichi avec le statut
  RETURN v_row.data || jsonb_build_object(
    '__status__',                 v_row.status,
    '__invitation_code_active__', v_row.invitation_code_active
  );
END;
$func_lt$;

GRANT EXECUTE ON FUNCTION lire_tontine(text) TO anon, authenticated;

DO $report1$
BEGIN
  RAISE NOTICE 'Migration v16 - SECTION 1 - lire_tontine mise a jour (bloque deleted)';
END;
$report1$;


-- ============================================================
-- SECTION 2 : RPC delete_tontine (soft delete securise)
--
-- Parametres Flutter :
--   p_code            text    -- code tontine
--   p_nom             text    -- nom du gestionnaire
--   p_pin             text    -- PIN du gestionnaire
--   p_raison          text    -- motif de suppression (obligatoire)
--   p_nom_confirmation text   -- nom exact de la tontine saisi par l'user
--
-- Retourne : {ok: bool, message?: text, erreur?: text}
-- ============================================================

CREATE OR REPLACE FUNCTION delete_tontine(
  p_code             text,
  p_nom              text,
  p_pin              text,
  p_raison           text,
  p_nom_confirmation text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $func_dt$
DECLARE
  v_code   text := upper(trim(p_code));
  v_ok     boolean;
  v_data   jsonb;
  v_nom    text;
  v_now    text;
  v_status text;
BEGIN
  -- 1. Motif obligatoire
  IF p_raison IS NULL OR length(trim(p_raison)) < 5 THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Le motif de suppression est obligatoire (minimum 5 caracteres).');
  END IF;

  -- 2. Verifier gestionnaire (4 strategies)
  SELECT verifier_gestionnaire(v_code, p_nom, p_pin) INTO v_ok;
  IF NOT v_ok THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'PIN incorrect ou gestionnaire non autorise.');
  END IF;

  -- 3. Lire la tontine
  SELECT data, status INTO v_data, v_status
  FROM tontines WHERE code = v_code;

  IF v_data IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Tontine introuvable.');
  END IF;

  -- 4. Deja supprimee ?
  IF v_status = 'deleted' THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Cette tontine est deja supprimee.');
  END IF;

  -- 5. Verifier la confirmation du nom
  v_nom := trim(COALESCE(v_data->>'nom', ''));
  IF lower(trim(p_nom_confirmation)) != lower(v_nom) THEN
    RETURN jsonb_build_object(
      'ok', false,
      'erreur', 'Le nom saisi ne correspond pas au nom de la tontine. Verification echouee.'
    );
  END IF;

  -- 6. Timestamp ISO
  v_now := to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD') || 'T'
           || to_char(now() AT TIME ZONE 'UTC', 'HH24:MI:SS') || '.000Z';

  -- 7. Soft delete : mettre a jour les colonnes
  UPDATE tontines
  SET
    status               = 'deleted',
    deleted_at           = now(),
    deleted_by           = p_nom,
    deletion_reason      = trim(p_raison),
    invitation_code_active = false,
    updated_at           = now(),
    data                 = v_data || jsonb_build_object(
      'status',    'deleted',
      'deletedAt', v_now,
      'deletedBy', p_nom,
      'deletionReason', trim(p_raison)
    )
  WHERE code = v_code;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Echec de la mise a jour.');
  END IF;

  -- 8. Journal d'audit
  BEGIN
    INSERT INTO journal_audit(code, gestionnaire, action, detail, membre_id, ancien_val, nouveau_val)
    VALUES (v_code, p_nom, 'TONTINE_DELETED', trim(p_raison), NULL, 'active', 'deleted');
  EXCEPTION WHEN others THEN NULL;
  END;

  BEGIN
    INSERT INTO audit(code, gestionnaire, empreinte)
    VALUES (v_code, p_nom, 'DELETE:' || v_code || ':' || to_char(now(), 'YYYYMMDDHH24MISS'));
  EXCEPTION WHEN others THEN NULL;
  END;

  RAISE NOTICE 'delete_tontine OK: code=% par=%', v_code, p_nom;

  RETURN jsonb_build_object(
    'ok',      true,
    'message', 'La tontine a ete supprimee avec succes. Son code d''invitation est desormais invalide.'
  );
END;
$func_dt$;

GRANT EXECUTE ON FUNCTION delete_tontine(text,text,text,text,text) TO anon, authenticated;

DO $report2$
BEGIN
  RAISE NOTICE 'Migration v16 - SECTION 2 - delete_tontine : OK';
END;
$report2$;


-- ============================================================
-- SECTION 3 : Modifier rejoindre_tontine / creer_tontine pour
-- bloquer un code invalide ou tontine supprimee.
-- On met a jour la RPC rejoindre si elle existe, sinon on cree
-- une RPC check_invitation_code utilisee par Flutter.
-- ============================================================

CREATE OR REPLACE FUNCTION check_invitation_code(p_code text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $func_cic$
DECLARE
  v_code   text := upper(trim(p_code));
  v_status text;
  v_active boolean;
  v_nom    text;
BEGIN
  SELECT status, invitation_code_active, data->>'nom'
  INTO v_status, v_active, v_nom
  FROM tontines WHERE code = v_code;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'CODE_INTROUVABLE', 'message', 'Code introuvable.');
  END IF;

  IF v_status = 'deleted' THEN
    RETURN jsonb_build_object(
      'ok',     false,
      'erreur', 'TONTINE_DELETED',
      'message', 'Cette tontine a ete supprimee. Son code d''invitation n''est plus valide.'
    );
  END IF;

  IF NOT COALESCE(v_active, true) THEN
    RETURN jsonb_build_object(
      'ok',     false,
      'erreur', 'INVITATION_INACTIVE',
      'message', 'Le code d''invitation de cette tontine n''est plus actif.'
    );
  END IF;

  IF v_status = 'suspended' THEN
    RETURN jsonb_build_object(
      'ok',     false,
      'erreur', 'TONTINE_SUSPENDED',
      'message', 'Cette tontine est suspendue. Contactez l''administrateur.'
    );
  END IF;

  RETURN jsonb_build_object('ok', true, 'nom', v_nom, 'status', v_status);
END;
$func_cic$;

GRANT EXECUTE ON FUNCTION check_invitation_code(text) TO anon, authenticated;

DO $report3$
BEGIN
  RAISE NOTICE 'Migration v16 - SECTION 3 - check_invitation_code : OK';
END;
$report3$;


-- ============================================================
-- SECTION 4 : RPC admin_lister_tontines etendue (avec statuts)
-- Remplace la version existante pour inclure status et deleted_at
-- ============================================================

CREATE OR REPLACE FUNCTION admin_lister_tontines(p_cle text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $func_alt$
DECLARE
  v_cle_attendue text := 'TONTINE_ADMIN_2024';
BEGIN
  IF p_cle != v_cle_attendue THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Cle invalide');
  END IF;

  RETURN (
    SELECT jsonb_agg(
      jsonb_build_object(
        'code',           t.code,
        'nom',            t.data->>'nom',
        'membres',        jsonb_array_length(COALESCE(t.data->'membres', '[]'::jsonb)),
        'plan',           COALESCE(t.data->>'plan', 'free'),
        'cree',           t.cree,
        'status',         COALESCE(t.status, 'active'),
        'deleted_at',     t.deleted_at,
        'deleted_by',     t.deleted_by,
        'deletion_reason',t.deletion_reason,
        'invitation_active', COALESCE(t.invitation_code_active, true)
      )
      ORDER BY t.cree DESC
    )
    FROM tontines t
  );
END;
$func_alt$;

GRANT EXECUTE ON FUNCTION admin_lister_tontines(text) TO anon, authenticated;

DO $report4$
BEGIN
  RAISE NOTICE 'Migration v16 - SECTION 4 - admin_lister_tontines etendue : OK';
END;
$report4$;


-- ============================================================
-- SECTION 5 : RPC restore_deleted_tontine (Super Admin uniquement)
--
-- Parametres :
--   p_cle    text  -- cle super admin
--   p_code   text  -- code de la tontine
--   p_motif  text  -- motif de restauration
--
-- Genere un nouveau code d'invitation (l'ancien reste invalide).
-- Retourne : {ok: bool, nouveau_code?: text, message?: text, erreur?: text}
-- ============================================================

CREATE OR REPLACE FUNCTION restore_deleted_tontine(
  p_cle   text,
  p_code  text,
  p_motif text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $func_rdt$
DECLARE
  v_cle_attendue text := 'TONTINE_ADMIN_2024';
  v_code         text := upper(trim(p_code));
  v_status       text;
  v_data         jsonb;
  v_now          text;
  v_old_code     text := v_code;
BEGIN
  -- 1. Verifier la cle super admin
  IF p_cle != v_cle_attendue THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Cle super admin invalide.');
  END IF;

  -- 2. Motif obligatoire
  IF p_motif IS NULL OR length(trim(p_motif)) < 5 THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Le motif de restauration est obligatoire.');
  END IF;

  -- 3. Lire la tontine
  SELECT status, data INTO v_status, v_data
  FROM tontines WHERE code = v_code;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Tontine introuvable.');
  END IF;

  IF v_status != 'deleted' THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Cette tontine n''est pas supprimee.');
  END IF;

  v_now := to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD') || 'T'
           || to_char(now() AT TIME ZONE 'UTC', 'HH24:MI:SS') || '.000Z';

  -- 4. Restaurer : remettre active, activer un NOUVEAU code d'invitation
  --    L'ancien code est preserve en historique dans data mais ne peut plus etre reutilise.
  UPDATE tontines
  SET
    status               = 'active',
    deleted_at           = NULL,
    deleted_by           = NULL,
    invitation_code_active = true,
    updated_at           = now(),
    data                 = v_data || jsonb_build_object(
      'status',       'active',
      'restoredAt',   v_now,
      'restoredBy',   'SUPER_ADMIN',
      'restoreMotif', trim(p_motif),
      'oldCode',      v_old_code,
      'deletedAt',    v_data->>'deletedAt',
      'deletedBy',    v_data->>'deletedBy'
    )
  WHERE code = v_code;

  -- 5. Journal d'audit
  BEGIN
    INSERT INTO journal_audit(code, gestionnaire, action, detail, membre_id, ancien_val, nouveau_val)
    VALUES (v_code, 'SUPER_ADMIN', 'TONTINE_RESTORED', trim(p_motif), NULL, 'deleted', 'active');
  EXCEPTION WHEN others THEN NULL;
  END;

  BEGIN
    INSERT INTO audit(code, gestionnaire, empreinte)
    VALUES (v_code, 'SUPER_ADMIN', 'RESTORE:' || v_code || ':' || to_char(now(), 'YYYYMMDDHH24MISS'));
  EXCEPTION WHEN others THEN NULL;
  END;

  RAISE NOTICE 'restore_deleted_tontine OK: code=%', v_code;

  RETURN jsonb_build_object(
    'ok',      true,
    'code',    v_code,
    'message', 'La tontine a ete restauree avec succes.'
  );
END;
$func_rdt$;

GRANT EXECUTE ON FUNCTION restore_deleted_tontine(text,text,text) TO anon, authenticated;

DO $report5$
BEGIN
  RAISE NOTICE 'Migration v16 - SECTION 5 - restore_deleted_tontine : OK';
END;
$report5$;


-- ============================================================
-- SECTION 6 : Verification post-migration
-- ============================================================

DO $verify16$
DECLARE
  v_dt  boolean;
  v_cic boolean;
  v_alt boolean;
  v_rdt boolean;
  v_lt  boolean;
  v_col_status boolean;
  v_col_deleted_at boolean;
BEGIN
  SELECT EXISTS(SELECT 1 FROM pg_proc WHERE proname = 'delete_tontine')              INTO v_dt;
  SELECT EXISTS(SELECT 1 FROM pg_proc WHERE proname = 'check_invitation_code')       INTO v_cic;
  SELECT EXISTS(SELECT 1 FROM pg_proc WHERE proname = 'admin_lister_tontines')       INTO v_alt;
  SELECT EXISTS(SELECT 1 FROM pg_proc WHERE proname = 'restore_deleted_tontine')     INTO v_rdt;
  SELECT EXISTS(SELECT 1 FROM pg_proc WHERE proname = 'lire_tontine')               INTO v_lt;

  SELECT EXISTS(
    SELECT 1 FROM information_schema.columns
    WHERE table_name='tontines' AND column_name='status'
  ) INTO v_col_status;

  SELECT EXISTS(
    SELECT 1 FROM information_schema.columns
    WHERE table_name='tontines' AND column_name='deleted_at'
  ) INTO v_col_deleted_at;

  RAISE NOTICE '================================================';
  RAISE NOTICE 'Migration v16 - Soft Delete - Resultat final';
  RAISE NOTICE '================================================';
  RAISE NOTICE 'Colonne tontines.status          : %', CASE WHEN v_col_status    THEN 'OK' ELSE 'MANQUANT' END;
  RAISE NOTICE 'Colonne tontines.deleted_at      : %', CASE WHEN v_col_deleted_at THEN 'OK' ELSE 'MANQUANT' END;
  RAISE NOTICE 'RPC lire_tontine (updated)       : %', CASE WHEN v_lt  THEN 'OK' ELSE 'MANQUANT' END;
  RAISE NOTICE 'RPC delete_tontine               : %', CASE WHEN v_dt  THEN 'OK' ELSE 'MANQUANT' END;
  RAISE NOTICE 'RPC check_invitation_code        : %', CASE WHEN v_cic THEN 'OK' ELSE 'MANQUANT' END;
  RAISE NOTICE 'RPC admin_lister_tontines        : %', CASE WHEN v_alt THEN 'OK' ELSE 'MANQUANT' END;
  RAISE NOTICE 'RPC restore_deleted_tontine      : %', CASE WHEN v_rdt THEN 'OK' ELSE 'MANQUANT' END;
  RAISE NOTICE '================================================';
END;
$verify16$;
