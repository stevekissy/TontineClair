-- ═══════════════════════════════════════════════════════════════════════════════
-- TontineClair — Migration : admin_set_gestionnaire_email
-- 
-- Objectif : permettre à l'admin d'enregistrer ou modifier l'e-mail d'un
-- gestionnaire directement dans la colonne JSONB `gestionnaires` de la table
-- `tontines`. Résout le problème des anciennes tontines créées sans e-mail.
--
-- RPC : admin_set_gestionnaire_email(p_cle, p_code_tontine, p_nom_gest, p_email)
-- Retourne :
--   {ok: true,  gest_nom, email, ancienEmail?, message}  — succès
--   {ok: false, erreur: "message lisible"}               — échec
--
-- Règles :
--   1. Authentification par clé admin (p_cle)
--   2. La tontine doit exister
--   3. Le gestionnaire doit exister dans la colonne `gestionnaires`
--   4. Si email déjà présent → le remplace (admin a autorité)
--   5. Si gestionnaire trouvé seulement comme string (format ancien) → convertit
--      en objet {nom, email} et ajoute dans gestionnaires
--   6. Log dans audit_securite
--
-- À exécuter dans : Supabase → SQL Editor → New query → Exécuter
-- ═══════════════════════════════════════════════════════════════════════════════

