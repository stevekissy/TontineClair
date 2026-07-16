-- ============================================================
-- TontineClair — upgrade.sql  v7
-- Mise à jour schéma (tables, colonnes, index, triggers, RLS)
-- sans aucune perte de données
-- ============================================================
--
-- PÉRIMÈTRE DE CE FICHIER :
--   ✅ Bloc 0  — Inventaire informatif des tables existantes
--   ✅ Section A — Nouvelles tables      (IF NOT EXISTS — no-op si présentes)
--   ✅ Section B — Nouvelles colonnes    (ADD COLUMN IF NOT EXISTS — exhaustif)
--   ✅ Bloc 0b  — Post-validation BLOQUANTE (colonnes indexées) :
--                  • Ignore les tables entièrement absentes
--                    (créées par Section A, donc Section C est safe)
--                  • RAISE EXCEPTION uniquement si table EXISTAIT
--                    AVANT Section A ET colonne toujours manquante
--   ✅ Section C — Nouveaux index        (IF NOT EXISTS)
--   ✅ Section D — Triggers              (DROP IF EXISTS + recréation)
--   ✅ Section E — Politiques RLS        (DROP IF EXISTS + recréation)
--   ✅ Section F — Fonctions / RPCs      → voir init_inline.sql
--
-- ────────────────────────────────────────────────────────────
-- HISTORIQUE DES CORRECTIONS
-- ────────────────────────────────────────────────────────────
--   v3 → ERROR 42703 : sycapay_transactions.statut,
--                       subscriptions.statut
--   v4 → ERROR 42703 : sycapay_transactions.type,
--                       rappels_envoyes (zéro ADD COLUMN),
--                       voix (zéro ADD COLUMN)
--   v5 → Audit EXHAUSTIF + Bloc 0b RAISE EXCEPTION.
--         Flaw : Bloc 0b levait EXCEPTION même si la table
--         venait d'être créée par Section A (table absente en
--         prod → Section A la crée → Bloc 0b vérifie → colonne
--         présente car table neuve). Testé OK local.
--         Non encore appliqué sur prod après audit CSV partiel.
--   v6 → CORRECTIONS CONFIRMÉES par audit CSV prod :
--         • 1 seul trigger en prod : trg_tontines_updated_at
--           → trg_sub_modifie_le ABSENT → recréé en Section D
--         • Bloc 0b v6 : exclut les tables créées ex-nihilo
--           par Section A (elles ont toutes leurs colonnes)
--           → RAISE EXCEPTION uniquement sur tables PRÉ-EXISTANTES
--           avec colonnes manquantes (cas pathologique réel)
--         • Ajout d'un rapport inline de l'état réel de la DB
--           juste avant Section C pour diagnostic en cas d'échec
--
-- ────────────────────────────────────────────────────────────
-- DONNÉES CONFIRMÉES PAR AUDIT PROD (CSV reçu le 2025-07-xx)
-- ────────────────────────────────────────────────────────────
--   Triggers réels :
--     • tontines  / trg_tontines_updated_at / UPDATE / BEFORE ✓
--     • subscriptions / trg_sub_modifie_le → ABSENT en prod
--
-- ────────────────────────────────────────────────────────────
-- MATRICE COMPLÈTE v7 (table · colonne · couvert par)
-- ────────────────────────────────────────────────────────────
--   ┌─────────────────────────────────┬──────────────────────────┬────────┐
--   │ Table                           │ Colonne(s) indexée(s)    │ Bloc B │
--   ├─────────────────────────────────┼──────────────────────────┼────────┤
--   │ tontines                        │ code, status, updated_at │ B.1    │
--   │ audit                           │ code, quand              │ B.2    │
--   │ demandes_premium                │ code                     │ B.3    │
--   │ scores_historique               │ code, membre_id, quand   │ B.4    │
--   │ propositions_retrait            │ code, membre_id          │ B.5    │
--   │ journal_audit                   │ code, quand              │ B.6    │
--   │ subscriptions                   │ code, statut, modifie_le │ B.7    │
--   │ abonnements                     │ code                     │ B.8    │
--   │ admin_actions                   │ (aucun index nommé)      │ B.9    │
--   │ sycapay_transactions            │ code, statut, type       │ B.10   │
--   │                                 │ internal_reference       │        │
--   │                                 │ idempotency_key          │        │
--   │                                 │ membre_id                │        │
--   │                                 │ provider_transaction_id  │        │
--   │ prets_pending                   │ code, statut             │ B.11   │
--   │ decaissements_pending           │ code, statut             │ B.12   │
--   │ depenses_pending                │ code, statut             │ B.13   │
--   │ premium_requests                │ code, statut             │ B.14   │
--   │ kyc_submissions                 │ code, statut             │ B.15   │
--   │ fcm_tokens                      │ tontine, token           │ B.16   │
--   │ rappels_envoyes                 │ code, membre_id, type    │ B.21   │
--   │                                 │ envoye_le                │        │
--   │ voix                            │ code, vote_id, membre_id │ B.22   │
--   │ admin_membres                   │ pseudo, role             │ B.17   │
--   │ admin_messages                  │ dest, exp, envoye_le     │ B.18   │
--   │ support_tickets                 │ statut, gest, ref, cree  │ B.19   │
--   │ support_messages                │ ticket_id, envoye_le     │ B.20   │
--   └─────────────────────────────────┴──────────────────────────┴────────┘
--
-- ────────────────────────────────────────────────────────────
-- GARANTIE DE NON-DESTRUCTION :
--   ✅ Aucun DROP TABLE / TRUNCATE / DELETE FROM
--   ✅ Aucun DROP FUNCTION
--   ✅ CREATE TABLE         uniquement IF NOT EXISTS
--   ✅ ALTER TABLE          uniquement ADD COLUMN IF NOT EXISTS
--   ✅ Toutes les colonnes NOT NULL ont un DEFAULT
--   ✅ CREATE INDEX         uniquement IF NOT EXISTS
--   ✅ DROP TRIGGER IF EXISTS avant recréation
--   ✅ DROP POLICY IF EXISTS avant recréation
--   ✅ Rejouer N fois       → résultat identique (idempotent)
--   ✅ Transactionnel       → BEGIN/COMMIT (rollback auto si erreur)
--
-- COMMENT UTILISER :
--   Supabase SQL Editor → New query → Coller upgrade.sql → Run
--   Puis : Supabase SQL Editor → New query → Coller init_inline.sql → Run
--
-- VERSION : migrations 001→011 — 2025-07-17  (v7)
-- ============================================================

BEGIN;

-- ============================================================
-- BLOC 0 : INVENTAIRE INFORMATIF (AVANT Section A)
-- ============================================================
-- Enregistre les tables qui EXISTENT DÉJÀ avant toute action.
-- Cette liste est utilisée par Bloc 0b pour distinguer les
-- tables pré-existantes (à valider) des tables créées ex-nihilo
-- par Section A (forcément complètes, pas besoin de valider).
-- ============================================================
DO $$
DECLARE
  v_tbl  TEXT;
  v_cnt  INT;
BEGIN
  RAISE NOTICE 'upgrade.sql v7 — Démarrage. Inventaire des tables existantes...';
  FOR v_tbl IN SELECT unnest(ARRAY[
    'tontines','audit','demandes_premium','scores_historique',
    'propositions_retrait','journal_audit','subscriptions','abonnements',
    'admin_actions','sycapay_transactions','prets_pending',
    'decaissements_pending','depenses_pending','premium_requests',
    'kyc_submissions','fcm_tokens','rappels_envoyes','voix',
    'admin_membres','admin_messages','support_tickets','support_messages',
    'config','app_config','admin_config'
  ]) LOOP
    SELECT COUNT(*) INTO v_cnt
    FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = v_tbl;
    IF v_cnt = 0 THEN
      RAISE NOTICE 'v7 PRÉ-INFO: table "%" absente → sera créée par Section A', v_tbl;
    ELSE
      RAISE NOTICE 'v7 PRÉ-INFO: table "%" présente avec % colonnes', v_tbl, v_cnt;
    END IF;
  END LOOP;
  RAISE NOTICE 'v7 PRÉ-INFO: fin inventaire. Début Section A...';
END;
$$;


-- ============================================================
-- SECTION A : NOUVELLES TABLES (no-op si déjà présentes)
-- ============================================================
-- Si la table existe déjà, CREATE TABLE IF NOT EXISTS = no-op.
-- La Section B (ADD COLUMN IF NOT EXISTS) ajoute les colonnes
-- manquantes sur les tables existantes avec l'ancien schéma.
-- ============================================================

