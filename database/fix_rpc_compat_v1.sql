-- ============================================================
-- TontineClair — fix_rpc_compat_v1.sql
-- Correctif de compatibilité RPC post-init_inline.sql
--
-- PROBLÈME : init_inline.sql contient 3 fonctions régressives
-- dont la signature ou le format de retour diffère de la version
-- prod (supabase-v16/v17/v18). Conséquence : les tontines
-- existantes s'affichent vides dans l'application.
--
-- CE SCRIPT :
--   ✅ Corrige uniquement les 3 fonctions régressives
--   ✅ Idempotent (CREATE OR REPLACE — safe à relancer)
--   ✅ Ne touche à aucune donnée existante
--   ✅ Ne crée aucune table ni colonne
--
-- ORDRE D'EXÉCUTION : après init_inline.sql et upgrade.sql
-- ============================================================


-- ============================================================
-- FIX 1 — lire_tontine v16-CORRECTE
--
-- RÉGRESSION dans init_inline.sql (ligne 826) :
--   Retournait {'ok': true, 'data': v_row.data, 'code': ..., 'status': ..., 'updated_at': ...}
--   → Flutter reçoit le wrapper, TontineData.fromJson() ne trouve
--     aucun champ connu (nom, membres, etc.) → tout est vide.
--
-- VERSION CORRECTE (supabase-v16-soft-delete.sql §1) :
--   Retourne v_row.data || {'__status__': ..., '__invitation_code_active__': ...}
--   → Flutter reçoit directement le JSON de la tontine + les 2 méta-clés.
--
-- Flutter (supabase_service.dart ligne 253) :
--   rawData['__deleted__'] == true → TONTINE_DELETED
--   rawData['__status__']          → status
--   rawData['__invitation_code_active__'] → invitationActive
--   TontineData.fromJson(rawData)  → parse nom, membres, etc. ✅
-- ============================================================

DROP FUNCTION IF EXISTS public.lire_tontine(text) CASCADE;

