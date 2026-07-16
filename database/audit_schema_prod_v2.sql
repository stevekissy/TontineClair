-- ============================================================
-- TontineClair — audit_schema_prod_v2.sql
-- Audit schéma production — VERSION 2 (résultat unique)
--
-- PROBLÈME avec v1 : le SQL Editor Supabase n'exporte que le
-- DERNIER résultat d'un script multi-requêtes en CSV.
-- v1 avait 9 SELECT séparés → seul le dernier (compteurs) était
-- visible dans l'export CSV.
--
-- SOLUTION v2 : UN SEUL SELECT avec colonne "section" pour
-- distinguer les types de lignes. Exportable en un clic CSV.
--
-- UTILISATION :
--   Supabase → SQL Editor → New query → Coller ce fichier
--   → Run → Download CSV (bouton en haut à droite des résultats)
--   → Envoyer le CSV à l'agent
--
-- CE SCRIPT :
--   ✅ Ne modifie rien (SELECT uniquement — aucun DDL)
--   ✅ UN seul résultat → export CSV complet en un clic
--   ✅ Couvre : tables, colonnes, index, contraintes,
--              triggers, RLS, fonctions
-- ============================================================

SELECT
  section,
  tbl,
  col1,
  col2,
  col3,
  col4,
  col5,
  col6,
  col7,
  col8
