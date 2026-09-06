-- ═══════════════════════════════════════════════════════════════════════════════
-- MIGRATION : blockchain_journal
-- Phase 1 — Fondations blockchain TontineClair Web2+Web3
-- Réseau   : Polygon Amoy (testnet) → Polygon Mainnet
-- Token    : USDT (ERC-20 sur Polygon)
-- ═══════════════════════════════════════════════════════════════════════════════

-- ── 1. Table principale ───────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS blockchain_journal (
  id               BIGSERIAL PRIMARY KEY,

  -- Identifiants métier TontineClair
  tontine_code     TEXT        NOT NULL,
  type_operation   TEXT        NOT NULL,  -- 'cotisation'|'distribution'|'pret'|'remboursement'|'vote'|'creation'|'apport'|'penalite'
  membre_id        TEXT,                  -- id du membre concerné (nullable pour création/vote global)
  membre_nom       TEXT,
  montant_xof      BIGINT,               -- montant en XOF (nullable pour vote)
  montant_usdt     NUMERIC(18,6),        -- montant USDT calculé au moment de l'opération
  taux_xof_usdt    NUMERIC(18,6),        -- taux de conversion utilisé

  -- Données blockchain
  reseau           TEXT        NOT NULL DEFAULT 'polygon_amoy',  -- 'polygon_amoy' | 'polygon'
  tx_hash          TEXT,                  -- hash de transaction Polygon (null si pending)
  block_number     BIGINT,               -- numéro de bloc confirmé
  wallet_tontine   TEXT,                 -- adresse wallet de la tontine
  wallet_membre    TEXT,                 -- adresse wallet du membre (si applicable)
  gas_used         BIGINT,
  statut           TEXT        NOT NULL DEFAULT 'pending',
                   -- 'pending'|'submitted'|'confirmed'|'failed'|'skipped'

  -- Signature cryptographique côté serveur (HMAC-SHA256)
  -- Signe : tontine_code + type_operation + montant_xof + membre_id + created_at
  signature        TEXT,
  payload_hash     TEXT,                  -- SHA-256 du payload original

  -- Référence opération source
  ref_interne      TEXT,                  -- numcommande ou ID interne TC
  metadata         JSONB DEFAULT '{}',    -- données complémentaires libres

  -- Horodatage
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  confirmed_at     TIMESTAMPTZ,
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ── 2. Table wallets tontines ─────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS blockchain_wallets (
  tontine_code     TEXT        PRIMARY KEY,
  adresse          TEXT        NOT NULL UNIQUE,   -- adresse Polygon publique
  reseau           TEXT        NOT NULL DEFAULT 'polygon_amoy',
  -- clé privée JAMAIS stockée ici — dans Supabase Vault / Secrets uniquement
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  solde_usdt       NUMERIC(18,6) DEFAULT 0,       -- mis à jour par blockchain-tx
  derniere_sync    TIMESTAMPTZ
);

-- ── 3. Table taux de conversion historique ────────────────────────────────────
CREATE TABLE IF NOT EXISTS blockchain_taux (
  id               BIGSERIAL PRIMARY KEY,
  paire            TEXT        NOT NULL DEFAULT 'XOF/USDT',
  taux             NUMERIC(18,6) NOT NULL,
  source           TEXT        NOT NULL DEFAULT 'direct',
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ── 4. Index pour performances ────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_bj_tontine     ON blockchain_journal (tontine_code);
CREATE INDEX IF NOT EXISTS idx_bj_statut      ON blockchain_journal (statut);
CREATE INDEX IF NOT EXISTS idx_bj_type        ON blockchain_journal (type_operation);
CREATE INDEX IF NOT EXISTS idx_bj_created     ON blockchain_journal (created_at DESC);
CREATE INDEX IF NOT EXISTS idx_bj_tx_hash     ON blockchain_journal (tx_hash) WHERE tx_hash IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_bj_membre      ON blockchain_journal (membre_id) WHERE membre_id IS NOT NULL;

-- ── 5. Trigger updated_at ─────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION update_blockchain_journal_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_bj_updated_at ON blockchain_journal;
CREATE TRIGGER trg_bj_updated_at
  BEFORE UPDATE ON blockchain_journal
  FOR EACH ROW EXECUTE FUNCTION update_blockchain_journal_updated_at();

-- ── 6. RPC admin : lire journal blockchain ───────────────────────────────────
CREATE OR REPLACE FUNCTION admin_blockchain_journal(
  p_cle       TEXT,
  p_limit     INT  DEFAULT 100,
  p_offset    INT  DEFAULT 0,
  p_tontine   TEXT DEFAULT NULL,
  p_statut    TEXT DEFAULT NULL,
  p_type      TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_ok   BOOLEAN;
  v_rows JSONB;
  v_total BIGINT;
BEGIN
  SELECT verifier_cle_admin(p_cle) INTO v_ok;
  IF NOT v_ok THEN
    RETURN jsonb_build_object('erreur', true, 'message', 'Clé admin invalide');
  END IF;

  SELECT COUNT(*) INTO v_total
  FROM blockchain_journal
  WHERE (p_tontine IS NULL OR tontine_code = p_tontine)
    AND (p_statut  IS NULL OR statut = p_statut)
    AND (p_type    IS NULL OR type_operation = p_type);

  SELECT jsonb_agg(row_to_json(t.*) ORDER BY t.created_at DESC) INTO v_rows
  FROM (
    SELECT * FROM blockchain_journal
    WHERE (p_tontine IS NULL OR tontine_code = p_tontine)
      AND (p_statut  IS NULL OR statut = p_statut)
      AND (p_type    IS NULL OR type_operation = p_type)
    ORDER BY created_at DESC
    LIMIT p_limit OFFSET p_offset
  ) t;

  RETURN jsonb_build_object(
    'ok',     true,
    'total',  v_total,
    'rows',   COALESCE(v_rows, '[]'::jsonb)
  );
END;
$$;

-- ── 7. RPC admin : stats blockchain ──────────────────────────────────────────
CREATE OR REPLACE FUNCTION admin_blockchain_stats(p_cle TEXT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_ok BOOLEAN;
BEGIN
  SELECT verifier_cle_admin(p_cle) INTO v_ok;
  IF NOT v_ok THEN
    RETURN jsonb_build_object('erreur', true, 'message', 'Clé admin invalide');
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'total_operations',  (SELECT COUNT(*)   FROM blockchain_journal),
    'confirmed',         (SELECT COUNT(*)   FROM blockchain_journal WHERE statut = 'confirmed'),
    'pending',           (SELECT COUNT(*)   FROM blockchain_journal WHERE statut IN ('pending','submitted')),
    'failed',            (SELECT COUNT(*)   FROM blockchain_journal WHERE statut = 'failed'),
    'total_usdt',        (SELECT COALESCE(SUM(montant_usdt), 0) FROM blockchain_journal WHERE statut = 'confirmed'),
    'total_xof',         (SELECT COALESCE(SUM(montant_xof),  0) FROM blockchain_journal WHERE statut = 'confirmed'),
    'tontines_actives',  (SELECT COUNT(DISTINCT tontine_code) FROM blockchain_journal),
    'wallets_crees',     (SELECT COUNT(*) FROM blockchain_wallets),
    'reseau',            'polygon_amoy'
  );
END;
$$;

-- ── 8. Row Level Security ─────────────────────────────────────────────────────
ALTER TABLE blockchain_journal  ENABLE ROW LEVEL SECURITY;
ALTER TABLE blockchain_wallets  ENABLE ROW LEVEL SECURITY;
ALTER TABLE blockchain_taux     ENABLE ROW LEVEL SECURITY;

-- Lecture publique (anon) interdite — accès uniquement via service_role (Edge Functions)
CREATE POLICY "service_role_only_journal"
  ON blockchain_journal FOR ALL
  TO service_role USING (true);

CREATE POLICY "service_role_only_wallets"
  ON blockchain_wallets FOR ALL
  TO service_role USING (true);

CREATE POLICY "service_role_only_taux"
  ON blockchain_taux FOR ALL
  TO service_role USING (true);

-- ── 9. Commentaires documentation ────────────────────────────────────────────
COMMENT ON TABLE blockchain_journal IS
  'Journal immuable de toutes les opérations financières TontineClair ancrées sur Polygon.
   Phase 1 : réseau Polygon Amoy (testnet). Phase 4 : migration Polygon Mainnet.
   Chaque ligne correspond à une opération (cotisation, distribution, prêt, vote, etc.)
   avec son hash de transaction blockchain et sa signature cryptographique serveur.';

COMMENT ON TABLE blockchain_wallets IS
  'Wallets Polygon dédiés par tontine. Clés privées JAMAIS stockées ici.
   Gérées exclusivement dans Supabase Vault via Edge Function blockchain-tx.';