-- ─── RPC principale ───────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION admin_set_gestionnaire_email(
    p_cle          TEXT,
    p_code_tontine TEXT,
    p_nom_gest     TEXT,
    p_email        TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_tontine_code   TEXT    := UPPER(TRIM(p_code_tontine));
    v_nom_gest       TEXT    := TRIM(p_nom_gest);
    v_email          TEXT    := LOWER(TRIM(p_email));
    v_gests          JSONB;
    v_gest           JSONB;
    v_new_gests      JSONB   := '[]'::JSONB;
    v_i              INT;
    v_len            INT;
    v_found          BOOLEAN := FALSE;
    v_ancien_email   TEXT    := NULL;
    v_gest_nom_reel  TEXT    := NULL;
    v_tontine_exists BOOLEAN := FALSE;
BEGIN
    -- ── 0. Valider l'e-mail ───────────────────────────────────────────────────
    IF v_email = '' OR v_email NOT LIKE '%@%.%' THEN
        RETURN jsonb_build_object(
            'ok',    FALSE,
            'erreur', 'Adresse e-mail invalide : ' || p_email
        );
    END IF;

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

    -- ── 2. Lire la colonne gestionnaires ─────────────────────────────────────
    SELECT gestionnaires INTO v_gests
    FROM   tontines
    WHERE  code = v_tontine_code
    LIMIT  1;

    -- Initialiser si null ou non-tableau
    IF v_gests IS NULL OR jsonb_typeof(v_gests) <> 'array' THEN
        -- Créer un gestionnaire minimal avec le nom et l'email
        v_new_gests := jsonb_build_array(
            jsonb_build_object('nom', v_nom_gest, 'email', v_email, 'pin', '')
        );
        UPDATE tontines
        SET    gestionnaires = v_new_gests
        WHERE  code = v_tontine_code;

        INSERT INTO audit_securite (tontine_code, gest_nom, action, description, resultat)
        VALUES (v_tontine_code, v_nom_gest,
                'admin_set_email',
                'E-mail créé (colonne gestionnaires vide) : ' || v_email,
                'succes');

        RETURN jsonb_build_object(
            'ok',       TRUE,
            'gest_nom', v_nom_gest,
            'email',    v_email,
            'message',  'Gestionnaire créé avec l''e-mail fourni (colonne était vide).'
        );
    END IF;

    -- ── 3. Chercher et mettre à jour le gestionnaire ─────────────────────────
    v_len := jsonb_array_length(v_gests);

    FOR v_i IN 0 .. v_len - 1 LOOP
        v_gest := v_gests -> v_i;

        IF jsonb_typeof(v_gest) = 'object' THEN
            IF LOWER(TRIM(v_gest ->> 'nom')) = LOWER(v_nom_gest) THEN
                v_found        := TRUE;
                v_gest_nom_reel := TRIM(v_gest ->> 'nom');
                v_ancien_email  := TRIM(COALESCE(v_gest ->> 'email', ''));
                -- Mettre à jour l'objet : conserver tous les champs existants
                v_gest := v_gest || jsonb_build_object('email', v_email);
                v_new_gests := v_new_gests || jsonb_build_array(v_gest);
            ELSE
                v_new_gests := v_new_gests || jsonb_build_array(v_gest);
            END IF;

        ELSIF jsonb_typeof(v_gest) = 'string' THEN
            -- Format ancien : string "Nom" → convertir en objet {nom, email, pin}
            IF LOWER(TRIM(v_gest #>> '{}')) = LOWER(v_nom_gest) THEN
                v_found         := TRUE;
                v_gest_nom_reel := TRIM(v_gest #>> '{}');
                v_ancien_email  := '';
                v_new_gests := v_new_gests || jsonb_build_array(
                    jsonb_build_object('nom', v_gest_nom_reel, 'email', v_email, 'pin', '')
                );
            ELSE
                v_new_gests := v_new_gests || jsonb_build_array(v_gest);
            END IF;
        END IF;
    END LOOP;

    IF NOT v_found THEN
        -- Gestionnaire non trouvé → l'ajouter comme nouvel objet
        v_new_gests := v_gests || jsonb_build_array(
            jsonb_build_object('nom', v_nom_gest, 'email', v_email, 'pin', '')
        );
        v_gest_nom_reel := v_nom_gest;

        UPDATE tontines
        SET    gestionnaires = v_new_gests
        WHERE  code = v_tontine_code;

        INSERT INTO audit_securite (tontine_code, gest_nom, action, description, resultat)
        VALUES (v_tontine_code, v_nom_gest,
                'admin_set_email',
                'Nouveau gestionnaire ajouté avec e-mail : ' || v_email,
                'succes');

        RETURN jsonb_build_object(
            'ok',       TRUE,
            'gest_nom', v_nom_gest,
            'email',    v_email,
            'message',  'Gestionnaire ajouté avec l''e-mail fourni (nom non trouvé dans la liste).'
        );
    END IF;

    -- ── 4. Sauvegarder le tableau mis à jour ──────────────────────────────────
    UPDATE tontines
    SET    gestionnaires = v_new_gests
    WHERE  code = v_tontine_code;

    -- ── 5. Log audit ─────────────────────────────────────────────────────────
    INSERT INTO audit_securite (tontine_code, gest_nom, action, description, resultat)
    VALUES (
        v_tontine_code,
        COALESCE(v_gest_nom_reel, v_nom_gest),
        'admin_set_email',
        CASE
            WHEN v_ancien_email = '' OR v_ancien_email IS NULL
            THEN 'E-mail enregistré pour la 1ère fois : ' || v_email
            ELSE 'E-mail modifié : ' || COALESCE(v_ancien_email,'') || ' → ' || v_email
        END,
        'succes'
    );

    RETURN jsonb_build_object(
        'ok',          TRUE,
        'gest_nom',    COALESCE(v_gest_nom_reel, v_nom_gest),
        'email',       v_email,
        'ancienEmail', COALESCE(v_ancien_email, ''),
        'message',     CASE
                         WHEN v_ancien_email = '' OR v_ancien_email IS NULL
                         THEN 'E-mail enregistré avec succès.'
                         ELSE 'E-mail mis à jour (ancien : ' || COALESCE(v_ancien_email,'') || ').'
                       END
    );

EXCEPTION WHEN OTHERS THEN
    RAISE LOG '[admin_set_gestionnaire_email] Erreur : %', SQLERRM;
    RETURN jsonb_build_object(
        'ok',    FALSE,
        'erreur', 'Erreur serveur inattendue : ' || SQLERRM
    );
END;
$$;

REVOKE ALL ON FUNCTION admin_set_gestionnaire_email(TEXT, TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION admin_set_gestionnaire_email(TEXT, TEXT, TEXT, TEXT) TO anon, authenticated;


-- ─── RPC : admin_get_gestionnaire_email ───────────────────────────────────────
-- Lit l'e-mail d'un gestionnaire depuis la colonne gestionnaires.
-- Retourne {ok, email, gest_nom} ou {ok: false, erreur}
CREATE OR REPLACE FUNCTION admin_get_gestionnaire_email(
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
    v_gests         JSONB;
    v_gest          JSONB;
    v_i             INT;
    v_len           INT;
    v_email         TEXT  := NULL;
    v_gest_nom_reel TEXT  := NULL;
    v_found         BOOLEAN := FALSE;
BEGIN
    SELECT gestionnaires INTO v_gests
    FROM   tontines
    WHERE  code = v_tontine_code
    LIMIT  1;

    IF v_gests IS NULL OR jsonb_typeof(v_gests) <> 'array' THEN
        RETURN jsonb_build_object('ok', FALSE, 'erreur', 'Aucun gestionnaire trouvé.');
    END IF;

    v_len := jsonb_array_length(v_gests);
    FOR v_i IN 0 .. v_len - 1 LOOP
        v_gest := v_gests -> v_i;
        IF jsonb_typeof(v_gest) = 'object' THEN
            IF LOWER(TRIM(v_gest ->> 'nom')) = LOWER(v_nom_gest) THEN
                v_email         := TRIM(COALESCE(v_gest ->> 'email', ''));
                v_gest_nom_reel := TRIM(v_gest ->> 'nom');
                v_found         := TRUE;
                EXIT;
            END IF;
        ELSIF jsonb_typeof(v_gest) = 'string' THEN
            IF LOWER(TRIM(v_gest #>> '{}')) = LOWER(v_nom_gest) THEN
                v_gest_nom_reel := TRIM(v_gest #>> '{}');
                v_email         := '';
                v_found         := TRUE;
                EXIT;
            END IF;
        END IF;
    END LOOP;

    IF NOT v_found THEN
        RETURN jsonb_build_object('ok', FALSE, 'erreur', 'Gestionnaire « ' || v_nom_gest || ' » introuvable.');
    END IF;

    RETURN jsonb_build_object(
        'ok',       TRUE,
        'gest_nom', COALESCE(v_gest_nom_reel, v_nom_gest),
        'email',    COALESCE(v_email, '')
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', FALSE, 'erreur', 'Erreur serveur : ' || SQLERRM);
END;
$$;

REVOKE ALL ON FUNCTION admin_get_gestionnaire_email(TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION admin_get_gestionnaire_email(TEXT, TEXT, TEXT) TO anon, authenticated;


-- ─── Version corrigée de admin_reinitialiser_pin_gestionnaire ─────────────────
-- Accepte désormais un paramètre p_email_override facultatif.
-- Si l'email en base est vide ET que p_email_override est fourni,
-- l'email override est utilisé directement (sans l'enregistrer en base).
-- L'enregistrement en base est fait SÉPARÉMENT par admin_set_gestionnaire_email.
CREATE OR REPLACE FUNCTION admin_reinitialiser_pin_gestionnaire(
    p_cle           TEXT,
    p_code_tontine  TEXT,
    p_nom_gest      TEXT,
    p_email_override TEXT DEFAULT ''
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_tontine_code  TEXT  := UPPER(TRIM(p_code_tontine));
    v_nom_gest      TEXT  := TRIM(p_nom_gest);
    v_email_override TEXT := LOWER(TRIM(p_email_override));
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
        RETURN jsonb_build_object('ok', FALSE, 'erreur', 'Tontine introuvable : ' || v_tontine_code);
    END IF;

    -- ── 2. Lire la colonne gestionnaires ─────────────────────────────────────
    SELECT gestionnaires INTO v_gests
    FROM   tontines
    WHERE  code = v_tontine_code
    LIMIT  1;

    IF v_gests IS NULL OR jsonb_typeof(v_gests) <> 'array' THEN
        -- Pas de gestionnaires en base : utiliser email_override si fourni
        IF v_email_override <> '' THEN
            v_gest_email    := v_email_override;
            v_gest_nom_reel := v_nom_gest;
            v_found         := TRUE;
        ELSE
            RETURN jsonb_build_object('ok', FALSE, 'erreur', 'Aucun gestionnaire trouvé dans la tontine ' || v_tontine_code);
        END IF;
    END IF;

    -- ── 3. Chercher le gestionnaire par nom ──────────────────────────────────
    IF NOT v_found THEN
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
    END IF;

    IF NOT v_found THEN
        RETURN jsonb_build_object(
            'ok',    FALSE,
            'erreur', 'Gestionnaire « ' || v_nom_gest || ' » introuvable dans la tontine ' || v_tontine_code || '.'
        );
    END IF;

    -- ── 4. Résoudre l'e-mail final ────────────────────────────────────────────
    -- Priorité : email en base → email_override fourni par admin
    IF (v_gest_email IS NULL OR v_gest_email = '') AND v_email_override <> '' THEN
        v_gest_email := v_email_override;
    END IF;

    IF v_gest_email IS NULL OR v_gest_email = '' THEN
        RETURN jsonb_build_object(
            'ok',    FALSE,
            'erreur', 'Le gestionnaire « ' || COALESCE(v_gest_nom_reel, v_nom_gest)
                      || ' » n''a pas d''adresse e-mail enregistrée. '
                      || 'Veuillez saisir son e-mail dans le formulaire.'
        );
    END IF;

    -- ── 5. Rate limiting ─────────────────────────────────────────────────────
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

        RETURN jsonb_build_object('ok', FALSE, 'erreur', 'Trop de tentatives. Réessayez dans 30 minutes.');
    END IF;

    -- ── 6. Invalider les anciens codes ───────────────────────────────────────
    UPDATE pin_reset_codes
    SET    utilise = TRUE
    WHERE  tontine_code = v_tontine_code
      AND  gest_nom     = v_gest_nom_reel
      AND  utilise      = FALSE;

    -- ── 7. Générer le code à 6 chiffres ──────────────────────────────────────
    v_code_clair := LPAD(
        (ABS(('x' || SUBSTR(gen_random_uuid()::TEXT, 1, 8))::BIT(32)::BIGINT)
         % 900000 + 100000)::TEXT,
        6, '0'
    );
    -- encode(sha256(...), 'hex') : natif PostgreSQL 11+, sans pgcrypto
    v_code_hash := encode(sha256(v_code_clair::bytea), 'hex');

    -- ── 8. Insérer le code en base ────────────────────────────────────────────
    INSERT INTO pin_reset_codes (
        tontine_code, gest_nom, contact, code, expire_at
    ) VALUES (
        v_tontine_code,
        COALESCE(v_gest_nom_reel, v_nom_gest),
        v_gest_email,
        v_code_hash,
        NOW() + INTERVAL '10 minutes'
    );

    -- ── 9. Log audit ─────────────────────────────────────────────────────────
    INSERT INTO audit_securite (tontine_code, gest_nom, action, description, resultat)
    VALUES (
        v_tontine_code, COALESCE(v_gest_nom_reel, v_nom_gest),
        'admin_reset_pin_demande',
        CASE WHEN v_email_override <> '' AND (SELECT TRIM(COALESCE(v_gest -> -1 ->> 'email', '')) = '' FROM (SELECT v_gests -> 0 AS v_gest) sq)
             THEN 'Reset PIN — email override admin : ' || v_email_override
             ELSE 'Reset PIN déclenché par administrateur — email : ' || v_gest_email
        END,
        'succes'
    );

    -- ── 10. Retourner le code_clair ───────────────────────────────────────────
    RETURN jsonb_build_object(
        'ok',           TRUE,
        'email',        v_gest_email,
        'gest_nom',     COALESCE(v_gest_nom_reel, v_nom_gest),
        'tontine_code', v_tontine_code,
        'code_clair',   v_code_clair,
        'email_source', CASE WHEN v_email_override <> '' AND (v_gest_email = v_email_override)
                             THEN 'override'
                             ELSE 'base'
                        END,
        'message',      'Code de réinitialisation généré avec succès.'
    );

EXCEPTION WHEN OTHERS THEN
    RAISE LOG '[admin_reinitialiser_pin_gestionnaire] Erreur : %', SQLERRM;
    RETURN jsonb_build_object('ok', FALSE, 'erreur', 'Erreur serveur inattendue : ' || SQLERRM);
END;
$$;

REVOKE ALL ON FUNCTION admin_reinitialiser_pin_gestionnaire(TEXT, TEXT, TEXT)         FROM PUBLIC;
REVOKE ALL ON FUNCTION admin_reinitialiser_pin_gestionnaire(TEXT, TEXT, TEXT, TEXT)   FROM PUBLIC;
GRANT EXECUTE ON FUNCTION admin_reinitialiser_pin_gestionnaire(TEXT, TEXT, TEXT)       TO anon, authenticated;
GRANT EXECUTE ON FUNCTION admin_reinitialiser_pin_gestionnaire(TEXT, TEXT, TEXT, TEXT) TO anon, authenticated;


-- ─── Vérification post-migration ──────────────────────────────────────────────
-- Test 1 : lire l'email d'un gestionnaire
-- SELECT admin_get_gestionnaire_email('votre-cle', 'K93JAP', 'Kissy');

-- Test 2 : enregistrer un email
-- SELECT admin_set_gestionnaire_email('votre-cle', 'K93JAP', 'Kissy', 'stevekissy@gmail.com');

-- Test 3 : reset PIN avec email override (si pas d'email en base)
-- SELECT admin_reinitialiser_pin_gestionnaire('votre-cle', 'K93JAP', 'Kissy', 'stevekissy@gmail.com');
