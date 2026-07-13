-- ─────────────────────────────────────────────────────────────────────────────
-- Table anti-spam pour les rappels d'échéances
-- À exécuter dans Supabase › SQL Editor AVANT de déployer verifier_echeances
-- ─────────────────────────────────────────────────────────────────────────────

-- Table de suivi : une entrée par (tontine, jour) = 1 seul rappel push/jour
CREATE TABLE IF NOT EXISTS rappels_envoyes (
  code TEXT    NOT NULL,
  date DATE    NOT NULL DEFAULT CURRENT_DATE,
  PRIMARY KEY (code, date)
);

-- RLS activé : seul le service_role (Edge Functions) peut lire/écrire
ALTER TABLE rappels_envoyes ENABLE ROW LEVEL SECURITY;

-- Politique : accès complet pour service_role uniquement
-- (Les Edge Functions utilisent SUPABASE_SERVICE_ROLE_KEY → accès garanti)
CREATE POLICY "service_role_only" ON rappels_envoyes
  USING (auth.role() = 'service_role')
  WITH CHECK (auth.role() = 'service_role');

-- Index pour nettoyage des vieilles entrées
CREATE INDEX IF NOT EXISTS idx_rappels_envoyes_date ON rappels_envoyes(date);

-- ─── Nettoyage automatique des anciennes entrées (optionnel) ─────────────────
-- Exécuter périodiquement ou via un cron Supabase :
--
--   DELETE FROM rappels_envoyes WHERE date < CURRENT_DATE - INTERVAL '30 days';
--
-- ─────────────────────────────────────────────────────────────────────────────
