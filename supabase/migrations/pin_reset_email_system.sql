-- ═══════════════════════════════════════════════════════════════════════════
-- TontineClair — Migration : Réinitialisation PIN + Système E-mails
-- Exécuter dans Supabase SQL Editor
-- ═══════════════════════════════════════════════════════════════════════════

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. TABLE : pin_reset_codes
--    Codes temporaires à 6 chiffres pour réinitialisation du PIN
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.pin_reset_codes (
  id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  tontine_code  TEXT        NOT NULL,
  gest_nom      TEXT        NOT NULL,           -- nom du gestionnaire
  contact       TEXT        NOT NULL,           -- email ou téléphone fourni
  code          TEXT        NOT NULL,           -- code à 6 chiffres haché (SHA-256)
  expire_at     TIMESTAMPTZ NOT NULL DEFAULT (NOW() + INTERVAL '10 minutes'),
  utilise       BOOLEAN     NOT NULL DEFAULT FALSE,
  tentatives    INT         NOT NULL DEFAULT 0, -- nb de saisies incorrectes
  ip_adresse    TEXT,                           -- IP de la demande (audit)
  cree_le       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Index pour recherche rapide
CREATE INDEX IF NOT EXISTS idx_pin_reset_tontine_gest
  ON public.pin_reset_codes (tontine_code, gest_nom, utilise, expire_at);

-- RLS : pas d'accès public direct, tout passe par les RPC
ALTER TABLE public.pin_reset_codes ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "no_direct_access_pin_reset" ON public.pin_reset_codes;
CREATE POLICY "no_direct_access_pin_reset" ON public.pin_reset_codes
  FOR ALL USING (FALSE);

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. TABLE : email_logs
--    Historique centralisé de tous les e-mails envoyés par TontineClair
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.email_logs (
  id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  destinataire  TEXT        NOT NULL,           -- adresse e-mail du destinataire
  type_email    TEXT        NOT NULL,           -- 'pin_reset', 'pin_change', 'kyc_verified', etc.
  sujet         TEXT        NOT NULL,
  tontine_code  TEXT,                           -- tontine concernée (nullable pour emails globaux)
  gest_nom      TEXT,                           -- gestionnaire concerné
  statut        TEXT        NOT NULL DEFAULT 'pending'
                            CHECK (statut IN ('envoye', 'pending', 'echoue')),
  motif_echec   TEXT,                           -- message d'erreur si échoué
  tentatives    INT         NOT NULL DEFAULT 0,
  envoye_le     TIMESTAMPTZ,                   -- timestamp du dernier envoi réussi
  cree_le       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  metadata      JSONB       DEFAULT '{}'::jsonb -- données supplémentaires (provider_id, etc.)
);

-- Index pour l'admin
CREATE INDEX IF NOT EXISTS idx_email_logs_statut    ON public.email_logs (statut, cree_le DESC);
CREATE INDEX IF NOT EXISTS idx_email_logs_type      ON public.email_logs (type_email, cree_le DESC);
CREATE INDEX IF NOT EXISTS idx_email_logs_tontine   ON public.email_logs (tontine_code, cree_le DESC);
CREATE INDEX IF NOT EXISTS idx_email_logs_dest      ON public.email_logs (destinataire, cree_le DESC);

-- RLS : admin uniquement via RPC
ALTER TABLE public.email_logs ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "no_direct_access_email_logs" ON public.email_logs;
CREATE POLICY "no_direct_access_email_logs" ON public.email_logs
  FOR ALL USING (FALSE);

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. TABLE : audit_securite
--    Journal d'audit pour toutes les actions de sécurité (PIN, accès, etc.)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.audit_securite (
  id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  tontine_code  TEXT        NOT NULL,
  gest_nom      TEXT        NOT NULL,
  action        TEXT        NOT NULL,           -- 'pin_reset', 'pin_change', 'pin_verify_fail', etc.
  description   TEXT,                           -- détails lisibles (jamais le PIN)
  appareil      TEXT,                           -- user-agent / plateforme
  ip_adresse    TEXT,
  resultat      TEXT        NOT NULL DEFAULT 'succes'
                            CHECK (resultat IN ('succes', 'echec', 'tente')),
  cree_le       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_audit_securite_tontine
  ON public.audit_securite (tontine_code, gest_nom, cree_le DESC);

ALTER TABLE public.audit_securite ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "no_direct_access_audit" ON public.audit_securite;
CREATE POLICY "no_direct_access_audit" ON public.audit_securite
  FOR ALL USING (FALSE);


-- ═══════════════════════════════════════════════════════════════════════════
-- FONCTIONS SQL
-- ═══════════════════════════════════════════════════════════════════════════

-- ─────────────────────────────────────────────────────────────────────────────
-- F1. demander_reset_pin(p_code, p_nom, p_contact)
--     Génère un code de réinitialisation, le hache et l'insère.
--     Retourne : { ok, code_clair, gest_nom, message, erreur }
--     Le code_clair est retourné UNE SEULE FOIS pour envoi par email.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.demander_reset_pin(
  p_code    TEXT,
  p_nom     TEXT,
  p_contact TEXT
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_tontine   JSONB;
  v_gest      JSONB;
  v_gests     JSONB;
  v_code_clair TEXT;
  v_code_hash  TEXT;
  v_existing   UUID;
BEGIN
  -- Normaliser
  p_code := UPPER(TRIM(p_code));
  p_nom  := TRIM(p_nom);
  p_contact := LOWER(TRIM(p_contact));

  -- 1. Vérifier que la tontine existe
  SELECT data INTO v_tontine
    FROM public.tontines
   WHERE code = p_code AND deleted_at IS NULL;
  
  IF v_tontine IS NULL THEN
    RETURN jsonb_build_object('ok', FALSE, 'erreur', 'Tontine introuvable.');
  END IF;

  -- 2. Vérifier que le gestionnaire existe dans cette tontine
  v_gests := v_tontine -> 'gestionnaires';
  v_gest := NULL;
  
  IF v_gests IS NOT NULL THEN
    SELECT elem INTO v_gest
      FROM jsonb_array_elements(v_gests) AS elem
     WHERE LOWER(TRIM(elem->>'nom')) = LOWER(TRIM(p_nom))
     LIMIT 1;
  END IF;

  IF v_gest IS NULL THEN
    RETURN jsonb_build_object('ok', FALSE, 'erreur', 'Gestionnaire introuvable dans cette tontine.');
  END IF;

  -- 3. Vérifier le contact (email ou téléphone stocké dans les données)
  --    On vérifie que le contact fourni correspond au contact enregistré
  DECLARE
    v_contact_enr TEXT := LOWER(TRIM(COALESCE(v_gest->>'contact', v_gest->>'email', '')));
  BEGIN
    IF v_contact_enr = '' OR (v_contact_enr != p_contact) THEN
      -- Tolérance : on retourne OK mais sans révéler si le contact est incorrect
      -- (sécurité : éviter l'énumération)
      RETURN jsonb_build_object(
        'ok', TRUE,
        'message', 'Si ce contact est lié à un compte, un code vous sera envoyé.',
        'envoyer', FALSE
      );
    END IF;
  END;

  -- 4. Limiter les demandes : max 3 codes actifs non utilisés dans les 30 dernières minutes
  SELECT COUNT(*) INTO v_existing
    FROM public.pin_reset_codes
   WHERE tontine_code = p_code
     AND gest_nom     = p_nom
     AND utilise      = FALSE
     AND expire_at    > NOW()
     AND cree_le      > NOW() - INTERVAL '30 minutes';

  IF v_existing >= 3 THEN
    RETURN jsonb_build_object(
      'ok', FALSE,
      'erreur', 'Trop de demandes en cours. Réessayez dans 30 minutes.'
    );
  END IF;

  -- 5. Invalider les anciens codes non utilisés pour ce gestionnaire
  UPDATE public.pin_reset_codes
     SET utilise = TRUE
   WHERE tontine_code = p_code
     AND gest_nom     = p_nom
     AND utilise      = FALSE;

  -- 6. Générer un code à 6 chiffres et le hacher
  v_code_clair := LPAD(FLOOR(RANDOM() * 1000000)::TEXT, 6, '0');
  v_code_hash  := ENCODE(DIGEST(v_code_clair, 'sha256'), 'hex');

  -- 7. Insérer le code
  INSERT INTO public.pin_reset_codes
    (tontine_code, gest_nom, contact, code, expire_at)
  VALUES
    (p_code, p_nom, p_contact, v_code_hash, NOW() + INTERVAL '10 minutes');

  -- 8. Journal d'audit
  INSERT INTO public.audit_securite
    (tontine_code, gest_nom, action, description, resultat)
  VALUES
    (p_code, p_nom, 'pin_reset_demande',
     'Demande de réinitialisation PIN — contact : ' || p_contact, 'succes');

  RETURN jsonb_build_object(
    'ok',         TRUE,
    'code_clair', v_code_clair,
    'gest_nom',   p_nom,
    'contact',    p_contact,
    'envoyer',    TRUE,
    'message',    'Code généré. Valide 10 minutes.'
  );
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- F2. valider_code_reset_pin(p_code_tontine, p_nom, p_code_saisi)
--     Valide le code de réinitialisation.
--     Retourne : { ok, message, erreur, tentatives_restantes }
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.valider_code_reset_pin(
  p_code_tontine TEXT,
  p_nom          TEXT,
  p_code_saisi   TEXT
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_record    public.pin_reset_codes;
  v_hash_saisi TEXT;
  v_max_tentatives CONSTANT INT := 5;
BEGIN
  p_code_tontine := UPPER(TRIM(p_code_tontine));
  p_nom          := TRIM(p_nom);
  p_code_saisi   := TRIM(p_code_saisi);

  -- 1. Trouver le code actif le plus récent
  SELECT * INTO v_record
    FROM public.pin_reset_codes
   WHERE tontine_code = p_code_tontine
     AND gest_nom     = p_nom
     AND utilise      = FALSE
     AND expire_at    > NOW()
   ORDER BY cree_le DESC
   LIMIT 1;

  IF v_record.id IS NULL THEN
    RETURN jsonb_build_object('ok', FALSE, 'erreur', 'Aucun code valide. Faites une nouvelle demande.');
  END IF;

  -- 2. Vérifier le nombre de tentatives
  IF v_record.tentatives >= v_max_tentatives THEN
    UPDATE public.pin_reset_codes SET utilise = TRUE WHERE id = v_record.id;
    RETURN jsonb_build_object('ok', FALSE, 'erreur', 'Trop de tentatives. Faites une nouvelle demande.');
  END IF;

  -- 3. Hacher le code saisi et comparer
  v_hash_saisi := ENCODE(DIGEST(p_code_saisi, 'sha256'), 'hex');

  IF v_hash_saisi != v_record.code THEN
    -- Incrémenter les tentatives
    UPDATE public.pin_reset_codes
       SET tentatives = tentatives + 1
     WHERE id = v_record.id;

    INSERT INTO public.audit_securite
      (tontine_code, gest_nom, action, description, resultat)
    VALUES
      (p_code_tontine, p_nom, 'pin_reset_code_invalide',
       'Code de vérification incorrect — tentative ' || (v_record.tentatives + 1), 'echec');

    RETURN jsonb_build_object(
      'ok', FALSE,
      'erreur', 'Code incorrect.',
      'tentatives_restantes', v_max_tentatives - (v_record.tentatives + 1)
    );
  END IF;

  -- 4. Code valide : marquer comme utilisé
  UPDATE public.pin_reset_codes SET utilise = TRUE WHERE id = v_record.id;

  RETURN jsonb_build_object('ok', TRUE, 'message', 'Code validé. Vous pouvez définir votre nouveau PIN.');
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- F3. reinitialiser_pin(p_code_tontine, p_nom, p_nouveau_pin)
--     Applique le nouveau PIN après validation du code.
--     Vérifie que le code a bien été validé (utilisé dans les 5 dernières minutes).
--     Retourne : { ok, message, erreur }
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.reinitialiser_pin(
  p_code_tontine TEXT,
  p_nom          TEXT,
  p_nouveau_pin  TEXT
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_tontine   JSONB;
  v_gests     JSONB;
  v_gest      JSONB;
  v_idx       INT := 0;
  v_nouveau_hash TEXT;
  v_pin_interdit BOOL := FALSE;
  v_recent_reset BOOLEAN;
BEGIN
  p_code_tontine := UPPER(TRIM(p_code_tontine));
  p_nom          := TRIM(p_nom);
  p_nouveau_pin  := TRIM(p_nouveau_pin);

  -- 1. Vérifier qu'un code valide a été utilisé récemment (≤ 5 min)
  SELECT EXISTS(
    SELECT 1 FROM public.pin_reset_codes
     WHERE tontine_code = p_code_tontine
       AND gest_nom     = p_nom
       AND utilise      = TRUE
       AND cree_le      > NOW() - INTERVAL '5 minutes'
  ) INTO v_recent_reset;

  IF NOT v_recent_reset THEN
    RETURN jsonb_build_object('ok', FALSE, 'erreur', 'Session expirée. Recommencez la procédure.');
  END IF;

  -- 2. Valider le nouveau PIN
  IF LENGTH(p_nouveau_pin) < 4 THEN
    RETURN jsonb_build_object('ok', FALSE, 'erreur', 'PIN trop court (4 chiffres minimum).');
  END IF;

  -- 3. Interdire PIN trop simples
  IF p_nouveau_pin IN ('0000','1111','2222','3333','4444','5555','6666','7777','8888','9999',
                        '1234','4321','1212','0101','1010','0011','1100',
                        '123456','654321','112233','000000','111111','999999') THEN
    v_pin_interdit := TRUE;
  END IF;

  IF v_pin_interdit THEN
    RETURN jsonb_build_object('ok', FALSE, 'erreur', 'Ce PIN est trop simple. Choisissez un PIN plus sécurisé.');
  END IF;

  -- 4. Récupérer la tontine
  SELECT data INTO v_tontine
    FROM public.tontines
   WHERE code = p_code_tontine AND deleted_at IS NULL;

  IF v_tontine IS NULL THEN
    RETURN jsonb_build_object('ok', FALSE, 'erreur', 'Tontine introuvable.');
  END IF;

  -- 5. Hacher le nouveau PIN
  v_nouveau_hash := ENCODE(DIGEST(p_nouveau_pin, 'sha256'), 'hex');

  -- 6. Mettre à jour le PIN dans le JSONB gestionnaires
  v_gests := v_tontine -> 'gestionnaires';
  
  IF v_gests IS NULL OR jsonb_array_length(v_gests) = 0 THEN
    RETURN jsonb_build_object('ok', FALSE, 'erreur', 'Gestionnaire introuvable.');
  END IF;

  -- Trouver l'index du gestionnaire
  SELECT idx INTO v_idx
    FROM (
      SELECT ordinality - 1 AS idx, elem
        FROM jsonb_array_elements(v_gests) WITH ORDINALITY AS t(elem, ordinality)
    ) sub
   WHERE LOWER(TRIM(sub.elem->>'nom')) = LOWER(TRIM(p_nom))
   LIMIT 1;

  -- Mettre à jour le PIN dans l'élément correspondant
  v_gests := jsonb_set(v_gests, ARRAY[v_idx::TEXT, 'pin'], to_jsonb(v_nouveau_hash));
  v_tontine := jsonb_set(v_tontine, '{gestionnaires}', v_gests);

  -- 7. Écrire dans la tontine
  UPDATE public.tontines
     SET data = v_tontine, updated_at = NOW()
   WHERE code = p_code_tontine;

  -- 8. Audit
  INSERT INTO public.audit_securite
    (tontine_code, gest_nom, action, description, resultat)
  VALUES
    (p_code_tontine, p_nom, 'pin_reset',
     'PIN réinitialisé avec succès via procédure de récupération.', 'succes');

  RETURN jsonb_build_object('ok', TRUE, 'message', 'PIN réinitialisé avec succès.');
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- F4. modifier_pin(p_code, p_nom, p_ancien_pin, p_nouveau_pin)
--     Change le PIN depuis une session connectée (connait l'ancien PIN).
--     Retourne : { ok, message, erreur }
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.modifier_pin(
  p_code         TEXT,
  p_nom          TEXT,
  p_ancien_pin   TEXT,
  p_nouveau_pin  TEXT
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_tontine      JSONB;
  v_gests        JSONB;
  v_gest         JSONB;
  v_idx          INT := 0;
  v_pin_stocke   TEXT;
  v_ancien_hash  TEXT;
  v_nouveau_hash TEXT;
BEGIN
  p_code        := UPPER(TRIM(p_code));
  p_nom         := TRIM(p_nom);
  p_ancien_pin  := TRIM(p_ancien_pin);
  p_nouveau_pin := TRIM(p_nouveau_pin);

  -- 1. Récupérer la tontine
  SELECT data INTO v_tontine
    FROM public.tontines
   WHERE code = p_code AND deleted_at IS NULL;

  IF v_tontine IS NULL THEN
    RETURN jsonb_build_object('ok', FALSE, 'erreur', 'Tontine introuvable.');
  END IF;

  v_gests := v_tontine -> 'gestionnaires';

  -- 2. Trouver le gestionnaire et son PIN
  SELECT sub.idx, sub.elem INTO v_idx, v_gest
    FROM (
      SELECT ordinality - 1 AS idx, elem
        FROM jsonb_array_elements(v_gests) WITH ORDINALITY AS t(elem, ordinality)
    ) sub
   WHERE LOWER(TRIM(sub.elem->>'nom')) = LOWER(TRIM(p_nom))
   LIMIT 1;

  IF v_gest IS NULL THEN
    RETURN jsonb_build_object('ok', FALSE, 'erreur', 'Gestionnaire introuvable.');
  END IF;

  -- 3. Vérifier l'ancien PIN (peut être haché ou en clair selon version)
  v_pin_stocke  := v_gest->>'pin';
  v_ancien_hash := ENCODE(DIGEST(p_ancien_pin, 'sha256'), 'hex');

  IF v_pin_stocke != p_ancien_pin AND v_pin_stocke != v_ancien_hash THEN
    INSERT INTO public.audit_securite
      (tontine_code, gest_nom, action, description, resultat)
    VALUES
      (p_code, p_nom, 'pin_change_echec', 'Ancien PIN incorrect.', 'echec');
    RETURN jsonb_build_object('ok', FALSE, 'erreur', 'Ancien PIN incorrect.');
  END IF;

  -- 4. Valider le nouveau PIN
  IF LENGTH(p_nouveau_pin) < 4 THEN
    RETURN jsonb_build_object('ok', FALSE, 'erreur', 'PIN trop court (4 chiffres minimum).');
  END IF;

  IF p_nouveau_pin IN ('0000','1111','2222','3333','4444','5555','6666','7777','8888','9999',
                        '1234','4321','1212','0101','1010','0011','1100',
                        '123456','654321','112233','000000','111111','999999') THEN
    RETURN jsonb_build_object('ok', FALSE, 'erreur', 'Ce PIN est trop simple. Choisissez-en un autre.');
  END IF;

  IF p_nouveau_pin = p_ancien_pin THEN
    RETURN jsonb_build_object('ok', FALSE, 'erreur', 'Le nouveau PIN doit être différent de l''ancien.');
  END IF;

  -- 5. Hacher et enregistrer
  v_nouveau_hash := ENCODE(DIGEST(p_nouveau_pin, 'sha256'), 'hex');
  v_gests := jsonb_set(v_gests, ARRAY[v_idx::TEXT, 'pin'], to_jsonb(v_nouveau_hash));
  v_tontine := jsonb_set(v_tontine, '{gestionnaires}', v_gests);

  UPDATE public.tontines
     SET data = v_tontine, updated_at = NOW()
   WHERE code = p_code;

  -- 6. Audit (jamais le PIN)
  INSERT INTO public.audit_securite
    (tontine_code, gest_nom, action, description, resultat)
  VALUES
    (p_code, p_nom, 'pin_change',
     'Modification du PIN de gestion depuis une session active.', 'succes');

  RETURN jsonb_build_object('ok', TRUE, 'message', 'PIN modifié avec succès.');
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- F5. enregistrer_email_log(p_destinataire, p_type, p_sujet, p_code, p_gest_nom, p_statut, p_motif)
--     Insère une entrée dans email_logs. Retourne l'UUID du log.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.enregistrer_email_log(
  p_destinataire TEXT,
  p_type_email   TEXT,
  p_sujet        TEXT,
  p_tontine_code TEXT DEFAULT NULL,
  p_gest_nom     TEXT DEFAULT NULL,
  p_statut       TEXT DEFAULT 'pending',
  p_motif_echec  TEXT DEFAULT NULL,
  p_metadata     JSONB DEFAULT '{}'::jsonb
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_id UUID;
BEGIN
  INSERT INTO public.email_logs
    (destinataire, type_email, sujet, tontine_code, gest_nom, statut, motif_echec, metadata,
     envoye_le, tentatives)
  VALUES
    (p_destinataire, p_type_email, p_sujet, p_tontine_code, p_gest_nom,
     p_statut, p_motif_echec, COALESCE(p_metadata, '{}'::jsonb),
     CASE WHEN p_statut = 'envoye' THEN NOW() ELSE NULL END,
     CASE WHEN p_statut = 'envoye' THEN 1 ELSE 0 END)
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- F6. maj_email_log(p_id, p_statut, p_motif)
--     Met à jour le statut d'un email_log après envoi.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.maj_email_log(
  p_id      UUID,
  p_statut  TEXT,
  p_motif   TEXT DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  UPDATE public.email_logs
     SET statut      = p_statut,
         motif_echec = p_motif,
         tentatives  = tentatives + 1,
         envoye_le   = CASE WHEN p_statut = 'envoye' THEN NOW() ELSE envoye_le END
   WHERE id = p_id;
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- F7. admin_email_logs(p_cle, p_limit, p_offset, p_statut, p_type)
--     Liste l'historique e-mails pour l'admin.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_email_logs(
  p_cle    TEXT,
  p_limit  INT     DEFAULT 50,
  p_offset INT     DEFAULT 0,
  p_statut TEXT    DEFAULT NULL,
  p_type   TEXT    DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_config JSONB;
  v_cle_ok BOOLEAN := FALSE;
BEGIN
  -- Vérifier la clé admin (même mécanisme que les autres fonctions admin)
  SELECT config INTO v_config FROM public.app_config WHERE id = 1 LIMIT 1;
  IF v_config IS NOT NULL THEN
    v_cle_ok := (v_config->>'cle_admin' = p_cle);
  END IF;
  IF NOT v_cle_ok THEN
    RETURN jsonb_build_object('ok', FALSE, 'erreur', 'Clé admin invalide.');
  END IF;

  RETURN (
    SELECT jsonb_build_object(
      'ok',    TRUE,
      'total', COUNT(*) OVER (),
      'logs',  COALESCE(
        jsonb_agg(
          jsonb_build_object(
            'id',           id,
            'destinataire', destinataire,
            'type_email',   type_email,
            'sujet',        sujet,
            'tontine_code', tontine_code,
            'gest_nom',     gest_nom,
            'statut',       statut,
            'motif_echec',  motif_echec,
            'tentatives',   tentatives,
            'envoye_le',    envoye_le,
            'cree_le',      cree_le
          ) ORDER BY cree_le DESC
        ),
        '[]'::jsonb
      )
    )
    FROM public.email_logs
    WHERE (p_statut IS NULL OR statut = p_statut)
      AND (p_type IS NULL OR type_email = p_type)
    LIMIT p_limit OFFSET p_offset
  );
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- F8. admin_relancer_email(p_cle, p_email_id)
--     Marque un email échoué comme 'pending' pour relance.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_relancer_email(
  p_cle      TEXT,
  p_email_id UUID
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_config JSONB;
  v_cle_ok BOOLEAN := FALSE;
BEGIN
  SELECT config INTO v_config FROM public.app_config WHERE id = 1 LIMIT 1;
  IF v_config IS NOT NULL THEN
    v_cle_ok := (v_config->>'cle_admin' = p_cle);
  END IF;
  IF NOT v_cle_ok THEN
    RETURN jsonb_build_object('ok', FALSE, 'erreur', 'Clé admin invalide.');
  END IF;

  UPDATE public.email_logs
     SET statut = 'pending', motif_echec = NULL
   WHERE id = p_email_id AND statut = 'echoue';

  RETURN jsonb_build_object('ok', TRUE);
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- Nettoyage automatique : codes PIN expirés > 24h
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.purger_codes_pin_expires()
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  DELETE FROM public.pin_reset_codes
   WHERE expire_at < NOW() - INTERVAL '24 hours';
END;
$$;

-- Note : Configurer pg_cron si disponible :
-- SELECT cron.schedule('purge-pin-codes', '0 * * * *', 'SELECT purger_codes_pin_expires()');

-- ═══════════════════════════════════════════════════════════════════════════
-- Fin de migration
-- ═══════════════════════════════════════════════════════════════════════════
