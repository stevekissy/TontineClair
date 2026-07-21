-- ─────────────────────────────────────────────────────────────────────────────
-- coinpayments_setup.sql
--
-- Migration Supabase pour l'intégration CoinPayments.
-- Miroir de security_sycapay_v5.sql adapté au prestataire CoinPayments.
--
-- Ce fichier crée :
--   1. Table coinpayments_transactions   (miroir de sycapay_transactions)
--   2. Table coinpayments_audit_log      (miroir de sycapay_audit_log)
--   3. Index de performance
--   4. Row Level Security (RLS)
--   5. Contraintes UNIQUE anti-double-crédit
--
-- IMPORTANT — Sécurité des RPCs :
--   Les fonctions crediter_*_sycapay sont déjà sécurisées (REVOKE FROM PUBLIC)
--   dans security_sycapay_v5.sql. CoinPayments réutilise ces mêmes RPCs via
--   p_operateur='coinpayments' — aucun nouveau RPC à sécuriser.
--
-- Prérequis :
--   - security_sycapay_v5.sql appliqué (RPCs crediter_* déjà REVOQUÉS)
--   - Extension pgcrypto activée (normalement déjà le cas)
-- ─────────────────────────────────────────────────────────────────────────────

-- ════════════════════════════════════════════════════════════════════════════
-- ÉTAPE 1 : Table coinpayments_transactions
-- Enregistre chaque transaction CoinPayments initiée depuis l'app.
-- Statuts : pending → processing → confirmed → credited
--                  ↘ cancelled (status=-1)
--                  ↘ failed
-- ════════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS public.coinpayments_transactions (
  -- Clé primaire
  id                        bigserial   PRIMARY KEY,

  -- Références de la transaction
  internal_reference        text        NOT NULL UNIQUE,  -- Notre ref : TCP_CODE_MID_TS
  provider_transaction_id   text        UNIQUE,           -- txn_id CoinPayments (ex: CPABCDEF1234)
  checkout_url              text,                         -- URL paiement retournée à Flutter

  -- Contexte tontine / opération
  tontine_code              text        NOT NULL,
  type_operation            text        NOT NULL DEFAULT 'cotisation',
                                        -- 'cotisation'|'caisse'|'penalite'|'remboursement_pret'|'pret_octroye'

  -- Montant et devise
  amount                    integer     NOT NULL CHECK (amount > 0),  -- XOF (entier)
  currency                  text        NOT NULL DEFAULT 'XOF',
  currency2                 text        NOT NULL DEFAULT 'USDT.TRC20',  -- crypto choisie
                                        -- 'USDT.TRC20'|'USDT.ERC20'|'BTC'|'ETH'|'LTC'

  -- Acteurs
  membre_id                 text,
  membre_nom                text,
  pret_id                   text,       -- pour remboursement_pret / pret_octroye

  -- Statut de la transaction
  status                    text        NOT NULL DEFAULT 'pending'
                                        CHECK (status IN (
                                          'pending',      -- en attente fonds acheteur
                                          'processing',   -- pièces reçues, confirming
                                          'confirmed',    -- status=100, vérifié via get_tx_info
                                          'credited',     -- crédité en DB Supabase (final)
                                          'cancelled',    -- annulé (status=-1)
                                          'failed'        -- échec technique
                                        )),

  -- Horodatage des transitions
  created_at                timestamptz NOT NULL DEFAULT now(),
  confirmed_at              timestamptz,     -- quand status=100 reçu
  credited_at               timestamptz,     -- quand crédit DB effectué
  ipn_received_at           timestamptz,     -- quand IPN CoinPayments reçu

  -- Métadonnées CoinPayments
  cp_timeout                integer,         -- durée de vie tx en secondes (défaut 7200)
  description               text,

  -- Diagnostic
  polling_attempts          integer     DEFAULT 0,
  error_message             text
);

-- Commentaire table
COMMENT ON TABLE public.coinpayments_transactions IS
  'Transactions CoinPayments (crypto). '
  'Miroir de sycapay_transactions. '
  'internal_reference format : TCP_[CODE]_[MEMBRE_ID]_[TIMESTAMP]. '
  'status=credited = crédit DB effectué via RPC crediter_*_sycapay (p_operateur=''coinpayments'').';

