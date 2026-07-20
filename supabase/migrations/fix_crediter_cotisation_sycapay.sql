-- =============================================================================
-- CORRECTIF : crediter_cotisation_sycapay
-- Problèmes corrigés :
--   1. Mise à jour de paiements{} (source de vérité Flutter pour membre.paye)
--   2. Ajout d'un mouvement 'cotisation' dans caisse.mouvements[] (balance)
--   3. Journal standardisé : clés 'gestionnaire'/'quand' au lieu de 'par'/'le'
-- =============================================================================

CREATE OR REPLACE FUNCTION public.crediter_cotisation_sycapay(
  p_code         text,
  p_membre_id    text,
  p_montant      integer,
  p_reference    text,
  p_num_commande text,
  p_operateur    text,
  p_now          text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row         record;
  v_data        jsonb;
  v_membres     jsonb;
  v_membre      jsonb;
  v_i           int;
  v_journal     jsonb;
  v_paiements   jsonb;
  v_caisse      jsonb;
  v_mouvements  jsonb;
  v_now         text;
  v_cotisations jsonb;
  v_cotis       jsonb;
  v_found       boolean := false;
  v_entry       jsonb;
  v_mouvement   jsonb;
  v_membre_nom  text;
  v_tour        int;
BEGIN
  v_now := COALESCE(p_now, now()::text);

  SELECT * INTO v_row
  FROM public.tontines
  WHERE code = UPPER(p_code);

  IF NOT FOUND THEN
    RAISE EXCEPTION 'TONTINE_INTROUVABLE: %', p_code;
  END IF;

  v_data       := v_row.data;
  v_membres    := COALESCE(v_data->'membres',  '[]'::jsonb);
  v_journal    := COALESCE(v_data->'journal',  '[]'::jsonb);
  v_paiements  := COALESCE(v_data->'paiements', '{}'::jsonb);
  v_caisse     := COALESCE(v_data->'caisse',   '{}'::jsonb);
  v_mouvements := COALESCE(v_caisse->'mouvements', '[]'::jsonb);
  v_tour       := COALESCE((v_data->>'tourActuel')::int, 0) + 1;

  -- ── Idempotence : déjà crédité pour ce membre ce tour ? ──────────────────
  IF v_paiements ? p_membre_id THEN
    RETURN jsonb_build_object('ok', true, 'message', 'déjà crédité (idempotent)');
  END IF;

  -- Idempotence sur la caisse (même référence déjà présente ?)
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_mouvements) AS m
    WHERE m->>'id' = p_reference OR m->>'numCommande' = p_num_commande
  ) THEN
    RETURN jsonb_build_object('ok', true, 'message', 'déjà crédité caisse (idempotent)');
  END IF;

  -- ── Trouver le membre et récupérer son nom ────────────────────────────────
  FOR v_i IN 0 .. jsonb_array_length(v_membres) - 1 LOOP
    v_membre := v_membres -> v_i;
    IF v_membre->>'id' = p_membre_id THEN
      v_membre_nom := COALESCE(v_membre->>'nom', p_membre_id);

      -- Ajouter la cotisation dans membres[].cotisations[]
      v_cotisations := COALESCE(v_membre->'cotisations', '[]'::jsonb);
      v_cotis := jsonb_build_object(
        'id',          p_reference,
        'montant',     p_montant,
        'date',        v_now,
        'methode',     'sycapay',
        'operateur',   p_operateur,
        'reference',   p_reference,
        'numCommande', p_num_commande
      );
      v_cotisations := v_cotisations || jsonb_build_array(v_cotis);
      v_membre      := v_membre || jsonb_build_object('cotisations', v_cotisations);
      v_membres     := jsonb_set(v_membres, ARRAY[v_i::text], v_membre);
      v_found       := true;
      EXIT;
    END IF;
  END LOOP;

  IF NOT v_found THEN
    RAISE EXCEPTION 'MEMBRE_INTROUVABLE: % dans tontine %', p_membre_id, p_code;
  END IF;

  -- ── 1. Mettre à jour paiements{} — source de vérité Flutter ──────────────
  v_paiements := v_paiements || jsonb_build_object(
    p_membre_id, jsonb_build_object(
      'date',        v_now,
      'methode',     'sycapay',
      'operateur',   p_operateur,
      'reference',   p_reference,
      'montant',     p_montant,
      'numCommande', p_num_commande
    )
  );

  -- ── 2. Ajouter mouvement 'cotisation' dans caisse.mouvements[] ────────────
  v_mouvement := jsonb_build_object(
    'id',          p_reference,
    'type',        'cotisation',
    'montant',     p_montant,
    'description', 'Cotisation ' || COALESCE(v_membre_nom, p_membre_id) || ' — Tour ' || v_tour::text || ' (SycaPay ' || UPPER(p_operateur) || ')',
    'gestionnaire','SycaPay',
    'date',        v_now,
    'reference',   p_reference,
    'methode',     'sycapay',
    'operateur',   p_operateur,
    'numCommande', p_num_commande
  );
  v_mouvements := v_mouvements || jsonb_build_array(v_mouvement);
  v_caisse     := v_caisse || jsonb_build_object('mouvements', v_mouvements);

  -- ── 3. Journal standardisé (clés gestionnaire/quand) ─────────────────────
  v_entry := jsonb_build_object(
    'quoi',        'COTISATION via SycaPay (' || UPPER(p_operateur) || ') — ' || COALESCE(v_membre_nom, p_membre_id) || ' — ' || p_montant::text || ' XOF',
    'gestionnaire','SycaPay',
    'quand',       v_now,
    'reference',   p_reference,
    'membreId',    p_membre_id
  );
  v_journal := jsonb_build_array(v_entry) || v_journal;

  -- ── Écrire tout d'un coup ─────────────────────────────────────────────────
  v_data := v_data
    || jsonb_build_object('membres',   v_membres)
    || jsonb_build_object('paiements', v_paiements)
    || jsonb_build_object('caisse',    v_caisse)
    || jsonb_build_object('journal',   v_journal);

  UPDATE public.tontines
  SET data = v_data, modifie_le = now()
  WHERE code = UPPER(p_code);

  RETURN jsonb_build_object('ok', true, 'message', 'cotisation créditée');
