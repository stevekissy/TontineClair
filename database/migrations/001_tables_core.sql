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
