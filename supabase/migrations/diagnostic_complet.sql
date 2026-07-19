-- ═══════════════════════════════════════════════════════════════════════════════
-- DIAGNOSTIC COMPLET — TontineClair PIN Reset
-- Exécuter dans : Supabase → SQL Editor → New query → Run
-- Chaque SELECT retourne une ligne avec son diagnostic
-- ═══════════════════════════════════════════════════════════════════════════════

-- ── 1. Vérifier la structure exacte de la colonne gestionnaires pour M3JQ3U ──
SELECT
  '1_COLONNE_GESTIONNAIRES' AS test,
  code,
  gestionnaires                                   AS colonne_gestionnaires,
  data -> 'gestionnaires'                         AS data_gestionnaires,
  jsonb_typeof(gestionnaires)                     AS type_colonne,
  jsonb_array_length(COALESCE(gestionnaires,'[]'::jsonb)) AS nb_objets_colonne,
  jsonb_array_length(COALESCE(data->'gestionnaires','[]'::jsonb)) AS nb_strings_data
FROM tontines
WHERE code = 'M3JQ3U';
