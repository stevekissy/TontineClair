-- ═══════════════════════════════════════════════════════════════════════════════
-- proposer_retrait  v2
-- Crée une proposition de retrait + insère le vote dans tontines.data['votes']
-- ET dans la table propositions_retrait (si elle existe).
--
-- IMPORTANT : Cette fonction ne modifie PAS tontines.data directement.
-- Le vote est inséré dans data par ecrire_tontine (côté Flutter) AVANT cet appel.
-- Cette RPC ne sert qu'à insérer dans propositions_retrait (table dédiée v6).
-- Elle ne doit JAMAIS écraser tontines.data.
-- ═══════════════════════════════════════════════════════════════════════════════

-- Créer la table propositions_retrait si elle n'existe pas
CREATE TABLE IF NOT EXISTS propositions_retrait (
  id              TEXT PRIMARY KEY DEFAULT gen_random_uuid()::TEXT,
  code            TEXT NOT NULL,
  membre_id       TEXT NOT NULL,
  membre_nom      TEXT NOT NULL,
  score           INT  NOT NULL DEFAULT 0,
  motif           TEXT NOT NULL,
  vote_id         TEXT NOT NULL,
  quorum          INT  NOT NULL DEFAULT 60,
  majorite        INT  NOT NULL DEFAULT 51,
  statut          TEXT NOT NULL DEFAULT 'en_cours', -- 'en_cours' | 'accepte' | 'refuse'
  gestionnaire    TEXT NOT NULL,
  cree_le         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  mis_a_jour_le   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Index pour requêtes par code
CREATE INDEX IF NOT EXISTS idx_propositions_retrait_code ON propositions_retrait(code);

-- RPC proposer_retrait : insère UNIQUEMENT dans propositions_retrait
-- Ne touche PAS à tontines.data (déjà mis à jour par ecrire_tontine côté Flutter)
CREATE OR REPLACE FUNCTION proposer_retrait(
  p_code       TEXT,
  p_nom        TEXT,
  p_pin        TEXT,
  p_membre_id  TEXT,
  p_membre_nom TEXT,
  p_score      INT,
  p_motif      TEXT,
  p_vote_id    TEXT,
  p_quorum     INT DEFAULT 60,
  p_majorite   INT DEFAULT 51
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_code TEXT := UPPER(TRIM(p_code));
  v_gest_valide BOOLEAN;
BEGIN
  -- Vérifier le PIN gestionnaire
  SELECT EXISTS(
    SELECT 1 FROM tontines t
    WHERE t.code = v_code
      AND t.data->'gestionnaires' @> jsonb_build_array(
        jsonb_build_object('nom', p_nom, 'pin', p_pin)
      )
  ) INTO v_gest_valide;

  IF NOT v_gest_valide THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'PIN gestionnaire incorrect');
  END IF;

  -- Insérer dans la table dédiée (upsert sur vote_id)
  INSERT INTO propositions_retrait (
    code, membre_id, membre_nom, score, motif,
    vote_id, quorum, majorite, gestionnaire
  )
  VALUES (
    v_code, p_membre_id, p_membre_nom, p_score, p_motif,
    p_vote_id, p_quorum, p_majorite, p_nom
  )
  ON CONFLICT (id) DO NOTHING;

  RETURN jsonb_build_object('ok', true, 'vote_id', p_vote_id);
END;
$$;

-- RPC maj_statut_retrait : met à jour le statut après clôture du vote
CREATE OR REPLACE FUNCTION maj_statut_retrait(
  p_code     TEXT,
  p_vote_id  TEXT,
  p_statut   TEXT  -- 'accepte' | 'refuse'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  UPDATE propositions_retrait
  SET statut = p_statut,
      mis_a_jour_le = NOW()
  WHERE code = UPPER(TRIM(p_code))
    AND vote_id = p_vote_id;

  RETURN jsonb_build_object('ok', true);
END;
$$;

-- Permissions
GRANT EXECUTE ON FUNCTION proposer_retrait TO anon, authenticated;
GRANT EXECUTE ON FUNCTION maj_statut_retrait TO anon, authenticated;
GRANT ALL ON TABLE propositions_retrait TO anon, authenticated;