-- Commentaires colonnes
COMMENT ON COLUMN public.coinpayments_transactions.internal_reference IS
  'Référence interne unique. Format: TCP_CODE_MEMBID_TIMESTAMP (TCP = TontineClair CoinPayments)';
COMMENT ON COLUMN public.coinpayments_transactions.provider_transaction_id IS
  'txn_id retourné par create_transaction CoinPayments';
COMMENT ON COLUMN public.coinpayments_transactions.currency2 IS
  'Cryptomonnaie choisie par le membre: USDT.TRC20 | USDT.ERC20 | BTC | ETH | LTC';
COMMENT ON COLUMN public.coinpayments_transactions.status IS
  'Cycle de vie: pending→processing→confirmed→credited (ou cancelled/failed)';
COMMENT ON COLUMN public.coinpayments_transactions.credited_at IS
  'Horodatage du crédit effectif. Non null = transaction finalisée avec succès.';


-- ════════════════════════════════════════════════════════════════════════════
-- ÉTAPE 2 : Index de performance
-- ════════════════════════════════════════════════════════════════════════════

-- Recherche par référence interne (requête principale)
CREATE INDEX IF NOT EXISTS coinpayments_transactions_internal_ref_idx
  ON public.coinpayments_transactions (internal_reference);

-- Recherche par txn_id CoinPayments (polling, webhook IPN)
CREATE INDEX IF NOT EXISTS coinpayments_transactions_provider_tx_id_idx
  ON public.coinpayments_transactions (provider_transaction_id)
  WHERE provider_transaction_id IS NOT NULL;

-- Filtrage par statut (dashboard admin)
CREATE INDEX IF NOT EXISTS coinpayments_transactions_status_idx
  ON public.coinpayments_transactions (status);

-- Filtrage par tontine (liste des transactions par tontine)
CREATE INDEX IF NOT EXISTS coinpayments_transactions_tontine_code_idx
  ON public.coinpayments_transactions (tontine_code);

-- Transactions en cours (toutes sauf credited/cancelled/failed) — pour monitoring
CREATE INDEX IF NOT EXISTS coinpayments_transactions_pending_idx
  ON public.coinpayments_transactions (status, created_at DESC)
  WHERE status IN ('pending', 'processing', 'confirmed');

-- Transactions créditées (pour rapports) — filtre partiel
CREATE INDEX IF NOT EXISTS coinpayments_transactions_credited_idx
  ON public.coinpayments_transactions (credited_at DESC)
  WHERE status = 'credited';


-- ════════════════════════════════════════════════════════════════════════════
-- ÉTAPE 3 : Table coinpayments_audit_log (journal immuable)
-- Enregistre chaque transition de statut pour traçabilité complète.
-- ════════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS public.coinpayments_audit_log (
  id                  bigserial   PRIMARY KEY,

  -- Référence pivot
  internal_reference  text        NOT NULL,   -- TCP_... (correspond à coinpayments_transactions)

  -- Transition de statut
  ancien_statut       text,
  nouveau_statut      text        NOT NULL,

  -- Source de l'événement
  source              text        NOT NULL,
                      -- 'CREATE'     : création via creer_transaction
                      -- 'POLLING'    : vérification depuis confirmer_et_crediter
                      -- 'WEBHOOK'    : IPN CoinPayments
                      -- 'IDEMPOTENT' : transaction déjà créditée (aucune action)

  -- Données de l'API CoinPayments (pour audit)
  reponse_api         jsonb,      -- Réponse brute get_tx_info ou create_transaction

  -- Résultat
  erreur              text,       -- Message d'erreur si échec

  -- Horodatage
  created_at          timestamptz NOT NULL DEFAULT now()
);

-- Commentaire
COMMENT ON TABLE public.coinpayments_audit_log IS
  'Journal d''audit immuable des transitions de statut CoinPayments. '
  'Append-only : toute modification de ligne est interdite via RLS. '
  'Miroir de sycapay_audit_log.';

