CREATE OR REPLACE FUNCTION demander_reset_pin_v3(
    p_code    TEXT,
    p_nom     TEXT,
    p_contact TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_tontine_code   TEXT    := UPPER(TRIM(p_code));
    v_nom            TEXT    := TRIM(p_nom);
    v_contact        TEXT    := LOWER(TRIM(p_contact));
    v_gest_email     TEXT    := NULL;
    v_gest_nom_reel  TEXT    := NULL;
    v_email_enreg    TEXT    := NULL;  -- email enregistré pour ce gestionnaire
    v_email_present  BOOLEAN := FALSE; -- TRUE si au moins 1 email non-vide existe
    v_nb_recents     INT     := 0;
    v_code_clair     TEXT;
    v_code_hash      TEXT;
    v_tontine_row    tontines%ROWTYPE;
    v_gests          JSONB;
    v_gest           JSONB;
    v_i              INT;
    v_match          BOOLEAN := FALSE;
BEGIN
    -- ── 1. Récupérer la tontine ──────────────────────────────────────────────
    SELECT * INTO v_tontine_row
    FROM   tontines
    WHERE  code = v_tontine_code
    LIMIT  1;

    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'ok',      TRUE,
            'envoyer', FALSE,
            'message', 'Si ce contact est lié à votre compte, un code vous a été envoyé.'
        );
    END IF;

    -- ── 2. Lire la colonne gestionnaires ────────────────────────────────────
    v_gests := v_tontine_row.gestionnaires;

    -- Fallback si colonne vide → lire data->'gestionnaires'
    IF v_gests IS NULL OR jsonb_typeof(v_gests) <> 'array' OR jsonb_array_length(v_gests) = 0 THEN
        v_gests := v_tontine_row.data -> 'gestionnaires';
    END IF;

    -- ── 3. Parcourir les gestionnaires ───────────────────────────────────────
    IF v_gests IS NOT NULL AND jsonb_typeof(v_gests) = 'array' THEN
        FOR v_i IN 0 .. jsonb_array_length(v_gests) - 1 LOOP
            v_gest := v_gests -> v_i;

            IF jsonb_typeof(v_gest) = 'object' THEN
                -- Vérifier si cet objet a un email non-vide
                IF COALESCE(TRIM(v_gest ->> 'email'), '') <> '' THEN
                    v_email_present := TRUE;
                END IF;

                -- Chercher par nom (pour identifier le bon gestionnaire)
                IF LOWER(TRIM(COALESCE(v_gest ->> 'nom', ''))) = LOWER(v_nom)
                   OR v_nom = ''
                THEN
                    v_gest_nom_reel := COALESCE(v_gest ->> 'nom', v_nom);
                    v_email_enreg   := COALESCE(TRIM(v_gest ->> 'email'), '');

                    -- Si email enregistré → vérifier correspondance
                    IF v_email_enreg <> '' THEN
                        IF LOWER(v_email_enreg) = v_contact THEN
                            v_gest_email := v_email_enreg;
                            v_match      := TRUE;
                            EXIT;
                        END IF;
                        -- Email enregistré mais ne correspond pas → on note sans EXIT
                        -- (on continue au cas où il y a d'autres gestionnaires)
                    ELSE
                        -- Pas d'email enregistré pour ce gestionnaire → match direct
                        -- On utilise le contact saisi comme adresse de destination
                        v_gest_email := v_contact;
                        v_match      := TRUE;
                        EXIT;
                    END IF;
                END IF;

            ELSIF jsonb_typeof(v_gest) = 'string' THEN
                -- Format ancien (string pure) → pas d'email → match direct
                IF LOWER(TRIM(v_gest #>> '{}')) = LOWER(v_nom) OR v_nom = '' THEN
                    v_gest_nom_reel := TRIM(v_gest #>> '{}');
                    v_gest_email    := v_contact;
                    v_match         := TRUE;
                    EXIT;
                END IF;
            END IF;
        END LOOP;
    END IF;

    -- ── 4. Logique de décision selon présence d'email enregistré ────────────
    --
    -- CAS A : gestionnaire trouvé par nom, avait un email enregistré,
    --         mais le contact saisi ne correspond pas → REFUS EXPLICITE
    --         (seulement si l'email est bien enregistré)
    IF NOT v_match AND v_gest_nom_reel IS NOT NULL AND v_email_enreg <> '' THEN
        INSERT INTO audit_securite (tontine_code, gest_nom, action, description, resultat)
        VALUES (v_tontine_code, v_nom, 'reset_pin_demande',
                'Email incorrect : ' || v_contact || ' (attendu: ' || v_email_enreg || ')', 'echec');

        RETURN jsonb_build_object(
            'ok',     FALSE,
            'erreur', 'Cet email ne correspond pas à cette tontine. '
                      'Utilisez l''email enregistré lors de la création.'
        );
    END IF;

    -- CAS B : gestionnaire non trouvé du tout → réponse neutre (anti-énumération)
    IF NOT v_match THEN
        RETURN jsonb_build_object(
            'ok',      TRUE,
            'envoyer', FALSE,
            'message', 'Si ce contact est lié à votre compte, un code vous a été envoyé.'
        );
    END IF;

    -- ── 5. Rate limiting ─────────────────────────────────────────────────────
    SELECT COUNT(*) INTO v_nb_recents
    FROM   pin_reset_codes
    WHERE  tontine_code = v_tontine_code
      AND  gest_nom     = COALESCE(v_gest_nom_reel, v_nom)
      AND  utilise      = FALSE
      AND  cree_le      > NOW() - INTERVAL '30 minutes';

    IF v_nb_recents >= 3 THEN
        INSERT INTO audit_securite (tontine_code, gest_nom, action, description, resultat)
        VALUES (v_tontine_code, COALESCE(v_gest_nom_reel, v_nom),
                'reset_pin_demande', 'Rate limit dépassé (3 codes / 30 min)', 'echec');

        RETURN jsonb_build_object(
            'ok',     FALSE,
            'erreur', 'Trop de tentatives. Réessayez dans 30 minutes.'
        );
    END IF;

    -- ── 6. Invalider anciens codes ───────────────────────────────────────────
    UPDATE pin_reset_codes
    SET    utilise = TRUE
    WHERE  tontine_code = v_tontine_code
      AND  gest_nom     = COALESCE(v_gest_nom_reel, v_nom)
      AND  utilise      = FALSE;

    -- ── 7. Générer le code à 6 chiffres ──────────────────────────────────────
    v_code_clair := LPAD(
        (ABS(('x' || SUBSTR(gen_random_uuid()::TEXT, 1, 8))::BIT(32)::BIGINT)
         % 900000 + 100000)::TEXT,
        6, '0'
    );

    BEGIN
        v_code_hash := ENCODE(DIGEST(v_code_clair, 'sha256'), 'hex');
    EXCEPTION WHEN undefined_function THEN
        v_code_hash := encode(sha256(v_code_clair::bytea), 'hex');
    END;

    -- ── 8. Insérer le code hashé ─────────────────────────────────────────────
    INSERT INTO pin_reset_codes (
        tontine_code, gest_nom, contact, code, expire_at
    ) VALUES (
        v_tontine_code,
        COALESCE(v_gest_nom_reel, v_nom),
        v_gest_email,
        v_code_hash,
        NOW() + INTERVAL '10 minutes'
    );

    -- ── 9. Log audit ─────────────────────────────────────────────────────────
    INSERT INTO audit_securite (tontine_code, gest_nom, action, description, resultat)
    VALUES (
        v_tontine_code,
        COALESCE(v_gest_nom_reel, v_nom),
        'reset_pin_demande',
        CASE WHEN v_email_enreg <> ''
             THEN 'Code généré — email vérifié (' || v_gest_email || ')'
             ELSE 'Code généré — tontine ancienne, email non enregistré'
        END,
        'succes'
    );

    -- ── 10. Retourner le code en clair ───────────────────────────────────────
    RETURN jsonb_build_object(
        'ok',           TRUE,
        'envoyer',      TRUE,
        'email',        v_gest_email,
        'gest_nom',     COALESCE(v_gest_nom_reel, v_nom),
        'tontine_nom',  COALESCE(v_tontine_row.data ->> 'nom', v_tontine_code),
        'tontine_code', v_tontine_code,
        'code_clair',   v_code_clair,
        'message',      'Code généré avec succès.'
    );

EXCEPTION WHEN OTHERS THEN
    RAISE LOG '[demander_reset_pin_v3] Erreur inattendue : %', SQLERRM;
    RETURN jsonb_build_object(
        'ok',      TRUE,
        'envoyer', FALSE,
        'message', 'Si ce contact est lié à votre compte, un code vous a été envoyé.'
    );
END;
$$;

GRANT EXECUTE ON FUNCTION demander_reset_pin_v3(TEXT, TEXT, TEXT) TO anon, authenticated;
