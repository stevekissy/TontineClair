-- =============================================================================
-- Migration : table sycapay_transactions
-- Exécuter dans Supabase SQL Editor (une seule fois)
-- Rend le workflow SycaPay idempotent et traçable
-- =============================================================================

-- 1. Créer la table de suivi des transactions SycaPay
CREATE TABLE IF NOT EXISTS public.sycapay_transactions (
  id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tontine_code            text        NOT NULL,               -- code de la tontine
  type_operation          text        NOT NULL DEFAULT 'cotisation', -- 'cotisation' | 'caisse'
  internal_reference      text        NOT NULL UNIQUE,        -- numcommande généré par l'app (TC_...)
  provider_transaction_id text,                               -- transactionId retourné par SycaPay
  phone_number_masked      text,                               -- ex: "07****8901"
  amount                  integer     NOT NULL,               -- montant en XOF
  currency                text        NOT NULL DEFAULT 'XOF',
  operator                text,                               -- orange | moov | mtn | wave
  status                  text        NOT NULL DEFAULT 'pending',
    -- pending | confirmed | failed | expired | credited
  membre_id               text,                               -- id du membre (cotisation)
  description             text,                               -- libellé (caisse)
  created_at              timestamptz NOT NULL DEFAULT now(),
  confirmed_at            timestamptz,                        -- quand SycaPay a confirmé
  credited_at             timestamptz,                        -- quand la caisse/cotisation a été créditée
  webhook_received_at     timestamptz,                        -- quand le webhook est arrivé
  webhook_payload         jsonb,                              -- payload complet du webhook (sécurisé)
  polling_attempts        integer     NOT NULL DEFAULT 0,     -- nombre de vérifications de statut
  error_message           text,                               -- message d'erreur si échec
  CONSTRAINT valid_status CHECK (
    status IN ('pending','confirmed','failed','expired','credited','cancelled')
  ),
  CONSTRAINT valid_operation CHECK (
    type_operation IN ('cotisation','caisse')
  )
);

-- 2. Index pour les recherches fréquentes
CREATE INDEX IF NOT EXISTS idx_sycapay_txn_reference
  ON public.sycapay_transactions(internal_reference);

CREATE INDEX IF NOT EXISTS idx_sycapay_txn_status
  ON public.sycapay_transactions(status)
  WHERE status IN ('pending','confirmed');

CREATE INDEX IF NOT EXISTS idx_sycapay_txn_tontine
  ON public.sycapay_transactions(tontine_code, status);

CREATE INDEX IF NOT EXISTS idx_sycapay_txn_provider_id
  ON public.sycapay_transactions(provider_transaction_id)
  WHERE provider_transaction_id IS NOT NULL;

-- 3. RLS : accès via anon key (l'Edge Function utilise le service role)
ALTER TABLE public.sycapay_transactions ENABLE ROW LEVEL SECURITY;

-- Permettre la lecture par l'anon key (pour que Flutter puisse vérifier les pending)
CREATE POLICY "anon_select_transactions"
  ON public.sycapay_transactions FOR SELECT
  TO anon, authenticated
  USING (true);

-- Les insertions/mises à jour se font via l'Edge Function (service role) uniquement
-- Pas de policy INSERT/UPDATE pour anon → sécurité

-- 4. Fonction RPC pour créer une transaction de manière idempotente
CREATE OR REPLACE FUNCTION public.creer_transaction_sycapay(
  p_tontine_code       text,
  p_type_operation     text,
  p_internal_reference text,
  p_amount             integer,
  p_currency           text,
  p_operator           text,
  p_phone_masked       text,
  p_membre_id          text DEFAULT NULL,
  p_description        text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_id uuid;
  v_existing_id uuid;
  v_existing_status text;
BEGIN
  -- Vérifier si la référence existe déjà (idempotence)
  SELECT id, status INTO v_existing_id, v_existing_status
  FROM public.sycapay_transactions
  WHERE internal_reference = p_internal_reference;

  IF FOUND THEN
    -- Si déjà créditée → erreur double paiement
    IF v_existing_status = 'credited' THEN
      RAISE EXCEPTION 'DEJA_CREDITE: transaction % déjà créditée', p_internal_reference;
    END IF;
    -- Sinon retourner l'id existant
    RETURN v_existing_id;
  END IF;

  -- Créer la transaction
  INSERT INTO public.sycapay_transactions (
    tontine_code, type_operation, internal_reference,
    amount, currency, operator, phone_number_masked,
    membre_id, description, status
  ) VALUES (
    p_tontine_code, p_type_operation, p_internal_reference,
    p_amount, p_currency, p_operator, p_phone_masked,
    p_membre_id, p_description, 'pending'
  ) RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

-- 5. Fonction RPC pour récupérer les transactions pending d'une tontine
CREATE OR REPLACE FUNCTION public.get_pending_sycapay_transactions(
  p_tontine_code text
) RETURNS TABLE(
  id                     uuid,
  internal_reference     text,
  provider_transaction_id text,
  amount                 integer,
  operator               text,
  type_operation         text,
  membre_id              text,
  description            text,
  created_at             timestamptz,
  polling_attempts       integer
)
LANGUAGE sql SECURITY DEFINER AS $$
  SELECT
    id, internal_reference, provider_transaction_id,
    amount, operator, type_operation, membre_id,
    description, created_at, polling_attempts
  FROM public.sycapay_transactions
  WHERE tontine_code = p_tontine_code
    AND status = 'pending'
    -- Ne pas récupérer les très anciennes (> 24h)
    AND created_at > now() - interval '24 hours'
  ORDER BY created_at DESC;
$$;

GRANT EXECUTE ON FUNCTION public.creer_transaction_sycapay TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_pending_sycapay_transactions TO anon, authenticated;

-- 6. Message de confirmation
DO $$ BEGIN
  RAISE NOTICE 'Table sycapay_transactions créée avec succès. Workflow SycaPay idempotent activé.';
END $$;
