-- =============================================================================
-- fix_prets_pending.sql
-- Migration idempotente : ajout de toutes les colonnes manquantes dans
-- public.prets_pending, sans suppression de données, sans recréation de table.
--
-- Contexte :
--   La table prets_pending a été créée avec des noms de colonnes hérités
--   (membre_id, membre_nom, taux_interet, duree_mois) qui ne correspondent
--   ni au payload Flutter ni aux colonnes attendues par les fonctions PL/pgSQL
--   admin_valider_pret (qui lit via %ROWTYPE) et admin_rejeter_pret.
--
--   Flutter envoie (soumettrePretenPending) :
--     code, emprunteur_id, emprunteur_nom, montant, frais_transaction,
--     montant_net, taux, durees_mois, operateur, numero_beneficiaire,
--     nom_beneficiaire, gestionnaire, reference, devise, description, statut
--
--   admin_valider_pret lit via v_row.* :
--     emprunteur_id, emprunteur_nom, taux, durees_mois, frais_transaction,
--     operateur, numero_beneficiaire, nom_beneficiaire, reference,
--     montant_net, gestionnaire, devise
--
--   admin_rejeter_pret écrit :
--     statut, motif_rejet, validated_at
--
-- Résultat de l'analyse des écarts (11 colonnes manquantes) :
--   ❌ emprunteur_id         (SQL avait membre_id)
--   ❌ emprunteur_nom        (SQL avait membre_nom)
--   ❌ taux                  (SQL avait taux_interet)
--   ❌ durees_mois           (SQL avait duree_mois)
--   ❌ frais_transaction
--   ❌ operateur
--   ❌ numero_beneficiaire
--   ❌ nom_beneficiaire
--   ❌ reference
--   ❌ description
--   ❌ validated_at
--
-- Stratégie :
--   ADD COLUMN IF NOT EXISTS → zéro risque sur une table déjà corrigée.
--   Les anciennes colonnes (membre_id, membre_nom, taux_interet, duree_mois)
--   sont conservées pour ne pas casser les anciens enregistrements.
--
-- Utilisation :
--   Exécuter dans le SQL Editor de Supabase, ou via psql.
--   Idempotent : peut être rejoué sans effet de bord.
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Colonnes d'identité de l'emprunteur
--    (les anciennes membre_id / membre_nom sont conservées — non supprimées)
-- ---------------------------------------------------------------------------

ALTER TABLE public.prets_pending
  ADD COLUMN IF NOT EXISTS emprunteur_id   TEXT,
  ADD COLUMN IF NOT EXISTS emprunteur_nom  TEXT;

-- ---------------------------------------------------------------------------
-- 2. Colonnes financières
--    taux       : taux d'intérêt (ancienne colonne : taux_interet, conservée)
--    durees_mois: durée en mois  (ancienne colonne : duree_mois,   conservée)
-- ---------------------------------------------------------------------------

ALTER TABLE public.prets_pending
  ADD COLUMN IF NOT EXISTS taux              NUMERIC(5,2) DEFAULT 0,
  ADD COLUMN IF NOT EXISTS durees_mois       INT          DEFAULT 1,
  ADD COLUMN IF NOT EXISTS frais_transaction NUMERIC(14,2);

-- ---------------------------------------------------------------------------
-- 3. Colonnes de paiement / bénéficiaire
-- ---------------------------------------------------------------------------

ALTER TABLE public.prets_pending
  ADD COLUMN IF NOT EXISTS operateur            TEXT,
  ADD COLUMN IF NOT EXISTS numero_beneficiaire  TEXT,
  ADD COLUMN IF NOT EXISTS nom_beneficiaire     TEXT,
  ADD COLUMN IF NOT EXISTS reference            TEXT;

-- ---------------------------------------------------------------------------
-- 4. Colonne de description libre (motif détaillé)
-- ---------------------------------------------------------------------------

ALTER TABLE public.prets_pending
  ADD COLUMN IF NOT EXISTS description TEXT;

-- ---------------------------------------------------------------------------
-- 5. Colonne de traçabilité administrative
--    validated_at : horodatage de validation/rejet par l'admin
--    (utilisée par admin_valider_pret et admin_rejeter_pret)
-- ---------------------------------------------------------------------------

ALTER TABLE public.prets_pending
  ADD COLUMN IF NOT EXISTS validated_at TIMESTAMPTZ;

-- ---------------------------------------------------------------------------
-- 6. Commentaires documentant chaque colonne ajoutée
-- ---------------------------------------------------------------------------

COMMENT ON COLUMN public.prets_pending.emprunteur_id
  IS 'Identifiant Flutter de l''emprunteur (remplace le legacy membre_id)';

COMMENT ON COLUMN public.prets_pending.emprunteur_nom
  IS 'Nom complet de l''emprunteur (remplace le legacy membre_nom)';

COMMENT ON COLUMN public.prets_pending.taux
  IS 'Taux d''intérêt en % (remplace le legacy taux_interet)';

COMMENT ON COLUMN public.prets_pending.durees_mois
  IS 'Durée du prêt en mois (remplace le legacy duree_mois)';

COMMENT ON COLUMN public.prets_pending.frais_transaction
  IS 'Frais de transaction Mobile Money déduits du montant brut';

COMMENT ON COLUMN public.prets_pending.operateur
  IS 'Opérateur Mobile Money (ex : Orange Money, Wave, MTN…)';

