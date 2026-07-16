-- ============================================================
-- TontineClair — upgrade.sql  v2
-- Mise à jour schéma (tables, colonnes, index, triggers, RLS)
-- sans aucune perte de données
-- ============================================================
--
-- PÉRIMÈTRE DE CE FICHIER :
--   ✅ Section A — Nouvelles tables           (IF NOT EXISTS)
--   ✅ Section B — Nouvelles colonnes          (ADD COLUMN IF NOT EXISTS)
--   ✅ Section C — Nouveaux index              (IF NOT EXISTS)
--   ✅ Section D — Triggers                    (DROP IF EXISTS + recréation)
--   ✅ Section E — Politiques RLS              (DROP IF EXISTS + recréation)
--   ✅ Section F — Fonctions / RPCs            (init_inline.sql)
--
-- POURQUOI LES FONCTIONS SONT DANS init_inline.sql ET PAS ICI :
--   PostgreSQL refuse CREATE OR REPLACE FUNCTION si les NOMS des
--   paramètres changent entre l'ancienne et la nouvelle version.
--   Les fonctions dans la base ont des signatures complètes (plus de
--   paramètres, noms différents) issues des migrations 006-011.
--   init_inline.sql contient les vraies signatures — il est le
--   fichier canonique pour les RPCs.
--
-- GARANTIE DE NON-DESTRUCTION :
--   ✅ Aucun DROP TABLE / TRUNCATE / DELETE FROM
--   ✅ Aucun DROP FUNCTION
--   ✅ CREATE TABLE         uniquement IF NOT EXISTS
--   ✅ ALTER TABLE          uniquement ADD COLUMN IF NOT EXISTS
--   ✅ Toutes les colonnes NOT NULL ont un DEFAULT
--   ✅ CREATE INDEX         uniquement IF NOT EXISTS
--   ✅ DROP TRIGGER IF EXISTS avant recréation (safe)
--   ✅ DROP POLICY IF EXISTS avant recréation (métadonnées seules)
--   ✅ Rejouer n fois       → résultat identique
--
-- DONNÉES CONSERVÉES : utilisateurs, tontines, cotisations, prêts,
--   abonnements, votes, scores, KYC, tickets support, transactions,
--   tokens FCM — rien n'est effacé ni modifié.
--
-- COMMENT UTILISER CE FICHIER :
--   Étape 1 — Schéma :
--     Supabase SQL Editor → New query → Coller upgrade.sql → Run
--   Étape 2 — Fonctions/RPCs :
--     Supabase SQL Editor → New query → Coller init_inline.sql → Run
--   (ou psql -f upgrade.sql && psql -f init_inline.sql)
--
-- VERSION : migrations 001→011 — 2025-07-16
-- ============================================================

-- ============================================================
-- SECTION A : NOUVELLES TABLES (no-op si déjà présentes)
-- ============================================================

-- A.1 — voix : table des votes (était absente de toutes les migrations)
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