EXCEPTION WHEN OTHERS THEN
  RAISE EXCEPTION 'crediter_cotisation_sycapay: % %', SQLSTATE, SQLERRM;
END;
$$;

GRANT EXECUTE ON FUNCTION public.crediter_cotisation_sycapay TO anon, authenticated;

-- =============================================================================
-- CORRECTIF : crediter_caisse_sycapay
-- Journal standardisé : 'gestionnaire'/'quand' au lieu de 'par'/'le'
-- =============================================================================
CREATE OR REPLACE FUNCTION public.crediter_caisse_sycapay(
  p_code         text,
  p_montant      integer,
  p_reference    text,
  p_num_commande text,
  p_operateur    text,
  p_description  text,
  p_now          text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row        record;
  v_data       jsonb;
  v_caisse     jsonb;
  v_mouvements jsonb;
  v_journal    jsonb;
  v_now        text;
  v_mouvement  jsonb;
  v_entry      jsonb;
BEGIN
  v_now := COALESCE(p_now, now()::text);

  SELECT * INTO v_row
  FROM public.tontines
  WHERE code = UPPER(p_code);

  IF NOT FOUND THEN
    RAISE EXCEPTION 'TONTINE_INTROUVABLE: %', p_code;
  END IF;

  v_data       := v_row.data;
  v_caisse     := COALESCE(v_data->'caisse', '{}'::jsonb);
  v_mouvements := COALESCE(v_caisse->'mouvements', '[]'::jsonb);
  v_journal    := COALESCE(v_data->'journal', '[]'::jsonb);

  -- Idempotence
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_mouvements) AS m
    WHERE m->>'id' = p_reference OR m->>'numCommande' = p_num_commande
  ) THEN
    RETURN jsonb_build_object('ok', true, 'message', 'déjà crédité (idempotent)');
  END IF;

  -- Mouvement type 'apport' pour les apports manuels en caisse
  v_mouvement := jsonb_build_object(
    'id',          p_reference,
    'type',        'apport',
    'montant',     p_montant,
    'description', p_description,
    'gestionnaire','SycaPay',
    'date',        v_now,
    'reference',   p_reference,
    'methode',     'sycapay',
    'operateur',   p_operateur,
    'numCommande', p_num_commande
  );

  -- Journal standardisé
  v_entry := jsonb_build_object(
    'quoi',        'APPORT CAISSE via SycaPay (' || UPPER(p_operateur) || ') — ' || p_montant::text || ' XOF' ||
                   CASE WHEN p_description <> '' THEN ' — ' || p_description ELSE '' END,
    'gestionnaire','SycaPay',
    'quand',       v_now,
    'reference',   p_reference
  );

  v_mouvements := v_mouvements || jsonb_build_array(v_mouvement);
  v_caisse     := v_caisse || jsonb_build_object('mouvements', v_mouvements);
  v_journal    := jsonb_build_array(v_entry) || v_journal;
  v_data       := v_data
                  || jsonb_build_object('caisse',  v_caisse)
                  || jsonb_build_object('journal', v_journal);

  UPDATE public.tontines
  SET data = v_data, modifie_le = now()
  WHERE code = UPPER(p_code);

  RETURN jsonb_build_object('ok', true, 'message', 'caisse créditée');
EXCEPTION WHEN OTHERS THEN
  RAISE EXCEPTION 'crediter_caisse_sycapay: % %', SQLSTATE, SQLERRM;
END;
$$;

GRANT EXECUTE ON FUNCTION public.crediter_caisse_sycapay TO anon, authenticated;