COMMENT ON COLUMN public.prets_pending.numero_beneficiaire
  IS 'Numéro de téléphone du bénéficiaire du décaissement';

COMMENT ON COLUMN public.prets_pending.nom_beneficiaire
  IS 'Nom du bénéficiaire tel qu''enregistré chez l''opérateur';

COMMENT ON COLUMN public.prets_pending.reference
  IS 'Référence de transaction Mobile Money (après décaissement)';

COMMENT ON COLUMN public.prets_pending.description
  IS 'Description libre / motif détaillé du prêt saisi par l''emprunteur';

COMMENT ON COLUMN public.prets_pending.validated_at
  IS 'Horodatage de validation ou de rejet par l''administrateur TontineClair';

COMMIT;

-- ---------------------------------------------------------------------------
-- 7. Rechargement du cache de schéma PostgREST
--    Indispensable pour que les nouvelles colonnes soient immédiatement
--    visibles via l'API REST (/rest/v1/prets_pending).
-- ---------------------------------------------------------------------------

NOTIFY pgrst, 'reload schema';

-- ---------------------------------------------------------------------------
-- 8. Requête de vérification
--    Affiche toutes les colonnes réelles de public.prets_pending avec
--    leur type, leur valeur par défaut et leur nullabilité.
--    À exécuter juste après pour confirmer le succès de la migration.
-- ---------------------------------------------------------------------------

SELECT
  ordinal_position                          AS "#",
  column_name                               AS "colonne",
  data_type                                 AS "type",
  character_maximum_length                  AS "longueur_max",
  numeric_precision                         AS "precision",
  numeric_scale                             AS "echelle",
  column_default                            AS "valeur_par_defaut",
  CASE is_nullable WHEN 'YES' THEN '✅ null ok' ELSE '❌ NOT NULL' END AS "nullabilite",
  CASE
    WHEN column_name IN (
      'emprunteur_id','emprunteur_nom','taux','durees_mois',
      'frais_transaction','operateur','numero_beneficiaire',
      'nom_beneficiaire','reference','description','validated_at'
    ) THEN '🆕 ajoutée'
    WHEN column_name IN ('membre_id','membre_nom','taux_interet','duree_mois')
    THEN '🔁 legacy (conservée)'
    ELSE '✅ originale'
  END AS "statut"
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name   = 'prets_pending'
ORDER BY ordinal_position;

-- =============================================================================
-- RÉSUMÉ DES CORRESPONDANCES Flutter ↔ SQL (audit de cohérence)
--
-- Payload Flutter (soumettrePretenPending)  →  Colonne SQL          Statut
-- ─────────────────────────────────────────────────────────────────────────
-- code                                      →  code                 ✅ OK
-- emprunteur_id                             →  emprunteur_id        ✅ AJOUTÉE
-- emprunteur_nom                            →  emprunteur_nom       ✅ AJOUTÉE
-- montant                                   →  montant              ✅ OK
-- frais_transaction                         →  frais_transaction    ✅ AJOUTÉE
-- montant_net                               →  montant_net          ✅ OK
-- taux                                      →  taux                 ✅ AJOUTÉE
-- durees_mois                               →  durees_mois          ✅ AJOUTÉE
-- operateur                                 →  operateur            ✅ AJOUTÉE
-- numero_beneficiaire                       →  numero_beneficiaire  ✅ AJOUTÉE
-- nom_beneficiaire                          →  nom_beneficiaire     ✅ AJOUTÉE
-- gestionnaire                              →  gestionnaire         ✅ OK
-- reference                                 →  reference            ✅ AJOUTÉE
-- devise                                    →  devise               ✅ OK
-- description                               →  description          ✅ AJOUTÉE
-- statut                                    →  statut               ✅ OK
--
-- Colonnes utilisées par admin_valider_pret (v_row.*)              Statut
-- ─────────────────────────────────────────────────────────────────────────
-- v_row.emprunteur_id                       →  emprunteur_id        ✅ AJOUTÉE
-- v_row.emprunteur_nom                      →  emprunteur_nom       ✅ AJOUTÉE
-- v_row.taux                                →  taux                 ✅ AJOUTÉE
-- v_row.durees_mois                         →  durees_mois          ✅ AJOUTÉE
-- v_row.frais_transaction                   →  frais_transaction    ✅ AJOUTÉE
-- v_row.operateur                           →  operateur            ✅ AJOUTÉE
-- v_row.numero_beneficiaire                 →  numero_beneficiaire  ✅ AJOUTÉE
-- v_row.nom_beneficiaire                    →  nom_beneficiaire     ✅ AJOUTÉE
-- v_row.reference                           →  reference            ✅ AJOUTÉE
-- v_row.montant_net                         →  montant_net          ✅ OK
-- v_row.gestionnaire                        →  gestionnaire         ✅ OK
-- v_row.devise                              →  devise               ✅ OK
--
-- Colonne utilisée par admin_rejeter_pret                          Statut
-- ─────────────────────────────────────────────────────────────────────────
-- validated_at                              →  validated_at         ✅ AJOUTÉE
--
-- VERDICT FLUTTER : aucune modification nécessaire dans le code Dart.
--                   Les noms envoyés par Flutter sont déjà corrects.
-- VERDICT APK     : aucune nouvelle APK requise.
-- =============================================================================
