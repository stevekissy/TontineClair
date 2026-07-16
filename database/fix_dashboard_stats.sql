-- ══════════════════════════════════════════════════════════════════════════════
-- fix_dashboard_stats.sql
-- Correctif ciblé : statistiques dashboard toujours à 0
-- Auteur  : audit session TC-Admin
-- Contraintes : pas de DROP TABLE / DELETE / TRUNCATE / CASCADE
--               pas de modification globale de schéma
--               requêtes indépendantes et vérifiables
-- ══════════════════════════════════════════════════════════════════════════════
--
-- DIAGNOSTIC COMPLET :
--
-- ROOT CAUSE 1 (critique) — _verif_admin_cle renvoie toujours false
-- ─────────────────────────────────────────────────────────────────
-- La version déployée en production lit :
--   SELECT 1 FROM config WHERE admin_cle = p_cle
-- Or la table config a pour schéma : (cle TEXT PK, valeur TEXT NOT NULL)
-- Il n'y a PAS de colonne admin_cle.
-- PostgreSQL lève undefined_column, capturé par EXCEPTION WHEN undefined_table
-- (qui attrape TOUTES les exceptions PL/pgSQL).
-- → v_ok = false → la fonction retourne false pour n'importe quelle clé.
--
-- ROOT CAUSE 2 (bloquant) — aucune valeur stockée dans app_config
-- ──────────────────────────────────────────────────────────────────
-- La version dans fix_rpc_admin_v2.sql lit app_config WHERE cle='admin_key'
-- mais app_config est vide si l'INSERT n'a jamais été exécuté.
-- → même résultat : false pour toute clé.
--
-- ROOT CAUSE 3 (secondaire) — plan RLS sur app_config bloque la lecture
-- ──────────────────────────────────────────────────────────────────────
-- app_config a une policy USING (false) → même un SELECT via SECURITY DEFINER
-- peut être bloqué selon la configuration RLS.
-- Note : SECURITY DEFINER bypass RLS seulement si l'owner a les droits.
--
-- SOLUTION CIBLÉE :
-- 1. Réécrire _verif_admin_cle pour lire config(cle,valeur) correctement
--    (source 1 : config WHERE cle='admin_key')
-- 2. Insérer la clé admin dans config si elle n'existe pas
-- 3. Insérer la clé admin dans app_config comme fallback
-- 4. Vérifier les droits EXECUTE sur les 6 RPCs du dashboard
-- ══════════════════════════════════════════════════════════════════════════════

-- ─────────────────────────────────────────────────────────────────────────────
-- ÉTAPE 0 : Diagnostic — lire ce que contient réellement la base
-- (requêtes en lecture seule, aucune modification)
-- ─────────────────────────────────────────────────────────────────────────────

-- Colonnes réelles de la table config
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'config'
ORDER BY ordinal_position;

-- Contenu actuel de config
SELECT * FROM config LIMIT 20;

-- Contenu actuel de app_config
SELECT * FROM app_config LIMIT 20;

-- Contenu actuel de admin_config
SELECT * FROM admin_config LIMIT 10;

-- Corps SQL actuel de _verif_admin_cle (pour confirmer le bug)
SELECT pg_get_functiondef(oid)
FROM pg_proc
WHERE proname = '_verif_admin_cle' AND pronamespace = 'public'::regnamespace;

-- ─────────────────────────────────────────────────────────────────────────────
-- ÉTAPE 1 : Insérer la clé admin dans config (schéma réel : cle, valeur)
-- ─────────────────────────────────────────────────────────────────────────────
-- Remplacer 'VOTRE_CLE_ADMIN_ICI' par la clé que vous saisissez dans l'app.
-- Si vous utilisez une clé de test (ex: "admin1234"), mettez-la ici.

INSERT INTO config (cle, valeur)
VALUES ('admin_key', 'VOTRE_CLE_ADMIN_ICI')
ON CONFLICT (cle) DO UPDATE SET valeur = EXCLUDED.valeur;

-- Même chose dans app_config (fallback)
INSERT INTO app_config (cle, valeur)
VALUES ('admin_key', 'VOTRE_CLE_ADMIN_ICI')
ON CONFLICT (cle) DO UPDATE SET valeur = EXCLUDED.valeur;

-- ─────────────────────────────────────────────────────────────────────────────
-- ÉTAPE 2 : Réécriture de _verif_admin_cle
-- Source unique : config(cle='admin_key', valeur) — schéma réel de la table
-- Fallback : app_config(cle='admin_key')
-- Fallback 2 : admin_config(cle=p_cle) pour rétrocompatibilité
-- ─────────────────────────────────────────────────────────────────────────────
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

  -- Source 1 : config(cle='admin_key', valeur)  [schéma réel : cle+valeur]
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

  -- Source 2 : app_config(cle='admin_key', valeur)
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

  -- Source 3 : admin_config(cle=p_cle)  [rétrocompatibilité]
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

-- ─────────────────────────────────────────────────────────────────────────────
-- ÉTAPE 3 : Confirmer les GRANT EXECUTE sur les 6 RPCs du dashboard
-- (idempotent — ne change rien si déjà accordé)
-- ─────────────────────────────────────────────────────────────────────────────
GRANT EXECUTE ON FUNCTION public.admin_stats_globales(text)           TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_dashboard_tontines(text, text, int, int) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_lister_abonnements(text, text, int) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_alertes(text)                  TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_stats_mensuelles(text)         TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_top_tontines(text)             TO anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- ÉTAPE 4 : Test de validation — vérifier que _verif_admin_cle retourne true
-- Remplacer 'VOTRE_CLE_ADMIN_ICI' par votre vraie clé
-- ─────────────────────────────────────────────────────────────────────────────
SELECT _verif_admin_cle('VOTRE_CLE_ADMIN_ICI') AS verif_ok;
-- Résultat attendu : true
-- Si false : la clé dans l'INSERT (étape 1) ne correspond pas à celle saisie

-- Test rapide des 6 RPCs avec la vraie clé
-- (retourne des données réelles si tout est correct)
SELECT admin_stats_globales('VOTRE_CLE_ADMIN_ICI');
SELECT jsonb_array_length(admin_dashboard_tontines('VOTRE_CLE_ADMIN_ICI', 'toutes', 5, 0)) AS nb_tontines;
SELECT jsonb_array_length(admin_lister_abonnements('VOTRE_CLE_ADMIN_ICI', 'tous', 5)) AS nb_abos;
SELECT jsonb_array_length(admin_alertes('VOTRE_CLE_ADMIN_ICI')) AS nb_alertes;
SELECT jsonb_array_length(admin_stats_mensuelles('VOTRE_CLE_ADMIN_ICI')) AS nb_mois;
SELECT jsonb_array_length(admin_top_tontines('VOTRE_CLE_ADMIN_ICI')) AS nb_top;
