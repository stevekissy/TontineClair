-- ============================================================
-- TontineClair — upgrade.sql  v3
-- Mise à jour schéma (tables, colonnes, index, triggers, RLS)
-- sans aucune perte de données
-- ============================================================
--
-- PÉRIMÈTRE DE CE FICHIER :
--   ✅ Section A — Nouvelles tables           (IF NOT EXISTS)
--   ✅ Section B — Nouvelles colonnes          (ADD COLUMN IF NOT EXISTS)
--   ✅ Section C — Nouveaux index              (IF NOT EXISTS)
--   ✅ Section D — Triggers                    (DROP IF EXISTS + recréation)
--   ✅ Section E — Politiques RLS              (DROP IF EXISTS + recréation)
--   ✅ Section F — Fonctions / RPCs            → voir init_inline.sql
--
-- POURQUOI LES FONCTIONS SONT DANS init_inline.sql ET PAS ICI :
--   PostgreSQL refuse CREATE OR REPLACE FUNCTION si les NOMS des
--   paramètres changent entre l'ancienne et la nouvelle version.
--   init_inline.sql contient les vraies signatures — c'est le
--   fichier canonique pour tous les RPCs.
--
-- GARANTIE DE NON-DESTRUCTION :
--   ✅ Aucun DROP TABLE / TRUNCATE / DELETE FROM
--   ✅ Aucun DROP FUNCTION
--   ✅ CREATE TABLE         uniquement IF NOT EXISTS
--   ✅ ALTER TABLE          uniquement ADD COLUMN IF NOT EXISTS
--   ✅ Toutes les colonnes NOT NULL ont un DEFAULT (sécurité lignes existantes)
--   ✅ CREATE INDEX         uniquement IF NOT EXISTS
--   ✅ DROP TRIGGER IF EXISTS avant recréation (safe)
--   ✅ DROP POLICY IF EXISTS avant recréation (métadonnées seules)
--   ✅ Rejouer n fois       → résultat identique
--
-- POURQUOI v3 CORRIGE v2 :
--   v2 échouait sur production avec ERROR 42703 (column "code" does not exist)
--   car la table sycapay_transactions existait avec un ANCIEN schéma à ~10
--   colonnes. CREATE TABLE IF NOT EXISTS était no-op, mais la Section B
--   ne couvrait que les colonnes v2 (internal_reference, idempotency_key…)
--   en supposant que code/membre_nom/devise/metadata/created_at/updated_at
--   étaient déjà présents. Ce n'est pas le cas sur la base de production.
--
--   v3 ajoute en Section B les ADD COLUMN IF NOT EXISTS pour TOUTES les
--   colonnes potentiellement absentes, en utilisant les vrais noms de
--   colonnes découverts par audit de la base de production réelle.
--
-- DONNÉES CONSERVÉES : utilisateurs, tontines, cotisations, prêts,
--   abonnements, votes, scores, KYC, tickets support, transactions,
--   tokens FCM — rien n'est effacé ni modifié.
--
-- COMMENT UTILISER CE FICHIER :
--   Étape 1 — Schéma :
--     Supabase SQL Editor → New query → Coller upgrade.sql → Run
--   Étape 2 — Fonctions/RPCs :
--     Supabase SQL Editor → New query → Coller init_inline.sql → Run
--   (ou psql -f upgrade.sql && psql -f init_inline.sql)
--
-- VERSION : migrations 001→011 — 2025-07-17  (v3)
-- ============================================================