CREATE OR REPLACE FUNCTION public.lire_tontine(p_code text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $func_lt$
DECLARE
  v_code text    := upper(trim(p_code));
  v_row  tontines%ROWTYPE;
BEGIN
  SELECT * INTO v_row FROM tontines WHERE code = v_code;

  -- Code inconnu → null (Flutter lève CODE_INTROUVABLE)
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  -- Tontine supprimée → marqueur __deleted__ (Flutter lève TONTINE_DELETED)
  IF v_row.status = 'deleted' THEN
    RETURN jsonb_build_object(
      '__deleted__', true,
      'code',        v_code,
      'message',     'Cette tontine a été supprimée par son gestionnaire et n''est plus accessible.'
    );
  END IF;

  -- Retourner le champ data fusionné avec les méta-clés attendues par Flutter
  -- Format exact attendu par supabase_service.dart :
  --   rawData['__status__']                 → v_row.status
  --   rawData['__invitation_code_active__'] → v_row.invitation_code_active
  --   TontineData.fromJson(rawData)         → parse nom, membres, montant, etc.
  RETURN COALESCE(v_row.data, '{}'::jsonb) || jsonb_build_object(
    '__status__',                 COALESCE(v_row.status, 'active'),
    '__invitation_code_active__', COALESCE(v_row.invitation_code_active, true)
  );
END;
$func_lt$;

GRANT EXECUTE ON FUNCTION public.lire_tontine(text) TO anon, authenticated;

DO $check1$
BEGIN
  RAISE NOTICE 'FIX 1 — lire_tontine v16-correcte : OK';
END;
$check1$;


-- ============================================================
-- FIX 2 — voter v18-CORRECTE (6 paramètres + retourne text)
--
-- RÉGRESSION dans init_inline.sql (ligne 1007) :
--   Signature : (p_code, p_vote_id, p_membre_id, p_nom, p_choix) — 5 params
--   Retour    : boolean
--   Stockage  : dans tontines.data->votes[].voix (jsonb inline)
--
-- VERSION CORRECTE (supabase-fix-v18-voter-choix-minuscules.sql) :
--   Signature : (p_code, p_vote_id, p_membre_id, p_pin_membre, p_choix, p_appareil) — 6 params
--   Retour    : text ('OK'|'PIN_INCORRECT'|'VOTE_INTROUVABLE'|'VOTE_CLOS'|'DEJA_VOTE'|'CHOIX_INVALIDE')
--   Stockage  : dans table voix (dédiée) + audit
--   Validation: PIN membre via tontines.membres_pins[]
--
-- Flutter (supabase_service.dart ligne 464) envoie :
--   p_code, p_vote_id, p_membre_id, p_pin_membre, p_choix, p_appareil ✅
-- ============================================================

-- Supprimer les deux surcharges possibles (5 params et 6 params)
DROP FUNCTION IF EXISTS public.voter(text, text, text, text, text)        CASCADE;
DROP FUNCTION IF EXISTS public.voter(text, text, text, text, text, text)  CASCADE;

CREATE OR REPLACE FUNCTION public.voter(
  p_code        text,
  p_vote_id     text,
  p_membre_id   text,
  p_pin_membre  text,
  p_choix       text,
  p_appareil    text
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $func_voter$
DECLARE
  v_statut text;
  v_choix  text;
BEGIN
  -- Normaliser le choix en minuscules (accepte 'Oui', 'OUI', 'oui', etc.)
  v_choix := lower(trim(p_choix));

  -- Valider le choix
  IF v_choix NOT IN ('oui', 'non', 'abstention') THEN
    RETURN 'CHOIX_INVALIDE';
  END IF;

  -- Vérifier le PIN du membre via membres_pins[]
  IF NOT EXISTS (
    SELECT 1 FROM tontines
     WHERE code = upper(p_code)
       AND membres_pins @> jsonb_build_array(
             jsonb_build_object('id', p_membre_id, 'pin', p_pin_membre)
           )
  ) THEN
    RETURN 'PIN_INCORRECT';
  END IF;

  -- Vérifier que le vote existe et est ouvert dans data->votes[]
  SELECT v->>'statut' INTO v_statut
    FROM tontines t,
         jsonb_array_elements(COALESCE(t.data->'votes', '[]'::jsonb)) v
   WHERE t.code = upper(p_code)
     AND v->>'id' = p_vote_id;

  IF v_statut IS NULL THEN RETURN 'VOTE_INTROUVABLE'; END IF;
  IF v_statut <> 'ouvert' THEN RETURN 'VOTE_CLOS'; END IF;

  -- Insérer la voix dans la table dédiée (unique_violation = déjà voté)
  BEGIN
    INSERT INTO voix(code, vote_id, membre_id, choix, methode, appareil)
    VALUES (
      upper(p_code),
      p_vote_id,
      p_membre_id,
      v_choix,
      'PIN',
      left(coalesce(p_appareil, ''), 64)
    );
  EXCEPTION WHEN unique_violation THEN
    RETURN 'DEJA_VOTE';
  END;

  -- Audit
  BEGIN
    INSERT INTO audit(code, gestionnaire, empreinte)
    VALUES (
      upper(p_code),
      'MEMBRE:' || p_membre_id,
      'VOTE:' || p_vote_id || ':' || v_choix
    );
  EXCEPTION WHEN OTHERS THEN NULL; -- table audit absente = non bloquant
  END;

  RETURN 'OK';
END;
$func_voter$;

GRANT EXECUTE ON FUNCTION public.voter(text, text, text, text, text, text) TO anon, authenticated;

DO $check2$
BEGIN
  RAISE NOTICE 'FIX 2 — voter v18-correcte (6 params, retour text) : OK';
END;
$check2$;


-- ============================================================
-- FIX 3 — delete_tontine v16-CORRECTE (p_raison + p_nom_confirmation)
--
-- RÉGRESSION dans init_inline.sql (ligne 931) :
--   Signature : (p_code, p_nom, p_pin, p_motif text DEFAULT '')
--   → Flutter envoie p_raison et p_nom_confirmation → PGRST202 (param inconnu)
--
-- VERSION CORRECTE (supabase-v16-soft-delete.sql §2) :
--   Signature : (p_code, p_nom, p_pin, p_raison, p_nom_confirmation)
--   Valide    : longueur de p_raison ≥ 5 chars
--   Valide    : p_nom_confirmation == data->>'nom' (case-insensitive)
--   Retourne  : {ok: bool, message?: text, erreur?: text, deletionReason?: text}
--
-- Flutter (supabase_service.dart ligne 304) envoie :
--   p_code, p_nom, p_pin, p_raison, p_nom_confirmation ✅
-- ============================================================

-- Supprimer les deux surcharges possibles (4 params avec DEFAULT et 5 params)
DROP FUNCTION IF EXISTS public.delete_tontine(text, text, text, text)        CASCADE;
DROP FUNCTION IF EXISTS public.delete_tontine(text, text, text, text, text)  CASCADE;

CREATE OR REPLACE FUNCTION public.delete_tontine(
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
  v_code text := upper(trim(p_code));
  v_nom  text;
  v_ok   boolean;
BEGIN
  -- Vérifier PIN gestionnaire
  SELECT verifier_gestionnaire(v_code, p_nom, p_pin) INTO v_ok;
  IF NOT v_ok THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'PIN incorrect ou gestionnaire non reconnu.');
  END IF;

  -- Valider la raison (≥ 5 caractères)
  IF p_raison IS NULL OR length(trim(p_raison)) < 5 THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'La raison doit contenir au moins 5 caractères.');
  END IF;

  -- Récupérer le nom de la tontine pour vérifier la confirmation
  SELECT data->>'nom' INTO v_nom FROM tontines WHERE code = v_code;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Tontine introuvable.');
  END IF;

  -- Vérifier que l'utilisateur a bien saisi le nom exact (case-insensitive)
  IF lower(trim(p_nom_confirmation)) != lower(COALESCE(v_nom, '')) THEN
    RETURN jsonb_build_object(
      'ok', false,
      'erreur', 'Le nom de confirmation ne correspond pas au nom de la tontine.'
    );
  END IF;

  -- Effectuer le soft delete
  UPDATE tontines
  SET
    status               = 'deleted',
    deleted_at           = NOW(),
    deleted_by           = p_nom,
    deletion_reason      = trim(p_raison),
    invitation_code_active = false,
    updated_at           = NOW()
  WHERE code = v_code
    AND status != 'deleted';

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Tontine déjà supprimée ou introuvable.');
  END IF;

  -- Audit dans journal si la table existe
  BEGIN
    INSERT INTO journal_audit(code, gestionnaire, action, detail)
    VALUES (v_code, p_nom, 'TONTINE_DELETED', trim(p_raison));
  EXCEPTION WHEN OTHERS THEN NULL;
  END;

  RETURN jsonb_build_object(
    'ok',            true,
    'message',       'La tontine a été supprimée avec succès.',
    'deletionReason', trim(p_raison)
  );
END;
$func_dt$;

GRANT EXECUTE ON FUNCTION public.delete_tontine(text, text, text, text, text) TO anon, authenticated;

DO $check3$
BEGIN
  RAISE NOTICE 'FIX 3 — delete_tontine v16-correcte (p_raison + p_nom_confirmation) : OK';
END;
$check3$;


-- ============================================================
-- VÉRIFICATION FINALE
-- ============================================================

DO $verify_all$
DECLARE
  v_lt_sig  text;
  v_vt_sig  text;
  v_vt_ret  text;
  v_dt_sig  text;
BEGIN
  -- lire_tontine : doit retourner jsonb, 1 param
  SELECT pg_get_function_result(p.oid)
    INTO v_lt_sig
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'lire_tontine';

  -- voter : doit avoir 6 params et retourner text
  SELECT pg_get_function_result(p.oid)
    INTO v_vt_ret
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'voter'
    AND p.pronargs = 6;

  -- delete_tontine : doit avoir 5 params
  SELECT pronargs::text
    INTO v_dt_sig
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'delete_tontine';

  RAISE NOTICE '════════════════════════════════════════';
  RAISE NOTICE 'RÉSULTAT VÉRIFICATION fix_rpc_compat_v1';
  RAISE NOTICE '────────────────────────────────────────';
  RAISE NOTICE 'lire_tontine  → retourne : %  [attendu: jsonb]',       COALESCE(v_lt_sig, 'ABSENT ❌');
  RAISE NOTICE 'voter(6)      → retourne : %  [attendu: text]',        COALESCE(v_vt_ret, 'ABSENT ❌');
  RAISE NOTICE 'delete_tontine → nb params : %  [attendu: 5]',         COALESCE(v_dt_sig, 'ABSENT ❌');
  RAISE NOTICE '════════════════════════════════════════';

  IF v_lt_sig IS NULL THEN
    RAISE WARNING 'lire_tontine absente — FIX 1 a échoué !';
  END IF;
  IF v_vt_ret IS NULL OR v_vt_ret != 'text' THEN
    RAISE WARNING 'voter(6) absente ou mauvais type — FIX 2 a échoué !';
  END IF;
  IF v_dt_sig IS NULL OR v_dt_sig != '5' THEN
    RAISE WARNING 'delete_tontine(5) absente — FIX 3 a échoué !';
  END IF;
END;
$verify_all$;

-- ============================================================
-- FIN fix_rpc_compat_v1.sql
-- ============================================================
