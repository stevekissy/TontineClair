-- ─── Migration 002 : Maintenance tokens FCM ─────────────────────────────────
-- Ajoute une procédure de nettoyage automatique des tokens expirés.
-- Un token non mis à jour depuis 90 jours est considéré périmé.
-- ─────────────────────────────────────────────────────────────────────────────

-- S'assurer que la colonne mis_a_jour_le est bien présente (idempotent)
ALTER TABLE public.fcm_tokens
  ADD COLUMN IF NOT EXISTS mis_a_jour_le timestamptz DEFAULT now();

-- Index sur mis_a_jour_le pour la purge rapide
CREATE INDEX IF NOT EXISTS idx_fcm_tokens_mis_a_jour
  ON public.fcm_tokens(mis_a_jour_le);

-- ─── RPC : nettoyer_tokens_perimes ───────────────────────────────────────────
-- Supprime les tokens non rafraîchis depuis plus de p_jours jours (défaut 90).
-- Appelable depuis le dashboard Supabase ou depuis l'Edge Function envoyer_notification.
CREATE OR REPLACE FUNCTION public.nettoyer_tokens_perimes(
  p_jours integer DEFAULT 90
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  nb_supprimes integer;
BEGIN
  DELETE FROM public.fcm_tokens
  WHERE mis_a_jour_le < now() - (p_jours || ' days')::interval;
  
  GET DIAGNOSTICS nb_supprimes = ROW_COUNT;
  RETURN nb_supprimes;
END;
$$;

-- ─── RPC : sauvegarder_token (mise à jour pour rafraîchir mis_a_jour_le) ─────
-- Remplace la version de 001 pour s'assurer que mis_a_jour_le est mis à jour.
CREATE OR REPLACE FUNCTION public.sauvegarder_token(
  p_code     text,
  p_token    text,
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
    mis_a_jour_le = now();   -- ← rafraîchit la date à chaque abonnement
  RETURN true;
EXCEPTION WHEN OTHERS THEN
  RETURN false;
END;
$$;

-- ─── Vue diagnostic : tokens actifs par tontine ───────────────────────────────
-- Utile pour vérifier le nombre d'appareils enregistrés par tontine.
CREATE OR REPLACE VIEW public.v_fcm_tokens_actifs AS
SELECT
  tontine_code,
  count(*)                                          AS nb_appareils,
  max(mis_a_jour_le)                                AS dernier_enregistrement,
  count(*) FILTER (
    WHERE mis_a_jour_le > now() - interval '7 days'
  )                                                 AS actifs_7j,
  count(*) FILTER (
    WHERE mis_a_jour_le > now() - interval '30 days'
  )                                                 AS actifs_30j
FROM public.fcm_tokens
GROUP BY tontine_code
ORDER BY nb_appareils DESC;
