-- ═══════════════════════════════════════════════════════════════════════════════
-- TontineClair — CORRECTIF URGENT : demander_reset_pin_v2
--
-- PROBLÈME IDENTIFIÉ :
--   La version précédente lisait `data -> 'gestionnaires'` dans le champ JSONB
--   `data` de la table `tontines`. Ce champ contient un tableau de STRINGS
--   (ex: ["ARNAUD le President"]) sans email → impossible de trouver un match.
--
-- CORRECTION :
--   Lire la colonne SÉPARÉE `gestionnaires` (type JSONB) qui contient des objets
--   {nom, email, pin} enregistrés par admin_set_gestionnaire_email.
--   Fallback : si la colonne est vide, lire data->'gestionnaires' (strings) pour
--   compatibilité avec les anciennes tontines.
--
-- VÉRIFICATION PRÉALABLE (requête 3 du diagnostic) a confirmé :
--   code=M3JQ3U → gestionnaires_column = [{"nom":"ARNAUD le President", ...}]
--                  nb_gests_column = 1  ← la colonne existe et a des données
--
-- À exécuter : Supabase → SQL Editor → New query → Run (sans LIMIT)
-- ═══════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION demander_reset_pin_v2(
    p_code    TEXT,    -- code de la tontine
    p_nom     TEXT,    -- nom du gestionnaire (affiché dans l'email)
    p_contact TEXT     -- email ou téléphone saisi par l'utilisateur
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_tontine_code  TEXT    := UPPER(TRIM(p_code));
    v_nom           TEXT    := TRIM(p_nom);
    v_contact       TEXT    := LOWER(TRIM(p_contact));
    v_gest_email    TEXT    := NULL;
    v_gest_nom_reel TEXT    := NULL;
    v_nb_recents    INT     := 0;
    v_code_clair    TEXT;
    v_code_hash     TEXT;
    -- ↓ CORRECTION : utiliser v_tontine_row (SELECT *) au lieu de v_tontine_data (SELECT data)
    v_tontine_row   tontines%ROWTYPE;
    v_gests         JSONB;
    v_gest          JSONB;
    v_i             INT;
    v_match         BOOLEAN := FALSE;
BEGIN
    -- ── 1. Récupérer la LIGNE COMPLÈTE de la tontine ─────────────────────────
    -- CORRECTION : SELECT * au lieu de SELECT data
    SELECT * INTO v_tontine_row
    FROM   tontines
    WHERE  code = v_tontine_code
    LIMIT  1;

    IF NOT FOUND THEN
        -- Anti-énumération : ne pas révéler si la tontine existe
        RETURN jsonb_build_object(
            'ok',      TRUE,
            'envoyer', FALSE,
            'message', 'Si ce contact est lié à votre compte, un code vous a été envoyé.'
        );
    END IF;

    -- ── 2. Lire la colonne `gestionnaires` (objets avec email) ───────────────
    -- CORRECTION : lire v_tontine_row.gestionnaires (colonne séparée)
    --              au lieu de v_tontine_data -> 'gestionnaires' (strings dans data)
    v_gests := v_tontine_row.gestionnaires;

    -- Fallback : si la colonne est vide ou n'est pas un tableau, tenter data->'gestionnaires'
    IF v_gests IS NULL OR jsonb_typeof(v_gests) <> 'array' OR jsonb_array_length(v_gests) = 0 THEN
        v_gests := v_tontine_row.data -> 'gestionnaires';
    END IF;

    -- ── 3. Chercher le gestionnaire par email ou téléphone ───────────────────
    IF v_gests IS NOT NULL AND jsonb_typeof(v_gests) = 'array' THEN
        FOR v_i IN 0 .. jsonb_array_length(v_gests) - 1 LOOP
            v_gest := v_gests -> v_i;

            -- Ignorer les éléments de type string (format ancien sans email)
            IF jsonb_typeof(v_gest) <> 'object' THEN
                CONTINUE;
            END IF;

            -- Comparer email
            IF LOWER(COALESCE(v_gest ->> 'email', '')) = v_contact
               AND v_contact <> ''
            THEN
                v_gest_email    := v_gest ->> 'email';
                v_gest_nom_reel := v_gest ->> 'nom';
                v_match         := TRUE;
                EXIT;
            END IF;

            -- Comparer téléphone (nettoyé des espaces/tirets)
            IF (v_gest ->> 'telephone') IS NOT NULL
               AND (v_gest ->> 'telephone') <> ''
               AND REGEXP_REPLACE(v_gest ->> 'telephone', '[^0-9+]', '', 'g')
                   = REGEXP_REPLACE(v_contact, '[^0-9+]', '', 'g')
            THEN
                v_gest_email    := v_gest ->> 'email';
                v_gest_nom_reel := v_gest ->> 'nom';
                v_match         := TRUE;
                EXIT;
            END IF;
        END LOOP;
    END IF;

    -- Deuxième passe : chercher par nom si le contact n'a pas matché directement
    IF NOT v_match AND v_gests IS NOT NULL AND jsonb_typeof(v_gests) = 'array' THEN
        FOR v_i IN 0 .. jsonb_array_length(v_gests) - 1 LOOP
            v_gest := v_gests -> v_i;

            IF jsonb_typeof(v_gest) <> 'object' THEN
                CONTINUE;
            END IF;

            IF LOWER(TRIM(COALESCE(v_gest ->> 'nom', ''))) = LOWER(v_nom) THEN
                -- Vérifier que le contact correspond (email ou téléphone)
                IF LOWER(COALESCE(v_gest ->> 'email', '')) = v_contact
                   AND v_contact <> ''
                THEN
                    v_gest_email    := v_gest ->> 'email';
                    v_gest_nom_reel := v_gest ->> 'nom';
                    v_match         := TRUE;
                    EXIT;
                END IF;

                IF (v_gest ->> 'telephone') IS NOT NULL
                   AND (v_gest ->> 'telephone') <> ''
                   AND REGEXP_REPLACE(v_gest ->> 'telephone', '[^0-9+]', '', 'g')
                       = REGEXP_REPLACE(v_contact, '[^0-9+]', '', 'g')
                THEN
                    v_gest_email    := v_gest ->> 'email';
                    v_gest_nom_reel := v_gest ->> 'nom';
                    v_match         := TRUE;
                    EXIT;
                END IF;
            END IF;
        END LOOP;
    END IF;

    -- Anti-énumération : si contact inconnu → réponse neutre
    IF NOT v_match OR v_gest_email IS NULL OR v_gest_email = '' THEN
        RETURN jsonb_build_object(
            'ok',      TRUE,
            'envoyer', FALSE,
            'message', 'Si ce contact est lié à votre compte, un code vous a été envoyé.'
        );
    END IF;

    -- ── 4. Rate limiting : max 3 codes actifs dans 30 min ────────────────────
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

    -- ── 5. Invalider les anciens codes non utilisés ───────────────────────────
    UPDATE pin_reset_codes
    SET    utilise = TRUE
    WHERE  tontine_code = v_tontine_code
      AND  gest_nom     = COALESCE(v_gest_nom_reel, v_nom)
      AND  utilise      = FALSE;

    -- ── 6. Générer le code à 6 chiffres ──────────────────────────────────────
    v_code_clair := LPAD(
        (ABS(('x' || SUBSTR(gen_random_uuid()::TEXT, 1, 8))::BIT(32)::BIGINT)
         % 900000 + 100000)::TEXT,
        6, '0'
    );

    -- Hachage SHA-256 — natif PostgreSQL 11+ via pgcrypto ou sha256()
    BEGIN
        -- Essayer la syntaxe pgcrypto (ENCODE/DIGEST)
        v_code_hash := ENCODE(DIGEST(v_code_clair, 'sha256'), 'hex');
    EXCEPTION WHEN undefined_function THEN
        -- Fallback : sha256() natif PostgreSQL 14+
        v_code_hash := encode(sha256(v_code_clair::bytea), 'hex');
    END;

    -- ── 7. Insérer le code hashé en base ─────────────────────────────────────
    INSERT INTO pin_reset_codes (
        tontine_code, gest_nom, contact, code, expire_at
    ) VALUES (
        v_tontine_code,
        COALESCE(v_gest_nom_reel, v_nom),
        v_gest_email,
        v_code_hash,
        NOW() + INTERVAL '10 minutes'
    );

    -- ── 8. Log audit ─────────────────────────────────────────────────────────
    INSERT INTO audit_securite (tontine_code, gest_nom, action, description, resultat)
    VALUES (
        v_tontine_code,
        COALESCE(v_gest_nom_reel, v_nom),
        'reset_pin_demande',
        'Code de réinitialisation généré — envoi email via Edge Function',
        'succes'
    );

    -- ── 9. Retourner le code_clair UNE SEULE FOIS ────────────────────────────
    -- Flutter appellera immédiatement send-manager-pin avec ce code
    -- Il n'est JAMAIS stocké en clair, jamais loggué
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
    RAISE LOG '[demander_reset_pin_v2] Erreur inattendue : %', SQLERRM;
    RETURN jsonb_build_object(
        'ok',      TRUE,
        'envoyer', FALSE,
        'message', 'Si ce contact est lié à votre compte, un code vous a été envoyé.'
    );
END;
$$;

GRANT EXECUTE ON FUNCTION demander_reset_pin_v2(TEXT, TEXT, TEXT) TO anon, authenticated;


-- ═══════════════════════════════════════════════════════════════════════════════
-- DÉPLOIEMENT DE admin_set_gestionnaire_email (si absente en base)
-- ═══════════════════════════════════════════════════════════════════════════════
-- La fonction n'existait pas en base (erreur 42883 confirmée).
-- Ce bloc la crée. Si elle existe déjà, OR REPLACE la met simplement à jour.
-- ═══════════════════════════════════════════════════════════════════════════════

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
    -- Vérification clé admin
    v_cle_admin      TEXT;
BEGIN
    -- ── 0. Vérifier la clé admin ──────────────────────────────────────────────
    -- La clé est dans parametres_globaux.cle_admin (colonne directe TEXT)
    SELECT cle_admin INTO v_cle_admin
    FROM   parametres_globaux
    LIMIT  1;

    IF v_cle_admin IS NULL OR p_cle <> v_cle_admin THEN
        RETURN jsonb_build_object('ok', FALSE, 'erreur', 'Clé admin invalide.');
    END IF;

    -- ── 1. Valider l'e-mail ───────────────────────────────────────────────────
    IF v_email = '' OR v_email NOT LIKE '%@%.%' THEN
        RETURN jsonb_build_object('ok', FALSE, 'erreur', 'Adresse e-mail invalide : ' || p_email);
    END IF;

    -- ── 2. Vérifier que la tontine existe ─────────────────────────────────────
    SELECT EXISTS(SELECT 1 FROM tontines WHERE code = v_tontine_code)
    INTO   v_tontine_exists;

    IF NOT v_tontine_exists THEN
        RETURN jsonb_build_object('ok', FALSE, 'erreur', 'Tontine introuvable : ' || v_tontine_code);
    END IF;

    -- ── 3. Lire la colonne gestionnaires ──────────────────────────────────────
    SELECT gestionnaires INTO v_gests
    FROM   tontines
    WHERE  code = v_tontine_code
    LIMIT  1;

    -- Initialiser si null ou non-tableau
    IF v_gests IS NULL OR jsonb_typeof(v_gests) <> 'array' THEN
        v_new_gests := jsonb_build_array(
            jsonb_build_object('nom', v_nom_gest, 'email', v_email, 'pin', '')
        );
        UPDATE tontines SET gestionnaires = v_new_gests WHERE code = v_tontine_code;

        INSERT INTO audit_securite (tontine_code, gest_nom, action, description, resultat)
        VALUES (v_tontine_code, v_nom_gest, 'admin_set_email',
                'E-mail créé (colonne gestionnaires vide) : ' || v_email, 'succes');

        RETURN jsonb_build_object(
            'ok',      TRUE,
            'gest_nom', v_nom_gest,
            'email',    v_email,
            'message',  'Gestionnaire créé avec l''e-mail fourni (colonne était vide).'
        );
    END IF;

    -- ── 4. Chercher et mettre à jour le gestionnaire ──────────────────────────
    v_len := jsonb_array_length(v_gests);

    FOR v_i IN 0 .. v_len - 1 LOOP
        v_gest := v_gests -> v_i;

        IF jsonb_typeof(v_gest) = 'object' THEN
            IF LOWER(TRIM(COALESCE(v_gest ->> 'nom', ''))) = LOWER(v_nom_gest) THEN
                v_found        := TRUE;
                v_gest_nom_reel := TRIM(v_gest ->> 'nom');
                v_ancien_email  := TRIM(COALESCE(v_gest ->> 'email', ''));
                -- Mettre à jour l'email en conservant les autres champs (pin, etc.)
                v_gest      := v_gest || jsonb_build_object('email', v_email);
                v_new_gests := v_new_gests || jsonb_build_array(v_gest);
            ELSE
                v_new_gests := v_new_gests || jsonb_build_array(v_gest);
            END IF;

        ELSIF jsonb_typeof(v_gest) = 'string' THEN
            -- Format ancien : "Nom Prénom" → convertir en objet {nom, email, pin}
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

        UPDATE tontines SET gestionnaires = v_new_gests WHERE code = v_tontine_code;

        INSERT INTO audit_securite (tontine_code, gest_nom, action, description, resultat)
        VALUES (v_tontine_code, v_nom_gest, 'admin_set_email',
                'Nouveau gestionnaire ajouté avec e-mail : ' || v_email, 'succes');

        RETURN jsonb_build_object(
            'ok',      TRUE,
            'gest_nom', v_nom_gest,
            'email',    v_email,
            'message',  'Gestionnaire ajouté avec l''e-mail fourni (nom non trouvé dans la liste).'
        );
    END IF;

    -- ── 5. Sauvegarder le tableau mis à jour ──────────────────────────────────
    UPDATE tontines SET gestionnaires = v_new_gests WHERE code = v_tontine_code;

    -- ── 6. Log audit ─────────────────────────────────────────────────────────
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
    RETURN jsonb_build_object('ok', FALSE, 'erreur', 'Erreur serveur inattendue : ' || SQLERRM);
END;
$$;

REVOKE ALL ON FUNCTION admin_set_gestionnaire_email(TEXT, TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION admin_set_gestionnaire_email(TEXT, TEXT, TEXT, TEXT) TO anon, authenticated;


-- ═══════════════════════════════════════════════════════════════════════════════
-- VÉRIFICATION POST-DÉPLOIEMENT
-- Exécuter ces requêtes UNE PAR UNE dans des onglets séparés après le déploiement
-- ═══════════════════════════════════════════════════════════════════════════════

-- Test 1 : Lire la clé admin depuis parametres_globaux
-- SELECT cle_admin FROM parametres_globaux LIMIT 1;

-- Test 2 : Vérifier la structure de la colonne gestionnaires pour M3JQ3U
-- SELECT code,
--        gestionnaires,
--        jsonb_array_length(COALESCE(gestionnaires,'[]')) AS nb_gests
-- FROM tontines WHERE code = 'M3JQ3U';

-- Test 3 : Tester demander_reset_pin_v2 (doit retourner envoyer:true si email enregistré)
-- SELECT (demander_reset_pin_v2('M3JQ3U', 'ARNAUD le President', 'assoa90@gmail.com'))::text;
