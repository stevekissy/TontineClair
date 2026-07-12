-- ═══════════════════════════════════════════════════════════════════════════
-- FIX v18 — Correction RPC voter() : validation choix en minuscules
-- ═══════════════════════════════════════════════════════════════════════════
--
-- PROBLÈME :
--   La fonction voter() validait p_choix = 'Oui'/'Non'/'Abstention'
--   (majuscule initiale), mais l'application Flutter envoie
--   'oui'/'non'/'abstention' (tout en minuscules).
--   Résultat : tous les votes retournaient CHOIX_INVALIDE.
--
-- CORRECTION :
--   1. Normaliser p_choix en minuscules dès l'entrée (lower())
--   2. Valider contre 'oui'/'non'/'abstention' (minuscules)
--   3. Stocker le choix normalisé (minuscules) dans la table voix
--
-- ⚠️  EXÉCUTER dans Supabase Dashboard → SQL Editor
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function voter(
  p_code        text,
  p_vote_id     text,
  p_membre_id   text,
  p_pin_membre  text,
  p_choix       text,
  p_appareil    text
)
returns text
language plpgsql security definer set search_path = public
as $$
declare
  v_statut text;
  v_choix  text;
begin
  -- Normaliser le choix en minuscules (accepte 'Oui', 'OUI', 'oui', etc.)
  v_choix := lower(trim(p_choix));

  -- Valider le choix normalisé
  if v_choix not in ('oui', 'non', 'abstention') then
    return 'CHOIX_INVALIDE';
  end if;

  -- Vérifier le PIN du membre
  if not exists (
    select 1 from tontines
     where code = upper(p_code)
       and membres_pins @> jsonb_build_array(
             jsonb_build_object('id', p_membre_id, 'pin', p_pin_membre)
           )
  ) then
    return 'PIN_INCORRECT';
  end if;

  -- Vérifier que le vote existe et est ouvert
  select v->>'statut' into v_statut
    from tontines t, jsonb_array_elements(t.data->'votes') v
   where t.code = upper(p_code)
     and v->>'id' = p_vote_id;

  if v_statut is null then return 'VOTE_INTROUVABLE'; end if;
  if v_statut <> 'ouvert' then return 'VOTE_CLOS'; end if;

  -- Insérer la voix (choix normalisé en minuscules)
  begin
    insert into voix(code, vote_id, membre_id, choix, methode, appareil)
    values (
      upper(p_code),
      p_vote_id,
      p_membre_id,
      v_choix,   -- ← minuscules normalisées
      'PIN',
      left(coalesce(p_appareil, ''), 64)
    );
  exception when unique_violation then
    return 'DEJA_VOTE';
  end;

  -- Audit
  insert into audit(code, gestionnaire, empreinte)
  values (
    upper(p_code),
    'MEMBRE:' || p_membre_id,
    'VOTE:' || p_vote_id || ':' || v_choix
  );

  return 'OK';
end $$;

grant execute on function voter(text, text, text, text, text, text) to anon;

-- ── Vérification ────────────────────────────────────────────────────────────
-- Après exécution, tester avec :
--   select voter('VOTRE_CODE', 'vote_id', 'membre_id', 'pin', 'oui', 'test');
--   → doit retourner 'OK' (ou 'PIN_INCORRECT' si le PIN ne correspond pas)
-- ═══════════════════════════════════════════════════════════════════════════
