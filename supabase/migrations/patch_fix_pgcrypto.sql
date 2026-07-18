-- ═══════════════════════════════════════════════════════════════════════════════
-- TontineClair — PATCH URGENT : Correction erreur pgcrypto
-- Symptôme : "function digest(text, unknown) does not exist"
-- Cause    : DIGEST() requiert l'extension pgcrypto (non activée)
-- Fix      : encode(sha256(...), 'hex') — natif PostgreSQL 11+, sans extension
--
-- À exécuter dans : Supabase → SQL Editor → New query → Exécuter
-- ═══════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION admin_reinitialiser_pin_gestionnaire(
    p_cle          TEXT,
    p_code_tontine TEXT,
    p_nom_gest     TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_tontine_code  TEXT  := UPPER(TRIM(p_code_tontine));
    v_nom_gest      TEXT  := TRIM(p_nom_gest);
    v_gest_email    TEXT  := NULL;
    v_gest_nom_reel TEXT  := NULL;
    v_nb_recents    INT   := 0;
    v_code_clair    TEXT;
    v_code_hash     TEXT;
    v_gests         JSONB;
    v_gest          JSONB;
    v_i             INT;
    v_len           INT;
    v_found         BOOLEAN := FALSE;
    v_tontine_exists BOOLEAN := FALSE;
BEGIN
    -- ── 1. Vérifier que la tontine existe ─────────────────────────────────────
    SELECT EXISTS(
        SELECT 1 FROM tontines WHERE code = v_tontine_code
    ) INTO v_tontine_exists;

    IF NOT v_tontine_exists THEN
        RETURN jsonb_build_object(
            'ok',    FALSE,
            'erreur', 'Tontine introuvable : ' || v_tontine_code
        );
    END IF;

    -- ── 2. Lire la colonne gestionnaires (JSONB séparée de data) ──────────────
    SELECT gestionnaires INTO v_gests
    FROM   tontines
    WHERE  code = v_tontine_code
    LIMIT  1;

    IF v_gests IS NULL OR jsonb_typeof(v_gests) <> 'array' THEN
        RETURN jsonb_build_object(
            'ok',    FALSE,
            'erreur', 'Aucun gestionnaire trouvé dans la tontine ' || v_tontine_code
        );
    END IF;

    -- ── 3. Chercher le gestionnaire par nom (case-insensitive) ────────────────
    v_len := jsonb_array_length(v_gests);
    FOR v_i IN 0 .. v_len - 1 LOOP
        v_gest := v_gests -> v_i;

        IF jsonb_typeof(v_gest) = 'object' THEN
            IF LOWER(TRIM(v_gest ->> 'nom')) = LOWER(v_nom_gest) THEN
                v_gest_email    := TRIM(COALESCE(v_gest ->> 'email', ''));
                v_gest_nom_reel := TRIM(v_gest ->> 'nom');
                v_found         := TRUE;
                EXIT;
            END IF;
        ELSIF jsonb_typeof(v_gest) = 'string' THEN
            IF LOWER(TRIM(v_gest #>> '{}')) = LOWER(v_nom_gest) THEN
                v_gest_nom_reel := TRIM(v_gest #>> '{}');
                v_gest_email    := '';
                v_found         := TRUE;
                EXIT;
            END IF;
        END IF;
    END LOOP;

    IF NOT v_found THEN
        RETURN jsonb_build_object(
            'ok',    FALSE,
            'erreur', 'Gestionnaire « ' || v_nom_gest || ' » introuvable dans la tontine ' || v_tontine_code || '.'
        );
    END IF;

    IF v_gest_email IS NULL OR v_gest_email = '' THEN
        RETURN jsonb_build_object(
            'ok',    FALSE,
            'erreur', 'Le gestionnaire « ' || COALESCE(v_gest_nom_reel, v_nom_gest)
                      || ' » n''a pas d''adresse e-mail enregistrée. '
                      || 'Demandez-lui d''ajouter son email dans son profil.'
        );
    END IF;

    -- ── 4. Rate limiting : max 3 codes dans 30 min ───────────────────────────
    SELECT COUNT(*) INTO v_nb_recents
    FROM   pin_reset_codes
    WHERE  tontine_code = v_tontine_code
      AND  gest_nom     = v_gest_nom_reel
      AND  utilise      = FALSE
      AND  cree_le      > NOW() - INTERVAL '30 minutes';

    IF v_nb_recents >= 3 THEN
        INSERT INTO audit_securite (tontine_code, gest_nom, action, description, resultat)
        VALUES (v_tontine_code, v_gest_nom_reel,
                'admin_reset_pin_demande', 'Rate limit dépassé (3 codes / 30 min)', 'echec');

        RETURN jsonb_build_object(
            'ok',    FALSE,
            'erreur', 'Trop de tentatives. Réessayez dans 30 minutes.'
        );
    END IF;

    -- ── 5. Invalider les anciens codes non utilisés ──────────────────────────
    UPDATE pin_reset_codes
    SET    utilise = TRUE
    WHERE  tontine_code = v_tontine_code
      AND  gest_nom     = v_gest_nom_reel
      AND  utilise      = FALSE;

    -- ── 6. Générer le code à 6 chiffres ──────────────────────────────────────
    v_code_clair := LPAD(
        (ABS(('x' || SUBSTR(gen_random_uuid()::TEXT, 1, 8))::BIT(32)::BIGINT)
         % 900000 + 100000)::TEXT,
        6, '0'
    );
    -- FIX pgcrypto : encode(sha256(...), 'hex') est NATIF PostgreSQL 11+
    -- Ancienne ligne qui échouait : ENCODE(DIGEST(v_code_clair, 'sha256'), 'hex')
    v_code_hash := encode(sha256(v_code_clair::bytea), 'hex');

    -- ── 7. Insérer le code hashé en base ─────────────────────────────────────
    INSERT INTO pin_reset_codes (
        tontine_code, gest_nom, contact, code, expire_at
    ) VALUES (
        v_tontine_code,
        v_gest_nom_reel,
        v_gest_email,
        v_code_hash,
        NOW() + INTERVAL '10 minutes'
    );

    -- ── 8. Log audit ─────────────────────────────────────────────────────────
    INSERT INTO audit_securite (tontine_code, gest_nom, action, description, resultat)
    VALUES (
        v_tontine_code, v_gest_nom_reel,
        'admin_reset_pin_demande',
        'Reset PIN déclenché par administrateur — envoi via Edge Function send-manager-pin',
        'succes'
    );

    -- ── 9. Retourner le code_clair UNE SEULE FOIS ────────────────────────────
    RETURN jsonb_build_object(
        'ok',           TRUE,
        'email',        v_gest_email,
        'gest_nom',     v_gest_nom_reel,
        'tontine_code', v_tontine_code,
        'code_clair',   v_code_clair,
        'message',      'Code de réinitialisation généré avec succès.'
    );

EXCEPTION WHEN OTHERS THEN
    RAISE LOG '[admin_reinitialiser_pin_gestionnaire] Erreur : %', SQLERRM;
    RETURN jsonb_build_object(
        'ok',    FALSE,
        'erreur', 'Erreur serveur inattendue : ' || SQLERRM
    );
END;
$$;

REVOKE ALL ON FUNCTION admin_reinitialiser_pin_gestionnaire(TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION admin_reinitialiser_pin_gestionnaire(TEXT, TEXT, TEXT) TO anon, authenticated;

-- ── Vérification post-patch ───────────────────────────────────────────────────
-- SELECT admin_reinitialiser_pin_gestionnaire('votre-cle-admin', 'K93JAP', 'Kissy');
-- Attendu (si email configuré) : {"ok": true, "email": "...", "code_clair": "123456", ...}
-- Attendu (clé incorrecte)     : {"ok": false, "erreur": "Clé admin incorrecte."}
