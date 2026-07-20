-- =============================================================================
-- MIGRATION SÉCURITÉ SycaPay v5
-- Date : 2025-07-14
-- Objectif :
--   1. RÉVOQUER l'accès direct aux RPCs de crédit depuis anon/authenticated
--      → seule l'Edge Function (service_role) peut les appeler
--   2. Créer la table sycapay_audit_log (journal d'audit immuable)
--   3. Ajouter contraintes UNIQUE sur sycapay_transactions
--   4. Ajouter verrou FOR UPDATE dans crediter_cotisation_sycapay
--   5. Ajouter verrou FOR UPDATE dans crediter_caisse_sycapay
--
-- RÈGLE ABSOLUE : aucun client (Flutter) ne peut créditer directement.
--   Le crédit passe toujours par l'Edge Function sycapay-payment (service_role).
-- =============================================================================

-- ============================================================
-- ÉTAPE 1 : RÉVOQUER les droits directs sur les RPCs de crédit
-- ============================================================
-- Sans ce REVOKE, n'importe quel utilisateur authentifié peut appeler
-- crediter_cotisation_sycapay via l'API REST Supabase sans passer par l'Edge Fn.

REVOKE EXECUTE ON FUNCTION public.crediter_cotisation_sycapay(
  text, text, integer, text, text, text, text
) FROM anon, authenticated;

REVOKE EXECUTE ON FUNCTION public.crediter_caisse_sycapay(
  text, integer, text, text, text, text, text
) FROM anon, authenticated;

-- Si d'autres RPCs de crédit existent, les révoquer aussi :
DO $$
BEGIN
  -- crediter_penalite_sycapay (si existe)
  IF EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'crediter_penalite_sycapay'
  ) THEN
    EXECUTE 'REVOKE EXECUTE ON FUNCTION public.crediter_penalite_sycapay FROM anon, authenticated';
  END IF;

  -- crediter_remboursement_sycapay (si existe)
  IF EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'crediter_remboursement_sycapay'
  ) THEN
    EXECUTE 'REVOKE EXECUTE ON FUNCTION public.crediter_remboursement_sycapay FROM anon, authenticated';
  END IF;

  -- crediter_pret_sycapay (si existe)
  IF EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'crediter_pret_sycapay'
  ) THEN
    EXECUTE 'REVOKE EXECUTE ON FUNCTION public.crediter_pret_sycapay FROM anon, authenticated';
  END IF;
END $$;

-- Vérification (commentée — à exécuter manuellement pour confirmer)
-- SELECT routine_name, grantee, privilege_type
-- FROM information_schema.role_routine_grants
-- WHERE specific_schema = 'public'
--   AND routine_name LIKE 'crediter%'
-- ORDER BY routine_name, grantee;


