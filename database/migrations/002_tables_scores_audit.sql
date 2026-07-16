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
