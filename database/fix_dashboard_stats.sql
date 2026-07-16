-- ══════════════════════════════════════════════════════════════════════════════
-- fix_dashboard_stats.sql  (v2 — blocs séparés, exécutables un par un)
-- Correctif ciblé : statistiques dashboard toujours à 0
-- Contraintes : pas de DROP TABLE / DELETE / TRUNCATE / CASCADE
-- ══════════════════════════════════════════════════════════════════════════════
--
-- CAUSE RACINE CONFIRMÉE :
--   _verif_admin_cle lit « config WHERE admin_cle = p_cle »
--   mais la table config a pour schéma (cle TEXT PK, valeur TEXT).
--   Il n'y a PAS de colonne admin_cle → PostgreSQL lève undefined_column,
--   capturé par EXCEPTION WHEN undefined_table (attrape TOUTES les exceptions).
--   → retourne false pour n'importe quelle clé
--   → les 6 RPCs du dashboard retournent null/[] immédiatement
--   → toutes les statistiques affichent 0
--
-- INSTRUCTIONS :
--   Remplacer VOTRE_CLE_ADMIN_ICI par la clé saisie dans l'app TC Admin.
--   Exécuter les 5 blocs ci-dessous UN PAR UN dans Supabase SQL Editor.
-- ══════════════════════════════════════════════════════════════════════════════


-- ════════════════════════════════════════════════════════════════════════════
-- BLOC 0 — DIAGNOSTIC (lecture seule, aucune modification)
-- Exécuter en premier pour identifier la configuration actuelle.
-- ════════════════════════════════════════════════════════════════════════════

SELECT
  'config'      AS table_name,
  column_name,
  data_type
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'config'
UNION ALL
SELECT
  'app_config'  AS table_name,
  column_name,
  data_type
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'app_config'
UNION ALL
SELECT
  'admin_config' AS table_name,
  column_name,
  data_type
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'admin_config'
ORDER BY table_name, column_name;


-- ════════════════════════════════════════════════════════════════════════════
-- BLOC 1 — STOCKER LA CLÉ ADMIN
-- Remplacer VOTRE_CLE_ADMIN_ICI par la vraie clé (ex: "admin1234").
-- ON CONFLICT : idempotent, peut être ré-exécuté sans risque.
-- ════════════════════════════════════════════════════════════════════════════

INSERT INTO public.config (cle, valeur)
VALUES ('admin_key', 'VOTRE_CLE_ADMIN_ICI')
ON CONFLICT (cle) DO UPDATE SET valeur = EXCLUDED.valeur;

INSERT INTO public.app_config (cle, valeur)
VALUES ('admin_key', 'VOTRE_CLE_ADMIN_ICI')
ON CONFLICT (cle) DO UPDATE SET valeur = EXCLUDED.valeur;

-- Vérification immédiate
SELECT 'config'     AS source, cle, valeur FROM public.config      WHERE cle = 'admin_key'
UNION ALL
SELECT 'app_config' AS source, cle, valeur FROM public.app_config  WHERE cle = 'admin_key';


-- ════════════════════════════════════════════════════════════════════════════
-- BLOC 2 — RÉÉCRITURE DE _verif_admin_cle
-- Corrige le bug : lit config(cle, valeur) au lieu de config(admin_cle).
-- Trois sources en cascade : config → app_config → admin_config.
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public._verif_admin_cle(p_cle TEXT)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $func_vac2$
DECLARE
  v_stockee TEXT;
BEGIN
  -- Garde-fou : clé soumise vide ou nulle
  IF p_cle IS NULL OR trim(p_cle) = '' THEN
    RETURN false;
  END IF;

  -- Source 1 : config(cle='admin_key', valeur)  ← schéma réel de la table
  BEGIN
    SELECT valeur INTO v_stockee
    FROM public.config
    WHERE cle = 'admin_key'
    LIMIT 1;
  EXCEPTION WHEN OTHERS THEN
    v_stockee := NULL;
  END;

  IF v_stockee IS NOT NULL AND trim(v_stockee) <> '' THEN
    RETURN p_cle = v_stockee;
  END IF;

  -- Source 2 : app_config(cle='admin_key', valeur)  ← fallback
  BEGIN
    SELECT valeur INTO v_stockee
    FROM public.app_config
    WHERE cle = 'admin_key'
    LIMIT 1;
  EXCEPTION WHEN OTHERS THEN
    v_stockee := NULL;
  END;

  IF v_stockee IS NOT NULL AND trim(v_stockee) <> '' THEN
    RETURN p_cle = v_stockee;
  END IF;

  -- Source 3 : admin_config(cle=p_cle)  ← rétrocompatibilité v1
  BEGIN
    RETURN EXISTS (
      SELECT 1 FROM public.admin_config WHERE cle = p_cle
    );
  EXCEPTION WHEN OTHERS THEN
    RETURN false;
  END;
END;
$func_vac2$;

GRANT EXECUTE ON FUNCTION public._verif_admin_cle(TEXT) TO anon, authenticated;


-- ════════════════════════════════════════════════════════════════════════════
-- BLOC 3 — GRANT EXECUTE sur les 6 RPCs du dashboard
-- Idempotent : ne change rien si les droits sont déjà accordés.
-- ════════════════════════════════════════════════════════════════════════════

GRANT EXECUTE ON FUNCTION public.admin_stats_globales(text)
  TO anon, authenticated;

GRANT EXECUTE ON FUNCTION public.admin_dashboard_tontines(text, text, int, int)
  TO anon, authenticated;

GRANT EXECUTE ON FUNCTION public.admin_lister_abonnements(text, text, int)
  TO anon, authenticated;

GRANT EXECUTE ON FUNCTION public.admin_alertes(text)
  TO anon, authenticated;

GRANT EXECUTE ON FUNCTION public.admin_stats_mensuelles(text)
  TO anon, authenticated;

GRANT EXECUTE ON FUNCTION public.admin_top_tontines(text)
  TO anon, authenticated;


-- ════════════════════════════════════════════════════════════════════════════
-- BLOC 4 — TESTS DE VALIDATION
-- Remplacer VOTRE_CLE_ADMIN_ICI par la même clé qu'au BLOC 1.
-- Résultats attendus :
--   verif_ok          → true
--   stats             → objet JSON avec total_tontines > 0
--   nb_tontines       → nombre de tontines en base
--   nb_abos           → nombre d'abonnements
--   nb_alertes        → 0 ou plus (normal si aucune alerte active)
--   nb_mois           → 12 (toujours — les 12 derniers mois)
--   nb_top            → nombre de tontines dans le top 10
-- ════════════════════════════════════════════════════════════════════════════

SELECT public._verif_admin_cle('VOTRE_CLE_ADMIN_ICI') AS verif_ok;

SELECT public.admin_stats_globales('VOTRE_CLE_ADMIN_ICI') AS stats;

SELECT
  jsonb_array_length(public.admin_dashboard_tontines('VOTRE_CLE_ADMIN_ICI', 'toutes', 10, 0)) AS nb_tontines,
  jsonb_array_length(public.admin_lister_abonnements('VOTRE_CLE_ADMIN_ICI', 'tous', 10))      AS nb_abos,
  jsonb_array_length(public.admin_alertes('VOTRE_CLE_ADMIN_ICI'))                             AS nb_alertes,
  jsonb_array_length(public.admin_stats_mensuelles('VOTRE_CLE_ADMIN_ICI'))                    AS nb_mois,
  jsonb_array_length(public.admin_top_tontines('VOTRE_CLE_ADMIN_ICI'))                        AS nb_top;
