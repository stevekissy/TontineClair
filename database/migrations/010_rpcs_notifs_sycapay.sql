-- =============================================================================
-- TontineClair — Migration 010 : Notifications FCM + Transactions SycaPay
-- =============================================================================
-- Sources canoniques :
--   • supabase/migrations/001_fcm_tokens.sql     → sauvegarder_token
--   • supabase-sycapay-transactions.sql          → creer_transaction_sycapay,
--                                                   get_pending_sycapay_transactions
--   • supabase-sycapay-v2.sql                    → crediter_caisse_sycapay,
--                                                   crediter_cotisation_sycapay
--                                                   (v2 FINAL — ajoute sycapay_reference,
--                                                    user_id, membre_nom, pret_id,
--                                                    emprunteur_id)
--   • supabase-penalite-sycapay.sql              → crediter_penalite_sycapay
--   • supabase-fix-v8-periodicitee.sql           → recalculer_echeances_expir
--   • supabase-fix-v11-beneficiaire.sql          → distribuer_tour
-- =============================================================================
-- Contient :
--   RPC 1  : sauvegarder_token
--   RPC 2  : creer_transaction_sycapay
--   RPC 3  : get_pending_sycapay_transactions
--   RPC 4  : crediter_caisse_sycapay
--   RPC 5  : crediter_cotisation_sycapay
--   RPC 6  : crediter_penalite_sycapay
--   RPC 7  : recalculer_echeances_expir
--   RPC 8  : distribuer_tour
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- Dépendances : Tables créées dans les migrations précédentes
--   • fcm_tokens            (004_tables_kyc_notifs.sql)
--   • sycapay_transactions  (003_tables_financier.sql)
--   • tontines              (001_tables_core.sql)
-- ─────────────────────────────────────────────────────────────────────────────

-- =============================================================================
-- 1. COLONNES ADDITIONNELLES sycapay_transactions (v2)
-- =============================================================================
-- Colonnes ajoutées par supabase-sycapay-v2.sql et supabase-penalite-sycapay.sql
-- Idempotentes — n'échouent pas si déjà présentes.
ALTER TABLE public.sycapay_transactions
  ADD COLUMN IF NOT EXISTS sycapay_reference text,
  ADD COLUMN IF NOT EXISTS user_id           text,
  ADD COLUMN IF NOT EXISTS membre_nom        text,
  ADD COLUMN IF NOT EXISTS pret_id           text,
  ADD COLUMN IF NOT EXISTS emprunteur_id     text;

-- Index supplémentaire membre_id (v2)
CREATE INDEX IF NOT EXISTS idx_sycapay_txn_membre
  ON public.sycapay_transactions(membre_id)
  WHERE membre_id IS NOT NULL;

