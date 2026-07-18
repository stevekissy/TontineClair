-- ═══════════════════════════════════════════════════════════════════════════════
-- TontineClair — Migration : PIN Reset v2 avec Edge Function send-manager-pin
-- 
-- Modifications vs v1 :
--   • demander_reset_pin_v2() : retourne {ok, email, code_clair, gest_nom,
--                                          tontine_code, envoyer, message, erreur}
--     → Flutter reçoit l'email du gestionnaire + le code_clair pour appeler
--       l'Edge Function send-manager-pin directement
--   • La RPC reste SECURITY DEFINER : le code_clair n'est JAMAIS en base
--   • Même anti-énumération : ok:true même si contact inconnu
--   • Rate limiting conservé (3 codes max / 30 min)
--   • Expiration 10 min, hash SHA-256, max 5 tentatives
--
-- À exécuter dans Supabase → SQL Editor
-- ═══════════════════════════════════════════════════════════════════════════════

-- ─── S'assurer que l'extension pgcrypto est activée ────────────────────────────
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ─── Table pin_reset_codes (créée en v1, on s'assure qu'elle existe) ──────────
CREATE TABLE IF NOT EXISTS pin_reset_codes (
    id           UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    tontine_code TEXT        NOT NULL,
    gest_nom     TEXT        NOT NULL,
    contact      TEXT        NOT NULL,
    code         TEXT        NOT NULL,   -- SHA-256 hash, jamais le code en clair
    expire_at    TIMESTAMPTZ NOT NULL DEFAULT NOW() + INTERVAL '10 minutes',
    utilise      BOOLEAN     NOT NULL DEFAULT FALSE,
    tentatives   INT         NOT NULL DEFAULT 0,
    cree_le      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Index pour les requêtes fréquentes
CREATE INDEX IF NOT EXISTS idx_pin_reset_codes_tontine_gest
    ON pin_reset_codes (tontine_code, gest_nom);
CREATE INDEX IF NOT EXISTS idx_pin_reset_codes_expire
    ON pin_reset_codes (expire_at);

-- RLS activé — accès uniquement via RPC SECURITY DEFINER
ALTER TABLE pin_reset_codes ENABLE ROW LEVEL SECURITY;
DO $$ BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies
        WHERE tablename = 'pin_reset_codes' AND policyname = 'no_direct_access'
    ) THEN
        CREATE POLICY no_direct_access ON pin_reset_codes USING (FALSE);
    END IF;
END $$;

-- ─── Table audit_securite (créée en v1, s'assurer qu'elle existe) ─────────────
CREATE TABLE IF NOT EXISTS audit_securite (
    id           UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    tontine_code TEXT        NOT NULL,
    gest_nom     TEXT        NOT NULL,
    action       TEXT        NOT NULL,
    description  TEXT,
    appareil     TEXT,
    ip_adresse   TEXT,
    resultat     TEXT        NOT NULL CHECK (resultat IN ('succes','echec','tente')),
    cree_le      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_audit_securite_tontine
    ON audit_securite (tontine_code, gest_nom);

ALTER TABLE audit_securite ENABLE ROW LEVEL SECURITY;
DO $$ BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies
        WHERE tablename = 'audit_securite' AND policyname = 'no_direct_access'
    ) THEN
        CREATE POLICY no_direct_access ON audit_securite USING (FALSE);
    END IF;
END $$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- FONCTION PRINCIPALE v2 : demander_reset_pin_v2
--
-- Retourne JSONB :
--   { ok: true,  email: "...", gest_nom: "...", tontine_code: "...",
--     code_clair: "123456", envoyer: true,
--     message: "Code généré" }
--
--   { ok: true,  envoyer: false,
--     message: "Si ce contact est lié..." }   ← anti-énumération (contact inconnu)
--
--   { ok: false, erreur: "Rate limit dépassé" }
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
    v_tontine_code  TEXT := UPPER(TRIM(p_code));
    v_nom           TEXT := TRIM(p_nom);
    v_contact       TEXT := LOWER(TRIM(p_contact));
    v_gest_email    TEXT := NULL;
    v_gest_nom_reel TEXT := NULL;
    v_nb_recents    INT  := 0;
    v_code_clair    TEXT;
    v_code_hash     TEXT;
    v_tontine_data  JSONB;
    v_gests         JSONB;
    v_gest          JSONB;
    v_i             INT;
    v_match         BOOLEAN := FALSE;
