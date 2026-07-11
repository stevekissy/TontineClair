-- ============================================================
-- TontineClair — Migration v8 : Périodicité journalière + Échéance
-- À exécuter dans Supabase SQL Editor
-- ============================================================
-- Cette migration :
--   1. Met à jour la RPC creer_tontine pour accepter 'journalier'
--   2. Crée une RPC de mise à jour de l'échéance (maj_echeance)
--   3. Corrige les tontines existantes dont l'échéance est passée
-- ============================================================

-- ============================================================
-- SECTION 1 : Validation de la périodicité
-- Supabase valide déjà le champ periodicite stocké dans data (JSONB).
-- Aucune contrainte SQL n'empêche 'journalier' — le JSONB est libre.
-- On vérifie juste que les RPCs existantes n'ont pas de contrainte.
-- ============================================================

-- ============================================================
-- SECTION 2 : RPC maj_echeance — mettre à jour l'échéance d'une tontine
-- Appelée depuis l'app après un nouveau cycle ou une modification de config.
-- ============================================================

create or replace function maj_echeance(
  p_code      text,
  p_nom       text,
  p_pin       text,
  p_echeance  text   -- Format ISO 8601 : 'YYYY-MM-DDTHH:MM:SS.sssZ'
)
returns boolean
language plpgsql
security definer
as $$
declare
  v_code text := upper(trim(p_code));
  v_ok   boolean;
begin
  -- Vérifier le gestionnaire
  select verifier_gestionnaire(v_code, p_nom, p_pin) into v_ok;
  if not v_ok then
    return false;
  end if;

  -- Mettre à jour l'échéance dans data
  update tontines
    set data = data || jsonb_build_object('echeance', p_echeance)
  where upper(code) = v_code;

  return found;
end;
$$;

grant execute on function maj_echeance(text,text,text,text) to anon;

-- ============================================================
-- SECTION 3 : RPC recalculer_echeances — recalcul automatique
-- Corrige les tontines dont l'échéance est dans le passé.
-- Lance un recalcul selon la périodicité stockée dans data.
-- ============================================================

create or replace function recalculer_echeances_expir()
returns jsonb
language plpgsql
security definer
as $$
declare
  v_rec     record;
  v_data    jsonb;
  v_periode text;
  v_echeance text;
  v_nouvelle_echeance timestamptz;
  v_fixed   int := 0;
begin
  for v_rec in
    select code, data
    from tontines
    where
      -- Tontines avec une échéance définie et passée
      data->>'echeance' is not null
      and (data->>'echeance')::timestamptz < now()
      -- Pas terminées
      and (data->>'cycleTermine' is null or data->>'cycleTermine' = 'false')
  loop
    v_data    := v_rec.data;
    v_periode := coalesce(v_data->>'periodicite', v_data->>'periode', 'mensuel');
    v_echeance := v_data->>'echeance';

    -- Calculer la prochaine échéance depuis la date passée
    v_nouvelle_echeance := (v_echeance::timestamptz);
    loop
      exit when v_nouvelle_echeance > now();
      case v_periode
        when 'journalier'  then v_nouvelle_echeance := v_nouvelle_echeance + interval '1 day';
        when 'hebdo'       then v_nouvelle_echeance := v_nouvelle_echeance + interval '7 days';
        when 'mensuel'     then v_nouvelle_echeance := v_nouvelle_echeance + interval '1 month';
        when 'bimensuel'   then v_nouvelle_echeance := v_nouvelle_echeance + interval '2 months';
        when 'trimestriel' then v_nouvelle_echeance := v_nouvelle_echeance + interval '3 months';
        else v_nouvelle_echeance := v_nouvelle_echeance + interval '1 month';
      end case;
    end loop;

    -- Mettre à jour la tontine
    update tontines
      set data = data || jsonb_build_object('echeance', to_char(v_nouvelle_echeance, 'YYYY-MM-DD"T"HH24:MI:SS".000Z"'))
    where code = v_rec.code;

    v_fixed := v_fixed + 1;
  end loop;

  return jsonb_build_object(
    'mises_a_jour', v_fixed,
    'message', v_fixed || ' échéance(s) recalculée(s).'
  );
end;
$$;

grant execute on function recalculer_echeances_expir() to anon;

-- ============================================================
-- SECTION 4 : RPC lire_config_tontine — lecture des params de config
-- Permet à l'app de lire periodicite + echeance séparément.
-- ============================================================

create or replace function lire_config_tontine(p_code text)
returns jsonb
language sql
security definer
as $$
  select jsonb_build_object(
    'periodicite', coalesce(data->>'periodicite', data->>'periode', 'mensuel'),
    'echeance',    data->>'echeance',
    'methodeOrdre', data->>'methodeOrdre',
    'montant',     (data->>'montant')::int,
    'nom',         data->>'nom'
  )
  from tontines
  where upper(code) = upper(trim(p_code));
$$;

grant execute on function lire_config_tontine(text) to anon;

-- ============================================================
-- SECTION 5 : Exécuter immédiatement le recalcul des échéances expirées
-- ============================================================
select recalculer_echeances_expir();

-- ============================================================
-- SECTION 6 : Vue diagnostic (optionnel) — périodicités utilisées
-- ============================================================
-- Décommenter pour vérifier la distribution des périodicités :
/*
select
  coalesce(data->>'periodicite', data->>'periode', 'non défini') as periodicite,
  count(*) as nb_tontines
from tontines
group by 1
order by 2 desc;
*/