FROM (

  -- ─────────────────────────────────────────────────────────
  -- SECTION 1 : TABLES
  -- col1=table_name  col2=rls_on  col3=table_type
  -- ─────────────────────────────────────────────────────────
  SELECT
    'TABLE'                                                    AS section,
    t.table_name                                               AS tbl,
    t.table_name                                               AS col1,
    CASE WHEN c.relrowsecurity THEN 'RLS=ON' ELSE 'RLS=OFF' END AS col2,
    t.table_type                                               AS col3,
    NULL::TEXT                                                 AS col4,
    NULL::TEXT                                                 AS col5,
    NULL::TEXT                                                 AS col6,
    NULL::TEXT                                                 AS col7,
    NULL::TEXT                                                 AS col8
  FROM information_schema.tables t
  JOIN pg_class c ON c.relname = t.table_name
    AND c.relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public')
  WHERE t.table_schema = 'public'
    AND t.table_type   = 'BASE TABLE'

  UNION ALL

  -- ─────────────────────────────────────────────────────────
  -- SECTION 2 : COLONNES
  -- col1=table  col2=pos  col3=column_name  col4=udt_type
  -- col5=nullable  col6=default  col7=identity
  -- ─────────────────────────────────────────────────────────
  SELECT
    'COLUMN'                                AS section,
    c.table_name                            AS tbl,
    c.table_name                            AS col1,
    c.ordinal_position::TEXT                AS col2,
    c.column_name                           AS col3,
    c.udt_name                              AS col4,
    c.is_nullable                           AS col5,
    LEFT(COALESCE(c.column_default,''),120) AS col6,
    COALESCE(c.identity_generation,'')      AS col7,
    NULL::TEXT                              AS col8
  FROM information_schema.columns c
  WHERE c.table_schema = 'public'

  UNION ALL

  -- ─────────────────────────────────────────────────────────
  -- SECTION 3 : INDEX
  -- col1=table  col2=index_name  col3=unique  col4=primary
  -- col5=definition (truncated)
  -- ─────────────────────────────────────────────────────────
  SELECT
    'INDEX'                                          AS section,
    t.relname                                        AS tbl,
    t.relname                                        AS col1,
    i.relname                                        AS col2,
    ix.indisunique::TEXT                             AS col3,
    ix.indisprimary::TEXT                            AS col4,
    LEFT(pg_get_indexdef(ix.indexrelid), 200)        AS col5,
    NULL::TEXT                                       AS col6,
    NULL::TEXT                                       AS col7,
    NULL::TEXT                                       AS col8
  FROM pg_index ix
  JOIN pg_class     t ON t.oid = ix.indrelid
  JOIN pg_class     i ON i.oid = ix.indexrelid
  JOIN pg_namespace n ON n.oid = t.relnamespace
  WHERE n.nspname = 'public'

  UNION ALL

  -- ─────────────────────────────────────────────────────────
  -- SECTION 4 : CONTRAINTES
  -- col1=table  col2=constraint_name  col3=type  col4=column
  -- col5=foreign_table  col6=foreign_col  col7=check_clause
  -- ─────────────────────────────────────────────────────────
  SELECT
    'CONSTRAINT'                                AS section,
    tc.table_name                               AS tbl,
    tc.table_name                               AS col1,
    tc.constraint_name                          AS col2,
    tc.constraint_type                          AS col3,
    COALESCE(kcu.column_name,'')                AS col4,
    COALESCE(ccu.table_name,'')                 AS col5,
    COALESCE(ccu.column_name,'')                AS col6,
    COALESCE(LEFT(cc.check_clause,120),'')      AS col7,
    NULL::TEXT                                  AS col8
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

  UNION ALL

  -- ─────────────────────────────────────────────────────────
  -- SECTION 5 : TRIGGERS
  -- col1=trigger_name  col2=table  col3=event  col4=timing
  -- col5=orientation  col6=definition
  -- ─────────────────────────────────────────────────────────
  SELECT
    'TRIGGER'                                   AS section,
    t.event_object_table                        AS tbl,
    t.trigger_name                              AS col1,
    t.event_object_table                        AS col2,
    t.event_manipulation                        AS col3,
    t.action_timing                             AS col4,
    t.action_orientation                        AS col5,
    LEFT(t.action_statement, 120)               AS col6,
    NULL::TEXT                                  AS col7,
    NULL::TEXT                                  AS col8
  FROM information_schema.triggers t
  WHERE t.trigger_schema = 'public'

  UNION ALL

  -- ─────────────────────────────────────────────────────────
  -- SECTION 6 : POLITIQUES RLS
  -- col1=table  col2=policyname  col3=cmd  col4=roles
  -- col5=permissive  col6=using  col7=with_check
  -- ─────────────────────────────────────────────────────────
  SELECT
    'RLS_POLICY'                                AS section,
    tablename                                   AS tbl,
    tablename                                   AS col1,
    policyname                                  AS col2,
    cmd                                         AS col3,
    array_to_string(roles,',')                  AS col4,
    permissive                                  AS col5,
    LEFT(COALESCE(qual,''),120)                 AS col6,
    LEFT(COALESCE(with_check,''),120)           AS col7,
    NULL::TEXT                                  AS col8
  FROM pg_policies
  WHERE schemaname = 'public'

  UNION ALL

  -- ─────────────────────────────────────────────────────────
  -- SECTION 7 : FONCTIONS / RPCs
  -- col1=function_name  col2=return_type  col3=language
  -- col4=security_definer  col5=args_preview
  -- ─────────────────────────────────────────────────────────
  SELECT
    'FUNCTION'                                             AS section,
    p.proname                                              AS tbl,
    p.proname                                              AS col1,
    pg_get_function_result(p.oid)                          AS col2,
    l.lanname                                              AS col3,
    p.prosecdef::TEXT                                      AS col4,
    LEFT(pg_get_function_arguments(p.oid), 120)            AS col5,
    NULL::TEXT                                             AS col6,
    NULL::TEXT                                             AS col7,
    NULL::TEXT                                             AS col8
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  JOIN pg_language  l ON l.oid = p.prolang
  WHERE n.nspname = 'public'
    AND p.prokind  = 'f'
    AND l.lanname IN ('plpgsql','sql')

  UNION ALL

  -- ─────────────────────────────────────────────────────────
  -- SECTION 8 : COMPTEURS DE SYNTHÈSE (1 ligne)
  -- ─────────────────────────────────────────────────────────
  SELECT
    'SUMMARY'                                                          AS section,
    'counts'                                                           AS tbl,
    (SELECT count(*)::TEXT FROM information_schema.tables
     WHERE table_schema='public' AND table_type='BASE TABLE')          AS col1,  -- total_tables
    (SELECT count(*)::TEXT FROM information_schema.columns
     WHERE table_schema='public')                                       AS col2,  -- total_columns
    (SELECT count(*)::TEXT FROM pg_indexes WHERE schemaname='public')  AS col3,  -- total_indexes
    (SELECT count(*)::TEXT FROM pg_policies WHERE schemaname='public') AS col4,  -- total_policies
    (SELECT count(*)::TEXT FROM information_schema.triggers
     WHERE trigger_schema='public')                                     AS col5,  -- total_triggers
    (SELECT count(*)::TEXT FROM pg_proc p
     JOIN pg_namespace n ON n.oid=p.pronamespace
     WHERE n.nspname='public' AND p.prokind='f')                        AS col6,  -- total_functions
    NULL::TEXT                                                          AS col7,
    NULL::TEXT                                                          AS col8

) sub
ORDER BY
  CASE section
    WHEN 'TABLE'      THEN 1
    WHEN 'COLUMN'     THEN 2
    WHEN 'INDEX'      THEN 3
    WHEN 'CONSTRAINT' THEN 4
    WHEN 'TRIGGER'    THEN 5
    WHEN 'RLS_POLICY' THEN 6
    WHEN 'FUNCTION'   THEN 7
    WHEN 'SUMMARY'    THEN 8
  END,
  tbl,
  col2;

-- ============================================================
-- INSTRUCTIONS :
--   1. Coller ce fichier dans Supabase → SQL Editor → Run
--   2. Attendre la fin de l'exécution (peut durer 5-10 sec
--      selon le nombre de fonctions)
--   3. Cliquer sur le bouton "Download CSV" en haut à droite
--      du tableau de résultats (icône téléchargement)
--   4. Envoyer le fichier CSV téléchargé à l'agent
--
-- Le CSV contiendra TOUTES les sections en un seul fichier :
--   - Lignes section=TABLE      → liste des tables
--   - Lignes section=COLUMN     → colonnes par table
--   - Lignes section=INDEX      → index par table
--   - Lignes section=CONSTRAINT → contraintes
--   - Lignes section=TRIGGER    → triggers (déjà connu : 1)
--   - Lignes section=RLS_POLICY → politiques RLS
--   - Lignes section=FUNCTION   → fonctions/RPCs
--   - Ligne  section=SUMMARY    → compteurs totaux
-- ============================================================