BEGIN
    -- ── 1. Récupérer les données de la tontine ────────────────────────────────
    SELECT data INTO v_tontine_data
    FROM tontines
    WHERE code = v_tontine_code
    LIMIT 1;

    IF NOT FOUND THEN
        -- Anti-énumération : ne pas révéler si la tontine existe
        RETURN jsonb_build_object(
            'ok',      TRUE,
            'envoyer', FALSE,
            'message', 'Si ce contact est lié à votre compte, un code vous a été envoyé.'
        );
    END IF;

    -- ── 2. Chercher le gestionnaire par email ou téléphone ────────────────────
    v_gests := v_tontine_data -> 'gestionnaires';

    IF v_gests IS NOT NULL AND jsonb_typeof(v_gests) = 'array' THEN
        FOR v_i IN 0 .. jsonb_array_length(v_gests) - 1 LOOP
            v_gest := v_gests -> v_i;

            -- Comparer email
            IF LOWER(v_gest ->> 'email') = v_contact THEN
                v_gest_email    := v_gest ->> 'email';
                v_gest_nom_reel := v_gest ->> 'nom';
                v_match         := TRUE;
                EXIT;
            END IF;

            -- Comparer téléphone (nettoyé)
            IF REGEXP_REPLACE(v_gest ->> 'telephone', '[^0-9+]', '', 'g')
               = REGEXP_REPLACE(v_contact, '[^0-9+]', '', 'g')
               AND (v_gest ->> 'telephone') IS NOT NULL
               AND (v_gest ->> 'telephone') <> ''
            THEN
                v_gest_email    := v_gest ->> 'email';
                v_gest_nom_reel := v_gest ->> 'nom';
                v_match         := TRUE;
                EXIT;
            END IF;
        END LOOP;
    END IF;

    -- Si le gestionnaire saisi (p_nom) correspond mais pas le contact →
    -- on utilise aussi le nom fourni pour chercher l'email du gestionnaire
    IF NOT v_match AND v_gests IS NOT NULL AND jsonb_typeof(v_gests) = 'array' THEN
        FOR v_i IN 0 .. jsonb_array_length(v_gests) - 1 LOOP
            v_gest := v_gests -> v_i;
            IF LOWER(v_gest ->> 'nom') = LOWER(v_nom) THEN
                -- Vérifier que le contact correspond (email ou tel)
                IF LOWER(v_gest ->> 'email') = v_contact
                   OR REGEXP_REPLACE(v_gest ->> 'telephone', '[^0-9+]', '', 'g')
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

    -- Anti-énumération : si contact inconnu, réponse identique
    IF NOT v_match OR v_gest_email IS NULL OR v_gest_email = '' THEN
        RETURN jsonb_build_object(
            'ok',      TRUE,
            'envoyer', FALSE,
            'message', 'Si ce contact est lié à votre compte, un code vous a été envoyé.'
        );
    END IF;

    -- ── 3. Rate limiting : max 3 codes actifs dans 30 min ────────────────────
    SELECT COUNT(*) INTO v_nb_recents
    FROM pin_reset_codes
    WHERE tontine_code = v_tontine_code
      AND gest_nom     = COALESCE(v_gest_nom_reel, v_nom)
      AND utilise      = FALSE
      AND cree_le      > NOW() - INTERVAL '30 minutes';

    IF v_nb_recents >= 3 THEN
        -- Log dans audit_securite
        INSERT INTO audit_securite (tontine_code, gest_nom, action, description, resultat)
        VALUES (v_tontine_code, COALESCE(v_gest_nom_reel, v_nom),
                'reset_pin_demande', 'Rate limit dépassé (3 codes / 30 min)', 'echec');

        RETURN jsonb_build_object(
            'ok',     FALSE,
            'erreur', 'Trop de tentatives. Réessayez dans 30 minutes.'
        );
    END IF;

    -- ── 4. Invalider les anciens codes non utilisés ───────────────────────────
    UPDATE pin_reset_codes
    SET    utilise = TRUE
    WHERE  tontine_code = v_tontine_code
      AND  gest_nom     = COALESCE(v_gest_nom_reel, v_nom)
      AND  utilise      = FALSE;

    -- ── 5. Générer le code à 6 chiffres ──────────────────────────────────────
    -- Génération sécurisée via gen_random_uuid → entier 6 chiffres
    v_code_clair := LPAD(
        (ABS(('x' || SUBSTR(gen_random_uuid()::TEXT, 1, 8))::BIT(32)::BIGINT) % 900000 + 100000)::TEXT,
        6, '0'
    );

    -- Hachage SHA-256 du code en clair
    v_code_hash := ENCODE(DIGEST(v_code_clair, 'sha256'), 'hex');

    -- ── 6. Insérer le code hashé en base ──────────────────────────────────────
    INSERT INTO pin_reset_codes (
        tontine_code, gest_nom, contact, code, expire_at
    ) VALUES (
        v_tontine_code,
        COALESCE(v_gest_nom_reel, v_nom),
        v_contact,
        v_code_hash,
        NOW() + INTERVAL '10 minutes'
    );

    -- ── 7. Log audit ──────────────────────────────────────────────────────────
    INSERT INTO audit_securite (tontine_code, gest_nom, action, description, resultat)
    VALUES (
        v_tontine_code,
        COALESCE(v_gest_nom_reel, v_nom),
        'reset_pin_demande',
        'Code de réinitialisation généré — envoi email via Edge Function',
        'succes'
    );

    -- ── 8. Retourner le code_clair UNE SEULE FOIS ────────────────────────────
    -- Flutter va immédiatement appeler send-manager-pin avec ce code
    -- Il n'est JAMAIS stocké en clair, jamais loggué
    RETURN jsonb_build_object(
        'ok',          TRUE,
        'envoyer',     TRUE,
        'email',       v_gest_email,
        'gest_nom',    COALESCE(v_gest_nom_reel, v_nom),
        'tontine_code', v_tontine_code,
        'code_clair',  v_code_clair,
        'message',     'Code généré avec succès.'
    );

