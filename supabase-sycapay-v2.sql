-- =============================================================================
-- Migration v2 : sycapay_transactions + RPCs de crédit serveur-side
-- À exécuter dans Supabase SQL Editor (remplace v1 si déjà exécuté)
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Table sycapay_transactions (v2)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.sycapay_transactions (
  id                       uuid        PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Identification tontine
  tontine_code             text        NOT NULL,
  type_operation           text        NOT NULL DEFAULT 'cotisation',

  -- Références
  internal_reference       text        NOT NULL UNIQUE,  -- numcommande TC_...
  sycapay_reference        text,                         -- ref SycaPay (souvent = numcommande)
  provider_transaction_id  text,                         -- transactionId interne SycaPay

  -- Payer
  user_id                  text,                         -- id utilisateur Flutter (si dispo)
  phone_number_masked       text,
  amount                   integer     NOT NULL,
  currency                 text        NOT NULL DEFAULT 'XOF',
  operator                 text,

  -- Statut
  status                   text        NOT NULL DEFAULT 'pending',
  --  pending | confirmed | failed | expired | credited | cancelled

  -- Membres
  membre_id                text,
  description              text,

  -- Timestamps
  created_at               timestamptz NOT NULL DEFAULT now(),
  confirmed_at             timestamptz,
  credited_at              timestamptz,
  webhook_received_at      timestamptz,

  -- Données complémentaires
  webhook_payload          jsonb,
  polling_attempts         integer     NOT NULL DEFAULT 0,
  error_message            text,

  -- Contraintes
  CONSTRAINT valid_status    CHECK (status    IN ('pending','confirmed','failed','expired','credited','cancelled')),
  CONSTRAINT valid_operation CHECK (type_operation IN ('cotisation','caisse'))
);

-- Ajouter les colonnes manquantes si table v1 existe déjà
ALTER TABLE public.sycapay_transactions
  ADD COLUMN IF NOT EXISTS sycapay_reference   text,
  ADD COLUMN IF NOT EXISTS user_id             text;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. Index
-- ─────────────────────────────────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_sycapay_txn_reference   ON public.sycapay_transactions(internal_reference);
CREATE INDEX IF NOT EXISTS idx_sycapay_txn_status      ON public.sycapay_transactions(status) WHERE status IN ('pending','confirmed');
CREATE INDEX IF NOT EXISTS idx_sycapay_txn_tontine     ON public.sycapay_transactions(tontine_code, status);
CREATE INDEX IF NOT EXISTS idx_sycapay_txn_provider_id ON public.sycapay_transactions(provider_transaction_id) WHERE provider_transaction_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_sycapay_txn_membre      ON public.sycapay_transactions(membre_id) WHERE membre_id IS NOT NULL;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. RLS
-- ─────────────────────────────────────────────────────────────────────────────
ALTER TABLE public.sycapay_transactions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "anon_select_transactions" ON public.sycapay_transactions;
CREATE POLICY "anon_select_transactions"
  ON public.sycapay_transactions FOR SELECT
  TO anon, authenticated
  USING (true);

-- Les écritures viennent exclusivement de l'Edge Function (service role) → pas de policy INSERT/UPDATE anon

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. RPC : crediter_caisse_sycapay
-- Crédite la caisse d'une tontine avec un apport SycaPay.
-- Appelé par l'Edge Function (SECURITY DEFINER → bypass RLS).
-- ─────────────────────────────────────────────────────────────────────────────
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
  v_row       record;
  v_data      jsonb;
  v_caisse    jsonb;
  v_mouvements jsonb;
  v_journal   jsonb;
  v_now       text;
  v_mouvement jsonb;
  v_entry     jsonb;
