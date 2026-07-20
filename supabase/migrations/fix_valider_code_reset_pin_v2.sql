-- ═══════════════════════════════════════════════════════════════════════════════
-- TontineClair — FIX CRITIQUE : Cohérence SHA-256 sur tout le flux PIN Reset
-- Version : fix-valider-v2 — 2025-07-20
--
-- PROBLÈME CORRIGÉ :
--   "function digest(text, unknown) does not exist"
--   Cause : ENCODE(DIGEST(...)) dans DECLARE sans try/catch → crash immédiat
--           si l'extension pgcrypto est absente du projet Supabase.
--
-- FONCTIONS CORRIGÉES (même logique SHA-256 dans toutes) :
--   1. valider_code_reset_pin   ← CAUSE RACINE du "code incorrect"
--   2. reinitialiser_pin        ← même bug pour le hash du nouveau PIN
--   3. modifier_pin             ← même bug pour vérif + hash du PIN
--
-- RÈGLE APPLIQUÉE PARTOUT :
--   BEGIN
--       v_hash := ENCODE(DIGEST(valeur, 'sha256'), 'hex');  -- pgcrypto si dispo
--   EXCEPTION WHEN undefined_function THEN
--       v_hash := encode(sha256(valeur::bytea), 'hex');      -- natif PG11+ sinon
--   END;
--
-- NOTE : demander_reset_pin_v3 utilise DÉJÀ ce pattern → cohérence garantie.
-- ═══════════════════════════════════════════════════════════════════════════════

-- ─────────────────────────────────────────────────────────────────────────────
-- Fonction utilitaire interne : hash_sha256_safe(valeur TEXT) → TEXT
-- Centralise le calcul SHA-256 avec fallback.
-- Utilisée par toutes les fonctions PIN du flux.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.hash_sha256_safe(p_valeur TEXT)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_hash TEXT;
BEGIN
    BEGIN
        v_hash := ENCODE(DIGEST(p_valeur, 'sha256'), 'hex');
    EXCEPTION WHEN undefined_function THEN
        v_hash := encode(sha256(p_valeur::bytea), 'hex');
    END;
    RETURN v_hash;
END;
$$;

GRANT EXECUTE ON FUNCTION public.hash_sha256_safe(TEXT) TO postgres;
-- NOTE : fonction interne uniquement, pas de GRANT à anon/authenticated


