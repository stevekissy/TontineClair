-- ============================================================================
-- TontineClair — KYC (Know Your Customer) — Vérification identité gestionnaire
-- Version : 1.0 — À exécuter dans Supabase SQL Editor
-- ============================================================================
-- Fonctionnement :
--   1. Règle KYC : réservé EXCLUSIVEMENT aux tontines Premium
--      • cagnotte < 200 000 XOF  → KYC optionnel (peut ignorer)
--      • cagnotte ≥ 200 000 XOF  → KYC OBLIGATOIRE et BLOQUANT
--      • cagnotte = montant × nbMembresActifs
--   2. Deux points d'entrée pour la soumission KYC (côté Flutter) :
--      a) upgrade_premium_screen.dart  → avant achat Google Play
--      b) nouveau_cycle_screen.dart    → avant démarrage cycle (si seuil franchi)
--   3. Le gestionnaire soumet : nom + type de pièce + numéro de pièce
--      → statut = 'pending' dans kyc_submissions
--      → data.kyc.statut = 'pending' dans tontines (JSONB)
--   4. L'admin voit la demande dans son espace (onglet 🪪 KYC)
--   5. Validation → RPC admin_valider_kyc :
--        • Met data.kyc.statut = 'valide' dans tontines (JSONB)
--        • Met statut = 'valide' + validated_at + valide_par dans kyc_submissions
--   6. Rejet → RPC admin_rejeter_kyc :
--        • Met data.kyc.statut = 'rejete' + motif dans tontines (JSONB)
--        • Met statut = 'rejete' + motif_rejet dans kyc_submissions
--   7. Notification Flutter envoyée dans les deux cas
-- ============================================================================
-- Structure JSON dans tontines.data :
--   "kyc": {
--     "statut":       "pending" | "valide" | "rejete" | null,
--     "nom":          "Jean Dupont",
--     "pieceType":    "cni" | "passeport" | "sejour",
--     "pieceNumero":  "A123456789",
--     "soumisLe":     "2025-01-15T10:30:00Z",
--     "motifRejet":   "Document illisible"   (null si non rejeté)
--   }
-- ============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. TABLE kyc_submissions
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.kyc_submissions (
  id              BIGSERIAL PRIMARY KEY,
  code            TEXT        NOT NULL,                      -- code tontine
  gestionnaire    TEXT        NOT NULL DEFAULT '',           -- nom du gestionnaire
  nom             TEXT        NOT NULL,                      -- nom complet déclaré
  piece_type      TEXT        NOT NULL CHECK (
                    piece_type IN ('cni', 'passeport', 'sejour')
                  ),                                         -- type de pièce d'identité
  piece_numero    TEXT        NOT NULL,                      -- numéro de la pièce
  soumis_le       TIMESTAMPTZ NOT NULL DEFAULT NOW(),        -- date de soumission
  statut          TEXT        NOT NULL DEFAULT 'pending' CHECK (
                    statut IN ('pending', 'valide', 'rejete')
                  ),
  motif_rejet     TEXT,                                      -- raison du rejet (nullable)
  valide_par      TEXT,                                      -- identifiant de l'admin validateur
  validated_at    TIMESTAMPTZ,                               -- date de validation/rejet
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Index pour les requêtes courantes
CREATE INDEX IF NOT EXISTS kyc_submissions_code_idx    ON public.kyc_submissions (code);
CREATE INDEX IF NOT EXISTS kyc_submissions_statut_idx  ON public.kyc_submissions (statut);
CREATE INDEX IF NOT EXISTS kyc_submissions_created_idx ON public.kyc_submissions (created_at DESC);

-- RLS : accès public (sécurité par clé admin côté RPC)
ALTER TABLE public.kyc_submissions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "kyc_submissions_select" ON public.kyc_submissions;
CREATE POLICY "kyc_submissions_select"
  ON public.kyc_submissions FOR SELECT USING (true);

DROP POLICY IF EXISTS "kyc_submissions_insert" ON public.kyc_submissions;
CREATE POLICY "kyc_submissions_insert"
  ON public.kyc_submissions FOR INSERT WITH CHECK (true);

DROP POLICY IF EXISTS "kyc_submissions_update" ON public.kyc_submissions;
CREATE POLICY "kyc_submissions_update"
  ON public.kyc_submissions FOR UPDATE USING (true);


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. RPC admin_lister_kyc
--    Retourne la liste des soumissions KYC filtrées par statut
--    p_statut = 'pending' | 'valide' | 'rejete' | 'tous'
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_lister_kyc(
  p_cle    TEXT,
  p_statut TEXT DEFAULT 'tous'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_attendue TEXT;
  v_liste    JSONB;
BEGIN
  -- Vérification clé admin
  SELECT value INTO v_attendue
  FROM   public.app_config
  WHERE  key = 'admin_key'
  LIMIT  1;

  IF v_attendue IS NULL OR p_cle <> v_attendue THEN
    RAISE EXCEPTION 'Clé admin invalide';
  END IF;

  -- Construction de la liste selon le filtre
  IF p_statut = 'tous' THEN
    SELECT COALESCE(jsonb_agg(
      jsonb_build_object(
        'id',           k.id,
        'code',         k.code,
        'gestionnaire', k.gestionnaire,
        'nom',          k.nom,
        'piece_type',   k.piece_type,
        'piece_numero', k.piece_numero,
        'soumis_le',    k.soumis_le,
        'statut',       k.statut,
        'motif_rejet',  k.motif_rejet,
        'valide_par',   k.valide_par,
        'validated_at', k.validated_at,
        'created_at',   k.created_at
      ) ORDER BY k.created_at DESC
    ), '[]'::jsonb)
    INTO v_liste
    FROM public.kyc_submissions k;
  ELSE
    SELECT COALESCE(jsonb_agg(
      jsonb_build_object(
        'id',           k.id,
        'code',         k.code,
        'gestionnaire', k.gestionnaire,
        'nom',          k.nom,
        'piece_type',   k.piece_type,
        'piece_numero', k.piece_numero,
        'soumis_le',    k.soumis_le,
        'statut',       k.statut,
        'motif_rejet',  k.motif_rejet,
        'valide_par',   k.valide_par,
        'validated_at', k.validated_at,
        'created_at',   k.created_at
      ) ORDER BY k.created_at DESC
    ), '[]'::jsonb)
    INTO v_liste
    FROM public.kyc_submissions k
    WHERE k.statut = p_statut;
  END IF;

  RETURN v_liste;
END;
$$;


-- ─────────────────────────────────────────────────────────────────────────────
-- 3. RPC admin_valider_kyc
--    Valide un dossier KYC :
--      • Met kyc_submissions.statut = 'valide'
--      • Met tontines.data.kyc.statut = 'valide'
--    Retourne { ok: true, message, gestionnaire, code }
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_valider_kyc(
  p_cle TEXT,
  p_id  BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_attendue   TEXT;
  v_submission RECORD;
  v_now        TIMESTAMPTZ := NOW();
BEGIN
  -- Vérification clé admin
  SELECT value INTO v_attendue
  FROM   public.app_config
  WHERE  key = 'admin_key'
  LIMIT  1;

  IF v_attendue IS NULL OR p_cle <> v_attendue THEN
    RAISE EXCEPTION 'Clé admin invalide';
  END IF;

  -- Récupérer la soumission
  SELECT * INTO v_submission
  FROM   public.kyc_submissions
  WHERE  id = p_id
  FOR    UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Dossier KYC introuvable.');
  END IF;

  IF v_submission.statut <> 'pending' THEN
    RETURN jsonb_build_object(
      'ok',     false,
      'erreur', 'Ce dossier a déjà été traité (statut : ' || v_submission.statut || ').'
    );
  END IF;

  -- 1. Mettre à jour kyc_submissions
  UPDATE public.kyc_submissions
  SET
    statut       = 'valide',
    validated_at = v_now,
    valide_par   = 'admin'
  WHERE id = p_id;

  -- 2. Mettre à jour tontines.data.kyc.statut = 'valide'
  UPDATE public.tontines
  SET data = jsonb_set(
    COALESCE(data, '{}'::jsonb),
    '{kyc, statut}',
    '"valide"',
    true
  )
  WHERE code = v_submission.code;

  RETURN jsonb_build_object(
    'ok',          true,
    'message',     'Dossier KYC validé avec succès.',
    'gestionnaire', v_submission.gestionnaire,
    'code',        v_submission.code
  );
END;
$$;


-- ─────────────────────────────────────────────────────────────────────────────
-- 4. RPC admin_rejeter_kyc
--    Rejette un dossier KYC :
--      • Met kyc_submissions.statut = 'rejete' + motif_rejet
--      • Met tontines.data.kyc.statut = 'rejete' + motifRejet
--    Retourne { ok: true, message, gestionnaire, code }
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_rejeter_kyc(
  p_cle   TEXT,
  p_id    BIGINT,
  p_motif TEXT DEFAULT 'Dossier non conforme.'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_attendue   TEXT;
  v_submission RECORD;
  v_now        TIMESTAMPTZ := NOW();
BEGIN
  -- Vérification clé admin
  SELECT value INTO v_attendue
  FROM   public.app_config
  WHERE  key = 'admin_key'
  LIMIT  1;

  IF v_attendue IS NULL OR p_cle <> v_attendue THEN
    RAISE EXCEPTION 'Clé admin invalide';
  END IF;

  -- Récupérer la soumission
  SELECT * INTO v_submission
  FROM   public.kyc_submissions
  WHERE  id = p_id
  FOR    UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Dossier KYC introuvable.');
  END IF;

  IF v_submission.statut <> 'pending' THEN
    RETURN jsonb_build_object(
      'ok',     false,
      'erreur', 'Ce dossier a déjà été traité (statut : ' || v_submission.statut || ').'
    );
  END IF;

  -- 1. Mettre à jour kyc_submissions
  UPDATE public.kyc_submissions
  SET
    statut       = 'rejete',
    motif_rejet  = p_motif,
    validated_at = v_now,
    valide_par   = 'admin'
  WHERE id = p_id;

  -- 2. Mettre à jour tontines.data.kyc : statut = 'rejete' + motifRejet
  UPDATE public.tontines
  SET data = jsonb_set(
    jsonb_set(
      COALESCE(data, '{}'::jsonb),
      '{kyc, statut}',
      '"rejete"',
      true
    ),
    '{kyc, motifRejet}',
    to_jsonb(p_motif),
    true
  )
  WHERE code = v_submission.code;

  RETURN jsonb_build_object(
    'ok',          true,
    'message',     'Dossier KYC rejeté.',
    'gestionnaire', v_submission.gestionnaire,
    'code',        v_submission.code,
    'motif',       p_motif
  );
END;
$$;


-- ─────────────────────────────────────────────────────────────────────────────
-- 5. GRANTS — Accès au rôle anon et authenticated
-- ─────────────────────────────────────────────────────────────────────────────
GRANT SELECT, INSERT, UPDATE ON public.kyc_submissions TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_lister_kyc  TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_valider_kyc TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_rejeter_kyc TO anon, authenticated;


-- ─────────────────────────────────────────────────────────────────────────────
-- FIN DU SCRIPT
-- ─────────────────────────────────────────────────────────────────────────────
-- Notes importantes :
--   • La clé admin est lue depuis app_config WHERE key = 'admin_key'
--   • admin_valider_kyc / admin_rejeter_kyc écrivent AUSSI dans tontines.data.kyc
--     (JSONB) via jsonb_set — la tontine n'a pas besoin d'être rechargée manuellement
--   • Le gestionnaire peut re-soumettre un KYC après rejet (nouveau pending)
--   • La soumission Flutter utilise ecrireTontineSansPIN + http.post kyc_submissions
-- ─────────────────────────────────────────────────────────────────────────────
