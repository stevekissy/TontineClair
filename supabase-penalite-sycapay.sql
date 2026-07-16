-- ============================================================================
-- TontineClair — Pénalité via SycaPay (comptes Premium)
-- Version : 1.0 — À exécuter dans Supabase SQL Editor
-- ============================================================================
-- Fonctionnement :
--   1. Gestionnaire Premium sélectionne un membre à pénaliser
--   2. Saisit le montant et le motif
--   3. Paie via SycaPay Mobile Money (même flux que l'apport caisse)
--   4. Edge Function appelle crediter_penalite_sycapay côté serveur :
--      • Injecte un mouvement 'penalite' dans caisse.mouvements
--      • Incrémente membres[idx].penalites
--      • Décrémente membres[idx].score de 5 points (min 0)
--      • Écrit dans le journal
-- ============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- RPC : crediter_penalite_sycapay
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.crediter_penalite_sycapay(
  p_code         text,
  p_montant      integer,
  p_reference    text,
  p_num_commande text,
  p_operateur    text,
  p_membre_id    text,
  p_membre_nom   text,
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
  v_membres    jsonb;
  v_now        text;
  v_mouvement  jsonb;
  v_entry      jsonb;
  v_idx        integer;
  v_membre     jsonb;
  v_pen_count  integer;
  v_score      integer;
BEGIN
  v_now := COALESCE(p_now, now()::text);

  -- ── Lire la tontine ─────────────────────────────────────────────────────────
  SELECT * INTO v_row
  FROM public.tontines
  WHERE code = UPPER(p_code);

  IF NOT FOUND THEN
    RAISE EXCEPTION 'TONTINE_INTROUVABLE: %', p_code;
  END IF;

  v_data := v_row.data;

  -- ── Lire caisse, journal, membres ───────────────────────────────────────────
  v_caisse     := COALESCE(v_data->'caisse', '{}'::jsonb);
  v_mouvements := COALESCE(v_caisse->'mouvements', '[]'::jsonb);
  v_journal    := COALESCE(v_data->'journal', '[]'::jsonb);
  v_membres    := COALESCE(v_data->'membres', '[]'::jsonb);

  -- ── Idempotence : même référence déjà présente ? ────────────────────────────
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_mouvements) AS m
    WHERE m->>'id' = p_reference OR m->>'numCommande' = p_num_commande
  ) THEN
    RETURN jsonb_build_object('ok', true, 'message', 'déjà crédité (idempotent)');
  END IF;

  -- ── Construire le mouvement pénalité ─────────────────────────────────────────
  v_mouvement := jsonb_build_object(
    'id',            p_reference,
    'type',          'penalite',
    'montant',       p_montant,
    'description',   CASE
                       WHEN p_description <> '' THEN p_description
                       ELSE 'Pénalité — ' || COALESCE(NULLIF(p_membre_nom,''), p_membre_id)
                     END,
    'gestionnaire',  'SycaPay',
    'date',          v_now,
    'reference',     p_reference,
    'methode',       'sycapay',
    'operateur',     p_operateur,
    'numCommande',   p_num_commande,
    'membreId',      p_membre_id,
    'membreNom',     p_membre_nom
  );

  -- ── Construire l'entrée journal ─────────────────────────────────────────────
  v_entry := jsonb_build_object(
    'quoi', 'PÉNALITÉ SycaPay — ' || COALESCE(NULLIF(p_membre_nom,''), p_membre_id)
            || ' — ' || p_montant::text || ' XOF'
            || CASE WHEN p_description <> '' THEN ' — ' || p_description ELSE '' END,
    'par',  'SycaPay',
    'le',   (EXTRACT(EPOCH FROM now()) * 1000)::bigint,
    'ref',  p_reference
  );

  -- ── Injecter mouvement dans caisse ──────────────────────────────────────────
  v_mouvements := v_mouvements || jsonb_build_array(v_mouvement);
  v_caisse     := v_caisse || jsonb_build_object('mouvements', v_mouvements);
  v_journal    := jsonb_build_array(v_entry) || v_journal;

  -- ── Mettre à jour le membre pénalisé (penalites++, score-5) ─────────────────
  -- Parcourt le tableau membres JSON pour trouver l'index du membre
  IF p_membre_id IS NOT NULL AND p_membre_id <> '' THEN
    v_idx := -1;
    FOR v_idx IN 0..(jsonb_array_length(v_membres) - 1) LOOP
      IF v_membres->v_idx->>'id' = p_membre_id THEN
        v_membre    := v_membres->v_idx;
        v_pen_count := COALESCE((v_membre->>'penalites')::integer, 0) + 1;
        v_score     := GREATEST(0, COALESCE((v_membre->>'score')::integer, 50) - 5);
        v_membre    := v_membre
                       || jsonb_build_object('penalites', v_pen_count)
                       || jsonb_build_object('score', v_score);
        v_membres   := jsonb_set(v_membres, ARRAY[v_idx::text], v_membre);
        EXIT;
      END IF;
    END LOOP;
  END IF;

  -- ── Assembler et écrire la tontine ─────────────────────────────────────────
  v_data := v_data
            || jsonb_build_object('caisse',  v_caisse)
            || jsonb_build_object('journal', v_journal)
            || jsonb_build_object('membres', v_membres);

  UPDATE public.tontines
  SET data = v_data, modifie_le = now()
  WHERE code = UPPER(p_code);

  RETURN jsonb_build_object('ok', true, 'message', 'pénalité enregistrée');

EXCEPTION WHEN OTHERS THEN
  RAISE EXCEPTION 'crediter_penalite_sycapay: % %', SQLSTATE, SQLERRM;
END;
$$;

GRANT EXECUTE ON FUNCTION public.crediter_penalite_sycapay TO service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- VÉRIFICATION
-- ─────────────────────────────────────────────────────────────────────────────
-- SELECT proname FROM pg_proc WHERE proname = 'crediter_penalite_sycapay';
-- ─────────────────────────────────────────────────────────────────────────────
