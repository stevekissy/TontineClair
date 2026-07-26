-- ============================================================
-- MIGRATIONS : RPCs pour dessaisissements Crypto
-- Prêt octroyé, Dépense caisse, Décaissement cagnotte
-- v1.2.9 — Frais réseau 2,5% uniformisés
-- ============================================================

-- ── 1. Prêt octroyé via CoinPayments : débite la caisse + crée le prêt ──────────
CREATE OR REPLACE FUNCTION public.debiter_pret_sycapay(
  p_code             TEXT,
  p_montant          INT,
  p_reference        TEXT,
  p_num_commande     TEXT,
  p_operateur        TEXT,
  p_emprunteur_id    TEXT,
  p_emprunteur_nom   TEXT,
  p_taux             NUMERIC DEFAULT 0,
  p_durees_mois      INT     DEFAULT 1,
  p_description      TEXT    DEFAULT '',
  p_now              TEXT    DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_data       JSONB;
  v_caisse     JSONB;
  v_mouvements JSONB;
  v_prets      JSONB;
  v_journal    JSONB;
  v_now        TEXT;
  v_interet    INT;
  v_total_du   INT;
  v_mensualite INT;
  v_echeancier JSONB;
  i            INT;
  v_date_ech   TIMESTAMPTZ;
BEGIN
  v_now := COALESCE(p_now, NOW()::TEXT);

  SELECT data INTO v_data FROM public.tontines WHERE code = UPPER(p_code);
  IF NOT FOUND THEN RAISE EXCEPTION 'Tontine % introuvable', p_code; END IF;

  -- Caisse
  v_caisse     := COALESCE(v_data->'caisse', '{"mouvements":[]}'::JSONB);
  v_mouvements := COALESCE(v_caisse->'mouvements', '[]'::JSONB);
  v_mouvements := v_mouvements || jsonb_build_object(
    'id',          p_reference || 'P',
    'type',        'depense',
    'montant',     p_montant,
    'description', CASE WHEN p_description <> '' THEN p_description
                        ELSE 'Prêt crypto → ' || p_emprunteur_nom END,
    'operateur',   p_operateur,
    'date',        v_now,
    'reference',   p_reference,
    'sycapay',     TRUE
  );
  v_data := jsonb_set(v_data, '{caisse}', jsonb_build_object('mouvements', v_mouvements));

  -- Prêt
  v_interet    := (p_montant * p_taux / 100)::INT;
  v_total_du   := p_montant + v_interet;
  v_mensualite := GREATEST(1, v_total_du / GREATEST(1, p_durees_mois));
  v_echeancier := '[]'::JSONB;
  FOR i IN 1..p_durees_mois LOOP
    v_date_ech := (NOW() + (i * INTERVAL '30 days'));
    v_echeancier := v_echeancier || jsonb_build_object(
      'mois', i, 'date', v_date_ech::TEXT,
      'montant', CASE WHEN i = p_durees_mois
                      THEN v_total_du - v_mensualite * (p_durees_mois - 1)
                      ELSE v_mensualite END
    );
  END LOOP;

  v_prets := COALESCE(v_data->'prets', '[]'::JSONB);
  v_prets := v_prets || jsonb_build_object(
    'id',             p_reference,
    'emprunteurId',   p_emprunteur_id,
    'emprunteurNom',  p_emprunteur_nom,
    'montant',        p_montant,
    'taux',           p_taux,
    'dureesMois',     p_durees_mois,
    'dateDebut',      v_now,
    'statut',         'en_cours',
    'remboursements', '[]'::JSONB,
    'echeancier',     v_echeancier,
    'reference',      p_reference,
    'resteADu',       v_total_du,
    'totalDu',        v_total_du,
    'sycapay',        TRUE
  );
  v_data := jsonb_set(v_data, '{prets}', v_prets);

  -- Journal
  v_journal := COALESCE(v_data->'journal', '[]'::JSONB);
  v_journal := jsonb_build_object(
    'quoi',        'PRÊT CRYPTO → ' || p_emprunteur_nom || ' — ' || p_montant::TEXT || ' — ' || p_taux::TEXT || '% — ' || p_durees_mois::TEXT || ' mois',
    'quand',       v_now,
    'reference',   p_reference,
    'sycapay',     TRUE
  ) || v_journal;
  v_data := jsonb_set(v_data, '{journal}', v_journal);

  UPDATE public.tontines SET data = v_data, updated_at = NOW() WHERE code = UPPER(p_code);
  RETURN jsonb_build_object('ok', TRUE, 'reference', p_reference);
END;
$$;

-- ── 2. Dépense caisse via CoinPayments : débite la caisse ───────────────────────
CREATE OR REPLACE FUNCTION public.debiter_depense_sycapay(
  p_code              TEXT,
  p_montant           INT,
  p_reference         TEXT,
  p_num_commande      TEXT,
  p_operateur         TEXT,
  p_beneficiaire_nom  TEXT,
  p_description       TEXT DEFAULT '',
  p_now               TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_data       JSONB;
  v_caisse     JSONB;
  v_mouvements JSONB;
  v_journal    JSONB;
  v_now        TEXT;
BEGIN
  v_now := COALESCE(p_now, NOW()::TEXT);

  SELECT data INTO v_data FROM public.tontines WHERE code = UPPER(p_code);
  IF NOT FOUND THEN RAISE EXCEPTION 'Tontine % introuvable', p_code; END IF;

  v_caisse     := COALESCE(v_data->'caisse', '{"mouvements":[]}'::JSONB);
  v_mouvements := COALESCE(v_caisse->'mouvements', '[]'::JSONB);
  v_mouvements := v_mouvements || jsonb_build_object(
    'id',          p_reference || 'D',
    'type',        'depense',
    'montant',     p_montant,
    'description', CASE WHEN p_description <> '' THEN p_description
                        ELSE 'Dépense crypto → ' || p_beneficiaire_nom END,
    'operateur',   p_operateur,
    'date',        v_now,
    'reference',   p_reference,
    'sycapay',     TRUE
  );
  v_data := jsonb_set(v_data, '{caisse}', jsonb_build_object('mouvements', v_mouvements));

  v_journal := COALESCE(v_data->'journal', '[]'::JSONB);
  v_journal := jsonb_build_object(
    'quoi',      'DÉPENSE CRYPTO → ' || p_beneficiaire_nom || ' — ' || p_montant::TEXT,
    'quand',     v_now,
    'reference', p_reference,
    'sycapay',   TRUE
  ) || v_journal;
  v_data := jsonb_set(v_data, '{journal}', v_journal);

  UPDATE public.tontines SET data = v_data, updated_at = NOW() WHERE code = UPPER(p_code);
  RETURN jsonb_build_object('ok', TRUE, 'reference', p_reference);
END;
$$;

-- ── 3. Décaissement cagnotte via CoinPayments ───────────────────────────────────
CREATE OR REPLACE FUNCTION public.debiter_decaissement_sycapay(
  p_code              TEXT,
  p_montant           INT,
  p_reference         TEXT,
  p_num_commande      TEXT,
  p_operateur         TEXT,
  p_beneficiaire_id   TEXT,
  p_beneficiaire_nom  TEXT,
  p_numero_tour       INT     DEFAULT 1,
  p_description       TEXT    DEFAULT '',
  p_now               TEXT    DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_data       JSONB;
  v_caisse     JSONB;
  v_mouvements JSONB;
  v_journal    JSONB;
  v_now        TEXT;
BEGIN
  v_now := COALESCE(p_now, NOW()::TEXT);

  SELECT data INTO v_data FROM public.tontines WHERE code = UPPER(p_code);
  IF NOT FOUND THEN RAISE EXCEPTION 'Tontine % introuvable', p_code; END IF;

  v_caisse     := COALESCE(v_data->'caisse', '{"mouvements":[]}'::JSONB);
  v_mouvements := COALESCE(v_caisse->'mouvements', '[]'::JSONB);
  v_mouvements := v_mouvements || jsonb_build_object(
    'id',          p_reference || 'C',
    'type',        'depense',
    'montant',     p_montant,
    'description', CASE WHEN p_description <> '' THEN p_description
                        ELSE 'Cagnotte tour ' || p_numero_tour::TEXT || ' → ' || p_beneficiaire_nom END,
    'operateur',   p_operateur,
    'date',        v_now,
    'reference',   p_reference,
    'sycapay',     TRUE,
    'tour',        p_numero_tour
  );
  v_data := jsonb_set(v_data, '{caisse}', jsonb_build_object('mouvements', v_mouvements));

  v_journal := COALESCE(v_data->'journal', '[]'::JSONB);
  v_journal := jsonb_build_object(
    'quoi',      'DÉCAISSEMENT TOUR ' || p_numero_tour::TEXT || ' → ' || p_beneficiaire_nom || ' — ' || p_montant::TEXT,
    'quand',     v_now,
    'reference', p_reference,
    'sycapay',   TRUE
  ) || v_journal;
  v_data := jsonb_set(v_data, '{journal}', v_journal);

  UPDATE public.tontines SET data = v_data, updated_at = NOW() WHERE code = UPPER(p_code);
  RETURN jsonb_build_object('ok', TRUE, 'reference', p_reference, 'tour', p_numero_tour);
END;
$$;

GRANT EXECUTE ON FUNCTION public.debiter_pret_sycapay TO service_role;
GRANT EXECUTE ON FUNCTION public.debiter_depense_sycapay TO service_role;
GRANT EXECUTE ON FUNCTION public.debiter_decaissement_sycapay TO service_role;
