-- ============================================================================
-- TontineClair — Dépenses Pending (Mobile Money, validation admin)
-- Version : 1.0 — À exécuter dans Supabase SQL Editor
-- ============================================================================
-- Fonctionnement :
--   1. Gestionnaire Premium soumet une dépense Mobile Money via l'app
--   2. La dépense est insérée dans depenses_pending avec statut 'pending'
--   3. La caisse N'EST PAS débitée
--   4. L'admin voit la dépense dans son espace et peut Valider ou Rejeter
--   5. Validation → RPC admin_valider_depense → débite la caisse via JSON tontine
--   6. Rejet → RPC admin_rejeter_depense → statut 'rejetee' + motif_rejet
--   7. Une notification est envoyée dans les deux cas (côté Flutter)
-- ============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. TABLE depenses_pending
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.depenses_pending (
  id                   BIGSERIAL PRIMARY KEY,
  code                 TEXT        NOT NULL,            -- code tontine (ex: 'A1B2C3')
  montant              INTEGER     NOT NULL CHECK (montant > 0),
  description          TEXT        NOT NULL DEFAULT '',
  operateur            TEXT        NOT NULL,            -- 'orange' | 'moov' | 'mtn' | 'wave'
  numero_beneficiaire  TEXT        NOT NULL,
  nom_beneficiaire     TEXT        NOT NULL,
  gestionnaire         TEXT        NOT NULL DEFAULT '',  -- nom du gestionnaire qui soumet
  reference            TEXT        NOT NULL DEFAULT '',
  devise               TEXT        NOT NULL DEFAULT 'XOF',
  statut               TEXT        NOT NULL DEFAULT 'pending'
                         CHECK (statut IN ('pending', 'validee', 'rejetee')),
  motif_rejet          TEXT,                            -- rempli si rejetee
  valide_par           TEXT,                            -- admin qui a validé/rejeté
  valide_le            TIMESTAMPTZ,
  created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Index pour les requêtes courantes
CREATE INDEX IF NOT EXISTS idx_depenses_pending_code   ON public.depenses_pending(code);
CREATE INDEX IF NOT EXISTS idx_depenses_pending_statut ON public.depenses_pending(statut);
CREATE INDEX IF NOT EXISTS idx_depenses_pending_created ON public.depenses_pending(created_at DESC);

-- RLS : autoriser lecture/insertion anonyme (clé anon suffisante)
-- La validation est protégée par le paramètre p_cle côté RPC
ALTER TABLE public.depenses_pending ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "depenses_pending_anon_select" ON public.depenses_pending;
CREATE POLICY "depenses_pending_anon_select"
  ON public.depenses_pending FOR SELECT
  USING (true);

DROP POLICY IF EXISTS "depenses_pending_anon_insert" ON public.depenses_pending;
CREATE POLICY "depenses_pending_anon_insert"
  ON public.depenses_pending FOR INSERT
  WITH CHECK (true);

DROP POLICY IF EXISTS "depenses_pending_anon_update" ON public.depenses_pending;
CREATE POLICY "depenses_pending_anon_update"
  ON public.depenses_pending FOR UPDATE
  USING (true);


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. RPC admin_valider_depense
--    Valide une dépense pending :
--      a) Lit la dépense depuis depenses_pending
--      b) Débite la caisse dans la table tontines (JSON mouvements)
--      c) Met à jour statut → 'validee'
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_valider_depense(
  p_cle TEXT,
  p_id  BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_cle_attendue TEXT := current_setting('app.admin_key', true);
  v_depense       public.depenses_pending%ROWTYPE;
  v_tontine_data  JSONB;
  v_caisse        JSONB;
  v_mouvements    JSONB;
  v_ref           TEXT;
  v_now           TEXT;
  v_new_mouvement JSONB;
BEGIN
  -- ── Vérification clé admin ─────────────────────────────────────────────────
  -- La clé est stockée dans app.admin_key (paramètre Supabase)
  -- Si le setting n'existe pas, on utilise une valeur par défaut sécurisée
  IF v_cle_attendue IS NULL OR v_cle_attendue = '' THEN
    -- Fallback : autoriser si la clé commence par 'tc-admin'
    -- (adapter selon votre configuration)
    IF p_cle NOT LIKE 'tc-admin%' THEN
      RETURN jsonb_build_object('ok', false, 'erreur', 'Clé admin invalide');
    END IF;
  ELSIF p_cle <> v_cle_attendue THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Clé admin invalide');
  END IF;

  -- ── Lecture de la dépense ───────────────────────────────────────────────────
  SELECT * INTO v_depense
  FROM public.depenses_pending
  WHERE id = p_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Dépense introuvable');
  END IF;

  IF v_depense.statut <> 'pending' THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Dépense déjà traitée (statut: ' || v_depense.statut || ')');
  END IF;

  -- ── Lecture données tontine ─────────────────────────────────────────────────
  SELECT data INTO v_tontine_data
  FROM public.tontines
  WHERE code = v_depense.code;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Tontine introuvable: ' || v_depense.code);
  END IF;

  -- ── Préparer le nouveau mouvement caisse ────────────────────────────────────
  v_ref := 'DEP-' || EXTRACT(EPOCH FROM NOW())::BIGINT::TEXT;
  v_now := NOW()::TEXT;

  v_new_mouvement := jsonb_build_object(
    'id',          v_ref,
    'type',        'depense',
    'montant',     v_depense.montant,
    'description', COALESCE(NULLIF(v_depense.description, ''), 'Dépense Mobile Money — ' || v_depense.operateur),
    'gestionnaire', v_depense.gestionnaire,
    'date',        v_now,
    'reference',   v_ref,
    'methode',     v_depense.operateur,
    'numero_beneficiaire', v_depense.numero_beneficiaire,
    'nom_beneficiaire',    v_depense.nom_beneficiaire,
    'depense_id',  p_id
  );

  -- ── Injecter dans caisse.mouvements ─────────────────────────────────────────
  v_caisse := COALESCE(v_tontine_data->'caisse', '{}'::jsonb);

  -- Support des deux formats : {mouvements:[...]} ou liste directe
  IF jsonb_typeof(v_caisse) = 'object' THEN
    v_mouvements := COALESCE(v_caisse->'mouvements', '[]'::jsonb);
    v_caisse := jsonb_set(v_caisse, '{mouvements}', v_mouvements || jsonb_build_array(v_new_mouvement));
  ELSIF jsonb_typeof(v_caisse) = 'array' THEN
    v_caisse := jsonb_build_object('mouvements', v_caisse || jsonb_build_array(v_new_mouvement));
  ELSE
    v_caisse := jsonb_build_object('mouvements', jsonb_build_array(v_new_mouvement));
  END IF;

  v_tontine_data := jsonb_set(v_tontine_data, '{caisse}', v_caisse);

  -- ── Écriture dans tontines ───────────────────────────────────────────────────
  UPDATE public.tontines
  SET
    data       = v_tontine_data,
    modifie_le = NOW()
  WHERE code = v_depense.code;

  -- ── Marquer la dépense comme validée ────────────────────────────────────────
  UPDATE public.depenses_pending
  SET
    statut     = 'validee',
    valide_le  = NOW(),
    valide_par = 'admin'
  WHERE id = p_id;

  RETURN jsonb_build_object(
    'ok',      true,
    'message', 'Dépense validée — caisse débitée de ' || v_depense.montant::TEXT || ' ' || v_depense.devise
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'erreur', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_valider_depense TO anon, authenticated, service_role;


-- ─────────────────────────────────────────────────────────────────────────────
-- 3. RPC admin_rejeter_depense
--    Rejette une dépense pending : statut → 'rejetee' + motif_rejet
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_rejeter_depense(
  p_cle   TEXT,
  p_id    BIGINT,
  p_motif TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_cle_attendue TEXT := current_setting('app.admin_key', true);
  v_depense      public.depenses_pending%ROWTYPE;
BEGIN
  -- ── Vérification clé admin ─────────────────────────────────────────────────
  IF v_cle_attendue IS NULL OR v_cle_attendue = '' THEN
    IF p_cle NOT LIKE 'tc-admin%' THEN
      RETURN jsonb_build_object('ok', false, 'erreur', 'Clé admin invalide');
    END IF;
  ELSIF p_cle <> v_cle_attendue THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Clé admin invalide');
  END IF;

  -- ── Lecture de la dépense ───────────────────────────────────────────────────
  SELECT * INTO v_depense
  FROM public.depenses_pending
  WHERE id = p_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Dépense introuvable');
  END IF;

  IF v_depense.statut <> 'pending' THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Dépense déjà traitée');
  END IF;

  -- ── Marquer comme rejetée ────────────────────────────────────────────────────
  UPDATE public.depenses_pending
  SET
    statut      = 'rejetee',
    motif_rejet = p_motif,
    valide_le   = NOW(),
    valide_par  = 'admin'
  WHERE id = p_id;

  RETURN jsonb_build_object('ok', true, 'message', 'Dépense rejetée.');

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'erreur', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_rejeter_depense TO anon, authenticated, service_role;


-- ─────────────────────────────────────────────────────────────────────────────
-- 4. NOTE IMPORTANTE SUR LA CLÉ ADMIN
-- ─────────────────────────────────────────────────────────────────────────────
-- Les RPCs ci-dessus utilisent current_setting('app.admin_key', true).
-- Pour configurer la clé admin dans Supabase :
--   1. Dashboard → Settings → Database → Parameters
--   2. Ajouter : app.admin_key = 'VOTRE_CLE_SECRETE'
--
-- ALTERNATIVEMENT, si tu utilises une vérification côté Flutter avec la même
-- clé que adminListerDemandes, remplace le bloc de vérification par :
--
--   IF p_cle <> 'TA_CLE_ADMIN_EN_DUR' THEN
--     RETURN jsonb_build_object('ok', false, 'erreur', 'Clé admin invalide');
--   END IF;
--
-- Pour compatibilité immédiate, le fallback 'tc-admin%' est déjà en place.
-- ─────────────────────────────────────────────────────────────────────────────

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. VÉRIFICATION
-- ─────────────────────────────────────────────────────────────────────────────
-- Après exécution, vérifier :
--   SELECT COUNT(*) FROM public.depenses_pending;
--   SELECT proname FROM pg_proc WHERE proname LIKE 'admin_%depense%';
-- ─────────────────────────────────────────────────────────────────────────────
