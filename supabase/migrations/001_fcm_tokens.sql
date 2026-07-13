-- ─── Table fcm_tokens ────────────────────────────────────────────────────────
-- Stocke les tokens FCM de chaque appareil par tontine.
-- Un même appareil peut être membre de plusieurs tontines.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.fcm_tokens (
  id            uuid DEFAULT gen_random_uuid() PRIMARY KEY,
  tontine_code  text        NOT NULL,
  token         text        NOT NULL,
  appareil      text        DEFAULT 'android',
  cree_le       timestamptz DEFAULT now(),
  mis_a_jour_le timestamptz DEFAULT now(),
  UNIQUE(tontine_code, token)
);

-- Index pour recherche rapide par code tontine
CREATE INDEX IF NOT EXISTS idx_fcm_tokens_tontine_code
  ON public.fcm_tokens(tontine_code);

-- RLS : lecture/écriture libres (tokens non sensibles)
ALTER TABLE public.fcm_tokens ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Accès libre fcm_tokens"
  ON public.fcm_tokens
  FOR ALL
  USING (true)
  WITH CHECK (true);

-- ─── RPC sauvegarder_token ────────────────────────────────────────────────────
-- Appelée par l'app Flutter au démarrage pour enregistrer/mettre à jour le token.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.sauvegarder_token(
  p_code    text,
  p_token   text,
  p_appareil text DEFAULT 'android'
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  INSERT INTO public.fcm_tokens(tontine_code, token, appareil, mis_a_jour_le)
  VALUES (upper(p_code), p_token, p_appareil, now())
  ON CONFLICT (tontine_code, token)
  DO UPDATE SET
    appareil      = EXCLUDED.appareil,
    mis_a_jour_le = now();
  RETURN true;
EXCEPTION WHEN OTHERS THEN
  RETURN false;
END;
$$;
