-- ============================================================
-- FIX SycaPay : fonction ecrire_tontine_sans_pin
-- À exécuter dans Supabase > SQL Editor
-- ============================================================
-- Cette fonction permet d'écrire les données d'une tontine
-- SANS vérification de PIN gestionnaire.
-- Utilisée uniquement après confirmation de paiement SycaPay
-- (cotisations Pro et apports de caisse Pro).
-- ============================================================

CREATE OR REPLACE FUNCTION ecrire_tontine_sans_pin(
  p_code text,
  p_data jsonb
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE tontines
     SET data       = p_data,
         modifie_le = now()
   WHERE code = upper(p_code);

  IF FOUND THEN
    INSERT INTO audit(code, gestionnaire, empreinte)
    VALUES (upper(p_code), 'sycapay', md5(p_data::text));
  END IF;

  RETURN FOUND;
END;
$$;

-- Autoriser la clé anon à appeler cette fonction
GRANT EXECUTE ON FUNCTION ecrire_tontine_sans_pin(text, jsonb) TO anon;
GRANT EXECUTE ON FUNCTION ecrire_tontine_sans_pin(text, jsonb) TO authenticated;
