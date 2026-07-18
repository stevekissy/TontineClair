-- ═══════════════════════════════════════════════════════════════════════════════
-- TontineClair — Migration : admin_reinitialiser_pin_gestionnaire
-- Version 2 — Lit depuis la colonne 'gestionnaires' (JSONB séparée de data)
--
-- Structure réelle des données :
--   tontines.gestionnaires = [{"nom": "Kissy", "pin": "0103", "email": "..."}, ...]
--   (Colonne JSONB séparée, PAS data->'gestionnaires' qui contient des strings)
--
-- Différences vs demander_reset_pin_v2 :
--   • Auth par clé admin (p_cle) — pas de contact utilisateur requis
--   • Lit colonne 'gestionnaires' (vraie source) plutôt que data->'gestionnaires'
--   • Retourne une vraie erreur si email manquant (pas d'anti-enum)
--   • Génère code 6 chiffres + hash SHA-256 + insère dans pin_reset_codes
--   • Retourne {ok, email, gest_nom, tontine_code, code_clair}
--
-- Prérequis :
--   • Extension pgcrypto (CREATE EXTENSION IF NOT EXISTS pgcrypto)
--   • Tables pin_reset_codes et audit_securite (migration pin_reset_email_system.sql)
--
-- À exécuter dans Supabase → SQL Editor
-- ═══════════════════════════════════════════════════════════════════════════════

-- ─── Extension pgcrypto (requise pour DIGEST / SHA-256) ───────────────────────
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ─── Table pin_reset_codes (si pas encore créée) ──────────────────────────────
CREATE TABLE IF NOT EXISTS pin_reset_codes (
    id           UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    tontine_code TEXT        NOT NULL,
    gest_nom     TEXT        NOT NULL,
    contact      TEXT        NOT NULL,
    code         TEXT        NOT NULL,
    expire_at    TIMESTAMPTZ NOT NULL DEFAULT NOW() + INTERVAL '10 minutes',
    utilise      BOOLEAN     NOT NULL DEFAULT FALSE,
    tentatives   INT         NOT NULL DEFAULT 0,
    cree_le      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_pin_reset_codes_tontine_gest
    ON pin_reset_codes (tontine_code, gest_nom);
CREATE INDEX IF NOT EXISTS idx_pin_reset_codes_expire
    ON pin_reset_codes (expire_at);

ALTER TABLE pin_reset_codes ENABLE ROW LEVEL SECURITY;
DO $$ BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies
        WHERE tablename = 'pin_reset_codes' AND policyname = 'no_direct_access'
    ) THEN
        CREATE POLICY no_direct_access ON pin_reset_codes USING (FALSE);
    END IF;
END $$;

-- ─── Table audit_securite (si pas encore créée) ───────────────────────────────
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
-- FONCTION PRINCIPALE : admin_reinitialiser_pin_gestionnaire
--
-- Paramètres :
--   p_cle          TEXT — clé d'administration
--   p_code_tontine TEXT — code de la tontine (ex: "K93JAP")
--   p_nom_gest     TEXT — nom du gestionnaire (ex: "Kissy")
--
-- Retourne JSONB :
--   OK  : {ok: true,  email, gest_nom, tontine_code, code_clair}
--   ERR : {ok: false, erreur: "message lisible"}
--
-- IMPORTANT — Structure réelle de la colonne gestionnaires :
--   [{"nom": "Kissy", "pin": "0103", "email": "kissy@example.com"}, ...]
--   La fonction lit la COLONNE gestionnaires, pas data->'gestionnaires'
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
    -- IMPORTANT : on lit la colonne 'gestionnaires' qui contient
    -- [{nom, pin, email?}, ...] — PAS data->'gestionnaires' qui contient des strings
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

        -- Chaque élément peut être un objet {nom, pin, email?}
        IF jsonb_typeof(v_gest) = 'object' THEN
            IF LOWER(TRIM(v_gest ->> 'nom')) = LOWER(v_nom_gest) THEN
                v_gest_email    := TRIM(COALESCE(v_gest ->> 'email', ''));
                v_gest_nom_reel := TRIM(v_gest ->> 'nom');
                v_found         := TRUE;
                EXIT;
            END IF;
        -- Compatibilité : si l'élément est une string "Nom"
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

    -- ── 6. Générer le code à 6 chiffres + hash SHA-256 ───────────────────────
    v_code_clair := LPAD(
        (ABS(('x' || SUBSTR(gen_random_uuid()::TEXT, 1, 8))::BIT(32)::BIGINT)
         % 900000 + 100000)::TEXT,
        6, '0'
    );
    v_code_hash := ENCODE(DIGEST(v_code_clair, 'sha256'), 'hex');

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

-- ─── Permissions ──────────────────────────────────────────────────────────────
REVOKE ALL ON FUNCTION admin_reinitialiser_pin_gestionnaire(TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION admin_reinitialiser_pin_gestionnaire(TEXT, TEXT, TEXT) TO anon, authenticated;

-- ─── Note sur pgcrypto ────────────────────────────────────────────────────────
-- Si DIGEST/ENCODE échoue avec "function digest(text, unknown) does not exist",
-- vérifier que pgcrypto est bien activée dans le projet Supabase :
--   Dashboard → Database → Extensions → pgcrypto → Enable
-- Ou exécuter : CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ─── Vérification (exécuter après la migration) ───────────────────────────────
-- SELECT admin_reinitialiser_pin_gestionnaire('ma-cle-admin', 'K93JAP', 'Kissy');
-- Résultat attendu si email présent : {"ok": true, "email": "...", "code_clair": "..."}
