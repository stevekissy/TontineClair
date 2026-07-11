-- ============================================================
-- TontineClair — Migration v7
-- Corrections : bénéficiaire + demandes_premium + refus
-- À exécuter dans Supabase SQL Editor
-- ============================================================

-- ============================================================
-- SECTION 1 : Ajouter colonnes manquantes à demandes_premium
-- ============================================================

-- Ajout de la colonne formule (si absente)
alter table demandes_premium
  add column if not exists formule text not null default 'mensuel';

-- Ajout de la colonne nom (gestionnaire complet, alias)
alter table demandes_premium
  add column if not exists nom text;

-- Ajout colonne statut refusée (mise à jour du check constraint)
-- On recrée le constraint pour inclure 'refusée'
alter table demandes_premium
  drop constraint if exists demandes_premium_statut_check;

alter table demandes_premium
  add constraint demandes_premium_statut_check
  check (statut in ('en attente', 'en_attente', 'activée', 'refusée', 'active', 'refuse'));

-- ============================================================
-- SECTION 2 : RPC demander_premium — avec formule + contact
-- ============================================================

create or replace function demander_premium(
  p_code    text,
  p_nom     text,
  p_pin     text,
  p_contact text default null,
  p_formule text default 'mensuel'
)
returns boolean
language plpgsql
security definer
as $$
declare
  v_code text := upper(trim(p_code));
begin
  -- Insérer ou remplacer la demande
  insert into demandes_premium (code, gestionnaire, nom, contact, formule, statut, quand)
  values (v_code, p_nom, p_nom, p_contact, p_formule, 'en attente', now())
  on conflict (code) do update
    set gestionnaire = excluded.gestionnaire,
        nom          = excluded.nom,
        contact      = excluded.contact,
        formule      = excluded.formule,
        statut       = 'en attente',
        quand        = now();
  return true;
exception when others then
  return false;
end;
$$;

-- Ajouter un index unique sur code pour le ON CONFLICT
create unique index if not exists idx_demandes_premium_code
  on demandes_premium(code);

-- ============================================================
-- SECTION 3 : RPC admin_lister_demandes — retourne toutes les infos
-- ============================================================

create or replace function admin_lister_demandes(p_cle text)
returns jsonb
language plpgsql
security definer
as $$
declare
  v_cle_attendue text := 'tontine2024admin';
begin
  if p_cle != v_cle_attendue then
    raise exception 'Clé invalide';
  end if;

  return (
    select coalesce(jsonb_agg(
      jsonb_build_object(
        'id',          d.id,
        'code',        d.code,
        'gestionnaire', coalesce(d.nom, d.gestionnaire, ''),
        'nom',         coalesce(d.nom, d.gestionnaire, ''),
        'contact',     coalesce(d.contact, ''),
        'formule',     coalesce(d.formule, 'mensuel'),
        'statut',      d.statut,
        'quand',       d.quand,
        -- Infos tontine depuis la table tontines
        'nom_tontine', coalesce(t.data->>'nom', d.code),
        'nb_membres',  coalesce(jsonb_array_length(t.data->'membres'), 0)
      )
      order by d.quand desc
    ), '[]'::jsonb)
    from demandes_premium d
    left join tontines t on upper(t.code) = upper(d.code)
  );
end;
$$;

-- ============================================================
-- SECTION 4 : RPC admin_refuser_demande
-- ============================================================

create or replace function admin_refuser_demande(
  p_cle  text,
  p_code text
)
returns boolean
language plpgsql
security definer
as $$
declare
  v_cle_attendue text := 'tontine2024admin';
  v_code text := upper(trim(p_code));
begin
  if p_cle != v_cle_attendue then
    raise exception 'Clé invalide';
  end if;

  update demandes_premium
    set statut = 'refusée',
        quand  = now()
  where upper(code) = v_code
    and statut in ('en attente', 'en_attente');

  return found;
end;
$$;

-- ============================================================
-- SECTION 5 : Fix bénéficiaire — recalcul ordre[] pour
--             les anciennes tontines dont ordre est vide
-- ============================================================
-- Cette fonction recalcule l'ordre de passage à partir des
-- membres existants (ordre alphabétique du nom) et définit
-- tourActuel = 0 si non défini.
-- Elle ne modifie PAS les tontines qui ont déjà un ordre valide.

create or replace function fix_beneficiaire_anciennes_tontines()
returns jsonb
language plpgsql
security definer
as $$
declare
  v_rec         record;
  v_data        jsonb;
  v_membres     jsonb;
  v_ordre       jsonb;
  v_nb_membres  int;
  v_tour        int;
  v_fixed       int := 0;
  v_skipped     int := 0;
  v_ids         jsonb;
begin
  for v_rec in
    select code, data
    from tontines
    where
      -- Tontines sans ordre OU avec ordre vide
      (data->'ordre' is null
       or jsonb_array_length(coalesce(data->'ordre', '[]'::jsonb)) = 0)
      -- Pas encore terminées
      and (data->>'cycleTermine' is null or data->>'cycleTermine' = 'false')
  loop
    v_data    := v_rec.data;
    v_membres := coalesce(v_data->'membres', '[]'::jsonb);
    v_nb_membres := jsonb_array_length(v_membres);

    -- Ignorer les tontines sans membres
    if v_nb_membres = 0 then
      v_skipped := v_skipped + 1;
      continue;
    end if;

    -- Construire l'ordre = liste des IDs dans l'ordre actuel des membres
    -- (conserve l'ordre d'inscription sans le modifier)
    v_ids := '[]'::jsonb;
    for i in 0..(v_nb_membres - 1) loop
      v_ids := v_ids || jsonb_build_array(v_membres->i->>'id');
    end loop;

    -- tourActuel : garder la valeur existante, sinon 0
    v_tour := coalesce((v_data->>'tourActuel')::int, 0);
    -- Clamp : ne pas dépasser nb_membres - 1
    if v_tour >= v_nb_membres then
      v_tour := 0;
    end if;

    -- Mettre à jour la tontine
    update tontines
    set data = data
               || jsonb_build_object('ordre', v_ids)
               || jsonb_build_object('tourActuel', v_tour)
               || jsonb_build_object('cycleTermine', false)
    where code = v_rec.code;

    v_fixed := v_fixed + 1;
  end loop;

  return jsonb_build_object(
    'fixees',   v_fixed,
    'ignorees', v_skipped,
    'message',  v_fixed || ' tontine(s) corrigée(s), ' || v_skipped || ' ignorée(s).'
  );
end;
$$;

-- Exécuter immédiatement la correction
select fix_beneficiaire_anciennes_tontines();

-- ============================================================
-- SECTION 6 : Permissions
-- ============================================================

grant execute on function demander_premium(text,text,text,text,text) to anon;
grant execute on function admin_lister_demandes(text)                 to anon;
grant execute on function admin_refuser_demande(text,text)            to anon;
grant execute on function fix_beneficiaire_anciennes_tontines()       to anon;

-- RLS : autoriser l'insert + update sur demandes_premium
drop policy if exists "demandes_premium_insert" on demandes_premium;
create policy "demandes_premium_insert"
  on demandes_premium for insert to anon with check (true);

drop policy if exists "demandes_premium_update" on demandes_premium;
create policy "demandes_premium_update"
  on demandes_premium for update to anon using (true);

drop policy if exists "demandes_premium_select" on demandes_premium;
create policy "demandes_premium_select"
  on demandes_premium for select to anon using (true);
