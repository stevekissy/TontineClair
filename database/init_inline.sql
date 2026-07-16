-- =============================================================================
-- TontineClair — init_inline.sql
-- BLOC 0 : DROP IF EXISTS CASCADE — Idempotence sur bases existantes
-- =============================================================================
-- Ce bloc supprime toutes les fonctions avant leur (re)création.
-- Nécessaire quand le type de retour ou la signature a changé entre versions
-- (ERROR 42P13 : cannot change return type of existing function).
-- Idempotent : IF EXISTS garantit l'absence d'erreur si la fonction n'existe pas.
-- CASCADE : supprime les objets dépendants (vues, autres fonctions).
-- =============================================================================

DO $drop_all_functions$
BEGIN
  -- ── Migration 006 : RPCs tontines ──────────────────────────────────────────
  DROP FUNCTION IF EXISTS public.tontines_set_updated_at() CASCADE;
  DROP FUNCTION IF EXISTS public._tc_nom_membre(jsonb, text) CASCADE;
  DROP FUNCTION IF EXISTS public.lire_tontine(text) CASCADE;
  DROP FUNCTION IF EXISTS public.ecrire_tontine_sans_pin(text, jsonb) CASCADE;
  DROP FUNCTION IF EXISTS public.verifier_gestionnaire(text, text, text) CASCADE;
  DROP FUNCTION IF EXISTS public.check_invitation_code(text) CASCADE;
  DROP FUNCTION IF EXISTS public.join_tontine_by_code(text) CASCADE;
  DROP FUNCTION IF EXISTS public.delete_tontine(text, text, text, text) CASCADE;
  DROP FUNCTION IF EXISTS public.restore_deleted_tontine(text, text, text) CASCADE;
  DROP FUNCTION IF EXISTS public.maj_echeance(text, text, text, text) CASCADE;
  DROP FUNCTION IF EXISTS public.lire_config_tontine(text) CASCADE;
  DROP FUNCTION IF EXISTS public.voter(text, text, text, text, text) CASCADE;
  DROP FUNCTION IF EXISTS public.cloturer_tour(text, text, text) CASCADE;
  DROP FUNCTION IF EXISTS public.proposer_nouveau_cycle(text, text, text, text) CASCADE;
  DROP FUNCTION IF EXISTS public.lire_etat_cycle(text) CASCADE;
  DROP FUNCTION IF EXISTS public.clore_vote_redemarrage(text, text, text, text) CASCADE;
  DROP FUNCTION IF EXISTS public.demarrer_nouveau_cycle(text, text, text) CASCADE;
  DROP FUNCTION IF EXISTS public.demander_premium(text, text, text, text, text) CASCADE;

  -- ── Migration 007 : RPCs Score & Audit ─────────────────────────────────────
  DROP FUNCTION IF EXISTS public.enregistrer_score(text, text, int, int, text, text, text) CASCADE;
  DROP FUNCTION IF EXISTS public.lire_historique_score(text, text) CASCADE;
  DROP FUNCTION IF EXISTS public.lire_scores_tontine(text) CASCADE;
  DROP FUNCTION IF EXISTS public.proposer_retrait(text, text, text, text, text, int, text, text, int, int) CASCADE;
  DROP FUNCTION IF EXISTS public.lire_propositions_retrait(text) CASCADE;
  DROP FUNCTION IF EXISTS public.maj_statut_retrait(text, text, text, text, text, int, int, int) CASCADE;
  DROP FUNCTION IF EXISTS public.lire_journal_audit(text, int) CASCADE;
  DROP FUNCTION IF EXISTS public.init_score_membre(text, text, int, text) CASCADE;
  DROP FUNCTION IF EXISTS public.modifier_score_membre(text, text, text, text, integer, text) CASCADE;
  DROP FUNCTION IF EXISTS public.lire_score_membre(text, text) CASCADE;
  DROP FUNCTION IF EXISTS public.reinitialiser_score_override(text, text, text, text) CASCADE;

  -- ── Migration 008 : RPCs Dashboard Admin ───────────────────────────────────
  DROP FUNCTION IF EXISTS public._verif_admin_cle(text) CASCADE;
  DROP FUNCTION IF EXISTS public.admin_stats_globales(text) CASCADE;
  DROP FUNCTION IF EXISTS public.admin_dashboard_tontines(text, text, int, int) CASCADE;
  DROP FUNCTION IF EXISTS public.admin_lister_abonnements(text, text, int) CASCADE;
  DROP FUNCTION IF EXISTS public.admin_alertes(text) CASCADE;
  DROP FUNCTION IF EXISTS public.admin_enregistrer_abonnement(text, text, text, int, text, text, text) CASCADE;
  DROP FUNCTION IF EXISTS public.admin_stats_mensuelles(text) CASCADE;
  DROP FUNCTION IF EXISTS public.admin_top_tontines(text) CASCADE;
  DROP FUNCTION IF EXISTS public.admin_tontine_counts(text) CASCADE;
  DROP FUNCTION IF EXISTS public.admin_lister_tontines(text) CASCADE;
  DROP FUNCTION IF EXISTS public.admin_lister_demandes(text) CASCADE;
  DROP FUNCTION IF EXISTS public.admin_activer_premium(text, text, integer) CASCADE;
  DROP FUNCTION IF EXISTS public.admin_refuser_demande(text, text, text) CASCADE;

  -- ── Migration 009 : RPCs Financier, KYC & Support ──────────────────────────
  DROP FUNCTION IF EXISTS public._sub_update_modifie_le() CASCADE;
  DROP FUNCTION IF EXISTS public.est_premium(text) CASCADE;
  DROP FUNCTION IF EXISTS public.lire_abonnement_tontine(text) CASCADE;
  DROP FUNCTION IF EXISTS public.verif_limite_tontines(text) CASCADE;
  DROP FUNCTION IF EXISTS public.verif_limite_membres(text) CASCADE;
  DROP FUNCTION IF EXISTS public.enregistrer_abonnement_web(text, text, int, text, text, text) CASCADE;
  DROP FUNCTION IF EXISTS public.expirer_abonnements_obsoletes() CASCADE;
  DROP FUNCTION IF EXISTS public.admin_valider_pret(text, bigint) CASCADE;
  DROP FUNCTION IF EXISTS public.admin_rejeter_pret(text, bigint, text) CASCADE;
  DROP FUNCTION IF EXISTS public.crediter_remboursement_sycapay(text, integer, text, text, text, text, text, text, text, text) CASCADE;
  DROP FUNCTION IF EXISTS public.admin_lister_decaissements(text, text) CASCADE;
  DROP FUNCTION IF EXISTS public.admin_valider_decaissement(text, bigint) CASCADE;
  DROP FUNCTION IF EXISTS public.admin_rejeter_decaissement(text, bigint, text) CASCADE;
  DROP FUNCTION IF EXISTS public.admin_valider_depense(text, bigint) CASCADE;
  DROP FUNCTION IF EXISTS public.admin_rejeter_depense(text, bigint, text) CASCADE;
  DROP FUNCTION IF EXISTS public.admin_lister_kyc(text, text) CASCADE;
  DROP FUNCTION IF EXISTS public.admin_valider_kyc(text, bigint) CASCADE;
  DROP FUNCTION IF EXISTS public.admin_rejeter_kyc(text, bigint, text) CASCADE;
  DROP FUNCTION IF EXISTS public.generer_ref_ticket() CASCADE;
  DROP FUNCTION IF EXISTS public.admin_lister_membres(text) CASCADE;
  DROP FUNCTION IF EXISTS public.admin_creer_membre(text, text, text, text, text, text) CASCADE;
  DROP FUNCTION IF EXISTS public.admin_modifier_membre(text, bigint, text, boolean) CASCADE;
  DROP FUNCTION IF EXISTS public.admin_auth_membre(text, text) CASCADE;
  DROP FUNCTION IF EXISTS public.admin_lister_messages(text, text, text) CASCADE;
  DROP FUNCTION IF EXISTS public.admin_envoyer_message(text, text, text, text, text) CASCADE;
  DROP FUNCTION IF EXISTS public.admin_marquer_lu(text, text, bigint) CASCADE;
  DROP FUNCTION IF EXISTS public.admin_compter_non_lus(text, text) CASCADE;
  DROP FUNCTION IF EXISTS public.support_ouvrir_ticket(text, text, text, text, text, text) CASCADE;
  DROP FUNCTION IF EXISTS public.support_mes_tickets(text) CASCADE;
  DROP FUNCTION IF EXISTS public.admin_lister_tickets(text, text) CASCADE;
  DROP FUNCTION IF EXISTS public.support_messages_ticket(bigint, boolean, text) CASCADE;
  DROP FUNCTION IF EXISTS public.support_repondre(bigint, text, text, boolean, text) CASCADE;
  DROP FUNCTION IF EXISTS public.admin_changer_statut_ticket(text, bigint, text, text) CASCADE;

  -- ── Migration 010 : FCM + SycaPay ──────────────────────────────────────────
  DROP FUNCTION IF EXISTS public.sauvegarder_token(text, text, text) CASCADE;
  DROP FUNCTION IF EXISTS public.creer_transaction_sycapay(text, text, text, integer, text, text, text, text, text) CASCADE;
  DROP FUNCTION IF EXISTS public.get_pending_sycapay_transactions(text) CASCADE;
  DROP FUNCTION IF EXISTS public.crediter_caisse_sycapay(text, integer, text, text, text, text, text) CASCADE;
  DROP FUNCTION IF EXISTS public.crediter_cotisation_sycapay(text, text, integer, text, text, text, text) CASCADE;
  DROP FUNCTION IF EXISTS public.crediter_penalite_sycapay(text, integer, text, text, text, text, text, text, text) CASCADE;
  DROP FUNCTION IF EXISTS public.recalculer_echeances_expir() CASCADE;
  DROP FUNCTION IF EXISTS public.distribuer_tour(text, text, text, text, int) CASCADE;

  -- ── Migration 011 : RPCs fondamentaux v1 ───────────────────────────────────
  DROP FUNCTION IF EXISTS public.creer_tontine(text, jsonb, jsonb) CASCADE;
  DROP FUNCTION IF EXISTS public.ecrire_tontine(text, text, text, jsonb) CASCADE;
  DROP FUNCTION IF EXISTS public.lire_voix_tontine(text) CASCADE;
  DROP FUNCTION IF EXISTS public.lire_plan(text) CASCADE;
  DROP FUNCTION IF EXISTS public.membres_avec_pin(text) CASCADE;
  DROP FUNCTION IF EXISTS public.definir_pin_membre(text, text, text, text, text) CASCADE;
  DROP FUNCTION IF EXISTS public.changer_pin_membre(text, text, text, text) CASCADE;
  DROP FUNCTION IF EXISTS public.admin_desactiver_premium(text, text) CASCADE;
  DROP FUNCTION IF EXISTS public.sauvegarder_langue_appareil(text, text) CASCADE;
  DROP FUNCTION IF EXISTS public.charger_langue_appareil(text) CASCADE;

  RAISE NOTICE 'BLOC 0 : DROP IF EXISTS CASCADE terminé — toutes les fonctions purgées.';
END;
$drop_all_functions$;