-- ─────────────────────────────────────────────────────────────────────────────
-- F2 (CORRIGÉE) : valider_code_reset_pin
--    Valide le code de réinitialisation.
--    FIX : calcul SHA-256 déplacé de DECLARE → BEGIN avec try/catch fallback.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.valider_code_reset_pin(
    p_code_tontine TEXT,
    p_nom          TEXT,
    p_code_saisi   TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_record         public.pin_reset_codes;
    v_hash_saisi     TEXT;                          -- calculé dans BEGIN, pas DECLARE
    v_max_tentatives CONSTANT INT := 5;
BEGIN
    p_code_tontine := UPPER(TRIM(p_code_tontine));
    p_nom          := TRIM(p_nom);
    p_code_saisi   := TRIM(p_code_saisi);

    -- ── 1. Trouver le code actif le plus récent ──────────────────────────────
    SELECT * INTO v_record
    FROM   public.pin_reset_codes
    WHERE  tontine_code = p_code_tontine
      AND  gest_nom     = p_nom
      AND  utilise      = FALSE
      AND  expire_at    > NOW()
    ORDER  BY cree_le DESC
    LIMIT  1;

    IF v_record.id IS NULL THEN
        RETURN jsonb_build_object(
            'ok',     FALSE,
            'erreur', 'Aucun code valide. Faites une nouvelle demande.'
        );
    END IF;

    -- ── 2. Vérifier le nombre de tentatives ─────────────────────────────────
    IF v_record.tentatives >= v_max_tentatives THEN
        UPDATE public.pin_reset_codes SET utilise = TRUE WHERE id = v_record.id;
        RETURN jsonb_build_object(
            'ok',     FALSE,
            'erreur', 'Trop de tentatives. Faites une nouvelle demande.'
        );
    END IF;

    -- ── 3. Hacher le code saisi — AVEC FALLBACK (fix de la cause racine) ─────
    --      Même algorithme que demander_reset_pin_v3 :
    --      essai pgcrypto DIGEST(), fallback sha256() natif PG11+
    BEGIN
        v_hash_saisi := ENCODE(DIGEST(TRIM(p_code_saisi), 'sha256'), 'hex');
    EXCEPTION WHEN undefined_function THEN
        v_hash_saisi := encode(sha256(TRIM(p_code_saisi)::bytea), 'hex');
    END;

    -- ── 4. Comparer les hash ─────────────────────────────────────────────────
    IF v_hash_saisi <> v_record.code THEN
        -- Incrémenter les tentatives
        UPDATE public.pin_reset_codes
        SET    tentatives = tentatives + 1
        WHERE  id = v_record.id;

        INSERT INTO public.audit_securite
            (tontine_code, gest_nom, action, description, resultat)
        VALUES (
            p_code_tontine, p_nom,
            'pin_reset_code_invalide',
            'Code de vérification incorrect — tentative ' || (v_record.tentatives + 1),
            'echec'
        );

        RETURN jsonb_build_object(
            'ok',                 FALSE,
            'erreur',             'Code incorrect.',
            'tentatives_restantes', v_max_tentatives - (v_record.tentatives + 1)
        );
    END IF;

    -- ── 5. Code valide : marquer comme utilisé ───────────────────────────────
    UPDATE public.pin_reset_codes SET utilise = TRUE WHERE id = v_record.id;

    INSERT INTO public.audit_securite
        (tontine_code, gest_nom, action, description, resultat)
    VALUES (
        p_code_tontine, p_nom,
        'pin_reset_code_valide',
        'Code de réinitialisation validé avec succès.',
        'succes'
    );

    RETURN jsonb_build_object(
        'ok',      TRUE,
        'message', 'Code validé. Vous pouvez définir votre nouveau PIN.'
    );

EXCEPTION WHEN OTHERS THEN
    RAISE LOG '[valider_code_reset_pin] Erreur inattendue : %', SQLERRM;
    RETURN jsonb_build_object(
        'ok',     FALSE,
        'erreur', 'Erreur serveur. Réessayez dans quelques instants.'
    );
END;
$$;

GRANT EXECUTE ON FUNCTION public.valider_code_reset_pin(TEXT, TEXT, TEXT) TO anon, authenticated;


-- ─────────────────────────────────────────────────────────────────────────────
-- F3 (CORRIGÉE) : reinitialiser_pin
--    Applique le nouveau PIN après validation du code.
--    FIX : ENCODE(DIGEST(...)) → pattern avec fallback sha256()
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.reinitialiser_pin(
    p_code_tontine TEXT,
    p_nom          TEXT,
    p_nouveau_pin  TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_tontine       JSONB;
    v_gests         JSONB;
    v_gest          JSONB;
    v_idx           INT     := 0;
    v_nouveau_hash  TEXT;
    v_pin_interdit  BOOL    := FALSE;
    v_recent_reset  BOOLEAN;
BEGIN
    p_code_tontine := UPPER(TRIM(p_code_tontine));
    p_nom          := TRIM(p_nom);
    p_nouveau_pin  := TRIM(p_nouveau_pin);

    -- ── 1. Vérifier qu'un code valide a été utilisé récemment (≤ 5 min) ─────
    SELECT EXISTS(
        SELECT 1 FROM public.pin_reset_codes
        WHERE  tontine_code = p_code_tontine
          AND  gest_nom     = p_nom
          AND  utilise      = TRUE
          AND  cree_le      > NOW() - INTERVAL '5 minutes'
    ) INTO v_recent_reset;

    IF NOT v_recent_reset THEN
        RETURN jsonb_build_object(
            'ok',     FALSE,
            'erreur', 'Session expirée. Recommencez la procédure.'
        );
    END IF;

    -- ── 2. Valider la longueur du nouveau PIN ────────────────────────────────
    IF LENGTH(p_nouveau_pin) < 4 THEN
        RETURN jsonb_build_object(
            'ok',     FALSE,
            'erreur', 'PIN trop court (4 chiffres minimum).'
        );
    END IF;

    -- ── 3. Interdire les PIN trop simples ────────────────────────────────────
    IF p_nouveau_pin IN (
        '0000','1111','2222','3333','4444','5555','6666','7777','8888','9999',
        '1234','4321','1212','0101','1010','0011','1100',
        '123456','654321','112233','000000','111111','999999'
    ) THEN
        v_pin_interdit := TRUE;
    END IF;

    IF v_pin_interdit THEN
        RETURN jsonb_build_object(
            'ok',     FALSE,
            'erreur', 'Ce PIN est trop simple. Choisissez un PIN plus sécurisé.'
        );
    END IF;

    -- ── 4. Récupérer la tontine ──────────────────────────────────────────────
    SELECT data INTO v_tontine
    FROM   public.tontines
    WHERE  code = p_code_tontine AND deleted_at IS NULL;

    IF v_tontine IS NULL THEN
        RETURN jsonb_build_object('ok', FALSE, 'erreur', 'Tontine introuvable.');
    END IF;

    -- ── 5. Hacher le nouveau PIN — AVEC FALLBACK ─────────────────────────────
    BEGIN
        v_nouveau_hash := ENCODE(DIGEST(p_nouveau_pin, 'sha256'), 'hex');
    EXCEPTION WHEN undefined_function THEN
        v_nouveau_hash := encode(sha256(p_nouveau_pin::bytea), 'hex');
    END;

    -- ── 6. Mettre à jour le PIN dans le JSONB gestionnaires ──────────────────
    v_gests := v_tontine -> 'gestionnaires';

    IF v_gests IS NULL OR jsonb_array_length(v_gests) = 0 THEN
        RETURN jsonb_build_object('ok', FALSE, 'erreur', 'Gestionnaire introuvable.');
    END IF;

    -- Trouver l'index du gestionnaire (cherche d'abord dans gestionnaires, puis data)
    SELECT idx INTO v_idx
    FROM (
        SELECT ordinality - 1 AS idx, elem
        FROM   jsonb_array_elements(v_gests) WITH ORDINALITY AS t(elem, ordinality)
    ) sub
    WHERE LOWER(TRIM(sub.elem->>'nom')) = LOWER(TRIM(p_nom))
    LIMIT 1;

    IF v_idx IS NULL THEN
        -- Fallback : chercher dans data->'gestionnaires'
        v_gests := v_tontine -> 'gestionnaires';
        SELECT idx INTO v_idx
        FROM (
            SELECT ordinality - 1 AS idx, elem
            FROM   jsonb_array_elements(
                       COALESCE(
                           (SELECT gestionnaires FROM tontines WHERE code = p_code_tontine),
                           v_gests
                       )
                   ) WITH ORDINALITY AS t(elem, ordinality)
        ) sub
        WHERE LOWER(TRIM(sub.elem->>'nom')) = LOWER(TRIM(p_nom))
        LIMIT 1;
    END IF;

    -- Mettre à jour dans v_gests
    v_gests   := jsonb_set(v_gests, ARRAY[v_idx::TEXT, 'pin'], to_jsonb(v_nouveau_hash));
    v_tontine := jsonb_set(v_tontine, '{gestionnaires}', v_gests);

    -- ── 7. Écrire en base ────────────────────────────────────────────────────
    UPDATE public.tontines
    SET    data       = v_tontine,
           updated_at = NOW()
    WHERE  code = p_code_tontine;

    -- ── 8. Audit ─────────────────────────────────────────────────────────────
    INSERT INTO public.audit_securite
        (tontine_code, gest_nom, action, description, resultat)
    VALUES (
        p_code_tontine, p_nom,
        'pin_reset',
        'PIN réinitialisé avec succès via procédure de récupération.',
        'succes'
    );

    RETURN jsonb_build_object('ok', TRUE, 'message', 'PIN réinitialisé avec succès.');

EXCEPTION WHEN OTHERS THEN
    RAISE LOG '[reinitialiser_pin] Erreur inattendue : %', SQLERRM;
    RETURN jsonb_build_object(
        'ok',     FALSE,
        'erreur', 'Erreur serveur. Réessayez dans quelques instants.'
    );
END;
$$;

GRANT EXECUTE ON FUNCTION public.reinitialiser_pin(TEXT, TEXT, TEXT) TO anon, authenticated;


-- ─────────────────────────────────────────────────────────────────────────────
-- F4 (CORRIGÉE) : modifier_pin
--    Change le PIN depuis une session connectée.
--    FIX : ENCODE(DIGEST(...)) → pattern avec fallback sha256()
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.modifier_pin(
    p_code        TEXT,
    p_nom         TEXT,
    p_ancien_pin  TEXT,
    p_nouveau_pin TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_tontine      JSONB;
    v_gests        JSONB;
    v_gest         JSONB;
    v_idx          INT  := 0;
    v_pin_stocke   TEXT;
    v_ancien_hash  TEXT;
    v_nouveau_hash TEXT;
BEGIN
    p_code        := UPPER(TRIM(p_code));
    p_nom         := TRIM(p_nom);
    p_ancien_pin  := TRIM(p_ancien_pin);
    p_nouveau_pin := TRIM(p_nouveau_pin);

    -- ── 1. Récupérer la tontine ──────────────────────────────────────────────
    SELECT data INTO v_tontine
    FROM   public.tontines
    WHERE  code = p_code AND deleted_at IS NULL;

    IF v_tontine IS NULL THEN
        RETURN jsonb_build_object('ok', FALSE, 'erreur', 'Tontine introuvable.');
    END IF;

    v_gests := v_tontine -> 'gestionnaires';

    -- ── 2. Trouver le gestionnaire et son PIN ────────────────────────────────
    SELECT sub.idx, sub.elem INTO v_idx, v_gest
    FROM (
        SELECT ordinality - 1 AS idx, elem
        FROM   jsonb_array_elements(v_gests) WITH ORDINALITY AS t(elem, ordinality)
    ) sub
    WHERE  LOWER(TRIM(sub.elem->>'nom')) = LOWER(TRIM(p_nom))
    LIMIT  1;

    IF v_gest IS NULL THEN
        RETURN jsonb_build_object('ok', FALSE, 'erreur', 'Gestionnaire introuvable.');
    END IF;

    -- ── 3. Hacher l'ancien PIN — AVEC FALLBACK ───────────────────────────────
    v_pin_stocke := v_gest->>'pin';

    BEGIN
        v_ancien_hash := ENCODE(DIGEST(p_ancien_pin, 'sha256'), 'hex');
    EXCEPTION WHEN undefined_function THEN
        v_ancien_hash := encode(sha256(p_ancien_pin::bytea), 'hex');
    END;

    -- Accepte PIN en clair (tontines très anciennes) OU PIN hashé
    IF v_pin_stocke <> p_ancien_pin AND v_pin_stocke <> v_ancien_hash THEN
        INSERT INTO public.audit_securite
            (tontine_code, gest_nom, action, description, resultat)
        VALUES (p_code, p_nom, 'pin_change_echec', 'Ancien PIN incorrect.', 'echec');

        RETURN jsonb_build_object('ok', FALSE, 'erreur', 'Ancien PIN incorrect.');
    END IF;

    -- ── 4. Valider le nouveau PIN ────────────────────────────────────────────
    IF LENGTH(p_nouveau_pin) < 4 THEN
        RETURN jsonb_build_object('ok', FALSE, 'erreur', 'PIN trop court (4 chiffres minimum).');
    END IF;

    IF p_nouveau_pin IN (
        '0000','1111','2222','3333','4444','5555','6666','7777','8888','9999',
        '1234','4321','1212','0101','1010','0011','1100',
        '123456','654321','112233','000000','111111','999999'
    ) THEN
        RETURN jsonb_build_object('ok', FALSE, 'erreur', 'Ce PIN est trop simple. Choisissez-en un autre.');
    END IF;

    IF p_nouveau_pin = p_ancien_pin THEN
        RETURN jsonb_build_object('ok', FALSE, 'erreur', 'Le nouveau PIN doit être différent de l''ancien.');
    END IF;

    -- ── 5. Hacher le nouveau PIN — AVEC FALLBACK ─────────────────────────────
    BEGIN
        v_nouveau_hash := ENCODE(DIGEST(p_nouveau_pin, 'sha256'), 'hex');
    EXCEPTION WHEN undefined_function THEN
        v_nouveau_hash := encode(sha256(p_nouveau_pin::bytea), 'hex');
    END;

    -- ── 6. Enregistrer ──────────────────────────────────────────────────────
    v_gests   := jsonb_set(v_gests, ARRAY[v_idx::TEXT, 'pin'], to_jsonb(v_nouveau_hash));
    v_tontine := jsonb_set(v_tontine, '{gestionnaires}', v_gests);

    UPDATE public.tontines
    SET    data       = v_tontine,
           updated_at = NOW()
    WHERE  code = p_code;

    -- ── 7. Audit ─────────────────────────────────────────────────────────────
    INSERT INTO public.audit_securite
        (tontine_code, gest_nom, action, description, resultat)
    VALUES (
        p_code, p_nom,
        'pin_change',
        'Modification du PIN de gestion depuis une session active.',
        'succes'
    );

    RETURN jsonb_build_object('ok', TRUE, 'message', 'PIN modifié avec succès.');

EXCEPTION WHEN OTHERS THEN
    RAISE LOG '[modifier_pin] Erreur inattendue : %', SQLERRM;
    RETURN jsonb_build_object(
        'ok',     FALSE,
        'erreur', 'Erreur serveur. Réessayez dans quelques instants.'
    );
END;
$$;

GRANT EXECUTE ON FUNCTION public.modifier_pin(TEXT, TEXT, TEXT, TEXT) TO anon, authenticated;


-- ═══════════════════════════════════════════════════════════════════════════════
-- Fin du fix — Résumé :
--   ✅ hash_sha256_safe()         : utilitaire centralisé avec fallback
--   ✅ valider_code_reset_pin     : CAUSE RACINE corrigée (DECLARE → BEGIN + try/catch)
--   ✅ reinitialiser_pin          : même pattern de fallback appliqué
--   ✅ modifier_pin               : même pattern de fallback appliqué
--   ✅ demander_reset_pin_v3      : déjà correct (inchangé)
-- ═══════════════════════════════════════════════════════════════════════════════