BEGIN
  v_now := COALESCE(p_now, now()::text);

  -- Lire la tontine
  SELECT * INTO v_row
  FROM public.tontines
  WHERE code = UPPER(p_code);

  IF NOT FOUND THEN
    RAISE EXCEPTION 'TONTINE_INTROUVABLE: %', p_code;
  END IF;

  v_data := v_row.data;

  -- Lire ou initialiser la caisse
  v_caisse     := COALESCE(v_data->'caisse', '{}'::jsonb);
  v_mouvements := COALESCE(v_caisse->'mouvements', '[]'::jsonb);
  v_journal    := COALESCE(v_data->'journal', '[]'::jsonb);

  -- Vérifier l'idempotence : même référence déjà présente dans mouvements ?
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_mouvements) AS m
    WHERE m->>'id' = p_reference OR m->>'numCommande' = p_num_commande
  ) THEN
    RETURN jsonb_build_object('ok', true, 'message', 'déjà crédité (idempotent)');
  END IF;

  -- Construire le mouvement
  v_mouvement := jsonb_build_object(
    'id',            p_reference,
    'type',          'apport',
    'montant',       p_montant,
    'description',   p_description,
    'gestionnaire',  'SycaPay',
    'date',          v_now,
    'reference',     p_reference,
    'methode',       'sycapay',
    'operateur',     p_operateur,
    'numCommande',   p_num_commande
  );

  -- Construire l'entrée journal
  v_entry := jsonb_build_object(
    'quoi', 'APPORT CAISSE via SycaPay (' || UPPER(p_operateur) || ') — ' || p_montant::text || ' XOF' ||
            CASE WHEN p_description <> '' THEN ' — ' || p_description ELSE '' END,
    'par',  'SycaPay',
    'le',   (EXTRACT(EPOCH FROM now()) * 1000)::bigint,
    'ref',  p_reference
  );

  -- Injecter dans le JSON
  v_mouvements := v_mouvements || jsonb_build_array(v_mouvement);
  v_caisse     := v_caisse || jsonb_build_object('mouvements', v_mouvements);
  v_journal    := jsonb_build_array(v_entry) || v_journal; -- journal en tête
  v_data       := v_data
                  || jsonb_build_object('caisse',  v_caisse)
                  || jsonb_build_object('journal', v_journal);

  -- Écrire la tontine
  UPDATE public.tontines
  SET data = v_data, modifie_le = now()
  WHERE code = UPPER(p_code);

  RETURN jsonb_build_object('ok', true, 'message', 'caisse créditée');
EXCEPTION WHEN OTHERS THEN
  RAISE EXCEPTION 'crediter_caisse_sycapay: % %', SQLSTATE, SQLERRM;
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. RPC : crediter_cotisation_sycapay
-- Marque la cotisation d'un membre comme payée.
-- ─────────────────────────────────────────────────────────────────────────────
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
  v_row      record;
  v_data     jsonb;
  v_membres  jsonb;
  v_membre   jsonb;
  v_i        int;
  v_journal  jsonb;
  v_now      text;
  v_cotisations jsonb;
  v_cotis    jsonb;
  v_found    boolean := false;
  v_entry    jsonb;
BEGIN
  v_now := COALESCE(p_now, now()::text);

  SELECT * INTO v_row
  FROM public.tontines
  WHERE code = UPPER(p_code);

  IF NOT FOUND THEN
    RAISE EXCEPTION 'TONTINE_INTROUVABLE: %', p_code;
  END IF;

  v_data    := v_row.data;
  v_membres := COALESCE(v_data->'membres', '[]'::jsonb);
  v_journal := COALESCE(v_data->'journal', '[]'::jsonb);

  -- Vérifier idempotence sur le journal
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_journal) AS j
    WHERE j->>'ref' = p_reference OR j->>'numCommande' = p_num_commande
  ) THEN
    RETURN jsonb_build_object('ok', true, 'message', 'déjà crédité (idempotent)');
  END IF;

  -- Trouver le membre et mettre à jour ses cotisations
  FOR v_i IN 0 .. jsonb_array_length(v_membres) - 1 LOOP
    v_membre := v_membres -> v_i;
    IF v_membre->>'id' = p_membre_id THEN
      -- Ajouter la cotisation dans cotisations[]
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

  -- Journal
  v_entry := jsonb_build_object(
    'quoi', 'COTISATION via SycaPay (' || UPPER(p_operateur) || ') — ' || p_montant::text || ' XOF',
    'par',  'SycaPay',
    'le',   (EXTRACT(EPOCH FROM now()) * 1000)::bigint,
    'ref',  p_reference,
    'membreId', p_membre_id
  );
  v_journal := jsonb_build_array(v_entry) || v_journal;
  v_data    := v_data
               || jsonb_build_object('membres', v_membres)
               || jsonb_build_object('journal', v_journal);

  UPDATE public.tontines
  SET data = v_data, modifie_le = now()
  WHERE code = UPPER(p_code);

  RETURN jsonb_build_object('ok', true, 'message', 'cotisation créditée');
EXCEPTION WHEN OTHERS THEN
  RAISE EXCEPTION 'crediter_cotisation_sycapay: % %', SQLSTATE, SQLERRM;
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. Grants
-- ─────────────────────────────────────────────────────────────────────────────
GRANT EXECUTE ON FUNCTION public.crediter_caisse_sycapay       TO service_role;
GRANT EXECUTE ON FUNCTION public.crediter_cotisation_sycapay   TO service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- 7. Vérification structure table tontines
-- ─────────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
  -- Vérifier que la colonne updated_at existe (sinon la RPC doit l'ignorer)
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'tontines' AND column_name = 'modifie_le'
  ) THEN
    RAISE NOTICE 'ATTENTION: La colonne modifie_le n''existe pas dans tontines. Vérifiez la structure.';
  END IF;
  RAISE NOTICE '✅ Migration sycapay v2 appliquée avec succès.';
  RAISE NOTICE '   Tables : sycapay_transactions ✓';
  RAISE NOTICE '   RPCs   : crediter_caisse_sycapay ✓  crediter_cotisation_sycapay ✓';
END $$;
