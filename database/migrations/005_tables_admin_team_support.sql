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
