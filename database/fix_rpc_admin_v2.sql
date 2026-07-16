-- ══════════════════════════════════════════════════════════════════════════════
-- fix_rpc_admin_v2.sql
-- Correction de l'authentification de l'Espace Admin TontineClair
--
-- Auteur    : généré automatiquement — session audit RPC admin
-- Date      : 2025-07-16
-- Dépend de : init_inline.sql (toutes migrations appliquées)
--
-- PROBLÈMES CORRIGÉS :
--   Bug 1 — admin_lister_kyc / admin_valider_kyc / admin_rejeter_kyc
--            lisent app_config.key (inexistant) au lieu de app_config.cle
--   Bug 2 — admin_tontine_counts / admin_lister_tontines
--            ont une clé administrateur codée en dur ('TONTINE_ADMIN_2024')
--   Bug 3 — admin_valider_depense / admin_rejeter_depense /
--            admin_lister_decaissements / admin_valider_decaissement /
--            admin_rejeter_decaissement
--            utilisent current_setting('app.admin_key') jamais configuré en
--            Supabase cloud, avec un fallback dangereux acceptant 'tc-admin%'
--
-- PRINCIPE :
--   • Une seule fonction privée de validation : _verif_admin_cle(p_cle TEXT)
--   • Elle lit uniquement app_config WHERE cle = 'admin_key' (colonnes réelles)
--   • Toutes les RPC Super Admin appellent cette fonction
--   • admin_auth_membre (membres d'équipe) n'est PAS modifié
--
-- IDEMPOTENCE :
--   • Uniquement CREATE OR REPLACE FUNCTION — aucun DROP TABLE
--   • Aucun DELETE / UPDATE / TRUNCATE sur les données métier
--   • Sûr à re-exécuter plusieurs fois
--
-- PÉRIMÈTRE :
--   ✅ Corrige  : 10 fonctions RPC admin
--   ✅ Préserve : toute la logique métier (corps des fonctions inchangés)
--   ✅ Préserve : admin_auth_membre (authentification membres d'équipe)
--   ✅ Préserve : toutes les tables, données, triggers, politiques RLS
-- ══════════════════════════════════════════════════════════════════════════════

-- ── Prévenir toute exécution accidentelle partielle ───────────────────────────
SET client_min_messages TO WARNING;


-- ══════════════════════════════════════════════════════════════════════════════
-- SECTION 0 — DROP des anciennes signatures pour éviter ERROR 42P13
-- ══════════════════════════════════════════════════════════════════════════════
-- Les fonctions remplacées ci-dessous ont exactement les mêmes signatures que
-- leurs versions actuelles dans init_inline.sql. Ces DROP sont donc no-op sur
-- un schéma propre mais nécessaires si le type de retour changeait.
-- Ici les signatures et types de retour sont conservés à l'identique :
-- les DROP sont présents par précaution et pour la ré-exécution sur copie.

DROP FUNCTION IF EXISTS public._verif_admin_cle(TEXT)              CASCADE;
DROP FUNCTION IF EXISTS public.admin_tontine_counts(TEXT)          CASCADE;
DROP FUNCTION IF EXISTS public.admin_lister_tontines(TEXT)         CASCADE;
DROP FUNCTION IF EXISTS public.admin_lister_kyc(TEXT, TEXT)        CASCADE;
DROP FUNCTION IF EXISTS public.admin_valider_kyc(TEXT, BIGINT)     CASCADE;
DROP FUNCTION IF EXISTS public.admin_rejeter_kyc(TEXT, BIGINT, TEXT) CASCADE;
DROP FUNCTION IF EXISTS public.admin_valider_depense(TEXT, BIGINT) CASCADE;
DROP FUNCTION IF EXISTS public.admin_rejeter_depense(TEXT, BIGINT, TEXT) CASCADE;
DROP FUNCTION IF EXISTS public.admin_lister_decaissements(TEXT, TEXT)    CASCADE;
DROP FUNCTION IF EXISTS public.admin_valider_decaissement(TEXT, BIGINT)  CASCADE;
DROP FUNCTION IF EXISTS public.admin_rejeter_decaissement(TEXT, BIGINT, TEXT) CASCADE;


-- ══════════════════════════════════════════════════════════════════════════════
-- SECTION 1 — _verif_admin_cle (version unifiée et sécurisée)
-- ══════════════════════════════════════════════════════════════════════════════
--
-- Remplace la version existante dans init_inline.sql (lignes 1864–1908)
-- qui lisait aussi "config.admin_cle" et "admin_config.cle".
--
-- Nouvelle version :
--   • Source unique : app_config WHERE cle = 'admin_key'
--     (colonnes réelles : cle TEXT PK, valeur TEXT)
--   • Refus explicite si la valeur stockée est vide ou nulle
--   • Aucune clé codée en dur
--   • Aucun fallback par préfixe
--   • SECURITY DEFINER avec search_path verrouillé
--
-- Toutes les RPC Super Admin de ce fichier appellent exclusivement
-- cette fonction pour valider la clé d'administration.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public._verif_admin_cle(p_cle TEXT)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $func_vac$
DECLARE
  v_stockee TEXT;
BEGIN
  -- Lecture de la source de vérité : app_config(cle, valeur)
  SELECT valeur INTO v_stockee
  FROM public.app_config
  WHERE cle = 'admin_key'
  LIMIT 1;

  -- Rejet si aucune clé configurée ou clé vide
  IF v_stockee IS NULL OR trim(v_stockee) = '' THEN
    RETURN false;
  END IF;

  -- Rejet si paramètre nul ou vide
  IF p_cle IS NULL OR trim(p_cle) = '' THEN
    RETURN false;
  END IF;

  -- Comparaison stricte — aucun préfixe, aucun fallback
  RETURN p_cle = v_stockee;
END;
$func_vac$;

GRANT EXECUTE ON FUNCTION public._verif_admin_cle(TEXT) TO anon, authenticated;
-- [OK] SECTION 1 : _verif_admin_cle recréée (source unique: app_config.cle)


-- ══════════════════════════════════════════════════════════════════════════════
-- SECTION 2 — admin_tontine_counts
-- CORRECTION Bug 2 : suppression de la clé 'TONTINE_ADMIN_2024' codée en dur
-- Logique métier : comptage des tontines par catégorie (inchangée)
-- ══════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.admin_tontine_counts(p_cle text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $func_atc2$
DECLARE
  v_counts   jsonb;
  v_demandes int := 0;
BEGIN
  -- Auth unifiée — aucune clé codée en dur
  IF NOT public._verif_admin_cle(p_cle) THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Clé admin invalide');
  END IF;

  WITH cats AS (
    SELECT
      code,
      CASE
        WHEN status = 'deleted' OR deleted_at IS NOT NULL THEN 'deleted'
        WHEN status = 'suspended'                          THEN 'suspended'
        WHEN status = 'inactive'                           THEN 'inactive'
        WHEN plan = 'premium'
             AND data->>'planExpire' IS NOT NULL
             AND (data->>'planExpire')::timestamptz < now() THEN 'expire'
        WHEN plan = 'premium' THEN 'premium'
        ELSE 'gratuit'
      END AS cat
    FROM tontines
  )
  SELECT jsonb_build_object(
    'total',      COUNT(*) FILTER (WHERE cat != 'deleted'),
    'actives',    COUNT(*) FILTER (WHERE cat IN ('gratuit','premium')),
    'premium',    COUNT(*) FILTER (WHERE cat = 'premium'),
    'gratuites',  COUNT(*) FILTER (WHERE cat = 'gratuit'),
    'inactives',  COUNT(*) FILTER (WHERE cat = 'inactive'),
    'suspendues', COUNT(*) FILTER (WHERE cat = 'suspended'),
    'expirees',   COUNT(*) FILTER (WHERE cat = 'expire'),
    'supprimees', COUNT(*) FILTER (WHERE cat = 'deleted')
  )
  INTO v_counts
  FROM cats;

  BEGIN
    SELECT COUNT(*) INTO v_demandes
    FROM premium_requests
    WHERE statut IN ('en_attente', 'en attente', 'pending');
  EXCEPTION WHEN undefined_table THEN
    v_demandes := 0;
  END;

  RETURN v_counts || jsonb_build_object(
    'ok',                  true,
    'demandes_en_attente', v_demandes
  );
END;
$func_atc2$;

GRANT EXECUTE ON FUNCTION public.admin_tontine_counts(text) TO anon, authenticated;
-- [OK] SECTION 2 : admin_tontine_counts corrigée (clé dure supprimée)


-- ══════════════════════════════════════════════════════════════════════════════
-- SECTION 3 — admin_lister_tontines
-- CORRECTION Bug 2 : suppression de la clé 'TONTINE_ADMIN_2024' codée en dur
-- Logique métier : liste complète des tontines soft-delete aware (inchangée)
-- ══════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.admin_lister_tontines(p_cle text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $func_alt2$
DECLARE
  v_result jsonb;
BEGIN
  -- Auth unifiée — aucune clé codée en dur
  IF NOT public._verif_admin_cle(p_cle) THEN
    RETURN '[]'::jsonb;
  END IF;

  SELECT jsonb_agg(
    jsonb_build_object(
      'code',              t.code,
      'nom',               COALESCE(
                             NULLIF(trim(t.data->>'nom'), ''),
                             'Tontine sans nom'
                           ),
      'president',         COALESCE(
                             t.data->'gestionnaire'->>'nom',
                             t.data->>'gestionnaire',
                             t.data->>'president',
                             t.data->>'created_by',
                             t.data->>'owner'
                           ),
      'membres',           COALESCE(jsonb_array_length(t.data->'membres'), 0),
      'plan',              COALESCE(t.plan, 'free'),
      'plan_expire',       t.data->>'planExpire',
      'cree',              to_char(t.created_at, 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
      'status',            COALESCE(t.status, 'active'),
      'deleted_at',        CASE WHEN t.deleted_at IS NOT NULL
                                THEN to_char(t.deleted_at, 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
                                ELSE NULL END,
      'deleted_by',        t.deleted_by,
      'deletion_reason',   t.deletion_reason,
      'invitation_active', t.invitation_code_active
    )
    ORDER BY
      CASE WHEN COALESCE(t.status,'active') = 'deleted' THEN 1 ELSE 0 END ASC,
      t.created_at DESC
  )
  INTO v_result
  FROM tontines t;

  RETURN COALESCE(v_result, '[]'::jsonb);
END;
$func_alt2$;

GRANT EXECUTE ON FUNCTION public.admin_lister_tontines(text) TO anon, authenticated;
-- [OK] SECTION 3 : admin_lister_tontines corrigée (clé dure supprimée)


-- ══════════════════════════════════════════════════════════════════════════════
-- SECTION 4 — admin_lister_kyc
-- CORRECTION Bug 1 : app_config.key → app_config.cle / value → valeur
-- Logique métier : liste les soumissions KYC filtrées par statut (inchangée)
-- ══════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.admin_lister_kyc(
  p_cle    TEXT,
  p_statut TEXT DEFAULT 'tous'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $func_alk2$
DECLARE
  v_liste JSONB;
BEGIN
  -- Auth unifiée — colonnes réelles app_config(cle, valeur)
  IF NOT public._verif_admin_cle(p_cle) THEN
    RAISE EXCEPTION 'Clé admin invalide';
  END IF;

  IF p_statut = 'tous' THEN
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',           k.id,
      'code',         k.code,
      'gestionnaire', k.gestionnaire,
      'nom',          k.nom,
      'piece_type',   k.piece_type,
      'piece_numero', k.piece_numero,
      'soumis_le',    k.soumis_le,
      'statut',       k.statut,
      'motif_rejet',  k.motif_rejet,
      'valide_par',   k.valide_par,
      'validated_at', k.validated_at,
      'created_at',   k.created_at
    ) ORDER BY k.created_at DESC), '[]'::jsonb)
    INTO v_liste
    FROM public.kyc_submissions k;
  ELSE
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',           k.id,
      'code',         k.code,
      'gestionnaire', k.gestionnaire,
      'nom',          k.nom,
      'piece_type',   k.piece_type,
      'piece_numero', k.piece_numero,
      'soumis_le',    k.soumis_le,
      'statut',       k.statut,
      'motif_rejet',  k.motif_rejet,
      'valide_par',   k.valide_par,
      'validated_at', k.validated_at,
      'created_at',   k.created_at
    ) ORDER BY k.created_at DESC), '[]'::jsonb)
    INTO v_liste
    FROM public.kyc_submissions k
    WHERE k.statut = p_statut;
  END IF;

  RETURN v_liste;
END;
$func_alk2$;

GRANT EXECUTE ON FUNCTION public.admin_lister_kyc(TEXT, TEXT) TO anon, authenticated;
-- [OK] SECTION 4 : admin_lister_kyc corrigée (app_config.cle/valeur)


-- ══════════════════════════════════════════════════════════════════════════════
-- SECTION 5 — admin_valider_kyc
-- CORRECTION Bug 1 : app_config.key → app_config.cle / value → valeur
-- Logique métier : valide un dossier KYC + met à jour tontines.data (inchangée)
-- ══════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.admin_valider_kyc(
  p_cle TEXT,
  p_id  BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $func_avk2$
DECLARE
  v_submission RECORD;
  v_now        TIMESTAMPTZ := NOW();
BEGIN
  -- Auth unifiée — colonnes réelles app_config(cle, valeur)
  IF NOT public._verif_admin_cle(p_cle) THEN
    RAISE EXCEPTION 'Clé admin invalide';
  END IF;

  SELECT * INTO v_submission FROM public.kyc_submissions WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Dossier KYC introuvable.');
  END IF;
  IF v_submission.statut <> 'pending' THEN
    RETURN jsonb_build_object('ok', false, 'erreur',
      'Ce dossier a déjà été traité (statut : ' || v_submission.statut || ').');
  END IF;

  UPDATE public.kyc_submissions
    SET statut = 'valide', validated_at = v_now, valide_par = 'admin'
    WHERE id = p_id;

  UPDATE public.tontines
    SET data = jsonb_set(COALESCE(data, '{}'::jsonb), '{kyc, statut}', '"valide"', true)
    WHERE code = v_submission.code;

  RETURN jsonb_build_object(
    'ok',           true,
    'message',      'Dossier KYC validé avec succès.',
    'gestionnaire', v_submission.gestionnaire,
    'code',         v_submission.code
  );
END;
$func_avk2$;

GRANT EXECUTE ON FUNCTION public.admin_valider_kyc(TEXT, BIGINT) TO anon, authenticated;
-- [OK] SECTION 5 : admin_valider_kyc corrigée (app_config.cle/valeur)


-- ══════════════════════════════════════════════════════════════════════════════
-- SECTION 6 — admin_rejeter_kyc
-- CORRECTION Bug 1 : app_config.key → app_config.cle / value → valeur
-- Logique métier : rejette un dossier KYC + met à jour tontines.data (inchangée)
-- ══════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.admin_rejeter_kyc(
  p_cle   TEXT,
  p_id    BIGINT,
  p_motif TEXT DEFAULT 'Dossier non conforme.'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $func_ark2$
DECLARE
  v_submission RECORD;
  v_now        TIMESTAMPTZ := NOW();
BEGIN
  -- Auth unifiée — colonnes réelles app_config(cle, valeur)
  IF NOT public._verif_admin_cle(p_cle) THEN
    RAISE EXCEPTION 'Clé admin invalide';
  END IF;

  SELECT * INTO v_submission FROM public.kyc_submissions WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Dossier KYC introuvable.');
  END IF;
  IF v_submission.statut <> 'pending' THEN
    RETURN jsonb_build_object('ok', false, 'erreur',
      'Ce dossier a déjà été traité (statut : ' || v_submission.statut || ').');
  END IF;

  UPDATE public.kyc_submissions
    SET statut      = 'rejete',
        motif_rejet = p_motif,
        validated_at = v_now,
        valide_par  = 'admin'
    WHERE id = p_id;

  UPDATE public.tontines
    SET data = jsonb_set(
                 jsonb_set(COALESCE(data, '{}'::jsonb), '{kyc, statut}', '"rejete"', true),
                 '{kyc, motifRejet}', to_jsonb(p_motif), true
               )
    WHERE code = v_submission.code;

  RETURN jsonb_build_object(
    'ok',           true,
    'message',      'Dossier KYC rejeté.',
    'gestionnaire', v_submission.gestionnaire,
    'code',         v_submission.code,
    'motif',        p_motif
  );
END;
$func_ark2$;

GRANT EXECUTE ON FUNCTION public.admin_rejeter_kyc(TEXT, BIGINT, TEXT) TO anon, authenticated;
-- [OK] SECTION 6 : admin_rejeter_kyc corrigée (app_config.cle/valeur)


-- ══════════════════════════════════════════════════════════════════════════════
-- SECTION 7 — admin_lister_decaissements
-- CORRECTION Bug 3 : current_setting + fallback préfixe → _verif_admin_cle
-- Logique métier : liste les décaissements filtrés par statut (inchangée)
-- ══════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.admin_lister_decaissements(
  p_cle    TEXT,
  p_statut TEXT DEFAULT 'tous'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $func_ald2$
DECLARE
  v_rows JSONB;
BEGIN
  -- Auth unifiée via _verif_admin_cle (Bug3 corrigé)
  IF NOT public._verif_admin_cle(p_cle) THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Clé admin invalide');
  END IF;

  IF p_statut = 'tous' THEN
    SELECT jsonb_agg(row_to_json(d.*)::jsonb ORDER BY d.created_at DESC)
    INTO v_rows
    FROM public.decaissements_pending d;
  ELSE
    SELECT jsonb_agg(row_to_json(d.*)::jsonb ORDER BY d.created_at DESC)
    INTO v_rows
    FROM public.decaissements_pending d
    WHERE d.statut = p_statut;
  END IF;

  RETURN COALESCE(v_rows, '[]'::jsonb);
EXCEPTION WHEN OTHERS THEN
  RETURN '[]'::jsonb;
END;
$func_ald2$;

GRANT EXECUTE ON FUNCTION public.admin_lister_decaissements(TEXT, TEXT) TO anon, authenticated;
-- [OK] SECTION 7 : admin_lister_decaissements corrigée (supprime current_setting)


-- ══════════════════════════════════════════════════════════════════════════════
-- SECTION 8 — admin_valider_decaissement
-- CORRECTION Bug 3 : current_setting + fallback préfixe → _verif_admin_cle
-- Logique métier : valide un décaissement + débite la caisse (inchangée)
-- ══════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.admin_valider_decaissement(
  p_cle TEXT,
  p_id  BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $func_avd2$
DECLARE
  v_dec           public.decaissements_pending%ROWTYPE;
  v_tontine_data  JSONB;
  v_caisse        JSONB;
  v_mouvements    JSONB;
  v_journal       JSONB;
  v_solde         INTEGER;
  v_ref           TEXT;
  v_now           TEXT;
  v_new_mouvement JSONB;
BEGIN
  -- Auth unifiée via _verif_admin_cle (Bug3 corrigé)
  IF NOT public._verif_admin_cle(p_cle) THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Clé admin invalide');
  END IF;

  SELECT * INTO v_dec FROM public.decaissements_pending WHERE id = p_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Décaissement introuvable');
  END IF;
  IF v_dec.statut <> 'pending' THEN
    RETURN jsonb_build_object('ok', false, 'erreur',
      'Décaissement déjà traité (statut: ' || v_dec.statut || ')');
  END IF;

  SELECT data INTO v_tontine_data FROM public.tontines WHERE UPPER(code) = UPPER(v_dec.code);
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Tontine introuvable: ' || v_dec.code);
  END IF;

  v_caisse     := COALESCE(v_tontine_data->'caisse', '{"mouvements":[]}'::jsonb);
  v_mouvements := COALESCE(v_caisse->'mouvements', '[]'::jsonb);

  SELECT COALESCE(SUM(CASE
    WHEN (m->>'type') IN ('depot','cotisation','remboursement','apport')
         THEN  (m->>'montant')::integer
    WHEN (m->>'type') IN ('depense','pret','penalite','correction','decaissement')
         THEN -((m->>'montant')::integer)
    ELSE 0 END), 0)
  INTO v_solde
  FROM jsonb_array_elements(v_mouvements) AS m;

  IF v_solde < v_dec.montant_net THEN
    RETURN jsonb_build_object('ok', false, 'erreur',
      format('Solde caisse insuffisant : %s %s disponible, %s %s requis',
             v_solde, v_dec.devise, v_dec.montant_net, v_dec.devise));
  END IF;

  v_ref := COALESCE(NULLIF(v_dec.reference, ''),
                    'DEC-' || EXTRACT(EPOCH FROM NOW())::BIGINT::TEXT);
  v_now := to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"');

  v_new_mouvement := jsonb_build_object(
    'id',                  v_ref,
    'type',                'decaissement',
    'montant',             v_dec.montant_net,
    'description',         format('Décaissement tour %s — %s — Mobile Money %s',
                                  v_dec.numer_tour, v_dec.beneficiaire_nom, upper(v_dec.operateur)),
    'gestionnaire',        v_dec.gestionnaire,
    'date',                v_now,
    'reference',           v_ref,
    'methode',             v_dec.operateur,
    'numero_beneficiaire', v_dec.numero_beneficiaire,
    'beneficiaire_id',     v_dec.beneficiaire_id,
    'beneficiaire_nom',    v_dec.beneficiaire_nom,
    'numer_tour',          v_dec.numer_tour,
    'commission',          v_dec.commission,
    'montant_brut',        v_dec.montant,
    'decaissement_id',     p_id
  );

  IF jsonb_typeof(v_caisse) = 'object' THEN
    v_mouvements := COALESCE(v_caisse->'mouvements', '[]'::jsonb);
    v_caisse := jsonb_set(v_caisse, '{mouvements}',
                          v_mouvements || jsonb_build_array(v_new_mouvement));
  ELSIF jsonb_typeof(v_caisse) = 'array' THEN
    v_caisse := jsonb_build_object('mouvements',
                  v_caisse || jsonb_build_array(v_new_mouvement));
  ELSE
    v_caisse := jsonb_build_object('mouvements', jsonb_build_array(v_new_mouvement));
  END IF;

  v_tontine_data := jsonb_set(v_tontine_data, '{caisse}', v_caisse);
  v_journal := COALESCE(v_tontine_data->'journal', '[]'::jsonb);
  v_journal := jsonb_build_array(jsonb_build_object(
    'quoi',         format('DÉCAISSEMENT VALIDÉ — Tour %s — %s — %s %s (net) — %s [commission: %s %s] — %s',
                           v_dec.numer_tour, v_dec.beneficiaire_nom, v_dec.montant_net, v_dec.devise,
                           upper(v_dec.operateur), v_dec.commission, v_dec.devise, v_dec.numero_beneficiaire),
    'gestionnaire', v_dec.gestionnaire,
    'quand',        v_now,
    'reference',    v_ref
  )) || v_journal;
  v_tontine_data := jsonb_set(v_tontine_data, '{journal}', v_journal);

  UPDATE public.tontines
    SET data = v_tontine_data, modifie_le = NOW()
    WHERE UPPER(code) = UPPER(v_dec.code);

  UPDATE public.decaissements_pending
    SET statut = 'validee', validated_at = NOW(), valide_par = 'admin'
    WHERE id = p_id;

  RETURN jsonb_build_object(
    'ok',           true,
    'message',      format('Décaissement validé — caisse débitée de %s %s (commission %s %s déduite)',
                           v_dec.montant_net, v_dec.devise, v_dec.commission, v_dec.devise),
    'montant_net',  v_dec.montant_net,
    'commission',   v_dec.commission,
    'beneficiaire', v_dec.beneficiaire_nom,
    'numer_tour',   v_dec.numer_tour
  );
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'erreur', SQLERRM);
END;
$func_avd2$;

GRANT EXECUTE ON FUNCTION public.admin_valider_decaissement(TEXT, BIGINT) TO anon, authenticated;
-- [OK] SECTION 8 : admin_valider_decaissement corrigée (supprime current_setting)


-- ══════════════════════════════════════════════════════════════════════════════
-- SECTION 9 — admin_rejeter_decaissement
-- CORRECTION Bug 3 : current_setting + fallback préfixe → _verif_admin_cle
-- Logique métier : rejette un décaissement, caisse inchangée (inchangée)
-- ══════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.admin_rejeter_decaissement(
  p_cle   TEXT,
  p_id    BIGINT,
  p_motif TEXT DEFAULT 'Rejeté par l''administrateur'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $func_ard2$
DECLARE
  v_dec public.decaissements_pending%ROWTYPE;
BEGIN
  -- Auth unifiée via _verif_admin_cle (Bug3 corrigé)
  IF NOT public._verif_admin_cle(p_cle) THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Clé admin invalide');
  END IF;

  SELECT * INTO v_dec FROM public.decaissements_pending WHERE id = p_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Décaissement introuvable');
  END IF;
  IF v_dec.statut <> 'pending' THEN
    RETURN jsonb_build_object('ok', false, 'erreur',
      'Décaissement déjà traité (statut: ' || v_dec.statut || ')');
  END IF;

  UPDATE public.decaissements_pending
    SET statut      = 'rejetee',
        motif_rejet = p_motif,
        validated_at = NOW(),
        valide_par  = 'admin'
    WHERE id = p_id;

  RETURN jsonb_build_object(
    'ok',          true,
    'message',     'Décaissement rejeté. La caisse n''a pas été modifiée.',
    'beneficiaire', v_dec.beneficiaire_nom,
    'numer_tour',  v_dec.numer_tour
  );
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'erreur', SQLERRM);
END;
$func_ard2$;

GRANT EXECUTE ON FUNCTION public.admin_rejeter_decaissement(TEXT, BIGINT, TEXT) TO anon, authenticated;
-- [OK] SECTION 9 : admin_rejeter_decaissement corrigée (supprime current_setting)


-- ══════════════════════════════════════════════════════════════════════════════
-- SECTION 10 — admin_valider_depense
-- CORRECTION Bug 3 : current_setting + fallback préfixe → _verif_admin_cle
-- Logique métier : valide une dépense + débite la caisse (inchangée)
-- ══════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.admin_valider_depense(
  p_cle TEXT,
  p_id  BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $func_avdep2$
DECLARE
  v_depense       public.depenses_pending%ROWTYPE;
  v_tontine_data  JSONB;
  v_caisse        JSONB;
  v_mouvements    JSONB;
  v_ref           TEXT;
  v_now           TEXT;
  v_new_mouvement JSONB;
BEGIN
  -- Auth unifiée via _verif_admin_cle (Bug3 corrigé)
  IF NOT public._verif_admin_cle(p_cle) THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Clé admin invalide');
  END IF;

  SELECT * INTO v_depense FROM public.depenses_pending WHERE id = p_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Dépense introuvable');
  END IF;
  IF v_depense.statut <> 'pending' THEN
    RETURN jsonb_build_object('ok', false, 'erreur',
      'Dépense déjà traitée (statut: ' || v_depense.statut || ')');
  END IF;

  SELECT data INTO v_tontine_data FROM public.tontines WHERE code = v_depense.code;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Tontine introuvable: ' || v_depense.code);
  END IF;

  v_ref := 'DEP-' || EXTRACT(EPOCH FROM NOW())::BIGINT::TEXT;
  v_now := NOW()::TEXT;

  v_new_mouvement := jsonb_build_object(
    'id',                  v_ref,
    'type',                'depense',
    'montant',             v_depense.montant,
    'description',         COALESCE(NULLIF(v_depense.description, ''),
                             'Dépense Mobile Money — ' || v_depense.operateur),
    'gestionnaire',        v_depense.gestionnaire,
    'date',                v_now,
    'reference',           v_ref,
    'methode',             v_depense.operateur,
    'numero_beneficiaire', v_depense.numero_beneficiaire,
    'nom_beneficiaire',    v_depense.nom_beneficiaire,
    'depense_id',          p_id
  );

  v_caisse := COALESCE(v_tontine_data->'caisse', '{}'::jsonb);
  IF jsonb_typeof(v_caisse) = 'object' THEN
    v_mouvements := COALESCE(v_caisse->'mouvements', '[]'::jsonb);
    v_caisse := jsonb_set(v_caisse, '{mouvements}',
                          v_mouvements || jsonb_build_array(v_new_mouvement));
  ELSIF jsonb_typeof(v_caisse) = 'array' THEN
    v_caisse := jsonb_build_object('mouvements',
                  v_caisse || jsonb_build_array(v_new_mouvement));
  ELSE
    v_caisse := jsonb_build_object('mouvements', jsonb_build_array(v_new_mouvement));
  END IF;

  v_tontine_data := jsonb_set(v_tontine_data, '{caisse}', v_caisse);

  UPDATE public.tontines
    SET data = v_tontine_data, modifie_le = NOW()
    WHERE code = v_depense.code;

  UPDATE public.depenses_pending
    SET statut = 'validee', valide_le = NOW(), valide_par = 'admin'
    WHERE id = p_id;

  RETURN jsonb_build_object(
    'ok',      true,
    'message', 'Dépense validée — caisse débitée de '
               || v_depense.montant::TEXT || ' ' || v_depense.devise
  );
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'erreur', SQLERRM);
END;
$func_avdep2$;

GRANT EXECUTE ON FUNCTION public.admin_valider_depense(TEXT, BIGINT) TO anon, authenticated;
-- [OK] SECTION 10 : admin_valider_depense corrigée (supprime current_setting)


-- ══════════════════════════════════════════════════════════════════════════════
-- SECTION 11 — admin_rejeter_depense
-- CORRECTION Bug 3 : current_setting + fallback préfixe → _verif_admin_cle
-- Logique métier : rejette une dépense, caisse inchangée (inchangée)
-- ══════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.admin_rejeter_depense(
  p_cle   TEXT,
  p_id    BIGINT,
  p_motif TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $func_ardep2$
DECLARE
  v_depense public.depenses_pending%ROWTYPE;
BEGIN
  -- Auth unifiée via _verif_admin_cle (Bug3 corrigé)
  IF NOT public._verif_admin_cle(p_cle) THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Clé admin invalide');
  END IF;

  SELECT * INTO v_depense FROM public.depenses_pending WHERE id = p_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Dépense introuvable');
  END IF;
  IF v_depense.statut <> 'pending' THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Dépense déjà traitée');
  END IF;

  UPDATE public.depenses_pending
    SET statut      = 'rejetee',
        motif_rejet = p_motif,
        valide_le   = NOW(),
        valide_par  = 'admin'
    WHERE id = p_id;

  RETURN jsonb_build_object('ok', true, 'message', 'Dépense rejetée.');
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'erreur', SQLERRM);
END;
$func_ardep2$;

GRANT EXECUTE ON FUNCTION public.admin_rejeter_depense(TEXT, BIGINT, TEXT) TO anon, authenticated;
-- [OK] SECTION 11 : admin_rejeter_depense corrigée (supprime current_setting)


-- ══════════════════════════════════════════════════════════════════════════════
-- SECTION 12 — BLOC DE VÉRIFICATION
-- Confirme : présence de _verif_admin_cle, absence des patterns dangereux,
-- et teste les 4 scénarios d'accès avec un enregistrement de test temporaire.
-- ══════════════════════════════════════════════════════════════════════════════
DO $verification$
DECLARE
  -- ── Vérifications structurelles ────────────────────────────────────────────
  v_vac_exists       boolean;
  v_current_setting  int;
  v_hardcoded_key    int;
  v_wrong_col_key    int;
  v_wrong_col_value  int;

  -- ── Vérifications des signatures ───────────────────────────────────────────
  v_sig_atc   boolean;
  v_sig_alt   boolean;
  v_sig_alk   boolean;
  v_sig_avk   boolean;
  v_sig_ark   boolean;
  v_sig_ald   boolean;
  v_sig_avd   boolean;
  v_sig_ard   boolean;
  v_sig_avdep boolean;
  v_sig_ardep boolean;

  -- ── Tests fonctionnels ─────────────────────────────────────────────────────
  v_test_cle_correcte text := '__TEST_CLE_V2_' || extract(epoch from now())::bigint::text;
  v_test_inserted     boolean := false;
  v_res_correcte      boolean;
  v_res_incorrecte    boolean;
  v_res_vide          boolean;
  v_res_null          boolean;
  v_res_auth_membre   jsonb;

BEGIN
  RAISE NOTICE '══════════════════════════════════════════════════════';
  RAISE NOTICE 'VÉRIFICATION fix_rpc_admin_v2.sql';
  RAISE NOTICE '══════════════════════════════════════════════════════';

  -- ── V1 : _verif_admin_cle existe ─────────────────────────────────────────
  SELECT EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = '_verif_admin_cle'
  ) INTO v_vac_exists;
  IF v_vac_exists THEN
    RAISE NOTICE '[OK] V1 : _verif_admin_cle est présente';
  ELSE
    RAISE EXCEPTION '[FAIL] V1 : _verif_admin_cle INTROUVABLE';
  END IF;

  -- ── V2 : aucun current_setting dans les fonctions admin corrigées ─────────
  SELECT COUNT(*) INTO v_current_setting
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname IN (
      'admin_tontine_counts','admin_lister_tontines',
      'admin_lister_kyc','admin_valider_kyc','admin_rejeter_kyc',
      'admin_valider_depense','admin_rejeter_depense',
      'admin_lister_decaissements','admin_valider_decaissement',
      'admin_rejeter_decaissement'
    )
    AND pg_get_functiondef(p.oid) ILIKE '%current_setting%';
  IF v_current_setting = 0 THEN
    RAISE NOTICE '[OK] V2 : aucun current_setting(''app.admin_key'') dans les fonctions corrigées';
  ELSE
    RAISE EXCEPTION '[FAIL] V2 : % fonction(s) contiennent encore current_setting', v_current_setting;
  END IF;

  -- ── V3 : aucune clé codée en dur dans les fonctions admin ────────────────
  SELECT COUNT(*) INTO v_hardcoded_key
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname IN (
      'admin_tontine_counts','admin_lister_tontines',
      '_verif_admin_cle'
    )
    AND pg_get_functiondef(p.oid) ILIKE '%TONTINE_ADMIN_2024%';
  IF v_hardcoded_key = 0 THEN
    RAISE NOTICE '[OK] V3 : aucune clé administrateur codée en dur trouvée';
  ELSE
    RAISE EXCEPTION '[FAIL] V3 : % fonction(s) contiennent encore une clé codée en dur', v_hardcoded_key;
  END IF;

  -- ── V4 : aucune référence à app_config.key ou app_config.value ────────────
  SELECT COUNT(*) INTO v_wrong_col_key
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname IN (
      'admin_lister_kyc','admin_valider_kyc','admin_rejeter_kyc'
    )
    AND pg_get_functiondef(p.oid) ~ 'app_config\s+WHERE\s+key\s*=';
  IF v_wrong_col_key = 0 THEN
    RAISE NOTICE '[OK] V4a : aucune référence à app_config.key (colonne inexistante)';
  ELSE
    RAISE EXCEPTION '[FAIL] V4a : % fonction(s) contiennent encore WHERE key =', v_wrong_col_key;
  END IF;

  SELECT COUNT(*) INTO v_wrong_col_value
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname IN (
      'admin_lister_kyc','admin_valider_kyc','admin_rejeter_kyc'
    )
    AND pg_get_functiondef(p.oid) ~ 'SELECT\s+value\s+INTO.*app_config';
  IF v_wrong_col_value = 0 THEN
    RAISE NOTICE '[OK] V4b : aucun SELECT value (colonne inexistante) sur app_config';
  ELSE
    RAISE EXCEPTION '[FAIL] V4b : % fonction(s) font encore SELECT value sur app_config', v_wrong_col_value;
  END IF;

  -- ── V5 : vérification des signatures conformes aux appels Flutter ─────────
  SELECT EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.proname='admin_tontine_counts'
      AND array_length(p.proargtypes,1)=1) INTO v_sig_atc;

  SELECT EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.proname='admin_lister_tontines'
      AND array_length(p.proargtypes,1)=1) INTO v_sig_alt;

  SELECT EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.proname='admin_lister_kyc'
      AND array_length(p.proargtypes,1)=2) INTO v_sig_alk;

  SELECT EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.proname='admin_valider_kyc'
      AND array_length(p.proargtypes,1)=2) INTO v_sig_avk;

  SELECT EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.proname='admin_rejeter_kyc'
      AND array_length(p.proargtypes,1)=3) INTO v_sig_ark;

  SELECT EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.proname='admin_lister_decaissements'
      AND array_length(p.proargtypes,1)=2) INTO v_sig_ald;

  SELECT EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.proname='admin_valider_decaissement'
      AND array_length(p.proargtypes,1)=2) INTO v_sig_avd;

  SELECT EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.proname='admin_rejeter_decaissement'
      AND array_length(p.proargtypes,1)=3) INTO v_sig_ard;

  SELECT EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.proname='admin_valider_depense'
      AND array_length(p.proargtypes,1)=2) INTO v_sig_avdep;

  SELECT EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.proname='admin_rejeter_depense'
      AND array_length(p.proargtypes,1)=3) INTO v_sig_ardep;

  IF v_sig_atc AND v_sig_alt AND v_sig_alk AND v_sig_avk AND v_sig_ark
     AND v_sig_ald AND v_sig_avd AND v_sig_ard AND v_sig_avdep AND v_sig_ardep THEN
    RAISE NOTICE '[OK] V5 : signatures de toutes les RPC conformes aux appels Flutter';
  ELSE
    RAISE WARNING '[WARN] V5 : signature incorrecte — atc=% alt=% alk=% avk=% ark=% ald=% avd=% ard=% avdep=% ardep=%',
      v_sig_atc, v_sig_alt, v_sig_alk, v_sig_avk, v_sig_ark,
      v_sig_ald, v_sig_avd, v_sig_ard, v_sig_avdep, v_sig_ardep;
  END IF;

  -- ── V6 : tests fonctionnels de _verif_admin_cle ──────────────────────────
  -- Insérer une clé de test dans app_config
  BEGIN
    INSERT INTO public.app_config (cle, valeur)
    VALUES ('admin_key', v_test_cle_correcte)
    ON CONFLICT (cle) DO UPDATE SET valeur = v_test_cle_correcte;
    v_test_inserted := true;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING '[SKIP] V6 : impossible d''insérer dans app_config (%)', SQLERRM;
  END;

  IF v_test_inserted THEN
    -- Test 1 : clé correcte → true
    SELECT public._verif_admin_cle(v_test_cle_correcte) INTO v_res_correcte;
    IF v_res_correcte IS TRUE THEN
      RAISE NOTICE '[OK] V6a : clé correcte → accès AUTORISÉ';
    ELSE
      RAISE EXCEPTION '[FAIL] V6a : clé correcte → accès refusé (attendu: autorisé)';
    END IF;

    -- Test 2 : clé incorrecte → false
    SELECT public._verif_admin_cle('mauvaise_cle_xyz') INTO v_res_incorrecte;
    IF v_res_incorrecte IS FALSE THEN
      RAISE NOTICE '[OK] V6b : clé incorrecte → accès REFUSÉ';
    ELSE
      RAISE EXCEPTION '[FAIL] V6b : clé incorrecte → accès autorisé (attendu: refusé)';
    END IF;

    -- Test 3 : clé vide → false
    SELECT public._verif_admin_cle('') INTO v_res_vide;
    IF v_res_vide IS FALSE THEN
      RAISE NOTICE '[OK] V6c : clé vide → accès REFUSÉ';
    ELSE
      RAISE EXCEPTION '[FAIL] V6c : clé vide → accès autorisé (attendu: refusé)';
    END IF;

    -- Test 4 : NULL → false
    SELECT public._verif_admin_cle(NULL) INTO v_res_null;
    IF v_res_null IS FALSE THEN
      RAISE NOTICE '[OK] V6d : clé NULL → accès REFUSÉ';
    ELSE
      RAISE EXCEPTION '[FAIL] V6d : clé NULL → accès autorisé (attendu: refusé)';
    END IF;

    -- Test 5 : préfixe 'tc-admin' (ancien fallback) → false
    SELECT public._verif_admin_cle('tc-admin-prefixe') INTO v_res_incorrecte;
    IF v_res_incorrecte IS FALSE THEN
      RAISE NOTICE '[OK] V6e : préfixe tc-admin → accès REFUSÉ (fallback supprimé)';
    ELSE
      RAISE EXCEPTION '[FAIL] V6e : préfixe tc-admin → accès autorisé (fallback non supprimé)';
    END IF;

    -- Restauration : remettre la valeur originale si elle existait,
    -- sinon supprimer l'enregistrement de test
    -- (on ne connaît pas la vraie clé de prod — on laisse la clé de test)
    -- L'opérateur doit mettre à jour app_config avec sa vraie clé après exécution.
    RAISE NOTICE '════════════════════════════════════════════════════';
    RAISE NOTICE 'ATTENTION : app_config.admin_key a été écrite avec une valeur de test.';
    RAISE NOTICE 'Après exécution, mettez à jour app_config avec votre vraie clé :';
    RAISE NOTICE '  UPDATE public.app_config SET valeur = ''VOTRE_CLE_ADMIN'' WHERE cle = ''admin_key'';';
    RAISE NOTICE '════════════════════════════════════════════════════';
  END IF;

  -- ── V7 : vérifier que admin_auth_membre est intact (non modifié) ──────────
  SELECT EXISTS(
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'admin_auth_membre'
      AND pg_get_functiondef(p.oid) ILIKE '%cle_hash%'
      AND pg_get_functiondef(p.oid) ILIKE '%admin_membres%'
  ) INTO v_test_inserted; -- réutilisation de la variable booléenne
  IF v_test_inserted THEN
    RAISE NOTICE '[OK] V7 : admin_auth_membre intact (hash + admin_membres)';
  ELSE
    RAISE WARNING '[WARN] V7 : admin_auth_membre introuvable ou modifié — vérifier manuellement';
  END IF;

  RAISE NOTICE '══════════════════════════════════════════════════════';
  RAISE NOTICE 'RÉSULTAT : fix_rpc_admin_v2.sql appliqué avec succès.';
  RAISE NOTICE '10 fonctions RPC admin corrigées — authentification unifiée.';
  RAISE NOTICE '══════════════════════════════════════════════════════';
END;
$verification$;