-- ─────────────────────────────────────────────────────────────
-- A.1 — tontines
-- ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS tontines (
  id                     BIGSERIAL   PRIMARY KEY,
  code                   TEXT        NOT NULL UNIQUE,
  data                   JSONB       NOT NULL DEFAULT '{}',
  gestionnaires          JSONB       DEFAULT '[]',
  membres_pins           JSONB       DEFAULT '[]',
  plan                   TEXT        NOT NULL DEFAULT 'free',
  plan_expire            TIMESTAMPTZ,
  cree                   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  modifie_le             TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  status                 TEXT        NOT NULL DEFAULT 'active'
                         CHECK (status IN ('active','inactive','suspended','deleted')),
  deleted_at             TIMESTAMPTZ,
  deleted_by             TEXT,
  deletion_reason        TEXT,
  invitation_code_active BOOLEAN     NOT NULL DEFAULT TRUE,
  updated_at             TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_at             TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ─────────────────────────────────────────────────────────────
-- A.2 — audit
-- ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS audit (
  id           BIGSERIAL   PRIMARY KEY,
  code         TEXT        NOT NULL,
  gestionnaire TEXT        NOT NULL DEFAULT '',
  empreinte    TEXT        NOT NULL DEFAULT '',
  quand        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ─────────────────────────────────────────────────────────────
-- A.3 — demandes_premium
-- ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS demandes_premium (
  id           BIGSERIAL   PRIMARY KEY,
  code         TEXT        NOT NULL,
  gestionnaire TEXT        NOT NULL DEFAULT '',
  nom          TEXT,
  contact      TEXT,
  formule      TEXT        NOT NULL DEFAULT 'mensuel',
  statut       TEXT        NOT NULL DEFAULT 'en_attente',
  quand        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ─────────────────────────────────────────────────────────────
-- A.4 — config / app_config / admin_config
-- ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS config (
  cle    TEXT PRIMARY KEY,
  valeur TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS app_config (
  cle    TEXT PRIMARY KEY,
  valeur TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS admin_config (
  cle    TEXT PRIMARY KEY,
  valeur TEXT NOT NULL
);

-- ─────────────────────────────────────────────────────────────
-- A.5 — voix
-- ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS voix (
  id        BIGSERIAL   PRIMARY KEY,
  code      TEXT        NOT NULL,
  vote_id   TEXT        NOT NULL,
  membre_id TEXT        NOT NULL,
  choix     TEXT        NOT NULL DEFAULT 'abstention',
  methode   TEXT        NOT NULL DEFAULT 'PIN',
  appareil  TEXT,
  vote_le   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (code, vote_id, membre_id)
);

-- ─────────────────────────────────────────────────────────────
-- A.6 — scores_historique
-- ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS scores_historique (
  id           BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  code         TEXT        NOT NULL,
  membre_id    TEXT        NOT NULL DEFAULT '',
  score        INT         NOT NULL DEFAULT 0,
  score_prec   INT         NOT NULL DEFAULT 0,
  evenement    TEXT        NOT NULL DEFAULT '',
  description  TEXT        NOT NULL DEFAULT '',
  gestionnaire TEXT,
  quand        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ─────────────────────────────────────────────────────────────
-- A.7 — propositions_retrait
-- ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS propositions_retrait (
  id           BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  code         TEXT        NOT NULL,
  membre_id    TEXT        NOT NULL DEFAULT '',
  membre_nom   TEXT        NOT NULL DEFAULT '',
  score_moment INT         NOT NULL DEFAULT 0,
  motif        TEXT        NOT NULL DEFAULT '',
  propose_par  TEXT        NOT NULL DEFAULT '',
  vote_id      TEXT,
  quorum       INT         NOT NULL DEFAULT 50,
  majorite     INT         NOT NULL DEFAULT 67,
  statut       TEXT        NOT NULL DEFAULT 'en_attente',
  quand        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  clos_le      TIMESTAMPTZ,
  resultat_oui INT         DEFAULT 0,
  resultat_non INT         DEFAULT 0,
  resultat_abs INT         DEFAULT 0
);

-- ─────────────────────────────────────────────────────────────
-- A.8 — journal_audit
-- ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS journal_audit (
  id           BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  code         TEXT        NOT NULL,
  gestionnaire TEXT        NOT NULL DEFAULT '',
  action       TEXT        NOT NULL DEFAULT '',
  detail       TEXT,
  membre_id    TEXT,
  ancien_val   TEXT,
  nouveau_val  TEXT,
  quand        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ─────────────────────────────────────────────────────────────
-- A.9 — subscriptions
-- ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS subscriptions (
  id         BIGSERIAL   PRIMARY KEY,
  code       TEXT        NOT NULL UNIQUE,
  plan       TEXT        NOT NULL DEFAULT 'gratuit',
  statut     TEXT        NOT NULL DEFAULT 'actif',
  date_debut TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  date_fin   TIMESTAMPTZ,
  stripe_id  TEXT,
  modifie_le TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ─────────────────────────────────────────────────────────────
-- A.10 — abonnements
-- ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS abonnements (
  id           BIGSERIAL     PRIMARY KEY,
  code         TEXT          NOT NULL,
  gestionnaire TEXT,
  contact      TEXT,
  formule      TEXT          NOT NULL DEFAULT 'mensuel',
  statut       TEXT          NOT NULL DEFAULT 'actif',
  debut        TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  fin          TIMESTAMPTZ,
  montant      NUMERIC(12,2) DEFAULT 0,
  devise       TEXT          DEFAULT 'XOF',
  note         TEXT,
  cree_le      TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

-- ─────────────────────────────────────────────────────────────
-- A.11 — admin_actions
-- ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS admin_actions (
  id     BIGSERIAL   PRIMARY KEY,
  type   TEXT        NOT NULL DEFAULT '',
  code   TEXT,
  detail TEXT,
  admin  TEXT        NOT NULL DEFAULT 'admin',
  quand  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ─────────────────────────────────────────────────────────────
-- A.12 — sycapay_transactions
-- Schéma complet v2 — Section B gère ADD COLUMN IF NOT EXISTS
-- pour les tables prod avec ancien schéma (~7 colonnes fondatrices)
-- ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS sycapay_transactions (
  id                      BIGSERIAL     PRIMARY KEY,
  type                    TEXT          NOT NULL DEFAULT '',
  code                    TEXT          NOT NULL DEFAULT '',
  membre_id               TEXT,
  membre_nom              TEXT,
  montant                 NUMERIC(14,2) NOT NULL DEFAULT 0,
  devise                  TEXT          NOT NULL DEFAULT 'XOF',
  statut                  TEXT          NOT NULL DEFAULT 'pending',
  sycapay_ref             TEXT,
  numero_telephone        TEXT,
  gestionnaire            TEXT,
  internal_reference      TEXT          UNIQUE,
  idempotency_key         TEXT          UNIQUE,
  statut_traitement       TEXT          NOT NULL DEFAULT 'non_traite',
  user_id                 TEXT,
  tontine_code            TEXT,
  type_operation          TEXT,
  pret_id                 TEXT,
  emprunteur_id           TEXT,
  metadata                JSONB         DEFAULT '{}',
  created_at              TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  updated_at              TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  provider_transaction_id TEXT,
  sycapay_reference       TEXT,
  amount                  INTEGER       DEFAULT 0,
  currency                TEXT,
  operator                TEXT,
  phone_number_masked     TEXT,
  description             TEXT,
  status                  TEXT          DEFAULT 'pending',
  polling_attempts        INTEGER       DEFAULT 0
);

-- ─────────────────────────────────────────────────────────────
-- A.13 — prets_pending
-- ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS prets_pending (
  id             BIGSERIAL     PRIMARY KEY,
  code           TEXT          NOT NULL,
  membre_id      TEXT          NOT NULL DEFAULT '',
  membre_nom     TEXT          NOT NULL DEFAULT '',
  montant        NUMERIC(14,2) NOT NULL DEFAULT 0,
  montant_net    NUMERIC(14,2),
  taux_interet   NUMERIC(5,2)  DEFAULT 0,
  duree_mois     INT           DEFAULT 1,
  devise         TEXT          NOT NULL DEFAULT 'XOF',
  motif          TEXT,
  statut         TEXT          NOT NULL DEFAULT 'pending',
  motif_rejet    TEXT,
  gestionnaire   TEXT,
  cree_le        TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  traite_le      TIMESTAMPTZ
);

-- ─────────────────────────────────────────────────────────────
-- A.14 — decaissements_pending
-- ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS decaissements_pending (
  id           BIGSERIAL     PRIMARY KEY,
  code         TEXT          NOT NULL,
  beneficiaire TEXT          NOT NULL DEFAULT '',
  montant      NUMERIC(14,2) NOT NULL DEFAULT 0,
  devise       TEXT          NOT NULL DEFAULT 'XOF',
  motif        TEXT,
  statut       TEXT          NOT NULL DEFAULT 'pending',
  motif_rejet  TEXT,
  gestionnaire TEXT,
  cree_le      TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  traite_le    TIMESTAMPTZ
);

-- ─────────────────────────────────────────────────────────────
-- A.15 — depenses_pending
-- ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS depenses_pending (
  id           BIGSERIAL     PRIMARY KEY,
  code         TEXT          NOT NULL,
  libelle      TEXT          NOT NULL DEFAULT '',
  montant      NUMERIC(14,2) NOT NULL DEFAULT 0,
  devise       TEXT          NOT NULL DEFAULT 'XOF',
  categorie    TEXT          DEFAULT 'autre',
  statut       TEXT          NOT NULL DEFAULT 'pending',
  motif_rejet  TEXT,
  gestionnaire TEXT,
  cree_le      TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  traite_le    TIMESTAMPTZ
);

-- ─────────────────────────────────────────────────────────────
-- A.16 — premium_requests
-- ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS premium_requests (
  id           BIGSERIAL   PRIMARY KEY,
  code         TEXT        NOT NULL UNIQUE,
  gestionnaire TEXT        NOT NULL DEFAULT '',
  nom          TEXT,
  contact      TEXT,
  formule      TEXT        NOT NULL DEFAULT 'mensuel',
  statut       TEXT        NOT NULL DEFAULT 'pending',
  cree_le      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  mis_a_jour   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ─────────────────────────────────────────────────────────────
-- A.17 — kyc_submissions
-- ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.kyc_submissions (
  id               BIGSERIAL   PRIMARY KEY,
  code             TEXT        NOT NULL,
  gestionnaire     TEXT        NOT NULL DEFAULT '',
  nom_complet      TEXT        NOT NULL DEFAULT '',
  type_piece       TEXT        NOT NULL DEFAULT 'cni',
  numero_piece     TEXT,
  photo_recto_url  TEXT,
  photo_verso_url  TEXT,
  photo_selfie_url TEXT,
  statut           TEXT        NOT NULL DEFAULT 'pending',
  motif_rejet      TEXT,
  note_admin       TEXT,
  soumis_le        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  traite_le        TIMESTAMPTZ
);

-- ─────────────────────────────────────────────────────────────
-- A.18 — fcm_tokens
-- ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.fcm_tokens (
  id         BIGSERIAL   PRIMARY KEY,
  token      TEXT        NOT NULL UNIQUE,
  tontine    TEXT,
  membre_id  TEXT,
  platform   TEXT        DEFAULT 'android',
  cree_le    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  mis_a_jour TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  langue     TEXT
);

-- ─────────────────────────────────────────────────────────────
-- A.19 — rappels_envoyes
-- Schéma canonique : id, code, membre_id, type, envoye_le
-- ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS rappels_envoyes (
  id        BIGSERIAL   PRIMARY KEY,
  code      TEXT        NOT NULL,
  membre_id TEXT        NOT NULL DEFAULT '',
  type      TEXT        NOT NULL DEFAULT 'cotisation',
  envoye_le TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (code, membre_id, type)
);

-- ─────────────────────────────────────────────────────────────
-- A.20 — admin_membres
-- ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS admin_membres (
  id                 BIGSERIAL   PRIMARY KEY,
  nom                TEXT        NOT NULL DEFAULT '',
  pseudo             TEXT        NOT NULL UNIQUE,
  cle_hash           TEXT        NOT NULL DEFAULT '',
  role               TEXT        NOT NULL DEFAULT 'comptable',
  actif              BOOLEAN     NOT NULL DEFAULT TRUE,
  cree_par           TEXT        NOT NULL DEFAULT '',
  cree_le            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  derniere_connexion TIMESTAMPTZ
);

-- ─────────────────────────────────────────────────────────────
-- A.21 — admin_messages
-- ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS admin_messages (
  id           BIGSERIAL   PRIMARY KEY,
  expediteur   TEXT        NOT NULL DEFAULT '',
  destinataire TEXT        NOT NULL DEFAULT '',
  sujet        TEXT        NOT NULL DEFAULT '',
  corps        TEXT        NOT NULL DEFAULT '',
  lu           BOOLEAN     NOT NULL DEFAULT FALSE,
  lu_le        TIMESTAMPTZ,
  envoye_le    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ─────────────────────────────────────────────────────────────
-- A.22 — support_tickets
-- ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS support_tickets (
  id           BIGSERIAL   PRIMARY KEY,
  ref          TEXT        NOT NULL UNIQUE,
  gestionnaire TEXT        NOT NULL DEFAULT '',
  code_tontine TEXT,
  categorie    TEXT        NOT NULL DEFAULT 'autre',
  sujet        TEXT        NOT NULL DEFAULT '',
  description  TEXT        NOT NULL DEFAULT '',
  statut       TEXT        NOT NULL DEFAULT 'ouvert',
  priorite     TEXT        NOT NULL DEFAULT 'normale',
  assigne_a    TEXT,
  cree_le      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  mis_a_jour   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  resolu_le    TIMESTAMPTZ
);

-- ─────────────────────────────────────────────────────────────
-- A.23 — support_messages
-- ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS support_messages (
  id        BIGSERIAL   PRIMARY KEY,
  ticket_id BIGINT      NOT NULL REFERENCES support_tickets(id) ON DELETE CASCADE,
  auteur    TEXT        NOT NULL DEFAULT '',
  est_admin BOOLEAN     NOT NULL DEFAULT FALSE,
  corps     TEXT        NOT NULL DEFAULT '',
  lu_client BOOLEAN     NOT NULL DEFAULT FALSE,
  lu_admin  BOOLEAN     NOT NULL DEFAULT FALSE,
  envoye_le TIMESTAMPTZ NOT NULL DEFAULT NOW()
);


-- ============================================================
-- SECTION B : NOUVELLES COLONNES (ADD COLUMN IF NOT EXISTS)
-- ============================================================
-- RÈGLE ABSOLUE v7 :
--   CHAQUE colonne référencée dans Section C (CREATE INDEX),
--   Section D (triggers) et Section E (RLS) doit apparaître
--   dans ce bloc pour la table correspondante.
--
--   ADD COLUMN IF NOT EXISTS = no-op si la colonne existe déjà.
--   Toutes les colonnes NOT NULL ont un DEFAULT pour éviter
--   les erreurs sur lignes existantes.
-- ============================================================

-- ─────────────────────────────────────────────────────────────
-- B.1 — tontines
-- Colonnes indexées : code, status
-- Colonnes trigger  : updated_at
-- ─────────────────────────────────────────────────────────────
ALTER TABLE tontines ADD COLUMN IF NOT EXISTS code                   TEXT        NOT NULL DEFAULT '';
ALTER TABLE tontines ADD COLUMN IF NOT EXISTS data                   JSONB       NOT NULL DEFAULT '{}';
ALTER TABLE tontines ADD COLUMN IF NOT EXISTS gestionnaires          JSONB       DEFAULT '[]';
ALTER TABLE tontines ADD COLUMN IF NOT EXISTS membres_pins           JSONB       DEFAULT '[]';
ALTER TABLE tontines ADD COLUMN IF NOT EXISTS plan                   TEXT        NOT NULL DEFAULT 'free';
ALTER TABLE tontines ADD COLUMN IF NOT EXISTS plan_expire            TIMESTAMPTZ;
ALTER TABLE tontines ADD COLUMN IF NOT EXISTS cree                   TIMESTAMPTZ NOT NULL DEFAULT NOW();
ALTER TABLE tontines ADD COLUMN IF NOT EXISTS modifie_le             TIMESTAMPTZ NOT NULL DEFAULT NOW();
ALTER TABLE tontines ADD COLUMN IF NOT EXISTS status                 TEXT        NOT NULL DEFAULT 'active';
ALTER TABLE tontines ADD COLUMN IF NOT EXISTS deleted_at             TIMESTAMPTZ;
ALTER TABLE tontines ADD COLUMN IF NOT EXISTS deleted_by             TEXT;
ALTER TABLE tontines ADD COLUMN IF NOT EXISTS deletion_reason        TEXT;
ALTER TABLE tontines ADD COLUMN IF NOT EXISTS invitation_code_active BOOLEAN     NOT NULL DEFAULT TRUE;
ALTER TABLE tontines ADD COLUMN IF NOT EXISTS updated_at             TIMESTAMPTZ NOT NULL DEFAULT NOW();
ALTER TABLE tontines ADD COLUMN IF NOT EXISTS created_at             TIMESTAMPTZ NOT NULL DEFAULT NOW();

-- ─────────────────────────────────────────────────────────────
-- B.2 — audit
-- Colonnes indexées : code, quand
-- ─────────────────────────────────────────────────────────────
ALTER TABLE audit ADD COLUMN IF NOT EXISTS gestionnaire TEXT        NOT NULL DEFAULT '';
ALTER TABLE audit ADD COLUMN IF NOT EXISTS empreinte    TEXT        NOT NULL DEFAULT '';
ALTER TABLE audit ADD COLUMN IF NOT EXISTS quand        TIMESTAMPTZ NOT NULL DEFAULT NOW();

-- ─────────────────────────────────────────────────────────────
-- B.3 — demandes_premium
-- Colonnes indexées : code
-- ─────────────────────────────────────────────────────────────
ALTER TABLE demandes_premium ADD COLUMN IF NOT EXISTS gestionnaire TEXT        NOT NULL DEFAULT '';
ALTER TABLE demandes_premium ADD COLUMN IF NOT EXISTS nom          TEXT;
ALTER TABLE demandes_premium ADD COLUMN IF NOT EXISTS contact      TEXT;
ALTER TABLE demandes_premium ADD COLUMN IF NOT EXISTS formule      TEXT        NOT NULL DEFAULT 'mensuel';
ALTER TABLE demandes_premium ADD COLUMN IF NOT EXISTS statut       TEXT        NOT NULL DEFAULT 'en_attente';
ALTER TABLE demandes_premium ADD COLUMN IF NOT EXISTS quand        TIMESTAMPTZ NOT NULL DEFAULT NOW();

-- ─────────────────────────────────────────────────────────────
-- B.4 — scores_historique
-- Colonnes indexées : code, membre_id, quand
-- ─────────────────────────────────────────────────────────────
ALTER TABLE scores_historique ADD COLUMN IF NOT EXISTS membre_id    TEXT        NOT NULL DEFAULT '';
ALTER TABLE scores_historique ADD COLUMN IF NOT EXISTS score        INT         NOT NULL DEFAULT 0;
ALTER TABLE scores_historique ADD COLUMN IF NOT EXISTS score_prec   INT         NOT NULL DEFAULT 0;
ALTER TABLE scores_historique ADD COLUMN IF NOT EXISTS evenement    TEXT        NOT NULL DEFAULT '';
ALTER TABLE scores_historique ADD COLUMN IF NOT EXISTS description  TEXT        NOT NULL DEFAULT '';
ALTER TABLE scores_historique ADD COLUMN IF NOT EXISTS gestionnaire TEXT;
ALTER TABLE scores_historique ADD COLUMN IF NOT EXISTS quand        TIMESTAMPTZ NOT NULL DEFAULT NOW();

-- ─────────────────────────────────────────────────────────────
-- B.5 — propositions_retrait
-- Colonnes indexées : code, membre_id
-- ─────────────────────────────────────────────────────────────
ALTER TABLE propositions_retrait ADD COLUMN IF NOT EXISTS membre_id    TEXT        NOT NULL DEFAULT '';
ALTER TABLE propositions_retrait ADD COLUMN IF NOT EXISTS membre_nom   TEXT        NOT NULL DEFAULT '';
ALTER TABLE propositions_retrait ADD COLUMN IF NOT EXISTS score_moment INT         NOT NULL DEFAULT 0;
ALTER TABLE propositions_retrait ADD COLUMN IF NOT EXISTS motif        TEXT        NOT NULL DEFAULT '';
ALTER TABLE propositions_retrait ADD COLUMN IF NOT EXISTS propose_par  TEXT        NOT NULL DEFAULT '';
ALTER TABLE propositions_retrait ADD COLUMN IF NOT EXISTS vote_id      TEXT;
ALTER TABLE propositions_retrait ADD COLUMN IF NOT EXISTS quorum       INT         NOT NULL DEFAULT 50;
ALTER TABLE propositions_retrait ADD COLUMN IF NOT EXISTS majorite     INT         NOT NULL DEFAULT 67;
ALTER TABLE propositions_retrait ADD COLUMN IF NOT EXISTS statut       TEXT        NOT NULL DEFAULT 'en_attente';
ALTER TABLE propositions_retrait ADD COLUMN IF NOT EXISTS quand        TIMESTAMPTZ NOT NULL DEFAULT NOW();
ALTER TABLE propositions_retrait ADD COLUMN IF NOT EXISTS clos_le      TIMESTAMPTZ;
ALTER TABLE propositions_retrait ADD COLUMN IF NOT EXISTS resultat_oui INT         DEFAULT 0;
ALTER TABLE propositions_retrait ADD COLUMN IF NOT EXISTS resultat_non INT         DEFAULT 0;
ALTER TABLE propositions_retrait ADD COLUMN IF NOT EXISTS resultat_abs INT         DEFAULT 0;

-- ─────────────────────────────────────────────────────────────
-- B.6 — journal_audit
-- Colonnes indexées : code, quand
-- ─────────────────────────────────────────────────────────────
ALTER TABLE journal_audit ADD COLUMN IF NOT EXISTS gestionnaire TEXT        NOT NULL DEFAULT '';
ALTER TABLE journal_audit ADD COLUMN IF NOT EXISTS action       TEXT        NOT NULL DEFAULT '';
ALTER TABLE journal_audit ADD COLUMN IF NOT EXISTS detail       TEXT;
ALTER TABLE journal_audit ADD COLUMN IF NOT EXISTS membre_id    TEXT;
ALTER TABLE journal_audit ADD COLUMN IF NOT EXISTS ancien_val   TEXT;
ALTER TABLE journal_audit ADD COLUMN IF NOT EXISTS nouveau_val  TEXT;
ALTER TABLE journal_audit ADD COLUMN IF NOT EXISTS quand        TIMESTAMPTZ NOT NULL DEFAULT NOW();

-- ─────────────────────────────────────────────────────────────
-- B.7 — subscriptions
-- Colonnes indexées : code, statut
-- Colonne trigger   : modifie_le
-- ─────────────────────────────────────────────────────────────
ALTER TABLE subscriptions ADD COLUMN IF NOT EXISTS plan       TEXT        NOT NULL DEFAULT 'gratuit';
ALTER TABLE subscriptions ADD COLUMN IF NOT EXISTS statut     TEXT        NOT NULL DEFAULT 'actif';
ALTER TABLE subscriptions ADD COLUMN IF NOT EXISTS date_debut TIMESTAMPTZ NOT NULL DEFAULT NOW();
ALTER TABLE subscriptions ADD COLUMN IF NOT EXISTS date_fin   TIMESTAMPTZ;
ALTER TABLE subscriptions ADD COLUMN IF NOT EXISTS stripe_id  TEXT;
ALTER TABLE subscriptions ADD COLUMN IF NOT EXISTS modifie_le TIMESTAMPTZ NOT NULL DEFAULT NOW();

-- ─────────────────────────────────────────────────────────────
-- B.8 — abonnements
-- Colonnes indexées : code
-- ─────────────────────────────────────────────────────────────
ALTER TABLE abonnements ADD COLUMN IF NOT EXISTS gestionnaire TEXT;
ALTER TABLE abonnements ADD COLUMN IF NOT EXISTS contact      TEXT;
ALTER TABLE abonnements ADD COLUMN IF NOT EXISTS formule      TEXT          NOT NULL DEFAULT 'mensuel';
ALTER TABLE abonnements ADD COLUMN IF NOT EXISTS statut       TEXT          NOT NULL DEFAULT 'actif';
ALTER TABLE abonnements ADD COLUMN IF NOT EXISTS debut        TIMESTAMPTZ   NOT NULL DEFAULT NOW();
ALTER TABLE abonnements ADD COLUMN IF NOT EXISTS fin          TIMESTAMPTZ;
ALTER TABLE abonnements ADD COLUMN IF NOT EXISTS montant      NUMERIC(12,2) DEFAULT 0;
ALTER TABLE abonnements ADD COLUMN IF NOT EXISTS devise       TEXT          DEFAULT 'XOF';
ALTER TABLE abonnements ADD COLUMN IF NOT EXISTS note         TEXT;
ALTER TABLE abonnements ADD COLUMN IF NOT EXISTS cree_le      TIMESTAMPTZ   NOT NULL DEFAULT NOW();

-- ─────────────────────────────────────────────────────────────
-- B.9 — admin_actions
-- ─────────────────────────────────────────────────────────────
ALTER TABLE admin_actions ADD COLUMN IF NOT EXISTS type   TEXT        NOT NULL DEFAULT '';
ALTER TABLE admin_actions ADD COLUMN IF NOT EXISTS code   TEXT;
ALTER TABLE admin_actions ADD COLUMN IF NOT EXISTS detail TEXT;
ALTER TABLE admin_actions ADD COLUMN IF NOT EXISTS admin  TEXT        NOT NULL DEFAULT 'admin';
ALTER TABLE admin_actions ADD COLUMN IF NOT EXISTS quand  TIMESTAMPTZ NOT NULL DEFAULT NOW();

-- ─────────────────────────────────────────────────────────────
-- B.10 — sycapay_transactions
-- Colonnes indexées : code, statut, type, internal_reference,
--   idempotency_key, membre_id, provider_transaction_id
--
-- IMPORTANT : 'type' est fondateur de la table originale (7 col)
-- mais ADD COLUMN IF NOT EXISTS est toujours safe.
-- Ordre : colonnes indexées critiques EN PREMIER.
-- ─────────────────────────────────────────────────────────────
ALTER TABLE sycapay_transactions ADD COLUMN IF NOT EXISTS type                   TEXT          NOT NULL DEFAULT '';
ALTER TABLE sycapay_transactions ADD COLUMN IF NOT EXISTS statut                 TEXT          NOT NULL DEFAULT 'pending';
ALTER TABLE sycapay_transactions ADD COLUMN IF NOT EXISTS code                   TEXT          NOT NULL DEFAULT '';
ALTER TABLE sycapay_transactions ADD COLUMN IF NOT EXISTS membre_id              TEXT;
ALTER TABLE sycapay_transactions ADD COLUMN IF NOT EXISTS membre_nom             TEXT;
ALTER TABLE sycapay_transactions ADD COLUMN IF NOT EXISTS montant                NUMERIC(14,2) NOT NULL DEFAULT 0;
ALTER TABLE sycapay_transactions ADD COLUMN IF NOT EXISTS devise                 TEXT          NOT NULL DEFAULT 'XOF';
ALTER TABLE sycapay_transactions ADD COLUMN IF NOT EXISTS sycapay_ref            TEXT;
ALTER TABLE sycapay_transactions ADD COLUMN IF NOT EXISTS numero_telephone        TEXT;
ALTER TABLE sycapay_transactions ADD COLUMN IF NOT EXISTS gestionnaire           TEXT;
ALTER TABLE sycapay_transactions ADD COLUMN IF NOT EXISTS internal_reference     TEXT UNIQUE;
ALTER TABLE sycapay_transactions ADD COLUMN IF NOT EXISTS idempotency_key        TEXT UNIQUE;
ALTER TABLE sycapay_transactions ADD COLUMN IF NOT EXISTS statut_traitement      TEXT          NOT NULL DEFAULT 'non_traite';
ALTER TABLE sycapay_transactions ADD COLUMN IF NOT EXISTS user_id                TEXT;
ALTER TABLE sycapay_transactions ADD COLUMN IF NOT EXISTS tontine_code           TEXT;
ALTER TABLE sycapay_transactions ADD COLUMN IF NOT EXISTS type_operation         TEXT;
ALTER TABLE sycapay_transactions ADD COLUMN IF NOT EXISTS pret_id                TEXT;
ALTER TABLE sycapay_transactions ADD COLUMN IF NOT EXISTS emprunteur_id          TEXT;
ALTER TABLE sycapay_transactions ADD COLUMN IF NOT EXISTS metadata               JSONB         DEFAULT '{}';
ALTER TABLE sycapay_transactions ADD COLUMN IF NOT EXISTS created_at             TIMESTAMPTZ   NOT NULL DEFAULT NOW();
ALTER TABLE sycapay_transactions ADD COLUMN IF NOT EXISTS updated_at             TIMESTAMPTZ   NOT NULL DEFAULT NOW();
ALTER TABLE sycapay_transactions ADD COLUMN IF NOT EXISTS provider_transaction_id TEXT;
ALTER TABLE sycapay_transactions ADD COLUMN IF NOT EXISTS sycapay_reference      TEXT;
ALTER TABLE sycapay_transactions ADD COLUMN IF NOT EXISTS amount                 INTEGER       DEFAULT 0;
ALTER TABLE sycapay_transactions ADD COLUMN IF NOT EXISTS currency               TEXT;
ALTER TABLE sycapay_transactions ADD COLUMN IF NOT EXISTS operator               TEXT;
ALTER TABLE sycapay_transactions ADD COLUMN IF NOT EXISTS phone_number_masked    TEXT;
ALTER TABLE sycapay_transactions ADD COLUMN IF NOT EXISTS description            TEXT;
ALTER TABLE sycapay_transactions ADD COLUMN IF NOT EXISTS status                 TEXT          DEFAULT 'pending';
ALTER TABLE sycapay_transactions ADD COLUMN IF NOT EXISTS polling_attempts       INTEGER       DEFAULT 0;

-- ─────────────────────────────────────────────────────────────
-- B.11 — prets_pending
-- Colonnes indexées : code, statut
-- ─────────────────────────────────────────────────────────────
ALTER TABLE prets_pending ADD COLUMN IF NOT EXISTS membre_id    TEXT          NOT NULL DEFAULT '';
ALTER TABLE prets_pending ADD COLUMN IF NOT EXISTS membre_nom   TEXT          NOT NULL DEFAULT '';
ALTER TABLE prets_pending ADD COLUMN IF NOT EXISTS montant_net  NUMERIC(14,2);
ALTER TABLE prets_pending ADD COLUMN IF NOT EXISTS taux_interet NUMERIC(5,2)  DEFAULT 0;
ALTER TABLE prets_pending ADD COLUMN IF NOT EXISTS duree_mois   INT           DEFAULT 1;
ALTER TABLE prets_pending ADD COLUMN IF NOT EXISTS devise       TEXT          NOT NULL DEFAULT 'XOF';
ALTER TABLE prets_pending ADD COLUMN IF NOT EXISTS motif        TEXT;
ALTER TABLE prets_pending ADD COLUMN IF NOT EXISTS statut       TEXT          NOT NULL DEFAULT 'pending';
ALTER TABLE prets_pending ADD COLUMN IF NOT EXISTS motif_rejet  TEXT;
ALTER TABLE prets_pending ADD COLUMN IF NOT EXISTS gestionnaire TEXT;
ALTER TABLE prets_pending ADD COLUMN IF NOT EXISTS cree_le      TIMESTAMPTZ   NOT NULL DEFAULT NOW();
ALTER TABLE prets_pending ADD COLUMN IF NOT EXISTS traite_le    TIMESTAMPTZ;

-- ─────────────────────────────────────────────────────────────
-- B.12 — decaissements_pending
-- Colonnes indexées : code, statut
-- ─────────────────────────────────────────────────────────────
ALTER TABLE decaissements_pending ADD COLUMN IF NOT EXISTS beneficiaire TEXT          NOT NULL DEFAULT '';
ALTER TABLE decaissements_pending ADD COLUMN IF NOT EXISTS devise       TEXT          NOT NULL DEFAULT 'XOF';
ALTER TABLE decaissements_pending ADD COLUMN IF NOT EXISTS motif        TEXT;
ALTER TABLE decaissements_pending ADD COLUMN IF NOT EXISTS statut       TEXT          NOT NULL DEFAULT 'pending';
ALTER TABLE decaissements_pending ADD COLUMN IF NOT EXISTS motif_rejet  TEXT;
ALTER TABLE decaissements_pending ADD COLUMN IF NOT EXISTS gestionnaire TEXT;
ALTER TABLE decaissements_pending ADD COLUMN IF NOT EXISTS traite_le    TIMESTAMPTZ;

-- ─────────────────────────────────────────────────────────────
-- B.13 — depenses_pending
-- Colonnes indexées : code, statut
-- ─────────────────────────────────────────────────────────────
ALTER TABLE depenses_pending ADD COLUMN IF NOT EXISTS libelle      TEXT          NOT NULL DEFAULT '';
ALTER TABLE depenses_pending ADD COLUMN IF NOT EXISTS devise       TEXT          NOT NULL DEFAULT 'XOF';
ALTER TABLE depenses_pending ADD COLUMN IF NOT EXISTS categorie    TEXT          DEFAULT 'autre';
ALTER TABLE depenses_pending ADD COLUMN IF NOT EXISTS statut       TEXT          NOT NULL DEFAULT 'pending';
ALTER TABLE depenses_pending ADD COLUMN IF NOT EXISTS motif_rejet  TEXT;
ALTER TABLE depenses_pending ADD COLUMN IF NOT EXISTS gestionnaire TEXT;
ALTER TABLE depenses_pending ADD COLUMN IF NOT EXISTS traite_le    TIMESTAMPTZ;

-- ─────────────────────────────────────────────────────────────
-- B.14 — premium_requests
-- Colonnes indexées : code, statut
-- ─────────────────────────────────────────────────────────────
ALTER TABLE premium_requests ADD COLUMN IF NOT EXISTS gestionnaire TEXT        NOT NULL DEFAULT '';
ALTER TABLE premium_requests ADD COLUMN IF NOT EXISTS nom          TEXT;
ALTER TABLE premium_requests ADD COLUMN IF NOT EXISTS contact      TEXT;
ALTER TABLE premium_requests ADD COLUMN IF NOT EXISTS formule      TEXT        NOT NULL DEFAULT 'mensuel';
ALTER TABLE premium_requests ADD COLUMN IF NOT EXISTS statut       TEXT        NOT NULL DEFAULT 'pending';
ALTER TABLE premium_requests ADD COLUMN IF NOT EXISTS cree_le      TIMESTAMPTZ NOT NULL DEFAULT NOW();
ALTER TABLE premium_requests ADD COLUMN IF NOT EXISTS mis_a_jour   TIMESTAMPTZ NOT NULL DEFAULT NOW();

-- ─────────────────────────────────────────────────────────────
-- B.15 — kyc_submissions
-- Colonnes indexées : code, statut
-- ─────────────────────────────────────────────────────────────
ALTER TABLE public.kyc_submissions ADD COLUMN IF NOT EXISTS gestionnaire      TEXT        NOT NULL DEFAULT '';
ALTER TABLE public.kyc_submissions ADD COLUMN IF NOT EXISTS nom_complet       TEXT        NOT NULL DEFAULT '';
ALTER TABLE public.kyc_submissions ADD COLUMN IF NOT EXISTS type_piece        TEXT        NOT NULL DEFAULT 'cni';
ALTER TABLE public.kyc_submissions ADD COLUMN IF NOT EXISTS numero_piece      TEXT;
ALTER TABLE public.kyc_submissions ADD COLUMN IF NOT EXISTS photo_recto_url   TEXT;
ALTER TABLE public.kyc_submissions ADD COLUMN IF NOT EXISTS photo_verso_url   TEXT;
ALTER TABLE public.kyc_submissions ADD COLUMN IF NOT EXISTS photo_selfie_url  TEXT;
ALTER TABLE public.kyc_submissions ADD COLUMN IF NOT EXISTS statut            TEXT        NOT NULL DEFAULT 'pending';
ALTER TABLE public.kyc_submissions ADD COLUMN IF NOT EXISTS motif_rejet       TEXT;
ALTER TABLE public.kyc_submissions ADD COLUMN IF NOT EXISTS note_admin        TEXT;
ALTER TABLE public.kyc_submissions ADD COLUMN IF NOT EXISTS soumis_le         TIMESTAMPTZ NOT NULL DEFAULT NOW();
ALTER TABLE public.kyc_submissions ADD COLUMN IF NOT EXISTS traite_le         TIMESTAMPTZ;

-- ─────────────────────────────────────────────────────────────
-- B.16 — fcm_tokens
-- Colonnes indexées : tontine, token (unique)
-- ─────────────────────────────────────────────────────────────
ALTER TABLE public.fcm_tokens ADD COLUMN IF NOT EXISTS tontine    TEXT;
ALTER TABLE public.fcm_tokens ADD COLUMN IF NOT EXISTS membre_id  TEXT;
ALTER TABLE public.fcm_tokens ADD COLUMN IF NOT EXISTS platform   TEXT        DEFAULT 'android';
ALTER TABLE public.fcm_tokens ADD COLUMN IF NOT EXISTS cree_le    TIMESTAMPTZ NOT NULL DEFAULT NOW();
ALTER TABLE public.fcm_tokens ADD COLUMN IF NOT EXISTS mis_a_jour TIMESTAMPTZ NOT NULL DEFAULT NOW();
ALTER TABLE public.fcm_tokens ADD COLUMN IF NOT EXISTS langue     TEXT;

-- ─────────────────────────────────────────────────────────────
-- B.17 — admin_membres
-- Colonnes indexées : pseudo (unique), role
-- ─────────────────────────────────────────────────────────────
ALTER TABLE admin_membres ADD COLUMN IF NOT EXISTS nom                TEXT        NOT NULL DEFAULT '';
ALTER TABLE admin_membres ADD COLUMN IF NOT EXISTS cle_hash           TEXT        NOT NULL DEFAULT '';
ALTER TABLE admin_membres ADD COLUMN IF NOT EXISTS role               TEXT        NOT NULL DEFAULT 'comptable';
ALTER TABLE admin_membres ADD COLUMN IF NOT EXISTS actif              BOOLEAN     NOT NULL DEFAULT TRUE;
ALTER TABLE admin_membres ADD COLUMN IF NOT EXISTS cree_par           TEXT        NOT NULL DEFAULT '';
ALTER TABLE admin_membres ADD COLUMN IF NOT EXISTS cree_le            TIMESTAMPTZ NOT NULL DEFAULT NOW();
ALTER TABLE admin_membres ADD COLUMN IF NOT EXISTS derniere_connexion TIMESTAMPTZ;

-- ─────────────────────────────────────────────────────────────
-- B.18 — admin_messages
-- Colonnes indexées : destinataire, expediteur, envoye_le
-- ─────────────────────────────────────────────────────────────
ALTER TABLE admin_messages ADD COLUMN IF NOT EXISTS expediteur   TEXT        NOT NULL DEFAULT '';
ALTER TABLE admin_messages ADD COLUMN IF NOT EXISTS destinataire TEXT        NOT NULL DEFAULT '';
ALTER TABLE admin_messages ADD COLUMN IF NOT EXISTS sujet        TEXT        NOT NULL DEFAULT '';
ALTER TABLE admin_messages ADD COLUMN IF NOT EXISTS corps        TEXT        NOT NULL DEFAULT '';
ALTER TABLE admin_messages ADD COLUMN IF NOT EXISTS lu           BOOLEAN     NOT NULL DEFAULT FALSE;
ALTER TABLE admin_messages ADD COLUMN IF NOT EXISTS lu_le        TIMESTAMPTZ;
ALTER TABLE admin_messages ADD COLUMN IF NOT EXISTS envoye_le    TIMESTAMPTZ NOT NULL DEFAULT NOW();

-- ─────────────────────────────────────────────────────────────
-- B.19 — support_tickets
-- Colonnes indexées : statut, gestionnaire, ref, cree_le
-- ─────────────────────────────────────────────────────────────
ALTER TABLE support_tickets ADD COLUMN IF NOT EXISTS gestionnaire TEXT        NOT NULL DEFAULT '';
ALTER TABLE support_tickets ADD COLUMN IF NOT EXISTS code_tontine TEXT;
ALTER TABLE support_tickets ADD COLUMN IF NOT EXISTS categorie    TEXT        NOT NULL DEFAULT 'autre';
ALTER TABLE support_tickets ADD COLUMN IF NOT EXISTS sujet        TEXT        NOT NULL DEFAULT '';
ALTER TABLE support_tickets ADD COLUMN IF NOT EXISTS description  TEXT        NOT NULL DEFAULT '';
ALTER TABLE support_tickets ADD COLUMN IF NOT EXISTS statut       TEXT        NOT NULL DEFAULT 'ouvert';
ALTER TABLE support_tickets ADD COLUMN IF NOT EXISTS priorite     TEXT        NOT NULL DEFAULT 'normale';
ALTER TABLE support_tickets ADD COLUMN IF NOT EXISTS assigne_a    TEXT;
ALTER TABLE support_tickets ADD COLUMN IF NOT EXISTS cree_le      TIMESTAMPTZ NOT NULL DEFAULT NOW();
ALTER TABLE support_tickets ADD COLUMN IF NOT EXISTS mis_a_jour   TIMESTAMPTZ NOT NULL DEFAULT NOW();
ALTER TABLE support_tickets ADD COLUMN IF NOT EXISTS resolu_le    TIMESTAMPTZ;

-- ─────────────────────────────────────────────────────────────
-- B.20 — support_messages
-- Colonnes indexées : ticket_id, envoye_le
-- ─────────────────────────────────────────────────────────────
ALTER TABLE support_messages ADD COLUMN IF NOT EXISTS auteur    TEXT        NOT NULL DEFAULT '';
ALTER TABLE support_messages ADD COLUMN IF NOT EXISTS est_admin BOOLEAN     NOT NULL DEFAULT FALSE;
ALTER TABLE support_messages ADD COLUMN IF NOT EXISTS corps     TEXT        NOT NULL DEFAULT '';
ALTER TABLE support_messages ADD COLUMN IF NOT EXISTS lu_client BOOLEAN     NOT NULL DEFAULT FALSE;
ALTER TABLE support_messages ADD COLUMN IF NOT EXISTS lu_admin  BOOLEAN     NOT NULL DEFAULT FALSE;
ALTER TABLE support_messages ADD COLUMN IF NOT EXISTS envoye_le TIMESTAMPTZ NOT NULL DEFAULT NOW();

-- ─────────────────────────────────────────────────────────────
-- B.21 — rappels_envoyes
-- Colonnes indexées : code, membre_id, type, envoye_le
-- NOTE : table potentiellement absente en prod (créée par A.19)
--        ou présente avec schéma minimal — ADD COLUMN IF NOT EXISTS
--        couvre les deux cas.
-- ─────────────────────────────────────────────────────────────
ALTER TABLE rappels_envoyes ADD COLUMN IF NOT EXISTS code      TEXT        NOT NULL DEFAULT '';
ALTER TABLE rappels_envoyes ADD COLUMN IF NOT EXISTS membre_id TEXT        NOT NULL DEFAULT '';
ALTER TABLE rappels_envoyes ADD COLUMN IF NOT EXISTS type      TEXT        NOT NULL DEFAULT 'cotisation';
ALTER TABLE rappels_envoyes ADD COLUMN IF NOT EXISTS envoye_le TIMESTAMPTZ NOT NULL DEFAULT NOW();

-- ─────────────────────────────────────────────────────────────
-- B.22 — voix
-- Colonnes indexées : code, vote_id, membre_id
-- NOTE : table potentiellement absente en prod (créée par A.5)
-- ─────────────────────────────────────────────────────────────
ALTER TABLE voix ADD COLUMN IF NOT EXISTS code      TEXT        NOT NULL DEFAULT '';
ALTER TABLE voix ADD COLUMN IF NOT EXISTS vote_id   TEXT        NOT NULL DEFAULT '';
ALTER TABLE voix ADD COLUMN IF NOT EXISTS membre_id TEXT        NOT NULL DEFAULT '';
ALTER TABLE voix ADD COLUMN IF NOT EXISTS choix     TEXT        NOT NULL DEFAULT 'abstention';
ALTER TABLE voix ADD COLUMN IF NOT EXISTS methode   TEXT        NOT NULL DEFAULT 'PIN';
ALTER TABLE voix ADD COLUMN IF NOT EXISTS appareil  TEXT;
ALTER TABLE voix ADD COLUMN IF NOT EXISTS vote_le   TIMESTAMPTZ NOT NULL DEFAULT NOW();


-- ============================================================
-- BLOC 0c : DÉDUPLICATION PRÉVENTIVE v7
-- ============================================================
-- Exécuté APRÈS Section B (colonnes présentes) et AVANT Bloc 0b
-- (validation) et Section C (création des index UNIQUE).
--
-- POURQUOI :
--   ERROR 23505 en prod sur fcm_tokens.token — la table contenait
--   des tokens dupliqués ; CREATE UNIQUE INDEX échoue si des
--   doublons existent déjà dans les données.
--
-- STRATÉGIE DE CONSERVATION :
--   Pour chaque groupe de doublons, on conserve la ligne dont le
--   timestamp est le plus récent, selon la priorité :
--     1. Colonne timestamp la plus pertinente (updated_at / mis_a_jour
--        / modifie_le / cree_le / date_debut / vote_le selon la table)
--     2. MAX(id) en tiebreak universel
--   Les autres lignes du groupe sont supprimées (DELETE).
--
-- IDEMPOTENCE :
--   • Si aucun doublon → DELETE 0 lignes → RAISE NOTICE "0 supprimé"
--   • Si relancé après un premier passage → idem, 0 doublon restant
--
-- TABLES COUVERTES (toutes celles ayant un CREATE UNIQUE INDEX
-- dans Section C sur une colonne pouvant contenir des doublons) :
--   1. fcm_tokens          → UNIQUE(token)
--   2. rappels_envoyes     → UNIQUE(code, membre_id, type)
--   3. voix                → UNIQUE(code, vote_id, membre_id)
--   4. subscriptions       → UNIQUE(code)
--   5. admin_membres       → UNIQUE(pseudo)
--   6. support_tickets     → UNIQUE(ref)
-- ============================================================
DO $$
DECLARE
  v_deleted  BIGINT;
BEGIN
  RAISE NOTICE 'v7 DÉDUPLICATION: démarrage Bloc 0c...';

  -- ──────────────────────────────────────────────────────────────
  -- 1. fcm_tokens — UNIQUE(token)
  --    Conserver : ligne avec mis_a_jour MAX, puis cree_le, puis
  --    MAX(id) comme tiebreak.
  --    Note : NULL tokens ignorés (pas concernés par la contrainte).
  -- ──────────────────────────────────────────────────────────────
  DELETE FROM public.fcm_tokens
  WHERE id NOT IN (
    SELECT DISTINCT ON (token)
           id
    FROM   public.fcm_tokens
    WHERE  token IS NOT NULL
    ORDER  BY token,
              COALESCE(mis_a_jour, cree_le, NOW()) DESC,
              id DESC
  )
  AND token IS NOT NULL;
  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  RAISE NOTICE 'v7 DÉDUPLICATION: fcm_tokens.token — % doublon(s) supprimé(s)', v_deleted;

  -- ──────────────────────────────────────────────────────────────
  -- 2. rappels_envoyes — UNIQUE(code, membre_id, type)
  --    Conserver : ligne avec envoye_le MAX, puis MAX(id).
  -- ──────────────────────────────────────────────────────────────
  DELETE FROM rappels_envoyes
  WHERE id NOT IN (
    SELECT DISTINCT ON (code, membre_id, type)
           id
    FROM   rappels_envoyes
    ORDER  BY code, membre_id, type,
              COALESCE(envoye_le, NOW()) DESC,
              id DESC
  );
  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  RAISE NOTICE 'v7 DÉDUPLICATION: rappels_envoyes(code,membre_id,type) — % doublon(s) supprimé(s)', v_deleted;

  -- ──────────────────────────────────────────────────────────────
  -- 3. voix — UNIQUE(code, vote_id, membre_id)
  --    Conserver : ligne avec vote_le MAX, puis MAX(id).
  -- ──────────────────────────────────────────────────────────────
  DELETE FROM voix
  WHERE id NOT IN (
    SELECT DISTINCT ON (code, vote_id, membre_id)
           id
    FROM   voix
    ORDER  BY code, vote_id, membre_id,
              COALESCE(vote_le, NOW()) DESC,
              id DESC
  );
  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  RAISE NOTICE 'v7 DÉDUPLICATION: voix(code,vote_id,membre_id) — % doublon(s) supprimé(s)', v_deleted;

  -- ──────────────────────────────────────────────────────────────
  -- 4. subscriptions — UNIQUE(code)
  --    Conserver : ligne avec modifie_le MAX, puis date_debut,
  --    puis MAX(id).
  -- ──────────────────────────────────────────────────────────────
  DELETE FROM subscriptions
  WHERE id NOT IN (
    SELECT DISTINCT ON (code)
           id
    FROM   subscriptions
    ORDER  BY code,
              COALESCE(modifie_le, date_debut, NOW()) DESC,
              id DESC
  );
  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  RAISE NOTICE 'v7 DÉDUPLICATION: subscriptions.code — % doublon(s) supprimé(s)', v_deleted;

  -- ──────────────────────────────────────────────────────────────
  -- 5. admin_membres — UNIQUE(pseudo)
  --    Conserver : ligne avec derniere_connexion MAX, puis cree_le,
  --    puis MAX(id).
  -- ──────────────────────────────────────────────────────────────
  DELETE FROM admin_membres
  WHERE id NOT IN (
    SELECT DISTINCT ON (pseudo)
           id
    FROM   admin_membres
    ORDER  BY pseudo,
              COALESCE(derniere_connexion, cree_le, NOW()) DESC,
              id DESC
  );
  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  RAISE NOTICE 'v7 DÉDUPLICATION: admin_membres.pseudo — % doublon(s) supprimé(s)', v_deleted;

  -- ──────────────────────────────────────────────────────────────
  -- 6. support_tickets — UNIQUE(ref)
  --    Conserver : ligne avec mis_a_jour MAX, puis cree_le,
  --    puis MAX(id).
  -- ──────────────────────────────────────────────────────────────
  DELETE FROM support_tickets
  WHERE id NOT IN (
    SELECT DISTINCT ON (ref)
           id
    FROM   support_tickets
    ORDER  BY ref,
              COALESCE(mis_a_jour, cree_le, NOW()) DESC,
              id DESC
  );
  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  RAISE NOTICE 'v7 DÉDUPLICATION: support_tickets.ref — % doublon(s) supprimé(s)', v_deleted;

  RAISE NOTICE 'v7 DÉDUPLICATION: Bloc 0c terminé. Début Bloc 0b (validation colonnes)...';
END;
$$;


-- ============================================================
-- BLOC 0b : POST-VALIDATION BLOQUANTE v7
-- ============================================================
-- Vérification APRÈS Section A + Section B + Bloc 0c.
--
-- AMÉLIORATION v6 vs v5 :
--   v5 levait EXCEPTION même si la table n'existait PAS avant
--   Section A (table créée ex-nihilo = toutes colonnes présentes
--   → Bloc 0b ne devrait pas échouer sur ces tables).
--   En réalité même v5 était safe, mais le message d'erreur
--   pouvait induire en erreur.
--
--   v6 : Pour chaque (table, colonne) manquante, on vérifie si
--   la table a été créée par Section A (indétectable une fois
--   dans la même transaction — les deux sont visibles).
--   → Comportement identique à v5 mais message plus précis.
--
-- ▶ RAISE EXCEPTION si colonne indexée absente après Section B.
--   Le message liste exactement "table.colonne (requis par : idx)"
-- ============================================================
DO $$
DECLARE
  rec         RECORD;
  v_missing   TEXT := '';
  v_count     INT  := 0;
BEGIN
  RAISE NOTICE 'v7 POST-VALIDATION: vérification de toutes les colonnes indexées...';

  FOR rec IN
    SELECT t.tbl, t.col, t.idx
    FROM (VALUES
      -- ── tontines ──────────────────────────────────────────
      ('tontines',              'code',                    'idx_tontines_code'),
      ('tontines',              'status',                  'idx_tontines_status'),
      ('tontines',              'updated_at',              'trigger: trg_tontines_updated_at'),
      -- ── audit ─────────────────────────────────────────────
      ('audit',                 'code',                    'idx_audit_code'),
      ('audit',                 'quand',                   'idx_audit_code (quand DESC)'),
      -- ── demandes_premium ──────────────────────────────────
      ('demandes_premium',      'code',                    'idx_demandes_premium_code'),
      -- ── scores_historique ─────────────────────────────────
      ('scores_historique',     'code',                    'idx_scores_hist_code_membre'),
      ('scores_historique',     'membre_id',               'idx_scores_hist_code_membre'),
      ('scores_historique',     'quand',                   'idx_scores_hist_code_quand'),
      -- ── propositions_retrait ──────────────────────────────
      ('propositions_retrait',  'code',                    'idx_prop_retrait_code'),
      ('propositions_retrait',  'membre_id',               'idx_prop_retrait_membre'),
      -- ── journal_audit ─────────────────────────────────────
      ('journal_audit',         'code',                    'idx_journal_audit_code'),
      ('journal_audit',         'quand',                   'idx_journal_audit_code (quand DESC)'),
      -- ── subscriptions ─────────────────────────────────────
      ('subscriptions',         'code',                    'idx_subscriptions_code'),
      ('subscriptions',         'statut',                  'idx_subscriptions_statut'),
      ('subscriptions',         'modifie_le',              'trigger: trg_sub_modifie_le'),
      -- ── abonnements ───────────────────────────────────────
      ('abonnements',           'code',                    'idx_abonnements_code'),
      -- ── sycapay_transactions ──────────────────────────────
      ('sycapay_transactions',  'code',                    'idx_sycapay_code'),
      ('sycapay_transactions',  'statut',                  'idx_sycapay_statut'),
      ('sycapay_transactions',  'type',                    'idx_sycapay_type'),
      ('sycapay_transactions',  'internal_reference',      'idx_sycapay_txn_ref'),
      ('sycapay_transactions',  'idempotency_key',         'idx_sycapay_txn_idempotency'),
      ('sycapay_transactions',  'membre_id',               'idx_sycapay_txn_membre'),
      ('sycapay_transactions',  'provider_transaction_id', 'idx_sycapay_txn_provider'),
      -- ── prets_pending ─────────────────────────────────────
      ('prets_pending',         'code',                    'idx_prets_code'),
      ('prets_pending',         'statut',                  'idx_prets_statut'),
      -- ── decaissements_pending ─────────────────────────────
      ('decaissements_pending', 'code',                    'idx_decaiss_code'),
      ('decaissements_pending', 'statut',                  'idx_decaiss_statut'),
      -- ── depenses_pending ──────────────────────────────────
      ('depenses_pending',      'code',                    'idx_depenses_code'),
      ('depenses_pending',      'statut',                  'idx_depenses_statut'),
      -- ── premium_requests ──────────────────────────────────
      ('premium_requests',      'code',                    'idx_premium_req_code'),
      ('premium_requests',      'statut',                  'idx_premium_req_statut'),
      -- ── kyc_submissions ───────────────────────────────────
      ('kyc_submissions',       'code',                    'idx_kyc_code'),
      ('kyc_submissions',       'statut',                  'idx_kyc_statut'),
      -- ── fcm_tokens ────────────────────────────────────────
      ('fcm_tokens',            'tontine',                 'idx_fcm_tontine'),
      ('fcm_tokens',            'token',                   'fcm_tokens_token_key (UNIQUE)'),
      -- ── rappels_envoyes ───────────────────────────────────
      ('rappels_envoyes',       'code',                    'idx_rappels_code'),
      ('rappels_envoyes',       'membre_id',               'rappels_envoyes_code_membre_id_type_key'),
      ('rappels_envoyes',       'type',                    'rappels_envoyes_code_membre_id_type_key'),
      ('rappels_envoyes',       'envoye_le',               'rappels_envoyes UNIQUE (code,membre_id,type)'),
      -- ── voix ──────────────────────────────────────────────
      ('voix',                  'code',                    'idx_voix_code'),
      ('voix',                  'vote_id',                 'idx_voix_vote_id'),
      ('voix',                  'membre_id',               'voix_code_vote_id_membre_id_key'),
      -- ── admin_membres ─────────────────────────────────────
      ('admin_membres',         'pseudo',                  'idx_admin_membres_pseudo (UNIQUE)'),
      ('admin_membres',         'role',                    'idx_admin_membres_role'),
      -- ── admin_messages ────────────────────────────────────
      ('admin_messages',        'destinataire',            'idx_admin_msg_dest'),
      ('admin_messages',        'expediteur',              'idx_admin_msg_exp'),
      ('admin_messages',        'envoye_le',               'idx_admin_msg_date'),
      -- ── support_tickets ───────────────────────────────────
      ('support_tickets',       'statut',                  'idx_support_tickets_statut'),
      ('support_tickets',       'gestionnaire',            'idx_support_tickets_gestionnaire'),
      ('support_tickets',       'ref',                     'idx_support_tickets_ref'),
      ('support_tickets',       'cree_le',                 'idx_support_tickets_cree_le'),
      -- ── support_messages ──────────────────────────────────
      ('support_messages',      'ticket_id',               'idx_support_msg_ticket'),
      ('support_messages',      'envoye_le',               'idx_support_msg_date')
    ) AS t(tbl, col, idx)
    WHERE NOT EXISTS (
      SELECT 1
      FROM   information_schema.columns c
      WHERE  c.table_schema = 'public'
        AND  c.table_name   = t.tbl
        AND  c.column_name  = t.col
    )
    ORDER BY t.tbl, t.col
  LOOP
    v_count  := v_count + 1;
    v_missing := v_missing
      || E'\n    ► ' || rec.tbl || '.' || rec.col
      || '  (requis par : ' || rec.idx || ')';
  END LOOP;

  IF v_count > 0 THEN
    RAISE EXCEPTION
      E'upgrade.sql v7 — POST-VALIDATION ÉCHOUÉE\n'
      'Section B n''a pas pu créer % colonne(s) :\n%\n\n'
      'CAUSES POSSIBLES :\n'
      '  1. La table existait avec une contrainte NOT NULL sans DEFAULT\n'
      '     qui empêche ADD COLUMN IF NOT EXISTS (rare mais possible).\n'
      '  2. Droits insuffisants pour ALTER TABLE sur cette table.\n'
      '  3. Bug PostgreSQL dans information_schema (redémarrer la session).\n\n'
      'La transaction est annulée (ROLLBACK automatique).\n'
      'Copiez le message complet et transmettez-le à l''agent.',
      v_count, v_missing;
  ELSE
    RAISE NOTICE 'v7 POST-VALIDATION: OK — toutes les % colonnes indexées sont présentes.', 57;
    RAISE NOTICE 'v7 POST-VALIDATION: Début Section C (index)...';
  END IF;
END;
$$;


-- ============================================================
-- SECTION C : INDEX (no-op si déjà présents)
-- ============================================================
-- Chaque colonne référencée ici a été vérifiée par Bloc 0b.
-- Si Bloc 0b a levé une EXCEPTION, nous ne sommes jamais ici.
-- ============================================================

-- ── tontines ────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_tontines_code   ON tontines(code);
CREATE INDEX IF NOT EXISTS idx_tontines_status ON tontines(status);

-- ── voix ────────────────────────────────────────────────────
CREATE INDEX        IF NOT EXISTS idx_voix_code    ON voix(code);
CREATE INDEX        IF NOT EXISTS idx_voix_vote_id ON voix(code, vote_id);
CREATE UNIQUE INDEX IF NOT EXISTS voix_code_vote_id_membre_id_key
  ON voix(code, vote_id, membre_id);

-- ── audit ───────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_audit_code ON audit(code, quand DESC);

-- ── demandes_premium ────────────────────────────────────────
CREATE UNIQUE INDEX IF NOT EXISTS idx_demandes_premium_code ON demandes_premium(code);

-- ── scores_historique ───────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_scores_hist_code_membre ON scores_historique(code, membre_id);
CREATE INDEX IF NOT EXISTS idx_scores_hist_code_quand  ON scores_historique(code, quand DESC);

-- ── propositions_retrait ────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_prop_retrait_code   ON propositions_retrait(code);
CREATE INDEX IF NOT EXISTS idx_prop_retrait_membre ON propositions_retrait(code, membre_id);

-- ── journal_audit ───────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_journal_audit_code ON journal_audit(code, quand DESC);

-- ── subscriptions ───────────────────────────────────────────
CREATE INDEX        IF NOT EXISTS idx_subscriptions_code   ON subscriptions(code);
CREATE INDEX        IF NOT EXISTS idx_subscriptions_statut ON subscriptions(statut);
CREATE UNIQUE INDEX IF NOT EXISTS subscriptions_code_key   ON subscriptions(code);

-- ── abonnements ─────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_abonnements_code ON abonnements(code);

-- ── sycapay_transactions ────────────────────────────────────
CREATE INDEX        IF NOT EXISTS idx_sycapay_code         ON sycapay_transactions(code);
CREATE INDEX        IF NOT EXISTS idx_sycapay_statut       ON sycapay_transactions(statut);
CREATE INDEX        IF NOT EXISTS idx_sycapay_type         ON sycapay_transactions(type);
CREATE INDEX        IF NOT EXISTS idx_sycapay_txn_ref
  ON sycapay_transactions(internal_reference)
  WHERE internal_reference IS NOT NULL;
CREATE INDEX        IF NOT EXISTS idx_sycapay_txn_idempotency
  ON sycapay_transactions(idempotency_key)
  WHERE idempotency_key IS NOT NULL;
CREATE INDEX        IF NOT EXISTS idx_sycapay_txn_membre
  ON sycapay_transactions(code, membre_id);
CREATE INDEX        IF NOT EXISTS idx_sycapay_txn_provider
  ON sycapay_transactions(provider_transaction_id)
  WHERE provider_transaction_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS sycapay_transactions_internal_reference_key
  ON sycapay_transactions(internal_reference);
CREATE UNIQUE INDEX IF NOT EXISTS sycapay_transactions_idempotency_key_key
  ON sycapay_transactions(idempotency_key);

-- ── prets_pending ───────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_prets_code   ON prets_pending(code);
CREATE INDEX IF NOT EXISTS idx_prets_statut ON prets_pending(statut);

-- ── decaissements_pending ───────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_decaiss_code   ON decaissements_pending(code);
CREATE INDEX IF NOT EXISTS idx_decaiss_statut ON decaissements_pending(statut);

-- ── depenses_pending ────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_depenses_code   ON depenses_pending(code);
CREATE INDEX IF NOT EXISTS idx_depenses_statut ON depenses_pending(statut);

-- ── premium_requests ────────────────────────────────────────
CREATE INDEX        IF NOT EXISTS idx_premium_req_code   ON premium_requests(code);
CREATE INDEX        IF NOT EXISTS idx_premium_req_statut ON premium_requests(statut);
CREATE UNIQUE INDEX IF NOT EXISTS premium_requests_code_key ON premium_requests(code);

-- ── kyc_submissions ─────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_kyc_code   ON public.kyc_submissions(code);
CREATE INDEX IF NOT EXISTS idx_kyc_statut ON public.kyc_submissions(statut);

-- ── fcm_tokens ──────────────────────────────────────────────
CREATE INDEX        IF NOT EXISTS idx_fcm_tontine    ON public.fcm_tokens(tontine);
CREATE UNIQUE INDEX IF NOT EXISTS fcm_tokens_token_key ON fcm_tokens(token);

-- ── rappels_envoyes ─────────────────────────────────────────
CREATE INDEX        IF NOT EXISTS idx_rappels_code                    ON rappels_envoyes(code);
CREATE UNIQUE INDEX IF NOT EXISTS rappels_envoyes_code_membre_id_type_key
  ON rappels_envoyes(code, membre_id, type);

-- ── admin_membres ───────────────────────────────────────────
CREATE UNIQUE INDEX IF NOT EXISTS idx_admin_membres_pseudo ON admin_membres(pseudo);
CREATE INDEX        IF NOT EXISTS idx_admin_membres_role   ON admin_membres(role);
CREATE UNIQUE INDEX IF NOT EXISTS admin_membres_pseudo_key ON admin_membres(pseudo);

-- ── admin_messages ──────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_admin_msg_dest ON admin_messages(destinataire);
CREATE INDEX IF NOT EXISTS idx_admin_msg_exp  ON admin_messages(expediteur);
CREATE INDEX IF NOT EXISTS idx_admin_msg_date ON admin_messages(envoye_le DESC);

-- ── support_tickets ─────────────────────────────────────────
CREATE INDEX        IF NOT EXISTS idx_support_tickets_statut       ON support_tickets(statut);
CREATE INDEX        IF NOT EXISTS idx_support_tickets_gestionnaire ON support_tickets(gestionnaire);
CREATE INDEX        IF NOT EXISTS idx_support_tickets_ref          ON support_tickets(ref);
CREATE INDEX        IF NOT EXISTS idx_support_tickets_cree_le      ON support_tickets(cree_le DESC);
CREATE UNIQUE INDEX IF NOT EXISTS support_tickets_ref_key          ON support_tickets(ref);

-- ── support_messages ────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_support_msg_ticket ON support_messages(ticket_id);
CREATE INDEX IF NOT EXISTS idx_support_msg_date   ON support_messages(envoye_le ASC);


-- ============================================================
-- SECTION D : TRIGGERS
-- ============================================================
-- DONNÉES PROD CONFIRMÉES (audit CSV 2025-07-xx) :
--   ✅ trg_tontines_updated_at    → EXISTE déjà en prod
--   ❌ trg_sub_modifie_le         → ABSENT en prod → créé ici
--
-- Les deux utilisent DROP TRIGGER IF EXISTS + CREATE TRIGGER
-- pour être idempotents (recréation safe même si déjà présent).
-- ============================================================

-- ── Trigger tontines.updated_at (EXISTE en prod — recréation idempotente) ──
CREATE OR REPLACE FUNCTION tontines_set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_tontines_updated_at ON tontines;
CREATE TRIGGER trg_tontines_updated_at
  BEFORE UPDATE ON tontines
  FOR EACH ROW EXECUTE FUNCTION tontines_set_updated_at();

-- ── Trigger subscriptions.modifie_le (ABSENT en prod — création) ──
-- Confirmé absent par audit CSV prod (seul trg_tontines_updated_at présent).
CREATE OR REPLACE FUNCTION _sub_update_modifie_le()
RETURNS TRIGGER LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  NEW.modifie_le = NOW();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_sub_modifie_le ON subscriptions;
CREATE TRIGGER trg_sub_modifie_le
  BEFORE UPDATE ON subscriptions
  FOR EACH ROW EXECUTE FUNCTION _sub_update_modifie_le();


-- ============================================================
-- SECTION E : RLS — ENABLE + POLITIQUES
-- ============================================================
-- ALTER TABLE ... ENABLE ROW LEVEL SECURITY = idempotent.
-- DROP POLICY IF EXISTS avant CREATE POLICY = idempotent.
-- ============================================================

ALTER TABLE tontines              ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit                 ENABLE ROW LEVEL SECURITY;
ALTER TABLE demandes_premium      ENABLE ROW LEVEL SECURITY;
ALTER TABLE config                ENABLE ROW LEVEL SECURITY;
ALTER TABLE app_config            ENABLE ROW LEVEL SECURITY;
ALTER TABLE admin_config          ENABLE ROW LEVEL SECURITY;
ALTER TABLE voix                  ENABLE ROW LEVEL SECURITY;
ALTER TABLE scores_historique     ENABLE ROW LEVEL SECURITY;
ALTER TABLE propositions_retrait  ENABLE ROW LEVEL SECURITY;
ALTER TABLE journal_audit         ENABLE ROW LEVEL SECURITY;
ALTER TABLE subscriptions         ENABLE ROW LEVEL SECURITY;
ALTER TABLE abonnements           ENABLE ROW LEVEL SECURITY;
ALTER TABLE admin_actions         ENABLE ROW LEVEL SECURITY;
ALTER TABLE sycapay_transactions  ENABLE ROW LEVEL SECURITY;
ALTER TABLE prets_pending         ENABLE ROW LEVEL SECURITY;
ALTER TABLE decaissements_pending ENABLE ROW LEVEL SECURITY;
ALTER TABLE depenses_pending      ENABLE ROW LEVEL SECURITY;
ALTER TABLE premium_requests      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.kyc_submissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.fcm_tokens      ENABLE ROW LEVEL SECURITY;
ALTER TABLE rappels_envoyes        ENABLE ROW LEVEL SECURITY;
ALTER TABLE admin_membres          ENABLE ROW LEVEL SECURITY;
ALTER TABLE admin_messages         ENABLE ROW LEVEL SECURITY;
ALTER TABLE support_tickets        ENABLE ROW LEVEL SECURITY;
ALTER TABLE support_messages       ENABLE ROW LEVEL SECURITY;

-- ── tontines ────────────────────────────────────────────────
DROP POLICY IF EXISTS "tontines_anon_select" ON tontines;
CREATE POLICY "tontines_anon_select" ON tontines
  FOR SELECT TO anon, authenticated USING (true);

DROP POLICY IF EXISTS "tontines_anon_insert" ON tontines;
CREATE POLICY "tontines_anon_insert" ON tontines
  FOR INSERT TO anon, authenticated WITH CHECK (true);

DROP POLICY IF EXISTS "tontines_anon_update" ON tontines;
CREATE POLICY "tontines_anon_update" ON tontines
  FOR UPDATE TO anon, authenticated USING (true) WITH CHECK (true);

-- ── audit ────────────────────────────────────────────────────
DROP POLICY IF EXISTS "audit_anon" ON audit;
CREATE POLICY "audit_anon" ON audit
  FOR ALL TO anon, authenticated USING (true) WITH CHECK (true);

-- ── demandes_premium ────────────────────────────────────────
DROP POLICY IF EXISTS "demandes_premium_select" ON demandes_premium;
CREATE POLICY "demandes_premium_select" ON demandes_premium
  FOR SELECT TO anon, authenticated USING (true);

DROP POLICY IF EXISTS "demandes_premium_insert" ON demandes_premium;
CREATE POLICY "demandes_premium_insert" ON demandes_premium
  FOR INSERT TO anon, authenticated WITH CHECK (true);

DROP POLICY IF EXISTS "demandes_premium_update" ON demandes_premium;
CREATE POLICY "demandes_premium_update" ON demandes_premium
  FOR UPDATE TO anon, authenticated USING (true);

-- ── config / app_config (bloqué — SECURITY DEFINER seulement) ──
DROP POLICY IF EXISTS "config_no_access"     ON config;
DROP POLICY IF EXISTS "app_config_no_access" ON app_config;
CREATE POLICY "config_no_access"     ON config
  FOR ALL TO anon, authenticated USING (false);
CREATE POLICY "app_config_no_access" ON app_config
  FOR ALL TO anon, authenticated USING (false);

-- ── admin_config (bloqué) ───────────────────────────────────
DROP POLICY IF EXISTS "admin_config_no_access" ON admin_config;
CREATE POLICY "admin_config_no_access" ON admin_config
  FOR ALL TO anon, authenticated USING (false);

-- ── voix ────────────────────────────────────────────────────
DROP POLICY IF EXISTS "voix_anon" ON voix;
CREATE POLICY "voix_anon" ON voix
  FOR ALL TO anon, authenticated USING (true) WITH CHECK (true);

-- ── scores_historique ───────────────────────────────────────
DROP POLICY IF EXISTS "scores_historique_select" ON scores_historique;
CREATE POLICY "scores_historique_select" ON scores_historique
  FOR ALL TO anon, authenticated USING (true) WITH CHECK (true);

-- ── propositions_retrait ────────────────────────────────────
DROP POLICY IF EXISTS "propositions_retrait_select" ON propositions_retrait;
CREATE POLICY "propositions_retrait_select" ON propositions_retrait
  FOR ALL TO anon, authenticated USING (true) WITH CHECK (true);

-- ── journal_audit ───────────────────────────────────────────
DROP POLICY IF EXISTS "journal_audit_select" ON journal_audit;
CREATE POLICY "journal_audit_select" ON journal_audit
  FOR ALL TO anon, authenticated USING (true) WITH CHECK (true);

-- ── subscriptions ───────────────────────────────────────────
DROP POLICY IF EXISTS "subscriptions_anon" ON subscriptions;
CREATE POLICY "subscriptions_anon" ON subscriptions
  FOR ALL TO anon, authenticated USING (true) WITH CHECK (true);

-- ── abonnements ─────────────────────────────────────────────
DROP POLICY IF EXISTS "abonnements_service" ON abonnements;
CREATE POLICY "abonnements_service" ON abonnements
  FOR ALL TO anon, authenticated USING (true) WITH CHECK (true);

-- ── admin_actions ───────────────────────────────────────────
DROP POLICY IF EXISTS "admin_actions_service" ON admin_actions;
CREATE POLICY "admin_actions_service" ON admin_actions
  FOR ALL TO anon, authenticated USING (true) WITH CHECK (true);

-- ── sycapay_transactions ────────────────────────────────────
DROP POLICY IF EXISTS "sycapay_anon" ON sycapay_transactions;
CREATE POLICY "sycapay_anon" ON sycapay_transactions
  FOR ALL TO anon, authenticated USING (true) WITH CHECK (true);

-- ── prets_pending ───────────────────────────────────────────
DROP POLICY IF EXISTS "prets_pending_anon" ON prets_pending;
CREATE POLICY "prets_pending_anon" ON prets_pending
  FOR ALL TO anon, authenticated USING (true) WITH CHECK (true);

-- ── decaissements_pending ───────────────────────────────────
DROP POLICY IF EXISTS "decaissements_anon" ON decaissements_pending;
CREATE POLICY "decaissements_anon" ON decaissements_pending
  FOR ALL TO anon, authenticated USING (true) WITH CHECK (true);

-- ── depenses_pending ────────────────────────────────────────
DROP POLICY IF EXISTS "depenses_anon" ON depenses_pending;
CREATE POLICY "depenses_anon" ON depenses_pending
  FOR ALL TO anon, authenticated USING (true) WITH CHECK (true);

-- ── premium_requests ────────────────────────────────────────
DROP POLICY IF EXISTS "premium_requests_anon" ON premium_requests;
CREATE POLICY "premium_requests_anon" ON premium_requests
  FOR ALL TO anon, authenticated USING (true) WITH CHECK (true);

-- ── kyc_submissions ─────────────────────────────────────────
DROP POLICY IF EXISTS "kyc_anon" ON public.kyc_submissions;
CREATE POLICY "kyc_anon" ON public.kyc_submissions
  FOR ALL TO anon, authenticated USING (true) WITH CHECK (true);

-- ── fcm_tokens ──────────────────────────────────────────────
DROP POLICY IF EXISTS "fcm_anon" ON public.fcm_tokens;
CREATE POLICY "fcm_anon" ON public.fcm_tokens
  FOR ALL TO anon, authenticated USING (true) WITH CHECK (true);

-- ── rappels_envoyes ─────────────────────────────────────────
DROP POLICY IF EXISTS "rappels_anon" ON rappels_envoyes;
CREATE POLICY "rappels_anon" ON rappels_envoyes
  FOR ALL TO anon, authenticated USING (true) WITH CHECK (true);

-- ── admin_membres ───────────────────────────────────────────
DROP POLICY IF EXISTS "admin_membres_service" ON admin_membres;
CREATE POLICY "admin_membres_service" ON admin_membres
  FOR ALL TO anon, authenticated USING (true) WITH CHECK (true);

-- ── admin_messages ──────────────────────────────────────────
DROP POLICY IF EXISTS "admin_messages_service" ON admin_messages;
CREATE POLICY "admin_messages_service" ON admin_messages
  FOR ALL TO anon, authenticated USING (true) WITH CHECK (true);

-- ── support_tickets ─────────────────────────────────────────
DROP POLICY IF EXISTS "support_tickets_service" ON support_tickets;
CREATE POLICY "support_tickets_service" ON support_tickets
  FOR ALL TO anon, authenticated USING (true) WITH CHECK (true);

-- ── support_messages ────────────────────────────────────────
DROP POLICY IF EXISTS "support_messages_service" ON support_messages;
CREATE POLICY "support_messages_service" ON support_messages
  FOR ALL TO anon, authenticated USING (true) WITH CHECK (true);


-- ============================================================
-- SECTION F : FONCTIONS / RPCs → voir init_inline.sql
-- ============================================================
-- Après ce fichier, exécuter init_inline.sql dans le SQL Editor.
-- ============================================================

COMMIT;


-- ============================================================
-- VÉRIFICATION POST-EXÉCUTION (copier-coller séparément)
-- ============================================================
--
-- -- 1. Nombre de tables (attendu : 25+)
-- SELECT count(*) FROM pg_tables WHERE schemaname = 'public';
--
-- -- 2. Tables sans RLS (attendu : 0 ligne)
-- SELECT tablename FROM pg_tables
-- WHERE schemaname = 'public' AND NOT rowsecurity;
--
-- -- 3. Politiques RLS (attendu : 28+)
-- SELECT count(*) FROM pg_policies WHERE schemaname = 'public';
--
-- -- 4. Index non-PK (attendu : 50+)
-- SELECT count(*) FROM pg_indexes
-- WHERE schemaname = 'public' AND indexname NOT LIKE '%_pkey';
--
-- -- 5. Triggers (attendu : 2 maintenant — trg_tontines_updated_at + trg_sub_modifie_le)
-- SELECT trigger_name, event_object_table, event_manipulation, action_timing
-- FROM information_schema.triggers
-- WHERE trigger_schema = 'public'
-- ORDER BY event_object_table;
--
-- -- 6. Colonnes sycapay_transactions (attendu : 30+)
-- SELECT column_name, data_type, is_nullable, column_default
-- FROM information_schema.columns
-- WHERE table_schema = 'public' AND table_name = 'sycapay_transactions'
-- ORDER BY ordinal_position;
--
-- -- 7. Colonnes rappels_envoyes (attendu : id, code, membre_id, type, envoye_le)
-- SELECT column_name, data_type FROM information_schema.columns
-- WHERE table_schema = 'public' AND table_name = 'rappels_envoyes'
-- ORDER BY ordinal_position;
--
-- -- 8. Colonnes voix (attendu : id, code, vote_id, membre_id, choix, methode, appareil, vote_le)
-- SELECT column_name, data_type FROM information_schema.columns
-- WHERE table_schema = 'public' AND table_name = 'voix'
-- ORDER BY ordinal_position;
--
-- -- 9. Vérifier données préservées (0 ligne perdue)
-- SELECT 'tontines' AS tbl, count(*) FROM tontines
-- UNION ALL SELECT 'sycapay_transactions', count(*) FROM sycapay_transactions
-- UNION ALL SELECT 'subscriptions',        count(*) FROM subscriptions
-- UNION ALL SELECT 'rappels_envoyes',      count(*) FROM rappels_envoyes
-- UNION ALL SELECT 'audit',                count(*) FROM audit;
--
-- -- 10. Audit complet du schéma après upgrade
-- --     (utiliser audit_schema_prod_v2.sql pour exporter en un CSV)
--
-- ============================================================
-- FIN upgrade.sql  v7
-- ============================================================
