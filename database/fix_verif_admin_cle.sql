-- ══════════════════════════════════════════════════════════════════════════════
-- fix_verif_admin_cle.sql
-- Correctif minimal : _verif_admin_cle + stockage de la clé admin
-- Exécuter EN UNE SEULE FOIS dans Supabase SQL Editor.
-- Remplacer VOTRE_CLE_ADMIN_ICI par la clé saisie dans l'app TC Admin.
-- Aucune table métier modifiée. Aucune donnée existante touchée.
-- ══════════════════════════════════════════════════════════════════════════════

-- Étape 1 : Stocker la clé admin dans admin_config
-- Schéma réel en production : (id INT PK DEFAULT 1, cle TEXT, note TEXT)
-- Contrainte : une seule ligne (id = 1 imposé)
INSERT INTO public.admin_config (id, cle, note)
VALUES (1, 'VOTRE_CLE_ADMIN_ICI', 'Clé admin principale')
ON CONFLICT (id) DO UPDATE SET cle = EXCLUDED.cle;

-- Étape 2 : Réécrire _verif_admin_cle
-- Source unique : admin_config WHERE id = 1
-- Aucune lecture de config ni app_config (colonnes incertaines en prod)
-- SECURITY DEFINER : bypass RLS pour lire admin_config
CREATE OR REPLACE FUNCTION public._verif_admin_cle(p_cle TEXT)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $func_vac3$
DECLARE
  v_stockee TEXT;
BEGIN
  IF p_cle IS NULL OR trim(p_cle) = '' THEN
    RETURN false;
  END IF;

  SELECT cle INTO v_stockee
  FROM public.admin_config
  WHERE id = 1
  LIMIT 1;

  IF v_stockee IS NULL OR trim(v_stockee) = '' THEN
    RETURN false;
  END IF;

  RETURN p_cle = v_stockee;
END;
$func_vac3$;

GRANT EXECUTE ON FUNCTION public._verif_admin_cle(TEXT) TO anon, authenticated;

-- Étape 3 : Vérification — doit retourner true avec votre clé
SELECT public._verif_admin_cle('VOTRE_CLE_ADMIN_ICI') AS verif_ok;
