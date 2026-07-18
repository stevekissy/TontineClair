-- ═══════════════════════════════════════════════════════════════════════════
-- TontineClair — Migration KYC Smile ID
-- Fichier : kyc_verifications.sql
-- À exécuter dans : Supabase → SQL Editor
-- ═══════════════════════════════════════════════════════════════════════════

-- ── 1. Enum des statuts KYC ───────────────────────────────────────────────
DO $$ BEGIN
  CREATE TYPE kyc_status AS ENUM (
    'not_started',
    'pending',
    'processing',
    'verified',
    'rejected',
    'manual_review'
  );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- ── 2. Enum des types de document ────────────────────────────────────────
DO $$ BEGIN
  CREATE TYPE kyc_document_type AS ENUM (
    'national_id',
    'passport',
    'drivers_license',
    'residence_permit',
    'voter_id'
  );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- ── 3. Table principale kyc_verifications ─────────────────────────────────
CREATE TABLE IF NOT EXISTS kyc_verifications (
  id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id                 TEXT NOT NULL,           -- nom gestionnaire (clé métier TontineClair)
  provider                TEXT NOT NULL DEFAULT 'mock',  -- 'mock' | 'smile_id'
  provider_reference      TEXT,                    -- ID retourné par Smile ID
  status                  kyc_status NOT NULL DEFAULT 'not_started',

  -- Données document
  document_type           kyc_document_type,
  document_country        TEXT,                    -- Code ISO 3166-1 alpha-2 (ex: 'CI', 'SN')
  document_number_masked  TEXT,                    -- Numéro masqué : ****1234

  -- Résultat
  rejection_reason        TEXT,
  rejection_code          TEXT,                    -- Code technique Smile ID
  confidence_score        NUMERIC(5,2),            -- Score de confiance 0.00–100.00
  review_notes            TEXT,                    -- Notes admin pour révision manuelle

  -- Données personnelles chiffrées (stockées de façon sécurisée)
  full_name               TEXT,
  date_of_birth           DATE,

  -- Consentement RGPD
  consent_given           BOOLEAN NOT NULL DEFAULT FALSE,
  consent_given_at        TIMESTAMPTZ,

  -- Timestamps
  submitted_at            TIMESTAMPTZ,
  verified_at             TIMESTAMPTZ,
  expires_at              TIMESTAMPTZ,             -- Expiration vérification (1 an)
  created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at              TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ── 4. Index ─────────────────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_kyc_user_id
  ON kyc_verifications(user_id);
CREATE INDEX IF NOT EXISTS idx_kyc_status
  ON kyc_verifications(status);
CREATE INDEX IF NOT EXISTS idx_kyc_provider_ref
  ON kyc_verifications(provider_reference)
  WHERE provider_reference IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_kyc_submitted_at
  ON kyc_verifications(submitted_at DESC)
  WHERE submitted_at IS NOT NULL;

-- ── 5. Trigger updated_at ─────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS kyc_verifications_updated_at ON kyc_verifications;
CREATE TRIGGER kyc_verifications_updated_at
  BEFORE UPDATE ON kyc_verifications
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ── 6. Table journal d'audit KYC ─────────────────────────────────────────
CREATE TABLE IF NOT EXISTS kyc_audit_log (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  kyc_id          UUID REFERENCES kyc_verifications(id) ON DELETE CASCADE,
  user_id         TEXT NOT NULL,
  action          TEXT NOT NULL,    -- 'submitted' | 'status_changed' | 'admin_review' | 'reset_requested'
  old_status      kyc_status,
  new_status      kyc_status,
  performed_by    TEXT NOT NULL,    -- 'system' | 'webhook' | 'admin:NOM'
  notes           TEXT,
  metadata        JSONB,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_kyc_audit_kyc_id
  ON kyc_audit_log(kyc_id);
CREATE INDEX IF NOT EXISTS idx_kyc_audit_user_id
  ON kyc_audit_log(user_id);

-- ── 7. Table stockage temporaire fichiers KYC ────────────────────────────
-- Les fichiers images sont supprimés après vérification (politique de rétention)
CREATE TABLE IF NOT EXISTS kyc_files (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  kyc_id          UUID REFERENCES kyc_verifications(id) ON DELETE CASCADE,
  user_id         TEXT NOT NULL,
  file_type       TEXT NOT NULL,    -- 'doc_front' | 'doc_back' | 'selfie'
  storage_path    TEXT NOT NULL,    -- chemin dans Supabase Storage (bucket: kyc-documents)
  uploaded_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  deleted_at      TIMESTAMPTZ,      -- null = fichier encore présent
  expires_at      TIMESTAMPTZ NOT NULL DEFAULT (NOW() + INTERVAL '30 days')
);

CREATE INDEX IF NOT EXISTS idx_kyc_files_kyc_id
  ON kyc_files(kyc_id);
CREATE INDEX IF NOT EXISTS idx_kyc_files_expires
  ON kyc_files(expires_at)
  WHERE deleted_at IS NULL;

-- ── 8. Activer Row Level Security ────────────────────────────────────────
ALTER TABLE kyc_verifications ENABLE ROW LEVEL SECURITY;
ALTER TABLE kyc_audit_log     ENABLE ROW LEVEL SECURITY;
ALTER TABLE kyc_files         ENABLE ROW LEVEL SECURITY;

-- ── 9. Politiques RLS — kyc_verifications ────────────────────────────────

-- Un utilisateur voit UNIQUEMENT son propre statut KYC
-- (user_id = nom du gestionnaire passé en paramètre de session)
CREATE POLICY "kyc_user_select_own"
  ON kyc_verifications FOR SELECT
  USING (user_id = current_setting('request.jwt.claims', true)::jsonb->>'sub'
         OR user_id = current_setting('app.current_user', true));

-- Un utilisateur peut insérer une entrée pour lui-même
CREATE POLICY "kyc_user_insert_own"
  ON kyc_verifications FOR INSERT
  WITH CHECK (user_id = current_setting('app.current_user', true));

-- Un utilisateur peut mettre à jour uniquement si statut not_started ou rejected
CREATE POLICY "kyc_user_update_own"
  ON kyc_verifications FOR UPDATE
  USING (
    user_id = current_setting('app.current_user', true)
    AND status IN ('not_started', 'rejected')
  );

-- Les Edge Functions (service_role) ont accès complet
CREATE POLICY "kyc_service_role_all"
  ON kyc_verifications FOR ALL
  USING (current_setting('role') = 'service_role');

-- ── 10. Politiques RLS — kyc_audit_log ───────────────────────────────────

-- Un utilisateur voit son propre journal
CREATE POLICY "kyc_audit_user_select"
  ON kyc_audit_log FOR SELECT
  USING (user_id = current_setting('app.current_user', true));

-- Seul service_role peut insérer dans l'audit
CREATE POLICY "kyc_audit_service_role_insert"
  ON kyc_audit_log FOR INSERT
  WITH CHECK (current_setting('role') = 'service_role');

-- ── 11. Politiques RLS — kyc_files ───────────────────────────────────────

CREATE POLICY "kyc_files_user_select"
  ON kyc_files FOR SELECT
  USING (user_id = current_setting('app.current_user', true));

CREATE POLICY "kyc_files_service_role_all"
  ON kyc_files FOR ALL
  USING (current_setting('role') = 'service_role');

-- ── 12. Fonctions utilitaires ─────────────────────────────────────────────

-- Obtenir le statut KYC d'un utilisateur (appelée par l'app)
CREATE OR REPLACE FUNCTION get_kyc_status(p_user_id TEXT)
RETURNS TABLE(
  id               UUID,
  status           kyc_status,
  document_type    kyc_document_type,
  document_country TEXT,
  rejection_reason TEXT,
  submitted_at     TIMESTAMPTZ,
  verified_at      TIMESTAMPTZ,
  expires_at       TIMESTAMPTZ,
  updated_at       TIMESTAMPTZ
)
LANGUAGE sql SECURITY DEFINER AS $$
  SELECT
    id, status, document_type, document_country,
    rejection_reason, submitted_at, verified_at, expires_at, updated_at
  FROM kyc_verifications
  WHERE user_id = p_user_id
  ORDER BY created_at DESC
  LIMIT 1;
$$;

-- Vérifier si un utilisateur peut réaliser une action financière
CREATE OR REPLACE FUNCTION can_perform_financial_action(
  p_user_id   TEXT,
  p_action    TEXT,     -- 'withdrawal' | 'disbursement' | 'loan' | 'large_transfer'
  p_amount    NUMERIC   -- montant en XOF
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_kyc         kyc_verifications%ROWTYPE;
  v_threshold   NUMERIC := 50000; -- seuil KYC obligatoire : 50 000 XOF
  v_result      JSONB;
BEGIN
  -- Récupérer le statut KYC le plus récent
  SELECT * INTO v_kyc
  FROM kyc_verifications
  WHERE user_id = p_user_id
  ORDER BY created_at DESC
  LIMIT 1;

  -- Si vérifié et non expiré → autoriser
  IF v_kyc.status = 'verified' AND (v_kyc.expires_at IS NULL OR v_kyc.expires_at > NOW()) THEN
    RETURN jsonb_build_object('allowed', true, 'kyc_status', 'verified');
  END IF;

  -- Si montant < seuil et pas premier décaissement → autoriser sans KYC
  IF p_amount < v_threshold AND p_action NOT IN ('withdrawal', 'disbursement') THEN
    RETURN jsonb_build_object('allowed', true, 'kyc_status', COALESCE(v_kyc.status::TEXT, 'not_started'));
  END IF;

  -- KYC requis
  v_result := jsonb_build_object(
    'allowed',      false,
    'kyc_status',   COALESCE(v_kyc.status::TEXT, 'not_started'),
    'reason',       CASE COALESCE(v_kyc.status::TEXT, 'not_started')
                      WHEN 'not_started' THEN 'Veuillez vérifier votre identité avant cette action.'
                      WHEN 'pending'     THEN 'Votre vérification est en cours. Patientez quelques instants.'
                      WHEN 'processing'  THEN 'Votre dossier est en cours d''analyse par notre équipe.'
                      WHEN 'rejected'    THEN 'Votre vérification a été refusée. Veuillez recommencer.'
                      WHEN 'manual_review' THEN 'Votre dossier nécessite une vérification manuelle. Contactez le support.'
                      ELSE 'Vérification d''identité requise.'
                    END
  );

  RETURN v_result;
END;
$$;

-- Statistiques KYC pour l'admin
CREATE OR REPLACE FUNCTION admin_kyc_stats(p_cle TEXT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_cle TEXT;
  v_result JSONB;
BEGIN
  -- Vérifier clé admin (réutilise le pattern existant de TontineClair)
  SELECT cle_admin INTO v_cle FROM parametres_globaux LIMIT 1;
  IF v_cle IS NULL OR p_cle != v_cle THEN
    RAISE EXCEPTION 'ACCES_REFUSE';
  END IF;

  SELECT jsonb_build_object(
    'total',          COUNT(*),
    'not_started',    COUNT(*) FILTER (WHERE status = 'not_started'),
    'pending',        COUNT(*) FILTER (WHERE status = 'pending'),
    'processing',     COUNT(*) FILTER (WHERE status = 'processing'),
    'verified',       COUNT(*) FILTER (WHERE status = 'verified'),
    'rejected',       COUNT(*) FILTER (WHERE status = 'rejected'),
    'manual_review',  COUNT(*) FILTER (WHERE status = 'manual_review')
  ) INTO v_result
  FROM kyc_verifications;

  RETURN v_result;
END;
$$;

-- Lister les KYC pour l'admin avec pagination
CREATE OR REPLACE FUNCTION admin_kyc_list(
  p_cle     TEXT,
  p_status  TEXT  DEFAULT 'tous',
  p_limit   INT   DEFAULT 50,
  p_offset  INT   DEFAULT 0
)
RETURNS TABLE(
  id               UUID,
  user_id          TEXT,
  provider         TEXT,
  status           kyc_status,
  document_type    kyc_document_type,
  document_country TEXT,
  rejection_reason TEXT,
  review_notes     TEXT,
  submitted_at     TIMESTAMPTZ,
  verified_at      TIMESTAMPTZ,
  updated_at       TIMESTAMPTZ
)
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_cle TEXT;
BEGIN
  SELECT cle_admin INTO v_cle FROM parametres_globaux LIMIT 1;
  IF v_cle IS NULL OR p_cle != v_cle THEN
    RAISE EXCEPTION 'ACCES_REFUSE';
  END IF;

  RETURN QUERY
  SELECT
    k.id, k.user_id, k.provider, k.status,
    k.document_type, k.document_country,
    k.rejection_reason, k.review_notes,
    k.submitted_at, k.verified_at, k.updated_at
  FROM kyc_verifications k
  WHERE (p_status = 'tous' OR k.status::TEXT = p_status)
  ORDER BY k.updated_at DESC
  LIMIT p_limit OFFSET p_offset;
END;
$$;

-- Admin : demander à un utilisateur de recommencer son KYC
CREATE OR REPLACE FUNCTION admin_kyc_request_reset(
  p_cle       TEXT,
  p_kyc_id    UUID,
  p_reason    TEXT,
  p_admin_nom TEXT
)
RETURNS BOOLEAN
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_cle     TEXT;
  v_old_st  kyc_status;
BEGIN
  SELECT cle_admin INTO v_cle FROM parametres_globaux LIMIT 1;
  IF v_cle IS NULL OR p_cle != v_cle THEN RAISE EXCEPTION 'ACCES_REFUSE'; END IF;

  -- Récupérer l'ancien statut
  SELECT status INTO v_old_st FROM kyc_verifications WHERE id = p_kyc_id;
  IF NOT FOUND THEN RETURN FALSE; END IF;

  -- Mettre à jour le statut
  UPDATE kyc_verifications
  SET status = 'rejected',
      rejection_reason = p_reason,
      review_notes = 'Réinitialisation demandée par admin: ' || p_admin_nom
  WHERE id = p_kyc_id;

  -- Journaliser l'action admin
  INSERT INTO kyc_audit_log(kyc_id, user_id, action, old_status, new_status, performed_by, notes)
  SELECT p_kyc_id, user_id, 'reset_requested', v_old_st, 'rejected',
         'admin:' || p_admin_nom, p_reason
  FROM kyc_verifications WHERE id = p_kyc_id;

  RETURN TRUE;
END;
$$;

-- ── 13. Politique de rétention — supprimer les fichiers expirés ───────────
-- À appeler via un Cron Job Supabase toutes les 24h
CREATE OR REPLACE FUNCTION purge_expired_kyc_files()
RETURNS INT
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_count INT;
BEGIN
  UPDATE kyc_files
  SET deleted_at = NOW()
  WHERE expires_at < NOW() AND deleted_at IS NULL;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

-- ── 14. Commentaires ─────────────────────────────────────────────────────
COMMENT ON TABLE kyc_verifications IS 'Vérifications KYC des utilisateurs TontineClair via Smile ID';
COMMENT ON TABLE kyc_audit_log     IS 'Journal immuable des actions KYC (admin + système)';
COMMENT ON TABLE kyc_files         IS 'Références fichiers KYC avec politique de rétention 30j';
COMMENT ON COLUMN kyc_verifications.user_id IS 'Nom du gestionnaire (clé métier TontineClair — identique à gestionnaire dans tontines)';
COMMENT ON COLUMN kyc_verifications.document_number_masked IS 'Numéro masqué pour affichage — jamais le numéro complet';