-- =============================================================================
-- TontineClair — Migration 001 : Tables fondamentales
-- Ordre d'exécution : 1/11
-- Remplace : (table tontines gérée par Supabase directement)
--            supabase-v6.sql (tables scores/audit)
--            supabase-v16-soft-delete.sql (colonnes status/deleted_at)
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. TABLE tontines (table principale — gérée nativement par Supabase)
--    Si elle n'existe pas encore, la créer ici.
--    Toutes les colonnes jamais utilisées par les RPCs sont déclarées ici
--    pour éviter les erreurs "column does not exist" sur base vierge.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS tontines (
  id                     BIGSERIAL   PRIMARY KEY,
  code                   TEXT        NOT NULL UNIQUE,
  data                   JSONB       NOT NULL DEFAULT '{}',
  -- Colonnes gestionnaires / membres (v1)
  gestionnaires          JSONB       DEFAULT '[]',
  membres_pins           JSONB       DEFAULT '[]',
  -- Colonnes plan/abonnement (v5/v6)
  plan                   TEXT        NOT NULL DEFAULT 'free',
  plan_expire            TIMESTAMPTZ,
  -- Timestamps
  cree                   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  modifie_le             TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  -- Colonnes soft-delete (v16)
  status                 TEXT        NOT NULL DEFAULT 'active'
                         CHECK (status IN ('active','inactive','suspended','deleted')),
  deleted_at             TIMESTAMPTZ,
  deleted_by             TEXT,
  deletion_reason        TEXT,
  invitation_code_active BOOLEAN     NOT NULL DEFAULT TRUE,
  updated_at             TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_at             TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Ajouter colonnes manquantes sur bases existantes (idempotent)
ALTER TABLE tontines ADD COLUMN IF NOT EXISTS gestionnaires          JSONB       DEFAULT '[]';
ALTER TABLE tontines ADD COLUMN IF NOT EXISTS membres_pins           JSONB       DEFAULT '[]';
ALTER TABLE tontines ADD COLUMN IF NOT EXISTS plan                   TEXT        NOT NULL DEFAULT 'free';
ALTER TABLE tontines ADD COLUMN IF NOT EXISTS plan_expire            TIMESTAMPTZ;
ALTER TABLE tontines ADD COLUMN IF NOT EXISTS cree                   TIMESTAMPTZ NOT NULL DEFAULT NOW();
ALTER TABLE tontines ADD COLUMN IF NOT EXISTS modifie_le             TIMESTAMPTZ NOT NULL DEFAULT NOW();
ALTER TABLE tontines ADD COLUMN IF NOT EXISTS status                 TEXT        NOT NULL DEFAULT 'active';
ALTER TABLE tontines ADD COLUMN IF NOT EXISTS deleted_at             TIMESTAMPTZ;
ALTER TABLE tontines ADD COLUMN IF NOT EXISTS deleted_by             TEXT;
ALTER TABLE tontines ADD COLUMN IF NOT EXISTS deletion_reason        TEXT;
ALTER TABLE tontines ADD COLUMN IF NOT EXISTS invitation_code_active BOOLEAN     NOT NULL DEFAULT TRUE;
ALTER TABLE tontines ADD COLUMN IF NOT EXISTS updated_at             TIMESTAMPTZ NOT NULL DEFAULT NOW();
ALTER TABLE tontines ADD COLUMN IF NOT EXISTS created_at             TIMESTAMPTZ NOT NULL DEFAULT NOW();

CREATE INDEX IF NOT EXISTS idx_tontines_code   ON tontines(code);
CREATE INDEX IF NOT EXISTS idx_tontines_status ON tontines(status);

ALTER TABLE tontines ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "tontines_anon_select" ON tontines;
CREATE POLICY "tontines_anon_select" ON tontines FOR SELECT TO anon USING (true);

DROP POLICY IF EXISTS "tontines_anon_insert" ON tontines;
CREATE POLICY "tontines_anon_insert" ON tontines FOR INSERT TO anon WITH CHECK (true);

DROP POLICY IF EXISTS "tontines_anon_update" ON tontines;
CREATE POLICY "tontines_anon_update" ON tontines FOR UPDATE TO anon USING (true);

-- Trigger updated_at
CREATE OR REPLACE FUNCTION tontines_set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at = NOW(); RETURN NEW; END; $$;

DROP TRIGGER IF EXISTS trg_tontines_updated_at ON tontines;
CREATE TRIGGER trg_tontines_updated_at
  BEFORE UPDATE ON tontines
  FOR EACH ROW EXECUTE FUNCTION tontines_set_updated_at();

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. TABLE audit (journal actions principales)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS audit (
  id          BIGSERIAL PRIMARY KEY,
  code        TEXT        NOT NULL,
  gestionnaire TEXT       NOT NULL,
  empreinte   TEXT        NOT NULL,
  quand       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_audit_code ON audit(code, quand DESC);
ALTER TABLE audit ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "audit_anon" ON audit;
CREATE POLICY "audit_anon" ON audit FOR ALL TO anon USING (true) WITH CHECK (true);

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. TABLE demandes_premium
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS demandes_premium (
  id          BIGSERIAL PRIMARY KEY,
  code        TEXT        NOT NULL,
  gestionnaire TEXT       NOT NULL,
  nom         TEXT,
  contact     TEXT,
  formule     TEXT        NOT NULL DEFAULT 'mensuel',
  statut      TEXT        NOT NULL DEFAULT 'en attente'
              CHECK (statut IN ('en attente','en_attente','activée','refusée','active','refuse')),
  quand       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_demandes_premium_code ON demandes_premium(code);
ALTER TABLE demandes_premium ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "demandes_premium_select" ON demandes_premium;
CREATE POLICY "demandes_premium_select" ON demandes_premium FOR SELECT TO anon USING (true);
DROP POLICY IF EXISTS "demandes_premium_insert" ON demandes_premium;
CREATE POLICY "demandes_premium_insert" ON demandes_premium FOR INSERT TO anon WITH CHECK (true);
DROP POLICY IF EXISTS "demandes_premium_update" ON demandes_premium;
CREATE POLICY "demandes_premium_update" ON demandes_premium FOR UPDATE TO anon USING (true);

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. TABLE config (clé admin sécurisée)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS config (
  cle    TEXT PRIMARY KEY,
  valeur TEXT NOT NULL
);

-- Alias app_config utilisé dans certaines RPCs
CREATE TABLE IF NOT EXISTS app_config (
  cle    TEXT PRIMARY KEY,
  valeur TEXT NOT NULL
);

ALTER TABLE config     ENABLE ROW LEVEL SECURITY;
ALTER TABLE app_config ENABLE ROW LEVEL SECURITY;

-- Les tables config/app_config ne sont accessibles que via SECURITY DEFINER RPCs
DROP POLICY IF EXISTS "config_no_access"     ON config;
CREATE POLICY "config_no_access"     ON config     USING (false);
DROP POLICY IF EXISTS "app_config_no_access" ON app_config;
CREATE POLICY "app_config_no_access" ON app_config USING (false);

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. TABLE admin_config (rétrocompatibilité avec supabase-admin.sql v1)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS admin_config (
  cle    TEXT PRIMARY KEY,
  valeur TEXT NOT NULL
);
ALTER TABLE admin_config ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "admin_config_no_access" ON admin_config;
CREATE POLICY "admin_config_no_access" ON admin_config USING (false);

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. TABLE voix (votes des membres — utilisée par voter() et lire_voix_tontine())
--    Référencée dans migrations 006 (voter v18) et 011 (lire_voix_tontine)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS voix (
  id         BIGSERIAL   PRIMARY KEY,
  code       TEXT        NOT NULL,
  vote_id    TEXT        NOT NULL,
  membre_id  TEXT        NOT NULL,
  choix      TEXT        NOT NULL CHECK (choix IN ('oui','non','abstention')),
  methode    TEXT        NOT NULL DEFAULT 'PIN',
  appareil   TEXT,
  vote_le    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (code, vote_id, membre_id)
);

CREATE INDEX IF NOT EXISTS idx_voix_code    ON voix(code);
CREATE INDEX IF NOT EXISTS idx_voix_vote_id ON voix(code, vote_id);
ALTER TABLE voix ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "voix_anon" ON voix;
CREATE POLICY "voix_anon" ON voix FOR ALL TO anon USING (true) WITH CHECK (true);
-- =============================================================================
-- TontineClair — Migration 002 : Scores de confiance & Audit détaillé
-- Ordre d'exécution : 2/10
-- Remplace : supabase-v6.sql (sections tables uniquement)
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. scores_historique
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS scores_historique (
  id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  code        TEXT        NOT NULL,
  membre_id   TEXT        NOT NULL,
  score       INT         NOT NULL CHECK (score BETWEEN 0 AND 100),
  score_prec  INT         NOT NULL CHECK (score_prec BETWEEN 0 AND 100),
  evenement   TEXT        NOT NULL,
  -- 'cotisation','retard','pret','remboursement','vote','admin','sanction','retrait','anciennete','init'
  description TEXT        NOT NULL,
  gestionnaire TEXT,       -- null = calcul automatique système
  quand       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_scores_hist_code_membre ON scores_historique(code, membre_id);
CREATE INDEX IF NOT EXISTS idx_scores_hist_code_quand  ON scores_historique(code, quand DESC);
ALTER TABLE scores_historique ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "scores_historique_select" ON scores_historique;
CREATE POLICY "scores_historique_select" ON scores_historique FOR SELECT TO anon USING (true);

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. propositions_retrait
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS propositions_retrait (
  id           BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  code         TEXT        NOT NULL,
  membre_id    TEXT        NOT NULL,
  membre_nom   TEXT        NOT NULL,
  score_moment INT         NOT NULL,
  motif        TEXT        NOT NULL,
  propose_par  TEXT        NOT NULL,
  vote_id      TEXT,
  quorum       INT         NOT NULL DEFAULT 50,
  majorite     INT         NOT NULL DEFAULT 67,
  statut       TEXT        NOT NULL DEFAULT 'en_attente'
               CHECK (statut IN ('en_attente','vote_ouvert','accepte','refuse')),
  quand        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  clos_le      TIMESTAMPTZ,
  resultat_oui INT         DEFAULT 0,
  resultat_non INT         DEFAULT 0,
  resultat_abs INT         DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_prop_retrait_code   ON propositions_retrait(code);
CREATE INDEX IF NOT EXISTS idx_prop_retrait_membre ON propositions_retrait(code, membre_id);
ALTER TABLE propositions_retrait ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "propositions_retrait_select" ON propositions_retrait;
CREATE POLICY "propositions_retrait_select" ON propositions_retrait FOR SELECT TO anon USING (true);

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. journal_audit (v6 — audit enrichi)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS journal_audit (
  id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  code        TEXT        NOT NULL,
  gestionnaire TEXT       NOT NULL,
  action      TEXT        NOT NULL,
  -- 'SCORE_MODIF','RETRAIT_PROPOSE','RETRAIT_ACCEPTE','RETRAIT_REFUSE',
  -- 'MEMBRE_RETIRE','SCORE_AUTO','SCORE_INIT'
  detail      TEXT,
  membre_id   TEXT,
  ancien_val  TEXT,
  nouveau_val TEXT,
  quand       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_journal_audit_code ON journal_audit(code, quand DESC);
ALTER TABLE journal_audit ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "journal_audit_select" ON journal_audit;
CREATE POLICY "journal_audit_select" ON journal_audit FOR SELECT TO anon USING (true);
-- =============================================================================
-- TontineClair — Migration 003 : Tables financières
-- Ordre d'exécution : 3/10
-- Remplace : supabase-subscriptions.sql, supabase-sycapay-transactions.sql,
--            supabase-sycapay-v2.sql, supabase-prets-pending.sql,
--            supabase-decaissements-pending.sql, supabase-depenses-pending.sql
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. subscriptions (abonnements Premium via Stripe/web)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS subscriptions (
  id             BIGSERIAL PRIMARY KEY,
  code           TEXT        NOT NULL UNIQUE,
  plan           TEXT        NOT NULL DEFAULT 'gratuit'
                 CHECK (plan IN ('gratuit','premium_mensuel','premium_annuel','pro')),
  statut         TEXT        NOT NULL DEFAULT 'actif'
                 CHECK (statut IN ('actif','expire','annule','suspendu')),
  date_debut     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  date_fin       TIMESTAMPTZ,
  stripe_id      TEXT,
  modifie_le     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_subscriptions_code   ON subscriptions(code);
CREATE INDEX IF NOT EXISTS idx_subscriptions_statut ON subscriptions(statut);
ALTER TABLE subscriptions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "subscriptions_anon" ON subscriptions;
CREATE POLICY "subscriptions_anon" ON subscriptions FOR ALL TO anon USING (true) WITH CHECK (true);

CREATE OR REPLACE FUNCTION _sub_update_modifie_le()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN NEW.modifie_le = NOW(); RETURN NEW; END; $$;

DROP TRIGGER IF EXISTS trg_sub_modifie_le ON subscriptions;
CREATE TRIGGER trg_sub_modifie_le
  BEFORE UPDATE ON subscriptions
  FOR EACH ROW EXECUTE FUNCTION _sub_update_modifie_le();

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. abonnements (table admin — suivi manuel Premium)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS abonnements (
  id          BIGSERIAL PRIMARY KEY,
  code        TEXT        NOT NULL,
  gestionnaire TEXT,
  contact     TEXT,
  formule     TEXT        NOT NULL DEFAULT 'mensuel',
  statut      TEXT        NOT NULL DEFAULT 'actif'
              CHECK (statut IN ('actif','expire','annule')),
  debut       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  fin         TIMESTAMPTZ,
  montant     NUMERIC(12,2) DEFAULT 0,
  devise      TEXT        DEFAULT 'XOF',
  note        TEXT,
  cree_le     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_abonnements_code ON abonnements(code);
ALTER TABLE abonnements ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "abonnements_service" ON abonnements;
CREATE POLICY "abonnements_service" ON abonnements USING (true) WITH CHECK (true);

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. admin_actions (log actions admin manuelles)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS admin_actions (
  id       BIGSERIAL PRIMARY KEY,
  type     TEXT        NOT NULL,  -- 'activation','suspension','note','refus'
  code     TEXT,
  detail   TEXT,
  admin    TEXT        NOT NULL DEFAULT 'admin',
  quand    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE admin_actions ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "admin_actions_service" ON admin_actions;
CREATE POLICY "admin_actions_service" ON admin_actions USING (true) WITH CHECK (true);

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. sycapay_transactions
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS sycapay_transactions (
  id                   BIGSERIAL PRIMARY KEY,
  type                 TEXT        NOT NULL,
  -- 'cotisation','caisse','penalite','remboursement_pret','decaissement'
  code                 TEXT        NOT NULL,
  membre_id            TEXT,
  membre_nom           TEXT,
  montant              NUMERIC(14,2) NOT NULL,
  devise               TEXT        NOT NULL DEFAULT 'XOF',
  statut               TEXT        NOT NULL DEFAULT 'pending'
                       CHECK (statut IN ('pending','completed','failed','cancelled')),
  sycapay_ref          TEXT,
  numero_telephone     TEXT,
  gestionnaire         TEXT,
  -- Colonnes v2 : idempotence et suivi avancé
  internal_reference   TEXT        UNIQUE,   -- numcommande TC_... (anti-doublon)
  idempotency_key      TEXT        UNIQUE,   -- clé idempotence SycaPay
  statut_traitement    TEXT        NOT NULL DEFAULT 'non_traite'
                       CHECK (statut_traitement IN ('non_traite','en_cours','traite','erreur')),
  user_id              TEXT,
  tontine_code         TEXT,
  type_operation       TEXT,
  pret_id              TEXT,
  emprunteur_id        TEXT,
  metadata             JSONB       DEFAULT '{}',
  created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at           TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Ajouter colonnes v2 sur bases existantes (idempotent)
ALTER TABLE sycapay_transactions ADD COLUMN IF NOT EXISTS internal_reference       TEXT UNIQUE;
ALTER TABLE sycapay_transactions ADD COLUMN IF NOT EXISTS idempotency_key          TEXT UNIQUE;
ALTER TABLE sycapay_transactions ADD COLUMN IF NOT EXISTS statut_traitement        TEXT NOT NULL DEFAULT 'non_traite';
ALTER TABLE sycapay_transactions ADD COLUMN IF NOT EXISTS user_id                  TEXT;
ALTER TABLE sycapay_transactions ADD COLUMN IF NOT EXISTS tontine_code             TEXT;
ALTER TABLE sycapay_transactions ADD COLUMN IF NOT EXISTS type_operation           TEXT;
ALTER TABLE sycapay_transactions ADD COLUMN IF NOT EXISTS pret_id                  TEXT;
ALTER TABLE sycapay_transactions ADD COLUMN IF NOT EXISTS emprunteur_id            TEXT;
ALTER TABLE sycapay_transactions ADD COLUMN IF NOT EXISTS provider_transaction_id  TEXT;
ALTER TABLE sycapay_transactions ADD COLUMN IF NOT EXISTS sycapay_reference        TEXT;
-- Colonnes nommées à la convention SycaPay (source supabase-sycapay-transactions.sql)
ALTER TABLE sycapay_transactions ADD COLUMN IF NOT EXISTS amount                   INTEGER;
ALTER TABLE sycapay_transactions ADD COLUMN IF NOT EXISTS currency                 TEXT;
ALTER TABLE sycapay_transactions ADD COLUMN IF NOT EXISTS operator                 TEXT;
ALTER TABLE sycapay_transactions ADD COLUMN IF NOT EXISTS phone_number_masked      TEXT;
ALTER TABLE sycapay_transactions ADD COLUMN IF NOT EXISTS description              TEXT;
ALTER TABLE sycapay_transactions ADD COLUMN IF NOT EXISTS status                   TEXT DEFAULT 'pending';
ALTER TABLE sycapay_transactions ADD COLUMN IF NOT EXISTS polling_attempts         INTEGER DEFAULT 0;

-- Index performance pour les colonnes critiques (idempotence)
CREATE INDEX IF NOT EXISTS idx_sycapay_txn_ref         ON sycapay_transactions(internal_reference) WHERE internal_reference IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_sycapay_txn_idempotency ON sycapay_transactions(idempotency_key)    WHERE idempotency_key IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_sycapay_txn_membre      ON sycapay_transactions(code, membre_id);
CREATE INDEX IF NOT EXISTS idx_sycapay_txn_provider    ON sycapay_transactions(provider_transaction_id) WHERE provider_transaction_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_sycapay_code   ON sycapay_transactions(code);
CREATE INDEX IF NOT EXISTS idx_sycapay_statut ON sycapay_transactions(statut);
CREATE INDEX IF NOT EXISTS idx_sycapay_type   ON sycapay_transactions(type);
ALTER TABLE sycapay_transactions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "sycapay_anon" ON sycapay_transactions;
CREATE POLICY "sycapay_anon" ON sycapay_transactions FOR ALL TO anon USING (true) WITH CHECK (true);

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. prets_pending (prêts en attente de validation admin)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS prets_pending (
  id             BIGSERIAL PRIMARY KEY,
  code           TEXT        NOT NULL,
  membre_id      TEXT        NOT NULL,
  membre_nom     TEXT        NOT NULL,
  montant        NUMERIC(14,2) NOT NULL,
  montant_net    NUMERIC(14,2),
  taux_interet   NUMERIC(5,2) DEFAULT 0,
  duree_mois     INT          DEFAULT 1,
  devise         TEXT        NOT NULL DEFAULT 'XOF',
  motif          TEXT,
  statut         TEXT        NOT NULL DEFAULT 'pending'
                 CHECK (statut IN ('pending','validee','rejetee')),
  motif_rejet    TEXT,
  gestionnaire   TEXT,
  cree_le        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  traite_le      TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_prets_code   ON prets_pending(code);
CREATE INDEX IF NOT EXISTS idx_prets_statut ON prets_pending(statut);
ALTER TABLE prets_pending ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "prets_pending_anon" ON prets_pending;
CREATE POLICY "prets_pending_anon" ON prets_pending FOR ALL TO anon USING (true) WITH CHECK (true);

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. decaissements_pending
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS decaissements_pending (
  id           BIGSERIAL PRIMARY KEY,
  code         TEXT        NOT NULL,
  beneficiaire TEXT        NOT NULL,
  montant      NUMERIC(14,2) NOT NULL,
  devise       TEXT        NOT NULL DEFAULT 'XOF',
  motif        TEXT,
  statut       TEXT        NOT NULL DEFAULT 'pending'
               CHECK (statut IN ('pending','validee','rejetee')),
  motif_rejet  TEXT,
  gestionnaire TEXT,
  cree_le      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  traite_le    TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_decaiss_code   ON decaissements_pending(code);
CREATE INDEX IF NOT EXISTS idx_decaiss_statut ON decaissements_pending(statut);
ALTER TABLE decaissements_pending ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "decaissements_anon" ON decaissements_pending;
CREATE POLICY "decaissements_anon" ON decaissements_pending FOR ALL TO anon USING (true) WITH CHECK (true);

-- ─────────────────────────────────────────────────────────────────────────────
-- 7. depenses_pending
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS depenses_pending (
  id           BIGSERIAL PRIMARY KEY,
  code         TEXT        NOT NULL,
  libelle      TEXT        NOT NULL,
  montant      NUMERIC(14,2) NOT NULL,
  devise       TEXT        NOT NULL DEFAULT 'XOF',
  categorie    TEXT        DEFAULT 'autre',
  statut       TEXT        NOT NULL DEFAULT 'pending'
               CHECK (statut IN ('pending','validee','rejetee')),
  motif_rejet  TEXT,
  gestionnaire TEXT,
  cree_le      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  traite_le    TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_depenses_code   ON depenses_pending(code);
CREATE INDEX IF NOT EXISTS idx_depenses_statut ON depenses_pending(statut);
ALTER TABLE depenses_pending ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "depenses_anon" ON depenses_pending;
CREATE POLICY "depenses_anon" ON depenses_pending FOR ALL TO anon USING (true) WITH CHECK (true);

-- ─────────────────────────────────────────────────────────────────────────────
-- 8. premium_requests (alias moderne de demandes_premium — v12)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS premium_requests (
  id           BIGSERIAL PRIMARY KEY,
  code         TEXT        NOT NULL UNIQUE,
  gestionnaire TEXT        NOT NULL,
  nom          TEXT,
  contact      TEXT,
  formule      TEXT        NOT NULL DEFAULT 'mensuel',
  statut       TEXT        NOT NULL DEFAULT 'pending'
               CHECK (statut IN ('pending','active','rejected','expired')),
  cree_le      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  mis_a_jour   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_premium_req_code   ON premium_requests(code);
CREATE INDEX IF NOT EXISTS idx_premium_req_statut ON premium_requests(statut);
ALTER TABLE premium_requests ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "premium_requests_anon" ON premium_requests;
CREATE POLICY "premium_requests_anon" ON premium_requests FOR ALL TO anon USING (true) WITH CHECK (true);
-- =============================================================================
-- TontineClair — Migration 004 : KYC, Notifications & Rappels
-- Ordre d'exécution : 4/10
-- Remplace : supabase-kyc.sql, supabase/migrations/001_fcm_tokens.sql,
--            supabase/migrations/rappels_envoyes.sql
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. kyc_submissions
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.kyc_submissions (
  id              BIGSERIAL PRIMARY KEY,
  code            TEXT        NOT NULL,
  gestionnaire    TEXT        NOT NULL,
  nom_complet     TEXT        NOT NULL,
  type_piece      TEXT        NOT NULL DEFAULT 'cni'
                  CHECK (type_piece IN ('cni','passeport','permis','sejour')),
  numero_piece    TEXT,
  photo_recto_url TEXT,
  photo_verso_url TEXT,
  photo_selfie_url TEXT,
  statut          TEXT        NOT NULL DEFAULT 'pending'
                  CHECK (statut IN ('pending','valide','rejete')),
  motif_rejet     TEXT,
  note_admin      TEXT,
  soumis_le       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  traite_le       TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_kyc_code   ON public.kyc_submissions(code);
CREATE INDEX IF NOT EXISTS idx_kyc_statut ON public.kyc_submissions(statut);
ALTER TABLE public.kyc_submissions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "kyc_anon" ON public.kyc_submissions;
CREATE POLICY "kyc_anon" ON public.kyc_submissions FOR ALL TO anon USING (true) WITH CHECK (true);

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. fcm_tokens (notifications push Firebase)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.fcm_tokens (
  id         BIGSERIAL PRIMARY KEY,
  token      TEXT        NOT NULL UNIQUE,
  tontine    TEXT,        -- code tontine associée
  membre_id  TEXT,
  platform   TEXT        DEFAULT 'android',
  cree_le    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  mis_a_jour TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_fcm_tontine ON public.fcm_tokens(tontine);
ALTER TABLE public.fcm_tokens ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "fcm_anon" ON public.fcm_tokens;
CREATE POLICY "fcm_anon" ON public.fcm_tokens FOR ALL TO anon USING (true) WITH CHECK (true);

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. rappels_envoyes (anti-spam rappels cotisation)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS rappels_envoyes (
  id        BIGSERIAL PRIMARY KEY,
  code      TEXT        NOT NULL,
  membre_id TEXT        NOT NULL,
  type      TEXT        NOT NULL DEFAULT 'cotisation',
  envoye_le TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (code, membre_id, type)
);

CREATE INDEX IF NOT EXISTS idx_rappels_code ON rappels_envoyes(code);
ALTER TABLE rappels_envoyes ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "rappels_anon" ON rappels_envoyes;
CREATE POLICY "rappels_anon" ON rappels_envoyes FOR ALL TO anon USING (true) WITH CHECK (true);
-- =============================================================================
-- TontineClair — Migration 005 : Équipe admin, Messagerie & Support client
-- Ordre d'exécution : 5/10
-- Remplace : supabase-admin-team.sql (intégralité)
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. admin_membres
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS admin_membres (
  id                 BIGSERIAL PRIMARY KEY,
  nom                TEXT        NOT NULL,
  pseudo             TEXT        NOT NULL UNIQUE,
  cle_hash           TEXT        NOT NULL,   -- SHA-256(clePerso)
  role               TEXT        NOT NULL DEFAULT 'comptable'
                     CHECK (role IN ('super_admin','comptable','conformite')),
  actif              BOOLEAN     NOT NULL DEFAULT TRUE,
  cree_par           TEXT        NOT NULL,
  cree_le            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  derniere_connexion TIMESTAMPTZ
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_admin_membres_pseudo ON admin_membres(pseudo);
CREATE INDEX        IF NOT EXISTS idx_admin_membres_role   ON admin_membres(role);
ALTER TABLE admin_membres ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "admin_membres_service" ON admin_membres;
CREATE POLICY "admin_membres_service" ON admin_membres USING (true) WITH CHECK (true);

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. admin_messages (messagerie interne équipe admin)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS admin_messages (
  id           BIGSERIAL PRIMARY KEY,
  expediteur   TEXT        NOT NULL,
  destinataire TEXT        NOT NULL,    -- pseudo ou 'tous'
  sujet        TEXT        NOT NULL DEFAULT '',
  corps        TEXT        NOT NULL,
  lu           BOOLEAN     NOT NULL DEFAULT FALSE,
  lu_le        TIMESTAMPTZ,
  envoye_le    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_admin_msg_dest     ON admin_messages(destinataire);
CREATE INDEX IF NOT EXISTS idx_admin_msg_exp      ON admin_messages(expediteur);
CREATE INDEX IF NOT EXISTS idx_admin_msg_date     ON admin_messages(envoye_le DESC);
ALTER TABLE admin_messages ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "admin_messages_service" ON admin_messages;
CREATE POLICY "admin_messages_service" ON admin_messages USING (true) WITH CHECK (true);

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. support_tickets
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS support_tickets (
  id           BIGSERIAL PRIMARY KEY,
  ref          TEXT        NOT NULL UNIQUE,   -- TC-YYYY-NNNN
  gestionnaire TEXT        NOT NULL,
  code_tontine TEXT,
  categorie    TEXT        NOT NULL DEFAULT 'autre'
               CHECK (categorie IN ('paiement','kyc','tontine','technique','autre')),
  sujet        TEXT        NOT NULL,
  description  TEXT        NOT NULL,
  statut       TEXT        NOT NULL DEFAULT 'ouvert'
               CHECK (statut IN ('ouvert','en_cours','resolu','ferme')),
  priorite     TEXT        NOT NULL DEFAULT 'normale'
               CHECK (priorite IN ('basse','normale','haute','urgente')),
  assigne_a    TEXT,
  cree_le      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  mis_a_jour   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  resolu_le    TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_support_tickets_statut       ON support_tickets(statut);
CREATE INDEX IF NOT EXISTS idx_support_tickets_gestionnaire ON support_tickets(gestionnaire);
CREATE INDEX IF NOT EXISTS idx_support_tickets_ref          ON support_tickets(ref);
CREATE INDEX IF NOT EXISTS idx_support_tickets_cree_le      ON support_tickets(cree_le DESC);
ALTER TABLE support_tickets ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "support_tickets_service" ON support_tickets;
CREATE POLICY "support_tickets_service" ON support_tickets USING (true) WITH CHECK (true);

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. support_messages
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS support_messages (
  id        BIGSERIAL PRIMARY KEY,
  ticket_id BIGINT      NOT NULL REFERENCES support_tickets(id) ON DELETE CASCADE,
  auteur    TEXT        NOT NULL,
  est_admin BOOLEAN     NOT NULL DEFAULT FALSE,
  corps     TEXT        NOT NULL,
  lu_client BOOLEAN     NOT NULL DEFAULT FALSE,
  lu_admin  BOOLEAN     NOT NULL DEFAULT FALSE,
  envoye_le TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_support_msg_ticket ON support_messages(ticket_id);
CREATE INDEX IF NOT EXISTS idx_support_msg_date   ON support_messages(envoye_le ASC);
ALTER TABLE support_messages ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "support_messages_service" ON support_messages;
CREATE POLICY "support_messages_service" ON support_messages USING (true) WITH CHECK (true);
-- =============================================================================
-- TontineClair — Migration 006 : RPCs Tontines (fonctions de base)
-- Ordre d'exécution : 6/10
-- Remplace (version finale de) : supabase-fix-v7.sql, supabase-fix-v8-periodicitee.sql,
--   supabase-fix-v9-nouveau-cycle.sql, supabase-fix-v10-cycle-logique.sql,
--   supabase-fix-v11-beneficiaire.sql, supabase-fix-v15-nouveau-cycle.sql,
--   supabase-fix-v18-voter-choix-minuscules.sql, supabase-v16-soft-delete.sql,
--   supabase-v17-fix-soft-delete.sql (sections tontines)
-- Note : chaque fonction ici est la version la plus récente appliquée.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- Helper interne
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION _tc_nom_membre(p_data jsonb, p_id text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT COALESCE(
    (SELECT m->>'nom' FROM jsonb_array_elements(p_data->'membres') m
     WHERE m->>'id' = p_id LIMIT 1),
    p_id
  );
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- lire_tontine — v16 (avec soft-delete)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION lire_tontine(p_code text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_code text := upper(trim(p_code));
  v_row  tontines%ROWTYPE;
BEGIN
  SELECT * INTO v_row FROM tontines WHERE code = v_code;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Tontine introuvable');
  END IF;
  IF v_row.status = 'deleted' OR v_row.deleted_at IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'TONTINE_DELETED',
      'message', 'Cette tontine a été supprimée.');
  END IF;
  RETURN jsonb_build_object('ok', true, 'data', v_row.data, 'code', v_code,
    'status', v_row.status, 'updated_at', v_row.updated_at);
END; $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- ecrire_tontine_sans_pin — écriture directe sans vérification PIN
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION ecrire_tontine_sans_pin(p_code text, p_data jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  UPDATE tontines SET data = p_data WHERE code = upper(trim(p_code));
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Code introuvable');
  END IF;
  RETURN jsonb_build_object('ok', true);
END; $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- verifier_gestionnaire — v15
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION verifier_gestionnaire(p_code text, p_nom text, p_pin text)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  RETURN EXISTS (
    SELECT 1 FROM tontines
    WHERE code = upper(trim(p_code))
      AND status != 'deleted'
      AND deleted_at IS NULL
      AND (
        gestionnaires @> jsonb_build_array(jsonb_build_object('nom', p_nom, 'pin', p_pin))
        OR data @> jsonb_build_object('gestionnaires',
              jsonb_build_array(jsonb_build_object('nom', p_nom, 'pin', p_pin)))
      )
  );
END; $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- check_invitation_code — v17 (version finale)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION check_invitation_code(p_code text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_code text := upper(trim(p_code));
  v_row  tontines%ROWTYPE;
BEGIN
  SELECT * INTO v_row FROM tontines WHERE code = v_code;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'CODE_INTROUVABLE',
      'message', 'Code de tontine invalide ou expiré.');
  END IF;
  IF v_row.status = 'deleted' OR v_row.deleted_at IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'TONTINE_DELETED',
      'message', 'Cette tontine a été supprimée. Son code d''invitation n''est plus valide.',
      'nom', COALESCE(v_row.data->>'nom', v_code));
  END IF;
  IF NOT COALESCE(v_row.invitation_code_active, true) THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'INVITATION_INACTIVE',
      'message', 'Le code d''invitation de cette tontine n''est plus actif.',
      'nom', COALESCE(v_row.data->>'nom', v_code));
  END IF;
  IF v_row.status = 'suspended' THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'TONTINE_SUSPENDED',
      'message', 'Cette tontine est suspendue.',
      'nom', COALESCE(v_row.data->>'nom', v_code));
  END IF;
  RETURN jsonb_build_object('ok', true, 'nom', COALESCE(v_row.data->>'nom', v_code));
END; $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- join_tontine_by_code — v17
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION join_tontine_by_code(p_code text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_code  text := upper(trim(p_code));
  v_check jsonb;
  v_row   tontines%ROWTYPE;
BEGIN
  v_check := check_invitation_code(v_code);
  IF (v_check->>'ok')::boolean = false THEN RETURN v_check; END IF;
  SELECT * INTO v_row FROM tontines WHERE code = v_code;
  IF NOT FOUND OR v_row.status = 'deleted' THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'TONTINE_DELETED');
  END IF;
  RETURN jsonb_build_object('ok', true, 'code', v_code,
    'nom', COALESCE(v_row.data->>'nom', v_code), 'data', v_row.data);
END; $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- delete_tontine — v16 (soft-delete)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION delete_tontine(p_code text, p_nom text, p_pin text, p_motif text DEFAULT '')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_code text := upper(trim(p_code));
  v_ok   boolean;
BEGIN
  v_ok := verifier_gestionnaire(v_code, p_nom, p_pin);
  IF NOT v_ok THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'PIN incorrect ou non-gestionnaire');
  END IF;
  UPDATE tontines
  SET status = 'deleted', deleted_at = NOW(), deleted_by = p_nom,
      deletion_reason = p_motif, invitation_code_active = false
  WHERE code = v_code;
  RETURN jsonb_build_object('ok', true);
END; $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- restore_deleted_tontine — v16
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION restore_deleted_tontine(
  p_cle text, p_code text, p_motif text DEFAULT ''
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_admin_key text := 'TONTINE_ADMIN_2024';
  v_new_code  text;
BEGIN
  IF p_cle != v_admin_key THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Clé admin invalide');
  END IF;
  v_new_code := upper(substr(md5(random()::text), 1, 6));
  UPDATE tontines
  SET status = 'active', deleted_at = NULL, deleted_by = NULL,
      deletion_reason = NULL, invitation_code_active = true,
      code = v_new_code
  WHERE code = upper(trim(p_code)) AND status = 'deleted';
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Tontine non trouvée ou non supprimée');
  END IF;
  RETURN jsonb_build_object('ok', true, 'nouveau_code', v_new_code);
END; $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- maj_echeance — v8
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION maj_echeance(p_code text, p_nom text, p_pin text, p_echeance text)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF NOT verifier_gestionnaire(p_code, p_nom, p_pin) THEN RETURN false; END IF;
  UPDATE tontines
  SET data = jsonb_set(data, '{echeance}', to_jsonb(p_echeance))
  WHERE code = upper(trim(p_code));
  RETURN FOUND;
END; $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- lire_config_tontine — v8
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION lire_config_tontine(p_code text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_data jsonb;
BEGIN
  SELECT data INTO v_data FROM tontines WHERE code = upper(trim(p_code));
  IF NOT FOUND THEN RETURN NULL; END IF;
  RETURN jsonb_build_object(
    'montant',      v_data->>'montant',
    'periodicite',  v_data->>'periodicite',
    'echeance',     v_data->>'echeance',
    'nbMembresMax', v_data->>'nbMembresMax',
    'devise',       COALESCE(v_data->>'devise', 'XOF')
  );
END; $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- voter — v18 (choix minuscules)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION voter(
  p_code    text, p_vote_id text, p_membre_id text,
  p_nom     text, p_choix   text
) RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_choix text := lower(trim(p_choix));
  v_row   tontines%ROWTYPE;
  v_data  jsonb; v_votes jsonb; v_vote jsonb; v_voix jsonb; v_idx int;
BEGIN
  IF v_choix NOT IN ('pour','contre','abstention') THEN RETURN false; END IF;
  SELECT * INTO v_row FROM tontines WHERE code = upper(trim(p_code));
  IF NOT FOUND THEN RETURN false; END IF;
  v_data  := v_row.data;
  v_votes := COALESCE(v_data->'votes', '[]'::jsonb);
  -- Trouver le vote
  FOR v_idx IN 0..jsonb_array_length(v_votes)-1 LOOP
    IF v_votes->v_idx->>'id' = p_vote_id THEN
      v_vote := v_votes->v_idx;
      v_voix := COALESCE(v_vote->'voix', '[]'::jsonb);
      -- Retirer vote existant du membre
      v_voix := (SELECT jsonb_agg(x) FROM jsonb_array_elements(v_voix) x
                 WHERE x->>'membreId' != p_membre_id);
      v_voix := COALESCE(v_voix, '[]'::jsonb);
      -- Ajouter nouveau vote
      v_voix := v_voix || jsonb_build_array(
        jsonb_build_object('membreId', p_membre_id, 'nom', p_nom, 'choix', v_choix,
                           'quand', now()::text));
      v_vote := jsonb_set(v_vote, '{voix}', v_voix);
      v_votes := jsonb_set(v_votes, ARRAY[v_idx::text], v_vote);
      UPDATE tontines SET data = jsonb_set(v_data, '{votes}', v_votes)
      WHERE code = v_row.code;
      RETURN true;
    END IF;
  END LOOP;
  RETURN false;
END; $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- cloturer_tour — v11 (version finale avec anti-doublon + beneficiaireNom)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION cloturer_tour(p_code text, p_pin text, p_gest text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_row         tontines%ROWTYPE;
  v_data        jsonb;
  v_ordre       jsonb; v_membres jsonb;
  v_tour_actuel int;  v_nb_tours int;
  v_benef_id    text; v_benef_nom text;
  v_paiements   jsonb; v_historique jsonb;
  v_nb_payes    int;  v_total_recu int;
  v_montant     int;  v_est_dernier boolean;
  v_new_tour    int;  v_payes_ids jsonb;
  v_ref         text; v_now text;
  v_gestionnaire text; v_doublons boolean;
BEGIN
  SELECT * INTO v_row FROM tontines WHERE code = p_code;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'erreur', 'Tontine introuvable'); END IF;

  v_data        := v_row.data;
  v_ordre       := COALESCE(v_data->'ordre', '[]'::jsonb);
  v_membres     := COALESCE(v_data->'membres', '[]'::jsonb);
  v_tour_actuel := COALESCE((v_data->>'tourActuel')::int, 0);
  v_nb_tours    := jsonb_array_length(v_ordre);
  v_montant     := COALESCE((v_data->>'montant')::int, 0);
  v_paiements   := COALESCE(v_data->'paiements', '{}'::jsonb);
  v_historique  := COALESCE(v_data->'historique', '[]'::jsonb);
  v_now         := now()::text;
  v_ref         := upper(substring(md5(random()::text) FROM 1 FOR 8));
  v_gestionnaire := COALESCE(p_gest, 'gestionnaire');

  IF (v_data->>'cycleTermine')::boolean = true THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Le cycle est déjà terminé'); END IF;
  IF v_nb_tours = 0 THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Aucun ordre de passage défini'); END IF;
  IF v_tour_actuel >= v_nb_tours THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Tous les tours ont été clôturés'); END IF;

  v_benef_id  := v_ordre->>v_tour_actuel;
  v_benef_nom := _tc_nom_membre(v_data, v_benef_id);

  -- Anti-doublon
  SELECT EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_historique) h
    WHERE (h->>'beneficiaireId') = v_benef_id OR (h->>'beneficiaire') = v_benef_nom
  ) INTO v_doublons;
  IF v_doublons THEN
    RETURN jsonb_build_object('ok', false, 'erreur',
      'Ce membre a déjà été servi dans ce cycle'); END IF;

  -- Compter paiements reçus
  SELECT COUNT(*), COALESCE(SUM((v_paiements->m->>'montant')::int), 0),
         jsonb_agg(m)
  INTO v_nb_payes, v_total_recu, v_payes_ids
  FROM jsonb_object_keys(v_paiements) m
  WHERE (v_paiements->m->>'statut') IN ('payé','paye','confirmed','completed');

  v_new_tour    := v_tour_actuel + 1;
  v_est_dernier := v_new_tour >= v_nb_tours;

  -- Ajouter entrée historique
  v_historique := v_historique || jsonb_build_array(jsonb_build_object(
    'ref', v_ref, 'tour', v_tour_actuel, 'beneficiaire', v_benef_nom,
    'beneficiaireId', v_benef_id, 'montantDistribue', v_total_recu,
    'nbPayants', v_nb_payes, 'date', v_now, 'gestionnaire', v_gestionnaire));

  -- Mettre à jour tontine
  UPDATE tontines SET data = v_data
    || jsonb_build_object('tourActuel',   v_new_tour)
    || jsonb_build_object('cycleTermine', v_est_dernier)
    || jsonb_build_object('historique',   v_historique)
    || jsonb_build_object('paiements',    '{}'::jsonb)
  WHERE code = v_row.code;

  RETURN jsonb_build_object('ok', true, 'beneficiaire', v_benef_nom,
    'beneficiaireId', v_benef_id, 'montant', v_total_recu,
    'cycleTermine', v_est_dernier, 'nouveauTour', v_new_tour);
END; $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- proposer_nouveau_cycle / lire_etat_cycle / clore_vote_redemarrage /
-- demarrer_nouveau_cycle — v15 (version finale)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION proposer_nouveau_cycle(
  p_code text, p_nom text, p_pin text, p_vote_id text
) RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF NOT verifier_gestionnaire(p_code, p_nom, p_pin) THEN RETURN false; END IF;
  UPDATE tontines SET data = jsonb_set(
    jsonb_set(data, '{cycleTermine}', 'true'),
    '{voteRedemarrage}',
    jsonb_build_object('voteId', p_vote_id, 'propose_par', p_nom,
                       'quand', now()::text, 'statut', 'en_attente')
  ) WHERE code = upper(trim(p_code));
  RETURN FOUND;
END; $$;

CREATE OR REPLACE FUNCTION lire_etat_cycle(p_code text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_data jsonb;
BEGIN
  SELECT data INTO v_data FROM tontines WHERE code = upper(trim(p_code));
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false); END IF;
  RETURN jsonb_build_object(
    'ok', true,
    'cycleTermine',    COALESCE((v_data->>'cycleTermine')::boolean, false),
    'tourActuel',      COALESCE((v_data->>'tourActuel')::int, 0),
    'voteRedemarrage', v_data->'voteRedemarrage',
    'historique',      COALESCE(v_data->'historique', '[]'::jsonb)
  );
END; $$;

CREATE OR REPLACE FUNCTION clore_vote_redemarrage(
  p_code text, p_nom text, p_pin text, p_statut text
) RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF NOT verifier_gestionnaire(p_code, p_nom, p_pin) THEN RETURN false; END IF;
  UPDATE tontines SET data = jsonb_set(
    data, '{voteRedemarrage}',
    COALESCE(data->'voteRedemarrage', '{}'::jsonb)
    || jsonb_build_object('statut', p_statut, 'clos_le', now()::text)
  ) WHERE code = upper(trim(p_code));
  RETURN FOUND;
END; $$;

CREATE OR REPLACE FUNCTION demarrer_nouveau_cycle(p_code text, p_nom text, p_pin text)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_data jsonb; v_membres jsonb; v_ordre jsonb; v_ids jsonb; v_i int;
BEGIN
  IF NOT verifier_gestionnaire(p_code, p_nom, p_pin) THEN RETURN false; END IF;
  SELECT data INTO v_data FROM tontines WHERE code = upper(trim(p_code));
  v_membres := COALESCE(v_data->'membres', '[]'::jsonb);
  v_ids     := '[]'::jsonb;
  FOR v_i IN 0..jsonb_array_length(v_membres)-1 LOOP
    v_ids := v_ids || jsonb_build_array(v_membres->v_i->>'id');
  END LOOP;
  UPDATE tontines SET data = v_data
    || jsonb_build_object('cycleTermine', false)
    || jsonb_build_object('tourActuel', 0)
    || jsonb_build_object('ordre', v_ids)
    || jsonb_build_object('paiements', '{}'::jsonb)
    || jsonb_build_object('voteRedemarrage', NULL)
  WHERE code = upper(trim(p_code));
  RETURN FOUND;
END; $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- demander_premium — v12 (version finale)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION demander_premium(
  p_code text, p_nom text, p_pin text,
  p_contact text DEFAULT NULL, p_formule text DEFAULT 'mensuel'
) RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_code text := upper(trim(p_code));
BEGIN
  INSERT INTO demandes_premium (code, gestionnaire, nom, contact, formule, statut, quand)
  VALUES (v_code, p_nom, p_nom, p_contact, p_formule, 'en attente', NOW())
  ON CONFLICT (code) DO UPDATE
    SET gestionnaire = EXCLUDED.gestionnaire, nom = EXCLUDED.nom,
        contact = EXCLUDED.contact, formule = EXCLUDED.formule,
        statut = 'en attente', quand = NOW();
  RETURN true;
EXCEPTION WHEN OTHERS THEN RETURN false;
END; $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- Permissions
-- ─────────────────────────────────────────────────────────────────────────────
GRANT EXECUTE ON FUNCTION lire_tontine(text)                              TO anon;
GRANT EXECUTE ON FUNCTION ecrire_tontine_sans_pin(text, jsonb)            TO anon;
GRANT EXECUTE ON FUNCTION verifier_gestionnaire(text, text, text)         TO anon;
GRANT EXECUTE ON FUNCTION check_invitation_code(text)                     TO anon;
GRANT EXECUTE ON FUNCTION join_tontine_by_code(text)                      TO anon;
GRANT EXECUTE ON FUNCTION delete_tontine(text, text, text, text)          TO anon;
GRANT EXECUTE ON FUNCTION restore_deleted_tontine(text, text, text)       TO anon;
GRANT EXECUTE ON FUNCTION maj_echeance(text, text, text, text)            TO anon;
GRANT EXECUTE ON FUNCTION lire_config_tontine(text)                       TO anon;
GRANT EXECUTE ON FUNCTION voter(text, text, text, text, text)             TO anon;
GRANT EXECUTE ON FUNCTION cloturer_tour(text, text, text)                 TO anon;
GRANT EXECUTE ON FUNCTION proposer_nouveau_cycle(text, text, text, text)  TO anon;
GRANT EXECUTE ON FUNCTION lire_etat_cycle(text)                           TO anon;
GRANT EXECUTE ON FUNCTION clore_vote_redemarrage(text, text, text, text)  TO anon;
GRANT EXECUTE ON FUNCTION demarrer_nouveau_cycle(text, text, text)        TO anon;
GRANT EXECUTE ON FUNCTION demander_premium(text, text, text, text, text)  TO anon;
-- ============================================================
-- TontineClair — Migration 007 : RPCs Score de Confiance & Audit
-- Source     : supabase-v6.sql (v6.2) + supabase-v14-FINAL.sql
-- Dépendances: 001_tables_core.sql, 002_tables_scores_audit.sql
-- Idempotent : CREATE OR REPLACE FUNCTION partout
-- ============================================================
-- Fonctions incluses (11) :
--   enregistrer_score, lire_historique_score, lire_scores_tontine,
--   proposer_retrait, lire_propositions_retrait, maj_statut_retrait,
--   lire_journal_audit, init_score_membre,
--   modifier_score_membre (v14-FINAL),
--   lire_score_membre    (v14-FINAL),
--   reinitialiser_score_override (v14-FINAL)
-- ============================================================

-- ────────────────────────────────────────────────────────────
-- 1. enregistrer_score
--    Enregistre un événement de score dans scores_historique + journal_audit
-- ────────────────────────────────────────────────────────────
create or replace function enregistrer_score(
  p_code        text,
  p_membre_id   text,
  p_score       int,
  p_score_prec  int,
  p_evenement   text,
  p_description text,
  p_gestionnaire text default null
)
returns boolean
language plpgsql security definer set search_path = public
as $$
begin
  if p_score      < 0 or p_score      > 100 then return false; end if;
  if p_score_prec < 0 or p_score_prec > 100 then return false; end if;
  if p_code is null or p_membre_id is null   then return false; end if;

  insert into scores_historique(
    code, membre_id, score, score_prec, evenement, description, gestionnaire
  )
  values (
    upper(p_code), p_membre_id, p_score, p_score_prec,
    p_evenement, p_description, p_gestionnaire
  );

  insert into journal_audit(
    code, gestionnaire, action, detail, membre_id, ancien_val, nouveau_val
  )
  values (
    upper(p_code),
    coalesce(p_gestionnaire, 'SYSTEME'),
    'SCORE_' || upper(p_evenement),
    p_description,
    p_membre_id,
    p_score_prec::text,
    p_score::text
  );

  begin
    insert into audit(code, gestionnaire, empreinte)
    values (
      upper(p_code),
      coalesce(p_gestionnaire, 'SYSTEME'),
      'SCORE:' || p_membre_id || ':' || p_score_prec || '->' || p_score
      || ':' || p_evenement
    );
  exception when undefined_table then null;
  end;

  return true;
end $$;

grant execute on function enregistrer_score(text, text, int, int, text, text, text) to anon;

-- ────────────────────────────────────────────────────────────
-- 2. lire_historique_score
--    Retourne l'historique des scores d'un membre (JSON)
-- ────────────────────────────────────────────────────────────
create or replace function lire_historique_score(
  p_code      text,
  p_membre_id text
)
returns jsonb
language sql security definer set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',             id,
    'score',          score,
    'scorePrecedent', score_prec,
    'delta',          score - score_prec,
    'evenement',      evenement,
    'description',    description,
    'gestionnaire',   gestionnaire,
    'quand',          to_char(quand at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
  ) order by quand desc), '[]'::jsonb)
  from scores_historique
  where code = upper(p_code) and membre_id = p_membre_id;
$$;

grant execute on function lire_historique_score(text, text) to anon;

-- ────────────────────────────────────────────────────────────
-- 3. lire_scores_tontine
--    Dernier score de chaque membre d'une tontine
-- ────────────────────────────────────────────────────────────
create or replace function lire_scores_tontine(p_code text)
returns jsonb
language sql security definer set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'membre_id',     membre_id,
    'dernier_score', score,
    'score_prec',    score_prec,
    'delta',         score - score_prec,
    'evenement',     evenement,
    'quand',         to_char(quand at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
  )), '[]'::jsonb)
  from (
    select distinct on (membre_id)
      membre_id, score, score_prec, evenement, quand
    from scores_historique
    where code = upper(p_code)
    order by membre_id, quand desc
  ) t;
$$;

grant execute on function lire_scores_tontine(text) to anon;

-- ────────────────────────────────────────────────────────────
-- 4. proposer_retrait
--    Crée une proposition de retrait de membre + audit
-- ────────────────────────────────────────────────────────────
create or replace function proposer_retrait(
  p_code       text,
  p_nom        text,
  p_pin        text,
  p_membre_id  text,
  p_membre_nom text,
  p_score      int,
  p_motif      text,
  p_vote_id    text,
  p_quorum     int default 50,
  p_majorite   int default 67
)
returns boolean
language plpgsql security definer set search_path = public
as $$
begin
  if not exists (
    select 1 from tontines
    where code = upper(p_code)
      and gestionnaires @> jsonb_build_array(
            jsonb_build_object('nom', p_nom, 'pin', p_pin)
          )
  ) then return false; end if;

  if p_quorum   < 0  or p_quorum   > 100 then return false; end if;
  if p_majorite < 50 or p_majorite > 100 then return false; end if;

  insert into propositions_retrait(
    code, membre_id, membre_nom, score_moment,
    motif, propose_par, vote_id, quorum, majorite, statut
  )
  values (
    upper(p_code), p_membre_id, p_membre_nom, p_score,
    p_motif, p_nom, p_vote_id, p_quorum, p_majorite, 'vote_ouvert'
  );

  insert into journal_audit(
    code, gestionnaire, action, detail, membre_id, nouveau_val
  )
  values (
    upper(p_code), p_nom, 'RETRAIT_PROPOSE',
    'Motif: ' || left(p_motif, 200)
    || ' | Quorum: '   || p_quorum   || '%'
    || ' | Majorité: ' || p_majorite || '%'
    || ' | Score: '    || p_score,
    p_membre_id,
    p_vote_id
  );

  begin
    insert into audit(code, gestionnaire, empreinte)
    values (
      upper(p_code), p_nom,
      'RETRAIT_PROPOSE:' || p_membre_id
      || ':score='    || p_score
      || ':quorum='   || p_quorum
      || ':majorite=' || p_majorite
      || ':' || left(p_motif, 80)
    );
  exception when undefined_table then null; end;

  return true;
end $$;

grant execute on function proposer_retrait(text, text, text, text, text, int, text, text, int, int) to anon;

-- ────────────────────────────────────────────────────────────
-- 5. lire_propositions_retrait
--    Toutes les propositions de retrait d'une tontine
-- ────────────────────────────────────────────────────────────
create or replace function lire_propositions_retrait(p_code text)
returns jsonb
language sql security definer set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',           id,
    'membreId',     membre_id,
    'membreNom',    membre_nom,
    'scoreAuMoment', score_moment,
    'motif',        motif,
    'proposePar',   propose_par,
    'voteId',       vote_id,
    'quorum',       quorum,
    'majorite',     majorite,
    'statut',       statut,
    'quand',        to_char(quand at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'closLe',       to_char(clos_le at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'resultatOui',  resultat_oui,
    'resultatNon',  resultat_non,
    'resultatAbs',  resultat_abs
  ) order by quand desc), '[]'::jsonb)
  from propositions_retrait
  where code = upper(p_code);
$$;

grant execute on function lire_propositions_retrait(text) to anon;

-- ────────────────────────────────────────────────────────────
-- 6. maj_statut_retrait
--    Clôture une proposition : accepté ou refusé
-- ────────────────────────────────────────────────────────────
create or replace function maj_statut_retrait(
  p_code     text,
  p_nom      text,
  p_pin      text,
  p_vote_id  text,
  p_statut   text,
  p_oui      int default 0,
  p_non      int default 0,
  p_abs      int default 0
)
returns boolean
language plpgsql security definer set search_path = public
as $$
begin
  if p_statut not in ('accepte','refuse') then return false; end if;

  if not exists (
    select 1 from tontines
    where code = upper(p_code)
      and gestionnaires @> jsonb_build_array(
            jsonb_build_object('nom', p_nom, 'pin', p_pin)
          )
  ) then return false; end if;

  update propositions_retrait
  set
    statut       = p_statut,
    clos_le      = now(),
    resultat_oui = p_oui,
    resultat_non = p_non,
    resultat_abs = p_abs
  where code = upper(p_code) and vote_id = p_vote_id;

  insert into journal_audit(
    code, gestionnaire, action, detail, nouveau_val
  )
  values (
    upper(p_code), p_nom,
    'RETRAIT_' || upper(p_statut),
    'Vote ' || p_vote_id
    || ' | Oui: ' || p_oui
    || ' Non: '   || p_non
    || ' Abs: '   || p_abs,
    p_statut
  );

  begin
    insert into audit(code, gestionnaire, empreinte)
    values (
      upper(p_code), p_nom,
      'RETRAIT_' || upper(p_statut)
      || ':vote=' || p_vote_id
      || ':oui='  || p_oui
      || ':non='  || p_non
      || ':abs='  || p_abs
    );
  exception when undefined_table then null; end;

  return found;
end $$;

grant execute on function maj_statut_retrait(text, text, text, text, text, int, int, int) to anon;

-- ────────────────────────────────────────────────────────────
-- 7. lire_journal_audit
--    Journal d'audit d'une tontine (N dernières entrées)
-- ────────────────────────────────────────────────────────────
create or replace function lire_journal_audit(
  p_code   text,
  p_limite int default 50
)
returns jsonb
language sql security definer set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',           id,
    'gestionnaire', gestionnaire,
    'action',       action,
    'detail',       detail,
    'membreId',     membre_id,
    'ancienVal',    ancien_val,
    'nouveauVal',   nouveau_val,
    'quand',        to_char(quand at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
  ) order by quand desc), '[]'::jsonb)
  from (
    select * from journal_audit
    where code = upper(p_code)
    order by quand desc
    limit p_limite
  ) t;
$$;

grant execute on function lire_journal_audit(text, int) to anon;

-- ────────────────────────────────────────────────────────────
-- 8. init_score_membre
--    Backfill : initialise le score si aucun historique n'existe
-- ────────────────────────────────────────────────────────────
create or replace function init_score_membre(
  p_code      text,
  p_membre_id text,
  p_score     int,
  p_desc      text default 'Score initial calculé depuis les données existantes'
)
returns boolean
language plpgsql security definer set search_path = public
as $$
begin
  if p_score < 0 or p_score > 100 then return false; end if;

  if not exists (
    select 1 from scores_historique
    where code = upper(p_code) and membre_id = p_membre_id
  ) then
    insert into scores_historique(
      code, membre_id, score, score_prec, evenement, description, gestionnaire
    )
    values (
      upper(p_code), p_membre_id, p_score, p_score, 'init', p_desc, 'SYSTEME'
    );

    insert into journal_audit(
      code, gestionnaire, action, detail, membre_id, ancien_val, nouveau_val
    )
    values (
      upper(p_code), 'SYSTEME', 'SCORE_INIT',
      p_desc, p_membre_id, '50', p_score::text
    );
  else
    update scores_historique
    set score = p_score
    where id = (
      select id from scores_historique
      where code = upper(p_code) and membre_id = p_membre_id
        and evenement = 'init'
      order by quand asc
      limit 1
    )
    and score != p_score;
  end if;

  return true;
end $$;

grant execute on function init_score_membre(text, text, int, text) to anon;

-- ────────────────────────────────────────────────────────────
-- 9. modifier_score_membre  [SOURCE: supabase-v14-FINAL.sql]
--    Modification manuelle du score par un gestionnaire
--    Écrit dans tontines.data.membres[].scoreOverride
--    + scores_historique + journal_audit + audit
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION modifier_score_membre(
  p_code       text,
  p_nom        text,
  p_pin        text,
  p_membre_id  text,
  p_nouveau    integer,
  p_motif      text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $func$
DECLARE
  v_code    text    := upper(trim(p_code));
  v_ancien  integer := 50;
  v_data    jsonb;
  v_membres jsonb;
  v_membre  jsonb;
  v_idx     integer := -1;
  v_found   boolean := false;
  v_now     text    := to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"');
  i         integer;
BEGIN
  IF p_nouveau < 0 OR p_nouveau > 100 THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Score invalide 0-100');
  END IF;
  IF p_motif IS NULL OR length(trim(p_motif)) < 3 THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Motif trop court');
  END IF;

  SELECT data INTO v_data FROM tontines WHERE code = v_code;
  IF v_data IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Tontine introuvable');
  END IF;

  IF NOT (
    (v_data->'gestionnaires' IS NOT NULL
     AND v_data->'gestionnaires' @> jsonb_build_array(
           jsonb_build_object('nom', p_nom, 'pin', p_pin)))
    OR EXISTS (
      SELECT 1 FROM tontines
      WHERE code = v_code
        AND gestionnaires @> jsonb_build_array(
              jsonb_build_object('nom', p_nom, 'pin', p_pin)))
    OR EXISTS (
      SELECT 1 FROM tontines t,
             jsonb_array_elements(COALESCE(t.gestionnaires, '[]'::jsonb)) g
      WHERE t.code = v_code
        AND (g->>'nom') = p_nom
        AND (g->>'pin') = p_pin)
  ) THEN
    RETURN jsonb_build_object('ok', false, 'message', 'PIN gestionnaire incorrect');
  END IF;

  v_membres := coalesce(v_data->'membres', '[]'::jsonb);

  FOR i IN 0 .. jsonb_array_length(v_membres) - 1 LOOP
    v_membre := v_membres->i;
    IF (v_membre->>'id') = p_membre_id THEN
      v_ancien := COALESCE(
        (v_membre->>'scoreOverride')::integer,
        (v_membre->>'score')::integer,
        50);
      v_idx   := i;
      v_found := true;
      EXIT;
    END IF;
  END LOOP;

  IF NOT v_found THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Membre introuvable');
  END IF;

  v_membres := jsonb_set(
    v_membres,
    ARRAY[v_idx::text],
    (v_membres->v_idx) || jsonb_build_object(
      'scoreOverride', p_nouveau,
      'motifOverride', trim(p_motif),
      'dateOverride',  v_now,
      'adminOverride', p_nom,
      'score',         p_nouveau),
    false);

  UPDATE tontines
  SET data = jsonb_set(v_data, '{membres}', v_membres, false)
  WHERE code = v_code;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Echec update');
  END IF;

  BEGIN
    INSERT INTO scores_historique(code, membre_id, score, score_prec, evenement, description, gestionnaire)
    VALUES (v_code, p_membre_id, p_nouveau, v_ancien, 'admin',
            'Modif manuelle par ' || p_nom || ' : ' || trim(p_motif), p_nom);
  EXCEPTION WHEN others THEN NULL;
  END;

  BEGIN
    INSERT INTO journal_audit(code, gestionnaire, action, detail, membre_id, ancien_val, nouveau_val)
    VALUES (v_code, p_nom, 'SCORE_MODIF', trim(p_motif), p_membre_id, v_ancien::text, p_nouveau::text);
  EXCEPTION WHEN others THEN NULL;
  END;

  BEGIN
    INSERT INTO audit(code, gestionnaire, empreinte)
    VALUES (v_code, p_nom, 'SCORE:' || p_membre_id || ':' || v_ancien || '->' || p_nouveau);
  EXCEPTION WHEN others THEN NULL;
  END;

  RETURN jsonb_build_object('ok', true, 'ancien', v_ancien, 'nouveau', p_nouveau,
    'message', 'Score ' || v_ancien || ' -> ' || p_nouveau);
END;
$func$;

GRANT EXECUTE ON FUNCTION modifier_score_membre(text,text,text,text,integer,text) TO anon, authenticated;

-- ────────────────────────────────────────────────────────────
-- 10. lire_score_membre  [SOURCE: supabase-v14-FINAL.sql]
--     Lit le score effectif (override ou calculé) depuis tontines.data
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION lire_score_membre(p_code text, p_membre_id text)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $func$
  SELECT jsonb_build_object(
    'membre_id',     p_membre_id,
    'score',         COALESCE((m->>'scoreOverride')::integer, (m->>'score')::integer, 50),
    'scoreOverride', (m->>'scoreOverride')::integer,
    'motifOverride', m->>'motifOverride',
    'dateOverride',  m->>'dateOverride',
    'adminOverride', m->>'adminOverride'
  )
  FROM tontines t,
       jsonb_array_elements(COALESCE(t.data->'membres', '[]'::jsonb)) AS m
  WHERE t.code = upper(p_code)
    AND (m->>'id') = p_membre_id
  LIMIT 1;
$func$;

GRANT EXECUTE ON FUNCTION lire_score_membre(text,text) TO anon, authenticated;

-- ────────────────────────────────────────────────────────────
-- 11. reinitialiser_score_override  [SOURCE: supabase-v14-FINAL.sql]
--     Supprime les champs scoreOverride/* du JSON membres
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION reinitialiser_score_override(p_code text, p_nom text, p_pin text, p_membre_id text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $func$
DECLARE
  v_code    text := upper(trim(p_code));
  v_data    jsonb;
  v_membres jsonb;
  v_membre  jsonb;
  i         integer;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM tontines t,
           jsonb_array_elements(COALESCE(t.gestionnaires, '[]'::jsonb)) g
    WHERE t.code = v_code AND (g->>'nom') = p_nom AND (g->>'pin') = p_pin
  ) THEN RETURN false; END IF;

  SELECT data INTO v_data FROM tontines WHERE code = v_code;
  IF v_data IS NULL THEN RETURN false; END IF;

  v_membres := COALESCE(v_data->'membres', '[]'::jsonb);

  FOR i IN 0 .. jsonb_array_length(v_membres) - 1 LOOP
    IF (v_membres->i->>'id') = p_membre_id THEN
      v_membre  := (v_membres->i) - 'scoreOverride' - 'motifOverride' - 'dateOverride' - 'adminOverride';
      v_membres := jsonb_set(v_membres, ARRAY[i::text], v_membre, false);
      EXIT;
    END IF;
  END LOOP;

  UPDATE tontines SET data = jsonb_set(v_data, '{membres}', v_membres, false) WHERE code = v_code;
  RETURN true;
END;
$func$;

GRANT EXECUTE ON FUNCTION reinitialiser_score_override(text,text,text,text) TO anon, authenticated;

-- ────────────────────────────────────────────────────────────
-- RLS : accès en lecture directe (protégé via security definer)
-- ────────────────────────────────────────────────────────────
drop policy if exists "scores_historique_select" on scores_historique;
create policy "scores_historique_select"
  on scores_historique for select to anon using (true);

drop policy if exists "propositions_retrait_select" on propositions_retrait;
create policy "propositions_retrait_select"
  on propositions_retrait for select to anon using (true);

drop policy if exists "journal_audit_select" on journal_audit;
create policy "journal_audit_select"
  on journal_audit for select to anon using (true);

-- ────────────────────────────────────────────────────────────
-- Vérification post-déploiement
-- ────────────────────────────────────────────────────────────
DO $verify007$
DECLARE
  v_fns text[] := ARRAY[
    'enregistrer_score','lire_historique_score','lire_scores_tontine',
    'proposer_retrait','lire_propositions_retrait','maj_statut_retrait',
    'lire_journal_audit','init_score_membre',
    'modifier_score_membre','lire_score_membre','reinitialiser_score_override'
  ];
  v_fn text;
  v_ok boolean;
BEGIN
  FOREACH v_fn IN ARRAY v_fns LOOP
    SELECT EXISTS(SELECT 1 FROM pg_proc WHERE proname = v_fn) INTO v_ok;
    RAISE NOTICE '007 % : %', v_fn, CASE WHEN v_ok THEN 'OK' ELSE 'MANQUANT' END;
  END LOOP;
END;
$verify007$;
-- ============================================================
-- FIN 007_rpcs_scores_audit.sql
-- ============================================================
-- ============================================================
-- TontineClair — Migration 008 : RPCs Dashboard Admin
-- Sources    : supabase-admin-fix.sql (v1.2 FINAL)
--              supabase-v17-fix-soft-delete.sql (admin_lister_tontines v17 FINAL)
--              supabase-fix-v12-premium-requests.sql (admin_lister_demandes FINAL)
-- Dépendances: 001_tables_core.sql, 003_tables_financier.sql
-- Idempotent : CREATE OR REPLACE FUNCTION partout
-- ============================================================
-- Fonctions incluses (14) :
--   _verif_admin_cle, admin_stats_globales, admin_dashboard_tontines,
--   admin_lister_abonnements, admin_alertes (v1.2 FIX ORDER BY),
--   admin_enregistrer_abonnement, admin_stats_mensuelles, admin_top_tontines,
--   admin_tontine_counts (v17), admin_lister_tontines (v17 FINAL),
--   tontines_set_updated_at (trigger),
--   admin_lister_demandes (v12 FINAL — source premium_requests),
--   admin_activer_premium (v12),
--   admin_refuser_demande (v12)
-- ============================================================

-- ────────────────────────────────────────────────────────────
-- 1. _verif_admin_cle
--    Helper interne : vérifie la clé admin depuis config (priorité) puis admin_config
-- ────────────────────────────────────────────────────────────
create or replace function _verif_admin_cle(p_cle text)
returns boolean
language plpgsql security definer set search_path = public
as $$
declare
  v_ok boolean := false;
begin
  -- Source 1 : table "config" (source de vérité v5)
  begin
    select exists(
      select 1 from config
      where admin_cle = p_cle
        and p_cle <> 'CHANGE-MOI-cle-admin-secrete'
    ) into v_ok;
  exception when undefined_table then
    v_ok := false;
  end;

  if v_ok then return true; end if;

  -- Source 2 : table "admin_config" (fallback)
  begin
    select exists(
      select 1 from admin_config where cle = p_cle
    ) into v_ok;
  exception when undefined_table then
    v_ok := false;
  end;

  -- Source 3 : hash SHA-256 dans admin_config
  if not v_ok then
    begin
      select exists(
        select 1 from admin_config
        where cle = encode(sha256(p_cle::bytea), 'hex')
      ) into v_ok;
    exception when undefined_table then
      v_ok := false;
    end;
  end if;

  return coalesce(v_ok, false);
end $$;

grant execute on function _verif_admin_cle(text) to anon;

-- ────────────────────────────────────────────────────────────
-- 2. admin_stats_globales
--    KPI cards : totaux, premium, membres, revenus
-- ────────────────────────────────────────────────────────────
create or replace function admin_stats_globales(p_cle text)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_now         timestamptz := now();
  v_debut_mois  timestamptz := date_trunc('month', now());
  v_debut_annee timestamptz := date_trunc('year', now());
  v_total       int;
  v_prem_actif  int;
  v_prem_expire int;
  v_gratuites   int;
  v_membres     int;
begin
  if not _verif_admin_cle(p_cle) then return null; end if;

  select count(*) into v_total from tontines;

  select count(*) into v_prem_actif
  from tontines
  where plan = 'premium'
    and (plan_expire is null or plan_expire > v_now);

  select count(*) into v_prem_expire
  from tontines
  where plan = 'premium'
    and plan_expire is not null
    and plan_expire <= v_now;

  v_gratuites := greatest(0, v_total - v_prem_actif - v_prem_expire);

  select coalesce(sum(
    case
      when jsonb_typeof(data->'membres') = 'array'
        then jsonb_array_length(data->'membres')
      else 0
    end
  ), 0)
  into v_membres
  from tontines;

  return jsonb_build_object(
    'total_tontines',        v_total,
    'premium_actives',       v_prem_actif,
    'premium_expires',       v_prem_expire,
    'gratuites',             v_gratuites,
    'total_membres',         v_membres,
    'abonnements_actifs',    (
      select count(*) from abonnements
      where statut = 'actif'
        and (date_fin is null or date_fin > v_now)
    ),
    'montant_mensuel_fcfa',  (
      select coalesce(sum(montant), 0) from abonnements
      where statut = 'actif' and formule = 'mensuel'
        and (date_fin is null or date_fin > v_now)
    ),
    'montant_annuel_fcfa',   (
      select coalesce(sum(montant), 0) from abonnements
      where statut = 'actif' and formule = 'annuel'
        and (date_fin is null or date_fin > v_now)
    ),
    'encaisse_ce_mois',      (
      select coalesce(sum(montant), 0) from abonnements
      where statut = 'actif' and quand >= v_debut_mois
    ),
    'encaisse_annee',        (
      select coalesce(sum(montant), 0) from abonnements
      where statut = 'actif' and quand >= v_debut_annee
    ),
    'revenu_mensuel_estime', v_prem_actif * 2500,
    'revenu_annuel_estime',  v_prem_actif * 2500 * 12,
    'alertes',               (
      select count(*) from tontines
      where plan = 'premium'
        and plan_expire is not null
        and plan_expire > v_now
        and plan_expire < v_now + interval '7 days'
    ),
    'calcule_le',            v_now
  );
end $$;

grant execute on function admin_stats_globales(text) to anon;

-- ────────────────────────────────────────────────────────────
-- 3. admin_dashboard_tontines
--    Liste enrichie des tontines avec infos abonnement (pagination + filtre)
-- ────────────────────────────────────────────────────────────
create or replace function admin_dashboard_tontines(
  p_cle    text,
  p_filtre text  default 'toutes',
  p_limit  int   default 100,
  p_offset int   default 0
)
returns jsonb
language plpgsql security definer set search_path = public
as $$
begin
  if not _verif_admin_cle(p_cle) then return '[]'::jsonb; end if;

  return (
    select coalesce(jsonb_agg(row_json order by cree_t desc), '[]'::jsonb)
    from (
      select jsonb_build_object(
        'code',           t.code,
        'nom',            t.data->>'nom',
        'plan',           coalesce(t.plan, 'free'),
        'plan_expire',    t.plan_expire,
        'cree',           t.cree_le,
        'nb_membres',     case
                            when jsonb_typeof(t.data->'membres') = 'array'
                              then jsonb_array_length(t.data->'membres')
                            else 0
                          end,
        'nb_votes',       case
                            when jsonb_typeof(t.data->'votes') = 'array'
                              then jsonb_array_length(t.data->'votes')
                            else 0
                          end,
        'nb_prets',       case
                            when jsonb_typeof(t.data->'prets') = 'array'
                              then jsonb_array_length(t.data->'prets')
                            else 0
                          end,
        'montant_cotis',  coalesce((t.data->>'montant')::int, 0),
        'periodicite',    coalesce(t.data->>'periodicite', ''),
        'premier_gest',   t.data->'gestionnaires'->0->>'nom',
        'est_actif',      (
          t.plan = 'premium'
          and (t.plan_expire is null or t.plan_expire > now())
        ),
        'expire_bientot', (
          t.plan = 'premium'
          and t.plan_expire is not null
          and t.plan_expire > now()
          and t.plan_expire < now() + interval '7 days'
        ),
        'dernier_abonnement', (
          select jsonb_build_object(
            'formule',        a.formule,
            'montant',        a.montant,
            'date_debut',     a.date_debut,
            'date_fin',       a.date_fin,
            'statut',         a.statut,
            'moyen_paiement', a.moyen_paiement,
            'reference',      a.reference_paiement
          )
          from abonnements a
          where a.code = t.code
          order by a.quand desc
          limit 1
        )
      ) as row_json,
      t.cree_le as cree_t
      from tontines t
      where
        case p_filtre
          when 'premium'   then
            t.plan = 'premium'
            and (t.plan_expire is null or t.plan_expire > now())
          when 'gratuites' then
            coalesce(t.plan, 'free') != 'premium'
          when 'expires'   then
            t.plan = 'premium'
            and t.plan_expire is not null
            and t.plan_expire <= now()
          else true
        end
      order by t.cree_le desc
      limit p_limit offset p_offset
    ) sub
  );
end $$;

grant execute on function admin_dashboard_tontines(text, text, int, int) to anon;

-- ────────────────────────────────────────────────────────────
-- 4. admin_lister_abonnements
--    Liste des abonnements filtrée par statut
-- ────────────────────────────────────────────────────────────
create or replace function admin_lister_abonnements(
  p_cle    text,
  p_statut text default 'tous',
  p_limit  int  default 50
)
returns jsonb
language plpgsql security definer set search_path = public
as $$
begin
  if not _verif_admin_cle(p_cle) then return '[]'::jsonb; end if;

  return (
    select coalesce(jsonb_agg(jsonb_build_object(
      'id',              a.id,
      'code',            a.code,
      'nom_tontine',     t.data->>'nom',
      'formule',         a.formule,
      'montant',         a.montant,
      'devise',          a.devise,
      'date_debut',      a.date_debut,
      'date_fin',        a.date_fin,
      'statut',          a.statut,
      'active_par',      a.active_par,
      'moyen_paiement',  a.moyen_paiement,
      'reference',       a.reference_paiement,
      'note',            a.note,
      'quand',           a.quand
    ) order by a.quand desc), '[]'::jsonb)
    from abonnements a
    left join tontines t on t.code = a.code
    where
      case p_statut
        when 'actif'      then a.statut = 'actif'
        when 'expire'     then a.statut = 'expire'
        when 'en_attente' then a.statut = 'en_attente'
        else true
      end
    limit p_limit
  );
end $$;

grant execute on function admin_lister_abonnements(text, text, int) to anon;

-- ────────────────────────────────────────────────────────────
-- 5. admin_alertes  [FIX v1.2 — ORDER BY sur colonne SQL "prio"]
--    Alertes critiques : expirations proches, demandes en attente
-- ────────────────────────────────────────────────────────────
create or replace function admin_alertes(p_cle text)
returns jsonb
language plpgsql security definer set search_path = public
as $$
begin
  if not _verif_admin_cle(p_cle) then return '[]'::jsonb; end if;

  return (
    select coalesce(jsonb_agg(alerte order by prio), '[]'::jsonb)
    from (

      -- Abonnements expirant dans 7 jours (priorité 1 — critique)
      select jsonb_build_object(
        'type',     'expiration_proche',
        'titre',    count(*)::text || ' abonnement(s) expire(nt) dans moins de 7 jours',
        'detail',   string_agg(code || ' (' || to_char(plan_expire, 'DD/MM/YYYY') || ')', ', '),
        'nb',       count(*),
        'niveau',   'alerte'
      ) as alerte,
      1 as prio
      from tontines
      where plan = 'premium'
        and plan_expire > now()
        and plan_expire < now() + interval '7 days'
      having count(*) > 0

      union all

      -- Premium expirés non renouvelés (priorité 2)
      select jsonb_build_object(
        'type',     'abonnements_expires',
        'titre',    count(*)::text || ' tontine(s) Premium expirée(s)',
        'detail',   'Ces tontines sont repassées en mode gratuit',
        'nb',       count(*),
        'niveau',   'info'
      ) as alerte,
      2 as prio
      from tontines
      where plan = 'premium'
        and plan_expire is not null
        and plan_expire <= now()
      having count(*) > 0

      union all

      -- Demandes Premium en attente (priorité 1)
      select jsonb_build_object(
        'type',     'demandes_attente',
        'titre',    count(*)::text || ' demande(s) Premium en attente de validation',
        'detail',   'Vérifier l''onglet Demandes',
        'nb',       count(*),
        'niveau',   'alerte'
      ) as alerte,
      1 as prio
      from demandes_premium
      where statut = 'en attente'
      having count(*) > 0

      union all

      -- Tontines Premium inactives depuis 30 jours (priorité 3)
      select jsonb_build_object(
        'type',     'tontines_inactives',
        'titre',    count(*)::text || ' tontine(s) Premium sans activité depuis 30 jours',
        'detail',   'Pas de vote ni de prêt enregistré',
        'nb',       count(*),
        'niveau',   'info'
      ) as alerte,
      3 as prio
      from tontines
      where plan = 'premium'
        and (plan_expire is null or plan_expire > now())
        and cree_le < now() - interval '30 days'
        and (
          coalesce(jsonb_array_length(data->'votes'), 0) = 0
          and coalesce(jsonb_array_length(data->'prets'), 0) = 0
        )
      having count(*) > 0

    ) sub
  );
end $$;

grant execute on function admin_alertes(text) to anon;

-- ────────────────────────────────────────────────────────────
-- 6. admin_enregistrer_abonnement
--    Crée un abonnement Premium + met à jour tontines.plan
-- ────────────────────────────────────────────────────────────
create or replace function admin_enregistrer_abonnement(
  p_cle       text,
  p_code      text,
  p_formule   text    default 'mensuel',
  p_montant   int     default 2500,
  p_moyen     text    default null,
  p_reference text    default null,
  p_note      text    default null
)
returns boolean
language plpgsql security definer set search_path = public
as $$
declare
  v_date_fin timestamptz;
begin
  if not _verif_admin_cle(p_cle) then return false; end if;

  v_date_fin := case p_formule
    when 'annuel' then now() + interval '1 year'
    else               now() + interval '1 month'
  end;

  update abonnements
  set statut = 'expire'
  where code = upper(p_code) and statut = 'actif';

  insert into abonnements(
    code, formule, montant, date_debut, date_fin,
    statut, active_par, moyen_paiement, reference_paiement, note
  )
  values (
    upper(p_code),
    p_formule,
    case p_formule when 'annuel' then 25000 else coalesce(p_montant, 2500) end,
    now(), v_date_fin,
    'actif', 'ADMIN', p_moyen, p_reference, p_note
  );

  insert into admin_actions(code, action, detail, effectue_par)
  values (
    upper(p_code), 'ABONNEMENT_CREE',
    'Formule: ' || p_formule
    || ' | Montant: ' || coalesce(p_montant::text, '2500') || ' FCFA'
    || ' | Réf: '    || coalesce(p_reference, '-'),
    'ADMIN'
  );

  return true;
end $$;

grant execute on function admin_enregistrer_abonnement(text, text, text, int, text, text, text) to anon;

-- ────────────────────────────────────────────────────────────
-- 7. admin_stats_mensuelles
--    Évolution sur 12 mois : tontines, premium, revenus
-- ────────────────────────────────────────────────────────────
create or replace function admin_stats_mensuelles(p_cle text)
returns jsonb
language plpgsql security definer set search_path = public
as $$
begin
  if not _verif_admin_cle(p_cle) then return '[]'::jsonb; end if;

  return (
    select coalesce(jsonb_agg(jsonb_build_object(
      'mois',               to_char(m.mois, 'YYYY-MM'),
      'mois_label',         to_char(m.mois, 'Mon YYYY'),
      'nouvelles_tontines', coalesce(t.nb, 0),
      'premium_actives',    coalesce(p.nb, 0),
      'revenu_fcfa',        coalesce(a.montant, 0)
    ) order by m.mois), '[]'::jsonb)
    from (
      select generate_series(
        date_trunc('month', now() - interval '11 months'),
        date_trunc('month', now()),
        interval '1 month'
      ) as mois
    ) m
    left join (
      select date_trunc('month', cree_le) as mois, count(*) as nb
      from tontines
      group by 1
    ) t on t.mois = m.mois
    left join (
      select date_trunc('month', coalesce(plan_expire, now()) - interval '1 month') as mois,
             count(*) as nb
      from tontines
      where plan = 'premium'
      group by 1
    ) p on p.mois = m.mois
    left join (
      select date_trunc('month', quand) as mois, sum(montant)::int as montant
      from abonnements
      where statut = 'actif'
      group by 1
    ) a on a.mois = m.mois
  );
end $$;

grant execute on function admin_stats_mensuelles(text) to anon;

-- ────────────────────────────────────────────────────────────
-- 8. admin_top_tontines
--    Top 10 tontines par nombre de membres
-- ────────────────────────────────────────────────────────────
create or replace function admin_top_tontines(p_cle text)
returns jsonb
language plpgsql security definer set search_path = public
as $$
begin
  if not _verif_admin_cle(p_cle) then return '[]'::jsonb; end if;

  return (
    select coalesce(jsonb_agg(jsonb_build_object(
      'code',       code,
      'nom',        data->>'nom',
      'plan',       coalesce(plan, 'free'),
      'nb_membres', case
                      when jsonb_typeof(data->'membres') = 'array'
                        then jsonb_array_length(data->'membres')
                      else 0
                    end,
      'montant',    coalesce((data->>'montant')::int, 0)
    ) order by case
        when jsonb_typeof(data->'membres') = 'array'
          then jsonb_array_length(data->'membres')
        else 0
      end desc
    ), '[]'::jsonb)
    from (
      select code, data, plan
      from tontines
      order by case
          when jsonb_typeof(data->'membres') = 'array'
            then jsonb_array_length(data->'membres')
          else 0
        end desc
      limit 10
    ) t
  );
end $$;

grant execute on function admin_top_tontines(text) to anon;

-- ────────────────────────────────────────────────────────────
-- 9. admin_tontine_counts  [SOURCE: supabase-v17-fix-soft-delete.sql]
--    Compteurs unifiés : total, actives, premium, supprimées, etc.
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION admin_tontine_counts(p_cle text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $func_atc$
DECLARE
  v_admin_key text := 'TONTINE_ADMIN_2024';
  v_counts    jsonb;
  v_demandes  int := 0;
BEGIN
  IF p_cle != v_admin_key THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Cle admin incorrecte.');
  END IF;

  WITH cats AS (
    SELECT
      code,
      CASE
        WHEN status = 'deleted' OR deleted_at IS NOT NULL THEN 'deleted'
        WHEN status = 'suspended'                          THEN 'suspended'
        WHEN status = 'inactive'                           THEN 'inactive'
        WHEN plan = 'premium'
             AND data->>'planExpire' IS NOT NULL
             AND (data->>'planExpire')::timestamptz < now() THEN 'expire'
        WHEN plan = 'premium' THEN 'premium'
        ELSE 'gratuit'
      END AS cat
    FROM tontines
  )
  SELECT jsonb_build_object(
    'total',      COUNT(*) FILTER (WHERE cat != 'deleted'),
    'actives',    COUNT(*) FILTER (WHERE cat IN ('gratuit','premium')),
    'premium',    COUNT(*) FILTER (WHERE cat = 'premium'),
    'gratuites',  COUNT(*) FILTER (WHERE cat = 'gratuit'),
    'inactives',  COUNT(*) FILTER (WHERE cat = 'inactive'),
    'suspendues', COUNT(*) FILTER (WHERE cat = 'suspended'),
    'expirees',   COUNT(*) FILTER (WHERE cat = 'expire'),
    'supprimees', COUNT(*) FILTER (WHERE cat = 'deleted')
  )
  INTO v_counts
  FROM cats;

  BEGIN
    SELECT COUNT(*) INTO v_demandes
    FROM premium_requests
    WHERE statut IN ('en_attente', 'en attente', 'pending');
  EXCEPTION WHEN undefined_table THEN
    v_demandes := 0;
  END;

  RETURN v_counts || jsonb_build_object(
    'ok',                  true,
    'demandes_en_attente', v_demandes
  );
END;
$func_atc$;

GRANT EXECUTE ON FUNCTION admin_tontine_counts(text) TO anon, authenticated;

-- ────────────────────────────────────────────────────────────
-- 10. admin_lister_tontines  [SOURCE: supabase-v17-fix-soft-delete.sql v17 FINAL]
--     Liste toutes les tontines (soft-delete aware) pour le dashboard admin
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION admin_lister_tontines(p_cle text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $func_alt$
DECLARE
  v_admin_key text := 'TONTINE_ADMIN_2024';
  v_result    jsonb;
BEGIN
  IF p_cle != v_admin_key THEN
    RETURN '[]'::jsonb;
  END IF;

  SELECT jsonb_agg(
    jsonb_build_object(
      'code',             t.code,
      'nom',              COALESCE(
                            NULLIF(trim(t.data->>'nom'), ''),
                            'Tontine sans nom'
                          ),
      'president',        COALESCE(
                            t.data->'gestionnaire'->>'nom',
                            t.data->>'gestionnaire',
                            t.data->>'president',
                            t.data->>'created_by',
                            t.data->>'owner'
                          ),
      'membres',          COALESCE(
                            jsonb_array_length(t.data->'membres'),
                            0
                          ),
      'plan',             COALESCE(t.plan, 'free'),
      'plan_expire',      t.data->>'planExpire',
      'cree',             to_char(t.created_at, 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
      'status',           COALESCE(t.status, 'active'),
      'deleted_at',       CASE WHEN t.deleted_at IS NOT NULL
                               THEN to_char(t.deleted_at, 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
                               ELSE NULL END,
      'deleted_by',       t.deleted_by,
      'deletion_reason',  t.deletion_reason,
      'invitation_active', t.invitation_code_active
    )
    ORDER BY
      CASE WHEN COALESCE(t.status,'active') = 'deleted' THEN 1 ELSE 0 END ASC,
      t.created_at DESC
  )
  INTO v_result
  FROM tontines t;

  RETURN COALESCE(v_result, '[]'::jsonb);
END;
$func_alt$;

GRANT EXECUTE ON FUNCTION admin_lister_tontines(text) TO anon, authenticated;

-- ────────────────────────────────────────────────────────────
-- 11. tontines_set_updated_at  [SOURCE: supabase-v17-fix-soft-delete.sql]
--     Trigger : met à jour updated_at automatiquement
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION tontines_set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $func_sua$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$func_sua$;

DROP TRIGGER IF EXISTS trg_tontines_updated_at ON tontines;

CREATE TRIGGER trg_tontines_updated_at
  BEFORE UPDATE ON tontines
  FOR EACH ROW
  EXECUTE FUNCTION tontines_set_updated_at();

-- ────────────────────────────────────────────────────────────
-- 12. admin_lister_demandes  [SOURCE: supabase-fix-v12-premium-requests.sql FINAL]
--     Lit depuis premium_requests (pas demandes_premium) — v12 final
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION admin_lister_demandes(p_cle text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_valide boolean;
BEGIN
  v_valide := (p_cle IS NOT NULL AND length(trim(p_cle)) >= 4);
  IF NOT v_valide THEN
    RAISE EXCEPTION 'CLE_INVALIDE';
  END IF;

  RETURN (
    SELECT jsonb_agg(
      jsonb_build_object(
        'id',          pr.id,
        'code',        pr.tontine_code,
        'statut',      pr.status,
        'gestionnaire', pr.requester_name,
        'nom',         pr.requester_name,
        'contact',     pr.contact,
        'formule',     pr.plan,
        'montant',     pr.amount,
        'plateforme',  pr.platform,
        'motif_refus', pr.rejection_reason,
        'traite_par',  pr.reviewed_by,
        'traite_le',   pr.reviewed_at,
        'quand',       to_char(pr.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
        'nom_tontine', coalesce(
                          t.data->>'nom',
                          t.data->>'titre',
                          pr.tontine_code
                        ),
        'nb_membres',  coalesce(
                          jsonb_array_length(t.data->'membres'),
                          0
                        )
      )
      ORDER BY pr.created_at DESC
    )
    FROM premium_requests pr
    LEFT JOIN tontines t ON upper(t.code) = upper(pr.tontine_code)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION admin_lister_demandes(text) TO anon;
GRANT EXECUTE ON FUNCTION admin_lister_demandes(text) TO authenticated;

-- ────────────────────────────────────────────────────────────
-- 13. admin_activer_premium  [SOURCE: supabase-fix-v12-premium-requests.sql]
--     Active le plan Premium + met à jour premium_requests
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION admin_activer_premium(
  p_cle  text,
  p_code text,
  p_mois integer DEFAULT 1
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_code      text := upper(trim(p_code));
  v_expire    timestamptz;
  v_rows      integer;
BEGIN
  IF p_cle IS NULL OR length(trim(p_cle)) < 4 THEN
    RAISE EXCEPTION 'CLE_INVALIDE';
  END IF;

  v_expire := now() + (p_mois || ' months')::interval;

  UPDATE tontines
  SET
    plan        = 'premium',
    plan_expire = v_expire,
    updated_at  = now()
  WHERE upper(code) = v_code;

  GET DIAGNOSTICS v_rows = ROW_COUNT;

  IF v_rows = 0 THEN
    BEGIN
      UPDATE tontines
      SET plan = 'premium', updated_at = now()
      WHERE upper(code) = v_code;
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
  END IF;

  UPDATE premium_requests
  SET
    status      = 'approuvee',
    reviewed_by = 'admin',
    reviewed_at = now()
  WHERE tontine_code = v_code
    AND status       = 'en_attente';

  RETURN true;
END;
$$;

GRANT EXECUTE ON FUNCTION admin_activer_premium(text, text, integer) TO anon;
GRANT EXECUTE ON FUNCTION admin_activer_premium(text, text, integer) TO authenticated;

-- ────────────────────────────────────────────────────────────
-- 14. admin_refuser_demande  [SOURCE: supabase-fix-v12-premium-requests.sql]
--     Refuse une demande Premium avec motif
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION admin_refuser_demande(
  p_cle   text,
  p_code  text,
  p_motif text DEFAULT ''
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_code text := upper(trim(p_code));
BEGIN
  IF p_cle IS NULL OR length(trim(p_cle)) < 4 THEN
    RAISE EXCEPTION 'CLE_INVALIDE';
  END IF;

  UPDATE premium_requests
  SET
    status           = 'refusee',
    rejection_reason = coalesce(nullif(trim(p_motif), ''), 'Demande refusée par l''administrateur.'),
    reviewed_by      = 'admin',
    reviewed_at      = now()
  WHERE tontine_code = v_code
    AND status       = 'en_attente';

  RETURN true;
END;
$$;

GRANT EXECUTE ON FUNCTION admin_refuser_demande(text, text, text) TO anon;
GRANT EXECUTE ON FUNCTION admin_refuser_demande(text, text, text) TO authenticated;

-- ────────────────────────────────────────────────────────────
-- RLS pour les tables admin (accès uniquement via RPC)
-- ────────────────────────────────────────────────────────────
drop policy if exists "abonnements_no_direct" on abonnements;
create policy "abonnements_no_direct"
  on abonnements for all to anon using (false);

drop policy if exists "admin_actions_no_direct" on admin_actions;
create policy "admin_actions_no_direct"
  on admin_actions for all to anon using (false);

drop policy if exists "admin_config_no_access" on admin_config;
create policy "admin_config_no_access"
  on admin_config for all to anon using (false);

drop policy if exists "demandes_premium_insert" on demandes_premium;
create policy "demandes_premium_insert"
  on demandes_premium for insert to anon with check (true);

drop policy if exists "demandes_premium_select" on demandes_premium;
create policy "demandes_premium_select"
  on demandes_premium for select to anon using (true);

-- ────────────────────────────────────────────────────────────
-- Vérification post-déploiement
-- ────────────────────────────────────────────────────────────
DO $verify008$
DECLARE
  v_fns text[] := ARRAY[
    '_verif_admin_cle','admin_stats_globales','admin_dashboard_tontines',
    'admin_lister_abonnements','admin_alertes','admin_enregistrer_abonnement',
    'admin_stats_mensuelles','admin_top_tontines',
    'admin_tontine_counts','admin_lister_tontines','tontines_set_updated_at',
    'admin_lister_demandes','admin_activer_premium','admin_refuser_demande'
  ];
  v_fn text;
  v_ok boolean;
BEGIN
  FOREACH v_fn IN ARRAY v_fns LOOP
    SELECT EXISTS(SELECT 1 FROM pg_proc WHERE proname = v_fn) INTO v_ok;
    RAISE NOTICE '008 % : %', v_fn, CASE WHEN v_ok THEN 'OK' ELSE 'MANQUANT' END;
  END LOOP;
END;
$verify008$;
-- ============================================================
-- FIN 008_rpcs_admin.sql
-- ============================================================
-- ============================================================
-- TontineClair — Migration 009 : RPCs Financier, KYC & Support
-- Sources    : supabase-subscriptions.sql
--              supabase-prets-pending.sql
--              supabase-decaissements-pending.sql
--              supabase-depenses-pending.sql
--              supabase-kyc.sql
--              supabase-admin-team.sql (support + admin team RPCs)
-- Dépendances: 003_tables_financier.sql, 004_tables_kyc_notifs.sql,
--              005_tables_admin_team_support.sql, 008_rpcs_admin.sql
-- Idempotent : CREATE OR REPLACE FUNCTION partout
-- ============================================================
-- Fonctions incluses (27) :
--   Abonnements (6): est_premium, lire_abonnement_tontine, verif_limite_tontines,
--     verif_limite_membres, enregistrer_abonnement_web, expirer_abonnements_obsoletes
--   Prêts (3): admin_valider_pret, admin_rejeter_pret, crediter_remboursement_sycapay
--   Décaissements (3): admin_lister_decaissements, admin_valider_decaissement,
--     admin_rejeter_decaissement
--   Dépenses (2): admin_valider_depense, admin_rejeter_depense
--   KYC (3): admin_lister_kyc, admin_valider_kyc, admin_rejeter_kyc
--   Admin Team (4): admin_lister_membres, admin_creer_membre, admin_modifier_membre,
--     admin_auth_membre
--   Messagerie (4): admin_lister_messages, admin_envoyer_message, admin_marquer_lu,
--     admin_compter_non_lus
--   Support (6): generer_ref_ticket, support_ouvrir_ticket, support_mes_tickets,
--     admin_lister_tickets, support_messages_ticket, support_repondre,
--     admin_changer_statut_ticket
-- ============================================================

-- ============================================================
-- SECTION A : Abonnements & Limites
-- Source : supabase-subscriptions.sql
-- ============================================================

-- ────────────────────────────────────────────────────────────
-- A1. _sub_update_modifie_le (trigger helper pour subscriptions)
-- ────────────────────────────────────────────────────────────
create or replace function _sub_update_modifie_le()
returns trigger language plpgsql as $$
begin
  new.modifie_le := now();
  return new;
end $$;

drop trigger if exists trg_sub_modifie_le on subscriptions;
create trigger trg_sub_modifie_le
  before update on subscriptions
  for each row execute function _sub_update_modifie_le();

-- ────────────────────────────────────────────────────────────
-- A2. est_premium
--     Vérifie si une tontine a un abonnement Premium actif
--     Double source : subscriptions (nouvelle) + tontines.plan (fallback)
-- ────────────────────────────────────────────────────────────
create or replace function est_premium(p_code text)
returns boolean
language plpgsql security definer set search_path = public
as $$
declare
  v_ok boolean := false;
begin
  begin
    select exists(
      select 1 from subscriptions
      where code = upper(p_code)
        and plan in ('premium_monthly','premium_yearly')
        and status in ('active','grace_period')
        and (expires_at is null or expires_at > now())
    ) into v_ok;
  exception when undefined_table then
    v_ok := false;
  end;

  if v_ok then return true; end if;

  begin
    select exists(
      select 1 from tontines
      where code = upper(p_code)
        and plan = 'premium'
        and (plan_expire is null or plan_expire > now())
    ) into v_ok;
  exception when undefined_column then
    v_ok := false;
  end;

  return coalesce(v_ok, false);
end $$;

grant execute on function est_premium(text) to anon;

-- ────────────────────────────────────────────────────────────
-- A3. lire_abonnement_tontine
--     Retourne le détail de l'abonnement actif pour une tontine
-- ────────────────────────────────────────────────────────────
create or replace function lire_abonnement_tontine(p_code text)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_sub   subscriptions%rowtype;
  v_plan  text := 'free';
  v_exp   timestamptz;
begin
  select * into v_sub
  from subscriptions
  where code = upper(p_code)
    and status in ('active','grace_period','pending')
  order by cree_le desc
  limit 1;

  if found then
    return jsonb_build_object(
      'plan',             v_sub.plan,
      'status',           v_sub.status,
      'platform',         v_sub.platform,
      'provider',         v_sub.provider,
      'product_id',       v_sub.product_id,
      'started_at',       v_sub.started_at,
      'expires_at',       v_sub.expires_at,
      'auto_renew',       v_sub.auto_renew,
      'last_verified_at', v_sub.last_verified_at,
      'montant_fcfa',     v_sub.montant_fcfa
    );
  end if;

  begin
    select t.plan, t.plan_expire
    into v_plan, v_exp
    from tontines t
    where t.code = upper(p_code)
    limit 1;
  exception when others then null;
  end;

  if v_plan = 'premium' then
    return jsonb_build_object(
      'plan',     'premium_monthly',
      'status',   case when (v_exp is null or v_exp > now()) then 'active' else 'expired' end,
      'platform', 'web',
      'provider', 'web',
      'expires_at', v_exp,
      'auto_renew', false
    );
  end if;

  return jsonb_build_object(
    'plan',     'free',
    'status',   'active',
    'platform', 'web',
    'provider', 'web',
    'auto_renew', false
  );
end $$;

grant execute on function lire_abonnement_tontine(text) to anon;

-- ────────────────────────────────────────────────────────────
-- A4. verif_limite_tontines (toujours autorisé — logique côté Flutter)
-- ────────────────────────────────────────────────────────────
create or replace function verif_limite_tontines(p_code_proprietaire text)
returns jsonb
language plpgsql security definer set search_path = public
as $$
begin
  return jsonb_build_object(
    'autorise', true,
    'premium',  false,
    'nb',       0,
    'message',  ''
  );
end $$;

grant execute on function verif_limite_tontines(text) to anon;

-- ────────────────────────────────────────────────────────────
-- A5. verif_limite_membres
--     Vérifie si l'ajout d'un membre est autorisé (5 max gratuit)
-- ────────────────────────────────────────────────────────────
create or replace function verif_limite_membres(p_code text)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_premium  boolean := false;
  v_nb       int     := 0;
  v_max      int     := 5;
  v_autorise boolean := false;
begin
  v_premium := est_premium(p_code);

  begin
    select
      case
        when jsonb_typeof(data->'membres') = 'array'
          then jsonb_array_length(data->'membres')
        else 0
      end
    into v_nb
    from tontines
    where code = upper(p_code)
    limit 1;
  exception when others then
    v_nb := 0;
  end;

  v_max      := case when v_premium then 999 else 5 end;
  v_autorise := v_nb < v_max;

  return jsonb_build_object(
    'autorise', v_autorise,
    'premium',  v_premium,
    'nb',       v_nb,
    'max',      v_max,
    'message',  case when not v_autorise then
      case when v_premium then
        'Limite de membres Premium atteinte.'
      else
        'La formule gratuite est limitée à 5 membres. Passez à Premium pour ajouter davantage de membres.'
      end
    else '' end
  );
end $$;

grant execute on function verif_limite_membres(text) to anon;

-- ────────────────────────────────────────────────────────────
-- A6. enregistrer_abonnement_web
--     Crée un abonnement web validé + synchronise tontines.plan
-- ────────────────────────────────────────────────────────────
create or replace function enregistrer_abonnement_web(
  p_code       text,
  p_plan       text    default 'premium_monthly',
  p_montant    int     default 2500,
  p_reference  text    default null,
  p_note       text    default null,
  p_active_par text    default 'ADMIN'
)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_expires_at timestamptz;
  v_new_id     bigint;
begin
  v_expires_at := case p_plan
    when 'premium_yearly'  then now() + interval '1 year'
    else                        now() + interval '1 month'
  end;

  update subscriptions
  set status     = 'expired',
      modifie_le = now()
  where code = upper(p_code)
    and status in ('active','grace_period');

  insert into subscriptions(
    code, plan, platform, provider,
    started_at, expires_at, status, auto_renew,
    montant_fcfa, reference, note, active_par,
    last_verified_at
  )
  values (
    upper(p_code), p_plan, 'web', 'web',
    now(), v_expires_at, 'active', false,
    case p_plan when 'premium_yearly' then 25000 else coalesce(p_montant, 2500) end,
    p_reference, p_note, p_active_par,
    now()
  )
  returning id into v_new_id;

  begin
    update tontines
    set plan       = 'premium',
        plan_expire = v_expires_at
    where code = upper(p_code);
  exception when undefined_column then null;
  end;

  begin
    insert into admin_actions(code, action, detail, effectue_par)
    values (
      upper(p_code),
      'ABONNEMENT_WEB_CREE',
      'Plan: ' || p_plan || ' | Montant: ' || coalesce(p_montant::text,'2500') || ' FCFA | Réf: ' || coalesce(p_reference,'-'),
      coalesce(p_active_par, 'ADMIN')
    );
  exception when others then null;
  end;

  return jsonb_build_object(
    'ok',         true,
    'id',         v_new_id,
    'code',       upper(p_code),
    'plan',       p_plan,
    'expires_at', v_expires_at
  );
end $$;

grant execute on function enregistrer_abonnement_web(text, text, int, text, text, text) to anon;

-- ────────────────────────────────────────────────────────────
-- A7. expirer_abonnements_obsoletes
--     Cron/trigger : passe statut → 'expired' pour les abonnements périmés
-- ────────────────────────────────────────────────────────────
create or replace function expirer_abonnements_obsoletes()
returns int
language plpgsql security definer set search_path = public
as $$
declare v_nb int;
begin
  update subscriptions
  set status     = 'expired',
      modifie_le = now()
  where status = 'active'
    and expires_at is not null
    and expires_at <= now();

  get diagnostics v_nb = row_count;

  begin
    update tontines t
    set plan       = 'free',
        plan_expire = t.plan_expire
    where t.plan = 'premium'
      and t.plan_expire is not null
      and t.plan_expire <= now()
      and not exists (
        select 1 from subscriptions s
        where s.code = t.code
          and s.status in ('active','grace_period')
      );
  exception when undefined_column then null;
  end;

  return v_nb;
end $$;

grant execute on function expirer_abonnements_obsoletes() to anon;

-- RLS subscriptions
alter table subscriptions enable row level security;
drop policy if exists "subscriptions_no_direct" on subscriptions;
create policy "subscriptions_no_direct"
  on subscriptions for all to anon using (false);

-- ============================================================
-- SECTION B : Prêts Internes
-- Source : supabase-prets-pending.sql
-- ============================================================

-- ────────────────────────────────────────────────────────────
-- B1. admin_valider_pret
--     Valide un prêt pending : débite caisse + crée prêt JSON + journal
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_valider_pret(
  p_cle  text,
  p_id   bigint
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_row        public.prets_pending%ROWTYPE;
  v_tontine    public.tontines%ROWTYPE;
  v_data       jsonb;
  v_caisse     jsonb;
  v_mouvements jsonb;
  v_prets      jsonb;
  v_journal    jsonb;
  v_solde      integer;
  v_now        text := to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"');
  v_interet    integer;
  v_total_du   integer;
  v_mensualite integer;
  v_echeancier jsonb;
  v_i          integer;
  v_date_ech   text;
BEGIN
  IF p_cle IS DISTINCT FROM current_setting('app.admin_key', true) THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.admin_config WHERE cle = p_cle AND actif = true LIMIT 1
    ) THEN
      RETURN jsonb_build_object('ok', false, 'erreur', 'Clé admin invalide');
    END IF;
  END IF;

  SELECT * INTO v_row FROM public.prets_pending WHERE id = p_id AND statut = 'pending';
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Demande introuvable ou déjà traitée');
  END IF;

  SELECT * INTO v_tontine FROM public.tontines
    WHERE UPPER(code) = UPPER(v_row.code) LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Tontine introuvable');
  END IF;

  v_data := v_tontine.data;
  v_caisse     := COALESCE(v_data->'caisse', '{"mouvements":[]}'::jsonb);
  v_mouvements := COALESCE(v_caisse->'mouvements', '[]'::jsonb);

  SELECT COALESCE(SUM(
    CASE
      WHEN (m->>'type') IN ('depot','cotisation','remboursement','apport') THEN (m->>'montant')::integer
      WHEN (m->>'type') IN ('depense','pret','penalite','correction','decaissement') THEN -((m->>'montant')::integer)
      ELSE 0
    END
  ), 0)
  INTO v_solde
  FROM jsonb_array_elements(v_mouvements) AS m;

  IF v_solde < v_row.montant_net THEN
    RETURN jsonb_build_object(
      'ok',     false,
      'erreur', format('Solde insuffisant : %s disponible, %s requis', v_solde, v_row.montant_net)
    );
  END IF;

  v_mouvements := v_mouvements || jsonb_build_object(
    'id',          v_row.reference || 'D',
    'type',        'depense',
    'montant',     v_row.montant_net,
    'description', format('Prêt à %s (Mobile Money %s)', v_row.emprunteur_nom, v_row.operateur),
    'gestionnaire', v_row.gestionnaire,
    'date',        v_now,
    'reference',   v_row.reference,
    'methode',     v_row.operateur,
    'beneficiaire', v_row.numero_beneficiaire
  );
  v_caisse := jsonb_set(v_caisse, '{mouvements}', v_mouvements);
  v_data   := jsonb_set(v_data, '{caisse}', v_caisse);

  v_interet    := round(v_row.montant * v_row.taux / 100);
  v_total_du   := v_row.montant + v_interet;
  v_mensualite := round(v_total_du::numeric / v_row.durees_mois);

  v_echeancier := '[]'::jsonb;
  FOR v_i IN 1..v_row.durees_mois LOOP
    v_date_ech := to_char(
      (now() AT TIME ZONE 'UTC') + (v_i * interval '30 days'),
      'YYYY-MM-DD"T"HH24:MI:SS"Z"'
    );
    v_echeancier := v_echeancier || jsonb_build_array(
      jsonb_build_object(
        'mois',    v_i,
        'date',    v_date_ech,
        'montant', CASE WHEN v_i = v_row.durees_mois
                        THEN v_total_du - v_mensualite * (v_row.durees_mois - 1)
                        ELSE v_mensualite END
      )
    );
  END LOOP;

  v_prets := COALESCE(v_data->'prets', '[]'::jsonb);
  v_prets := v_prets || jsonb_build_array(
    jsonb_build_object(
      'id',              v_row.reference,
      'emprunteurId',    v_row.emprunteur_id,
      'emprunteurNom',   v_row.emprunteur_nom,
      'montant',         v_row.montant,
      'fraisTransaction', v_row.frais_transaction,
      'montantNet',      v_row.montant_net,
      'taux',            v_row.taux,
      'dureesMois',      v_row.durees_mois,
      'dateDebut',       v_now,
      'statut',          'en_cours',
      'remboursements',  '[]'::jsonb,
      'echeancier',      v_echeancier,
      'gestionnaire',    v_row.gestionnaire,
      'reference',       v_row.reference,
      'operateur',       v_row.operateur,
      'numeroBeneficiaire', v_row.numero_beneficiaire,
      'nomBeneficiaire', v_row.nom_beneficiaire,
      'resteADu',        v_total_du,
      'totalDu',         v_total_du
    )
  );
  v_data := jsonb_set(v_data, '{prets}', v_prets);

  v_journal := COALESCE(v_data->'journal', '[]'::jsonb);
  v_journal := jsonb_build_array(
    jsonb_build_object(
      'quoi',        format('PRÊT VALIDÉ — %s — %s %s — %s%% — %s mois — via %s',
                            v_row.emprunteur_nom, v_row.montant_net, v_row.devise,
                            v_row.taux, v_row.durees_mois, v_row.operateur),
      'gestionnaire', v_row.gestionnaire,
      'quand',       v_now,
      'reference',   v_row.reference
    )
  ) || v_journal;
  v_data := jsonb_set(v_data, '{journal}', v_journal);

  UPDATE public.tontines SET data = v_data WHERE UPPER(code) = UPPER(v_row.code);
  UPDATE public.prets_pending SET statut = 'validee', validated_at = now() WHERE id = p_id;

  RETURN jsonb_build_object('ok', true, 'pret_reference', v_row.reference,
    'montant_net', v_row.montant_net, 'emprunteur', v_row.emprunteur_nom);
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_valider_pret(text, bigint) TO anon, authenticated;

-- ────────────────────────────────────────────────────────────
-- B2. admin_rejeter_pret
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_rejeter_pret(
  p_cle   text,
  p_id    bigint,
  p_motif text DEFAULT 'Rejeté par l''administrateur'
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.prets_pending WHERE id = p_id AND statut = 'pending') THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Demande introuvable ou déjà traitée');
  END IF;
  UPDATE public.prets_pending
    SET statut = 'rejetee', motif_rejet = p_motif, validated_at = now()
    WHERE id = p_id;
  RETURN jsonb_build_object('ok', true);
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_rejeter_pret(text, bigint, text) TO anon, authenticated;

-- ────────────────────────────────────────────────────────────
-- B3. crediter_remboursement_sycapay
--     Crédite caisse + met à jour prêt après remboursement SycaPay
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.crediter_remboursement_sycapay(
  p_code         text,
  p_montant      integer,
  p_reference    text,
  p_num_commande text,
  p_operateur    text,
  p_pret_id      text,
  p_emprunteur_id   text,
  p_emprunteur_nom  text,
  p_description  text,
  p_now          text DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_tontine      public.tontines%ROWTYPE;
  v_data         jsonb;
  v_caisse       jsonb;
  v_mouvements   jsonb;
  v_prets        jsonb;
  v_pret         jsonb;
  v_rembs        jsonb;
  v_journal      jsonb;
  v_now          text;
  v_idx          integer := -1;
  v_i            integer := 0;
  v_total_du     integer;
  v_total_remb   integer;
  v_reste        integer;
  v_pret_solde   boolean := false;
  v_p            jsonb;
BEGIN
  v_now := COALESCE(p_now, to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'));

  SELECT * INTO v_tontine FROM public.tontines WHERE UPPER(code) = UPPER(p_code) LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Tontine introuvable');
  END IF;

  v_data := v_tontine.data;

  -- Idempotence
  FOR v_p IN SELECT jsonb_array_elements(COALESCE(v_data->'prets', '[]'::jsonb)) LOOP
    FOR v_i IN 0..(jsonb_array_length(COALESCE(v_p->'remboursements','[]'::jsonb))-1) LOOP
      IF (v_p->'remboursements'->v_i->>'reference') = p_reference
      OR (v_p->'remboursements'->v_i->>'id') = p_reference THEN
        RETURN jsonb_build_object('ok', true, 'idempotent', true);
      END IF;
    END LOOP;
  END LOOP;

  v_caisse     := COALESCE(v_data->'caisse', '{"mouvements":[]}'::jsonb);
  v_mouvements := COALESCE(v_caisse->'mouvements', '[]'::jsonb);
  v_mouvements := v_mouvements || jsonb_build_object(
    'id',          p_reference || 'R',
    'type',        'remboursement',
    'montant',     p_montant,
    'description', CASE WHEN p_description <> ''
                        THEN p_description
                        ELSE format('Remboursement prêt %s via SycaPay', p_emprunteur_nom) END,
    'gestionnaire', p_emprunteur_nom,
    'date',        v_now,
    'reference',   p_reference,
    'methode',     p_operateur,
    'numCommande', p_num_commande
  );
  v_caisse := jsonb_set(v_caisse, '{mouvements}', v_mouvements);
  v_data   := jsonb_set(v_data, '{caisse}', v_caisse);

  v_prets := COALESCE(v_data->'prets', '[]'::jsonb);
  v_idx   := -1;
  FOR v_i IN 0..(jsonb_array_length(v_prets)-1) LOOP
    IF (v_prets->v_i->>'id') = p_pret_id THEN v_idx := v_i; EXIT; END IF;
  END LOOP;

  IF v_idx >= 0 THEN
    v_pret  := v_prets->v_idx;
    v_rembs := COALESCE(v_pret->'remboursements', '[]'::jsonb);
    v_rembs := v_rembs || jsonb_build_array(
      jsonb_build_object('id', p_reference, 'montant', p_montant, 'date', v_now,
        'methode', p_operateur, 'reference', p_reference, 'numCommande', p_num_commande)
    );
    SELECT COALESCE(SUM((r->>'montant')::integer), 0) INTO v_total_remb
    FROM jsonb_array_elements(v_rembs) AS r;
    v_total_du := COALESCE((v_pret->>'totalDu')::integer, (v_pret->>'resteADu')::integer, 0);
    IF v_total_du = 0 THEN
      v_total_du := (v_pret->>'montant')::integer
                  + round(((v_pret->>'montant')::integer * (v_pret->>'taux')::numeric / 100));
    END IF;
    v_reste      := GREATEST(0, v_total_du - v_total_remb);
    v_pret_solde := v_reste = 0;
    v_pret := v_pret || jsonb_build_object(
      'remboursements', v_rembs, 'resteADu', v_reste, 'totalRembourse', v_total_remb,
      'statut', CASE WHEN v_pret_solde THEN 'soldé' ELSE 'en_cours' END);
    v_prets := jsonb_set(v_prets, ARRAY[v_idx::text], v_pret);
    v_data  := jsonb_set(v_data, '{prets}', v_prets);
  END IF;

  v_journal := COALESCE(v_data->'journal', '[]'::jsonb);
  v_journal := jsonb_build_array(jsonb_build_object(
    'quoi', format('REMBOURSEMENT SycaPay — %s — %s XOF — Réf: %s%s',
                   p_emprunteur_nom, p_montant, p_reference,
                   CASE WHEN v_pret_solde THEN ' — SOLDÉ ✓' ELSE '' END),
    'gestionnaire', p_emprunteur_nom, 'quand', v_now, 'reference', p_reference
  )) || v_journal;
  v_data := jsonb_set(v_data, '{journal}', v_journal);

  UPDATE public.tontines SET data = v_data WHERE UPPER(code) = UPPER(p_code);
  RETURN jsonb_build_object('ok', true, 'pret_solde', v_pret_solde, 'reste', v_reste);
END;
$$;

GRANT EXECUTE ON FUNCTION public.crediter_remboursement_sycapay(
  text, integer, text, text, text, text, text, text, text, text
) TO anon, authenticated;

-- ============================================================
-- SECTION C : Décaissements
-- Source : supabase-decaissements-pending.sql
-- ============================================================

-- ────────────────────────────────────────────────────────────
-- C1. admin_lister_decaissements
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_lister_decaissements(
  p_cle    TEXT,
  p_statut TEXT DEFAULT 'tous'
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_cle_attendue TEXT := current_setting('app.admin_key', true);
  v_rows         JSONB;
BEGIN
  IF v_cle_attendue IS NULL OR v_cle_attendue = '' THEN
    IF p_cle NOT LIKE 'tc-admin%' THEN
      RETURN jsonb_build_object('ok', false, 'erreur', 'Clé admin invalide');
    END IF;
  ELSIF p_cle <> v_cle_attendue THEN
    IF NOT EXISTS (SELECT 1 FROM public.admin_config WHERE cle = p_cle AND actif = true LIMIT 1) THEN
      RETURN jsonb_build_object('ok', false, 'erreur', 'Clé admin invalide');
    END IF;
  END IF;

  IF p_statut = 'tous' THEN
    SELECT jsonb_agg(row_to_json(d.*)::jsonb ORDER BY d.created_at DESC) INTO v_rows
    FROM public.decaissements_pending d;
  ELSE
    SELECT jsonb_agg(row_to_json(d.*)::jsonb ORDER BY d.created_at DESC) INTO v_rows
    FROM public.decaissements_pending d WHERE d.statut = p_statut;
  END IF;

  RETURN COALESCE(v_rows, '[]'::jsonb);
EXCEPTION WHEN OTHERS THEN
  RETURN '[]'::jsonb;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_lister_decaissements(TEXT, TEXT) TO anon, authenticated;

-- ────────────────────────────────────────────────────────────
-- C2. admin_valider_decaissement
--     Débite caisse + ajoute mouvement JSON + marque validée
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_valider_decaissement(
  p_cle TEXT,
  p_id  BIGINT
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_cle_attendue  TEXT := current_setting('app.admin_key', true);
  v_dec           public.decaissements_pending%ROWTYPE;
  v_tontine_data  JSONB;
  v_caisse        JSONB;
  v_mouvements    JSONB;
  v_journal       JSONB;
  v_solde         INTEGER;
  v_ref           TEXT;
  v_now           TEXT;
  v_new_mouvement JSONB;
BEGIN
  IF v_cle_attendue IS NULL OR v_cle_attendue = '' THEN
    IF p_cle NOT LIKE 'tc-admin%' THEN
      RETURN jsonb_build_object('ok', false, 'erreur', 'Clé admin invalide');
    END IF;
  ELSIF p_cle <> v_cle_attendue THEN
    IF NOT EXISTS (SELECT 1 FROM public.admin_config WHERE cle = p_cle AND actif = true LIMIT 1) THEN
      RETURN jsonb_build_object('ok', false, 'erreur', 'Clé admin invalide');
    END IF;
  END IF;

  SELECT * INTO v_dec FROM public.decaissements_pending WHERE id = p_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'erreur', 'Décaissement introuvable'); END IF;
  IF v_dec.statut <> 'pending' THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Décaissement déjà traité (statut: ' || v_dec.statut || ')');
  END IF;

  SELECT data INTO v_tontine_data FROM public.tontines WHERE UPPER(code) = UPPER(v_dec.code);
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'erreur', 'Tontine introuvable: ' || v_dec.code); END IF;

  v_caisse     := COALESCE(v_tontine_data->'caisse', '{"mouvements":[]}'::jsonb);
  v_mouvements := COALESCE(v_caisse->'mouvements', '[]'::jsonb);

  SELECT COALESCE(SUM(CASE
    WHEN (m->>'type') IN ('depot','cotisation','remboursement','apport') THEN  (m->>'montant')::integer
    WHEN (m->>'type') IN ('depense','pret','penalite','correction','decaissement') THEN -((m->>'montant')::integer)
    ELSE 0 END), 0)
  INTO v_solde FROM jsonb_array_elements(v_mouvements) AS m;

  IF v_solde < v_dec.montant_net THEN
    RETURN jsonb_build_object('ok', false, 'erreur',
      format('Solde caisse insuffisant : %s %s disponible, %s %s requis',
             v_solde, v_dec.devise, v_dec.montant_net, v_dec.devise));
  END IF;

  v_ref := COALESCE(NULLIF(v_dec.reference, ''), 'DEC-' || EXTRACT(EPOCH FROM NOW())::BIGINT::TEXT);
  v_now := to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"');

  v_new_mouvement := jsonb_build_object(
    'id', v_ref, 'type', 'decaissement', 'montant', v_dec.montant_net,
    'description', format('Décaissement tour %s — %s — Mobile Money %s',
                          v_dec.numer_tour, v_dec.beneficiaire_nom, upper(v_dec.operateur)),
    'gestionnaire', v_dec.gestionnaire, 'date', v_now, 'reference', v_ref,
    'methode', v_dec.operateur, 'numero_beneficiaire', v_dec.numero_beneficiaire,
    'beneficiaire_id', v_dec.beneficiaire_id, 'beneficiaire_nom', v_dec.beneficiaire_nom,
    'numer_tour', v_dec.numer_tour, 'commission', v_dec.commission,
    'montant_brut', v_dec.montant, 'decaissement_id', p_id
  );

  IF jsonb_typeof(v_caisse) = 'object' THEN
    v_mouvements := COALESCE(v_caisse->'mouvements', '[]'::jsonb);
    v_caisse := jsonb_set(v_caisse, '{mouvements}', v_mouvements || jsonb_build_array(v_new_mouvement));
  ELSIF jsonb_typeof(v_caisse) = 'array' THEN
    v_caisse := jsonb_build_object('mouvements', v_caisse || jsonb_build_array(v_new_mouvement));
  ELSE
    v_caisse := jsonb_build_object('mouvements', jsonb_build_array(v_new_mouvement));
  END IF;

  v_tontine_data := jsonb_set(v_tontine_data, '{caisse}', v_caisse);
  v_journal := COALESCE(v_tontine_data->'journal', '[]'::jsonb);
  v_journal := jsonb_build_array(jsonb_build_object(
    'quoi', format('DÉCAISSEMENT VALIDÉ — Tour %s — %s — %s %s (net) — %s [commission: %s %s] — %s',
                   v_dec.numer_tour, v_dec.beneficiaire_nom, v_dec.montant_net, v_dec.devise,
                   upper(v_dec.operateur), v_dec.commission, v_dec.devise, v_dec.numero_beneficiaire),
    'gestionnaire', v_dec.gestionnaire, 'quand', v_now, 'reference', v_ref
  )) || v_journal;
  v_tontine_data := jsonb_set(v_tontine_data, '{journal}', v_journal);

  UPDATE public.tontines SET data = v_tontine_data, modifie_le = NOW() WHERE UPPER(code) = UPPER(v_dec.code);
  UPDATE public.decaissements_pending SET statut = 'validee', validated_at = NOW(), valide_par = 'admin' WHERE id = p_id;

  RETURN jsonb_build_object('ok', true,
    'message', format('Décaissement validé — caisse débitée de %s %s (commission %s %s déduite)',
                      v_dec.montant_net, v_dec.devise, v_dec.commission, v_dec.devise),
    'montant_net', v_dec.montant_net, 'commission', v_dec.commission,
    'beneficiaire', v_dec.beneficiaire_nom, 'numer_tour', v_dec.numer_tour);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'erreur', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_valider_decaissement(TEXT, BIGINT) TO anon, authenticated;

-- ────────────────────────────────────────────────────────────
-- C3. admin_rejeter_decaissement
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_rejeter_decaissement(
  p_cle   TEXT,
  p_id    BIGINT,
  p_motif TEXT DEFAULT 'Rejeté par l''administrateur'
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_cle_attendue TEXT := current_setting('app.admin_key', true);
  v_dec          public.decaissements_pending%ROWTYPE;
BEGIN
  IF v_cle_attendue IS NULL OR v_cle_attendue = '' THEN
    IF p_cle NOT LIKE 'tc-admin%' THEN
      RETURN jsonb_build_object('ok', false, 'erreur', 'Clé admin invalide');
    END IF;
  ELSIF p_cle <> v_cle_attendue THEN
    IF NOT EXISTS (SELECT 1 FROM public.admin_config WHERE cle = p_cle AND actif = true LIMIT 1) THEN
      RETURN jsonb_build_object('ok', false, 'erreur', 'Clé admin invalide');
    END IF;
  END IF;

  SELECT * INTO v_dec FROM public.decaissements_pending WHERE id = p_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'erreur', 'Décaissement introuvable'); END IF;
  IF v_dec.statut <> 'pending' THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Décaissement déjà traité (statut: ' || v_dec.statut || ')');
  END IF;

  UPDATE public.decaissements_pending
    SET statut = 'rejetee', motif_rejet = p_motif, validated_at = NOW(), valide_par = 'admin'
    WHERE id = p_id;

  RETURN jsonb_build_object('ok', true, 'message', 'Décaissement rejeté. La caisse n''a pas été modifiée.',
    'beneficiaire', v_dec.beneficiaire_nom, 'numer_tour', v_dec.numer_tour);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'erreur', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_rejeter_decaissement(TEXT, BIGINT, TEXT) TO anon, authenticated;

-- ============================================================
-- SECTION D : Dépenses
-- Source : supabase-depenses-pending.sql
-- ============================================================

-- ────────────────────────────────────────────────────────────
-- D1. admin_valider_depense
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_valider_depense(
  p_cle TEXT,
  p_id  BIGINT
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_cle_attendue TEXT := current_setting('app.admin_key', true);
  v_depense       public.depenses_pending%ROWTYPE;
  v_tontine_data  JSONB;
  v_caisse        JSONB;
  v_mouvements    JSONB;
  v_ref           TEXT;
  v_now           TEXT;
  v_new_mouvement JSONB;
BEGIN
  IF v_cle_attendue IS NULL OR v_cle_attendue = '' THEN
    IF p_cle NOT LIKE 'tc-admin%' THEN
      RETURN jsonb_build_object('ok', false, 'erreur', 'Clé admin invalide');
    END IF;
  ELSIF p_cle <> v_cle_attendue THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Clé admin invalide');
  END IF;

  SELECT * INTO v_depense FROM public.depenses_pending WHERE id = p_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'erreur', 'Dépense introuvable'); END IF;
  IF v_depense.statut <> 'pending' THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Dépense déjà traitée (statut: ' || v_depense.statut || ')');
  END IF;

  SELECT data INTO v_tontine_data FROM public.tontines WHERE code = v_depense.code;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'erreur', 'Tontine introuvable: ' || v_depense.code); END IF;

  v_ref := 'DEP-' || EXTRACT(EPOCH FROM NOW())::BIGINT::TEXT;
  v_now := NOW()::TEXT;

  v_new_mouvement := jsonb_build_object(
    'id', v_ref, 'type', 'depense', 'montant', v_depense.montant,
    'description', COALESCE(NULLIF(v_depense.description, ''), 'Dépense Mobile Money — ' || v_depense.operateur),
    'gestionnaire', v_depense.gestionnaire, 'date', v_now, 'reference', v_ref,
    'methode', v_depense.operateur, 'numero_beneficiaire', v_depense.numero_beneficiaire,
    'nom_beneficiaire', v_depense.nom_beneficiaire, 'depense_id', p_id
  );

  v_caisse := COALESCE(v_tontine_data->'caisse', '{}'::jsonb);
  IF jsonb_typeof(v_caisse) = 'object' THEN
    v_mouvements := COALESCE(v_caisse->'mouvements', '[]'::jsonb);
    v_caisse := jsonb_set(v_caisse, '{mouvements}', v_mouvements || jsonb_build_array(v_new_mouvement));
  ELSIF jsonb_typeof(v_caisse) = 'array' THEN
    v_caisse := jsonb_build_object('mouvements', v_caisse || jsonb_build_array(v_new_mouvement));
  ELSE
    v_caisse := jsonb_build_object('mouvements', jsonb_build_array(v_new_mouvement));
  END IF;

  v_tontine_data := jsonb_set(v_tontine_data, '{caisse}', v_caisse);
  UPDATE public.tontines SET data = v_tontine_data, modifie_le = NOW() WHERE code = v_depense.code;
  UPDATE public.depenses_pending SET statut = 'validee', valide_le = NOW(), valide_par = 'admin' WHERE id = p_id;

  RETURN jsonb_build_object('ok', true,
    'message', 'Dépense validée — caisse débitée de ' || v_depense.montant::TEXT || ' ' || v_depense.devise);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'erreur', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_valider_depense TO anon, authenticated;

-- ────────────────────────────────────────────────────────────
-- D2. admin_rejeter_depense
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_rejeter_depense(
  p_cle   TEXT,
  p_id    BIGINT,
  p_motif TEXT
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_cle_attendue TEXT := current_setting('app.admin_key', true);
  v_depense      public.depenses_pending%ROWTYPE;
BEGIN
  IF v_cle_attendue IS NULL OR v_cle_attendue = '' THEN
    IF p_cle NOT LIKE 'tc-admin%' THEN
      RETURN jsonb_build_object('ok', false, 'erreur', 'Clé admin invalide');
    END IF;
  ELSIF p_cle <> v_cle_attendue THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Clé admin invalide');
  END IF;

  SELECT * INTO v_depense FROM public.depenses_pending WHERE id = p_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'erreur', 'Dépense introuvable'); END IF;
  IF v_depense.statut <> 'pending' THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Dépense déjà traitée');
  END IF;

  UPDATE public.depenses_pending
    SET statut = 'rejetee', motif_rejet = p_motif, valide_le = NOW(), valide_par = 'admin'
    WHERE id = p_id;

  RETURN jsonb_build_object('ok', true, 'message', 'Dépense rejetée.');
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'erreur', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_rejeter_depense TO anon, authenticated;

-- ============================================================
-- SECTION E : KYC
-- Source : supabase-kyc.sql
-- ============================================================

-- ────────────────────────────────────────────────────────────
-- E1. admin_lister_kyc
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_lister_kyc(
  p_cle    TEXT,
  p_statut TEXT DEFAULT 'tous'
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_attendue TEXT;
  v_liste    JSONB;
BEGIN
  SELECT value INTO v_attendue FROM public.app_config WHERE key = 'admin_key' LIMIT 1;
  IF v_attendue IS NULL OR p_cle <> v_attendue THEN
    RAISE EXCEPTION 'Clé admin invalide';
  END IF;

  IF p_statut = 'tous' THEN
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id', k.id, 'code', k.code, 'gestionnaire', k.gestionnaire, 'nom', k.nom,
      'piece_type', k.piece_type, 'piece_numero', k.piece_numero, 'soumis_le', k.soumis_le,
      'statut', k.statut, 'motif_rejet', k.motif_rejet, 'valide_par', k.valide_par,
      'validated_at', k.validated_at, 'created_at', k.created_at
    ) ORDER BY k.created_at DESC), '[]'::jsonb) INTO v_liste FROM public.kyc_submissions k;
  ELSE
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id', k.id, 'code', k.code, 'gestionnaire', k.gestionnaire, 'nom', k.nom,
      'piece_type', k.piece_type, 'piece_numero', k.piece_numero, 'soumis_le', k.soumis_le,
      'statut', k.statut, 'motif_rejet', k.motif_rejet, 'valide_par', k.valide_par,
      'validated_at', k.validated_at, 'created_at', k.created_at
    ) ORDER BY k.created_at DESC), '[]'::jsonb) INTO v_liste FROM public.kyc_submissions k WHERE k.statut = p_statut;
  END IF;

  RETURN v_liste;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_lister_kyc TO anon, authenticated;

-- ────────────────────────────────────────────────────────────
-- E2. admin_valider_kyc
--     Valide KYC : met à jour kyc_submissions + tontines.data.kyc
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_valider_kyc(
  p_cle TEXT,
  p_id  BIGINT
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_attendue   TEXT;
  v_submission RECORD;
  v_now        TIMESTAMPTZ := NOW();
BEGIN
  SELECT value INTO v_attendue FROM public.app_config WHERE key = 'admin_key' LIMIT 1;
  IF v_attendue IS NULL OR p_cle <> v_attendue THEN RAISE EXCEPTION 'Clé admin invalide'; END IF;

  SELECT * INTO v_submission FROM public.kyc_submissions WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'erreur', 'Dossier KYC introuvable.'); END IF;
  IF v_submission.statut <> 'pending' THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Ce dossier a déjà été traité (statut : ' || v_submission.statut || ').');
  END IF;

  UPDATE public.kyc_submissions SET statut = 'valide', validated_at = v_now, valide_par = 'admin' WHERE id = p_id;
  UPDATE public.tontines SET data = jsonb_set(COALESCE(data, '{}'::jsonb), '{kyc, statut}', '"valide"', true)
    WHERE code = v_submission.code;

  RETURN jsonb_build_object('ok', true, 'message', 'Dossier KYC validé avec succès.',
    'gestionnaire', v_submission.gestionnaire, 'code', v_submission.code);
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_valider_kyc TO anon, authenticated;

-- ────────────────────────────────────────────────────────────
-- E3. admin_rejeter_kyc
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_rejeter_kyc(
  p_cle   TEXT,
  p_id    BIGINT,
  p_motif TEXT DEFAULT 'Dossier non conforme.'
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_attendue   TEXT;
  v_submission RECORD;
  v_now        TIMESTAMPTZ := NOW();
BEGIN
  SELECT value INTO v_attendue FROM public.app_config WHERE key = 'admin_key' LIMIT 1;
  IF v_attendue IS NULL OR p_cle <> v_attendue THEN RAISE EXCEPTION 'Clé admin invalide'; END IF;

  SELECT * INTO v_submission FROM public.kyc_submissions WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'erreur', 'Dossier KYC introuvable.'); END IF;
  IF v_submission.statut <> 'pending' THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Ce dossier a déjà été traité (statut : ' || v_submission.statut || ').');
  END IF;

  UPDATE public.kyc_submissions SET statut = 'rejete', motif_rejet = p_motif, validated_at = v_now, valide_par = 'admin' WHERE id = p_id;
  UPDATE public.tontines
    SET data = jsonb_set(jsonb_set(COALESCE(data, '{}'::jsonb), '{kyc, statut}', '"rejete"', true),
                         '{kyc, motifRejet}', to_jsonb(p_motif), true)
    WHERE code = v_submission.code;

  RETURN jsonb_build_object('ok', true, 'message', 'Dossier KYC rejeté.',
    'gestionnaire', v_submission.gestionnaire, 'code', v_submission.code, 'motif', p_motif);
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_rejeter_kyc TO anon, authenticated;

GRANT SELECT, INSERT, UPDATE ON public.kyc_submissions TO anon, authenticated;

-- ============================================================
-- SECTION F : Admin Team + Messagerie + Support
-- Source : supabase-admin-team.sql
-- ============================================================

-- ────────────────────────────────────────────────────────────
-- F0. generer_ref_ticket (helper)
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION generer_ref_ticket()
RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE
  annee TEXT := TO_CHAR(NOW(), 'YYYY');
  seq   BIGINT;
BEGIN
  SELECT COALESCE(MAX(id), 0) + 1 INTO seq FROM support_tickets;
  RETURN 'TC-' || annee || '-' || LPAD(seq::TEXT, 4, '0');
END;
$$;

-- ────────────────────────────────────────────────────────────
-- F1. admin_lister_membres (super_admin only)
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION admin_lister_membres(p_cle TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_cle TEXT;
BEGIN
  SELECT valeur INTO v_cle FROM app_config WHERE cle = 'admin_key';
  IF v_cle IS NULL OR p_cle != v_cle THEN RAISE EXCEPTION 'Clé admin invalide'; END IF;
  RETURN (
    SELECT JSONB_AGG(JSONB_BUILD_OBJECT(
      'id', m.id, 'nom', m.nom, 'pseudo', m.pseudo, 'role', m.role,
      'actif', m.actif, 'cree_par', m.cree_par, 'cree_le', m.cree_le,
      'derniere_connexion', m.derniere_connexion
    ) ORDER BY m.cree_le ASC)
    FROM admin_membres m
  );
END;
$$;

-- ────────────────────────────────────────────────────────────
-- F2. admin_creer_membre
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION admin_creer_membre(
  p_cle TEXT, p_nom TEXT, p_pseudo TEXT, p_cle_perso TEXT, p_role TEXT, p_cree_par TEXT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_cle TEXT; v_hash TEXT; v_nouveau admin_membres;
BEGIN
  SELECT valeur INTO v_cle FROM app_config WHERE cle = 'admin_key';
  IF v_cle IS NULL OR p_cle != v_cle THEN RAISE EXCEPTION 'Clé admin invalide'; END IF;
  IF p_role NOT IN ('super_admin','comptable','conformite') THEN
    RAISE EXCEPTION 'Rôle invalide: %', p_role;
  END IF;
  v_hash := ENCODE(SHA256(p_cle_perso::BYTEA), 'hex');
  INSERT INTO admin_membres (nom, pseudo, cle_hash, role, actif, cree_par)
  VALUES (p_nom, p_pseudo, v_hash, p_role, TRUE, p_cree_par)
  RETURNING * INTO v_nouveau;
  RETURN JSONB_BUILD_OBJECT('id', v_nouveau.id, 'pseudo', v_nouveau.pseudo,
    'role', v_nouveau.role, 'actif', v_nouveau.actif);
END;
$$;

-- ────────────────────────────────────────────────────────────
-- F3. admin_modifier_membre
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION admin_modifier_membre(
  p_cle TEXT, p_id BIGINT, p_role TEXT DEFAULT NULL, p_actif BOOLEAN DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_cle TEXT;
BEGIN
  SELECT valeur INTO v_cle FROM app_config WHERE cle = 'admin_key';
  IF v_cle IS NULL OR p_cle != v_cle THEN RAISE EXCEPTION 'Clé admin invalide'; END IF;
  UPDATE admin_membres SET role = COALESCE(p_role, role), actif = COALESCE(p_actif, actif) WHERE id = p_id;
  RETURN JSONB_BUILD_OBJECT('ok', TRUE, 'id', p_id);
END;
$$;

-- ────────────────────────────────────────────────────────────
-- F4. admin_auth_membre
--     Authentifie un membre admin par pseudo + clé personnelle (hash SHA-256)
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION admin_auth_membre(p_pseudo TEXT, p_cle_perso TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_membre admin_membres%ROWTYPE;
  v_hash   TEXT;
BEGIN
  v_hash := ENCODE(SHA256(p_cle_perso::BYTEA), 'hex');
  SELECT * INTO v_membre FROM admin_membres WHERE pseudo = p_pseudo AND cle_hash = v_hash AND actif = TRUE;
  IF NOT FOUND THEN
    RETURN JSONB_BUILD_OBJECT('ok', FALSE, 'erreur', 'Identifiants incorrects');
  END IF;
  UPDATE admin_membres SET derniere_connexion = NOW() WHERE id = v_membre.id;
  RETURN JSONB_BUILD_OBJECT('ok', TRUE, 'id', v_membre.id, 'nom', v_membre.nom,
    'pseudo', v_membre.pseudo, 'role', v_membre.role);
END;
$$;

-- ────────────────────────────────────────────────────────────
-- F5. admin_lister_messages
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION admin_lister_messages(
  p_pseudo TEXT, p_cle_perso TEXT, p_boite TEXT DEFAULT 'recus'
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_hash TEXT; v_ok BOOLEAN;
BEGIN
  v_hash := ENCODE(SHA256(p_cle_perso::BYTEA), 'hex');
  SELECT EXISTS(SELECT 1 FROM admin_membres WHERE pseudo = p_pseudo AND cle_hash = v_hash AND actif) INTO v_ok;
  IF NOT v_ok THEN RAISE EXCEPTION 'Authentification requise'; END IF;
  RETURN (
    SELECT JSONB_AGG(JSONB_BUILD_OBJECT(
      'id', m.id, 'expediteur', m.expediteur, 'destinataire', m.destinataire,
      'sujet', m.sujet, 'corps', m.corps, 'lu', m.lu, 'lu_le', m.lu_le, 'envoye_le', m.envoye_le
    ) ORDER BY m.envoye_le DESC)
    FROM admin_messages m
    WHERE CASE p_boite
      WHEN 'recus'   THEN m.destinataire IN (p_pseudo, 'tous')
      WHEN 'envoyes' THEN m.expediteur = p_pseudo
      ELSE                m.destinataire IN (p_pseudo, 'tous') OR m.expediteur = p_pseudo
    END
  );
END;
$$;

-- ────────────────────────────────────────────────────────────
-- F6. admin_envoyer_message
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION admin_envoyer_message(
  p_pseudo TEXT, p_cle_perso TEXT, p_destinataire TEXT, p_sujet TEXT, p_corps TEXT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_hash TEXT; v_ok BOOLEAN; v_id BIGINT;
BEGIN
  v_hash := ENCODE(SHA256(p_cle_perso::BYTEA), 'hex');
  SELECT EXISTS(SELECT 1 FROM admin_membres WHERE pseudo = p_pseudo AND cle_hash = v_hash AND actif) INTO v_ok;
  IF NOT v_ok THEN RAISE EXCEPTION 'Authentification requise'; END IF;
  INSERT INTO admin_messages (expediteur, destinataire, sujet, corps)
  VALUES (p_pseudo, p_destinataire, p_sujet, p_corps) RETURNING id INTO v_id;
  RETURN JSONB_BUILD_OBJECT('ok', TRUE, 'id', v_id);
END;
$$;

-- ────────────────────────────────────────────────────────────
-- F7. admin_marquer_lu
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION admin_marquer_lu(
  p_pseudo TEXT, p_cle_perso TEXT, p_message_id BIGINT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_hash TEXT; v_ok BOOLEAN;
BEGIN
  v_hash := ENCODE(SHA256(p_cle_perso::BYTEA), 'hex');
  SELECT EXISTS(SELECT 1 FROM admin_membres WHERE pseudo = p_pseudo AND cle_hash = v_hash AND actif) INTO v_ok;
  IF NOT v_ok THEN RAISE EXCEPTION 'Authentification requise'; END IF;
  UPDATE admin_messages SET lu = TRUE, lu_le = NOW()
    WHERE id = p_message_id AND destinataire IN (p_pseudo, 'tous');
  RETURN JSONB_BUILD_OBJECT('ok', TRUE);
END;
$$;

-- ────────────────────────────────────────────────────────────
-- F8. admin_compter_non_lus
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION admin_compter_non_lus(p_pseudo TEXT, p_cle_perso TEXT)
RETURNS BIGINT LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_hash TEXT; v_ok BOOLEAN; v_count BIGINT;
BEGIN
  v_hash := ENCODE(SHA256(p_cle_perso::BYTEA), 'hex');
  SELECT EXISTS(SELECT 1 FROM admin_membres WHERE pseudo = p_pseudo AND cle_hash = v_hash AND actif) INTO v_ok;
  IF NOT v_ok THEN RETURN 0; END IF;
  SELECT COUNT(*) INTO v_count FROM admin_messages
    WHERE destinataire IN (p_pseudo, 'tous') AND lu = FALSE AND expediteur != p_pseudo;
  RETURN v_count;
END;
$$;

-- ────────────────────────────────────────────────────────────
-- F9. support_ouvrir_ticket (client)
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION support_ouvrir_ticket(
  p_gestionnaire TEXT, p_code_tontine TEXT, p_categorie TEXT,
  p_sujet TEXT, p_description TEXT, p_priorite TEXT DEFAULT 'normale'
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_ref TEXT; v_id BIGINT;
BEGIN
  v_ref := generer_ref_ticket();
  INSERT INTO support_tickets (ref, gestionnaire, code_tontine, categorie, sujet, description, priorite)
  VALUES (v_ref, p_gestionnaire, p_code_tontine, p_categorie, p_sujet, p_description, p_priorite)
  RETURNING id INTO v_id;
  INSERT INTO support_messages (ticket_id, auteur, est_admin, corps, lu_admin)
  VALUES (v_id, p_gestionnaire, FALSE, p_description, FALSE);
  RETURN JSONB_BUILD_OBJECT('ok', TRUE, 'id', v_id, 'ref', v_ref);
END;
$$;

-- ────────────────────────────────────────────────────────────
-- F10. support_mes_tickets (client — par gestionnaire)
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION support_mes_tickets(p_gestionnaire TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  RETURN (
    SELECT JSONB_AGG(JSONB_BUILD_OBJECT(
      'id', t.id, 'ref', t.ref, 'categorie', t.categorie, 'sujet', t.sujet,
      'statut', t.statut, 'priorite', t.priorite, 'assigne_a', t.assigne_a,
      'cree_le', t.cree_le, 'mis_a_jour', t.mis_a_jour,
      'nb_non_lus', (SELECT COUNT(*) FROM support_messages sm
                     WHERE sm.ticket_id = t.id AND sm.est_admin = TRUE AND sm.lu_client = FALSE)
    ) ORDER BY t.cree_le DESC)
    FROM support_tickets t WHERE t.gestionnaire = p_gestionnaire
  );
END;
$$;

-- ────────────────────────────────────────────────────────────
-- F11. admin_lister_tickets (admin)
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION admin_lister_tickets(
  p_cle TEXT, p_statut TEXT DEFAULT 'tous'
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_cle TEXT;
BEGIN
  SELECT valeur INTO v_cle FROM app_config WHERE cle = 'admin_key';
  IF v_cle IS NULL OR p_cle != v_cle THEN RAISE EXCEPTION 'Clé admin invalide'; END IF;
  RETURN (
    SELECT JSONB_AGG(JSONB_BUILD_OBJECT(
      'id', t.id, 'ref', t.ref, 'gestionnaire', t.gestionnaire, 'code_tontine', t.code_tontine,
      'categorie', t.categorie, 'sujet', t.sujet, 'statut', t.statut, 'priorite', t.priorite,
      'assigne_a', t.assigne_a, 'cree_le', t.cree_le, 'mis_a_jour', t.mis_a_jour,
      'nb_non_lus', (SELECT COUNT(*) FROM support_messages sm
                     WHERE sm.ticket_id = t.id AND sm.est_admin = FALSE AND sm.lu_admin = FALSE)
    ) ORDER BY CASE t.priorite WHEN 'urgente' THEN 1 WHEN 'haute' THEN 2 WHEN 'normale' THEN 3 ELSE 4 END,
               t.mis_a_jour DESC)
    FROM support_tickets t WHERE p_statut = 'tous' OR t.statut = p_statut
  );
END;
$$;

-- ────────────────────────────────────────────────────────────
-- F12. support_messages_ticket (client ou admin — marque lu)
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION support_messages_ticket(
  p_ticket_id BIGINT, p_est_admin BOOLEAN DEFAULT FALSE, p_cle_ou_gest TEXT DEFAULT ''
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_cle TEXT; v_ok BOOLEAN := FALSE;
BEGIN
  IF p_est_admin THEN
    SELECT valeur INTO v_cle FROM app_config WHERE cle = 'admin_key';
    v_ok := (v_cle IS NOT NULL AND p_cle_ou_gest = v_cle);
    IF v_ok THEN
      UPDATE support_messages SET lu_admin = TRUE
        WHERE ticket_id = p_ticket_id AND est_admin = FALSE AND lu_admin = FALSE;
    END IF;
  ELSE
    SELECT EXISTS(SELECT 1 FROM support_tickets WHERE id = p_ticket_id AND gestionnaire = p_cle_ou_gest) INTO v_ok;
    IF v_ok THEN
      UPDATE support_messages SET lu_client = TRUE
        WHERE ticket_id = p_ticket_id AND est_admin = TRUE AND lu_client = FALSE;
    END IF;
  END IF;
  IF NOT v_ok THEN RAISE EXCEPTION 'Accès refusé'; END IF;
  RETURN (
    SELECT JSONB_AGG(JSONB_BUILD_OBJECT(
      'id', sm.id, 'auteur', sm.auteur, 'est_admin', sm.est_admin,
      'corps', sm.corps, 'envoye_le', sm.envoye_le
    ) ORDER BY sm.envoye_le ASC)
    FROM support_messages sm WHERE sm.ticket_id = p_ticket_id
  );
END;
$$;

-- ────────────────────────────────────────────────────────────
-- F13. support_repondre (client ou admin)
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION support_repondre(
  p_ticket_id BIGINT, p_auteur TEXT, p_corps TEXT,
  p_est_admin BOOLEAN DEFAULT FALSE, p_cle_ou_gest TEXT DEFAULT ''
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_cle TEXT; v_ok BOOLEAN := FALSE; v_id BIGINT;
BEGIN
  IF p_est_admin THEN
    SELECT valeur INTO v_cle FROM app_config WHERE cle = 'admin_key';
    v_ok := (v_cle IS NOT NULL AND p_cle_ou_gest = v_cle);
  ELSE
    SELECT EXISTS(SELECT 1 FROM support_tickets WHERE id = p_ticket_id AND gestionnaire = p_cle_ou_gest) INTO v_ok;
  END IF;
  IF NOT v_ok THEN RAISE EXCEPTION 'Accès refusé'; END IF;
  INSERT INTO support_messages (ticket_id, auteur, est_admin, corps)
  VALUES (p_ticket_id, p_auteur, p_est_admin, p_corps) RETURNING id INTO v_id;
  UPDATE support_tickets SET mis_a_jour = NOW(),
    statut = CASE WHEN p_est_admin AND statut = 'ouvert' THEN 'en_cours' ELSE statut END
    WHERE id = p_ticket_id;
  RETURN JSONB_BUILD_OBJECT('ok', TRUE, 'id', v_id);
END;
$$;

-- ────────────────────────────────────────────────────────────
-- F14. admin_changer_statut_ticket
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION admin_changer_statut_ticket(
  p_cle TEXT, p_ticket_id BIGINT, p_statut TEXT, p_assigne_a TEXT DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_cle TEXT;
BEGIN
  SELECT valeur INTO v_cle FROM app_config WHERE cle = 'admin_key';
  IF v_cle IS NULL OR p_cle != v_cle THEN RAISE EXCEPTION 'Clé admin invalide'; END IF;
  UPDATE support_tickets SET statut = p_statut, assigne_a = COALESCE(p_assigne_a, assigne_a),
    mis_a_jour = NOW(),
    resolu_le = CASE WHEN p_statut IN ('resolu','ferme') THEN NOW() ELSE resolu_le END
    WHERE id = p_ticket_id;
  RETURN JSONB_BUILD_OBJECT('ok', TRUE);
END;
$$;

-- ────────────────────────────────────────────────────────────
-- Vérification post-déploiement
-- ────────────────────────────────────────────────────────────
DO $verify009$
DECLARE
  v_fns text[] := ARRAY[
    'est_premium','lire_abonnement_tontine','verif_limite_membres',
    'enregistrer_abonnement_web','expirer_abonnements_obsoletes',
    'admin_valider_pret','admin_rejeter_pret','crediter_remboursement_sycapay',
    'admin_lister_decaissements','admin_valider_decaissement','admin_rejeter_decaissement',
    'admin_valider_depense','admin_rejeter_depense',
    'admin_lister_kyc','admin_valider_kyc','admin_rejeter_kyc',
    'admin_lister_membres','admin_creer_membre','admin_modifier_membre','admin_auth_membre',
    'admin_lister_messages','admin_envoyer_message','admin_marquer_lu','admin_compter_non_lus',
    'generer_ref_ticket','support_ouvrir_ticket','support_mes_tickets',
    'admin_lister_tickets','support_messages_ticket','support_repondre',
    'admin_changer_statut_ticket'
  ];
  v_fn text;
  v_ok boolean;
BEGIN
  FOREACH v_fn IN ARRAY v_fns LOOP
    SELECT EXISTS(SELECT 1 FROM pg_proc WHERE proname = v_fn) INTO v_ok;
    RAISE NOTICE '009 % : %', v_fn, CASE WHEN v_ok THEN 'OK' ELSE 'MANQUANT' END;
  END LOOP;
END;
$verify009$;
-- ============================================================
-- FIN 009_rpcs_financier_support.sql
-- ============================================================
-- =============================================================================
-- TontineClair — Migration 010 : Notifications FCM + Transactions SycaPay
-- =============================================================================
-- Sources canoniques :
--   • supabase/migrations/001_fcm_tokens.sql     → sauvegarder_token
--   • supabase-sycapay-transactions.sql          → creer_transaction_sycapay,
--                                                   get_pending_sycapay_transactions
--   • supabase-sycapay-v2.sql                    → crediter_caisse_sycapay,
--                                                   crediter_cotisation_sycapay
--                                                   (v2 FINAL — ajoute sycapay_reference,
--                                                    user_id, membre_nom, pret_id,
--                                                    emprunteur_id)
--   • supabase-penalite-sycapay.sql              → crediter_penalite_sycapay
--   • supabase-fix-v8-periodicitee.sql           → recalculer_echeances_expir
--   • supabase-fix-v11-beneficiaire.sql          → distribuer_tour
-- =============================================================================
-- Contient :
--   RPC 1  : sauvegarder_token
--   RPC 2  : creer_transaction_sycapay
--   RPC 3  : get_pending_sycapay_transactions
--   RPC 4  : crediter_caisse_sycapay
--   RPC 5  : crediter_cotisation_sycapay
--   RPC 6  : crediter_penalite_sycapay
--   RPC 7  : recalculer_echeances_expir
--   RPC 8  : distribuer_tour
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- Dépendances : Tables créées dans les migrations précédentes
--   • fcm_tokens            (004_tables_kyc_notifs.sql)
--   • sycapay_transactions  (003_tables_financier.sql)
--   • tontines              (001_tables_core.sql)
-- ─────────────────────────────────────────────────────────────────────────────

-- =============================================================================
-- 1. COLONNES ADDITIONNELLES sycapay_transactions (v2)
-- =============================================================================
-- Colonnes ajoutées par supabase-sycapay-v2.sql et supabase-penalite-sycapay.sql
-- Idempotentes — n'échouent pas si déjà présentes.
ALTER TABLE public.sycapay_transactions
  ADD COLUMN IF NOT EXISTS sycapay_reference text,
  ADD COLUMN IF NOT EXISTS user_id           text,
  ADD COLUMN IF NOT EXISTS membre_nom        text,
  ADD COLUMN IF NOT EXISTS pret_id           text,
  ADD COLUMN IF NOT EXISTS emprunteur_id     text;

-- Index supplémentaire membre_id (v2)
CREATE INDEX IF NOT EXISTS idx_sycapay_txn_membre
  ON public.sycapay_transactions(membre_id)
  WHERE membre_id IS NOT NULL;

-- =============================================================================
-- 2. RPC : sauvegarder_token
-- =============================================================================
-- Enregistre ou met à jour le token FCM d'un appareil pour une tontine.
-- Appelée par l'app Flutter au démarrage (UPSERT idempotent).
-- Source : supabase/migrations/001_fcm_tokens.sql
-- =============================================================================
CREATE OR REPLACE FUNCTION public.sauvegarder_token(
  p_code     text,
  p_token    text,
  p_appareil text DEFAULT 'android'
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.fcm_tokens(tontine_code, token, appareil, mis_a_jour_le)
  VALUES (upper(p_code), p_token, p_appareil, now())
  ON CONFLICT (tontine_code, token)
  DO UPDATE SET
    appareil      = EXCLUDED.appareil,
    mis_a_jour_le = now();
  RETURN true;
EXCEPTION WHEN OTHERS THEN
  RETURN false;
END;
$$;

GRANT EXECUTE ON FUNCTION public.sauvegarder_token TO anon, authenticated;

-- =============================================================================
-- 3. RPC : creer_transaction_sycapay
-- =============================================================================
-- Crée une transaction SycaPay de manière idempotente.
-- Refuse si la référence est déjà 'credited' (anti-doublon paiement).
-- Source : supabase-sycapay-transactions.sql
-- =============================================================================
CREATE OR REPLACE FUNCTION public.creer_transaction_sycapay(
  p_tontine_code       text,
  p_type_operation     text,
  p_internal_reference text,
  p_amount             integer,
  p_currency           text,
  p_operator           text,
  p_phone_masked       text,
  p_membre_id          text DEFAULT NULL,
  p_description        text DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id              bigint;
  v_existing_id     bigint;
  v_existing_status text;
BEGIN
  -- Vérifier si la référence existe déjà (idempotence)
  SELECT id, status
  INTO v_existing_id, v_existing_status
  FROM public.sycapay_transactions
  WHERE internal_reference = p_internal_reference;

  IF FOUND THEN
    -- Si déjà créditée → erreur double paiement
    IF v_existing_status = 'credited' THEN
      RAISE EXCEPTION 'DEJA_CREDITE: transaction % déjà créditée', p_internal_reference;
    END IF;
    -- Sinon retourner l'id existant (idempotent)
    RETURN v_existing_id;
  END IF;

  -- Créer la transaction
  INSERT INTO public.sycapay_transactions (
    tontine_code, type_operation, internal_reference,
    amount, currency, operator, phone_number_masked,
    membre_id, description, status
  ) VALUES (
    p_tontine_code, p_type_operation, p_internal_reference,
    p_amount, p_currency, p_operator, p_phone_masked,
    p_membre_id, p_description, 'pending'
  ) RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.creer_transaction_sycapay TO anon, authenticated;

-- =============================================================================
-- 4. RPC : get_pending_sycapay_transactions
-- =============================================================================
-- Retourne les transactions SycaPay en attente d'une tontine.
-- Filtre les transactions de plus de 24h (expirées de facto).
-- Source : supabase-sycapay-transactions.sql
-- =============================================================================
CREATE OR REPLACE FUNCTION public.get_pending_sycapay_transactions(
  p_tontine_code text
)
RETURNS TABLE(
  id                      bigint,
  internal_reference      text,
  provider_transaction_id text,
  amount                  integer,
  operator                text,
  type_operation          text,
  membre_id               text,
  description             text,
  created_at              timestamptz,
  polling_attempts        integer
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    id,
    internal_reference,
    provider_transaction_id,
    amount,
    operator,
    type_operation,
    membre_id,
    description,
    created_at,
    polling_attempts
  FROM public.sycapay_transactions
  WHERE tontine_code = p_tontine_code
    AND status = 'pending'
    -- Ne pas récupérer les très anciennes (> 24h)
    AND created_at > now() - interval '24 hours'
  ORDER BY created_at DESC;
$$;

GRANT EXECUTE ON FUNCTION public.get_pending_sycapay_transactions TO anon, authenticated;

-- =============================================================================
-- 5. RPC : crediter_caisse_sycapay
-- =============================================================================
-- Crédite la caisse d'une tontine avec un apport SycaPay.
-- Appelée par l'Edge Function (SECURITY DEFINER → bypass RLS).
-- Idempotente : vérifie la présence de la référence dans caisse.mouvements.
-- Source : supabase-sycapay-v2.sql (FINAL)
-- =============================================================================
CREATE OR REPLACE FUNCTION public.crediter_caisse_sycapay(
  p_code         text,
  p_montant      integer,
  p_reference    text,
  p_num_commande text,
  p_operateur    text,
  p_description  text,
  p_now          text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row        record;
  v_data       jsonb;
  v_caisse     jsonb;
  v_mouvements jsonb;
  v_journal    jsonb;
  v_now        text;
  v_mouvement  jsonb;
  v_entry      jsonb;
BEGIN
  v_now := COALESCE(p_now, now()::text);

  -- Lire la tontine
  SELECT * INTO v_row
  FROM public.tontines
  WHERE code = UPPER(p_code);

  IF NOT FOUND THEN
    RAISE EXCEPTION 'TONTINE_INTROUVABLE: %', p_code;
  END IF;

  v_data := v_row.data;

  -- Lire ou initialiser la caisse
  v_caisse     := COALESCE(v_data->'caisse', '{}'::jsonb);
  v_mouvements := COALESCE(v_caisse->'mouvements', '[]'::jsonb);
  v_journal    := COALESCE(v_data->'journal', '[]'::jsonb);

  -- Idempotence : même référence déjà présente dans mouvements ?
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_mouvements) AS m
    WHERE m->>'id' = p_reference OR m->>'numCommande' = p_num_commande
  ) THEN
    RETURN jsonb_build_object('ok', true, 'message', 'déjà crédité (idempotent)');
  END IF;

  -- Construire le mouvement
  v_mouvement := jsonb_build_object(
    'id',          p_reference,
    'type',        'apport',
    'montant',     p_montant,
    'description', p_description,
    'gestionnaire','SycaPay',
    'date',        v_now,
    'reference',   p_reference,
    'methode',     'sycapay',
    'operateur',   p_operateur,
    'numCommande', p_num_commande
  );

  -- Construire l'entrée journal
  v_entry := jsonb_build_object(
    'quoi', 'APPORT CAISSE via SycaPay (' || UPPER(p_operateur) || ') — ' || p_montant::text || ' XOF' ||
            CASE WHEN p_description <> '' THEN ' — ' || p_description ELSE '' END,
    'par',  'SycaPay',
    'le',   (EXTRACT(EPOCH FROM now()) * 1000)::bigint,
    'ref',  p_reference
  );

  -- Injecter dans le JSON
  v_mouvements := v_mouvements || jsonb_build_array(v_mouvement);
  v_caisse     := v_caisse || jsonb_build_object('mouvements', v_mouvements);
  v_journal    := jsonb_build_array(v_entry) || v_journal;  -- journal en tête
  v_data       := v_data
                  || jsonb_build_object('caisse',  v_caisse)
                  || jsonb_build_object('journal', v_journal);

  -- Écrire la tontine
  UPDATE public.tontines
  SET data = v_data, modifie_le = now()
  WHERE code = UPPER(p_code);

  RETURN jsonb_build_object('ok', true, 'message', 'caisse créditée');
EXCEPTION WHEN OTHERS THEN
  RAISE EXCEPTION 'crediter_caisse_sycapay: % %', SQLSTATE, SQLERRM;
END;
$$;

GRANT EXECUTE ON FUNCTION public.crediter_caisse_sycapay TO anon, authenticated;

-- =============================================================================
-- 6. RPC : crediter_cotisation_sycapay
-- =============================================================================
-- Marque la cotisation d'un membre comme payée via SycaPay.
-- Idempotente : vérifie la référence dans journal[].ref.
-- Source : supabase-sycapay-v2.sql (FINAL)
-- =============================================================================
CREATE OR REPLACE FUNCTION public.crediter_cotisation_sycapay(
  p_code         text,
  p_membre_id    text,
  p_montant      integer,
  p_reference    text,
  p_num_commande text,
  p_operateur    text,
  p_now          text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row         record;
  v_data        jsonb;
  v_membres     jsonb;
  v_membre      jsonb;
  v_i           int;
  v_journal     jsonb;
  v_now         text;
  v_cotisations jsonb;
  v_cotis       jsonb;
  v_found       boolean := false;
  v_entry       jsonb;
BEGIN
  v_now := COALESCE(p_now, now()::text);

  SELECT * INTO v_row
  FROM public.tontines
  WHERE code = UPPER(p_code);

  IF NOT FOUND THEN
    RAISE EXCEPTION 'TONTINE_INTROUVABLE: %', p_code;
  END IF;

  v_data    := v_row.data;
  v_membres := COALESCE(v_data->'membres', '[]'::jsonb);
  v_journal := COALESCE(v_data->'journal', '[]'::jsonb);

  -- Idempotence sur le journal
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_journal) AS j
    WHERE j->>'ref' = p_reference OR j->>'numCommande' = p_num_commande
  ) THEN
    RETURN jsonb_build_object('ok', true, 'message', 'déjà crédité (idempotent)');
  END IF;

  -- Trouver le membre et mettre à jour ses cotisations
  FOR v_i IN 0 .. jsonb_array_length(v_membres) - 1 LOOP
    v_membre := v_membres -> v_i;
    IF v_membre->>'id' = p_membre_id THEN
      -- Ajouter la cotisation dans cotisations[]
      v_cotisations := COALESCE(v_membre->'cotisations', '[]'::jsonb);
      v_cotis := jsonb_build_object(
        'id',          p_reference,
        'montant',     p_montant,
        'date',        v_now,
        'methode',     'sycapay',
        'operateur',   p_operateur,
        'reference',   p_reference,
        'numCommande', p_num_commande
      );
      v_cotisations := v_cotisations || jsonb_build_array(v_cotis);
      v_membre      := v_membre || jsonb_build_object('cotisations', v_cotisations);
      v_membres     := jsonb_set(v_membres, ARRAY[v_i::text], v_membre);
      v_found       := true;
      EXIT;
    END IF;
  END LOOP;

  IF NOT v_found THEN
    RAISE EXCEPTION 'MEMBRE_INTROUVABLE: % dans tontine %', p_membre_id, p_code;
  END IF;

  -- Journal
  v_entry := jsonb_build_object(
    'quoi',     'COTISATION via SycaPay (' || UPPER(p_operateur) || ') — ' || p_montant::text || ' XOF',
    'par',      'SycaPay',
    'le',       (EXTRACT(EPOCH FROM now()) * 1000)::bigint,
    'ref',      p_reference,
    'membreId', p_membre_id
  );
  v_journal := jsonb_build_array(v_entry) || v_journal;
  v_data    := v_data
               || jsonb_build_object('membres', v_membres)
               || jsonb_build_object('journal', v_journal);

  UPDATE public.tontines
  SET data = v_data, modifie_le = now()
  WHERE code = UPPER(p_code);

  RETURN jsonb_build_object('ok', true, 'message', 'cotisation créditée');
EXCEPTION WHEN OTHERS THEN
  RAISE EXCEPTION 'crediter_cotisation_sycapay: % %', SQLSTATE, SQLERRM;
END;
$$;

GRANT EXECUTE ON FUNCTION public.crediter_cotisation_sycapay TO anon, authenticated;

-- =============================================================================
-- 7. RPC : crediter_penalite_sycapay
-- =============================================================================
-- Enregistre une pénalité SycaPay :
--   • Injecte un mouvement 'penalite' dans caisse.mouvements
--   • Incrémente membres[idx].penalites
--   • Décrémente membres[idx].score de 5 points (plancher 0)
--   • Écrit dans le journal
-- Source : supabase-penalite-sycapay.sql
-- =============================================================================
CREATE OR REPLACE FUNCTION public.crediter_penalite_sycapay(
  p_code         text,
  p_montant      integer,
  p_reference    text,
  p_num_commande text,
  p_operateur    text,
  p_membre_id    text,
  p_membre_nom   text,
  p_description  text,
  p_now          text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row        record;
  v_data       jsonb;
  v_caisse     jsonb;
  v_mouvements jsonb;
  v_journal    jsonb;
  v_membres    jsonb;
  v_now        text;
  v_mouvement  jsonb;
  v_entry      jsonb;
  v_idx        integer;
  v_membre     jsonb;
  v_pen_count  integer;
  v_score      integer;
BEGIN
  v_now := COALESCE(p_now, now()::text);

  -- Lire la tontine
  SELECT * INTO v_row
  FROM public.tontines
  WHERE code = UPPER(p_code);

  IF NOT FOUND THEN
    RAISE EXCEPTION 'TONTINE_INTROUVABLE: %', p_code;
  END IF;

  v_data := v_row.data;

  -- Lire caisse, journal, membres
  v_caisse     := COALESCE(v_data->'caisse', '{}'::jsonb);
  v_mouvements := COALESCE(v_caisse->'mouvements', '[]'::jsonb);
  v_journal    := COALESCE(v_data->'journal', '[]'::jsonb);
  v_membres    := COALESCE(v_data->'membres', '[]'::jsonb);

  -- Idempotence : même référence déjà présente ?
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_mouvements) AS m
    WHERE m->>'id' = p_reference OR m->>'numCommande' = p_num_commande
  ) THEN
    RETURN jsonb_build_object('ok', true, 'message', 'déjà crédité (idempotent)');
  END IF;

  -- Construire le mouvement pénalité
  v_mouvement := jsonb_build_object(
    'id',          p_reference,
    'type',        'penalite',
    'montant',     p_montant,
    'description', CASE
                     WHEN p_description <> '' THEN p_description
                     ELSE 'Pénalité — ' || COALESCE(NULLIF(p_membre_nom, ''), p_membre_id)
                   END,
    'gestionnaire','SycaPay',
    'date',        v_now,
    'reference',   p_reference,
    'methode',     'sycapay',
    'operateur',   p_operateur,
    'numCommande', p_num_commande,
    'membreId',    p_membre_id,
    'membreNom',   p_membre_nom
  );

  -- Construire l'entrée journal
  v_entry := jsonb_build_object(
    'quoi', 'PÉNALITÉ SycaPay — ' || COALESCE(NULLIF(p_membre_nom, ''), p_membre_id)
            || ' — ' || p_montant::text || ' XOF'
            || CASE WHEN p_description <> '' THEN ' — ' || p_description ELSE '' END,
    'par',  'SycaPay',
    'le',   (EXTRACT(EPOCH FROM now()) * 1000)::bigint,
    'ref',  p_reference
  );

  -- Injecter mouvement dans caisse
  v_mouvements := v_mouvements || jsonb_build_array(v_mouvement);
  v_caisse     := v_caisse || jsonb_build_object('mouvements', v_mouvements);
  v_journal    := jsonb_build_array(v_entry) || v_journal;

  -- Mettre à jour le membre pénalisé (penalites++, score−5, plancher 0)
  IF p_membre_id IS NOT NULL AND p_membre_id <> '' THEN
    FOR v_idx IN 0 .. (jsonb_array_length(v_membres) - 1) LOOP
      IF v_membres->v_idx->>'id' = p_membre_id THEN
        v_membre    := v_membres->v_idx;
        v_pen_count := COALESCE((v_membre->>'penalites')::integer, 0) + 1;
        v_score     := GREATEST(0, COALESCE((v_membre->>'score')::integer, 50) - 5);
        v_membre    := v_membre
                       || jsonb_build_object('penalites', v_pen_count)
                       || jsonb_build_object('score', v_score);
        v_membres   := jsonb_set(v_membres, ARRAY[v_idx::text], v_membre);
        EXIT;
      END IF;
    END LOOP;
  END IF;

  -- Assembler et écrire la tontine
  v_data := v_data
            || jsonb_build_object('caisse',  v_caisse)
            || jsonb_build_object('journal', v_journal)
            || jsonb_build_object('membres', v_membres);

  UPDATE public.tontines
  SET data = v_data, modifie_le = now()
  WHERE code = UPPER(p_code);

  RETURN jsonb_build_object('ok', true, 'message', 'pénalité enregistrée');
EXCEPTION WHEN OTHERS THEN
  RAISE EXCEPTION 'crediter_penalite_sycapay: % %', SQLSTATE, SQLERRM;
END;
$$;

GRANT EXECUTE ON FUNCTION public.crediter_penalite_sycapay TO anon, authenticated;

-- =============================================================================
-- 8. RPC : recalculer_echeances_expir
-- =============================================================================
-- Recalcule et avance les échéances expirées selon la périodicité de chaque
-- tontine. Boucle jusqu'à obtenir une date future.
-- Source : supabase-fix-v8-periodicitee.sql
-- =============================================================================
CREATE OR REPLACE FUNCTION public.recalculer_echeances_expir()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_rec               record;
  v_data              jsonb;
  v_periode           text;
  v_echeance          text;
  v_nouvelle_echeance timestamptz;
  v_fixed             int := 0;
BEGIN
  FOR v_rec IN
    SELECT code, data
    FROM public.tontines
    WHERE
      -- Tontines avec une échéance définie et passée
      data->>'echeance' IS NOT NULL
      AND (data->>'echeance')::timestamptz < now()
      -- Pas terminées
      AND (data->>'cycleTermine' IS NULL OR data->>'cycleTermine' = 'false')
  LOOP
    v_data    := v_rec.data;
    v_periode := COALESCE(v_data->>'periodicite', v_data->>'periode', 'mensuel');
    v_echeance := v_data->>'echeance';

    -- Calculer la prochaine échéance depuis la date passée
    v_nouvelle_echeance := (v_echeance::timestamptz);
    LOOP
      EXIT WHEN v_nouvelle_echeance > now();
      CASE v_periode
        WHEN 'journalier'  THEN v_nouvelle_echeance := v_nouvelle_echeance + interval '1 day';
        WHEN 'hebdo'       THEN v_nouvelle_echeance := v_nouvelle_echeance + interval '7 days';
        WHEN 'mensuel'     THEN v_nouvelle_echeance := v_nouvelle_echeance + interval '1 month';
        WHEN 'bimensuel'   THEN v_nouvelle_echeance := v_nouvelle_echeance + interval '2 months';
        WHEN 'trimestriel' THEN v_nouvelle_echeance := v_nouvelle_echeance + interval '3 months';
        ELSE                    v_nouvelle_echeance := v_nouvelle_echeance + interval '1 month';
      END CASE;
    END LOOP;

    -- Mettre à jour la tontine
    UPDATE public.tontines
    SET data = data || jsonb_build_object(
      'echeance',
      to_char(v_nouvelle_echeance, 'YYYY-MM-DD"T"HH24:MI:SS".000Z"')
    )
    WHERE code = v_rec.code;

    v_fixed := v_fixed + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'mises_a_jour', v_fixed,
    'message',      v_fixed || ' échéance(s) recalculée(s).'
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.recalculer_echeances_expir TO anon, authenticated;

-- =============================================================================
-- 9. RPC : distribuer_tour
-- =============================================================================
-- Enregistre la distribution d'un tour manuellement (confirmation gestionnaire).
-- Fonctionnement :
--   • Anti-doublon : refuse si le bénéficiaire a déjà été servi dans ce cycle
--   • Calcule automatiquement montantRecu si non fourni (nb_payes × montant)
--   • Écrit dans historique[], caisse.mouvements[], journal[]
--   • Réinitialise paiements{} et membres[].paye = false pour le prochain tour
--   • Avance tourActuel et marque cycleTermine si dernier tour
-- Source : supabase-fix-v11-beneficiaire.sql (FINAL v11)
-- =============================================================================
CREATE OR REPLACE FUNCTION public.distribuer_tour(
  p_code         text,
  p_pin          text,
  p_gest         text,
  p_benef_id     text DEFAULT NULL,  -- si NULL : utilise ordre[tourActuel]
  p_montant_recu int  DEFAULT NULL   -- si NULL : calcule automatiquement
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row          tontines%ROWTYPE;
  v_data         jsonb;
  v_ordre        jsonb;
  v_tour_actuel  int;
  v_nb_tours     int;
  v_benef_id     text;
  v_benef_nom    text;
  v_montant      int;
  v_total_recu   int;
  v_nb_payes     int;
  v_paiements    jsonb;
  v_historique   jsonb;
  v_payes_ids    jsonb;
  v_est_dernier  boolean;
  v_new_tour     int;
  v_ref          text;
  v_now          text;
  v_doublons     boolean;
  v_caisse_mv    jsonb;
BEGIN
  -- Lire et vérifier la tontine
  SELECT * INTO v_row FROM public.tontines WHERE code = p_code;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Tontine introuvable');
  END IF;

  -- Vérification PIN
  IF v_row.pin_hash IS NOT NULL AND v_row.pin_hash <> crypt(p_pin, v_row.pin_hash) THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'PIN incorrect');
  END IF;

  v_data        := v_row.data;
  v_ordre       := COALESCE(v_data->'ordre', '[]'::jsonb);
  v_tour_actuel := COALESCE((v_data->>'tourActuel')::int, 0);
  v_nb_tours    := jsonb_array_length(v_ordre);
  v_montant     := COALESCE((v_data->>'montant')::int, 0);
  v_paiements   := COALESCE(v_data->'paiements', '{}'::jsonb);
  v_historique  := COALESCE(v_data->'historique', '[]'::jsonb);
  v_now         := now()::text;
  v_ref         := upper(substring(md5(random()::text) FROM 1 FOR 8));

  -- Vérifications préalables
  IF (v_data->>'cycleTermine')::boolean = true THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Le cycle est déjà terminé');
  END IF;
  IF v_nb_tours = 0 THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Aucun ordre défini');
  END IF;
  IF v_tour_actuel >= v_nb_tours THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Tous les tours ont été effectués');
  END IF;

  -- Identifier le bénéficiaire (explicite ou auto depuis ordre[])
  v_benef_id  := COALESCE(p_benef_id, v_ordre->>v_tour_actuel);
  v_benef_nom := _tc_nom_membre(v_data, v_benef_id);

  -- Anti-doublon : ce membre a-t-il déjà été servi ?
  SELECT EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_historique) h
    WHERE (h->>'beneficiaireId') = v_benef_id
  ) INTO v_doublons;

  IF v_doublons THEN
    RETURN jsonb_build_object(
      'ok',    false,
      'erreur', format('%s a déjà été servi dans ce cycle', v_benef_nom)
    );
  END IF;

  -- Calculs du tour
  SELECT COUNT(*) INTO v_nb_payes FROM jsonb_object_keys(v_paiements);
  v_total_recu  := COALESCE(p_montant_recu, v_nb_payes * v_montant);
  v_payes_ids   := (SELECT jsonb_agg(k) FROM jsonb_object_keys(v_paiements) k);
  v_est_dernier := (v_tour_actuel + 1) >= v_nb_tours;
  v_new_tour    := CASE WHEN v_est_dernier THEN v_tour_actuel ELSE v_tour_actuel + 1 END;

  -- Entrée historique
  v_historique := jsonb_build_array(
    jsonb_build_object(
      'tour',            v_tour_actuel + 1,
      'beneficiaireId',  v_benef_id,
      'beneficiaire',    v_benef_nom,
      'beneficiaireNom', v_benef_nom,
      'montantRecu',     v_total_recu,
      'totalRecu',       v_total_recu,
      'totalAttendu',    v_nb_tours * v_montant,
      'nbPayes',         v_nb_payes,
      'payesIds',        COALESCE(v_payes_ids, '[]'::jsonb),
      'statut',          'Distribué',
      'date',            v_now,
      'closLe',          v_now,
      'reference',       v_ref
    )
  ) || v_historique;

  -- Mise à jour data principale
  v_data := v_data || jsonb_build_object(
    'tourActuel',   v_new_tour,
    'cycleTermine', v_est_dernier,
    'paiements',    '{}'::jsonb,
    'historique',   v_historique
  );

  -- Reset paye de tous les membres pour le prochain tour
  v_data := jsonb_set(v_data, '{membres}', (
    SELECT jsonb_agg(m || '{"paye":false,"datePaiement":null,"methodePaiement":null}')
    FROM jsonb_array_elements(COALESCE(v_data->'membres', '[]'::jsonb)) m
  ));

  -- Mouvement caisse : distribution
  v_caisse_mv := jsonb_build_object(
    'id',          v_ref || 'D',
    'type',        'distribution',
    'montant',     -v_total_recu,
    'description', format('Distribution Tour %s → %s', v_tour_actuel + 1, v_benef_nom),
    'gestionnaire', COALESCE(p_gest, 'gestionnaire'),
    'date',        v_now,
    'reference',   v_ref
  );
  v_data := jsonb_set(
    v_data,
    '{caisse,mouvements}',
    jsonb_build_array(v_caisse_mv) || COALESCE(v_data->'caisse'->'mouvements', '[]'::jsonb)
  );

  -- Journal
  v_data := jsonb_set(v_data, '{journal}',
    jsonb_build_array(jsonb_build_object(
      'quoi',        format('DISTRIBUTION_TOUR_%s|%s|%s FCFA', v_tour_actuel + 1, v_benef_nom, v_total_recu),
      'gestionnaire', COALESCE(p_gest, 'gestionnaire'),
      'quand',        v_now,
      'reference',    v_ref
    )) || COALESCE(v_data->'journal', '[]'::jsonb)
  );

  -- Sauvegarder
  UPDATE public.tontines
  SET data = v_data, updated_at = now()
  WHERE code = p_code;

  RETURN jsonb_build_object(
    'ok',                 true,
    'tourDistribue',      v_tour_actuel + 1,
    'beneficiaire',       v_benef_nom,
    'beneficiaireId',     v_benef_id,
    'montantRecu',        v_total_recu,
    'cycleTermine',       v_est_dernier,
    'prochainTour',       CASE WHEN v_est_dernier THEN null ELSE v_new_tour + 1 END,
    'prochainBeneficiaire', CASE
      WHEN v_est_dernier THEN null
      ELSE _tc_nom_membre(v_data, v_ordre->>(v_new_tour)::int)
    END
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.distribuer_tour TO anon, authenticated;

-- =============================================================================
-- BLOC DE VÉRIFICATION 010
-- =============================================================================
DO $verify010$
DECLARE
  v_missing text[] := ARRAY[]::text[];
  v_fn      text;
  v_fns     text[] := ARRAY[
    'sauvegarder_token',
    'creer_transaction_sycapay',
    'get_pending_sycapay_transactions',
    'crediter_caisse_sycapay',
    'crediter_cotisation_sycapay',
    'crediter_penalite_sycapay',
    'recalculer_echeances_expir',
    'distribuer_tour'
  ];
BEGIN
  FOREACH v_fn IN ARRAY v_fns LOOP
    IF NOT EXISTS (
      SELECT 1 FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public' AND p.proname = v_fn
    ) THEN
      v_missing := array_append(v_missing, v_fn);
    END IF;
  END LOOP;

  IF array_length(v_missing, 1) > 0 THEN
    RAISE EXCEPTION '❌ Migration 010 incomplète — fonctions manquantes : %', array_to_string(v_missing, ', ');
  END IF;

  -- Vérifier les colonnes sycapay_transactions v2
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name   = 'sycapay_transactions'
      AND column_name  = 'sycapay_reference'
  ) THEN
    RAISE WARNING '⚠️  Colonne sycapay_reference absente de sycapay_transactions (ALTER TABLE ignoré ?)';
  END IF;

  RAISE NOTICE '✅ Migration 010 vérifiée — 8 RPCs (Notifications FCM + SycaPay) présents.';
  RAISE NOTICE '   sauvegarder_token              ✓';
  RAISE NOTICE '   creer_transaction_sycapay      ✓';
  RAISE NOTICE '   get_pending_sycapay_transactions ✓';
  RAISE NOTICE '   crediter_caisse_sycapay        ✓';
  RAISE NOTICE '   crediter_cotisation_sycapay    ✓';
  RAISE NOTICE '   crediter_penalite_sycapay      ✓';
  RAISE NOTICE '   recalculer_echeances_expir     ✓';
  RAISE NOTICE '   distribuer_tour                ✓';
END;
$verify010$;
-- ═══════════════════════════════════════════════════════════════════════════════
-- Migration 011 — RPCs fondamentaux v1 (reconstruits)
-- ═══════════════════════════════════════════════════════════════════════════════
--
-- CONTEXTE :
--   Ces 10 fonctions constituent le noyau applicatif de TontineClair v1.
--   Elles ont été créées directement dans Supabase SQL Editor et n'ont
--   jamais été sauvegardées dans un fichier SQL source dans le dépôt.
--
--   Elles ont été reconstruites fidèlement à partir de :
--     • Les signatures d'appel exactes de lib/services/supabase_service.dart
--     • Les patterns établis dans les migrations 001–010
--     • Le schéma de la table tontines (colonne `data jsonb`, `gestionnaires jsonb`,
--       `membres_pins jsonb`, `plan text`, `plan_expire timestamptz`)
--     • La documentation inline dans les commentaires Dart
--
-- FONCTIONS RECONSTRUITES (10) :
--   1.  creer_tontine                  — Créer une nouvelle tontine
--   2.  ecrire_tontine                 — Écrire les données avec vérif PIN gestionnaire
--   3.  lire_voix_tontine              — Lister les voix d'une tontine
--   4.  lire_plan                      — Lire le plan Premium simplifié {plan, expire}
--   5.  membres_avec_pin               — Lister les IDs membres ayant un PIN
--   6.  definir_pin_membre             — Admin définit le PIN d'un membre
--   7.  changer_pin_membre             — Membre change son propre PIN
--   8.  admin_desactiver_premium       — Super admin désactive Premium
--   9.  sauvegarder_langue_appareil    — Sauvegarder langue préférée d'un appareil
--  10.  charger_langue_appareil        — Charger langue préférée d'un appareil
--
-- NOTE : Les fonctions de langue (9 & 10) s'appuient sur la table fcm_tokens
--        (migration 004) qui contient déjà une colonne `langue` (text).
--        Elles sont marquées « NEW FEATURE » car non encore déployées en prod.
--
-- IDEMPOTENT : CREATE OR REPLACE — safe à rejouer
-- ═══════════════════════════════════════════════════════════════════════════════


-- ══════════════════════════════════════════════════════════════════════════════
-- 1. creer_tontine
-- ══════════════════════════════════════════════════════════════════════════════
--
-- Appelé depuis Dart :
--   rpc('creer_tontine', {
--     'p_code':          code.toUpperCase(),
--     'p_gestionnaires': gestionnaires,   // List<Map> [{nom, pin}, ...]
--     'p_data':          data,            // Map<String,dynamic> (TontineData JSON)
--   })
--   Retourne : bool (true = OK, false/null = code déjà pris)
--
CREATE OR REPLACE FUNCTION public.creer_tontine(
  p_code          text,
  p_gestionnaires jsonb,
  p_data          jsonb
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_code text := upper(trim(p_code));
BEGIN
  -- Vérifie que le code n'existe pas encore
  IF EXISTS (SELECT 1 FROM tontines WHERE code = v_code) THEN
    RETURN false;
  END IF;

  INSERT INTO tontines(code, gestionnaires, data)
  VALUES (v_code, p_gestionnaires, p_data);

  INSERT INTO audit(code, gestionnaire, empreinte)
  VALUES (v_code, 'creer_tontine', md5(p_data::text));

  RETURN true;
END;
$$;

GRANT EXECUTE ON FUNCTION public.creer_tontine(text, jsonb, jsonb) TO anon, authenticated;


-- ══════════════════════════════════════════════════════════════════════════════
-- 2. ecrire_tontine
-- ══════════════════════════════════════════════════════════════════════════════
--
-- Appelé depuis Dart :
--   rpc('ecrire_tontine', {
--     'p_code': code.toUpperCase(),
--     'p_nom':  nom,
--     'p_pin':  pin,
--     'p_data': data,
--   })
--   Retourne : bool (true = OK, false = PIN incorrect ou tontine introuvable)
--
CREATE OR REPLACE FUNCTION public.ecrire_tontine(
  p_code text,
  p_nom  text,
  p_pin  text,
  p_data jsonb
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_code text := upper(trim(p_code));
  v_ok   boolean;
BEGIN
  -- Vérifier PIN gestionnaire
  SELECT verifier_gestionnaire(v_code, p_nom, p_pin) INTO v_ok;
  IF NOT v_ok THEN
    RETURN false;
  END IF;

  UPDATE tontines
     SET data       = p_data,
         modifie_le = now()
   WHERE code = v_code;

  IF FOUND THEN
    INSERT INTO audit(code, gestionnaire, empreinte)
    VALUES (v_code, p_nom, md5(p_data::text));
  END IF;

  RETURN FOUND;
END;
$$;

GRANT EXECUTE ON FUNCTION public.ecrire_tontine(text, text, text, jsonb) TO anon, authenticated;


-- ══════════════════════════════════════════════════════════════════════════════
-- 3. lire_voix_tontine
-- ══════════════════════════════════════════════════════════════════════════════
--
-- Appelé depuis Dart :
--   rpc('lire_voix_tontine', {'p_code': code.toUpperCase()})
--   Retourne : List (jsonb array) de toutes les voix de la tontine
--              [{code, vote_id, membre_id, choix, methode, appareil, vote_le}, ...]
--
CREATE OR REPLACE FUNCTION public.lire_voix_tontine(p_code text)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'id',        v.id,
        'code',      v.code,
        'vote_id',   v.vote_id,
        'membre_id', v.membre_id,
        'choix',     v.choix,
        'methode',   v.methode,
        'appareil',  v.appareil,
        'vote_le',   v.vote_le
      )
      ORDER BY v.vote_le ASC
    ),
    '[]'::jsonb
  )
  FROM voix v
  WHERE v.code = upper(trim(p_code));
$$;

GRANT EXECUTE ON FUNCTION public.lire_voix_tontine(text) TO anon, authenticated;


-- ══════════════════════════════════════════════════════════════════════════════
-- 4. lire_plan
-- ══════════════════════════════════════════════════════════════════════════════
--
-- Appelé depuis Dart (deux endroits) :
--   rpc('lire_plan', {'p_code': code.toUpperCase()})
--   Retourne : Map {'plan': 'free'|'premium_monthly'|'premium_yearly'|'premium',
--                   'expire': ISO8601 string | null}
--   Fallback Flutter: {'plan': 'free', 'expire': null} si exception
--
-- Simplifie lire_abonnement_tontine pour l'usage Flutter (format plus court).
--
CREATE OR REPLACE FUNCTION public.lire_plan(p_code text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_code     text := upper(trim(p_code));
  v_plan     text := 'free';
  v_expire   timestamptz;
  v_sub_plan text;
  v_sub_exp  timestamptz;
  v_sub_stat text;
BEGIN
  -- 1. Chercher dans la table subscriptions (source de vérité v7+)
  SELECT plan, expires_at, status
    INTO v_sub_plan, v_sub_exp, v_sub_stat
  FROM subscriptions
  WHERE code = v_code
    AND status IN ('active', 'grace_period', 'pending')
  ORDER BY cree_le DESC
  LIMIT 1;

  IF FOUND THEN
    RETURN jsonb_build_object(
      'plan',   v_sub_plan,
      'expire', CASE WHEN v_sub_exp IS NOT NULL
                     THEN to_char(v_sub_exp AT TIME ZONE 'UTC',
                                  'YYYY-MM-DD"T"HH24:MI:SS"Z"')
                     ELSE NULL END
    );
  END IF;

  -- 2. Fallback : colonne tontines.plan (v5/v6)
  BEGIN
    SELECT t.plan, t.plan_expire
      INTO v_plan, v_expire
    FROM tontines t
    WHERE t.code = v_code
    LIMIT 1;
  EXCEPTION WHEN others THEN
    NULL;
  END;

  IF v_plan IN ('premium', 'premium_monthly', 'premium_yearly') THEN
    RETURN jsonb_build_object(
      'plan',   v_plan,
      'expire', CASE WHEN v_expire IS NOT NULL
                     THEN to_char(v_expire AT TIME ZONE 'UTC',
                                  'YYYY-MM-DD"T"HH24:MI:SS"Z"')
                     ELSE NULL END
    );
  END IF;

  -- 3. Gratuit par défaut
  RETURN jsonb_build_object('plan', 'free', 'expire', NULL);
END;
$$;

GRANT EXECUTE ON FUNCTION public.lire_plan(text) TO anon, authenticated;


-- ══════════════════════════════════════════════════════════════════════════════
-- 5. membres_avec_pin
-- ══════════════════════════════════════════════════════════════════════════════
--
-- Appelé depuis Dart :
--   rpc('membres_avec_pin', {'p_code': code.toUpperCase()})
--   Retourne : List<String> — liste des IDs membres ayant un PIN défini
--   (membres_pins est une colonne jsonb de tontines : [{id, pin}, ...])
--
CREATE OR REPLACE FUNCTION public.membres_avec_pin(p_code text)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(
    jsonb_agg(mp->>'id' ORDER BY (mp->>'id'))
    FILTER (WHERE (mp->>'pin') IS NOT NULL AND length(trim(mp->>'pin')) > 0),
    '[]'::jsonb
  )
  FROM tontines t,
       jsonb_array_elements(COALESCE(t.membres_pins, '[]'::jsonb)) AS mp
  WHERE t.code = upper(trim(p_code));
$$;

GRANT EXECUTE ON FUNCTION public.membres_avec_pin(text) TO anon, authenticated;


-- ══════════════════════════════════════════════════════════════════════════════
-- 6. definir_pin_membre
-- ══════════════════════════════════════════════════════════════════════════════
--
-- Appelé depuis Dart :
--   rpc('definir_pin_membre', {
--     'p_code':       code.toUpperCase(),
--     'p_nom':        gestNom,
--     'p_pin':        gestPin,
--     'p_membre_id':  membreId,
--     'p_pin_membre': nouveauPin,
--   })
--   Retourne : bool (true = OK, false = PIN gestionnaire incorrect)
--
-- Le gestionnaire admin définit ou réinitialise le PIN d'un membre.
-- membres_pins est stockée dans la colonne membres_pins jsonb de tontines.
--
CREATE OR REPLACE FUNCTION public.definir_pin_membre(
  p_code       text,
  p_nom        text,
  p_pin        text,
  p_membre_id  text,
  p_pin_membre text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_code     text := upper(trim(p_code));
  v_ok       boolean;
  v_pins     jsonb;
  v_new_pins jsonb;
  v_found    boolean := false;
  v_entry    jsonb;
  i          integer;
BEGIN
  -- Vérifier PIN gestionnaire
  SELECT verifier_gestionnaire(v_code, p_nom, p_pin) INTO v_ok;
  IF NOT v_ok THEN
    RETURN false;
  END IF;

  -- Lire membres_pins actuels
  SELECT COALESCE(membres_pins, '[]'::jsonb)
    INTO v_pins
  FROM tontines
  WHERE code = v_code;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  -- Chercher si p_membre_id existe déjà dans membres_pins
  v_new_pins := '[]'::jsonb;
  FOR i IN 0 .. jsonb_array_length(v_pins) - 1 LOOP
    v_entry := v_pins->i;
    IF (v_entry->>'id') = p_membre_id THEN
      -- Remplacer le PIN existant
      v_new_pins := v_new_pins || jsonb_build_array(
        jsonb_build_object('id', p_membre_id, 'pin', p_pin_membre)
      );
      v_found := true;
    ELSE
      v_new_pins := v_new_pins || jsonb_build_array(v_entry);
    END IF;
  END LOOP;

  -- Ajouter si non trouvé
  IF NOT v_found THEN
    v_new_pins := v_new_pins || jsonb_build_array(
      jsonb_build_object('id', p_membre_id, 'pin', p_pin_membre)
    );
  END IF;

  UPDATE tontines
     SET membres_pins = v_new_pins,
         modifie_le   = now()
   WHERE code = v_code;

  INSERT INTO audit(code, gestionnaire, empreinte)
  VALUES (v_code, p_nom, 'PIN_DEFINI:' || p_membre_id);

  RETURN true;
END;
$$;

GRANT EXECUTE ON FUNCTION public.definir_pin_membre(text, text, text, text, text) TO anon, authenticated;


-- ══════════════════════════════════════════════════════════════════════════════
-- 7. changer_pin_membre
-- ══════════════════════════════════════════════════════════════════════════════
--
-- Appelé depuis Dart :
--   rpc('changer_pin_membre', {
--     'p_code':      code.toUpperCase(),
--     'p_membre_id': membreId,
--     'p_ancien':    ancienPin,
--     'p_nouveau':   nouveauPin,
--   })
--   Retourne : bool (true = OK, false = ancien PIN incorrect ou membre introuvable)
--
-- Le membre change lui-même son PIN en fournissant l'ancien.
--
CREATE OR REPLACE FUNCTION public.changer_pin_membre(
  p_code      text,
  p_membre_id text,
  p_ancien    text,
  p_nouveau   text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_code     text := upper(trim(p_code));
  v_pins     jsonb;
  v_new_pins jsonb;
  v_found    boolean := false;
  v_entry    jsonb;
  i          integer;
BEGIN
  -- Vérifier que le membre existe et que l'ancien PIN correspond
  SELECT COALESCE(membres_pins, '[]'::jsonb)
    INTO v_pins
  FROM tontines
  WHERE code = v_code
    AND membres_pins @> jsonb_build_array(
          jsonb_build_object('id', p_membre_id, 'pin', p_ancien)
        );

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  -- Remplacer le PIN
  v_new_pins := '[]'::jsonb;
  FOR i IN 0 .. jsonb_array_length(v_pins) - 1 LOOP
    v_entry := v_pins->i;
    IF (v_entry->>'id') = p_membre_id THEN
      v_new_pins := v_new_pins || jsonb_build_array(
        jsonb_build_object('id', p_membre_id, 'pin', p_nouveau)
      );
      v_found := true;
    ELSE
      v_new_pins := v_new_pins || jsonb_build_array(v_entry);
    END IF;
  END LOOP;

  IF NOT v_found THEN
    RETURN false;
  END IF;

  UPDATE tontines
     SET membres_pins = v_new_pins,
         modifie_le   = now()
   WHERE code = v_code;

  INSERT INTO audit(code, gestionnaire, empreinte)
  VALUES (v_code, 'MEMBRE:' || p_membre_id, 'PIN_CHANGE');

  RETURN true;
END;
$$;

GRANT EXECUTE ON FUNCTION public.changer_pin_membre(text, text, text, text) TO anon, authenticated;


-- ══════════════════════════════════════════════════════════════════════════════
-- 8. admin_desactiver_premium
-- ══════════════════════════════════════════════════════════════════════════════
--
-- Appelé depuis Dart :
--   rpc('admin_desactiver_premium', {
--     'p_cle':  cle,
--     'p_code': code.toUpperCase(),
--   })
--   Retourne : bool (true = OK, false = clé invalide ou tontine introuvable)
--
-- Super admin désactive manuellement le Premium d'une tontine.
-- Remet plan = 'free', annule l'abonnement actif dans subscriptions.
--
CREATE OR REPLACE FUNCTION public.admin_desactiver_premium(
  p_cle  text,
  p_code text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_code        text := upper(trim(p_code));
  v_cle_ok      boolean;
BEGIN
  -- Vérifier clé admin (réutilise _verif_admin_cle si elle existe)
  BEGIN
    SELECT _verif_admin_cle(p_cle) INTO v_cle_ok;
  EXCEPTION WHEN undefined_function THEN
    -- Fallback direct si _verif_admin_cle n'existe pas encore
    SELECT (p_cle = (SELECT cle FROM admin_config LIMIT 1)) INTO v_cle_ok;
  END;

  IF NOT COALESCE(v_cle_ok, false) THEN
    RETURN false;
  END IF;

  -- Mettre à jour la table tontines (colonne plan — rétrocompatibilité v5/v6)
  UPDATE tontines
     SET plan        = 'free',
         plan_expire = NULL,
         modifie_le  = now()
   WHERE code = v_code;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  -- Annuler les abonnements actifs dans subscriptions (v7+)
  UPDATE subscriptions
     SET status     = 'expired',
         modifie_le = now()
   WHERE code   = v_code
     AND status IN ('active', 'grace_period', 'pending');

  -- Journal d'audit
  BEGIN
    INSERT INTO audit(code, gestionnaire, empreinte)
    VALUES (v_code, 'SUPER_ADMIN', 'PREMIUM_DESACTIVE:' || v_code);
  EXCEPTION WHEN others THEN NULL;
  END;

  RETURN true;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_desactiver_premium(text, text) TO anon, authenticated;


-- ══════════════════════════════════════════════════════════════════════════════
-- 9. sauvegarder_langue_appareil  [NEW FEATURE — pas encore en prod]
-- ══════════════════════════════════════════════════════════════════════════════
--
-- Appelé depuis Dart :
--   rpc('sauvegarder_langue_appareil', {
--     'p_token':  token,      // fcm_token ou identifiant appareil
--     'p_langue': langueCode, // ex: 'fr', 'en', 'ar'
--   })
--   Retourne : void (silencieux — erreur non bloquante côté Flutter)
--
-- Utilise la table fcm_tokens (migration 004) — colonne langue text.
-- ALTER TABLE guard : ajoute la colonne si elle n'existe pas encore.
--
DO $lang_col$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'fcm_tokens' AND column_name = 'langue'
  ) THEN
    ALTER TABLE fcm_tokens ADD COLUMN langue text;
  END IF;
END;
$lang_col$;

CREATE OR REPLACE FUNCTION public.sauvegarder_langue_appareil(
  p_token  text,
  p_langue text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Upsert : met à jour la ligne existante ou insère une nouvelle
  UPDATE fcm_tokens
     SET langue     = p_langue,
         modifie_le = now()
   WHERE token = p_token;

  -- Si le token n'est pas encore dans fcm_tokens, on l'insère sans user_id
  -- (le token sera mis à jour lors du prochain sauvegarder_token)
  IF NOT FOUND THEN
    BEGIN
      INSERT INTO fcm_tokens(token, langue)
      VALUES (p_token, p_langue);
    EXCEPTION WHEN others THEN
      -- Ignorer les erreurs d'insertion (contrainte NOT NULL user_id, etc.)
      NULL;
    END;
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION public.sauvegarder_langue_appareil(text, text) TO anon, authenticated;


-- ══════════════════════════════════════════════════════════════════════════════
-- 10. charger_langue_appareil  [NEW FEATURE — pas encore en prod]
-- ══════════════════════════════════════════════════════════════════════════════
--
-- Appelé depuis Dart :
--   rpc('charger_langue_appareil', {'p_token': token})
--   Retourne : Map {'langue': 'fr'|'en'|...} ou null si non trouvé
--   Fallback Flutter: null → SharedPreferences prend le relais
--
CREATE OR REPLACE FUNCTION public.charger_langue_appareil(p_token text)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT CASE
    WHEN f.langue IS NOT NULL AND length(trim(f.langue)) > 0
    THEN jsonb_build_object('langue', f.langue)
    ELSE NULL
  END
  FROM fcm_tokens f
  WHERE f.token = p_token
  LIMIT 1;
$$;

GRANT EXECUTE ON FUNCTION public.charger_langue_appareil(text) TO anon, authenticated;


-- ══════════════════════════════════════════════════════════════════════════════
-- VÉRIFICATION POST-MIGRATION
-- ══════════════════════════════════════════════════════════════════════════════

DO $verify011$
DECLARE
  v_creer_tontine               boolean;
  v_ecrire_tontine              boolean;
  v_lire_voix_tontine           boolean;
  v_lire_plan                   boolean;
  v_membres_avec_pin            boolean;
  v_definir_pin_membre          boolean;
  v_changer_pin_membre          boolean;
  v_admin_desactiver_premium    boolean;
  v_sauvegarder_langue_appareil boolean;
  v_charger_langue_appareil     boolean;
BEGIN
  SELECT EXISTS(SELECT 1 FROM pg_proc WHERE proname = 'creer_tontine')
    INTO v_creer_tontine;
  SELECT EXISTS(SELECT 1 FROM pg_proc WHERE proname = 'ecrire_tontine')
    INTO v_ecrire_tontine;
  SELECT EXISTS(SELECT 1 FROM pg_proc WHERE proname = 'lire_voix_tontine')
    INTO v_lire_voix_tontine;
  SELECT EXISTS(SELECT 1 FROM pg_proc WHERE proname = 'lire_plan')
    INTO v_lire_plan;
  SELECT EXISTS(SELECT 1 FROM pg_proc WHERE proname = 'membres_avec_pin')
    INTO v_membres_avec_pin;
  SELECT EXISTS(SELECT 1 FROM pg_proc WHERE proname = 'definir_pin_membre')
    INTO v_definir_pin_membre;
  SELECT EXISTS(SELECT 1 FROM pg_proc WHERE proname = 'changer_pin_membre')
    INTO v_changer_pin_membre;
  SELECT EXISTS(SELECT 1 FROM pg_proc WHERE proname = 'admin_desactiver_premium')
    INTO v_admin_desactiver_premium;
  SELECT EXISTS(SELECT 1 FROM pg_proc WHERE proname = 'sauvegarder_langue_appareil')
    INTO v_sauvegarder_langue_appareil;
  SELECT EXISTS(SELECT 1 FROM pg_proc WHERE proname = 'charger_langue_appareil')
    INTO v_charger_langue_appareil;

  RAISE NOTICE '══════════════════════════════════════════════════════';
  RAISE NOTICE 'Migration 011 — RPCs fondamentaux v1 (reconstruits)';
  RAISE NOTICE '══════════════════════════════════════════════════════';
  RAISE NOTICE 'creer_tontine                : %', CASE WHEN v_creer_tontine               THEN '✅ OK' ELSE '❌ MANQUANT' END;
  RAISE NOTICE 'ecrire_tontine               : %', CASE WHEN v_ecrire_tontine              THEN '✅ OK' ELSE '❌ MANQUANT' END;
  RAISE NOTICE 'lire_voix_tontine            : %', CASE WHEN v_lire_voix_tontine           THEN '✅ OK' ELSE '❌ MANQUANT' END;
  RAISE NOTICE 'lire_plan                    : %', CASE WHEN v_lire_plan                   THEN '✅ OK' ELSE '❌ MANQUANT' END;
  RAISE NOTICE 'membres_avec_pin             : %', CASE WHEN v_membres_avec_pin            THEN '✅ OK' ELSE '❌ MANQUANT' END;
  RAISE NOTICE 'definir_pin_membre           : %', CASE WHEN v_definir_pin_membre          THEN '✅ OK' ELSE '❌ MANQUANT' END;
  RAISE NOTICE 'changer_pin_membre           : %', CASE WHEN v_changer_pin_membre          THEN '✅ OK' ELSE '❌ MANQUANT' END;
  RAISE NOTICE 'admin_desactiver_premium     : %', CASE WHEN v_admin_desactiver_premium    THEN '✅ OK' ELSE '❌ MANQUANT' END;
  RAISE NOTICE 'sauvegarder_langue_appareil  : %', CASE WHEN v_sauvegarder_langue_appareil THEN '✅ OK' ELSE '❌ MANQUANT' END;
  RAISE NOTICE 'charger_langue_appareil      : %', CASE WHEN v_charger_langue_appareil     THEN '✅ OK' ELSE '❌ MANQUANT' END;
  RAISE NOTICE '══════════════════════════════════════════════════════';
  RAISE NOTICE 'NOTE : sauvegarder/charger_langue_appareil sont des';
  RAISE NOTICE '       nouvelles fonctionnalités (pas encore en prod).';
  RAISE NOTICE '       Elles nécessitent ALTER TABLE fcm_tokens ADD COLUMN langue.';
  RAISE NOTICE '══════════════════════════════════════════════════════';
END;
$verify011$;
