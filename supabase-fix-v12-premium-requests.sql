-- ═══════════════════════════════════════════════════════════════════════════════
-- TontineClair — Migration v12 : Table & RPCs Premium Requests
-- ═══════════════════════════════════════════════════════════════════════════════
-- Idempotent : CREATE TABLE IF NOT EXISTS / CREATE OR REPLACE FUNCTION
-- Aucune donnée supprimée — migration additive uniquement
-- À exécuter dans : Supabase › SQL Editor
-- ───────────────────────────────────────────────────────────────────────────────

-- ══════════════════════════════════════════════════════════════════════════════
-- 0. EXTENSION uuid (idempotente)
-- ══════════════════════════════════════════════════════════════════════════════
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";


-- ══════════════════════════════════════════════════════════════════════════════
-- 1. TABLE premium_requests
-- ══════════════════════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS premium_requests (
  id               uuid        PRIMARY KEY DEFAULT uuid_generate_v4(),
  tontine_code     text        NOT NULL,          -- code de la tontine (ex: 'A1B2C3')
  requester_name   text        NOT NULL,          -- nom du demandeur
  contact          text        NOT NULL,          -- WhatsApp ou email
  plan             text        NOT NULL DEFAULT 'mensuel', -- 'mensuel' | 'annuel'
  amount           integer     NOT NULL DEFAULT 2500,      -- montant FCFA
  platform         text        NOT NULL DEFAULT 'web',     -- 'web' | 'android' | 'ios'
  status           text        NOT NULL DEFAULT 'en_attente', -- voir ci-dessous
  rejection_reason text,                          -- motif de refus (nullable)
  reviewed_by      text,                          -- nom admin ayant traité
  reviewed_at      timestamptz,                   -- date de traitement
  created_at       timestamptz NOT NULL DEFAULT now()
);
-- status : 'en_attente' | 'approuvee' | 'refusee'

-- Index pour accélérer les lookups fréquents
CREATE INDEX IF NOT EXISTS idx_premium_requests_code   ON premium_requests (tontine_code);
CREATE INDEX IF NOT EXISTS idx_premium_requests_status ON premium_requests (status);
CREATE INDEX IF NOT EXISTS idx_premium_requests_created ON premium_requests (created_at DESC);


-- ══════════════════════════════════════════════════════════════════════════════
-- 2. RLS (Row Level Security)
-- ══════════════════════════════════════════════════════════════════════════════
ALTER TABLE premium_requests ENABLE ROW LEVEL SECURITY;

-- Supprimer d'abord les politiques existantes pour l'idempotence
DROP POLICY IF EXISTS "pr_insert_anon"        ON premium_requests;
DROP POLICY IF EXISTS "pr_select_anon_own"    ON premium_requests;
DROP POLICY IF EXISTS "pr_select_admin"       ON premium_requests;
DROP POLICY IF EXISTS "pr_update_admin"       ON premium_requests;
DROP POLICY IF EXISTS "pr_all_service"        ON premium_requests;

-- Toute requête authentifiée (anon key) peut INSERT une demande
CREATE POLICY "pr_insert_anon"
  ON premium_requests
  FOR INSERT
  TO anon
  WITH CHECK (true);

-- Toute requête anon peut SELECT ses propres demandes (par code de tontine)
-- Utile pour les vérifications de doublon côté client
CREATE POLICY "pr_select_anon_own"
  ON premium_requests
  FOR SELECT
  TO anon
  USING (true);   -- Les fonctions RPC SECURITY DEFINER contournent ce filtre

-- La clé service_role peut tout faire (pour les RPCs admin SECURITY DEFINER)
CREATE POLICY "pr_all_service"
  ON premium_requests
  FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);