EXCEPTION WHEN OTHERS THEN
    -- Ne jamais propager une erreur interne à l'utilisateur
    RAISE LOG '[demander_reset_pin_v2] Erreur : %', SQLERRM;
    RETURN jsonb_build_object(
        'ok',      TRUE,
        'envoyer', FALSE,
        'message', 'Si ce contact est lié à votre compte, un code vous a été envoyé.'
    );
END;
$$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- FONCTION : valider_code_reset_pin (inchangée — compatible v1 et v2)
-- ═══════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION valider_code_reset_pin(
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
    v_tontine_code TEXT := UPPER(TRIM(p_code_tontine));
    v_nom          TEXT := TRIM(p_nom);
    v_code_hash    TEXT := ENCODE(DIGEST(TRIM(p_code_saisi), 'sha256'), 'hex');
    v_record       pin_reset_codes%ROWTYPE;
    v_tentatives   INT;
    v_max_tent     CONSTANT INT := 5;
BEGIN
    -- Chercher le code valide le plus récent (non utilisé, non expiré)
    SELECT * INTO v_record
    FROM   pin_reset_codes
    WHERE  tontine_code = v_tontine_code
      AND  gest_nom     = v_nom
      AND  utilise      = FALSE
      AND  expire_at    > NOW()
    ORDER BY cree_le DESC
    LIMIT 1;

    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'ok',    FALSE,
            'erreur', 'Code expiré ou invalide. Demandez un nouveau code.'
        );
    END IF;

    -- Vérifier le nombre de tentatives
    IF v_record.tentatives >= v_max_tent THEN
        UPDATE pin_reset_codes SET utilise = TRUE WHERE id = v_record.id;
        INSERT INTO audit_securite (tontine_code, gest_nom, action, description, resultat)
        VALUES (v_tontine_code, v_nom, 'reset_pin_tentative',
                'Max tentatives atteint — code invalidé', 'echec');
        RETURN jsonb_build_object(
            'ok',                  FALSE,
            'erreur',              'Trop de tentatives. Demandez un nouveau code.',
            'tentatives_restantes', 0
        );
    END IF;

    -- Incrémenter le compteur de tentatives
    UPDATE pin_reset_codes
    SET tentatives = tentatives + 1
    WHERE id = v_record.id;

    v_tentatives := v_max_tent - (v_record.tentatives + 1);

    -- Comparer le hash
    IF v_record.code <> v_code_hash THEN
        INSERT INTO audit_securite (tontine_code, gest_nom, action, description, resultat)
        VALUES (v_tontine_code, v_nom, 'reset_pin_tentative',
                'Code incorrect — ' || (v_record.tentatives + 1) || ' tentative(s)', 'echec');
        RETURN jsonb_build_object(
            'ok',                  FALSE,
            'erreur',              'Code incorrect.',
            'tentatives_restantes', GREATEST(v_tentatives, 0)
        );
    END IF;

    -- ✅ Code valide — on le marque utilisé
    UPDATE pin_reset_codes
    SET utilise = TRUE
    WHERE id = v_record.id;

    INSERT INTO audit_securite (tontine_code, gest_nom, action, description, resultat)
    VALUES (v_tontine_code, v_nom, 'reset_pin_code_valide',
            'Code de réinitialisation validé', 'succes');

    RETURN jsonb_build_object(
        'ok',      TRUE,
        'message', 'Code validé. Définissez votre nouveau PIN.'
    );