-- =============================================================================
-- 2. RPC : sauvegarder_token
-- =============================================================================
-- Enregistre ou met à jour le token FCM d'un appareil pour une tontine.
-- Appelée par l'app Flutter au démarrage (UPSERT idempotent).
-- Source : supabase/migrations/001_fcm_tokens.sql
-- =============================================================================
CREATE OR REPLACE FUNCTION public.sauvegarder_token(
  p_code     text,
  p_token    text,
  p_appareil text DEFAULT 'android'
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.fcm_tokens(tontine_code, token, appareil, mis_a_jour_le)
  VALUES (upper(p_code), p_token, p_appareil, now())
  ON CONFLICT (tontine_code, token)
  DO UPDATE SET
    appareil      = EXCLUDED.appareil,
    mis_a_jour_le = now();
  RETURN true;
EXCEPTION WHEN OTHERS THEN
  RETURN false;
END;
$$;

GRANT EXECUTE ON FUNCTION public.sauvegarder_token TO anon, authenticated;

-- =============================================================================
-- 3. RPC : creer_transaction_sycapay
-- =============================================================================
-- Crée une transaction SycaPay de manière idempotente.
-- Refuse si la référence est déjà 'credited' (anti-doublon paiement).
-- Source : supabase-sycapay-transactions.sql
-- =============================================================================
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
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id              uuid;
  v_existing_id     uuid;
  v_existing_status text;
BEGIN
  -- Vérifier si la référence existe déjà (idempotence)
  SELECT id, status
  INTO v_existing_id, v_existing_status
  FROM public.sycapay_transactions
  WHERE internal_reference = p_internal_reference;

  IF FOUND THEN
    -- Si déjà créditée → erreur double paiement
    IF v_existing_status = 'credited' THEN
      RAISE EXCEPTION 'DEJA_CREDITE: transaction % déjà créditée', p_internal_reference;
    END IF;
    -- Sinon retourner l'id existant (idempotent)
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

GRANT EXECUTE ON FUNCTION public.creer_transaction_sycapay TO anon, authenticated;

-- =============================================================================
-- 4. RPC : get_pending_sycapay_transactions
-- =============================================================================
-- Retourne les transactions SycaPay en attente d'une tontine.
-- Filtre les transactions de plus de 24h (expirées de facto).
-- Source : supabase-sycapay-transactions.sql
-- =============================================================================
CREATE OR REPLACE FUNCTION public.get_pending_sycapay_transactions(
  p_tontine_code text
)
RETURNS TABLE(
  id                      uuid,
  internal_reference      text,
  provider_transaction_id text,
  amount                  integer,
  operator                text,
  type_operation          text,
  membre_id               text,
  description             text,
  created_at              timestamptz,
  polling_attempts        integer
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    id,
    internal_reference,
    provider_transaction_id,
    amount,
    operator,
    type_operation,
    membre_id,
    description,
    created_at,
    polling_attempts
  FROM public.sycapay_transactions
  WHERE tontine_code = p_tontine_code
    AND status = 'pending'
    -- Ne pas récupérer les très anciennes (> 24h)
    AND created_at > now() - interval '24 hours'
  ORDER BY created_at DESC;
$$;

GRANT EXECUTE ON FUNCTION public.get_pending_sycapay_transactions TO anon, authenticated;

-- =============================================================================
-- 5. RPC : crediter_caisse_sycapay
-- =============================================================================
-- Crédite la caisse d'une tontine avec un apport SycaPay.
-- Appelée par l'Edge Function (SECURITY DEFINER → bypass RLS).
-- Idempotente : vérifie la présence de la référence dans caisse.mouvements.
-- Source : supabase-sycapay-v2.sql (FINAL)
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

  -- Idempotence : même référence déjà présente dans mouvements ?
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_mouvements) AS m
    WHERE m->>'id' = p_reference OR m->>'numCommande' = p_num_commande
  ) THEN
    RETURN jsonb_build_object('ok', true, 'message', 'déjà crédité (idempotent)');
  END IF;

  -- Construire le mouvement
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
  v_journal    := jsonb_build_array(v_entry) || v_journal;  -- journal en tête
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

GRANT EXECUTE ON FUNCTION public.crediter_caisse_sycapay TO service_role;

-- =============================================================================
-- 6. RPC : crediter_cotisation_sycapay
-- =============================================================================
-- Marque la cotisation d'un membre comme payée via SycaPay.
-- Idempotente : vérifie la référence dans journal[].ref.
-- Source : supabase-sycapay-v2.sql (FINAL)
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
  v_now         text;
  v_cotisations jsonb;
  v_cotis       jsonb;
  v_found       boolean := false;
  v_entry       jsonb;
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

  -- Idempotence sur le journal
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
    'quoi',     'COTISATION via SycaPay (' || UPPER(p_operateur) || ') — ' || p_montant::text || ' XOF',
    'par',      'SycaPay',
    'le',       (EXTRACT(EPOCH FROM now()) * 1000)::bigint,
    'ref',      p_reference,
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

GRANT EXECUTE ON FUNCTION public.crediter_cotisation_sycapay TO service_role;

