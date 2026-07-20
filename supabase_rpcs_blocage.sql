-- ═══════════════════════════════════════════════════════════════════════════
-- TontineClair — RPCs de blocage/déblocage de tontine
-- Projet : ubrqtcxbxcmvmxleiglh
-- Version : 1.2.15+19
-- 
-- DÉPLOIEMENT : SQL Editor dans Supabase Dashboard
--   https://supabase.com/dashboard/project/ubrqtcxbxcmvmxleiglh/sql/new
-- ═══════════════════════════════════════════════════════════════════════════

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. BLOQUER UNE TONTINE
--    Paramètres :
--      p_cle   = clé secrète admin (vérifiée via app.admin_key)
--      p_code  = code de la tontine (ex: "TONTI01")
--      p_motif = raison du blocage (texte libre)
--    Retourne :
--      {"ok": true}  ou  {"ok": false, "erreur": "..."}
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_bloquer_tontine(
  p_cle   text,
  p_code  text,
  p_motif text
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_count integer;
BEGIN
  -- Vérification de la clé admin
  IF p_cle IS DISTINCT FROM current_setting('app.admin_key', true) THEN
    RETURN json_build_object('ok', false, 'erreur', 'Clé invalide');
  END IF;

  -- Vérifier que la tontine existe
  SELECT COUNT(*) INTO v_count
  FROM tontines
  WHERE code = upper(p_code);

  IF v_count = 0 THEN
    RETURN json_build_object('ok', false, 'erreur', 'Tontine introuvable : ' || upper(p_code));
  END IF;

  -- Appliquer le blocage
  UPDATE tontines
  SET
    status = 'blocked',
    data   = jsonb_set(
               COALESCE(data, '{}'::jsonb),
               '{_blocage}',
               jsonb_build_object(
                 'motif',  p_motif,
                 'date',   now()::text,
                 'auteur', 'admin'
               )
             )
  WHERE code = upper(p_code);

  RETURN json_build_object('ok', true);
END;
$$;

-- Accorder l'exécution au rôle anon et authenticated
GRANT EXECUTE ON FUNCTION public.admin_bloquer_tontine(text, text, text) TO anon;
GRANT EXECUTE ON FUNCTION public.admin_bloquer_tontine(text, text, text) TO authenticated;


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. DÉBLOQUER UNE TONTINE
--    Paramètres :
--      p_cle  = clé secrète admin
--      p_code = code de la tontine
--    Retourne :
--      {"ok": true}  ou  {"ok": false, "erreur": "..."}
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_debloquer_tontine(
  p_cle  text,
  p_code text
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_count integer;
BEGIN
  -- Vérification de la clé admin
  IF p_cle IS DISTINCT FROM current_setting('app.admin_key', true) THEN
    RETURN json_build_object('ok', false, 'erreur', 'Clé invalide');
  END IF;

  -- Vérifier que la tontine existe
  SELECT COUNT(*) INTO v_count
  FROM tontines
  WHERE code = upper(p_code);

  IF v_count = 0 THEN
    RETURN json_build_object('ok', false, 'erreur', 'Tontine introuvable : ' || upper(p_code));
  END IF;

  -- Lever le blocage → retour à 'active' + suppression du champ _blocage
  UPDATE tontines
  SET
    status = 'active',
    data   = data - '_blocage'
  WHERE code = upper(p_code);

  RETURN json_build_object('ok', true);
END;
$$;

-- Accorder l'exécution au rôle anon et authenticated
GRANT EXECUTE ON FUNCTION public.admin_debloquer_tontine(text, text) TO anon;
GRANT EXECUTE ON FUNCTION public.admin_debloquer_tontine(text, text) TO authenticated;


-- ─────────────────────────────────────────────────────────────────────────────
-- 3. VÉRIFICATION POST-DÉPLOIEMENT
--    Exécutez ces SELECT pour confirmer que les fonctions existent bien.
-- ─────────────────────────────────────────────────────────────────────────────
SELECT
  routine_name,
  routine_type,
  security_type
FROM information_schema.routines
WHERE routine_schema = 'public'
  AND routine_name IN ('admin_bloquer_tontine', 'admin_debloquer_tontine')
ORDER BY routine_name;

-- Résultat attendu :
--  routine_name             | routine_type | security_type
-- --------------------------+--------------+---------------
--  admin_bloquer_tontine    | FUNCTION     | DEFINER
--  admin_debloquer_tontine  | FUNCTION     | DEFINER

