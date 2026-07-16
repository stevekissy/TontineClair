-- =============================================================================
-- TontineClair — init.sql  (Master Bootstrap Script)
-- =============================================================================
-- Usage (psql ou Supabase SQL Editor) :
--
--   psql postgresql://<user>:<pass>@<host>/<db> -f database/init.sql
--
--   OU dans Supabase SQL Editor (copier-coller le contenu complet) :
--   Les \i ne fonctionnent pas dans l'éditeur web → utiliser le script
--   database/init_inline.sql généré par : cat migrations/*.sql > init_inline.sql
--
-- Ce script reconstruit entièrement la base TontineClair depuis zéro.
-- Toutes les migrations sont idempotentes (CREATE IF NOT EXISTS, OR REPLACE).
--
-- Ordre d'exécution OBLIGATOIRE (dépendances inter-migrations) :
--   001 → Tables core (tontines, config, app_config, admin_config, audit)
--   002 → Tables scores & audit (scores_historique, propositions_retrait, journal_audit)
--   003 → Tables financier (subscriptions, abonnements, sycapay_transactions, prets_pending, …)
--   004 → Tables KYC & notifs (kyc_submissions, fcm_tokens, rappels_envoyes)
--   005 → Tables admin team & support (admin_membres, admin_messages, support_tickets, …)
--   006 → RPCs tontines core (lire_tontine, ecrire_tontine, voter, cloturer_tour, …)
--   007 → RPCs scores & audit (enregistrer_score, modifier_score_membre v14-FINAL, …)
--   008 → RPCs admin dashboard (admin_lister_tontines v17, admin_alertes v1.2, …)
--   009 → RPCs financier & support (abonnements, prêts, décaissements, KYC, team, …)
--   010 → RPCs notifications & SycaPay (sauvegarder_token, crediter_* sycapay, …)
-- =============================================================================

\echo '============================================================'
\echo 'TontineClair — Reconstruction base Supabase'
\echo 'Début : ' :DATESTRING
\echo '============================================================'
\echo ''

-- =============================================================================
-- PHASE 1 — TABLES (migrations 001–005)
-- =============================================================================

\echo '--- [001/010] Tables core (tontines, config, audit) ---'
\i migrations/001_tables_core.sql

\echo ''
\echo '--- [002/010] Tables scores & audit ---'
\i migrations/002_tables_scores_audit.sql

\echo ''
\echo '--- [003/010] Tables financier (sycapay, prêts, abonnements) ---'
\i migrations/003_tables_financier.sql

\echo ''
\echo '--- [004/010] Tables KYC & notifications FCM ---'
\i migrations/004_tables_kyc_notifs.sql

\echo ''
\echo '--- [005/010] Tables admin team & support tickets ---'
\i migrations/005_tables_admin_team_support.sql

-- =============================================================================
-- PHASE 2 — FONCTIONS ET RPC (migrations 006–010)
-- =============================================================================

\echo ''
\echo '--- [006/010] RPCs tontines core (lire_tontine, voter, cloturer_tour, …) ---'
\i migrations/006_rpcs_tontines_core.sql

\echo ''
\echo '--- [007/010] RPCs scores & audit (enregistrer_score, modifier_score_membre, …) ---'
\i migrations/007_rpcs_scores_audit.sql

\echo ''
\echo '--- [008/010] RPCs admin dashboard (admin_lister_tontines, admin_alertes, …) ---'
\i migrations/008_rpcs_admin.sql

\echo ''
\echo '--- [009/010] RPCs financier & support (abonnements, prêts, KYC, team, …) ---'
\i migrations/009_rpcs_financier_support.sql

\echo ''
\echo '--- [010/010] RPCs notifications & SycaPay (sauvegarder_token, crediter_*, …) ---'
\i migrations/010_rpcs_notifs_sycapay.sql

-- =============================================================================
-- PHASE 3 — VÉRIFICATION FINALE
-- =============================================================================

\echo ''
\echo '============================================================'
\echo 'Vérification finale — Comptage des objets créés'
\echo '============================================================'

-- Nombre de tables créées
SELECT
  'Tables créées' AS objet,
  COUNT(*)::text  AS compte
FROM information_schema.tables
WHERE table_schema = 'public'
  AND table_type = 'BASE TABLE'
  AND table_name IN (
    -- 001 core
    'tontines', 'audit_log', 'demandes_premium', 'config', 'app_config', 'admin_config',
    -- 002 scores
    'scores_historique', 'propositions_retrait', 'journal_audit',
    -- 003 financier
    'subscriptions', 'abonnements', 'admin_actions', 'sycapay_transactions',
    'prets_pending', 'decaissements_pending', 'depenses_pending', 'premium_requests',
    -- 004 kyc/notifs
    'kyc_submissions', 'fcm_tokens', 'rappels_envoyes',
    -- 005 admin team
    'admin_membres', 'admin_messages', 'support_tickets', 'support_messages'
  )

UNION ALL

-- Nombre de fonctions créées
SELECT
  'Fonctions RPC créées',
  COUNT(*)::text
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN (
    -- 006 tontines core (17)
    '_tc_nom_membre', 'lire_tontine', 'ecrire_tontine_sans_pin', 'verifier_gestionnaire',
    'check_invitation_code', 'join_tontine_by_code', 'delete_tontine', 'restore_deleted_tontine',
    'maj_echeance', 'lire_config_tontine', 'voter', 'cloturer_tour',
    'proposer_nouveau_cycle', 'lire_etat_cycle', 'clore_vote_redemarrage',
    'demarrer_nouveau_cycle', 'demander_premium',
    -- 007 scores (11)
    'enregistrer_score', 'lire_historique_score', 'lire_scores_tontine',
    'proposer_retrait', 'lire_propositions_retrait', 'maj_statut_retrait',
    'lire_journal_audit', 'init_score_membre',
    'modifier_score_membre', 'lire_score_membre', 'reinitialiser_score_override',
    -- 008 admin (14)
    '_verif_admin_cle', 'admin_stats_globales', 'admin_dashboard_tontines',
    'admin_lister_abonnements', 'admin_alertes', 'admin_enregistrer_abonnement',
    'admin_stats_mensuelles', 'admin_top_tontines', 'admin_tontine_counts',
    'admin_lister_tontines', 'admin_lister_demandes', 'admin_activer_premium',
    'admin_refuser_demande',
    -- 009 financier & support (31)
    'est_premium', 'lire_abonnement_tontine', 'verif_limite_tontines',
    'verif_limite_membres', 'enregistrer_abonnement_web', 'expirer_abonnements_obsoletes',
    'admin_valider_pret', 'admin_rejeter_pret', 'crediter_remboursement_sycapay',
    'admin_lister_decaissements', 'admin_valider_decaissement', 'admin_rejeter_decaissement',
    'admin_valider_depense', 'admin_rejeter_depense',
    'admin_lister_kyc', 'admin_valider_kyc', 'admin_rejeter_kyc',
    'admin_lister_membres', 'admin_creer_membre', 'admin_modifier_membre', 'admin_auth_membre',
    'admin_lister_messages', 'admin_envoyer_message', 'admin_marquer_lu', 'admin_compter_non_lus',
    'generer_ref_ticket', 'support_ouvrir_ticket', 'support_mes_tickets',
    'admin_lister_tickets', 'support_messages_ticket', 'support_repondre',
    'admin_changer_statut_ticket',
    -- 010 notifs & sycapay (8)
    'sauvegarder_token', 'creer_transaction_sycapay', 'get_pending_sycapay_transactions',
    'crediter_caisse_sycapay', 'crediter_cotisation_sycapay', 'crediter_penalite_sycapay',
    'recalculer_echeances_expir', 'distribuer_tour'
  )

UNION ALL

-- Triggers actifs
SELECT
  'Triggers actifs',
  COUNT(*)::text
FROM information_schema.triggers
WHERE trigger_schema = 'public'
  AND trigger_name IN ('tontines_set_updated_at', 'sub_update_modifie_le');

-- Détail des tables avec leur nombre de colonnes
\echo ''
\echo '--- Détail des tables (colonnes) ---'
SELECT
  table_name            AS "Table",
  COUNT(column_name)    AS "Nb colonnes"
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name IN (
    'tontines', 'audit_log', 'demandes_premium', 'config', 'app_config', 'admin_config',
    'scores_historique', 'propositions_retrait', 'journal_audit',
    'subscriptions', 'abonnements', 'admin_actions', 'sycapay_transactions',
    'prets_pending', 'decaissements_pending', 'depenses_pending', 'premium_requests',
    'kyc_submissions', 'fcm_tokens', 'rappels_envoyes',
    'admin_membres', 'admin_messages', 'support_tickets', 'support_messages'
  )
GROUP BY table_name
ORDER BY table_name;

-- Vérifier les index essentiels
\echo ''
\echo '--- Index critiques ---'
SELECT
  indexname   AS "Index",
  tablename   AS "Table"
FROM pg_indexes
WHERE schemaname = 'public'
  AND indexname IN (
    'idx_tontines_code', 'idx_tontines_status',
    'idx_scores_historique_tontine', 'idx_scores_historique_membre',
    'idx_sycapay_txn_reference', 'idx_sycapay_txn_status',
    'idx_prets_pending_code', 'idx_kyc_user_id',
    'idx_fcm_tokens_tontine_code', 'idx_admin_membres_email'
  )
ORDER BY tablename, indexname;

\echo ''
\echo '============================================================'
\echo '✅  Reconstruction TontineClair terminée avec succès.'
\echo '    20 tables  |  80+ fonctions RPC  |  2 triggers'
\echo '============================================================'