-- =============================================================================
-- 7. RPC : crediter_penalite_sycapay
-- =============================================================================
-- Enregistre une pénalité SycaPay :
--   • Injecte un mouvement 'penalite' dans caisse.mouvements
--   • Incrémente membres[idx].penalites
--   • Décrémente membres[idx].score de 5 points (plancher 0)
--   • Écrit dans le journal
-- Source : supabase-penalite-sycapay.sql
-- =============================================================================
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

  -- Lire la tontine
  SELECT * INTO v_row
  FROM public.tontines
  WHERE code = UPPER(p_code);

  IF NOT FOUND THEN
    RAISE EXCEPTION 'TONTINE_INTROUVABLE: %', p_code;
  END IF;

  v_data := v_row.data;

  -- Lire caisse, journal, membres
  v_caisse     := COALESCE(v_data->'caisse', '{}'::jsonb);
  v_mouvements := COALESCE(v_caisse->'mouvements', '[]'::jsonb);
  v_journal    := COALESCE(v_data->'journal', '[]'::jsonb);
  v_membres    := COALESCE(v_data->'membres', '[]'::jsonb);

  -- Idempotence : même référence déjà présente ?
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_mouvements) AS m
    WHERE m->>'id' = p_reference OR m->>'numCommande' = p_num_commande
  ) THEN
    RETURN jsonb_build_object('ok', true, 'message', 'déjà crédité (idempotent)');
  END IF;

  -- Construire le mouvement pénalité
  v_mouvement := jsonb_build_object(
    'id',          p_reference,
    'type',        'penalite',
    'montant',     p_montant,
    'description', CASE
                     WHEN p_description <> '' THEN p_description
                     ELSE 'Pénalité — ' || COALESCE(NULLIF(p_membre_nom, ''), p_membre_id)
                   END,
    'gestionnaire','SycaPay',
    'date',        v_now,
    'reference',   p_reference,
    'methode',     'sycapay',
    'operateur',   p_operateur,
    'numCommande', p_num_commande,
    'membreId',    p_membre_id,
    'membreNom',   p_membre_nom
  );

  -- Construire l'entrée journal
  v_entry := jsonb_build_object(
    'quoi', 'PÉNALITÉ SycaPay — ' || COALESCE(NULLIF(p_membre_nom, ''), p_membre_id)
            || ' — ' || p_montant::text || ' XOF'
            || CASE WHEN p_description <> '' THEN ' — ' || p_description ELSE '' END,
    'par',  'SycaPay',
    'le',   (EXTRACT(EPOCH FROM now()) * 1000)::bigint,
    'ref',  p_reference
  );

  -- Injecter mouvement dans caisse
  v_mouvements := v_mouvements || jsonb_build_array(v_mouvement);
  v_caisse     := v_caisse || jsonb_build_object('mouvements', v_mouvements);
  v_journal    := jsonb_build_array(v_entry) || v_journal;

  -- Mettre à jour le membre pénalisé (penalites++, score−5, plancher 0)
  IF p_membre_id IS NOT NULL AND p_membre_id <> '' THEN
    FOR v_idx IN 0 .. (jsonb_array_length(v_membres) - 1) LOOP
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

  -- Assembler et écrire la tontine
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

-- =============================================================================
-- 8. RPC : recalculer_echeances_expir
-- =============================================================================
-- Recalcule et avance les échéances expirées selon la périodicité de chaque
-- tontine. Boucle jusqu'à obtenir une date future.
-- Source : supabase-fix-v8-periodicitee.sql
-- =============================================================================
CREATE OR REPLACE FUNCTION public.recalculer_echeances_expir()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_rec               record;
  v_data              jsonb;
  v_periode           text;
  v_echeance          text;
  v_nouvelle_echeance timestamptz;
  v_fixed             int := 0;
BEGIN
  FOR v_rec IN
    SELECT code, data
    FROM public.tontines
    WHERE
      -- Tontines avec une échéance définie et passée
      data->>'echeance' IS NOT NULL
      AND (data->>'echeance')::timestamptz < now()
      -- Pas terminées
      AND (data->>'cycleTermine' IS NULL OR data->>'cycleTermine' = 'false')
  LOOP
    v_data    := v_rec.data;
    v_periode := COALESCE(v_data->>'periodicite', v_data->>'periode', 'mensuel');
    v_echeance := v_data->>'echeance';

    -- Calculer la prochaine échéance depuis la date passée
    v_nouvelle_echeance := (v_echeance::timestamptz);
    LOOP
      EXIT WHEN v_nouvelle_echeance > now();
      CASE v_periode
        WHEN 'journalier'  THEN v_nouvelle_echeance := v_nouvelle_echeance + interval '1 day';
        WHEN 'hebdo'       THEN v_nouvelle_echeance := v_nouvelle_echeance + interval '7 days';
        WHEN 'mensuel'     THEN v_nouvelle_echeance := v_nouvelle_echeance + interval '1 month';
        WHEN 'bimensuel'   THEN v_nouvelle_echeance := v_nouvelle_echeance + interval '2 months';
        WHEN 'trimestriel' THEN v_nouvelle_echeance := v_nouvelle_echeance + interval '3 months';
        ELSE                    v_nouvelle_echeance := v_nouvelle_echeance + interval '1 month';
      END CASE;
    END LOOP;

    -- Mettre à jour la tontine
    UPDATE public.tontines
    SET data = data || jsonb_build_object(
      'echeance',
      to_char(v_nouvelle_echeance, 'YYYY-MM-DD"T"HH24:MI:SS".000Z"')
    )
    WHERE code = v_rec.code;

    v_fixed := v_fixed + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'mises_a_jour', v_fixed,
    'message',      v_fixed || ' échéance(s) recalculée(s).'
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.recalculer_echeances_expir TO anon, authenticated;

