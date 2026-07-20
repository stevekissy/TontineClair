-- ═══════════════════════════════════════════════════════════════════════════════
-- TontineClair — FIX : reinitialiser_pin + modifier_pin écrivent dans la mauvaise colonne
-- Version : fix-colonne-v3 — 2025-07-20
--
-- PROBLÈME :
--   La table `tontines` a DEUX colonnes pour les gestionnaires :
--     1. colonne `gestionnaires` JSONB séparée  ← LUE par verifier_gestionnaire + l'app
--     2. colonne `data`->>'gestionnaires'       ← ÉCRITE par reinitialiser_pin et modifier_pin
--
--   → L'app lit le PIN depuis `gestionnaires` (colonne 1) → PIN en clair = 0103
--   → reinitialiser_pin écrit dans `data` (colonne 2)     → ignoré par l'app
--   → Résultat : l'ancien PIN fonctionne toujours après reset
--
-- FIX :
--   reinitialiser_pin → écrire dans la colonne `gestionnaires` séparée
--   modifier_pin      → idem
--   PIN stocké en clair (compatible avec verifier_gestionnaire qui fait @> jsonb_build_object)
--
-- NOTE SUR LE HASH :
--   verifier_gestionnaire fait : gestionnaires @> jsonb_build_object('nom', p_nom, 'pin', p_pin)
--   → Il compare le PIN tel quel (l'app envoie le PIN en clair, la DB cherche en clair)
--   → On stocke donc le PIN EN CLAIR dans la colonne gestionnaires
--   → C'est le comportement actuel (0103 en clair) qu'on doit respecter
-- ═══════════════════════════════════════════════════════════════════════════════


-- ─────────────────────────────────────────────────────────────────────────────
-- F3 (CORRIGÉE v3) : reinitialiser_pin
--    Écrit le nouveau PIN dans la colonne `gestionnaires` séparée (pas dans data)
--    PIN stocké en clair pour compatibilité avec verifier_gestionnaire
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
    v_gests         JSONB;
    v_idx           INT     := NULL;
    v_pin_interdit  BOOL    := FALSE;
    v_recent_reset  BOOLEAN;
    v_found         BOOLEAN := FALSE;
    v_i             INT;
    v_gest          JSONB;
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
        RETURN jsonb_build_object(
            'ok',     FALSE,
            'erreur', 'Ce PIN est trop simple. Choisissez un PIN plus sécurisé.'
        );
    END IF;

    -- ── 4. Lire la colonne `gestionnaires` séparée ───────────────────────────
    SELECT gestionnaires INTO v_gests
    FROM   public.tontines
    WHERE  code = p_code_tontine;

    IF v_gests IS NULL OR jsonb_typeof(v_gests) <> 'array' OR jsonb_array_length(v_gests) = 0 THEN
        RETURN jsonb_build_object('ok', FALSE, 'erreur', 'Gestionnaire introuvable (colonne vide).');
    END IF;

    -- ── 5. Trouver l'index du gestionnaire (insensible à la casse) ───────────
    FOR v_i IN 0 .. jsonb_array_length(v_gests) - 1 LOOP
        v_gest := v_gests -> v_i;
        IF jsonb_typeof(v_gest) = 'object' THEN
            IF LOWER(TRIM(COALESCE(v_gest->>'nom', ''))) = LOWER(p_nom) THEN
                v_idx   := v_i;
                v_found := TRUE;
                EXIT;
            END IF;
        END IF;
    END LOOP;

    IF NOT v_found THEN
        RETURN jsonb_build_object('ok', FALSE, 'erreur', 'Gestionnaire "' || p_nom || '" introuvable dans cette tontine.');
    END IF;

    -- ── 6. Écrire le nouveau PIN EN CLAIR dans la colonne `gestionnaires` ───
    --      (verifier_gestionnaire compare pin en clair avec @> jsonb_build_object)
    v_gests := jsonb_set(v_gests, ARRAY[v_idx::TEXT, 'pin'], to_jsonb(p_nouveau_pin));

    UPDATE public.tontines
    SET    gestionnaires = v_gests,
           updated_at    = NOW()
    WHERE  code = p_code_tontine;

    -- ── 7. Audit ─────────────────────────────────────────────────────────────
    INSERT INTO public.audit_securite
        (tontine_code, gest_nom, action, description, resultat)
    VALUES (
        p_code_tontine, p_nom,
        'pin_reset',
        'PIN réinitialisé via email — stocké dans colonne gestionnaires.',
        'succes'
    );

    RETURN jsonb_build_object('ok', TRUE, 'message', 'PIN réinitialisé avec succès.');

EXCEPTION WHEN OTHERS THEN
    RAISE LOG '[reinitialiser_pin_v3] Erreur : %', SQLERRM;
    RETURN jsonb_build_object(
        'ok',     FALSE,
        'erreur', 'Erreur serveur : ' || SQLERRM
    );
END;
$$;

GRANT EXECUTE ON FUNCTION public.reinitialiser_pin(TEXT, TEXT, TEXT) TO anon, authenticated;


-- ─────────────────────────────────────────────────────────────────────────────
-- F4 (CORRIGÉE v3) : modifier_pin
--    Lit ET écrit dans la colonne `gestionnaires` séparée (pas dans data)
--    PIN stocké en clair pour compatibilité avec verifier_gestionnaire
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
    v_gests        JSONB;
    v_gest         JSONB;
    v_idx          INT     := NULL;
    v_pin_stocke   TEXT;
    v_ancien_hash  TEXT;
    v_found        BOOLEAN := FALSE;
    v_i            INT;
BEGIN
    p_code        := UPPER(TRIM(p_code));
    p_nom         := TRIM(p_nom);
    p_ancien_pin  := TRIM(p_ancien_pin);
    p_nouveau_pin := TRIM(p_nouveau_pin);

    -- ── 1. Lire la colonne `gestionnaires` séparée ───────────────────────────
    SELECT gestionnaires INTO v_gests
    FROM   public.tontines
    WHERE  code = p_code AND deleted_at IS NULL;

    IF v_gests IS NULL OR jsonb_typeof(v_gests) <> 'array' OR jsonb_array_length(v_gests) = 0 THEN
        RETURN jsonb_build_object('ok', FALSE, 'erreur', 'Tontine introuvable ou aucun gestionnaire.');
    END IF;

    -- ── 2. Trouver le gestionnaire et son PIN ────────────────────────────────
    FOR v_i IN 0 .. jsonb_array_length(v_gests) - 1 LOOP
        v_gest := v_gests -> v_i;
        IF jsonb_typeof(v_gest) = 'object' THEN
            IF LOWER(TRIM(COALESCE(v_gest->>'nom', ''))) = LOWER(p_nom) THEN
                v_idx    := v_i;
                v_found  := TRUE;
                EXIT;
            END IF;
        END IF;
    END LOOP;

    IF NOT v_found THEN
        RETURN jsonb_build_object('ok', FALSE, 'erreur', 'Gestionnaire introuvable.');
    END IF;

    -- ── 3. Vérifier l'ancien PIN ─────────────────────────────────────────────
    --      Accepte : PIN en clair (cas normal) OU PIN hashé SHA-256 (anciennes versions)
    v_pin_stocke := (v_gests -> v_idx)->>'pin';

    -- Calculer le hash de l'ancien PIN saisi (avec fallback)
    BEGIN
        v_ancien_hash := ENCODE(DIGEST(p_ancien_pin, 'sha256'), 'hex');
    EXCEPTION WHEN undefined_function THEN
        v_ancien_hash := encode(sha256(p_ancien_pin::bytea), 'hex');
    END;

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

    -- ── 5. Écrire le nouveau PIN EN CLAIR dans la colonne `gestionnaires` ───
    v_gests := jsonb_set(v_gests, ARRAY[v_idx::TEXT, 'pin'], to_jsonb(p_nouveau_pin));

    UPDATE public.tontines
    SET    gestionnaires = v_gests,
           updated_at    = NOW()
    WHERE  code = p_code;

    -- ── 6. Audit ─────────────────────────────────────────────────────────────
    INSERT INTO public.audit_securite
        (tontine_code, gest_nom, action, description, resultat)
    VALUES (
        p_code, p_nom,
        'pin_change',
        'PIN modifié depuis session active — colonne gestionnaires mise à jour.',
        'succes'
    );

    RETURN jsonb_build_object('ok', TRUE, 'message', 'PIN modifié avec succès.');

EXCEPTION WHEN OTHERS THEN
    RAISE LOG '[modifier_pin_v3] Erreur : %', SQLERRM;
    RETURN jsonb_build_object(
        'ok',     FALSE,
        'erreur', 'Erreur serveur : ' || SQLERRM
    );
END;
$$;

GRANT EXECUTE ON FUNCTION public.modifier_pin(TEXT, TEXT, TEXT, TEXT) TO anon, authenticated;


-- ═══════════════════════════════════════════════════════════════════════════════
-- Fin du fix v3 — Résumé :
--   ✅ reinitialiser_pin : lit+écrit colonne `gestionnaires` séparée, PIN en clair
--   ✅ modifier_pin      : lit+écrit colonne `gestionnaires` séparée, PIN en clair
--   ✅ verifier_gestionnaire : inchangé (compare déjà depuis colonne gestionnaires)
-- ═══════════════════════════════════════════════════════════════════════════════
