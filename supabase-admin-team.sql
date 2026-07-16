-- =============================================================================
-- TONTINECLAIR — Admin Team, Messagerie interne & Support client
-- À exécuter dans Supabase SQL Editor
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. TABLE admin_membres
--    Membres de l'équipe admin avec leur rôle
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS admin_membres (
  id          BIGSERIAL PRIMARY KEY,
  nom         TEXT        NOT NULL,
  pseudo      TEXT        NOT NULL UNIQUE,          -- identifiant de connexion
  cle_hash    TEXT        NOT NULL,                 -- hash SHA-256 de la clé personnelle
  role        TEXT        NOT NULL DEFAULT 'comptable'
              CHECK (role IN ('super_admin','comptable','conformite')),
  actif       BOOLEAN     NOT NULL DEFAULT TRUE,
  cree_par    TEXT        NOT NULL,                 -- pseudo du super_admin créateur
  cree_le     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  derniere_connexion TIMESTAMPTZ
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_admin_membres_pseudo ON admin_membres(pseudo);
CREATE INDEX        IF NOT EXISTS idx_admin_membres_role   ON admin_membres(role);

-- RLS
ALTER TABLE admin_membres ENABLE ROW LEVEL SECURITY;
CREATE POLICY "admin_membres_service_role" ON admin_membres
  USING (TRUE) WITH CHECK (TRUE);

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. TABLE admin_messages  (messagerie interne admin)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS admin_messages (
  id          BIGSERIAL PRIMARY KEY,
  expediteur  TEXT        NOT NULL,                 -- pseudo expéditeur
  destinataire TEXT       NOT NULL,                 -- pseudo destinataire ou 'tous'
  sujet       TEXT        NOT NULL DEFAULT '',
  corps       TEXT        NOT NULL,
  lu          BOOLEAN     NOT NULL DEFAULT FALSE,
  lu_le       TIMESTAMPTZ,
  envoye_le   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_admin_messages_destinataire ON admin_messages(destinataire);
CREATE INDEX IF NOT EXISTS idx_admin_messages_expediteur   ON admin_messages(expediteur);
CREATE INDEX IF NOT EXISTS idx_admin_messages_envoye_le    ON admin_messages(envoye_le DESC);

ALTER TABLE admin_messages ENABLE ROW LEVEL SECURITY;
CREATE POLICY "admin_messages_service_role" ON admin_messages
  USING (TRUE) WITH CHECK (TRUE);

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. TABLE support_tickets  (tickets support client)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS support_tickets (
  id          BIGSERIAL PRIMARY KEY,
  ref         TEXT        NOT NULL UNIQUE,          -- ex: TC-2024-0001
  gestionnaire TEXT       NOT NULL,                 -- nom/pseudo du client
  code_tontine TEXT,                                -- tontine concernée (optionnel)
  categorie   TEXT        NOT NULL DEFAULT 'autre'
              CHECK (categorie IN ('paiement','kyc','tontine','technique','autre')),
  sujet       TEXT        NOT NULL,
  description TEXT        NOT NULL,
  statut      TEXT        NOT NULL DEFAULT 'ouvert'
              CHECK (statut IN ('ouvert','en_cours','resolu','ferme')),
  priorite    TEXT        NOT NULL DEFAULT 'normale'
              CHECK (priorite IN ('basse','normale','haute','urgente')),
  assigne_a   TEXT,                                 -- pseudo admin assigné
  cree_le     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  mis_a_jour  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  resolu_le   TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_support_tickets_statut      ON support_tickets(statut);
CREATE INDEX IF NOT EXISTS idx_support_tickets_gestionnaire ON support_tickets(gestionnaire);
CREATE INDEX IF NOT EXISTS idx_support_tickets_ref         ON support_tickets(ref);
CREATE INDEX IF NOT EXISTS idx_support_tickets_cree_le     ON support_tickets(cree_le DESC);

ALTER TABLE support_tickets ENABLE ROW LEVEL SECURITY;
CREATE POLICY "support_tickets_service_role" ON support_tickets
  USING (TRUE) WITH CHECK (TRUE);

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. TABLE support_messages  (conversation par ticket)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS support_messages (
  id          BIGSERIAL PRIMARY KEY,
  ticket_id   BIGINT      NOT NULL REFERENCES support_tickets(id) ON DELETE CASCADE,
  auteur      TEXT        NOT NULL,                 -- pseudo ou gestionnaire
  est_admin   BOOLEAN     NOT NULL DEFAULT FALSE,   -- TRUE = réponse admin
  corps       TEXT        NOT NULL,
  lu_client   BOOLEAN     NOT NULL DEFAULT FALSE,   -- lu par le client
  lu_admin    BOOLEAN     NOT NULL DEFAULT FALSE,   -- lu par l'admin
  envoye_le   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_support_messages_ticket_id  ON support_messages(ticket_id);
CREATE INDEX IF NOT EXISTS idx_support_messages_envoye_le  ON support_messages(envoye_le ASC);

ALTER TABLE support_messages ENABLE ROW LEVEL SECURITY;
CREATE POLICY "support_messages_service_role" ON support_messages
  USING (TRUE) WITH CHECK (TRUE);

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. FONCTION: séquence de référence ticket (TC-YYYY-NNNN)
-- ─────────────────────────────────────────────────────────────────────────────
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

-- =============================================================================
-- RPCs — Admin Membres
-- =============================================================================

-- Lister tous les membres admin (super_admin seulement)
CREATE OR REPLACE FUNCTION admin_lister_membres(p_cle TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_cle TEXT;
BEGIN
  SELECT valeur INTO v_cle FROM app_config WHERE cle = 'admin_key';
  IF v_cle IS NULL OR p_cle != v_cle THEN
    RAISE EXCEPTION 'Clé admin invalide';
  END IF;

  RETURN (
    SELECT JSONB_AGG(
      JSONB_BUILD_OBJECT(
        'id',         m.id,
        'nom',        m.nom,
        'pseudo',     m.pseudo,
        'role',       m.role,
        'actif',      m.actif,
        'cree_par',   m.cree_par,
        'cree_le',    m.cree_le,
        'derniere_connexion', m.derniere_connexion
      ) ORDER BY m.cree_le ASC
    )
    FROM admin_membres m
  );
END;
$$;

-- Créer un membre admin
CREATE OR REPLACE FUNCTION admin_creer_membre(
  p_cle       TEXT,
  p_nom       TEXT,
  p_pseudo    TEXT,
  p_cle_perso TEXT,    -- clé personnelle en clair (sera hashée côté SQL)
  p_role      TEXT,
  p_cree_par  TEXT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_cle       TEXT;
  v_hash      TEXT;
  v_nouveau   admin_membres;
BEGIN
  SELECT valeur INTO v_cle FROM app_config WHERE cle = 'admin_key';
  IF v_cle IS NULL OR p_cle != v_cle THEN
    RAISE EXCEPTION 'Clé admin invalide';
  END IF;

  IF p_role NOT IN ('super_admin','comptable','conformite') THEN
    RAISE EXCEPTION 'Rôle invalide: %', p_role;
  END IF;

  -- Hash SHA-256 de la clé personnelle
  v_hash := ENCODE(SHA256(p_cle_perso::BYTEA), 'hex');

  INSERT INTO admin_membres (nom, pseudo, cle_hash, role, actif, cree_par)
  VALUES (p_nom, p_pseudo, v_hash, p_role, TRUE, p_cree_par)
  RETURNING * INTO v_nouveau;

  RETURN JSONB_BUILD_OBJECT(
    'id',     v_nouveau.id,
    'pseudo', v_nouveau.pseudo,
    'role',   v_nouveau.role,
    'actif',  v_nouveau.actif
  );
END;
$$;

-- Modifier rôle / statut actif d'un membre
CREATE OR REPLACE FUNCTION admin_modifier_membre(
  p_cle     TEXT,
  p_id      BIGINT,
  p_role    TEXT     DEFAULT NULL,
  p_actif   BOOLEAN  DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_cle TEXT;
BEGIN
  SELECT valeur INTO v_cle FROM app_config WHERE cle = 'admin_key';
  IF v_cle IS NULL OR p_cle != v_cle THEN
    RAISE EXCEPTION 'Clé admin invalide';
  END IF;

  UPDATE admin_membres
  SET
    role  = COALESCE(p_role,  role),
    actif = COALESCE(p_actif, actif)
  WHERE id = p_id;

  RETURN JSONB_BUILD_OBJECT('ok', TRUE, 'id', p_id);
END;
$$;

-- Authentifier un membre admin par pseudo + clé perso
CREATE OR REPLACE FUNCTION admin_auth_membre(
  p_pseudo    TEXT,
  p_cle_perso TEXT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_membre admin_membres%ROWTYPE;
  v_hash   TEXT;
BEGIN
  v_hash := ENCODE(SHA256(p_cle_perso::BYTEA), 'hex');

  SELECT * INTO v_membre
  FROM admin_membres
  WHERE pseudo = p_pseudo AND cle_hash = v_hash AND actif = TRUE;

  IF NOT FOUND THEN
    RETURN JSONB_BUILD_OBJECT('ok', FALSE, 'erreur', 'Identifiants incorrects');
  END IF;

  -- Mettre à jour dernière connexion
  UPDATE admin_membres SET derniere_connexion = NOW() WHERE id = v_membre.id;

  RETURN JSONB_BUILD_OBJECT(
    'ok',    TRUE,
    'id',    v_membre.id,
    'nom',   v_membre.nom,
    'pseudo',v_membre.pseudo,
    'role',  v_membre.role
  );
END;
$$;

-- =============================================================================
-- RPCs — Messagerie interne admin
-- =============================================================================

-- Lister messages reçus pour un membre
CREATE OR REPLACE FUNCTION admin_lister_messages(
  p_pseudo    TEXT,
  p_cle_perso TEXT,
  p_boite     TEXT DEFAULT 'recus'   -- 'recus' | 'envoyes' | 'tous'
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_hash TEXT;
  v_ok   BOOLEAN;
BEGIN
  v_hash := ENCODE(SHA256(p_cle_perso::BYTEA), 'hex');
  SELECT EXISTS(SELECT 1 FROM admin_membres WHERE pseudo = p_pseudo AND cle_hash = v_hash AND actif) INTO v_ok;
  IF NOT v_ok THEN RAISE EXCEPTION 'Authentification requise'; END IF;

  RETURN (
    SELECT JSONB_AGG(
      JSONB_BUILD_OBJECT(
        'id',          m.id,
        'expediteur',  m.expediteur,
        'destinataire',m.destinataire,
        'sujet',       m.sujet,
        'corps',       m.corps,
        'lu',          m.lu,
        'lu_le',       m.lu_le,
        'envoye_le',   m.envoye_le
      ) ORDER BY m.envoye_le DESC
    )
    FROM admin_messages m
    WHERE
      CASE p_boite
        WHEN 'recus'   THEN m.destinataire IN (p_pseudo, 'tous')
        WHEN 'envoyes' THEN m.expediteur = p_pseudo
        ELSE                m.destinataire IN (p_pseudo, 'tous') OR m.expediteur = p_pseudo
      END
  );
END;
$$;

-- Envoyer un message interne
CREATE OR REPLACE FUNCTION admin_envoyer_message(
  p_pseudo      TEXT,
  p_cle_perso   TEXT,
  p_destinataire TEXT,
  p_sujet       TEXT,
  p_corps       TEXT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_hash TEXT;
  v_ok   BOOLEAN;
  v_id   BIGINT;
BEGIN
  v_hash := ENCODE(SHA256(p_cle_perso::BYTEA), 'hex');
  SELECT EXISTS(SELECT 1 FROM admin_membres WHERE pseudo = p_pseudo AND cle_hash = v_hash AND actif) INTO v_ok;
  IF NOT v_ok THEN RAISE EXCEPTION 'Authentification requise'; END IF;

  INSERT INTO admin_messages (expediteur, destinataire, sujet, corps)
  VALUES (p_pseudo, p_destinataire, p_sujet, p_corps)
  RETURNING id INTO v_id;

  RETURN JSONB_BUILD_OBJECT('ok', TRUE, 'id', v_id);
END;
$$;

-- Marquer un message comme lu
CREATE OR REPLACE FUNCTION admin_marquer_lu(
  p_pseudo    TEXT,
  p_cle_perso TEXT,
  p_message_id BIGINT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_hash TEXT;
  v_ok   BOOLEAN;
BEGIN
  v_hash := ENCODE(SHA256(p_cle_perso::BYTEA), 'hex');
  SELECT EXISTS(SELECT 1 FROM admin_membres WHERE pseudo = p_pseudo AND cle_hash = v_hash AND actif) INTO v_ok;
  IF NOT v_ok THEN RAISE EXCEPTION 'Authentification requise'; END IF;

  UPDATE admin_messages SET lu = TRUE, lu_le = NOW()
  WHERE id = p_message_id AND destinataire IN (p_pseudo, 'tous');

  RETURN JSONB_BUILD_OBJECT('ok', TRUE);
END;
$$;

-- Compter messages non lus pour un membre
CREATE OR REPLACE FUNCTION admin_compter_non_lus(
  p_pseudo    TEXT,
  p_cle_perso TEXT
) RETURNS BIGINT LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_hash  TEXT;
  v_ok    BOOLEAN;
  v_count BIGINT;
BEGIN
  v_hash := ENCODE(SHA256(p_cle_perso::BYTEA), 'hex');
  SELECT EXISTS(SELECT 1 FROM admin_membres WHERE pseudo = p_pseudo AND cle_hash = v_hash AND actif) INTO v_ok;
  IF NOT v_ok THEN RETURN 0; END IF;

  SELECT COUNT(*) INTO v_count
  FROM admin_messages
  WHERE destinataire IN (p_pseudo, 'tous') AND lu = FALSE AND expediteur != p_pseudo;

  RETURN v_count;
END;
$$;

-- =============================================================================
-- RPCs — Support client
-- =============================================================================

-- Ouvrir un ticket support (client)
CREATE OR REPLACE FUNCTION support_ouvrir_ticket(
  p_gestionnaire TEXT,
  p_code_tontine TEXT,
  p_categorie    TEXT,
  p_sujet        TEXT,
  p_description  TEXT,
  p_priorite     TEXT DEFAULT 'normale'
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_ref TEXT;
  v_id  BIGINT;
BEGIN
  v_ref := generer_ref_ticket();

  INSERT INTO support_tickets (ref, gestionnaire, code_tontine, categorie, sujet, description, priorite)
  VALUES (v_ref, p_gestionnaire, p_code_tontine, p_categorie, p_sujet, p_description, p_priorite)
  RETURNING id INTO v_id;

  -- Premier message automatique = description du client
  INSERT INTO support_messages (ticket_id, auteur, est_admin, corps, lu_admin)
  VALUES (v_id, p_gestionnaire, FALSE, p_description, FALSE);

  RETURN JSONB_BUILD_OBJECT('ok', TRUE, 'id', v_id, 'ref', v_ref);
END;
$$;

-- Lister tickets d'un client (par gestionnaire)
CREATE OR REPLACE FUNCTION support_mes_tickets(p_gestionnaire TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  RETURN (
    SELECT JSONB_AGG(
      JSONB_BUILD_OBJECT(
        'id',          t.id,
        'ref',         t.ref,
        'categorie',   t.categorie,
        'sujet',       t.sujet,
        'statut',      t.statut,
        'priorite',    t.priorite,
        'assigne_a',   t.assigne_a,
        'cree_le',     t.cree_le,
        'mis_a_jour',  t.mis_a_jour,
        'nb_non_lus',  (SELECT COUNT(*) FROM support_messages sm
                        WHERE sm.ticket_id = t.id AND sm.est_admin = TRUE AND sm.lu_client = FALSE)
      ) ORDER BY t.cree_le DESC
    )
    FROM support_tickets t
    WHERE t.gestionnaire = p_gestionnaire
  );
END;
$$;

-- Lister tous les tickets (admin)
CREATE OR REPLACE FUNCTION admin_lister_tickets(
  p_cle    TEXT,
  p_statut TEXT DEFAULT 'tous'
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_cle TEXT;
BEGIN
  SELECT valeur INTO v_cle FROM app_config WHERE cle = 'admin_key';
  IF v_cle IS NULL OR p_cle != v_cle THEN
    RAISE EXCEPTION 'Clé admin invalide';
  END IF;

  RETURN (
    SELECT JSONB_AGG(
      JSONB_BUILD_OBJECT(
        'id',          t.id,
        'ref',         t.ref,
        'gestionnaire',t.gestionnaire,
        'code_tontine',t.code_tontine,
        'categorie',   t.categorie,
        'sujet',       t.sujet,
        'statut',      t.statut,
        'priorite',    t.priorite,
        'assigne_a',   t.assigne_a,
        'cree_le',     t.cree_le,
        'mis_a_jour',  t.mis_a_jour,
        'nb_non_lus',  (SELECT COUNT(*) FROM support_messages sm
                        WHERE sm.ticket_id = t.id AND sm.est_admin = FALSE AND sm.lu_admin = FALSE)
      ) ORDER BY
        CASE t.priorite WHEN 'urgente' THEN 1 WHEN 'haute' THEN 2 WHEN 'normale' THEN 3 ELSE 4 END,
        t.mis_a_jour DESC
    )
    FROM support_tickets t
    WHERE p_statut = 'tous' OR t.statut = p_statut
  );
END;
$$;

-- Lister messages d'un ticket (client ou admin)
CREATE OR REPLACE FUNCTION support_messages_ticket(
  p_ticket_id    BIGINT,
  p_est_admin    BOOLEAN DEFAULT FALSE,
  p_cle_ou_gest  TEXT    DEFAULT ''      -- clé admin si admin, gestionnaire si client
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_cle TEXT;
  v_ok  BOOLEAN := FALSE;
BEGIN
  IF p_est_admin THEN
    SELECT valeur INTO v_cle FROM app_config WHERE cle = 'admin_key';
    v_ok := (v_cle IS NOT NULL AND p_cle_ou_gest = v_cle);
    -- Marquer messages client comme lus par admin
    IF v_ok THEN
      UPDATE support_messages SET lu_admin = TRUE
      WHERE ticket_id = p_ticket_id AND est_admin = FALSE AND lu_admin = FALSE;
    END IF;
  ELSE
    SELECT EXISTS(SELECT 1 FROM support_tickets WHERE id = p_ticket_id AND gestionnaire = p_cle_ou_gest)
    INTO v_ok;
    -- Marquer messages admin comme lus par client
    IF v_ok THEN
      UPDATE support_messages SET lu_client = TRUE
      WHERE ticket_id = p_ticket_id AND est_admin = TRUE AND lu_client = FALSE;
    END IF;
  END IF;

  IF NOT v_ok THEN RAISE EXCEPTION 'Accès refusé'; END IF;

  RETURN (
    SELECT JSONB_AGG(
      JSONB_BUILD_OBJECT(
        'id',        sm.id,
        'auteur',    sm.auteur,
        'est_admin', sm.est_admin,
        'corps',     sm.corps,
        'envoye_le', sm.envoye_le
      ) ORDER BY sm.envoye_le ASC
    )
    FROM support_messages sm
    WHERE sm.ticket_id = p_ticket_id
  );
END;
$$;

-- Répondre à un ticket (client ou admin)
CREATE OR REPLACE FUNCTION support_repondre(
  p_ticket_id   BIGINT,
  p_auteur      TEXT,
  p_corps       TEXT,
  p_est_admin   BOOLEAN DEFAULT FALSE,
  p_cle_ou_gest TEXT    DEFAULT ''
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_cle TEXT;
  v_ok  BOOLEAN := FALSE;
  v_id  BIGINT;
BEGIN
  IF p_est_admin THEN
    SELECT valeur INTO v_cle FROM app_config WHERE cle = 'admin_key';
    v_ok := (v_cle IS NOT NULL AND p_cle_ou_gest = v_cle);
  ELSE
    SELECT EXISTS(SELECT 1 FROM support_tickets WHERE id = p_ticket_id AND gestionnaire = p_cle_ou_gest)
    INTO v_ok;
  END IF;

  IF NOT v_ok THEN RAISE EXCEPTION 'Accès refusé'; END IF;

  INSERT INTO support_messages (ticket_id, auteur, est_admin, corps)
  VALUES (p_ticket_id, p_auteur, p_est_admin, p_corps)
  RETURNING id INTO v_id;

  -- Mettre à jour mis_a_jour + statut si admin répond (passe en 'en_cours')
  UPDATE support_tickets
  SET mis_a_jour = NOW(),
      statut = CASE
        WHEN p_est_admin AND statut = 'ouvert' THEN 'en_cours'
        ELSE statut
      END
  WHERE id = p_ticket_id;

  RETURN JSONB_BUILD_OBJECT('ok', TRUE, 'id', v_id);
END;
$$;

-- Changer statut ticket (admin)
CREATE OR REPLACE FUNCTION admin_changer_statut_ticket(
  p_cle       TEXT,
  p_ticket_id BIGINT,
  p_statut    TEXT,
  p_assigne_a TEXT DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_cle TEXT;
BEGIN
  SELECT valeur INTO v_cle FROM app_config WHERE cle = 'admin_key';
  IF v_cle IS NULL OR p_cle != v_cle THEN
    RAISE EXCEPTION 'Clé admin invalide';
  END IF;

  UPDATE support_tickets
  SET
    statut     = p_statut,
    assigne_a  = COALESCE(p_assigne_a, assigne_a),
    mis_a_jour = NOW(),
    resolu_le  = CASE WHEN p_statut IN ('resolu','ferme') THEN NOW() ELSE resolu_le END
  WHERE id = p_ticket_id;

  RETURN JSONB_BUILD_OBJECT('ok', TRUE);
END;
$$;
