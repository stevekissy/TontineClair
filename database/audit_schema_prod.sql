-- ============================================================
-- TontineClair — audit_schema_prod.sql
-- Script d'introspection du schéma réel de production
--
-- UTILISATION :
--   Supabase SQL Editor → New query → Coller ce fichier → Run
--   Copier l'intégralité du résultat et le transmettre à l'agent.
--
-- CE SCRIPT :
--   ✅ Ne modifie rien (SELECT uniquement)
--   ✅ Exporte : tables, colonnes, types, defaults, nullable
--   ✅ Exporte : index (nom, colonnes, unique, partial)
--   ✅ Exporte : contraintes (PK, UNIQUE, CHECK, FK)
--   ✅ Exporte : triggers (nom, table, événement, fonction)
--   ✅ Exporte : politiques RLS (nom, table, cmd, roles, expr)
--   ✅ Exporte : fonctions/RPCs (nom, arguments, retour)
--   ✅ Produit un résumé JSON compact par table à la fin
-- ============================================================

-- ────────────────────────────────────────────────────────────
-- SECTION 1 : LISTE DES TABLES
-- ────────────────────────────────────────────────────────────
SELECT
  '=== TABLES ===' AS section,
  t.table_name,
  t.table_type,
  obj_description(c.oid, 'pg_class') AS table_comment,
  CASE WHEN c.relrowsecurity THEN 'RLS=ON' ELSE 'RLS=OFF' END AS rls_status
FROM information_schema.tables t
JOIN pg_class c ON c.relname = t.table_name
  AND c.relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public')
WHERE t.table_schema = 'public'
  AND t.table_type = 'BASE TABLE'
ORDER BY t.table_name;

-- ────────────────────────────────────────────────────────────
-- SECTION 2 : COLONNES (avec type exact, default, nullable)
-- ────────────────────────────────────────────────────────────
SELECT
  '=== COLUMNS ===' AS section,
  c.table_name,
  c.ordinal_position AS pos,
  c.column_name,
  c.data_type,
  c.udt_name,
  c.character_maximum_length AS max_len,
  c.numeric_precision,
  c.numeric_scale,
  c.is_nullable,
  c.column_default,
  c.identity_generation
FROM information_schema.columns c
WHERE c.table_schema = 'public'
ORDER BY c.table_name, c.ordinal_position;

-- ────────────────────────────────────────────────────────────
-- SECTION 3 : INDEX (nom, table, colonnes, unique, partial)
-- ────────────────────────────────────────────────────────────
SELECT
  '=== INDEXES ===' AS section,
  t.relname          AS table_name,
  i.relname          AS index_name,
  ix.indisunique     AS is_unique,
  ix.indisprimary    AS is_primary,
  pg_get_indexdef(ix.indexrelid) AS index_definition
FROM pg_index ix
JOIN pg_class t  ON t.oid  = ix.indrelid
JOIN pg_class i  ON i.oid  = ix.indexrelid
JOIN pg_namespace n ON n.oid = t.relnamespace
WHERE n.nspname = 'public'
ORDER BY t.relname, i.relname;

-- ────────────────────────────────────────────────────────────
-- SECTION 4 : CONTRAINTES (PK, UNIQUE, CHECK, FK)
-- ────────────────────────────────────────────────────────────
SELECT
  '=== CONSTRAINTS ===' AS section,
  tc.table_name,
  tc.constraint_name,
  tc.constraint_type,
  kcu.column_name,
  ccu.table_name  AS foreign_table,
  ccu.column_name AS foreign_column,
  cc.check_clause
FROM information_schema.table_constraints tc
LEFT JOIN information_schema.key_column_usage kcu
       ON kcu.constraint_name = tc.constraint_name
      AND kcu.table_schema    = tc.table_schema
LEFT JOIN information_schema.constraint_column_usage ccu
       ON ccu.constraint_name = tc.constraint_name
      AND ccu.table_schema    = tc.table_schema
      AND tc.constraint_type  = 'FOREIGN KEY'
LEFT JOIN information_schema.check_constraints cc
       ON cc.constraint_name  = tc.constraint_name
      AND cc.constraint_schema = tc.table_schema
WHERE tc.table_schema = 'public'
ORDER BY tc.table_name, tc.constraint_type, tc.constraint_name, kcu.ordinal_position;

-- ────────────────────────────────────────────────────────────
-- SECTION 5 : TRIGGERS
-- ────────────────────────────────────────────────────────────
SELECT
  '=== TRIGGERS ===' AS section,
  t.trigger_name,
  t.event_object_table  AS table_name,
  t.event_manipulation  AS event,
  t.action_timing       AS timing,
  t.action_orientation  AS orientation,
  t.action_statement    AS definition
FROM information_schema.triggers t
WHERE t.trigger_schema = 'public'
ORDER BY t.event_object_table, t.trigger_name;

-- ────────────────────────────────────────────────────────────
-- SECTION 6 : POLITIQUES RLS
-- ────────────────────────────────────────────────────────────
SELECT
  '=== RLS POLICIES ===' AS section,
  schemaname,
  tablename,
  policyname,
  permissive,
  roles,
  cmd,
  qual         AS using_expr,
  with_check   AS with_check_expr
FROM pg_policies
WHERE schemaname = 'public'
ORDER BY tablename, policyname;

-- ────────────────────────────────────────────────────────────
-- SECTION 7 : FONCTIONS / RPCs (publiques, non-système)
-- ────────────────────────────────────────────────────────────
SELECT
  '=== FUNCTIONS ===' AS section,
  p.proname           AS function_name,
  pg_get_function_arguments(p.oid) AS arguments,
  pg_get_function_result(p.oid)    AS return_type,
  l.lanname           AS language,
  p.prosecdef         AS security_definer,
  LEFT(pg_get_functiondef(p.oid), 200) AS body_preview
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
JOIN pg_language  l ON l.oid = p.prolang
WHERE n.nspname = 'public'
  AND p.prokind = 'f'
  AND l.lanname IN ('plpgsql','sql')
ORDER BY p.proname;

-- ────────────────────────────────────────────────────────────
-- SECTION 8 : RÉSUMÉ JSON COMPACT PAR TABLE
-- (format idéal pour diff automatisé)
-- ────────────────────────────────────────────────────────────
SELECT
  '=== JSON SCHEMA SUMMARY ===' AS section,
  table_name,
  jsonb_agg(
    jsonb_build_object(
      'pos',     ordinal_position,
      'col',     column_name,
      'type',    udt_name,
      'notnull', is_nullable = 'NO',
      'default', column_default
    )
    ORDER BY ordinal_position
  ) AS columns_json
FROM information_schema.columns
WHERE table_schema = 'public'
GROUP BY table_name
ORDER BY table_name;

-- ────────────────────────────────────────────────────────────
-- SECTION 9 : COMPTEURS DE SYNTHÈSE
-- ────────────────────────────────────────────────────────────
SELECT '=== SUMMARY ===' AS section,
  (SELECT count(*) FROM information_schema.tables
   WHERE table_schema='public' AND table_type='BASE TABLE')   AS total_tables,
  (SELECT count(*) FROM information_schema.columns
   WHERE table_schema='public')                               AS total_columns,
  (SELECT count(*) FROM pg_indexes
   WHERE schemaname='public')                                 AS total_indexes,
  (SELECT count(*) FROM pg_policies
   WHERE schemaname='public')                                 AS total_policies,
  (SELECT count(*) FROM information_schema.triggers
   WHERE trigger_schema='public')                             AS total_triggers,
  (SELECT count(*) FROM pg_proc p
   JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public' AND p.prokind='f')                AS total_functions;