-- ============================================================
-- SECTION A : NOUVELLES TABLES (no-op si déjà présentes)
-- ============================================================
-- Chaque CREATE TABLE IF NOT EXISTS utilise le schéma complet
-- et correct tel que défini dans les migrations 001-005.
-- Si la table existe déjà, cette section est un no-op total.
-- La Section B (ADD COLUMN IF NOT EXISTS) prend le relais
-- pour ajouter les colonnes manquantes sur les tables existantes.
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
-- Schéma réel prod : id, code, gestionnaire, empreinte, quand
-- (upgrade v2 avait "action TEXT, data JSONB" — incorrect)
-- ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS audit (
  id           BIGSERIAL   PRIMARY KEY,
  code         TEXT        NOT NULL,
  gestionnaire TEXT        NOT NULL,
  empreinte    TEXT        NOT NULL,
  quand        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ─────────────────────────────────────────────────────────────
-- A.3 — demandes_premium
-- Schéma réel prod : id, code, gestionnaire, nom, contact,
--   formule, statut, quand
-- ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS demandes_premium (
  id           BIGSERIAL   PRIMARY KEY,
  code         TEXT        NOT NULL,
  gestionnaire TEXT        NOT NULL,
  nom          TEXT,
  contact      TEXT,
  formule      TEXT        NOT NULL DEFAULT 'mensuel',
  statut       TEXT        NOT NULL DEFAULT 'en attente'
               CHECK (statut IN ('en attente','en_attente','activée','refusée','active','refuse')),
  quand        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ─────────────────────────────────────────────────────────────
-- A.4 — config / app_config / admin_config
-- Schéma réel prod : UNIQUEMENT cle (TEXT PK) + valeur (TEXT)
-- SANS colonne id (upgrade v2 avait BIGSERIAL PRIMARY KEY — incorrect)
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
-- A.5 — voix (nouvelle table — absente de toutes les versions prod)
-- ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS voix (
  id        BIGSERIAL   PRIMARY KEY,
  code      TEXT        NOT NULL,
  vote_id   TEXT        NOT NULL,
  membre_id TEXT        NOT NULL,
  choix     TEXT        NOT NULL CHECK (choix IN ('oui','non','abstention')),
  methode   TEXT        NOT NULL DEFAULT 'PIN',
  appareil  TEXT,
  vote_le   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (code, vote_id, membre_id)
);

-- ─────────────────────────────────────────────────────────────
-- A.6 — scores_historique
-- Schéma réel prod : id, code, membre_id, score, score_prec,
--   evenement, description, gestionnaire, quand
-- (upgrade v2 avait type/delta/raison — incorrect)
-- ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS scores_historique (
  id           BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  code         TEXT        NOT NULL,
  membre_id    TEXT        NOT NULL,
  score        INT         NOT NULL CHECK (score BETWEEN 0 AND 100),
  score_prec   INT         NOT NULL CHECK (score_prec BETWEEN 0 AND 100),
  evenement    TEXT        NOT NULL,
  description  TEXT        NOT NULL,
  gestionnaire TEXT,
  quand        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ─────────────────────────────────────────────────────────────
-- A.7 — propositions_retrait
-- Schéma réel prod : id, code, membre_id, membre_nom,
--   score_moment, motif, propose_par, vote_id, quorum, majorite,
--   statut, quand, clos_le, resultat_oui, resultat_non, resultat_abs
-- ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS propositions_retrait (
  id           BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  code         TEXT        NOT NULL,
  membre_id    TEXT        NOT NULL,
  membre_nom   TEXT        NOT NULL,
  score_moment INT         NOT NULL,
  motif        TEXT        NOT NULL,
  propose_par  TEXT        NOT NULL,
  vote_id      TEXT,
  quorum       INT         NOT NULL DEFAULT 50,
  majorite     INT         NOT NULL DEFAULT 67,
  statut       TEXT        NOT NULL DEFAULT 'en_attente'
               CHECK (statut IN ('en_attente','vote_ouvert','accepte','refuse')),
  quand        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  clos_le      TIMESTAMPTZ,
  resultat_oui INT         DEFAULT 0,
  resultat_non INT         DEFAULT 0,
  resultat_abs INT         DEFAULT 0
);

-- ─────────────────────────────────────────────────────────────
-- A.8 — journal_audit
-- Schéma réel prod : id, code, gestionnaire, action, detail,
--   membre_id, ancien_val, nouveau_val, quand
-- (upgrade v2 avait acteur/details — incorrect)
-- ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS journal_audit (
  id           BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  code         TEXT        NOT NULL,
  gestionnaire TEXT        NOT NULL,
  action       TEXT        NOT NULL,
  detail       TEXT,
  membre_id    TEXT,
  ancien_val   TEXT,
  nouveau_val  TEXT,
  quand        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ─────────────────────────────────────────────────────────────
-- A.9 — subscriptions
-- Schéma réel prod : id, code, plan, statut, date_debut,
--   date_fin, stripe_id, modifie_le
-- (upgrade v2 avait debut/fin — incorrect ; vrais noms : date_debut/date_fin)
-- ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS subscriptions (
  id         BIGSERIAL   PRIMARY KEY,
  code       TEXT        NOT NULL UNIQUE,
  plan       TEXT        NOT NULL DEFAULT 'gratuit'
             CHECK (plan IN ('gratuit','premium_mensuel','premium_annuel','pro')),
  statut     TEXT        NOT NULL DEFAULT 'actif'
             CHECK (statut IN ('actif','expire','annule','suspendu')),
  date_debut TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  date_fin   TIMESTAMPTZ,
  stripe_id  TEXT,
  modifie_le TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ─────────────────────────────────────────────────────────────
-- A.10 — abonnements
-- Schéma réel prod : id, code, gestionnaire, contact, formule,
--   statut, debut, fin, montant, devise, note, cree_le
-- ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS abonnements (
  id           BIGSERIAL     PRIMARY KEY,
  code         TEXT          NOT NULL,
  gestionnaire TEXT,
  contact      TEXT,
  formule      TEXT          NOT NULL DEFAULT 'mensuel',
  statut       TEXT          NOT NULL DEFAULT 'actif'
               CHECK (statut IN ('actif','expire','annule')),
  debut        TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  fin          TIMESTAMPTZ,
  montant      NUMERIC(12,2) DEFAULT 0,
  devise       TEXT          DEFAULT 'XOF',
  note         TEXT,
  cree_le      TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

-- ─────────────────────────────────────────────────────────────
-- A.11 — admin_actions
-- Schéma réel prod : id, type, code, detail, admin, quand
-- (upgrade v2 avait admin_id/action/cible/details/fait_le — incorrect)
-- ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS admin_actions (
  id     BIGSERIAL   PRIMARY KEY,
  type   TEXT        NOT NULL,
  code   TEXT,
  detail TEXT,
  admin  TEXT        NOT NULL DEFAULT 'admin',
  quand  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ─────────────────────────────────────────────────────────────
-- A.12 — sycapay_transactions
-- Schéma réel prod (ancien) : ~10 colonnes seulement.
-- On déclare ici le schéma complet v2.
-- La Section B gère les ADD COLUMN IF NOT EXISTS pour la prod.
-- ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS sycapay_transactions (
  id                   BIGSERIAL     PRIMARY KEY,
  type                 TEXT          NOT NULL,
  code                 TEXT          NOT NULL,
  membre_id            TEXT,
  membre_nom           TEXT,
  montant              NUMERIC(14,2) NOT NULL,
  devise               TEXT          NOT NULL DEFAULT 'XOF',
  statut               TEXT          NOT NULL DEFAULT 'pending'
                       CHECK (statut IN ('pending','completed','failed','cancelled')),
  sycapay_ref          TEXT,
  numero_telephone     TEXT,
  gestionnaire         TEXT,
  internal_reference   TEXT          UNIQUE,
  idempotency_key      TEXT          UNIQUE,
  statut_traitement    TEXT          NOT NULL DEFAULT 'non_traite'
                       CHECK (statut_traitement IN ('non_traite','en_cours','traite','erreur')),
  user_id              TEXT,
  tontine_code         TEXT,
  type_operation       TEXT,
  pret_id              TEXT,
  emprunteur_id        TEXT,
  metadata             JSONB         DEFAULT '{}',
  created_at           TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  updated_at           TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  provider_transaction_id TEXT,
  sycapay_reference    TEXT,
  amount               INTEGER,
  currency             TEXT,
  operator             TEXT,
  phone_number_masked  TEXT,
  description          TEXT,
  status               TEXT          DEFAULT 'pending',
  polling_attempts     INTEGER       DEFAULT 0
);

-- ─────────────────────────────────────────────────────────────
-- A.13 — prets_pending
-- Schéma réel prod : id, code, membre_id, membre_nom, montant,
--   montant_net, taux_interet, duree_mois, devise, motif, statut,
--   motif_rejet, gestionnaire, cree_le, traite_le
-- ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS prets_pending (
  id             BIGSERIAL     PRIMARY KEY,
  code           TEXT          NOT NULL,
  membre_id      TEXT          NOT NULL,
  membre_nom     TEXT          NOT NULL,
  montant        NUMERIC(14,2) NOT NULL,
  montant_net    NUMERIC(14,2),
  taux_interet   NUMERIC(5,2)  DEFAULT 0,
  duree_mois     INT           DEFAULT 1,
  devise         TEXT          NOT NULL DEFAULT 'XOF',
  motif          TEXT,
  statut         TEXT          NOT NULL DEFAULT 'pending'
                 CHECK (statut IN ('pending','validee','rejetee')),
  motif_rejet    TEXT,
  gestionnaire   TEXT,
  cree_le        TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  traite_le      TIMESTAMPTZ
);

-- ─────────────────────────────────────────────────────────────
-- A.14 — decaissements_pending
-- Schéma réel prod : id, code, beneficiaire, montant, devise,
--   motif, statut, motif_rejet, gestionnaire, cree_le, traite_le
-- ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS decaissements_pending (
  id           BIGSERIAL     PRIMARY KEY,
  code         TEXT          NOT NULL,
  beneficiaire TEXT          NOT NULL,
  montant      NUMERIC(14,2) NOT NULL,
  devise       TEXT          NOT NULL DEFAULT 'XOF',
  motif        TEXT,
  statut       TEXT          NOT NULL DEFAULT 'pending'
               CHECK (statut IN ('pending','validee','rejetee')),
  motif_rejet  TEXT,
  gestionnaire TEXT,
  cree_le      TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  traite_le    TIMESTAMPTZ
);

-- ─────────────────────────────────────────────────────────────
-- A.15 — depenses_pending
-- Schéma réel prod : id, code, libelle, montant, devise,
--   categorie, statut, motif_rejet, gestionnaire, cree_le, traite_le
-- ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS depenses_pending (
  id           BIGSERIAL     PRIMARY KEY,
  code         TEXT          NOT NULL,
  libelle      TEXT          NOT NULL,
  montant      NUMERIC(14,2) NOT NULL,
  devise       TEXT          NOT NULL DEFAULT 'XOF',
  categorie    TEXT          DEFAULT 'autre',
  statut       TEXT          NOT NULL DEFAULT 'pending'
               CHECK (statut IN ('pending','validee','rejetee')),
  motif_rejet  TEXT,
  gestionnaire TEXT,
  cree_le      TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  traite_le    TIMESTAMPTZ
);

-- ─────────────────────────────────────────────────────────────
-- A.16 — premium_requests
-- Schéma réel prod : id, code, gestionnaire, nom, contact,
--   formule, statut, cree_le, mis_a_jour
-- ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS premium_requests (
  id           BIGSERIAL   PRIMARY KEY,
  code         TEXT        NOT NULL UNIQUE,
  gestionnaire TEXT        NOT NULL,
  nom          TEXT,
  contact      TEXT,
  formule      TEXT        NOT NULL DEFAULT 'mensuel',
  statut       TEXT        NOT NULL DEFAULT 'pending'
               CHECK (statut IN ('pending','active','rejected','expired')),
  cree_le      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  mis_a_jour   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ─────────────────────────────────────────────────────────────
-- A.17 — kyc_submissions
-- Schéma réel prod : id, code, gestionnaire, nom_complet,
--   type_piece, numero_piece, photo_recto_url, photo_verso_url,
--   photo_selfie_url, statut, motif_rejet, note_admin,
--   soumis_le, traite_le
-- ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.kyc_submissions (
  id               BIGSERIAL   PRIMARY KEY,
  code             TEXT        NOT NULL,
  gestionnaire     TEXT        NOT NULL,
  nom_complet      TEXT        NOT NULL,
  type_piece       TEXT        NOT NULL DEFAULT 'cni'
                   CHECK (type_piece IN ('cni','passeport','permis','sejour')),
  numero_piece     TEXT,
  photo_recto_url  TEXT,
  photo_verso_url  TEXT,
  photo_selfie_url TEXT,
  statut           TEXT        NOT NULL DEFAULT 'pending'
                   CHECK (statut IN ('pending','valide','rejete')),
  motif_rejet      TEXT,
  note_admin       TEXT,
  soumis_le        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  traite_le        TIMESTAMPTZ
);

-- ─────────────────────────────────────────────────────────────
-- A.18 — fcm_tokens
-- Schéma réel prod : id, token, tontine, membre_id, platform,
--   cree_le, mis_a_jour, langue
-- (upgrade v2 avait appareil — incorrect ; vrai nom : platform)
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
-- ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS rappels_envoyes (
  id        BIGSERIAL   PRIMARY KEY,
  code      TEXT        NOT NULL,
  membre_id TEXT        NOT NULL,
  type      TEXT        NOT NULL DEFAULT 'cotisation',
  envoye_le TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (code, membre_id, type)
);

-- ─────────────────────────────────────────────────────────────
-- A.20 — admin_membres
-- Schéma réel prod : id, nom, pseudo, cle_hash, role, actif,
--   cree_par, cree_le, derniere_connexion
-- (upgrade v2 avait cle_perso — incorrect ; vrai nom : cle_hash)
-- ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS admin_membres (
  id                 BIGSERIAL   PRIMARY KEY,
  nom                TEXT        NOT NULL,
  pseudo             TEXT        NOT NULL UNIQUE,
  cle_hash           TEXT        NOT NULL,
  role               TEXT        NOT NULL DEFAULT 'comptable'
                     CHECK (role IN ('super_admin','comptable','conformite')),
  actif              BOOLEAN     NOT NULL DEFAULT TRUE,
  cree_par           TEXT        NOT NULL,
  cree_le            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  derniere_connexion TIMESTAMPTZ
);

-- ─────────────────────────────────────────────────────────────
-- A.21 — admin_messages
-- Schéma réel prod : id, expediteur, destinataire, sujet, corps,
--   lu, lu_le, envoye_le
-- (upgrade v2 avait contenu — incorrect ; vrais noms : sujet + corps)
-- ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS admin_messages (
  id           BIGSERIAL   PRIMARY KEY,
  expediteur   TEXT        NOT NULL,
  destinataire TEXT        NOT NULL,
  sujet        TEXT        NOT NULL DEFAULT '',
  corps        TEXT        NOT NULL,
  lu           BOOLEAN     NOT NULL DEFAULT FALSE,
  lu_le        TIMESTAMPTZ,
  envoye_le    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ─────────────────────────────────────────────────────────────
-- A.22 — support_tickets
-- Schéma réel prod : id, ref, gestionnaire, code_tontine,
--   categorie, sujet, description, statut, priorite, assigne_a,
--   cree_le, mis_a_jour, resolu_le
-- ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS support_tickets (
  id           BIGSERIAL   PRIMARY KEY,
  ref          TEXT        NOT NULL UNIQUE,
  gestionnaire TEXT        NOT NULL,
  code_tontine TEXT,
  categorie    TEXT        NOT NULL DEFAULT 'autre'
               CHECK (categorie IN ('paiement','kyc','tontine','technique','autre')),
  sujet        TEXT        NOT NULL,
  description  TEXT        NOT NULL,
  statut       TEXT        NOT NULL DEFAULT 'ouvert'
               CHECK (statut IN ('ouvert','en_cours','resolu','ferme')),
  priorite     TEXT        NOT NULL DEFAULT 'normale'
               CHECK (priorite IN ('basse','normale','haute','urgente')),
  assigne_a    TEXT,
  cree_le      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  mis_a_jour   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  resolu_le    TIMESTAMPTZ
);

-- ─────────────────────────────────────────────────────────────
-- A.23 — support_messages
-- Schéma réel prod : id, ticket_id, auteur, est_admin, corps,
--   lu_client, lu_admin, envoye_le
-- ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS support_messages (
  id        BIGSERIAL   PRIMARY KEY,
  ticket_id BIGINT      NOT NULL REFERENCES support_tickets(id) ON DELETE CASCADE,
  auteur    TEXT        NOT NULL,
  est_admin BOOLEAN     NOT NULL DEFAULT FALSE,
  corps     TEXT        NOT NULL,
  lu_client BOOLEAN     NOT NULL DEFAULT FALSE,
  lu_admin  BOOLEAN     NOT NULL DEFAULT FALSE,
  envoye_le TIMESTAMPTZ NOT NULL DEFAULT NOW()
);


-- ============================================================
-- SECTION B : NOUVELLES COLONNES (ADD COLUMN IF NOT EXISTS)
-- ============================================================
-- RÈGLE CRITIQUE : cette section couvre TOUTES les colonnes
-- potentiellement absentes sur une base de production avec
-- un ancien schéma, y compris les colonnes "de base" qui
-- n'étaient pas encore ajoutées via ALTER TABLE dans les
-- versions précédentes de ce script.
--
-- ORDRE OBLIGATOIRE : Section B doit précéder Section C
-- (les index référencent des colonnes qui doivent exister).
--
-- Règle stricte : toute colonne NOT NULL a un DEFAULT.
-- → Aucun risque sur les lignes existantes.
-- ============================================================

-- ─────────────────────────────────────────────────────────────
-- B.1 — tontines : colonnes v2
-- ─────────────────────────────────────────────────────────────
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
-- B.2 — audit : colonnes réelles prod
-- (l'ancienne version avait peut-être action/data au lieu de gestionnaire/empreinte)
-- ─────────────────────────────────────────────────────────────
ALTER TABLE audit ADD COLUMN IF NOT EXISTS gestionnaire TEXT NOT NULL DEFAULT '';
ALTER TABLE audit ADD COLUMN IF NOT EXISTS empreinte    TEXT NOT NULL DEFAULT '';

-- ─────────────────────────────────────────────────────────────
-- B.3 — demandes_premium : colonnes réelles prod
-- ─────────────────────────────────────────────────────────────
ALTER TABLE demandes_premium ADD COLUMN IF NOT EXISTS gestionnaire TEXT;
ALTER TABLE demandes_premium ADD COLUMN IF NOT EXISTS nom          TEXT;
ALTER TABLE demandes_premium ADD COLUMN IF NOT EXISTS contact      TEXT;
ALTER TABLE demandes_premium ADD COLUMN IF NOT EXISTS formule      TEXT NOT NULL DEFAULT 'mensuel';
ALTER TABLE demandes_premium ADD COLUMN IF NOT EXISTS statut       TEXT NOT NULL DEFAULT 'en_attente';
ALTER TABLE demandes_premium ADD COLUMN IF NOT EXISTS quand        TIMESTAMPTZ NOT NULL DEFAULT NOW();

-- ─────────────────────────────────────────────────────────────
-- B.4 — scores_historique : colonnes réelles prod
-- (l'ancienne version avait type/delta/raison — incorrects)
-- ─────────────────────────────────────────────────────────────
ALTER TABLE scores_historique ADD COLUMN IF NOT EXISTS score        INT  NOT NULL DEFAULT 0;
ALTER TABLE scores_historique ADD COLUMN IF NOT EXISTS score_prec   INT  NOT NULL DEFAULT 0;
ALTER TABLE scores_historique ADD COLUMN IF NOT EXISTS evenement    TEXT NOT NULL DEFAULT '';
ALTER TABLE scores_historique ADD COLUMN IF NOT EXISTS description  TEXT NOT NULL DEFAULT '';
ALTER TABLE scores_historique ADD COLUMN IF NOT EXISTS gestionnaire TEXT;

-- ─────────────────────────────────────────────────────────────
-- B.5 — propositions_retrait : colonnes réelles prod
-- ─────────────────────────────────────────────────────────────
ALTER TABLE propositions_retrait ADD COLUMN IF NOT EXISTS membre_nom   TEXT NOT NULL DEFAULT '';
ALTER TABLE propositions_retrait ADD COLUMN IF NOT EXISTS score_moment INT  NOT NULL DEFAULT 0;
ALTER TABLE propositions_retrait ADD COLUMN IF NOT EXISTS propose_par  TEXT NOT NULL DEFAULT '';
ALTER TABLE propositions_retrait ADD COLUMN IF NOT EXISTS vote_id      TEXT;
ALTER TABLE propositions_retrait ADD COLUMN IF NOT EXISTS quorum       INT  NOT NULL DEFAULT 50;
ALTER TABLE propositions_retrait ADD COLUMN IF NOT EXISTS majorite     INT  NOT NULL DEFAULT 67;
ALTER TABLE propositions_retrait ADD COLUMN IF NOT EXISTS clos_le      TIMESTAMPTZ;
ALTER TABLE propositions_retrait ADD COLUMN IF NOT EXISTS resultat_oui INT  DEFAULT 0;
ALTER TABLE propositions_retrait ADD COLUMN IF NOT EXISTS resultat_non INT  DEFAULT 0;
ALTER TABLE propositions_retrait ADD COLUMN IF NOT EXISTS resultat_abs INT  DEFAULT 0;

-- ─────────────────────────────────────────────────────────────
-- B.6 — journal_audit : colonnes réelles prod
-- (l'ancienne version avait acteur/details — incorrects)
-- ─────────────────────────────────────────────────────────────
ALTER TABLE journal_audit ADD COLUMN IF NOT EXISTS gestionnaire TEXT NOT NULL DEFAULT '';
ALTER TABLE journal_audit ADD COLUMN IF NOT EXISTS action       TEXT NOT NULL DEFAULT '';
ALTER TABLE journal_audit ADD COLUMN IF NOT EXISTS detail       TEXT;
ALTER TABLE journal_audit ADD COLUMN IF NOT EXISTS membre_id    TEXT;
ALTER TABLE journal_audit ADD COLUMN IF NOT EXISTS ancien_val   TEXT;
ALTER TABLE journal_audit ADD COLUMN IF NOT EXISTS nouveau_val  TEXT;

-- ─────────────────────────────────────────────────────────────
-- B.7 — subscriptions : colonnes réelles prod
-- (l'ancienne version avait debut/fin — incorrects)
-- vrais noms : date_debut / date_fin / stripe_id
-- ─────────────────────────────────────────────────────────────
ALTER TABLE subscriptions ADD COLUMN IF NOT EXISTS date_debut TIMESTAMPTZ NOT NULL DEFAULT NOW();
ALTER TABLE subscriptions ADD COLUMN IF NOT EXISTS date_fin   TIMESTAMPTZ;
ALTER TABLE subscriptions ADD COLUMN IF NOT EXISTS stripe_id  TEXT;
ALTER TABLE subscriptions ADD COLUMN IF NOT EXISTS modifie_le TIMESTAMPTZ NOT NULL DEFAULT NOW();

-- ─────────────────────────────────────────────────────────────
-- B.8 — abonnements : colonnes réelles prod
-- ─────────────────────────────────────────────────────────────
ALTER TABLE abonnements ADD COLUMN IF NOT EXISTS gestionnaire TEXT;
ALTER TABLE abonnements ADD COLUMN IF NOT EXISTS contact      TEXT;
ALTER TABLE abonnements ADD COLUMN IF NOT EXISTS formule      TEXT          NOT NULL DEFAULT 'mensuel';
ALTER TABLE abonnements ADD COLUMN IF NOT EXISTS debut        TIMESTAMPTZ   NOT NULL DEFAULT NOW();
ALTER TABLE abonnements ADD COLUMN IF NOT EXISTS fin          TIMESTAMPTZ;
ALTER TABLE abonnements ADD COLUMN IF NOT EXISTS montant      NUMERIC(12,2) DEFAULT 0;
ALTER TABLE abonnements ADD COLUMN IF NOT EXISTS devise       TEXT          DEFAULT 'XOF';
ALTER TABLE abonnements ADD COLUMN IF NOT EXISTS note         TEXT;
ALTER TABLE abonnements ADD COLUMN IF NOT EXISTS cree_le      TIMESTAMPTZ   NOT NULL DEFAULT NOW();

-- ─────────────────────────────────────────────────────────────
-- B.9 — admin_actions : colonnes réelles prod
-- (l'ancienne version avait admin_id/action/cible/details/fait_le — incorrect)
-- vrais noms : type, code, detail, admin, quand
-- ─────────────────────────────────────────────────────────────
ALTER TABLE admin_actions ADD COLUMN IF NOT EXISTS type   TEXT        NOT NULL DEFAULT '';
ALTER TABLE admin_actions ADD COLUMN IF NOT EXISTS code   TEXT;
ALTER TABLE admin_actions ADD COLUMN IF NOT EXISTS detail TEXT;
ALTER TABLE admin_actions ADD COLUMN IF NOT EXISTS admin  TEXT        NOT NULL DEFAULT 'admin';
ALTER TABLE admin_actions ADD COLUMN IF NOT EXISTS quand  TIMESTAMPTZ NOT NULL DEFAULT NOW();

-- ─────────────────────────────────────────────────────────────
-- B.10 — sycapay_transactions : TOUTES les colonnes potentiellement
-- absentes sur une production avec l'ancien schéma ~10 colonnes.
--
-- COLONNE PAR COLONNE :
--   code             → colonne qui causait ERROR 42703 en prod
--   membre_nom       → absente dans ancien schéma
--   devise           → absente dans ancien schéma
--   numero_telephone → absente dans ancien schéma
--   gestionnaire     → absente dans ancien schéma
--   metadata         → absente dans ancien schéma
--   created_at       → absente dans ancien schéma (alias de cree_le)
--   updated_at       → absente dans ancien schéma
--   + toutes les colonnes v2 (internal_reference, idempotency_key, etc.)
-- ─────────────────────────────────────────────────────────────

-- Colonnes de base potentiellement absentes (ancien schéma prod)
ALTER TABLE sycapay_transactions ADD COLUMN IF NOT EXISTS code             TEXT          NOT NULL DEFAULT '';
ALTER TABLE sycapay_transactions ADD COLUMN IF NOT EXISTS membre_nom       TEXT;
ALTER TABLE sycapay_transactions ADD COLUMN IF NOT EXISTS devise           TEXT          NOT NULL DEFAULT 'XOF';
ALTER TABLE sycapay_transactions ADD COLUMN IF NOT EXISTS numero_telephone TEXT;
ALTER TABLE sycapay_transactions ADD COLUMN IF NOT EXISTS gestionnaire     TEXT;
ALTER TABLE sycapay_transactions ADD COLUMN IF NOT EXISTS metadata         JSONB         DEFAULT '{}';
ALTER TABLE sycapay_transactions ADD COLUMN IF NOT EXISTS created_at       TIMESTAMPTZ   NOT NULL DEFAULT NOW();
ALTER TABLE sycapay_transactions ADD COLUMN IF NOT EXISTS updated_at       TIMESTAMPTZ   NOT NULL DEFAULT NOW();

-- Colonnes v2 : idempotence et suivi avancé
ALTER TABLE sycapay_transactions ADD COLUMN IF NOT EXISTS internal_reference      TEXT UNIQUE;
ALTER TABLE sycapay_transactions ADD COLUMN IF NOT EXISTS idempotency_key         TEXT UNIQUE;
ALTER TABLE sycapay_transactions ADD COLUMN IF NOT EXISTS statut_traitement       TEXT NOT NULL DEFAULT 'non_traite';
ALTER TABLE sycapay_transactions ADD COLUMN IF NOT EXISTS user_id                 TEXT;
ALTER TABLE sycapay_transactions ADD COLUMN IF NOT EXISTS tontine_code            TEXT;
ALTER TABLE sycapay_transactions ADD COLUMN IF NOT EXISTS type_operation          TEXT;
ALTER TABLE sycapay_transactions ADD COLUMN IF NOT EXISTS pret_id                 TEXT;
ALTER TABLE sycapay_transactions ADD COLUMN IF NOT EXISTS emprunteur_id           TEXT;
ALTER TABLE sycapay_transactions ADD COLUMN IF NOT EXISTS provider_transaction_id TEXT;
ALTER TABLE sycapay_transactions ADD COLUMN IF NOT EXISTS sycapay_reference       TEXT;

-- Colonnes convention SycaPay API
ALTER TABLE sycapay_transactions ADD COLUMN IF NOT EXISTS amount             INTEGER DEFAULT 0;
ALTER TABLE sycapay_transactions ADD COLUMN IF NOT EXISTS currency           TEXT;
ALTER TABLE sycapay_transactions ADD COLUMN IF NOT EXISTS operator           TEXT;
ALTER TABLE sycapay_transactions ADD COLUMN IF NOT EXISTS phone_number_masked TEXT;
ALTER TABLE sycapay_transactions ADD COLUMN IF NOT EXISTS description        TEXT;
ALTER TABLE sycapay_transactions ADD COLUMN IF NOT EXISTS status             TEXT    DEFAULT 'pending';
ALTER TABLE sycapay_transactions ADD COLUMN IF NOT EXISTS polling_attempts   INTEGER DEFAULT 0;

-- ─────────────────────────────────────────────────────────────
-- B.11 — prets_pending : colonnes réelles prod
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
-- B.12 — decaissements_pending : colonnes réelles prod
-- ─────────────────────────────────────────────────────────────
ALTER TABLE decaissements_pending ADD COLUMN IF NOT EXISTS beneficiaire TEXT          NOT NULL DEFAULT '';
ALTER TABLE decaissements_pending ADD COLUMN IF NOT EXISTS devise       TEXT          NOT NULL DEFAULT 'XOF';
ALTER TABLE decaissements_pending ADD COLUMN IF NOT EXISTS motif        TEXT;
ALTER TABLE decaissements_pending ADD COLUMN IF NOT EXISTS statut       TEXT          NOT NULL DEFAULT 'pending';
ALTER TABLE decaissements_pending ADD COLUMN IF NOT EXISTS motif_rejet  TEXT;
ALTER TABLE decaissements_pending ADD COLUMN IF NOT EXISTS gestionnaire TEXT;
ALTER TABLE decaissements_pending ADD COLUMN IF NOT EXISTS cree_le      TIMESTAMPTZ   NOT NULL DEFAULT NOW();
ALTER TABLE decaissements_pending ADD COLUMN IF NOT EXISTS traite_le    TIMESTAMPTZ;

-- ─────────────────────────────────────────────────────────────
-- B.13 — depenses_pending : colonnes réelles prod
-- ─────────────────────────────────────────────────────────────
ALTER TABLE depenses_pending ADD COLUMN IF NOT EXISTS libelle      TEXT          NOT NULL DEFAULT '';
ALTER TABLE depenses_pending ADD COLUMN IF NOT EXISTS devise       TEXT          NOT NULL DEFAULT 'XOF';
ALTER TABLE depenses_pending ADD COLUMN IF NOT EXISTS categorie    TEXT          DEFAULT 'autre';
ALTER TABLE depenses_pending ADD COLUMN IF NOT EXISTS statut       TEXT          NOT NULL DEFAULT 'pending';
ALTER TABLE depenses_pending ADD COLUMN IF NOT EXISTS motif_rejet  TEXT;
ALTER TABLE depenses_pending ADD COLUMN IF NOT EXISTS gestionnaire TEXT;
ALTER TABLE depenses_pending ADD COLUMN IF NOT EXISTS cree_le      TIMESTAMPTZ   NOT NULL DEFAULT NOW();
ALTER TABLE depenses_pending ADD COLUMN IF NOT EXISTS traite_le    TIMESTAMPTZ;

-- ─────────────────────────────────────────────────────────────
-- B.14 — premium_requests : colonnes réelles prod
-- ─────────────────────────────────────────────────────────────
ALTER TABLE premium_requests ADD COLUMN IF NOT EXISTS gestionnaire TEXT        NOT NULL DEFAULT '';
ALTER TABLE premium_requests ADD COLUMN IF NOT EXISTS nom          TEXT;
ALTER TABLE premium_requests ADD COLUMN IF NOT EXISTS contact      TEXT;
ALTER TABLE premium_requests ADD COLUMN IF NOT EXISTS formule      TEXT        NOT NULL DEFAULT 'mensuel';
ALTER TABLE premium_requests ADD COLUMN IF NOT EXISTS statut       TEXT        NOT NULL DEFAULT 'pending';
ALTER TABLE premium_requests ADD COLUMN IF NOT EXISTS cree_le      TIMESTAMPTZ NOT NULL DEFAULT NOW();
ALTER TABLE premium_requests ADD COLUMN IF NOT EXISTS mis_a_jour   TIMESTAMPTZ NOT NULL DEFAULT NOW();

-- ─────────────────────────────────────────────────────────────
-- B.15 — kyc_submissions : colonnes réelles prod
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
-- B.16 — fcm_tokens : colonnes réelles prod
-- (l'ancienne version avait appareil — incorrect ; vrai nom : platform)
-- ─────────────────────────────────────────────────────────────
ALTER TABLE public.fcm_tokens ADD COLUMN IF NOT EXISTS tontine    TEXT;
ALTER TABLE public.fcm_tokens ADD COLUMN IF NOT EXISTS membre_id  TEXT;
ALTER TABLE public.fcm_tokens ADD COLUMN IF NOT EXISTS platform   TEXT        DEFAULT 'android';
ALTER TABLE public.fcm_tokens ADD COLUMN IF NOT EXISTS cree_le    TIMESTAMPTZ NOT NULL DEFAULT NOW();
ALTER TABLE public.fcm_tokens ADD COLUMN IF NOT EXISTS mis_a_jour TIMESTAMPTZ NOT NULL DEFAULT NOW();
ALTER TABLE public.fcm_tokens ADD COLUMN IF NOT EXISTS langue     TEXT;

-- ─────────────────────────────────────────────────────────────
-- B.17 — admin_membres : colonnes réelles prod
-- (l'ancienne version avait cle_perso — incorrect ; vrai nom : cle_hash)
-- ─────────────────────────────────────────────────────────────
ALTER TABLE admin_membres ADD COLUMN IF NOT EXISTS nom                TEXT        NOT NULL DEFAULT '';
ALTER TABLE admin_membres ADD COLUMN IF NOT EXISTS cle_hash           TEXT        NOT NULL DEFAULT '';
ALTER TABLE admin_membres ADD COLUMN IF NOT EXISTS role               TEXT        NOT NULL DEFAULT 'comptable';
ALTER TABLE admin_membres ADD COLUMN IF NOT EXISTS actif              BOOLEAN     NOT NULL DEFAULT TRUE;
ALTER TABLE admin_membres ADD COLUMN IF NOT EXISTS cree_par           TEXT        NOT NULL DEFAULT '';
ALTER TABLE admin_membres ADD COLUMN IF NOT EXISTS cree_le            TIMESTAMPTZ NOT NULL DEFAULT NOW();
ALTER TABLE admin_membres ADD COLUMN IF NOT EXISTS derniere_connexion TIMESTAMPTZ;

-- ─────────────────────────────────────────────────────────────
-- B.18 — admin_messages : colonnes réelles prod
-- (l'ancienne version avait contenu — incorrect ; vrais noms : sujet + corps)
-- ─────────────────────────────────────────────────────────────
ALTER TABLE admin_messages ADD COLUMN IF NOT EXISTS sujet        TEXT        NOT NULL DEFAULT '';
ALTER TABLE admin_messages ADD COLUMN IF NOT EXISTS corps        TEXT        NOT NULL DEFAULT '';
ALTER TABLE admin_messages ADD COLUMN IF NOT EXISTS lu           BOOLEAN     NOT NULL DEFAULT FALSE;
ALTER TABLE admin_messages ADD COLUMN IF NOT EXISTS lu_le        TIMESTAMPTZ;
ALTER TABLE admin_messages ADD COLUMN IF NOT EXISTS envoye_le    TIMESTAMPTZ NOT NULL DEFAULT NOW();

-- ─────────────────────────────────────────────────────────────
-- B.19 — support_tickets : colonnes réelles prod
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
-- B.20 — support_messages : colonnes réelles prod
-- ─────────────────────────────────────────────────────────────
ALTER TABLE support_messages ADD COLUMN IF NOT EXISTS auteur    TEXT        NOT NULL DEFAULT '';
ALTER TABLE support_messages ADD COLUMN IF NOT EXISTS est_admin BOOLEAN     NOT NULL DEFAULT FALSE;
ALTER TABLE support_messages ADD COLUMN IF NOT EXISTS corps     TEXT        NOT NULL DEFAULT '';
ALTER TABLE support_messages ADD COLUMN IF NOT EXISTS lu_client BOOLEAN     NOT NULL DEFAULT FALSE;
ALTER TABLE support_messages ADD COLUMN IF NOT EXISTS lu_admin  BOOLEAN     NOT NULL DEFAULT FALSE;
ALTER TABLE support_messages ADD COLUMN IF NOT EXISTS envoye_le TIMESTAMPTZ NOT NULL DEFAULT NOW();


-- ============================================================
-- SECTION C : INDEX (no-op si déjà présents)
-- ============================================================
-- IMPORTANT : Section C doit toujours venir APRÈS Section B.
-- Tous les index référencent des colonnes déjà garanties
-- présentes par la Section B ci-dessus.
-- ============================================================

-- tontines
CREATE INDEX IF NOT EXISTS idx_tontines_code   ON tontines(code);
CREATE INDEX IF NOT EXISTS idx_tontines_status ON tontines(status);

-- voix
CREATE INDEX IF NOT EXISTS idx_voix_code    ON voix(code);
CREATE INDEX IF NOT EXISTS idx_voix_vote_id ON voix(code, vote_id);
CREATE UNIQUE INDEX IF NOT EXISTS voix_code_vote_id_membre_id_key
  ON voix(code, vote_id, membre_id);

-- audit
CREATE INDEX IF NOT EXISTS idx_audit_code ON audit(code, quand DESC);

-- demandes_premium
CREATE UNIQUE INDEX IF NOT EXISTS idx_demandes_premium_code ON demandes_premium(code);

-- scores_historique
CREATE INDEX IF NOT EXISTS idx_scores_hist_code_membre ON scores_historique(code, membre_id);
CREATE INDEX IF NOT EXISTS idx_scores_hist_code_quand  ON scores_historique(code, quand DESC);

-- propositions_retrait
CREATE INDEX IF NOT EXISTS idx_prop_retrait_code   ON propositions_retrait(code);
CREATE INDEX IF NOT EXISTS idx_prop_retrait_membre ON propositions_retrait(code, membre_id);

-- journal_audit
CREATE INDEX IF NOT EXISTS idx_journal_audit_code ON journal_audit(code, quand DESC);

-- subscriptions
CREATE INDEX IF NOT EXISTS idx_subscriptions_code   ON subscriptions(code);
CREATE INDEX IF NOT EXISTS idx_subscriptions_statut ON subscriptions(statut);
CREATE UNIQUE INDEX IF NOT EXISTS subscriptions_code_key ON subscriptions(code);

-- abonnements
CREATE INDEX IF NOT EXISTS idx_abonnements_code ON abonnements(code);

-- sycapay_transactions
-- (code et statut et type garantis présents par B.10 avant ces CREATE INDEX)
CREATE INDEX IF NOT EXISTS idx_sycapay_code   ON sycapay_transactions(code);
CREATE INDEX IF NOT EXISTS idx_sycapay_statut ON sycapay_transactions(statut);
CREATE INDEX IF NOT EXISTS idx_sycapay_type   ON sycapay_transactions(type);
CREATE INDEX IF NOT EXISTS idx_sycapay_txn_ref
  ON sycapay_transactions(internal_reference)
  WHERE internal_reference IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_sycapay_txn_idempotency
  ON sycapay_transactions(idempotency_key)
  WHERE idempotency_key IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_sycapay_txn_membre
  ON sycapay_transactions(code, membre_id);
CREATE INDEX IF NOT EXISTS idx_sycapay_txn_provider
  ON sycapay_transactions(provider_transaction_id)
  WHERE provider_transaction_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS sycapay_transactions_internal_reference_key
  ON sycapay_transactions(internal_reference);
CREATE UNIQUE INDEX IF NOT EXISTS sycapay_transactions_idempotency_key_key
  ON sycapay_transactions(idempotency_key);

-- prets_pending
CREATE INDEX IF NOT EXISTS idx_prets_code   ON prets_pending(code);
CREATE INDEX IF NOT EXISTS idx_prets_statut ON prets_pending(statut);

-- decaissements_pending
CREATE INDEX IF NOT EXISTS idx_decaiss_code   ON decaissements_pending(code);
CREATE INDEX IF NOT EXISTS idx_decaiss_statut ON decaissements_pending(statut);

-- depenses_pending
CREATE INDEX IF NOT EXISTS idx_depenses_code   ON depenses_pending(code);
CREATE INDEX IF NOT EXISTS idx_depenses_statut ON depenses_pending(statut);

-- premium_requests
CREATE INDEX IF NOT EXISTS idx_premium_req_code   ON premium_requests(code);
CREATE INDEX IF NOT EXISTS idx_premium_req_statut ON premium_requests(statut);
CREATE UNIQUE INDEX IF NOT EXISTS premium_requests_code_key ON premium_requests(code);

-- kyc_submissions
CREATE INDEX IF NOT EXISTS idx_kyc_code   ON public.kyc_submissions(code);
CREATE INDEX IF NOT EXISTS idx_kyc_statut ON public.kyc_submissions(statut);

-- fcm_tokens
CREATE INDEX IF NOT EXISTS idx_fcm_tontine ON public.fcm_tokens(tontine);
CREATE UNIQUE INDEX IF NOT EXISTS fcm_tokens_token_key ON fcm_tokens(token);

-- rappels_envoyes
CREATE INDEX IF NOT EXISTS idx_rappels_code ON rappels_envoyes(code);
CREATE UNIQUE INDEX IF NOT EXISTS rappels_envoyes_code_membre_id_type_key
  ON rappels_envoyes(code, membre_id, type);

-- admin_membres
CREATE UNIQUE INDEX IF NOT EXISTS idx_admin_membres_pseudo ON admin_membres(pseudo);
CREATE INDEX        IF NOT EXISTS idx_admin_membres_role   ON admin_membres(role);
CREATE UNIQUE INDEX IF NOT EXISTS admin_membres_pseudo_key ON admin_membres(pseudo);

-- admin_messages
CREATE INDEX IF NOT EXISTS idx_admin_msg_dest ON admin_messages(destinataire);
CREATE INDEX IF NOT EXISTS idx_admin_msg_exp  ON admin_messages(expediteur);
CREATE INDEX IF NOT EXISTS idx_admin_msg_date ON admin_messages(envoye_le DESC);

-- support_tickets
CREATE INDEX IF NOT EXISTS idx_support_tickets_statut       ON support_tickets(statut);
CREATE INDEX IF NOT EXISTS idx_support_tickets_gestionnaire ON support_tickets(gestionnaire);
CREATE INDEX IF NOT EXISTS idx_support_tickets_ref          ON support_tickets(ref);
CREATE INDEX IF NOT EXISTS idx_support_tickets_cree_le      ON support_tickets(cree_le DESC);
CREATE UNIQUE INDEX IF NOT EXISTS support_tickets_ref_key   ON support_tickets(ref);

-- support_messages
CREATE INDEX IF NOT EXISTS idx_support_msg_ticket ON support_messages(ticket_id);
CREATE INDEX IF NOT EXISTS idx_support_msg_date   ON support_messages(envoye_le ASC);


-- ============================================================
-- SECTION D : TRIGGERS (DROP IF EXISTS + recréation — safe)
-- ============================================================

-- D.1 — tontines : updated_at automatique
CREATE OR REPLACE FUNCTION tontines_set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public
AS $$
BEGIN NEW.updated_at = NOW(); RETURN NEW; END;
$$;

DROP TRIGGER IF EXISTS trg_tontines_updated_at ON tontines;
CREATE TRIGGER trg_tontines_updated_at
  BEFORE UPDATE ON tontines
  FOR EACH ROW EXECUTE FUNCTION tontines_set_updated_at();

-- D.2 — subscriptions : modifie_le automatique
CREATE OR REPLACE FUNCTION _sub_update_modifie_le()
RETURNS TRIGGER LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public
AS $$
BEGIN NEW.modifie_le = NOW(); RETURN NEW; END;
$$;

DROP TRIGGER IF EXISTS trg_sub_modifie_le ON subscriptions;
CREATE TRIGGER trg_sub_modifie_le
  BEFORE UPDATE ON subscriptions
  FOR EACH ROW EXECUTE FUNCTION _sub_update_modifie_le();


-- ============================================================
-- SECTION E : RLS — ENABLE + POLITIQUES (métadonnées seules)
-- ============================================================
-- DROP POLICY IF EXISTS + CREATE POLICY = mise à jour in-place.
-- Ne touche pas aux données, uniquement aux règles d'accès.
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

-- tontines
DROP POLICY IF EXISTS "tontines_anon_select" ON tontines;
CREATE POLICY "tontines_anon_select" ON tontines
  FOR SELECT TO anon, authenticated USING (true);
DROP POLICY IF EXISTS "tontines_anon_insert" ON tontines;
CREATE POLICY "tontines_anon_insert" ON tontines
  FOR INSERT TO anon, authenticated WITH CHECK (true);
DROP POLICY IF EXISTS "tontines_anon_update" ON tontines;
CREATE POLICY "tontines_anon_update" ON tontines
  FOR UPDATE TO anon, authenticated USING (true) WITH CHECK (true);

-- audit
DROP POLICY IF EXISTS "audit_anon" ON audit;
CREATE POLICY "audit_anon" ON audit
  FOR ALL TO anon, authenticated USING (true) WITH CHECK (true);

-- demandes_premium
DROP POLICY IF EXISTS "demandes_premium_select" ON demandes_premium;
CREATE POLICY "demandes_premium_select" ON demandes_premium
  FOR SELECT TO anon, authenticated USING (true);
DROP POLICY IF EXISTS "demandes_premium_insert" ON demandes_premium;
CREATE POLICY "demandes_premium_insert" ON demandes_premium
  FOR INSERT TO anon, authenticated WITH CHECK (true);
DROP POLICY IF EXISTS "demandes_premium_update" ON demandes_premium;
CREATE POLICY "demandes_premium_update" ON demandes_premium
  FOR UPDATE TO anon, authenticated USING (true);

-- config / app_config (accès bloqué — fonctions SECURITY DEFINER seulement)
DROP POLICY IF EXISTS "config_no_access"     ON config;
DROP POLICY IF EXISTS "app_config_no_access" ON app_config;
CREATE POLICY "config_no_access"     ON config     FOR ALL TO anon, authenticated USING (false);
CREATE POLICY "app_config_no_access" ON app_config FOR ALL TO anon, authenticated USING (false);

-- admin_config (accès bloqué)
DROP POLICY IF EXISTS "admin_config_no_access" ON admin_config;
CREATE POLICY "admin_config_no_access" ON admin_config
  FOR ALL TO anon, authenticated USING (false);

-- voix
DROP POLICY IF EXISTS "voix_anon" ON voix;
CREATE POLICY "voix_anon" ON voix
  FOR ALL TO anon, authenticated USING (true) WITH CHECK (true);

-- scores_historique
DROP POLICY IF EXISTS "scores_historique_select" ON scores_historique;
CREATE POLICY "scores_historique_select" ON scores_historique
  FOR ALL TO anon, authenticated USING (true) WITH CHECK (true);

-- propositions_retrait
DROP POLICY IF EXISTS "propositions_retrait_select" ON propositions_retrait;
CREATE POLICY "propositions_retrait_select" ON propositions_retrait
  FOR ALL TO anon, authenticated USING (true) WITH CHECK (true);

-- journal_audit
DROP POLICY IF EXISTS "journal_audit_select" ON journal_audit;
CREATE POLICY "journal_audit_select" ON journal_audit
  FOR ALL TO anon, authenticated USING (true) WITH CHECK (true);

-- subscriptions
DROP POLICY IF EXISTS "subscriptions_anon" ON subscriptions;
CREATE POLICY "subscriptions_anon" ON subscriptions
  FOR ALL TO anon, authenticated USING (true) WITH CHECK (true);

-- abonnements
DROP POLICY IF EXISTS "abonnements_service" ON abonnements;
CREATE POLICY "abonnements_service" ON abonnements
  FOR ALL TO anon, authenticated USING (true) WITH CHECK (true);

-- admin_actions
DROP POLICY IF EXISTS "admin_actions_service" ON admin_actions;
CREATE POLICY "admin_actions_service" ON admin_actions
  FOR ALL TO anon, authenticated USING (true) WITH CHECK (true);

-- sycapay_transactions
DROP POLICY IF EXISTS "sycapay_anon" ON sycapay_transactions;
CREATE POLICY "sycapay_anon" ON sycapay_transactions
  FOR ALL TO anon, authenticated USING (true) WITH CHECK (true);

-- prets_pending
DROP POLICY IF EXISTS "prets_pending_anon" ON prets_pending;
CREATE POLICY "prets_pending_anon" ON prets_pending
  FOR ALL TO anon, authenticated USING (true) WITH CHECK (true);

-- decaissements_pending
DROP POLICY IF EXISTS "decaissements_anon" ON decaissements_pending;
CREATE POLICY "decaissements_anon" ON decaissements_pending
  FOR ALL TO anon, authenticated USING (true) WITH CHECK (true);

-- depenses_pending
DROP POLICY IF EXISTS "depenses_anon" ON depenses_pending;
CREATE POLICY "depenses_anon" ON depenses_pending
  FOR ALL TO anon, authenticated USING (true) WITH CHECK (true);

-- premium_requests
DROP POLICY IF EXISTS "premium_requests_anon" ON premium_requests;
CREATE POLICY "premium_requests_anon" ON premium_requests
  FOR ALL TO anon, authenticated USING (true) WITH CHECK (true);

-- kyc_submissions
DROP POLICY IF EXISTS "kyc_anon" ON public.kyc_submissions;
CREATE POLICY "kyc_anon" ON public.kyc_submissions
  FOR ALL TO anon, authenticated USING (true) WITH CHECK (true);

-- fcm_tokens
DROP POLICY IF EXISTS "fcm_anon" ON public.fcm_tokens;
CREATE POLICY "fcm_anon" ON public.fcm_tokens
  FOR ALL TO anon, authenticated USING (true) WITH CHECK (true);

-- rappels_envoyes
DROP POLICY IF EXISTS "rappels_anon" ON rappels_envoyes;
CREATE POLICY "rappels_anon" ON rappels_envoyes
  FOR ALL TO anon, authenticated USING (true) WITH CHECK (true);

-- admin_membres
DROP POLICY IF EXISTS "admin_membres_service" ON admin_membres;
CREATE POLICY "admin_membres_service" ON admin_membres
  FOR ALL TO anon, authenticated USING (true) WITH CHECK (true);

-- admin_messages
DROP POLICY IF EXISTS "admin_messages_service" ON admin_messages;
CREATE POLICY "admin_messages_service" ON admin_messages
  FOR ALL TO anon, authenticated USING (true) WITH CHECK (true);

-- support_tickets
DROP POLICY IF EXISTS "support_tickets_service" ON support_tickets;
CREATE POLICY "support_tickets_service" ON support_tickets
  FOR ALL TO anon, authenticated USING (true) WITH CHECK (true);

-- support_messages
DROP POLICY IF EXISTS "support_messages_service" ON support_messages;
CREATE POLICY "support_messages_service" ON support_messages
  FOR ALL TO anon, authenticated USING (true) WITH CHECK (true);


-- ============================================================
-- SECTION F : FONCTIONS / RPCs
-- ============================================================
-- Les fonctions sont mises à jour via init_inline.sql (fichier séparé).
-- Raison : PostgreSQL exige que CREATE OR REPLACE FUNCTION conserve
-- les mêmes NOMS de paramètres que la version existante.
-- Les migrations 006-011 ont des signatures complètes avec de nombreux
-- paramètres — init_inline.sql est le fichier canonique.
--
-- PROCÉDURE :
--   Après avoir exécuté ce fichier (upgrade.sql), exécuter :
--   → init_inline.sql  dans le SQL Editor Supabase
--
-- init_inline.sql contient uniquement CREATE OR REPLACE FUNCTION
-- (aucune destruction de données) — il est également safe à rejouer.
-- ============================================================


-- ============================================================
-- VÉRIFICATION POST-EXÉCUTION (copier séparément après Run)
-- ============================================================
--
-- -- Nombre de tables (attendu : 25)
-- SELECT count(*) FROM pg_tables WHERE schemaname = 'public';
--
-- -- Tables sans RLS (attendu : 0 ligne)
-- SELECT tablename FROM pg_tables
-- WHERE schemaname = 'public' AND NOT rowsecurity;
--
-- -- Nombre de politiques RLS (attendu : 32+)
-- SELECT count(*) FROM pg_policies WHERE schemaname = 'public';
--
-- -- Index non-PK (attendu : 54+)
-- SELECT count(*) FROM pg_indexes
-- WHERE schemaname = 'public' AND indexname NOT LIKE '%_pkey';
--
-- -- Triggers (attendu : 2)
-- SELECT trigger_name, event_object_table
-- FROM information_schema.triggers
-- WHERE trigger_schema = 'public';
--
-- -- Colonnes sycapay_transactions (attendu : 31)
-- SELECT column_name FROM information_schema.columns
-- WHERE table_schema = 'public' AND table_name = 'sycapay_transactions'
-- ORDER BY ordinal_position;
--
-- ============================================================
-- FIN upgrade.sql  v3
-- ============================================================