-- Index
CREATE INDEX IF NOT EXISTS coinpayments_audit_log_internal_ref_idx
  ON public.coinpayments_audit_log (internal_reference);

CREATE INDEX IF NOT EXISTS coinpayments_audit_log_created_at_idx
  ON public.coinpayments_audit_log (created_at DESC);


-- ════════════════════════════════════════════════════════════════════════════
-- ÉTAPE 4 : Row Level Security (RLS)
-- Même politique que sycapay_transactions :
--   - anon / authenticated : lecture avec filtre tontine si nécessaire
--   - service_role (Edge Function) : écriture totale (bypass RLS)
-- ════════════════════════════════════════════════════════════════════════════

-- ── coinpayments_transactions ─────────────────────────────────────────────

ALTER TABLE public.coinpayments_transactions ENABLE ROW LEVEL SECURITY;

-- Lecture : membres authentifiés voient toutes les transactions
-- (à restreindre avec auth.uid() et membres de la tontine si nécessaire)
CREATE POLICY "cp_tx_read_authenticated" ON public.coinpayments_transactions
  FOR SELECT TO authenticated
  USING (true);

-- Écriture : UNIQUEMENT le service_role (Edge Function)
-- anon et authenticated ne peuvent ni insérer, ni modifier, ni supprimer
-- (service_role bypass RLS implicitement — ces politiques bloquent les autres)

CREATE POLICY "cp_tx_insert_service_only" ON public.coinpayments_transactions
  FOR INSERT TO anon, authenticated
  WITH CHECK (false);

CREATE POLICY "cp_tx_update_service_only" ON public.coinpayments_transactions
  FOR UPDATE TO anon, authenticated
  USING (false);

CREATE POLICY "cp_tx_delete_service_only" ON public.coinpayments_transactions
  FOR DELETE TO anon, authenticated
  USING (false);


-- ── coinpayments_audit_log ────────────────────────────────────────────────

ALTER TABLE public.coinpayments_audit_log ENABLE ROW LEVEL SECURITY;

-- Lecture : authentifié peut consulter les logs
CREATE POLICY "cp_audit_read_authenticated" ON public.coinpayments_audit_log
  FOR SELECT TO authenticated
  USING (true);

-- Écriture : UNIQUEMENT service_role (Edge Function)
CREATE POLICY "cp_audit_insert_service_only" ON public.coinpayments_audit_log
  FOR INSERT TO anon, authenticated
  WITH CHECK (false);

CREATE POLICY "cp_audit_update_service_only" ON public.coinpayments_audit_log
  FOR UPDATE TO anon, authenticated
  USING (false);

-- Suppression interdite pour tout le monde (sauf superuser)
CREATE POLICY "cp_audit_delete_nobody" ON public.coinpayments_audit_log
  FOR DELETE TO anon, authenticated, service_role
  USING (false);


-- ════════════════════════════════════════════════════════════════════════════
-- ÉTAPE 5 : Contraintes UNIQUE anti-double-crédit
-- Garantit qu'une internal_reference ne peut jamais être créditée deux fois,
-- même en cas de race condition ou de replay d'IPN.
-- ════════════════════════════════════════════════════════════════════════════

DO $$
BEGIN
  -- Contrainte UNIQUE sur internal_reference (déjà dans la définition mais on s'assure)
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.table_constraints
    WHERE table_schema = 'public'
      AND table_name   = 'coinpayments_transactions'
      AND constraint_name = 'coinpayments_transactions_internal_reference_key'
  ) THEN
    ALTER TABLE public.coinpayments_transactions
      ADD CONSTRAINT coinpayments_transactions_internal_reference_key
      UNIQUE (internal_reference);
  END IF;

  -- Contrainte UNIQUE sur provider_transaction_id (un txn_id CoinPayments = une seule transaction)
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.table_constraints
    WHERE table_schema = 'public'
      AND table_name   = 'coinpayments_transactions'
      AND constraint_name = 'coinpayments_transactions_provider_tx_id_key'
  ) THEN
    -- Index unique partiel (NULL exclus pour éviter les conflits sur txn_id null)
    CREATE UNIQUE INDEX IF NOT EXISTS coinpayments_transactions_provider_tx_id_unique_idx
      ON public.coinpayments_transactions (provider_transaction_id)
      WHERE provider_transaction_id IS NOT NULL;
  END IF;