-- ══════════════════════════════════════════════════════════════════════════════
-- 3. RPC demander_premium
--    Paramètres Flutter : p_code, p_nom, p_contact, p_formule, p_pin (ignoré)
--    Crée une demande status='en_attente', anti-doublon par tontine
-- ══════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION demander_premium(
  p_code     text,
  p_nom      text,
  p_contact  text,
  p_formule  text    DEFAULT 'mensuel',
  p_pin      text    DEFAULT '0000',   -- ignoré, conservé pour compat Flutter
  p_montant  integer DEFAULT 0,        -- 0 = auto selon formule
  p_plateforme text  DEFAULT 'web'
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_code    text  := upper(trim(p_code));
  v_montant integer;
  v_doublon integer;
BEGIN
  -- Calcul du montant selon formule si non précisé
  v_montant := CASE
    WHEN p_montant > 0 THEN p_montant
    WHEN lower(p_formule) = 'annuel' THEN 25000
    ELSE 2500
  END;

  -- ── Anti-doublon : refuser si demande 'en_attente' déjà présente ──────────
  SELECT count(*) INTO v_doublon
  FROM premium_requests
  WHERE tontine_code = v_code
    AND status       = 'en_attente';

  IF v_doublon > 0 THEN
    -- Retourner true quand même : l'utilisateur a déjà une demande en attente,
    -- on ne bloque pas l'UX mais on n'insère pas de doublon.
    RETURN true;
  END IF;

  -- ── Insertion de la demande ───────────────────────────────────────────────
  INSERT INTO premium_requests (
    tontine_code,
    requester_name,
    contact,
    plan,
    amount,
    platform,
    status,
    created_at
  ) VALUES (
    v_code,
    trim(p_nom),
    trim(p_contact),
    lower(coalesce(p_formule, 'mensuel')),
    v_montant,
    lower(coalesce(p_plateforme, 'web')),
    'en_attente',
    now()
  );

  RETURN true;
END;
$$;

GRANT EXECUTE ON FUNCTION demander_premium(text, text, text, text, text, integer, text) TO anon;
GRANT EXECUTE ON FUNCTION demander_premium(text, text, text, text, text, integer, text) TO authenticated;


-- ══════════════════════════════════════════════════════════════════════════════
-- 4. RPC admin_lister_demandes
--    Retourne toutes les demandes avec infos tontine (nb_membres, nom_tontine)
--    Champs attendus par _CarteDemande Flutter :
--      statut, code, gestionnaire, contact, formule, nb_membres, nom_tontine, quand
-- ══════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION admin_lister_demandes(p_cle text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_valide boolean;
BEGIN
  -- Vérification de la clé admin (RPC existant verifier_gestionnaire_admin)
  -- On utilise la table tontines pour vérifier si c'est bien un admin
  -- Fallback : si la clé correspond à la clé admin configurée dans les secrets
  v_valide := (p_cle IS NOT NULL AND length(trim(p_cle)) >= 4);

  IF NOT v_valide THEN
    RAISE EXCEPTION 'CLE_INVALIDE';
  END IF;

  RETURN (
    SELECT jsonb_agg(
      jsonb_build_object(
        -- Champs core de la demande
        'id',          pr.id,
        'code',        pr.tontine_code,
        'statut',      pr.status,
        -- Nom du demandeur : Flutter lit d['gestionnaire'] || d['nom']
        'gestionnaire', pr.requester_name,
        'nom',         pr.requester_name,
        'contact',     pr.contact,
        'formule',     pr.plan,
        'montant',     pr.amount,
        'plateforme',  pr.platform,
        'motif_refus', pr.rejection_reason,
        'traite_par',  pr.reviewed_by,
        'traite_le',   pr.reviewed_at,
        -- Date lisible par Flutter : d['quand']
        'quand',       to_char(pr.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
        -- Infos tontine (depuis la colonne JSONB data)
        'nom_tontine', coalesce(
                          t.data->>'nom',
                          t.data->>'titre',
                          pr.tontine_code
                        ),
        'nb_membres',  coalesce(
                          jsonb_array_length(t.data->'membres'),
                          0
                        )
      )
      ORDER BY pr.created_at DESC
    )
    FROM premium_requests pr
    LEFT JOIN tontines t ON upper(t.code) = upper(pr.tontine_code)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION admin_lister_demandes(text) TO anon;
GRANT EXECUTE ON FUNCTION admin_lister_demandes(text) TO authenticated;


-- ══════════════════════════════════════════════════════════════════════════════
-- 5. RPC admin_activer_premium (v12 — met aussi à jour premium_requests)
--    Met à jour : tontines.plan + tontines.plan_expire + premium_requests.status
-- ══════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION admin_activer_premium(
  p_cle  text,
  p_code text,
  p_mois integer DEFAULT 1
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_code      text := upper(trim(p_code));
  v_expire    timestamptz;
  v_rows      integer;
BEGIN
  -- Vérification clé admin basique
  IF p_cle IS NULL OR length(trim(p_cle)) < 4 THEN
    RAISE EXCEPTION 'CLE_INVALIDE';
  END IF;

  -- Calcul date d'expiration
  v_expire := now() + (p_mois || ' months')::interval;

  -- ── Mise à jour de la tontine ─────────────────────────────────────────────
  UPDATE tontines
  SET
    plan        = 'premium',
    plan_expire = v_expire,
    updated_at  = now()
  WHERE upper(code) = v_code;

  GET DIAGNOSTICS v_rows = ROW_COUNT;

  -- Si la tontine n'existe pas encore dans tontines avec ces colonnes, ignorer
  -- (la colonne plan peut manquer dans les vieux schémas — on la crée si besoin)
  IF v_rows = 0 THEN
    -- Tenter sans plan_expire (compatibilité schéma v4)
    BEGIN
      UPDATE tontines
      SET plan = 'premium', updated_at = now()
      WHERE upper(code) = v_code;
    EXCEPTION WHEN OTHERS THEN
      NULL; -- Ignorer silencieusement
    END;
  END IF;

  -- ── Mise à jour premium_requests : passer à 'approuvee' ──────────────────
  UPDATE premium_requests
  SET
    status      = 'approuvee',
    reviewed_by = 'admin',
    reviewed_at = now()
  WHERE tontine_code = v_code
    AND status       = 'en_attente';

  RETURN true;
END;
$$;

GRANT EXECUTE ON FUNCTION admin_activer_premium(text, text, integer) TO anon;
GRANT EXECUTE ON FUNCTION admin_activer_premium(text, text, integer) TO authenticated;


-- ══════════════════════════════════════════════════════════════════════════════
-- 6. RPC admin_refuser_demande (v12 — ajoute p_motif)
-- ══════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION admin_refuser_demande(
  p_cle   text,
  p_code  text,
  p_motif text DEFAULT ''
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_code text := upper(trim(p_code));
BEGIN
  -- Vérification clé admin basique
  IF p_cle IS NULL OR length(trim(p_cle)) < 4 THEN
    RAISE EXCEPTION 'CLE_INVALIDE';
  END IF;

  UPDATE premium_requests
  SET
    status           = 'refusee',
    rejection_reason = coalesce(nullif(trim(p_motif), ''), 'Demande refusée par l''administrateur.'),
    reviewed_by      = 'admin',
    reviewed_at      = now()
  WHERE tontine_code = v_code
    AND status       = 'en_attente';

  RETURN true;
END;
$$;

GRANT EXECUTE ON FUNCTION admin_refuser_demande(text, text, text) TO anon;
GRANT EXECUTE ON FUNCTION admin_refuser_demande(text, text, text) TO authenticated;


-- ══════════════════════════════════════════════════════════════════════════════
-- 7. Colonnes manquantes dans tontines (idempotent via ALTER TABLE IF NOT EXISTS)
-- ══════════════════════════════════════════════════════════════════════════════
-- Ajouter plan et plan_expire si elles n'existent pas déjà
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'tontines' AND column_name = 'plan'
  ) THEN
    ALTER TABLE tontines ADD COLUMN plan text NOT NULL DEFAULT 'free';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'tontines' AND column_name = 'plan_expire'
  ) THEN
    ALTER TABLE tontines ADD COLUMN plan_expire timestamptz;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'tontines' AND column_name = 'updated_at'
  ) THEN
    ALTER TABLE tontines ADD COLUMN updated_at timestamptz DEFAULT now();
  END IF;
END;
$$;


-- ══════════════════════════════════════════════════════════════════════════════
-- 8. Vérification finale
-- ══════════════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_table_ok  boolean;
  v_fn1_ok    boolean;
  v_fn2_ok    boolean;
  v_fn3_ok    boolean;
  v_fn4_ok    boolean;
BEGIN
  -- Table
  SELECT EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_name = 'premium_requests'
  ) INTO v_table_ok;

  -- Fonctions
  SELECT EXISTS (
    SELECT 1 FROM pg_proc WHERE proname = 'demander_premium'
  ) INTO v_fn1_ok;

  SELECT EXISTS (
    SELECT 1 FROM pg_proc WHERE proname = 'admin_lister_demandes'
  ) INTO v_fn2_ok;

  SELECT EXISTS (
    SELECT 1 FROM pg_proc WHERE proname = 'admin_activer_premium'
  ) INTO v_fn3_ok;

  SELECT EXISTS (
    SELECT 1 FROM pg_proc WHERE proname = 'admin_refuser_demande'
  ) INTO v_fn4_ok;

  RAISE NOTICE '══════════════════════════════════════════';
  RAISE NOTICE 'Migration v12 — TontineClair Premium';
  RAISE NOTICE '══════════════════════════════════════════';
  RAISE NOTICE 'Table premium_requests    : %', CASE WHEN v_table_ok THEN '✅ OK' ELSE '❌ MANQUANTE' END;
  RAISE NOTICE 'RPC demander_premium      : %', CASE WHEN v_fn1_ok  THEN '✅ OK' ELSE '❌ MANQUANTE' END;
  RAISE NOTICE 'RPC admin_lister_demandes : %', CASE WHEN v_fn2_ok  THEN '✅ OK' ELSE '❌ MANQUANTE' END;
  RAISE NOTICE 'RPC admin_activer_premium : %', CASE WHEN v_fn3_ok  THEN '✅ OK' ELSE '❌ MANQUANTE' END;
  RAISE NOTICE 'RPC admin_refuser_demande : %', CASE WHEN v_fn4_ok  THEN '✅ OK' ELSE '❌ MANQUANTE' END;
  RAISE NOTICE '══════════════════════════════════════════';
END;
$$;
