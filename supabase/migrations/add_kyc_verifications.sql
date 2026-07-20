-- ═══════════════════════════════════════════════════════════════════════════
-- TontineClair — KYC Verifications (Smile ID)
--
-- Table : public.kyc_verifications
-- RPCs  : get_kyc_status, upsert_kyc_verification, update_kyc_status,
--         set_kyc_provider_reference, reset_kyc_status,
--         kyc_audit_log, get_kyc_admin_stats, list_kyc_verifications
--
-- Règle métier : KYC obligatoire pour TOUT compte Premium.
-- Compte Gratuit → aucun KYC requis.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── 1. Table principale ───────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.kyc_verifications (
  id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id                 TEXT NOT NULL,
  provider                TEXT NOT NULL DEFAULT 'smile_id',
  provider_reference      TEXT,
  status                  TEXT NOT NULL DEFAULT 'not_started'
                            CHECK (status IN (
                              'not_started','pending','processing',
                              'verified','rejected','manual_review')),
  document_type           TEXT,
  document_country        TEXT,
  document_number_masked  TEXT,
  rejection_reason        TEXT,
  submitted_at            TIMESTAMPTZ,
  verified_at             TIMESTAMPTZ,
  expires_at              TIMESTAMPTZ,
  updated_at              TIMESTAMPTZ DEFAULT NOW(),
  created_at              TIMESTAMPTZ DEFAULT NOW(),
  raw_result              JSONB DEFAULT '{}'::JSONB
);

-- Index unicité : 1 entrée par user_id (upsert)
CREATE UNIQUE INDEX IF NOT EXISTS kyc_verifications_user_id_unique
  ON public.kyc_verifications (user_id);

-- Index performance
CREATE INDEX IF NOT EXISTS kyc_verifications_status_idx
  ON public.kyc_verifications (status);

CREATE INDEX IF NOT EXISTS kyc_verifications_updated_idx
  ON public.kyc_verifications (updated_at DESC);

-- ── 2. Table audit log KYC ────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.kyc_audit_log (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  kyc_id       UUID REFERENCES public.kyc_verifications(id) ON DELETE SET NULL,
  user_id      TEXT NOT NULL,
  action       TEXT NOT NULL,
  old_status   TEXT,
  new_status   TEXT,
  performed_by TEXT DEFAULT 'system',
  details      JSONB DEFAULT '{}'::JSONB,
  created_at   TIMESTAMPTZ DEFAULT NOW()
);