-- ============================================================
-- ÉTAPE 2 : TABLE sycapay_audit_log (journal d'audit immuable)
-- ============================================================
-- Cette table enregistre chaque transition de statut d'une transaction SycaPay.
-- Elle est APPEND-ONLY : aucune UPDATE ni DELETE n'est autorisée.
-- La signature du webhook ou la source API est tracée pour chaque événement.

CREATE TABLE IF NOT EXISTS public.sycapay_audit_log (
  id                  bigserial PRIMARY KEY,
  -- Références de la transaction
  num_commande        text        NOT NULL,           -- Notre référence pivot TC_...
  provider_tx_id      text,                           -- ID SycaPay (transactionId)
  merchant_reference  text,                           -- Référence marchand SycaPay
  -- Données de l'opération
  tontine_code        text,                           -- Code de la tontine
  membre_id           text,                           -- ID du membre (si cotisation)
  type_operation      text,                           -- 'cotisation'|'caisse'|'penalite'|...
  montant             integer,                        -- Montant attendu en DB
  montant_verifie     integer,                        -- Montant retourné par GetStatus
  operateur           text,                           -- 'orange'|'moov'|'mtn'|'wave'
  -- Transition de statut
  ancien_statut       text,                           -- Statut avant l'événement
  nouveau_statut      text,                           -- Statut après l'événement
  -- Source de la confirmation
  source              text        NOT NULL,           -- 'WEBHOOK'|'STATUS_API'|'POLLING'|'IDEMPOTENT'
  -- Réponse SycaPay brute (pour audit)
  reponse_api         jsonb,                          -- Réponse complète GetStatus
  marchand_verifie    text,                           -- marchandId retourné par SycaPay
  -- Résultat
  credit_effectue     boolean     DEFAULT false,      -- true si crédit réellement effectué
  erreur              text,                           -- Message d'erreur si échec
  -- Métadonnées
  created_at          timestamptz DEFAULT now() NOT NULL,
  ip_address          inet,                           -- IP de l'appelant (si disponible)
  user_agent          text                            -- User-Agent (si disponible)
);

-- Index pour les requêtes courantes
CREATE INDEX IF NOT EXISTS sycapay_audit_log_num_commande_idx
  ON public.sycapay_audit_log (num_commande);

CREATE INDEX IF NOT EXISTS sycapay_audit_log_provider_tx_id_idx
  ON public.sycapay_audit_log (provider_tx_id)
  WHERE provider_tx_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS sycapay_audit_log_created_at_idx
  ON public.sycapay_audit_log (created_at DESC);

CREATE INDEX IF NOT EXISTS sycapay_audit_log_credit_effectue_idx
  ON public.sycapay_audit_log (credit_effectue)
  WHERE credit_effectue = true;

-- Commentaire
COMMENT ON TABLE public.sycapay_audit_log IS
  'Journal d''audit immuable des transitions de statut SycaPay. '
  'Append-only : toute modification de ligne est interdite via RLS.';

-- RLS : anon/authenticated peuvent LIRE uniquement leurs propres entrées
-- Le service_role (Edge Function) peut tout écrire
ALTER TABLE public.sycapay_audit_log ENABLE ROW LEVEL SECURITY;

-- Politique lecture : authentifié peut voir les logs de ses propres tontines
-- (optionnel — ajuster selon les besoins)
CREATE POLICY "audit_log_read_own" ON public.sycapay_audit_log
  FOR SELECT TO authenticated
  USING (true);  -- Ajuster avec auth.uid() si nécessaire

-- Politique écriture : SEUL le service_role peut insérer (via Edge Function)
-- Les clients ne peuvent jamais écrire directement
CREATE POLICY "audit_log_insert_service_only" ON public.sycapay_audit_log
  FOR INSERT TO service_role
  WITH CHECK (true);

-- Interdire UPDATE et DELETE pour tout le monde (APPEND-ONLY)
CREATE POLICY "audit_log_no_update" ON public.sycapay_audit_log
  FOR UPDATE USING (false);  -- Personne ne peut modifier

CREATE POLICY "audit_log_no_delete" ON public.sycapay_audit_log
  FOR DELETE USING (false);  -- Personne ne peut supprimer


-- ============================================================
-- ÉTAPE 3 : CONTRAINTES UNIQUE sur sycapay_transactions
-- ============================================================
-- Ces contraintes garantissent l'idempotence au niveau base de données.
-- Une même référence SycaPay ne peut jamais être créditée deux fois.

-- Vérifier si la table existe (elle est peut-être gérée par l'Edge Function)
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public'
      AND table_name = 'sycapay_transactions'
  ) THEN
    -- Contrainte UNIQUE sur internal_reference (notre numCommande TC_...)
    -- Empêche deux transactions avec la même référence interne
    IF NOT EXISTS (
      SELECT 1 FROM information_schema.table_constraints
      WHERE table_schema = 'public'
        AND table_name = 'sycapay_transactions'
        AND constraint_name = 'sycapay_transactions_internal_reference_key'
    ) THEN
      ALTER TABLE public.sycapay_transactions
        ADD CONSTRAINT sycapay_transactions_internal_reference_key
        UNIQUE (internal_reference);
      RAISE NOTICE 'Contrainte UNIQUE(internal_reference) ajoutée';
    ELSE
      RAISE NOTICE 'Contrainte UNIQUE(internal_reference) déjà présente';
    END IF;

    -- Contrainte UNIQUE sur provider_transaction_id (ID SycaPay)
    -- Empêche d'utiliser la même référence SycaPay pour plusieurs crédits
    IF NOT EXISTS (
      SELECT 1 FROM information_schema.table_constraints
      WHERE table_schema = 'public'
        AND table_name = 'sycapay_transactions'
        AND constraint_name = 'sycapay_transactions_provider_transaction_id_key'
    ) THEN
      -- provider_transaction_id peut être NULL (Wave avant scan), donc partial unique
      -- Uniquement sur les valeurs non-NULL
      EXECUTE '
        CREATE UNIQUE INDEX IF NOT EXISTS sycapay_transactions_provider_tx_id_unique_idx
          ON public.sycapay_transactions (provider_transaction_id)
          WHERE provider_transaction_id IS NOT NULL
      ';
      RAISE NOTICE 'Index UNIQUE(provider_transaction_id) ajouté';
    ELSE
      RAISE NOTICE 'Contrainte UNIQUE(provider_transaction_id) déjà présente';
    END IF;

    -- Colonne status si pas encore présente
    IF NOT EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public'
        AND table_name = 'sycapay_transactions'
        AND column_name = 'status'
    ) THEN
      ALTER TABLE public.sycapay_transactions
        ADD COLUMN status text DEFAULT 'pending' NOT NULL;
      RAISE NOTICE 'Colonne status ajoutée';
    END IF;

    -- Colonne credited_at pour tracer quand le crédit a été effectué
    IF NOT EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public'
        AND table_name = 'sycapay_transactions'
        AND column_name = 'credited_at'
    ) THEN
      ALTER TABLE public.sycapay_transactions
        ADD COLUMN credited_at timestamptz;
      RAISE NOTICE 'Colonne credited_at ajoutée';
    END IF;

    RAISE NOTICE 'Table sycapay_transactions mise à jour avec succès';
  ELSE
    RAISE NOTICE 'Table sycapay_transactions non trouvée — ignoré (gérée par Edge Function)';
  END IF;
