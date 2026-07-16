-- =============================================================================
-- TontineClair — Migration 001 : Tables fondamentales
-- Ordre d'exécution : 1/10
-- Remplace : (table tontines gérée par Supabase directement)
--            supabase-v6.sql (tables scores/audit)
--            supabase-v16-soft-delete.sql (colonnes status/deleted_at)
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. TABLE tontines (table principale — gérée nativement par Supabase)
--    Si elle n'existe pas encore, la créer ici.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS tontines (
  id         BIGSERIAL PRIMARY KEY,
  code       TEXT        NOT NULL UNIQUE,
  data       JSONB       NOT NULL DEFAULT '{}',
  -- Colonnes ajoutées en v16 (soft-delete)
  status     TEXT        NOT NULL DEFAULT 'active'
             CHECK (status IN ('active','inactive','suspended','deleted')),
  deleted_at TIMESTAMPTZ,
  deleted_by TEXT,
  deletion_reason TEXT,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

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