-- ── 3. RPC : get_kyc_status ───────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.get_kyc_status(p_user_id TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_row kyc_verifications%ROWTYPE;
BEGIN
  SELECT * INTO v_row
  FROM   public.kyc_verifications
  WHERE  user_id = p_user_id
  LIMIT  1;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  RETURN jsonb_build_object(
    'id',                     v_row.id,
    'user_id',                v_row.user_id,
    'provider',               v_row.provider,
    'provider_reference',     v_row.provider_reference,
    'status',                 v_row.status,
    'document_type',          v_row.document_type,
    'document_country',       v_row.document_country,
    'document_number_masked', v_row.document_number_masked,
    'rejection_reason',       v_row.rejection_reason,
    'submitted_at',           v_row.submitted_at,
    'verified_at',            v_row.verified_at,
    'expires_at',             v_row.expires_at,
    'updated_at',             v_row.updated_at,
    'created_at',             v_row.created_at
  );
END;
$$;

-- ── 4. RPC : update_kyc_status (appelé par webhook Smile ID) ─────────────
CREATE OR REPLACE FUNCTION public.update_kyc_status(
  p_user_id      TEXT,
  p_status       TEXT,
  p_verified_at  TIMESTAMPTZ DEFAULT NULL,
  p_expires_at   TIMESTAMPTZ DEFAULT NULL,
  p_rejection    TEXT        DEFAULT NULL,
  p_performed_by TEXT        DEFAULT 'system',
  p_raw_result   JSONB       DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_id         UUID;
  v_old_status TEXT;
BEGIN
  SELECT id, status INTO v_id, v_old_status
  FROM   public.kyc_verifications
  WHERE  user_id = p_user_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', FALSE, 'error', 'KYC entry not found for user_id: ' || p_user_id);
  END IF;

  UPDATE public.kyc_verifications
  SET
    status           = p_status,
    verified_at      = COALESCE(p_verified_at, verified_at),
    expires_at       = COALESCE(p_expires_at,  expires_at),
    rejection_reason = COALESCE(p_rejection,   rejection_reason),
    raw_result       = CASE WHEN p_raw_result IS NOT NULL
                            THEN p_raw_result
                            ELSE raw_result END,
    updated_at       = NOW()
  WHERE id = v_id;

  -- Audit log
  INSERT INTO public.kyc_audit_log
    (kyc_id, user_id, action, old_status, new_status, performed_by)
  VALUES
    (v_id, p_user_id, 'status_update', v_old_status, p_status, p_performed_by);

  RETURN jsonb_build_object('ok', TRUE, 'id', v_id, 'new_status', p_status);
END;
$$;

-- ── 5. RPC : reset_kyc_status ─────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.reset_kyc_status(p_user_id TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  UPDATE public.kyc_verifications
  SET  status     = 'not_started',
       updated_at = NOW()
  WHERE user_id = p_user_id;
  RETURN FOUND;
END;
$$;

-- ── 6. RPC : get_kyc_admin_stats ──────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.get_kyc_admin_stats(p_cle_admin TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  -- Vérification basique de la clé admin (à renforcer si nécessaire)
  IF p_cle_admin IS NULL OR length(p_cle_admin) < 8 THEN
    RETURN jsonb_build_object('error', 'Clé admin invalide');
  END IF;

  RETURN (
    SELECT jsonb_build_object(
      'total',        COUNT(*),
      'not_started',  COUNT(*) FILTER (WHERE status = 'not_started'),
      'pending',      COUNT(*) FILTER (WHERE status = 'pending'),
      'processing',   COUNT(*) FILTER (WHERE status = 'processing'),
      'verified',     COUNT(*) FILTER (WHERE status = 'verified'),
      'rejected',     COUNT(*) FILTER (WHERE status = 'rejected'),
      'manual_review',COUNT(*) FILTER (WHERE status = 'manual_review')
    )
    FROM public.kyc_verifications
  );
END;
$$;

-- ── 7. RPC : list_kyc_verifications (admin) ───────────────────────────────
CREATE OR REPLACE FUNCTION public.list_kyc_verifications(
  p_cle_admin TEXT,
  p_status    TEXT    DEFAULT 'tous',
  p_limit     INTEGER DEFAULT 50,
  p_offset    INTEGER DEFAULT 0
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_rows JSONB;
BEGIN
  IF p_cle_admin IS NULL OR length(p_cle_admin) < 8 THEN
    RETURN jsonb_build_object('error', 'Clé admin invalide');
  END IF;

  SELECT jsonb_agg(row_to_json(r))
  INTO   v_rows
  FROM (
    SELECT id, user_id, provider, status, document_type,
           document_country, document_number_masked,
           submitted_at, verified_at, rejection_reason, updated_at
    FROM   public.kyc_verifications
    WHERE  (p_status = 'tous' OR status = p_status)
    ORDER  BY updated_at DESC
    LIMIT  p_limit OFFSET p_offset
  ) r;

  RETURN COALESCE(v_rows, '[]'::JSONB);
END;
$$;

-- ── 8. RLS : désactiver pour permettre l'accès service_role ──────────────
ALTER TABLE public.kyc_verifications DISABLE ROW LEVEL SECURITY;
ALTER TABLE public.kyc_audit_log     DISABLE ROW LEVEL SECURITY;

-- ── 9. Permissions ────────────────────────────────────────────────────────
GRANT SELECT, INSERT, UPDATE ON public.kyc_verifications TO anon, authenticated;
GRANT SELECT, INSERT          ON public.kyc_audit_log     TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_kyc_status(TEXT)          TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.update_kyc_status(TEXT,TEXT,TIMESTAMPTZ,TIMESTAMPTZ,TEXT,TEXT,JSONB) TO service_role;
GRANT EXECUTE ON FUNCTION public.reset_kyc_status(TEXT)        TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_kyc_admin_stats(TEXT)     TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.list_kyc_verifications(TEXT,TEXT,INTEGER,INTEGER) TO anon, authenticated;