-- =============================================================================
-- 9. RPC : distribuer_tour
-- =============================================================================
-- Enregistre la distribution d'un tour manuellement (confirmation gestionnaire).
-- Fonctionnement :
--   • Anti-doublon : refuse si le bénéficiaire a déjà été servi dans ce cycle
--   • Calcule automatiquement montantRecu si non fourni (nb_payes × montant)
--   • Écrit dans historique[], caisse.mouvements[], journal[]
--   • Réinitialise paiements{} et membres[].paye = false pour le prochain tour
--   • Avance tourActuel et marque cycleTermine si dernier tour
-- Source : supabase-fix-v11-beneficiaire.sql (FINAL v11)
-- =============================================================================
CREATE OR REPLACE FUNCTION public.distribuer_tour(
  p_code         text,
  p_pin          text,
  p_gest         text,
  p_benef_id     text DEFAULT NULL,  -- si NULL : utilise ordre[tourActuel]
  p_montant_recu int  DEFAULT NULL   -- si NULL : calcule automatiquement
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row          tontines%ROWTYPE;
  v_data         jsonb;
  v_ordre        jsonb;
  v_tour_actuel  int;
  v_nb_tours     int;
  v_benef_id     text;
  v_benef_nom    text;
  v_montant      int;
  v_total_recu   int;
  v_nb_payes     int;
  v_paiements    jsonb;
  v_historique   jsonb;
  v_payes_ids    jsonb;
  v_est_dernier  boolean;
  v_new_tour     int;
  v_ref          text;
  v_now          text;
  v_doublons     boolean;
  v_caisse_mv    jsonb;
BEGIN
  -- Lire et vérifier la tontine
  SELECT * INTO v_row FROM public.tontines WHERE code = p_code;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Tontine introuvable');
  END IF;

  -- Vérification PIN
  IF v_row.pin_hash IS NOT NULL AND v_row.pin_hash <> crypt(p_pin, v_row.pin_hash) THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'PIN incorrect');
  END IF;

  v_data        := v_row.data;
  v_ordre       := COALESCE(v_data->'ordre', '[]'::jsonb);
  v_tour_actuel := COALESCE((v_data->>'tourActuel')::int, 0);
  v_nb_tours    := jsonb_array_length(v_ordre);
  v_montant     := COALESCE((v_data->>'montant')::int, 0);
  v_paiements   := COALESCE(v_data->'paiements', '{}'::jsonb);
  v_historique  := COALESCE(v_data->'historique', '[]'::jsonb);
  v_now         := now()::text;
  v_ref         := upper(substring(md5(random()::text) FROM 1 FOR 8));

  -- Vérifications préalables
  IF (v_data->>'cycleTermine')::boolean = true THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Le cycle est déjà terminé');
  END IF;
  IF v_nb_tours = 0 THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Aucun ordre défini');
  END IF;
  IF v_tour_actuel >= v_nb_tours THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Tous les tours ont été effectués');
  END IF;

  -- Identifier le bénéficiaire (explicite ou auto depuis ordre[])
  v_benef_id  := COALESCE(p_benef_id, v_ordre->>v_tour_actuel);
  v_benef_nom := _tc_nom_membre(v_data, v_benef_id);

  -- Anti-doublon : ce membre a-t-il déjà été servi ?
  SELECT EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_historique) h
    WHERE (h->>'beneficiaireId') = v_benef_id
  ) INTO v_doublons;

  IF v_doublons THEN
    RETURN jsonb_build_object(
      'ok',    false,
      'erreur', format('%s a déjà été servi dans ce cycle', v_benef_nom)
    );
  END IF;

  -- Calculs du tour
  SELECT COUNT(*) INTO v_nb_payes FROM jsonb_object_keys(v_paiements);
  v_total_recu  := COALESCE(p_montant_recu, v_nb_payes * v_montant);
  v_payes_ids   := (SELECT jsonb_agg(k) FROM jsonb_object_keys(v_paiements) k);
  v_est_dernier := (v_tour_actuel + 1) >= v_nb_tours;
  v_new_tour    := CASE WHEN v_est_dernier THEN v_tour_actuel ELSE v_tour_actuel + 1 END;

  -- Entrée historique
  v_historique := jsonb_build_array(
    jsonb_build_object(
      'tour',            v_tour_actuel + 1,
      'beneficiaireId',  v_benef_id,
      'beneficiaire',    v_benef_nom,
      'beneficiaireNom', v_benef_nom,
      'montantRecu',     v_total_recu,
      'totalRecu',       v_total_recu,
      'totalAttendu',    v_nb_tours * v_montant,
      'nbPayes',         v_nb_payes,
      'payesIds',        COALESCE(v_payes_ids, '[]'::jsonb),
      'statut',          'Distribué',
      'date',            v_now,
      'closLe',          v_now,
      'reference',       v_ref
    )
  ) || v_historique;

  -- Mise à jour data principale
  v_data := v_data || jsonb_build_object(
    'tourActuel',   v_new_tour,
    'cycleTermine', v_est_dernier,
    'paiements',    '{}'::jsonb,
    'historique',   v_historique
  );

  -- Reset paye de tous les membres pour le prochain tour
  v_data := jsonb_set(v_data, '{membres}', (
    SELECT jsonb_agg(m || '{"paye":false,"datePaiement":null,"methodePaiement":null}')
    FROM jsonb_array_elements(COALESCE(v_data->'membres', '[]'::jsonb)) m
  ));

  -- Mouvement caisse : distribution
  v_caisse_mv := jsonb_build_object(
    'id',          v_ref || 'D',
    'type',        'distribution',
    'montant',     -v_total_recu,
    'description', format('Distribution Tour %s → %s', v_tour_actuel + 1, v_benef_nom),
    'gestionnaire', COALESCE(p_gest, 'gestionnaire'),
    'date',        v_now,
    'reference',   v_ref
  );
  v_data := jsonb_set(
    v_data,
    '{caisse,mouvements}',
    jsonb_build_array(v_caisse_mv) || COALESCE(v_data->'caisse'->'mouvements', '[]'::jsonb)
  );

  -- Journal
  v_data := jsonb_set(v_data, '{journal}',
    jsonb_build_array(jsonb_build_object(
      'quoi',        format('DISTRIBUTION_TOUR_%s|%s|%s FCFA', v_tour_actuel + 1, v_benef_nom, v_total_recu),
      'gestionnaire', COALESCE(p_gest, 'gestionnaire'),
      'quand',        v_now,
      'reference',    v_ref
    )) || COALESCE(v_data->'journal', '[]'::jsonb)
  );

  -- Sauvegarder
  UPDATE public.tontines
  SET data = v_data, updated_at = now()
  WHERE code = p_code;

  RETURN jsonb_build_object(
    'ok',                 true,
    'tourDistribue',      v_tour_actuel + 1,
    'beneficiaire',       v_benef_nom,
    'beneficiaireId',     v_benef_id,
    'montantRecu',        v_total_recu,
    'cycleTermine',       v_est_dernier,
    'prochainTour',       CASE WHEN v_est_dernier THEN null ELSE v_new_tour + 1 END,
    'prochainBeneficiaire', CASE
      WHEN v_est_dernier THEN null
      ELSE _tc_nom_membre(v_data, v_ordre->>(v_new_tour)::int)
    END
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.distribuer_tour TO anon, authenticated;

-- =============================================================================
-- BLOC DE VÉRIFICATION 010
-- =============================================================================
DO $verify010$
DECLARE
  v_missing text[] := ARRAY[]::text[];
  v_fn      text;
  v_fns     text[] := ARRAY[
    'sauvegarder_token',
    'creer_transaction_sycapay',
    'get_pending_sycapay_transactions',
    'crediter_caisse_sycapay',
    'crediter_cotisation_sycapay',
    'crediter_penalite_sycapay',
    'recalculer_echeances_expir',
    'distribuer_tour'
  ];
BEGIN
  FOREACH v_fn IN ARRAY v_fns LOOP
    IF NOT EXISTS (
      SELECT 1 FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public' AND p.proname = v_fn
    ) THEN
      v_missing := array_append(v_missing, v_fn);
    END IF;
  END LOOP;

  IF array_length(v_missing, 1) > 0 THEN
    RAISE EXCEPTION '❌ Migration 010 incomplète — fonctions manquantes : %', array_to_string(v_missing, ', ');
  END IF;

  -- Vérifier les colonnes sycapay_transactions v2
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name   = 'sycapay_transactions'
      AND column_name  = 'sycapay_reference'
  ) THEN
    RAISE WARNING '⚠️  Colonne sycapay_reference absente de sycapay_transactions (ALTER TABLE ignoré ?)';
  END IF;

  RAISE NOTICE '✅ Migration 010 vérifiée — 8 RPCs (Notifications FCM + SycaPay) présents.';
  RAISE NOTICE '   sauvegarder_token              ✓';
  RAISE NOTICE '   creer_transaction_sycapay      ✓';
  RAISE NOTICE '   get_pending_sycapay_transactions ✓';
  RAISE NOTICE '   crediter_caisse_sycapay        ✓';
  RAISE NOTICE '   crediter_cotisation_sycapay    ✓';
  RAISE NOTICE '   crediter_penalite_sycapay      ✓';
  RAISE NOTICE '   recalculer_echeances_expir     ✓';
  RAISE NOTICE '   distribuer_tour                ✓';
END;
$verify010$;
