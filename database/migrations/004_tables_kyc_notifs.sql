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