END $$;


-- ════════════════════════════════════════════════════════════════════════════
-- ÉTAPE 6 : Note sécurité RPCs
-- Les RPCs crediter_*_sycapay sont DÉJÀ sécurisés (REVOKE FROM PUBLIC) par
-- security_sycapay_v5.sql. CoinPayments les réutilise avec p_operateur='coinpayments'.
-- Aucun nouveau REVOKE nécessaire — la sécurité est héritée.
-- ════════════════════════════════════════════════════════════════════════════

-- Vérification que les REVOKEs SycaPay sont en place (informatif, pas d'erreur)
DO $$
DECLARE
  v_count integer;
BEGIN
  SELECT count(*) INTO v_count
  FROM information_schema.routine_privileges
  WHERE routine_schema = 'public'
    AND routine_name   IN (
      'crediter_cotisation_sycapay',
      'crediter_caisse_sycapay',
      'crediter_penalite_sycapay',
      'crediter_remboursement_sycapay',
      'debiter_pret_sycapay'
    )
    AND grantee IN ('anon', 'authenticated')
    AND privilege_type = 'EXECUTE';

  IF v_count > 0 THEN
    RAISE WARNING
      '[coinpayments_setup] ⚠️  % RPC(s) crediter_* encore accessibles par anon/authenticated. '
      'Vérifiez que security_sycapay_v5.sql a bien été appliqué.',
      v_count;
  ELSE
    RAISE NOTICE
      '[coinpayments_setup] ✅ RPCs crediter_* correctement sécurisés (REVOKE confirmé).';
  END IF;
END $$;


-- ════════════════════════════════════════════════════════════════════════════
-- ÉTAPE 7 : Vue de monitoring (optionnel — utile pour le dashboard admin)
-- ════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE VIEW public.v_coinpayments_resume AS
SELECT
  status,
  currency2,
  type_operation,
  count(*)                                    AS nb_transactions,
  sum(amount)                                 AS total_xof,
  min(created_at)                             AS premiere_tx,
  max(created_at)                             AS derniere_tx,
  count(*) FILTER (WHERE credited_at IS NOT NULL) AS nb_creditees
FROM public.coinpayments_transactions
GROUP BY status, currency2, type_operation
ORDER BY status, currency2, type_operation;

COMMENT ON VIEW public.v_coinpayments_resume IS
  'Vue de monitoring des transactions CoinPayments par statut / crypto / opération.';


-- ════════════════════════════════════════════════════════════════════════════
-- RÉSUMÉ DE LA MIGRATION
-- ════════════════════════════════════════════════════════════════════════════
--
-- Tables créées :
--   ✅ coinpayments_transactions   — log des tx CoinPayments (statut, montant, etc.)
--   ✅ coinpayments_audit_log      — journal immuable des transitions de statut
--
-- Sécurité :
--   ✅ RLS activé sur les deux tables
--   ✅ INSERT / UPDATE / DELETE bloqués pour anon et authenticated
--   ✅ Seul service_role (Edge Function) peut écrire
--   ✅ UNIQUE sur internal_reference + provider_transaction_id (anti-double-crédit)
--   ✅ RPCs crediter_*_sycapay déjà sécurisés par security_sycapay_v5.sql
--
-- Variables d'environnement à configurer dans Supabase Dashboard :
--   → COINPAYMENTS_PUBLIC_KEY      : clé publique API CoinPayments
--   → COINPAYMENTS_PRIVATE_KEY     : clé privée HMAC-SHA512
--   → COINPAYMENTS_IPN_SECRET      : secret IPN (pour valider les webhooks)
--   → SUPABASE_URL                 : auto-injecté par Supabase
--   → SUPABASE_SERVICE_ROLE_KEY    : auto-injecté par Supabase
-- ─────────────────────────────────────────────────────────────────────────────
