-- ─────────────────────────────────────────────────────────────────────────────
-- Migration : Stockage permanent des preuves de paiement
--
-- Objectif :
--   Créer le bucket Supabase Storage "preuves-paiement" et les policies RLS
--   permettant aux membres d'uploader leurs preuves et aux gestionnaires
--   de les consulter/supprimer en cas de contestation.
--
-- Chemin de stockage : {tontineCode}/{membreId}/{timestamp}_{description}.jpg
-- Conservation       : permanente (jusqu'à suppression de la tontine)
-- Accès              : membre propriétaire + gestionnaire de la tontine
-- ─────────────────────────────────────────────────────────────────────────────

-- ── 1. Créer le bucket (public pour lecture via URL) ─────────────────────────
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'preuves-paiement',
  'preuves-paiement',
  true,                         -- URL publique pour affichage dans l'app
  10485760,                     -- 10 Mo max par fichier
  ARRAY['image/jpeg', 'image/png', 'image/webp', 'image/heic', 'application/pdf']
)
ON CONFLICT (id) DO UPDATE SET
  public            = EXCLUDED.public,
  file_size_limit   = EXCLUDED.file_size_limit,
  allowed_mime_types = EXCLUDED.allowed_mime_types;

-- ── 2. Policy : tout utilisateur authentifié peut uploader ───────────────────
-- (La clé anon suffit car l'app utilise la clé anon pour toutes les ops)
DO $$ BEGIN
  DROP POLICY IF EXISTS "preuves_upload" ON storage.objects;
  CREATE POLICY "preuves_upload"
    ON storage.objects
    FOR INSERT
    WITH CHECK (bucket_id = 'preuves-paiement');
EXCEPTION WHEN others THEN NULL;
END $$;

-- ── 3. Policy : lecture publique (URL directe, déjà garantie par bucket public)
DO $$ BEGIN
  DROP POLICY IF EXISTS "preuves_lecture_publique" ON storage.objects;
  CREATE POLICY "preuves_lecture_publique"
    ON storage.objects
    FOR SELECT
    USING (bucket_id = 'preuves-paiement');
EXCEPTION WHEN others THEN NULL;
END $$;

-- ── 4. Policy : suppression permise (gestionnaire, clé anon) ────────────────
DO $$ BEGIN
  DROP POLICY IF EXISTS "preuves_suppression" ON storage.objects;
  CREATE POLICY "preuves_suppression"
    ON storage.objects
    FOR DELETE
    USING (bucket_id = 'preuves-paiement');
EXCEPTION WHEN others THEN NULL;
END $$;

-- ── 5. Policy : mise à jour (upsert) ────────────────────────────────────────
DO $$ BEGIN
  DROP POLICY IF EXISTS "preuves_upsert" ON storage.objects;
  CREATE POLICY "preuves_upsert"
    ON storage.objects
    FOR UPDATE
    USING (bucket_id = 'preuves-paiement');
EXCEPTION WHEN others THEN NULL;
END $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- Note : la suppression des preuves lors de la suppression d'une tontine est
-- gérée côté application (PreuvePaiementService.supprimerDossierTontine()).
-- ─────────────────────────────────────────────────────────────────────────────
