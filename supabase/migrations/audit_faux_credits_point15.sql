-- =============================================================================
-- AUDIT POINT 15 — Transactions créditées sans confirmation SycaPay réelle
-- Date : 2026-07-20
-- Objectif :
--   Identifier toutes les transactions dans sycapay_transactions dont le statut
--   indique un crédit (credited/confirmed/paid) mais qui n'ont aucune entrée
--   dans sycapay_audit_log avec credit_effectue = true.
--   Ces transactions sont des suspects de faux crédits à examiner manuellement.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- ÉTAPE 1 : Vue d'ensemble globale
-- ─────────────────────────────────────────────────────────────────────────────
SELECT
  statut,
  statut_traitement,
  COUNT(*)             AS nb_transactions,
  SUM(montant)         AS montant_total,
  MIN(created_at)      AS plus_ancienne,
  MAX(created_at)      AS plus_recente
FROM public.sycapay_transactions
GROUP BY statut, statut_traitement
ORDER BY nb_transactions DESC;

-- ─────────────────────────────────────────────────────────────────────────────
-- ÉTAPE 2 : Identifier les transactions créditées sans audit de crédit
--           (faux crédits potentiels — point 15 de la spec sécurité)
-- ─────────────────────────────────────────────────────────────────────────────
WITH suspects AS (
  SELECT
    t.id,
    t.internal_reference,
    t.code             AS tontine_code,
    t.membre_id,
    t.membre_nom,
    t.montant,
    t.devise,
    t.statut,
    t.statut_traitement,
    t.type,
    t.type_operation,
    t.sycapay_ref,
    t.sycapay_reference,
    t.created_at,
    t.credited_at,
    t.confirmed_at,
    -- Y a-t-il une entrée d'audit confirmant le crédit ?
    EXISTS (
      SELECT 1 FROM public.sycapay_audit_log a
      WHERE a.num_commande = t.internal_reference
        AND a.credit_effectue = true
    ) AS a_audit_credit
  FROM public.sycapay_transactions t
  WHERE
    -- Toutes les transactions qui semblent créditées
    t.statut IN ('credited', 'confirmed', 'PAID', 'paid', 'completed')
    OR t.statut_traitement IN ('credite', 'traite', 'credited', 'completed')
    OR t.credited_at IS NOT NULL
)
SELECT
  id,
  internal_reference,
  tontine_code,
  membre_id,
  membre_nom,
  montant,
  devise,
  statut,
  statut_traitement,
  type,
  type_operation,
  sycapay_ref,
  sycapay_reference,
  created_at,
  credited_at,
  confirmed_at,
  a_audit_credit,
  CASE
    WHEN NOT a_audit_credit THEN 'FAUX_CREDIT_SUSPECT'
    ELSE 'OK_AUDIT_PRESENT'
  END AS verdict
FROM suspects
ORDER BY
  -- Suspectes en premier
  a_audit_credit ASC,
  created_at DESC;

-- ─────────────────────────────────────────────────────────────────────────────
-- ÉTAPE 3 : Insérer les faux crédits dans sycapay_credit_review
--           pour examen manuel et décision de reversement
-- ─────────────────────────────────────────────────────────────────────────────
INSERT INTO public.sycapay_credit_review (
  transaction_id,
  num_commande,
  tontine_code,
  membre_id,
  montant,
  statut_original,
  raison_revue,
  created_at
)
SELECT
  t.id,
  t.internal_reference,
  t.code,
  t.membre_id,
  t.montant,
  t.statut,
  'POINT_15_AUDIT: transaction creditée sans entrée sycapay_audit_log.credit_effectue=true',
  NOW()
FROM public.sycapay_transactions t
WHERE (
  t.statut IN ('credited', 'confirmed', 'PAID', 'paid', 'completed')
  OR t.statut_traitement IN ('credite', 'traite', 'credited', 'completed')
  OR t.credited_at IS NOT NULL
)
AND NOT EXISTS (
  SELECT 1 FROM public.sycapay_audit_log a
  WHERE a.num_commande = t.internal_reference
    AND a.credit_effectue = true
)
AND NOT EXISTS (
  -- Idempotence : ne pas insérer en double
  SELECT 1 FROM public.sycapay_credit_review r
  WHERE r.transaction_id = t.id
    AND r.raison_revue LIKE 'POINT_15_AUDIT%'
)
RETURNING id, num_commande, tontine_code, membre_id, montant, statut_original;

-- ─────────────────────────────────────────────────────────────────────────────
-- ÉTAPE 4 : Résumé final
-- ─────────────────────────────────────────────────────────────────────────────
SELECT
  (SELECT COUNT(*) FROM public.sycapay_transactions
   WHERE statut IN ('credited','confirmed','PAID','paid','completed')
      OR statut_traitement IN ('credite','traite','credited','completed')
      OR credited_at IS NOT NULL) AS total_credites,
  (SELECT COUNT(*) FROM public.sycapay_audit_log
   WHERE credit_effectue = true) AS total_avec_audit,
  (SELECT COUNT(*) FROM public.sycapay_credit_review
   WHERE raison_revue LIKE 'POINT_15_AUDIT%') AS total_suspects_en_revue;
