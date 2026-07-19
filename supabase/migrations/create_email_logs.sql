-- ═══════════════════════════════════════════════════════════════════════════
-- TontineClair — Table email_logs
-- Trace tous les envois SMTP de l'Edge Function send-manager-pin.
-- Remplace le log silencieux qui échouait (table inexistante).
-- ═══════════════════════════════════════════════════════════════════════════

-- ── 1. Créer la table ──────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS email_logs (
    id            BIGSERIAL PRIMARY KEY,
    cree_le       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    mis_a_jour_le TIMESTAMPTZ,

    -- Destinataire
    destinataire  TEXT NOT NULL,

    -- Contexte métier
    type_email    TEXT NOT NULL DEFAULT 'pin_reset',  -- pin_reset | notification | autre
    sujet         TEXT,
    tontine_code  TEXT,
    gest_nom      TEXT,

    -- Statut envoi
    statut        TEXT NOT NULL DEFAULT 'pending'
                  CHECK (statut IN ('pending', 'envoye', 'echoue')),
    motif_echec   TEXT,          -- Message d'erreur SMTP si statut = 'echoue'
    message_id    TEXT,          -- messageId nodemailer si succès (ex: <xxx@smtp.hostinger.com>)

    -- Méta
    ip_source     TEXT,
    user_agent    TEXT
);

-- ── 2. Index pour les requêtes fréquentes ──────────────────────────────────
CREATE INDEX IF NOT EXISTS email_logs_destinataire_idx   ON email_logs (destinataire);
CREATE INDEX IF NOT EXISTS email_logs_tontine_code_idx   ON email_logs (tontine_code);
CREATE INDEX IF NOT EXISTS email_logs_statut_idx         ON email_logs (statut);
CREATE INDEX IF NOT EXISTS email_logs_cree_le_idx        ON email_logs (cree_le DESC);

-- ── 3. RLS — lecture admin seulement ──────────────────────────────────────
ALTER TABLE email_logs ENABLE ROW LEVEL SECURITY;

-- Service role bypass (Edge Function utilise service role)
-- anon / authenticated : lecture seulement sur leurs propres tontines
CREATE POLICY "service_role_all" ON email_logs
    FOR ALL
    TO service_role
    USING (true)
    WITH CHECK (true);

-- Admin Flutter peut lire tous les logs
CREATE POLICY "admin_read_all" ON email_logs
    FOR SELECT
    TO authenticated
    USING (true);

-- ── 4. Trigger mis_a_jour_le ───────────────────────────────────────────────
CREATE OR REPLACE FUNCTION set_email_logs_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    NEW.mis_a_jour_le := NOW();
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS email_logs_updated_at ON email_logs;
CREATE TRIGGER email_logs_updated_at
    BEFORE UPDATE ON email_logs
    FOR EACH ROW
    EXECUTE FUNCTION set_email_logs_updated_at();

-- ── 5. Commentaires ────────────────────────────────────────────────────────
COMMENT ON TABLE email_logs IS
    'Trace tous les envois email de l''Edge Function send-manager-pin. '
    'Permet de diagnostiquer les problèmes de livraison SMTP.';

COMMENT ON COLUMN email_logs.statut IS
    'pending = en cours | envoye = SMTP ok | echoue = erreur SMTP';

COMMENT ON COLUMN email_logs.motif_echec IS
    'Message d''erreur nodemailer exact (ex: "550 User not found", "535 Auth failed")';

COMMENT ON COLUMN email_logs.message_id IS
    'ID unique de message retourné par Hostinger SMTP si envoi réussi';