EXCEPTION WHEN OTHERS THEN
    RAISE LOG '[valider_code_reset_pin] Erreur : %', SQLERRM;
    RETURN jsonb_build_object('ok', FALSE, 'erreur', 'Erreur serveur. Réessayez.');
END;
$$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- FONCTION : reinitialiser_pin (inchangée — compatible v1 et v2)
-- ═══════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION reinitialiser_pin(
    p_code_tontine  TEXT,
    p_nom           TEXT,
    p_nouveau_pin   TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_tontine_code  TEXT := UPPER(TRIM(p_code_tontine));
    v_nom           TEXT := TRIM(p_nom);
    v_nouveau_pin   TEXT := TRIM(p_nouveau_pin);
    v_pin_hash      TEXT;
    v_record        pin_reset_codes%ROWTYPE;
    v_tontine_data  JSONB;
    v_gests         JSONB;
    v_gests_updated JSONB;
    v_gest          JSONB;
    v_idx           INT := -1;
    v_i             INT;
    -- PIN trop simples interdits
    v_pins_interdits TEXT[] := ARRAY[
        '0000','1111','2222','3333','4444','5555','6666','7777','8888','9999',
        '1234','4321','1212','0101','1010','0011','1100',
        '123456','654321','112233','000000','111111','999999','123123','321321'
    ];
BEGIN
    -- ── 1. Validation longueur ────────────────────────────────────────────────
    IF length(v_nouveau_pin) < 4 OR length(v_nouveau_pin) > 6 THEN
        RETURN jsonb_build_object('ok', FALSE, 'erreur', 'Le PIN doit faire 4 à 6 chiffres.');
    END IF;

    -- Vérifier que c'est bien des chiffres
    IF v_nouveau_pin !~ '^\d+$' THEN
        RETURN jsonb_build_object('ok', FALSE, 'erreur', 'Le PIN ne doit contenir que des chiffres.');
    END IF;

    -- ── 2. PIN trop simple ────────────────────────────────────────────────────
    IF v_nouveau_pin = ANY(v_pins_interdits) THEN
        RETURN jsonb_build_object('ok', FALSE, 'erreur', 'Ce PIN est trop simple. Choisissez-en un plus sécurisé.');
    END IF;

    -- ── 3. Vérifier session reset valide (code utilisé < 5 min) ──────────────
    SELECT * INTO v_record
    FROM   pin_reset_codes
    WHERE  tontine_code = v_tontine_code
      AND  gest_nom     = v_nom
      AND  utilise      = TRUE
      AND  cree_le      > NOW() - INTERVAL '5 minutes'
    ORDER BY cree_le DESC
    LIMIT  1;

    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'ok',    FALSE,
            'erreur', 'Session expirée. Recommencez la procédure de réinitialisation.'
        );
    END IF;

    -- ── 4. Hacher le nouveau PIN ──────────────────────────────────────────────
    v_pin_hash := ENCODE(DIGEST(v_nouveau_pin, 'sha256'), 'hex');

    -- ── 5. Trouver le gestionnaire dans le JSONB ──────────────────────────────
    SELECT data INTO v_tontine_data
    FROM   tontines
    WHERE  code = v_tontine_code;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', FALSE, 'erreur', 'Tontine introuvable.');
    END IF;

    v_gests := v_tontine_data -> 'gestionnaires';

    IF v_gests IS NULL OR jsonb_typeof(v_gests) <> 'array' THEN
        RETURN jsonb_build_object('ok', FALSE, 'erreur', 'Aucun gestionnaire trouvé.');
    END IF;

    -- Trouver l'index du gestionnaire
    FOR v_i IN 0 .. jsonb_array_length(v_gests) - 1 LOOP
        IF LOWER(v_gests -> v_i ->> 'nom') = LOWER(v_nom) THEN
            v_idx := v_i;
            EXIT;
        END IF;
    END LOOP;

    IF v_idx = -1 THEN
        RETURN jsonb_build_object('ok', FALSE, 'erreur', 'Gestionnaire introuvable.');
    END IF;

    -- ── 6. Mettre à jour le PIN dans le JSONB via jsonb_set ──────────────────
    v_gests_updated := jsonb_set(
        v_gests,
        ARRAY[v_idx::TEXT, 'pin'],
        to_jsonb(v_pin_hash),
        TRUE
    );

    UPDATE tontines
    SET data = jsonb_set(data, '{gestionnaires}', v_gests_updated, FALSE)
    WHERE code = v_tontine_code;

    -- ── 7. Log audit ──────────────────────────────────────────────────────────
    INSERT INTO audit_securite (tontine_code, gest_nom, action, description, resultat)
    VALUES (v_tontine_code, v_nom, 'reinitialisation_pin',
            'PIN de gestion réinitialisé avec succès via Edge Function', 'succes');

    RETURN jsonb_build_object('ok', TRUE, 'message', 'PIN réinitialisé avec succès.');