-- A.2 — Toutes les autres tables core (no-op si présentes)
CREATE TABLE IF NOT EXISTS tontines (
  id                     BIGSERIAL   PRIMARY KEY,
  code                   TEXT        NOT NULL UNIQUE,
  data                   JSONB       NOT NULL DEFAULT '{}',
  gestionnaires          JSONB       DEFAULT '[]',
  membres_pins           JSONB       DEFAULT '[]',
  plan                   TEXT        NOT NULL DEFAULT 'free',
  plan_expire            TIMESTAMPTZ,
  cree                   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  modifie_le             TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  status                 TEXT        NOT NULL DEFAULT 'active'
                         CHECK (status IN ('active','inactive','suspended','deleted')),
  deleted_at             TIMESTAMPTZ,
  deleted_by             TEXT,
  deletion_reason        TEXT,
  invitation_code_active BOOLEAN     NOT NULL DEFAULT TRUE,
  updated_at             TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_at             TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS audit (
  id     BIGSERIAL   PRIMARY KEY,
  code   TEXT        NOT NULL,
  action TEXT        NOT NULL,
  data   JSONB,
  quand  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS demandes_premium (
  id         BIGSERIAL   PRIMARY KEY,
  code       TEXT        NOT NULL,
  membre_id  TEXT        NOT NULL,
  plan       TEXT        NOT NULL DEFAULT 'premium',
  statut     TEXT        NOT NULL DEFAULT 'en_attente',
  demande_le TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  traite_le  TIMESTAMPTZ,
  traite_par TEXT
);

CREATE TABLE IF NOT EXISTS config (
  id     BIGSERIAL PRIMARY KEY,
  cle    TEXT      NOT NULL UNIQUE,
  valeur JSONB
);

CREATE TABLE IF NOT EXISTS app_config (
  id     BIGSERIAL PRIMARY KEY,
  cle    TEXT      NOT NULL UNIQUE,
  valeur JSONB
);

CREATE TABLE IF NOT EXISTS admin_config (
  id     BIGSERIAL PRIMARY KEY,
  cle    TEXT      NOT NULL UNIQUE,
  valeur JSONB
);

CREATE TABLE IF NOT EXISTS scores_historique (
  id        BIGSERIAL   PRIMARY KEY,
  code      TEXT        NOT NULL,
  membre_id TEXT        NOT NULL,
  type      TEXT        NOT NULL,
  delta     INTEGER     NOT NULL DEFAULT 0,
  raison    TEXT,
  quand     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS propositions_retrait (
  id         BIGSERIAL   PRIMARY KEY,
  code       TEXT        NOT NULL,
  membre_id  TEXT        NOT NULL,
  montant    INTEGER     NOT NULL,
  motif      TEXT,
  statut     TEXT        NOT NULL DEFAULT 'en_attente',
  propose_le TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  traite_le  TIMESTAMPTZ,
  traite_par TEXT
);

CREATE TABLE IF NOT EXISTS journal_audit (
  id      BIGSERIAL   PRIMARY KEY,
  code    TEXT        NOT NULL,
  acteur  TEXT        NOT NULL,
  action  TEXT        NOT NULL,
  details JSONB,
  quand   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS subscriptions (
  id         BIGSERIAL   PRIMARY KEY,
  code       TEXT        NOT NULL UNIQUE,
  plan       TEXT        NOT NULL DEFAULT 'free',
  statut     TEXT        NOT NULL DEFAULT 'actif',
  debut      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  fin        TIMESTAMPTZ,
  modifie_le TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS abonnements (
  id        BIGSERIAL   PRIMARY KEY,
  code      TEXT        NOT NULL,
  plan      TEXT        NOT NULL,
  statut    TEXT        NOT NULL DEFAULT 'actif',
  debut     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  fin       TIMESTAMPTZ,
  reference TEXT,
  cree_le   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS admin_actions (
  id       BIGSERIAL   PRIMARY KEY,
  admin_id TEXT        NOT NULL,
  action   TEXT        NOT NULL,
  cible    TEXT,
  details  JSONB,
  fait_le  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS sycapay_transactions (
  id          BIGSERIAL   PRIMARY KEY,
  code        TEXT        NOT NULL,
  membre_id   TEXT        NOT NULL,
  type        TEXT        NOT NULL,
  montant     INTEGER     NOT NULL,
  statut      TEXT        NOT NULL DEFAULT 'en_attente',
  reference   TEXT,
  sycapay_ref TEXT,
  cree_le     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  traite_le   TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS prets_pending (
  id         BIGSERIAL   PRIMARY KEY,
  code       TEXT        NOT NULL,
  emprunteur TEXT        NOT NULL,
  montant    INTEGER     NOT NULL,
  statut     TEXT        NOT NULL DEFAULT 'en_attente',
  demande_le TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  traite_le  TIMESTAMPTZ,
  traite_par TEXT
);

CREATE TABLE IF NOT EXISTS decaissements_pending (
  id           BIGSERIAL   PRIMARY KEY,
  code         TEXT        NOT NULL,
  beneficiaire TEXT        NOT NULL,
  montant      INTEGER     NOT NULL,
  statut       TEXT        NOT NULL DEFAULT 'en_attente',
  cree_le      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  traite_le    TIMESTAMPTZ,
  traite_par   TEXT
);

CREATE TABLE IF NOT EXISTS depenses_pending (
  id          BIGSERIAL   PRIMARY KEY,
  code        TEXT        NOT NULL,
  description TEXT        NOT NULL,
  montant     INTEGER     NOT NULL,
  statut      TEXT        NOT NULL DEFAULT 'en_attente',
  cree_le     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  traite_le   TIMESTAMPTZ,
  traite_par  TEXT
);

CREATE TABLE IF NOT EXISTS premium_requests (
  id         BIGSERIAL   PRIMARY KEY,
  code       TEXT        NOT NULL UNIQUE,
  membre_id  TEXT        NOT NULL,
  plan       TEXT        NOT NULL DEFAULT 'premium',
  statut     TEXT        NOT NULL DEFAULT 'en_attente',
  demande_le TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  traite_le  TIMESTAMPTZ,
  traite_par TEXT
);

CREATE TABLE IF NOT EXISTS public.kyc_submissions (
  id         BIGSERIAL   PRIMARY KEY,
  code       TEXT        NOT NULL,
  membre_id  TEXT        NOT NULL,
  type_doc   TEXT        NOT NULL,
  url_doc    TEXT        NOT NULL,
  statut     TEXT        NOT NULL DEFAULT 'en_attente',
  soumis_le  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  traite_le  TIMESTAMPTZ,
  traite_par TEXT,
  notes      TEXT
);

CREATE TABLE IF NOT EXISTS public.fcm_tokens (
  id         BIGSERIAL   PRIMARY KEY,
  tontine    TEXT        NOT NULL,
  membre_id  TEXT        NOT NULL,
  token      TEXT        NOT NULL UNIQUE,
  appareil   TEXT,
  mis_a_jour TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS rappels_envoyes (
  id        BIGSERIAL   PRIMARY KEY,
  code      TEXT        NOT NULL,
  membre_id TEXT        NOT NULL,
  type      TEXT        NOT NULL,
  envoye_le TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (code, membre_id, type)
);

CREATE TABLE IF NOT EXISTS admin_membres (
  id        BIGSERIAL   PRIMARY KEY,
  pseudo    TEXT        NOT NULL UNIQUE,
  cle_perso TEXT        NOT NULL,
  role      TEXT        NOT NULL DEFAULT 'moderateur',
  cree_le   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS admin_messages (
  id           BIGSERIAL   PRIMARY KEY,
  expediteur   TEXT        NOT NULL,
  destinataire TEXT        NOT NULL,
  contenu      TEXT        NOT NULL,
  lu           BOOLEAN     NOT NULL DEFAULT FALSE,
  envoye_le    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS support_tickets (
  id           BIGSERIAL   PRIMARY KEY,
  ref          TEXT        NOT NULL UNIQUE,
  gestionnaire TEXT        NOT NULL,
  tontine_code TEXT,
  sujet        TEXT        NOT NULL,
  statut       TEXT        NOT NULL DEFAULT 'ouvert',
  priorite     TEXT        NOT NULL DEFAULT 'normale',
  cree_le      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  ferme_le     TIMESTAMPTZ,
  ferme_par    TEXT
);

CREATE TABLE IF NOT EXISTS support_messages (
  id          BIGSERIAL   PRIMARY KEY,
  ticket_id   BIGINT      NOT NULL REFERENCES support_tickets(id) ON DELETE CASCADE,
  auteur      TEXT        NOT NULL,
  role_auteur TEXT        NOT NULL DEFAULT 'client',
  contenu     TEXT        NOT NULL,
  envoye_le   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);


-- ============================================================
-- SECTION B : NOUVELLES COLONNES (no-op si déjà présentes)
-- ============================================================
-- Règle stricte : toute colonne NOT NULL a un DEFAULT.
-- → Aucun risque sur les lignes existantes.

-- B.1 — tontines : colonnes v2 (gestionnaires, membres_pins, plan, etc.)
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

-- B.2 — sycapay_transactions : colonnes v2 (API SycaPay mise à jour)
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
ALTER TABLE sycapay_transactions ADD COLUMN IF NOT EXISTS amount                   INTEGER;
ALTER TABLE sycapay_transactions ADD COLUMN IF NOT EXISTS currency                 TEXT;
ALTER TABLE sycapay_transactions ADD COLUMN IF NOT EXISTS operator                 TEXT;
ALTER TABLE sycapay_transactions ADD COLUMN IF NOT EXISTS phone_number_masked      TEXT;
ALTER TABLE sycapay_transactions ADD COLUMN IF NOT EXISTS description              TEXT;
ALTER TABLE sycapay_transactions ADD COLUMN IF NOT EXISTS status                   TEXT DEFAULT 'pending';
ALTER TABLE sycapay_transactions ADD COLUMN IF NOT EXISTS polling_attempts         INTEGER DEFAULT 0;

-- B.3 — fcm_tokens : colonne langue (préférences de notification)
DO $lang_guard$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name   = 'fcm_tokens'
      AND column_name  = 'langue'
  ) THEN
    ALTER TABLE fcm_tokens ADD COLUMN langue text;
  END IF;
END;
$lang_guard$;


-- ============================================================
-- SECTION C : INDEX (no-op si déjà présents)
-- ============================================================

-- tontines
CREATE INDEX IF NOT EXISTS idx_tontines_code   ON tontines(code);
CREATE INDEX IF NOT EXISTS idx_tontines_status ON tontines(status);

-- voix
CREATE INDEX IF NOT EXISTS idx_voix_code    ON voix(code);
CREATE INDEX IF NOT EXISTS idx_voix_vote_id ON voix(code, vote_id);
CREATE UNIQUE INDEX IF NOT EXISTS voix_code_vote_id_membre_id_key
  ON voix(code, vote_id, membre_id);

-- audit
CREATE INDEX IF NOT EXISTS idx_audit_code ON audit(code, quand DESC);

-- demandes_premium
CREATE UNIQUE INDEX IF NOT EXISTS idx_demandes_premium_code ON demandes_premium(code);

-- scores_historique
CREATE INDEX IF NOT EXISTS idx_scores_hist_code_membre ON scores_historique(code, membre_id);
CREATE INDEX IF NOT EXISTS idx_scores_hist_code_quand  ON scores_historique(code, quand DESC);

-- propositions_retrait
CREATE INDEX IF NOT EXISTS idx_prop_retrait_code   ON propositions_retrait(code);
CREATE INDEX IF NOT EXISTS idx_prop_retrait_membre ON propositions_retrait(code, membre_id);

-- journal_audit
CREATE INDEX IF NOT EXISTS idx_journal_audit_code ON journal_audit(code, quand DESC);

-- subscriptions
CREATE INDEX IF NOT EXISTS idx_subscriptions_code   ON subscriptions(code);
CREATE INDEX IF NOT EXISTS idx_subscriptions_statut ON subscriptions(statut);
CREATE UNIQUE INDEX IF NOT EXISTS subscriptions_code_key ON subscriptions(code);

-- abonnements
CREATE INDEX IF NOT EXISTS idx_abonnements_code ON abonnements(code);

-- sycapay_transactions
CREATE INDEX IF NOT EXISTS idx_sycapay_code   ON sycapay_transactions(code);
CREATE INDEX IF NOT EXISTS idx_sycapay_statut ON sycapay_transactions(statut);
CREATE INDEX IF NOT EXISTS idx_sycapay_type   ON sycapay_transactions(type);
CREATE INDEX IF NOT EXISTS idx_sycapay_txn_ref
  ON sycapay_transactions(internal_reference)
  WHERE internal_reference IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_sycapay_txn_idempotency
  ON sycapay_transactions(idempotency_key)
  WHERE idempotency_key IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_sycapay_txn_membre
  ON sycapay_transactions(code, membre_id);
CREATE INDEX IF NOT EXISTS idx_sycapay_txn_provider
  ON sycapay_transactions(provider_transaction_id)
  WHERE provider_transaction_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS sycapay_transactions_internal_reference_key
  ON sycapay_transactions(internal_reference);
CREATE UNIQUE INDEX IF NOT EXISTS sycapay_transactions_idempotency_key_key
  ON sycapay_transactions(idempotency_key);

-- prets_pending
CREATE INDEX IF NOT EXISTS idx_prets_code   ON prets_pending(code);
CREATE INDEX IF NOT EXISTS idx_prets_statut ON prets_pending(statut);

-- decaissements_pending
CREATE INDEX IF NOT EXISTS idx_decaiss_code   ON decaissements_pending(code);
CREATE INDEX IF NOT EXISTS idx_decaiss_statut ON decaissements_pending(statut);

-- depenses_pending
CREATE INDEX IF NOT EXISTS idx_depenses_code   ON depenses_pending(code);
CREATE INDEX IF NOT EXISTS idx_depenses_statut ON depenses_pending(statut);

-- premium_requests
CREATE INDEX IF NOT EXISTS idx_premium_req_code   ON premium_requests(code);
CREATE INDEX IF NOT EXISTS idx_premium_req_statut ON premium_requests(statut);
CREATE UNIQUE INDEX IF NOT EXISTS premium_requests_code_key ON premium_requests(code);

-- kyc_submissions
CREATE INDEX IF NOT EXISTS idx_kyc_code   ON public.kyc_submissions(code);
CREATE INDEX IF NOT EXISTS idx_kyc_statut ON public.kyc_submissions(statut);

-- fcm_tokens
CREATE INDEX IF NOT EXISTS idx_fcm_tontine ON public.fcm_tokens(tontine);
CREATE UNIQUE INDEX IF NOT EXISTS fcm_tokens_token_key ON fcm_tokens(token);

-- rappels_envoyes
CREATE INDEX IF NOT EXISTS idx_rappels_code ON rappels_envoyes(code);
CREATE UNIQUE INDEX IF NOT EXISTS rappels_envoyes_code_membre_id_type_key
  ON rappels_envoyes(code, membre_id, type);

-- admin_membres
CREATE UNIQUE INDEX IF NOT EXISTS idx_admin_membres_pseudo ON admin_membres(pseudo);
CREATE INDEX        IF NOT EXISTS idx_admin_membres_role   ON admin_membres(role);
CREATE UNIQUE INDEX IF NOT EXISTS admin_membres_pseudo_key ON admin_membres(pseudo);

-- admin_messages
CREATE INDEX IF NOT EXISTS idx_admin_msg_dest  ON admin_messages(destinataire);
CREATE INDEX IF NOT EXISTS idx_admin_msg_exp   ON admin_messages(expediteur);
CREATE INDEX IF NOT EXISTS idx_admin_msg_date  ON admin_messages(envoye_le DESC);

-- support_tickets
CREATE INDEX IF NOT EXISTS idx_support_tickets_statut       ON support_tickets(statut);
CREATE INDEX IF NOT EXISTS idx_support_tickets_gestionnaire ON support_tickets(gestionnaire);
CREATE INDEX IF NOT EXISTS idx_support_tickets_ref          ON support_tickets(ref);
CREATE INDEX IF NOT EXISTS idx_support_tickets_cree_le      ON support_tickets(cree_le DESC);
CREATE UNIQUE INDEX IF NOT EXISTS support_tickets_ref_key   ON support_tickets(ref);

-- support_messages
CREATE INDEX IF NOT EXISTS idx_support_msg_ticket ON support_messages(ticket_id);
CREATE INDEX IF NOT EXISTS idx_support_msg_date   ON support_messages(envoye_le ASC);


-- ============================================================
-- SECTION D : TRIGGERS (DROP IF EXISTS + recréation — safe)
-- ============================================================

-- D.1 — tontines : updated_at automatique
CREATE OR REPLACE FUNCTION tontines_set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public
AS $$
BEGIN NEW.updated_at = NOW(); RETURN NEW; END;
$$;

DROP TRIGGER IF EXISTS trg_tontines_updated_at ON tontines;
CREATE TRIGGER trg_tontines_updated_at
  BEFORE UPDATE ON tontines
  FOR EACH ROW EXECUTE FUNCTION tontines_set_updated_at();

-- D.2 — subscriptions : modifie_le automatique
CREATE OR REPLACE FUNCTION _sub_update_modifie_le()
RETURNS TRIGGER LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public
AS $$
BEGIN NEW.modifie_le = NOW(); RETURN NEW; END;
$$;

DROP TRIGGER IF EXISTS trg_sub_modifie_le ON subscriptions;
CREATE TRIGGER trg_sub_modifie_le
  BEFORE UPDATE ON subscriptions
  FOR EACH ROW EXECUTE FUNCTION _sub_update_modifie_le();


-- ============================================================
-- SECTION E : RLS — ENABLE + POLITIQUES (métadonnées seules)
-- ============================================================
-- DROP POLICY IF EXISTS + CREATE POLICY = mise à jour in-place.
-- Ne touche pas aux données, uniquement aux règles d'accès.

ALTER TABLE tontines              ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit                 ENABLE ROW LEVEL SECURITY;
ALTER TABLE demandes_premium      ENABLE ROW LEVEL SECURITY;
ALTER TABLE config                ENABLE ROW LEVEL SECURITY;
ALTER TABLE app_config            ENABLE ROW LEVEL SECURITY;
ALTER TABLE admin_config          ENABLE ROW LEVEL SECURITY;
ALTER TABLE voix                  ENABLE ROW LEVEL SECURITY;
ALTER TABLE scores_historique     ENABLE ROW LEVEL SECURITY;
ALTER TABLE propositions_retrait  ENABLE ROW LEVEL SECURITY;
ALTER TABLE journal_audit         ENABLE ROW LEVEL SECURITY;
ALTER TABLE subscriptions         ENABLE ROW LEVEL SECURITY;
ALTER TABLE abonnements           ENABLE ROW LEVEL SECURITY;
ALTER TABLE admin_actions         ENABLE ROW LEVEL SECURITY;
ALTER TABLE sycapay_transactions  ENABLE ROW LEVEL SECURITY;
ALTER TABLE prets_pending         ENABLE ROW LEVEL SECURITY;
ALTER TABLE decaissements_pending ENABLE ROW LEVEL SECURITY;
ALTER TABLE depenses_pending      ENABLE ROW LEVEL SECURITY;
ALTER TABLE premium_requests      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.kyc_submissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.fcm_tokens      ENABLE ROW LEVEL SECURITY;
ALTER TABLE rappels_envoyes        ENABLE ROW LEVEL SECURITY;
ALTER TABLE admin_membres          ENABLE ROW LEVEL SECURITY;
ALTER TABLE admin_messages         ENABLE ROW LEVEL SECURITY;
ALTER TABLE support_tickets        ENABLE ROW LEVEL SECURITY;
ALTER TABLE support_messages       ENABLE ROW LEVEL SECURITY;

-- tontines
DROP POLICY IF EXISTS "tontines_anon_select" ON tontines;
CREATE POLICY "tontines_anon_select" ON tontines
  FOR SELECT TO anon, authenticated USING (true);
DROP POLICY IF EXISTS "tontines_anon_insert" ON tontines;
CREATE POLICY "tontines_anon_insert" ON tontines
  FOR INSERT TO anon, authenticated WITH CHECK (true);
DROP POLICY IF EXISTS "tontines_anon_update" ON tontines;
CREATE POLICY "tontines_anon_update" ON tontines
  FOR UPDATE TO anon, authenticated USING (true) WITH CHECK (true);

-- audit
DROP POLICY IF EXISTS "audit_anon" ON audit;
CREATE POLICY "audit_anon" ON audit
  FOR ALL TO anon, authenticated USING (true) WITH CHECK (true);

-- demandes_premium
DROP POLICY IF EXISTS "demandes_premium_select" ON demandes_premium;
CREATE POLICY "demandes_premium_select" ON demandes_premium
  FOR SELECT TO anon, authenticated USING (true);
DROP POLICY IF EXISTS "demandes_premium_insert" ON demandes_premium;
CREATE POLICY "demandes_premium_insert" ON demandes_premium
  FOR INSERT TO anon, authenticated WITH CHECK (true);
DROP POLICY IF EXISTS "demandes_premium_update" ON demandes_premium;
CREATE POLICY "demandes_premium_update" ON demandes_premium
  FOR UPDATE TO anon, authenticated USING (true);

-- config / app_config (accès bloqué — fonctions SECURITY DEFINER seulement)
DROP POLICY IF EXISTS "config_no_access"     ON config;
DROP POLICY IF EXISTS "app_config_no_access" ON app_config;
CREATE POLICY "config_no_access"     ON config     FOR ALL TO anon, authenticated USING (false);
CREATE POLICY "app_config_no_access" ON app_config FOR ALL TO anon, authenticated USING (false);

-- admin_config (accès bloqué)
DROP POLICY IF EXISTS "admin_config_no_access" ON admin_config;
CREATE POLICY "admin_config_no_access" ON admin_config
  FOR ALL TO anon, authenticated USING (false);

-- voix
DROP POLICY IF EXISTS "voix_anon" ON voix;
CREATE POLICY "voix_anon" ON voix
  FOR ALL TO anon, authenticated USING (true) WITH CHECK (true);

-- scores_historique
DROP POLICY IF EXISTS "scores_historique_select" ON scores_historique;
CREATE POLICY "scores_historique_select" ON scores_historique
  FOR ALL TO anon, authenticated USING (true) WITH CHECK (true);

-- propositions_retrait
DROP POLICY IF EXISTS "propositions_retrait_select" ON propositions_retrait;
CREATE POLICY "propositions_retrait_select" ON propositions_retrait
  FOR ALL TO anon, authenticated USING (true) WITH CHECK (true);

-- journal_audit
DROP POLICY IF EXISTS "journal_audit_select" ON journal_audit;
CREATE POLICY "journal_audit_select" ON journal_audit
  FOR ALL TO anon, authenticated USING (true) WITH CHECK (true);

-- subscriptions
DROP POLICY IF EXISTS "subscriptions_anon" ON subscriptions;
CREATE POLICY "subscriptions_anon" ON subscriptions
  FOR ALL TO anon, authenticated USING (true) WITH CHECK (true);

-- abonnements
DROP POLICY IF EXISTS "abonnements_service" ON abonnements;
CREATE POLICY "abonnements_service" ON abonnements
  FOR ALL TO anon, authenticated USING (true) WITH CHECK (true);

-- admin_actions
DROP POLICY IF EXISTS "admin_actions_service" ON admin_actions;
CREATE POLICY "admin_actions_service" ON admin_actions
  FOR ALL TO anon, authenticated USING (true) WITH CHECK (true);

-- sycapay_transactions
DROP POLICY IF EXISTS "sycapay_anon" ON sycapay_transactions;
CREATE POLICY "sycapay_anon" ON sycapay_transactions
  FOR ALL TO anon, authenticated USING (true) WITH CHECK (true);

-- prets_pending
DROP POLICY IF EXISTS "prets_pending_anon" ON prets_pending;
CREATE POLICY "prets_pending_anon" ON prets_pending
  FOR ALL TO anon, authenticated USING (true) WITH CHECK (true);

-- decaissements_pending
DROP POLICY IF EXISTS "decaissements_anon" ON decaissements_pending;
CREATE POLICY "decaissements_anon" ON decaissements_pending
  FOR ALL TO anon, authenticated USING (true) WITH CHECK (true);

-- depenses_pending
DROP POLICY IF EXISTS "depenses_anon" ON depenses_pending;
CREATE POLICY "depenses_anon" ON depenses_pending
  FOR ALL TO anon, authenticated USING (true) WITH CHECK (true);

-- premium_requests
DROP POLICY IF EXISTS "premium_requests_anon" ON premium_requests;
CREATE POLICY "premium_requests_anon" ON premium_requests
  FOR ALL TO anon, authenticated USING (true) WITH CHECK (true);

-- kyc_submissions
DROP POLICY IF EXISTS "kyc_anon" ON public.kyc_submissions;
CREATE POLICY "kyc_anon" ON public.kyc_submissions
  FOR ALL TO anon, authenticated USING (true) WITH CHECK (true);

-- fcm_tokens
DROP POLICY IF EXISTS "fcm_anon" ON public.fcm_tokens;
CREATE POLICY "fcm_anon" ON public.fcm_tokens
  FOR ALL TO anon, authenticated USING (true) WITH CHECK (true);

-- rappels_envoyes
DROP POLICY IF EXISTS "rappels_anon" ON rappels_envoyes;
CREATE POLICY "rappels_anon" ON rappels_envoyes
  FOR ALL TO anon, authenticated USING (true) WITH CHECK (true);

-- admin_membres
DROP POLICY IF EXISTS "admin_membres_service" ON admin_membres;
CREATE POLICY "admin_membres_service" ON admin_membres
  FOR ALL TO anon, authenticated USING (true) WITH CHECK (true);

-- admin_messages
DROP POLICY IF EXISTS "admin_messages_service" ON admin_messages;
CREATE POLICY "admin_messages_service" ON admin_messages
  FOR ALL TO anon, authenticated USING (true) WITH CHECK (true);

-- support_tickets
DROP POLICY IF EXISTS "support_tickets_service" ON support_tickets;
CREATE POLICY "support_tickets_service" ON support_tickets
  FOR ALL TO anon, authenticated USING (true) WITH CHECK (true);

-- support_messages
DROP POLICY IF EXISTS "support_messages_service" ON support_messages;
CREATE POLICY "support_messages_service" ON support_messages
  FOR ALL TO anon, authenticated USING (true) WITH CHECK (true);


-- ============================================================
-- SECTION F : FONCTIONS / RPCs
-- ============================================================
-- Les fonctions sont mises à jour via init_inline.sql (fichier séparé).
-- Raison : PostgreSQL exige que CREATE OR REPLACE FUNCTION conserve
-- les mêmes NOMS de paramètres que la version existante.
-- Les migrations 006-011 ont des signatures complètes avec de nombreux
-- paramètres — init_inline.sql est le fichier canonique.
--
-- PROCÉDURE :
--   Après avoir exécuté ce fichier (upgrade.sql), exécuter :
--   → init_inline.sql  dans le SQL Editor Supabase
--
-- init_inline.sql contient uniquement CREATE OR REPLACE FUNCTION
-- (aucune destruction de données) — il est également safe à rejouer.
-- ============================================================


-- ============================================================
-- VÉRIFICATION POST-EXÉCUTION (copier séparément après Run)
-- ============================================================
--
-- -- Nombre de tables (attendu : 25)
-- SELECT count(*) FROM pg_tables WHERE schemaname = 'public';
--
-- -- Tables sans RLS (attendu : 0 ligne)
-- SELECT tablename FROM pg_tables
-- WHERE schemaname = 'public' AND NOT rowsecurity;
--
-- -- Nombre de politiques RLS (attendu : 32+)
-- SELECT count(*) FROM pg_policies WHERE schemaname = 'public';
--
-- -- Index (attendu : 54+)
-- SELECT count(*) FROM pg_indexes
-- WHERE schemaname = 'public' AND indexname NOT LIKE '%_pkey';
--
-- -- Triggers (attendu : 2)
-- SELECT trigger_name, event_object_table
-- FROM information_schema.triggers
-- WHERE trigger_schema = 'public';
--
-- ============================================================
-- FIN upgrade.sql
-- ============================================================
