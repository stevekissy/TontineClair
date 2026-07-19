-- ═══════════════════════════════════════════════════════════════════════════════
-- TontineClair — demander_reset_pin_v3 : vérification stricte de l'email
--
-- CONTEXTE :
--   v2 utilisait l'anti-énumération : réponse neutre si email inconnu.
--   Désormais, l'email est OBLIGATOIRE à la création (stocké dans gestionnaires).
--   → Si l'email saisi ne correspond PAS → erreur explicite (ok: false).
--   → L'utilisateur sait qu'il doit ressaisir le BON email.
--
-- CHANGEMENTS vs v2 :
--   - Si tontine introuvable      → ok: false, erreur explicite
--   - Si email ne correspond pas  → ok: false, erreur explicite
--   - Si email correct + code ok  → ok: true, envoyer: true (inchangé)
--   - Rate limit                  → ok: false (inchangé)
--
-- À déployer : Supabase → SQL Editor → New query → Run
-- ═══════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION demander_reset_pin_v3(
    p_code    TEXT,    -- code de la tontine
    p_nom     TEXT,    -- nom du gestionnaire (affiché dans l'email)
    p_contact TEXT     -- email saisi par l'utilisateur
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
    v_tontine_row   tontines%ROWTYPE;
    v_gests         JSONB;
    v_gest          JSONB;
    v_i             INT;
    v_match         BOOLEAN := FALSE;
BEGIN
    -- ── 1. Récupérer la tontine ──────────────────────────────────────────────
    SELECT * INTO v_tontine_row
    FROM   tontines
    WHERE  code = v_tontine_code
    LIMIT  1;

    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'ok',     FALSE,
            'erreur', 'Tontine introuvable. Vérifiez le code saisi.'
        );
    END IF;

    -- ── 2. Lire la colonne `gestionnaires` (objets {nom, email, pin}) ────────
    v_gests := v_tontine_row.gestionnaires;

    -- Fallback : si la colonne séparée est vide, tenter data->'gestionnaires'
    IF v_gests IS NULL OR jsonb_typeof(v_gests) <> 'array' OR jsonb_array_length(v_gests) = 0 THEN
        v_gests := v_tontine_row.data -> 'gestionnaires';
    END IF;

    -- ── 3. Chercher le gestionnaire par email ────────────────────────────────
    IF v_gests IS NOT NULL AND jsonb_typeof(v_gests) = 'array' THEN
        FOR v_i IN 0 .. jsonb_array_length(v_gests) - 1 LOOP
            v_gest := v_gests -> v_i;

            -- Ignorer les entrées de type string (ancien format sans email)
            IF jsonb_typeof(v_gest) <> 'object' THEN
                CONTINUE;
            END IF;

            -- Comparaison email exacte (insensible à la casse)
            IF LOWER(COALESCE(v_gest ->> 'email', '')) = v_contact
               AND v_contact <> ''
            THEN
                v_gest_email    := v_gest ->> 'email';
                v_gest_nom_reel := v_gest ->> 'nom';
                v_match         := TRUE;
                EXIT;
            END IF;
        END LOOP;
    END IF;

    -- ── 4. Email incorrect → refus explicite ─────────────────────────────────
    -- (Pas d'anti-énumération en v3 : l'email est obligatoire à la création)
    IF NOT v_match OR v_gest_email IS NULL OR v_gest_email = '' THEN
        INSERT INTO audit_securite (tontine_code, gest_nom, action, description, resultat)
        VALUES (v_tontine_code, v_nom, 'reset_pin_demande',
                'Email incorrect ou absent : ' || v_contact, 'echec');

        RETURN jsonb_build_object(
            'ok',     FALSE,
            'erreur', 'Cet email ne correspond pas à cette tontine. '
                      'Vérifiez l''email saisi lors de la création.'
        );
    END IF;

    -- ── 5. Rate limiting : max 3 codes dans 30 min ───────────────────────────
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

    -- ── 6. Invalider les anciens codes non utilisés ───────────────────────────
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

    -- Hachage SHA-256
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

    -- ── 9. Log audit succès ───────────────────────────────────────────────────
    INSERT INTO audit_securite (tontine_code, gest_nom, action, description, resultat)
    VALUES (
        v_tontine_code,
        COALESCE(v_gest_nom_reel, v_nom),
        'reset_pin_demande',
        'Code généré — email vérifié et envoyé via Edge Function',
        'succes'
    );

    -- ── 10. Retourner le code en clair (UNE SEULE FOIS) ──────────────────────
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
        'ok',     FALSE,
        'erreur', 'Erreur serveur inattendue. Réessayez.'
    );
END;
$$;

GRANT EXECUTE ON FUNCTION demander_reset_pin_v3(TEXT, TEXT, TEXT) TO anon, authenticated;


-- ═══════════════════════════════════════════════════════════════════════════════
-- MIGRATION creer_tontine : stocker l'email dans la colonne `gestionnaires`
--
-- La RPC creer_tontine reçoit p_gestionnaires comme tableau d'objets {nom, pin, email}.
-- La colonne `gestionnaires` de la table `tontines` doit stocker ces objets.
-- Ce bloc vérifie que la colonne accepte bien le champ email.
-- ═══════════════════════════════════════════════════════════════════════════════

-- Vérification que la colonne gestionnaires existe (JSONB)
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE  table_name  = 'tontines'
          AND  column_name = 'gestionnaires'
    ) THEN
        ALTER TABLE tontines ADD COLUMN gestionnaires JSONB DEFAULT '[]';
        RAISE NOTICE 'Colonne gestionnaires ajoutée à la table tontines.';
    ELSE
        RAISE NOTICE 'Colonne gestionnaires déjà présente.';
    END IF;
END;
$$;


-- ═══════════════════════════════════════════════════════════════════════════════
-- VÉRIFICATION POST-DÉPLOIEMENT
-- ═══════════════════════════════════════════════════════════════════════════════

-- Test 1 : Vérifier que v3 est bien créée
-- SELECT proname, pronargs FROM pg_proc WHERE proname = 'demander_reset_pin_v3';

-- Test 2 : Test avec email correct (doit retourner ok:true, envoyer:true)
-- SELECT demander_reset_pin_v3('CODE_TONTINE', 'NOM_GEST', 'email@correct.com');

-- Test 3 : Test avec email incorrect (doit retourner ok:false)
-- SELECT demander_reset_pin_v3('CODE_TONTINE', 'NOM_GEST', 'mauvais@email.com');
