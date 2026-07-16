-- ============================================================================
-- TontineClair — Décaissements Pending (Clôture tour Premium, validation admin)
-- Version : 1.0 — À exécuter dans Supabase SQL Editor
-- ============================================================================
-- Fonctionnement :
--   1. Gestionnaire Premium clôture un tour → Mobile Money form (opérateur + numéro)
--   2. Le décaissement est inséré dans decaissements_pending (statut = 'pending')
--   3. Le tour avance (tourActuel++) MAIS la caisse N'EST PAS débitée
--   4. L'admin voit la demande dans son espace (onglet 💰 Décaissements)
--   5. Validation → RPC admin_valider_decaissement :
--        • Vérifie solde caisse >= montant_net
--        • Débite la caisse du montant_net (type='decaissement' dans JSON mouvements)
--        • Marque statut = 'validee'
--   6. Rejet → RPC admin_rejeter_decaissement :
--        • Marque statut = 'rejetee' + motif_rejet
--        • Le tour est déjà avancé, la caisse reste intacte
--   7. Dans les deux cas : une notification est envoyée côté Flutter
-- ============================================================================
-- Champs Mobile Money :
--   commission    = round(montant * 0.01)   (1% du montant brut)
--   montant_net   = montant - commission     (montant effectivement débité de la caisse)
--   numer_tour    = numéro du tour cloturé
-- ============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. TABLE decaissements_pending
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.decaissements_pending (
  id                   BIGSERIAL PRIMARY KEY,
  code                 TEXT        NOT NULL,            -- code tontine (ex: 'A1B2C3')
  beneficiaire_id      TEXT        NOT NULL,            -- id du membre bénéficiaire
  beneficiaire_nom     TEXT        NOT NULL,            -- nom du membre bénéficiaire
  montant              INTEGER     NOT NULL CHECK (montant > 0),   -- montant brut versé
  commission           INTEGER     NOT NULL DEFAULT 0, -- 1% du montant brut
  montant_net          INTEGER     NOT NULL,            -- montant - commission (débité caisse)
  numer_tour           INTEGER     NOT NULL DEFAULT 0, -- numéro du tour cloturé
  operateur            TEXT        NOT NULL,            -- 'orange' | 'moov' | 'mtn' | 'wave'
  numero_beneficiaire  TEXT        NOT NULL,            -- numéro Mobile Money du bénéficiaire
  gestionnaire         TEXT        NOT NULL DEFAULT '', -- nom du gestionnaire qui soumet
  reference            TEXT        NOT NULL DEFAULT '', -- référence unique générée côté Flutter
  devise               TEXT        NOT NULL DEFAULT 'XOF',
  statut               TEXT        NOT NULL DEFAULT 'pending'
                         CHECK (statut IN ('pending', 'validee', 'rejetee')),
  motif_rejet          TEXT,                            -- rempli si rejetee
  valide_par           TEXT,                            -- 'admin' si validée/rejetée
  validated_at         TIMESTAMPTZ,                     -- horodatage de la décision
  created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Index pour les requêtes courantes
CREATE INDEX IF NOT EXISTS idx_decaissements_pending_code    ON public.decaissements_pending(code);
CREATE INDEX IF NOT EXISTS idx_decaissements_pending_statut  ON public.decaissements_pending(statut);
CREATE INDEX IF NOT EXISTS idx_decaissements_pending_created ON public.decaissements_pending(created_at DESC);

-- RLS : autoriser lecture/insertion/update anonyme (clé anon suffisante)
-- La validation est protégée par le paramètre p_cle côté RPC
ALTER TABLE public.decaissements_pending ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "decaissements_pending_anon_select" ON public.decaissements_pending;
CREATE POLICY "decaissements_pending_anon_select"
  ON public.decaissements_pending FOR SELECT
  USING (true);

DROP POLICY IF EXISTS "decaissements_pending_anon_insert" ON public.decaissements_pending;
CREATE POLICY "decaissements_pending_anon_insert"
  ON public.decaissements_pending FOR INSERT
  WITH CHECK (true);

DROP POLICY IF EXISTS "decaissements_pending_anon_update" ON public.decaissements_pending;
CREATE POLICY "decaissements_pending_anon_update"
  ON public.decaissements_pending FOR UPDATE
  USING (true);


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. RPC admin_lister_decaissements
--    Retourne les décaissements filtrés par statut.
--    p_statut : 'tous' | 'pending' | 'validee' | 'rejetee'
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_lister_decaissements(
  p_cle    TEXT,
  p_statut TEXT DEFAULT 'tous'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_cle_attendue TEXT := current_setting('app.admin_key', true);
  v_rows         JSONB;
BEGIN
  -- ── Vérification clé admin ─────────────────────────────────────────────────
  IF v_cle_attendue IS NULL OR v_cle_attendue = '' THEN
    IF p_cle NOT LIKE 'tc-admin%' THEN
      RETURN jsonb_build_object('ok', false, 'erreur', 'Clé admin invalide');
    END IF;
  ELSIF p_cle <> v_cle_attendue THEN
    -- Fallback : vérifier dans admin_config si elle existe
    IF NOT EXISTS (
      SELECT 1 FROM public.admin_config WHERE cle = p_cle AND actif = true LIMIT 1
    ) THEN
      RETURN jsonb_build_object('ok', false, 'erreur', 'Clé admin invalide');
    END IF;
  END IF;

  -- ── Requête filtrée ────────────────────────────────────────────────────────
  IF p_statut = 'tous' THEN
    SELECT jsonb_agg(row_to_json(d.*)::jsonb ORDER BY d.created_at DESC)
    INTO v_rows
    FROM public.decaissements_pending d;
  ELSE
    SELECT jsonb_agg(row_to_json(d.*)::jsonb ORDER BY d.created_at DESC)
    INTO v_rows
    FROM public.decaissements_pending d
    WHERE d.statut = p_statut;
  END IF;

  RETURN COALESCE(v_rows, '[]'::jsonb);

EXCEPTION WHEN OTHERS THEN
  RETURN '[]'::jsonb;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_lister_decaissements(TEXT, TEXT) TO anon, authenticated, service_role;


-- ─────────────────────────────────────────────────────────────────────────────
-- 3. RPC admin_valider_decaissement
--    Valide un décaissement pending :
--      a) Lit le décaissement depuis decaissements_pending
--      b) Vérifie que le solde caisse >= montant_net
--      c) Débite la caisse du montant_net (type='decaissement' dans JSON mouvements)
--      d) Met à jour statut → 'validee' + validated_at
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_valider_decaissement(
  p_cle TEXT,
  p_id  BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_cle_attendue  TEXT := current_setting('app.admin_key', true);
  v_dec           public.decaissements_pending%ROWTYPE;
  v_tontine_data  JSONB;
  v_caisse        JSONB;
  v_mouvements    JSONB;
  v_journal       JSONB;
  v_solde         INTEGER;
  v_ref           TEXT;
  v_now           TEXT;
  v_new_mouvement JSONB;
BEGIN
  -- ── Vérification clé admin ─────────────────────────────────────────────────
  IF v_cle_attendue IS NULL OR v_cle_attendue = '' THEN
    IF p_cle NOT LIKE 'tc-admin%' THEN
      RETURN jsonb_build_object('ok', false, 'erreur', 'Clé admin invalide');
    END IF;
  ELSIF p_cle <> v_cle_attendue THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.admin_config WHERE cle = p_cle AND actif = true LIMIT 1
    ) THEN
      RETURN jsonb_build_object('ok', false, 'erreur', 'Clé admin invalide');
    END IF;
  END IF;

  -- ── Lecture du décaissement ─────────────────────────────────────────────────
  SELECT * INTO v_dec
  FROM public.decaissements_pending
  WHERE id = p_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Décaissement introuvable');
  END IF;

  IF v_dec.statut <> 'pending' THEN
    RETURN jsonb_build_object(
      'ok',     false,
      'erreur', 'Décaissement déjà traité (statut: ' || v_dec.statut || ')'
    );
  END IF;

  -- ── Lecture données tontine ─────────────────────────────────────────────────
  SELECT data INTO v_tontine_data
  FROM public.tontines
  WHERE UPPER(code) = UPPER(v_dec.code);

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Tontine introuvable: ' || v_dec.code);
  END IF;

  -- ── Calcul du solde caisse actuel ───────────────────────────────────────────
  v_caisse     := COALESCE(v_tontine_data->'caisse', '{"mouvements":[]}'::jsonb);
  v_mouvements := COALESCE(v_caisse->'mouvements', '[]'::jsonb);

  SELECT COALESCE(SUM(
    CASE
      WHEN (m->>'type') IN ('depot','cotisation','remboursement','apport') THEN  (m->>'montant')::integer
      WHEN (m->>'type') IN ('depense','pret','penalite','correction','decaissement') THEN -((m->>'montant')::integer)
      ELSE 0
    END
  ), 0)
  INTO v_solde
  FROM jsonb_array_elements(v_mouvements) AS m;

  -- ── Vérification solde suffisant ────────────────────────────────────────────
  IF v_solde < v_dec.montant_net THEN
    RETURN jsonb_build_object(
      'ok',     false,
      'erreur', format(
        'Solde caisse insuffisant : %s %s disponible, %s %s requis (montant net après commission)',
        v_solde, v_dec.devise, v_dec.montant_net, v_dec.devise
      )
    );
  END IF;

  -- ── Préparer le nouveau mouvement caisse ────────────────────────────────────
  v_ref := COALESCE(NULLIF(v_dec.reference, ''), 'DEC-' || EXTRACT(EPOCH FROM NOW())::BIGINT::TEXT);
  v_now := to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"');

  v_new_mouvement := jsonb_build_object(
    'id',                  v_ref,
    'type',                'decaissement',
    'montant',             v_dec.montant_net,
    'description',         format(
                             'Décaissement tour %s — %s — Mobile Money %s',
                             v_dec.numer_tour,
                             v_dec.beneficiaire_nom,
                             upper(v_dec.operateur)
                           ),
    'gestionnaire',        v_dec.gestionnaire,
    'date',                v_now,
    'reference',           v_ref,
    'methode',             v_dec.operateur,
    'numero_beneficiaire', v_dec.numero_beneficiaire,
    'beneficiaire_id',     v_dec.beneficiaire_id,
    'beneficiaire_nom',    v_dec.beneficiaire_nom,
    'numer_tour',          v_dec.numer_tour,
    'commission',          v_dec.commission,
    'montant_brut',        v_dec.montant,
    'decaissement_id',     p_id
  );

  -- ── Injecter dans caisse.mouvements ─────────────────────────────────────────
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

  -- ── Journal ─────────────────────────────────────────────────────────────────
  v_journal := COALESCE(v_tontine_data->'journal', '[]'::jsonb);
  v_journal := jsonb_build_array(
    jsonb_build_object(
      'quoi',        format(
                       'DÉCAISSEMENT VALIDÉ — Tour %s — %s — %s %s (net) — %s [commission: %s %s] — %s',
                       v_dec.numer_tour,
                       v_dec.beneficiaire_nom,
                       v_dec.montant_net, v_dec.devise,
                       upper(v_dec.operateur),
                       v_dec.commission, v_dec.devise,
                       v_dec.numero_beneficiaire
                     ),
      'gestionnaire', v_dec.gestionnaire,
      'quand',        v_now,
      'reference',    v_ref
    )
  ) || v_journal;
  v_tontine_data := jsonb_set(v_tontine_data, '{journal}', v_journal);

  -- ── Écriture dans tontines ───────────────────────────────────────────────────
  UPDATE public.tontines
  SET
    data       = v_tontine_data,
    modifie_le = NOW()
  WHERE UPPER(code) = UPPER(v_dec.code);

  -- ── Marquer le décaissement comme validé ────────────────────────────────────
  UPDATE public.decaissements_pending
  SET
    statut       = 'validee',
    validated_at = NOW(),
    valide_par   = 'admin'
  WHERE id = p_id;

  RETURN jsonb_build_object(
    'ok',            true,
    'message',       format(
                       'Décaissement validé — caisse débitée de %s %s (commission %s %s déduite)',
                       v_dec.montant_net, v_dec.devise,
                       v_dec.commission,  v_dec.devise
                     ),
    'montant_net',   v_dec.montant_net,
    'commission',    v_dec.commission,
    'beneficiaire',  v_dec.beneficiaire_nom,
    'numer_tour',    v_dec.numer_tour
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'erreur', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_valider_decaissement(TEXT, BIGINT) TO anon, authenticated, service_role;


-- ─────────────────────────────────────────────────────────────────────────────
-- 4. RPC admin_rejeter_decaissement
--    Rejette un décaissement pending.
--    Note : le tour est DÉJÀ avancé (tourActuel++) côté Flutter au moment de la
--    soumission — la caisse reste intacte, seul le statut change.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_rejeter_decaissement(
  p_cle   TEXT,
  p_id    BIGINT,
  p_motif TEXT DEFAULT 'Rejeté par l''administrateur'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_cle_attendue TEXT := current_setting('app.admin_key', true);
  v_dec          public.decaissements_pending%ROWTYPE;
BEGIN
  -- ── Vérification clé admin ─────────────────────────────────────────────────
  IF v_cle_attendue IS NULL OR v_cle_attendue = '' THEN
    IF p_cle NOT LIKE 'tc-admin%' THEN
      RETURN jsonb_build_object('ok', false, 'erreur', 'Clé admin invalide');
    END IF;
  ELSIF p_cle <> v_cle_attendue THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.admin_config WHERE cle = p_cle AND actif = true LIMIT 1
    ) THEN
      RETURN jsonb_build_object('ok', false, 'erreur', 'Clé admin invalide');
    END IF;
  END IF;

  -- ── Lecture du décaissement ─────────────────────────────────────────────────
  SELECT * INTO v_dec
  FROM public.decaissements_pending
  WHERE id = p_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Décaissement introuvable');
  END IF;

  IF v_dec.statut <> 'pending' THEN
    RETURN jsonb_build_object(
      'ok',     false,
      'erreur', 'Décaissement déjà traité (statut: ' || v_dec.statut || ')'
    );
  END IF;

  -- ── Marquer comme rejeté ─────────────────────────────────────────────────────
  -- IMPORTANT : le tour avancé côté Flutter N'EST PAS annulé.
  -- La caisse n'a jamais été débitée → aucun rollback nécessaire.
  UPDATE public.decaissements_pending
  SET
    statut       = 'rejetee',
    motif_rejet  = p_motif,
    validated_at = NOW(),
    valide_par   = 'admin'
  WHERE id = p_id;

  RETURN jsonb_build_object(
    'ok',           true,
    'message',      'Décaissement rejeté. La caisse n''a pas été modifiée.',
    'beneficiaire', v_dec.beneficiaire_nom,
    'numer_tour',   v_dec.numer_tour
  );

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'erreur', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_rejeter_decaissement(TEXT, BIGINT, TEXT) TO anon, authenticated, service_role;


-- ─────────────────────────────────────────────────────────────────────────────
-- 5. NOTE IMPORTANTE SUR LA CLÉ ADMIN
-- ─────────────────────────────────────────────────────────────────────────────
-- Les RPCs ci-dessus utilisent current_setting('app.admin_key', true).
-- Pour configurer la clé admin dans Supabase :
--   1. Dashboard → Settings → Database → Parameters
--   2. Ajouter : app.admin_key = 'VOTRE_CLE_SECRETE'
--
-- ALTERNATIVEMENT, si tu utilises la table admin_config :
--   • INSERT INTO admin_config (cle, actif) VALUES ('ta-cle-secrete', true);
--
-- FALLBACK automatique : si app.admin_key est vide, les clés commençant
-- par 'tc-admin' sont acceptées (pratique pour les tests).
-- ─────────────────────────────────────────────────────────────────────────────

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. VÉRIFICATION
-- ─────────────────────────────────────────────────────────────────────────────
-- Après exécution, vérifier :
--   SELECT COUNT(*) FROM public.decaissements_pending;
--   SELECT proname, pronargs FROM pg_proc
--     WHERE proname IN (
--       'admin_lister_decaissements',
--       'admin_valider_decaissement',
--       'admin_rejeter_decaissement'
--     );
-- ─────────────────────────────────────────────────────────────────────────────
