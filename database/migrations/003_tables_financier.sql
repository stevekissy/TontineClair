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
  id               BIGSERIAL PRIMARY KEY,
  type             TEXT        NOT NULL,
  -- 'cotisation','caisse','penalite','remboursement_pret','decaissement'
  code             TEXT        NOT NULL,
  membre_id        TEXT,
  membre_nom       TEXT,
  montant          NUMERIC(14,2) NOT NULL,
  devise           TEXT        NOT NULL DEFAULT 'XOF',
  statut           TEXT        NOT NULL DEFAULT 'pending'
                   CHECK (statut IN ('pending','completed','failed','cancelled')),
  sycapay_ref      TEXT,
  numero_telephone TEXT,
  gestionnaire     TEXT,
  metadata         JSONB       DEFAULT '{}',
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

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