EXCEPTION WHEN OTHERS THEN
    RAISE LOG '[reinitialiser_pin] Erreur : %', SQLERRM;
    RETURN jsonb_build_object('ok', FALSE, 'erreur', 'Erreur serveur. Réessayez.');
END;
$$;

-- ── Révoquer accès public, garder SECURITY DEFINER ────────────────────────────
REVOKE ALL ON FUNCTION demander_reset_pin_v2(TEXT, TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION valider_code_reset_pin(TEXT, TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION reinitialiser_pin(TEXT, TEXT, TEXT) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION demander_reset_pin_v2(TEXT, TEXT, TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION valider_code_reset_pin(TEXT, TEXT, TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION reinitialiser_pin(TEXT, TEXT, TEXT) TO anon, authenticated;

-- ── Nettoyage automatique des codes expirés (>24h) ────────────────────────────
CREATE OR REPLACE FUNCTION purger_codes_pin_expires()
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_nb INT;
BEGIN
    DELETE FROM pin_reset_codes
    WHERE expire_at < NOW() - INTERVAL '24 hours';
    GET DIAGNOSTICS v_nb = ROW_COUNT;
    RETURN v_nb;
END;
$$;

GRANT EXECUTE ON FUNCTION purger_codes_pin_expires() TO service_role;