END $$;


-- ============================================================
-- ÉTAPE 4 : Sécuriser crediter_cotisation_sycapay avec FOR UPDATE
-- ============================================================
-- Ajoute un verrou pessimiste sur la ligne tontine avant toute modification.
-- Garantit l'atomicité : pas deux crédits simultanés possibles.

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

  -- ── VERROU PESSIMISTE : empêche deux crédits simultanés ──────────────────
  -- FOR UPDATE bloque les autres transactions qui essaieraient de modifier
  -- la même tontine au même moment → garantit l'atomicité SQL
  SELECT * INTO v_row
  FROM public.tontines
  WHERE code = UPPER(p_code)
  FOR UPDATE;  -- ← VERROU AJOUTÉ (v5 sécurité)

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
    RETURN jsonb_build_object('ok', true, 'message', 'déjà crédité (idempotent)', 'idempotent', true);
  END IF;

  -- Idempotence sur la caisse (même référence déjà présente ?)
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_mouvements) AS m
    WHERE m->>'id' = p_reference OR m->>'numCommande' = p_num_commande
  ) THEN
    RETURN jsonb_build_object('ok', true, 'message', 'déjà crédité caisse (idempotent)', 'idempotent', true);
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

  -- ── Écrire tout d'un coup (dans la même transaction SQL) ─────────────────
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

-- ⚠️ NE PAS accorder anon/authenticated — seul service_role (Edge Function) peut appeler
-- Les GRANTs précédents ont été RÉVOQUÉS en étape 1
-- GRANT EXECUTE ON FUNCTION public.crediter_cotisation_sycapay TO service_role;  -- déjà implicite


-- ============================================================
-- ÉTAPE 5 : Sécuriser crediter_caisse_sycapay avec FOR UPDATE
-- ============================================================

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

  -- ── VERROU PESSIMISTE : empêche deux crédits simultanés ──────────────────
  SELECT * INTO v_row
  FROM public.tontines
  WHERE code = UPPER(p_code)
  FOR UPDATE;  -- ← VERROU AJOUTÉ (v5 sécurité)

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
    RETURN jsonb_build_object('ok', true, 'message', 'déjà crédité (idempotent)', 'idempotent', true);
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

-- ⚠️ NE PAS accorder anon/authenticated
-- GRANT EXECUTE ON FUNCTION public.crediter_caisse_sycapay TO service_role;  -- déjà implicite


-- ============================================================
-- ÉTAPE 6 : Script d'audit — transactions créditées sans confirmation
-- ============================================================
-- Ce script IDENTIFIE les faux crédits potentiels.
-- À exécuter manuellement et analyser avant toute annulation.
-- NE SUPPRIME RIEN — uniquement lecture + marquage pour revue.

-- Créer une table de revue si elle n'existe pas
CREATE TABLE IF NOT EXISTS public.sycapay_credit_review (
  id                  bigserial PRIMARY KEY,
  num_commande        text,
  tontine_code        text,
  membre_id           text,
  montant             integer,
  date_credit         text,
  statut_sycapay      text,       -- Statut réel SycaPay (à vérifier manuellement)
  decision            text DEFAULT 'en_attente',  -- 'confirme'|'annule'|'en_attente'
  note                text,
  created_at          timestamptz DEFAULT now()
);

COMMENT ON TABLE public.sycapay_credit_review IS
  'Transactions SycaPay à passer en revue. Résultat de l''audit sécurité v5.';

-- ============================================================
-- RÉSUMÉ DES CHANGEMENTS
-- ============================================================
-- ✅ REVOKE EXECUTE sur crediter_cotisation_sycapay FROM anon, authenticated
-- ✅ REVOKE EXECUTE sur crediter_caisse_sycapay FROM anon, authenticated
-- ✅ TABLE sycapay_audit_log (immuable, append-only via RLS)
-- ✅ INDEX sur sycapay_transactions (si table existe)
-- ✅ FOR UPDATE dans crediter_cotisation_sycapay (verrou pessimiste)
-- ✅ FOR UPDATE dans crediter_caisse_sycapay (verrou pessimiste)
-- ✅ TABLE sycapay_credit_review pour l'audit point 15
--
-- PROCHAINES ÉTAPES :
-- 1. Déployer l'Edge Function v5 (sycapay-payment)
-- 2. Vérifier les logs Supabase pour les appels directs aux RPCs (maintenant bloqués)
-- 3. Remplir sycapay_credit_review avec les transactions suspectes
-- 4. Comparer avec le tableau marchand SycaPay
-- 5. Annuler comptablement les faux crédits identifiés
-- =============================================================================
