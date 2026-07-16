-- ============================================================
-- TontineClair — Migration 008 : RPCs Dashboard Admin
-- Sources    : supabase-admin-fix.sql (v1.2 FINAL)
--              supabase-v17-fix-soft-delete.sql (admin_lister_tontines v17 FINAL)
--              supabase-fix-v12-premium-requests.sql (admin_lister_demandes FINAL)
-- Dépendances: 001_tables_core.sql, 003_tables_financier.sql
-- Idempotent : CREATE OR REPLACE FUNCTION partout
-- ============================================================
-- Fonctions incluses (14) :
--   _verif_admin_cle, admin_stats_globales, admin_dashboard_tontines,
--   admin_lister_abonnements, admin_alertes (v1.2 FIX ORDER BY),
--   admin_enregistrer_abonnement, admin_stats_mensuelles, admin_top_tontines,
--   admin_tontine_counts (v17), admin_lister_tontines (v17 FINAL),
--   tontines_set_updated_at (trigger),
--   admin_lister_demandes (v12 FINAL — source premium_requests),
--   admin_activer_premium (v12),
--   admin_refuser_demande (v12)
-- ============================================================

-- ────────────────────────────────────────────────────────────
-- 1. _verif_admin_cle
--    Helper interne : vérifie la clé admin depuis config (priorité) puis admin_config
-- ────────────────────────────────────────────────────────────
create or replace function _verif_admin_cle(p_cle text)
returns boolean
language plpgsql security definer set search_path = public
as $$
declare
  v_ok boolean := false;
begin
  -- Source 1 : table "config" (source de vérité v5)
  begin
    select exists(
      select 1 from config
      where admin_cle = p_cle
        and p_cle <> 'CHANGE-MOI-cle-admin-secrete'
    ) into v_ok;
  exception when undefined_table then
    v_ok := false;
  end;

  if v_ok then return true; end if;

  -- Source 2 : table "admin_config" (fallback)
  begin
    select exists(
      select 1 from admin_config where cle = p_cle
    ) into v_ok;
  exception when undefined_table then
    v_ok := false;
  end;

  -- Source 3 : hash SHA-256 dans admin_config
  if not v_ok then
    begin
      select exists(
        select 1 from admin_config
        where cle = encode(sha256(p_cle::bytea), 'hex')
      ) into v_ok;
    exception when undefined_table then
      v_ok := false;
    end;
  end if;

  return coalesce(v_ok, false);
end $$;

grant execute on function _verif_admin_cle(text) to anon;

-- ────────────────────────────────────────────────────────────
-- 2. admin_stats_globales
--    KPI cards : totaux, premium, membres, revenus
-- ────────────────────────────────────────────────────────────
create or replace function admin_stats_globales(p_cle text)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_now         timestamptz := now();
  v_debut_mois  timestamptz := date_trunc('month', now());
  v_debut_annee timestamptz := date_trunc('year', now());
  v_total       int;
  v_prem_actif  int;
  v_prem_expire int;
  v_gratuites   int;
  v_membres     int;
begin
  if not _verif_admin_cle(p_cle) then return null; end if;

  select count(*) into v_total from tontines;

  select count(*) into v_prem_actif
  from tontines
  where plan = 'premium'
    and (plan_expire is null or plan_expire > v_now);

  select count(*) into v_prem_expire
  from tontines
  where plan = 'premium'
    and plan_expire is not null
    and plan_expire <= v_now;

  v_gratuites := greatest(0, v_total - v_prem_actif - v_prem_expire);

  select coalesce(sum(
    case
      when jsonb_typeof(data->'membres') = 'array'
        then jsonb_array_length(data->'membres')
      else 0
    end
  ), 0)
  into v_membres
  from tontines;

  return jsonb_build_object(
    'total_tontines',        v_total,
    'premium_actives',       v_prem_actif,
    'premium_expires',       v_prem_expire,
    'gratuites',             v_gratuites,
    'total_membres',         v_membres,
    'abonnements_actifs',    (
      select count(*) from abonnements
      where statut = 'actif'
        and (date_fin is null or date_fin > v_now)
    ),
    'montant_mensuel_fcfa',  (
      select coalesce(sum(montant), 0) from abonnements
      where statut = 'actif' and formule = 'mensuel'
        and (date_fin is null or date_fin > v_now)
    ),
    'montant_annuel_fcfa',   (
      select coalesce(sum(montant), 0) from abonnements
      where statut = 'actif' and formule = 'annuel'
        and (date_fin is null or date_fin > v_now)
    ),
    'encaisse_ce_mois',      (
      select coalesce(sum(montant), 0) from abonnements
      where statut = 'actif' and quand >= v_debut_mois
    ),
    'encaisse_annee',        (
      select coalesce(sum(montant), 0) from abonnements
      where statut = 'actif' and quand >= v_debut_annee
    ),
    'revenu_mensuel_estime', v_prem_actif * 2500,
    'revenu_annuel_estime',  v_prem_actif * 2500 * 12,
    'alertes',               (
      select count(*) from tontines
      where plan = 'premium'
        and plan_expire is not null
        and plan_expire > v_now
        and plan_expire < v_now + interval '7 days'
    ),
    'calcule_le',            v_now
  );
end $$;

grant execute on function admin_stats_globales(text) to anon;

-- ────────────────────────────────────────────────────────────
-- 3. admin_dashboard_tontines
--    Liste enrichie des tontines avec infos abonnement (pagination + filtre)
-- ────────────────────────────────────────────────────────────
create or replace function admin_dashboard_tontines(
  p_cle    text,
  p_filtre text  default 'toutes',
  p_limit  int   default 100,
  p_offset int   default 0
)
returns jsonb
language plpgsql security definer set search_path = public
as $$
begin
  if not _verif_admin_cle(p_cle) then return '[]'::jsonb; end if;

  return (
    select coalesce(jsonb_agg(row_json order by cree_t desc), '[]'::jsonb)
    from (
      select jsonb_build_object(
        'code',           t.code,
        'nom',            t.data->>'nom',
        'plan',           coalesce(t.plan, 'free'),
        'plan_expire',    t.plan_expire,
        'cree',           t.cree_le,
        'nb_membres',     case
                            when jsonb_typeof(t.data->'membres') = 'array'
                              then jsonb_array_length(t.data->'membres')
                            else 0
                          end,
        'nb_votes',       case
                            when jsonb_typeof(t.data->'votes') = 'array'
                              then jsonb_array_length(t.data->'votes')
                            else 0
                          end,
        'nb_prets',       case
                            when jsonb_typeof(t.data->'prets') = 'array'
                              then jsonb_array_length(t.data->'prets')
                            else 0
                          end,
        'montant_cotis',  coalesce((t.data->>'montant')::int, 0),
        'periodicite',    coalesce(t.data->>'periodicite', ''),
        'premier_gest',   t.data->'gestionnaires'->0->>'nom',
        'est_actif',      (
          t.plan = 'premium'
          and (t.plan_expire is null or t.plan_expire > now())
        ),
        'expire_bientot', (
          t.plan = 'premium'
          and t.plan_expire is not null
          and t.plan_expire > now()
          and t.plan_expire < now() + interval '7 days'
        ),
        'dernier_abonnement', (
          select jsonb_build_object(
            'formule',        a.formule,
            'montant',        a.montant,
            'date_debut',     a.date_debut,
            'date_fin',       a.date_fin,
            'statut',         a.statut,
            'moyen_paiement', a.moyen_paiement,
            'reference',      a.reference_paiement
          )
          from abonnements a
          where a.code = t.code
          order by a.quand desc
          limit 1
        )
      ) as row_json,
      t.cree_le as cree_t
      from tontines t
      where
        case p_filtre
          when 'premium'   then
            t.plan = 'premium'
            and (t.plan_expire is null or t.plan_expire > now())
          when 'gratuites' then
            coalesce(t.plan, 'free') != 'premium'
          when 'expires'   then
            t.plan = 'premium'
            and t.plan_expire is not null
            and t.plan_expire <= now()
          else true
        end
      order by t.cree_le desc
      limit p_limit offset p_offset
    ) sub
  );
end $$;

grant execute on function admin_dashboard_tontines(text, text, int, int) to anon;

-- ────────────────────────────────────────────────────────────
-- 4. admin_lister_abonnements
--    Liste des abonnements filtrée par statut
-- ────────────────────────────────────────────────────────────
create or replace function admin_lister_abonnements(
  p_cle    text,
  p_statut text default 'tous',
  p_limit  int  default 50
)
returns jsonb
language plpgsql security definer set search_path = public
as $$
begin
  if not _verif_admin_cle(p_cle) then return '[]'::jsonb; end if;

  return (
    select coalesce(jsonb_agg(jsonb_build_object(
      'id',              a.id,
      'code',            a.code,
      'nom_tontine',     t.data->>'nom',
      'formule',         a.formule,
      'montant',         a.montant,
      'devise',          a.devise,
      'date_debut',      a.date_debut,
      'date_fin',        a.date_fin,
      'statut',          a.statut,
      'active_par',      a.active_par,
      'moyen_paiement',  a.moyen_paiement,
      'reference',       a.reference_paiement,
      'note',            a.note,
      'quand',           a.quand
    ) order by a.quand desc), '[]'::jsonb)
    from abonnements a
    left join tontines t on t.code = a.code
    where
      case p_statut
        when 'actif'      then a.statut = 'actif'
        when 'expire'     then a.statut = 'expire'
        when 'en_attente' then a.statut = 'en_attente'
        else true
      end
    limit p_limit
  );
end $$;

grant execute on function admin_lister_abonnements(text, text, int) to anon;

-- ────────────────────────────────────────────────────────────
-- 5. admin_alertes  [FIX v1.2 — ORDER BY sur colonne SQL "prio"]
--    Alertes critiques : expirations proches, demandes en attente
-- ────────────────────────────────────────────────────────────
create or replace function admin_alertes(p_cle text)
returns jsonb
language plpgsql security definer set search_path = public
as $$
begin
  if not _verif_admin_cle(p_cle) then return '[]'::jsonb; end if;

  return (
    select coalesce(jsonb_agg(alerte order by prio), '[]'::jsonb)
    from (

      -- Abonnements expirant dans 7 jours (priorité 1 — critique)
      select jsonb_build_object(
        'type',     'expiration_proche',
        'titre',    count(*)::text || ' abonnement(s) expire(nt) dans moins de 7 jours',
        'detail',   string_agg(code || ' (' || to_char(plan_expire, 'DD/MM/YYYY') || ')', ', '),
        'nb',       count(*),
        'niveau',   'alerte'
      ) as alerte,
      1 as prio
      from tontines
      where plan = 'premium'
        and plan_expire > now()
        and plan_expire < now() + interval '7 days'
      having count(*) > 0

      union all

      -- Premium expirés non renouvelés (priorité 2)
      select jsonb_build_object(
        'type',     'abonnements_expires',
        'titre',    count(*)::text || ' tontine(s) Premium expirée(s)',
        'detail',   'Ces tontines sont repassées en mode gratuit',
        'nb',       count(*),
        'niveau',   'info'
      ) as alerte,
      2 as prio
      from tontines
      where plan = 'premium'
        and plan_expire is not null
        and plan_expire <= now()
      having count(*) > 0

      union all

      -- Demandes Premium en attente (priorité 1)
      select jsonb_build_object(
        'type',     'demandes_attente',
        'titre',    count(*)::text || ' demande(s) Premium en attente de validation',
        'detail',   'Vérifier l''onglet Demandes',
        'nb',       count(*),
        'niveau',   'alerte'
      ) as alerte,
      1 as prio
      from demandes_premium
      where statut = 'en attente'
      having count(*) > 0

      union all

      -- Tontines Premium inactives depuis 30 jours (priorité 3)
      select jsonb_build_object(
        'type',     'tontines_inactives',
        'titre',    count(*)::text || ' tontine(s) Premium sans activité depuis 30 jours',
        'detail',   'Pas de vote ni de prêt enregistré',
        'nb',       count(*),
        'niveau',   'info'
      ) as alerte,
      3 as prio
      from tontines
      where plan = 'premium'
        and (plan_expire is null or plan_expire > now())
        and cree_le < now() - interval '30 days'
        and (
          coalesce(jsonb_array_length(data->'votes'), 0) = 0
          and coalesce(jsonb_array_length(data->'prets'), 0) = 0
        )
      having count(*) > 0

    ) sub
  );
end $$;

grant execute on function admin_alertes(text) to anon;

-- ────────────────────────────────────────────────────────────
-- 6. admin_enregistrer_abonnement
--    Crée un abonnement Premium + met à jour tontines.plan
-- ────────────────────────────────────────────────────────────
create or replace function admin_enregistrer_abonnement(
  p_cle       text,
  p_code      text,
  p_formule   text    default 'mensuel',
  p_montant   int     default 2500,
  p_moyen     text    default null,
  p_reference text    default null,
  p_note      text    default null
)
returns boolean
language plpgsql security definer set search_path = public
as $$
declare
  v_date_fin timestamptz;
begin
  if not _verif_admin_cle(p_cle) then return false; end if;

  v_date_fin := case p_formule
    when 'annuel' then now() + interval '1 year'
    else               now() + interval '1 month'
  end;

  update abonnements
  set statut = 'expire'
  where code = upper(p_code) and statut = 'actif';

  insert into abonnements(
    code, formule, montant, date_debut, date_fin,
    statut, active_par, moyen_paiement, reference_paiement, note
  )
  values (
    upper(p_code),
    p_formule,
    case p_formule when 'annuel' then 25000 else coalesce(p_montant, 2500) end,
    now(), v_date_fin,
    'actif', 'ADMIN', p_moyen, p_reference, p_note
  );

  insert into admin_actions(code, action, detail, effectue_par)
  values (
    upper(p_code), 'ABONNEMENT_CREE',
    'Formule: ' || p_formule
    || ' | Montant: ' || coalesce(p_montant::text, '2500') || ' FCFA'
    || ' | Réf: '    || coalesce(p_reference, '-'),
    'ADMIN'
  );

  return true;
end $$;

grant execute on function admin_enregistrer_abonnement(text, text, text, int, text, text, text) to anon;

-- ────────────────────────────────────────────────────────────
-- 7. admin_stats_mensuelles
--    Évolution sur 12 mois : tontines, premium, revenus
-- ────────────────────────────────────────────────────────────
create or replace function admin_stats_mensuelles(p_cle text)
returns jsonb
language plpgsql security definer set search_path = public
as $$
begin
  if not _verif_admin_cle(p_cle) then return '[]'::jsonb; end if;

  return (
    select coalesce(jsonb_agg(jsonb_build_object(
      'mois',               to_char(m.mois, 'YYYY-MM'),
      'mois_label',         to_char(m.mois, 'Mon YYYY'),
      'nouvelles_tontines', coalesce(t.nb, 0),
      'premium_actives',    coalesce(p.nb, 0),
      'revenu_fcfa',        coalesce(a.montant, 0)
    ) order by m.mois), '[]'::jsonb)
    from (
      select generate_series(
        date_trunc('month', now() - interval '11 months'),
        date_trunc('month', now()),
        interval '1 month'
      ) as mois
    ) m
    left join (
      select date_trunc('month', cree_le) as mois, count(*) as nb
      from tontines
      group by 1
    ) t on t.mois = m.mois
    left join (
      select date_trunc('month', coalesce(plan_expire, now()) - interval '1 month') as mois,
             count(*) as nb
      from tontines
      where plan = 'premium'
      group by 1
    ) p on p.mois = m.mois
    left join (
      select date_trunc('month', quand) as mois, sum(montant)::int as montant
      from abonnements
      where statut = 'actif'
      group by 1
    ) a on a.mois = m.mois
  );
end $$;

grant execute on function admin_stats_mensuelles(text) to anon;

-- ────────────────────────────────────────────────────────────
-- 8. admin_top_tontines
--    Top 10 tontines par nombre de membres
-- ────────────────────────────────────────────────────────────
create or replace function admin_top_tontines(p_cle text)
returns jsonb
language plpgsql security definer set search_path = public
as $$
begin
  if not _verif_admin_cle(p_cle) then return '[]'::jsonb; end if;

  return (
    select coalesce(jsonb_agg(jsonb_build_object(
      'code',       code,
      'nom',        data->>'nom',
      'plan',       coalesce(plan, 'free'),
      'nb_membres', case
                      when jsonb_typeof(data->'membres') = 'array'
                        then jsonb_array_length(data->'membres')
                      else 0
                    end,
      'montant',    coalesce((data->>'montant')::int, 0)
    ) order by case
        when jsonb_typeof(data->'membres') = 'array'
          then jsonb_array_length(data->'membres')
        else 0
      end desc
    ), '[]'::jsonb)
    from (
      select code, data, plan
      from tontines
      order by case
          when jsonb_typeof(data->'membres') = 'array'
            then jsonb_array_length(data->'membres')
          else 0
        end desc
      limit 10
    ) t
  );
end $$;

grant execute on function admin_top_tontines(text) to anon;

-- ────────────────────────────────────────────────────────────
-- 9. admin_tontine_counts  [SOURCE: supabase-v17-fix-soft-delete.sql]
--    Compteurs unifiés : total, actives, premium, supprimées, etc.
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION admin_tontine_counts(p_cle text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $func_atc$
DECLARE
  v_admin_key text := 'TONTINE_ADMIN_2024';
  v_counts    jsonb;
  v_demandes  int := 0;
BEGIN
  IF p_cle != v_admin_key THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Cle admin incorrecte.');
  END IF;

  WITH cats AS (
    SELECT
      code,
      CASE
        WHEN status = 'deleted' OR deleted_at IS NOT NULL THEN 'deleted'
        WHEN status = 'suspended'                          THEN 'suspended'
        WHEN status = 'inactive'                           THEN 'inactive'
        WHEN plan = 'premium'
             AND data->>'planExpire' IS NOT NULL
             AND (data->>'planExpire')::timestamptz < now() THEN 'expire'
        WHEN plan = 'premium' THEN 'premium'
        ELSE 'gratuit'
      END AS cat
    FROM tontines
  )
  SELECT jsonb_build_object(
    'total',      COUNT(*) FILTER (WHERE cat != 'deleted'),
    'actives',    COUNT(*) FILTER (WHERE cat IN ('gratuit','premium')),
    'premium',    COUNT(*) FILTER (WHERE cat = 'premium'),
    'gratuites',  COUNT(*) FILTER (WHERE cat = 'gratuit'),
    'inactives',  COUNT(*) FILTER (WHERE cat = 'inactive'),
    'suspendues', COUNT(*) FILTER (WHERE cat = 'suspended'),
    'expirees',   COUNT(*) FILTER (WHERE cat = 'expire'),
    'supprimees', COUNT(*) FILTER (WHERE cat = 'deleted')
  )
  INTO v_counts
  FROM cats;

  BEGIN
    SELECT COUNT(*) INTO v_demandes
    FROM premium_requests
    WHERE statut IN ('en_attente', 'en attente', 'pending');
  EXCEPTION WHEN undefined_table THEN
    v_demandes := 0;
  END;

  RETURN v_counts || jsonb_build_object(
    'ok',                  true,
    'demandes_en_attente', v_demandes
  );
END;
$func_atc$;

GRANT EXECUTE ON FUNCTION admin_tontine_counts(text) TO anon, authenticated;

-- ────────────────────────────────────────────────────────────
-- 10. admin_lister_tontines  [SOURCE: supabase-v17-fix-soft-delete.sql v17 FINAL]
--     Liste toutes les tontines (soft-delete aware) pour le dashboard admin
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION admin_lister_tontines(p_cle text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $func_alt$
DECLARE
  v_admin_key text := 'TONTINE_ADMIN_2024';
  v_result    jsonb;
BEGIN
  IF p_cle != v_admin_key THEN
    RETURN '[]'::jsonb;
  END IF;

  SELECT jsonb_agg(
    jsonb_build_object(
      'code',             t.code,
      'nom',              COALESCE(
                            NULLIF(trim(t.data->>'nom'), ''),
                            'Tontine sans nom'
                          ),
      'president',        COALESCE(
                            t.data->'gestionnaire'->>'nom',
                            t.data->>'gestionnaire',
                            t.data->>'president',
                            t.data->>'created_by',
                            t.data->>'owner'
                          ),
      'membres',          COALESCE(
                            jsonb_array_length(t.data->'membres'),
                            0
                          ),
      'plan',             COALESCE(t.plan, 'free'),
      'plan_expire',      t.data->>'planExpire',
      'cree',             to_char(t.created_at, 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
      'status',           COALESCE(t.status, 'active'),
      'deleted_at',       CASE WHEN t.deleted_at IS NOT NULL
                               THEN to_char(t.deleted_at, 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
                               ELSE NULL END,
      'deleted_by',       t.deleted_by,
      'deletion_reason',  t.deletion_reason,
      'invitation_active', t.invitation_code_active
    )
    ORDER BY
      CASE WHEN COALESCE(t.status,'active') = 'deleted' THEN 1 ELSE 0 END ASC,
      t.created_at DESC
  )
  INTO v_result
  FROM tontines t;

  RETURN COALESCE(v_result, '[]'::jsonb);
END;
$func_alt$;

GRANT EXECUTE ON FUNCTION admin_lister_tontines(text) TO anon, authenticated;

-- ────────────────────────────────────────────────────────────
-- 11. tontines_set_updated_at  [SOURCE: supabase-v17-fix-soft-delete.sql]
--     Trigger : met à jour updated_at automatiquement
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION tontines_set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $func_sua$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$func_sua$;

DROP TRIGGER IF EXISTS trg_tontines_updated_at ON tontines;

CREATE TRIGGER trg_tontines_updated_at
  BEFORE UPDATE ON tontines
  FOR EACH ROW
  EXECUTE FUNCTION tontines_set_updated_at();

-- ────────────────────────────────────────────────────────────
-- 12. admin_lister_demandes  [SOURCE: supabase-fix-v12-premium-requests.sql FINAL]
--     Lit depuis premium_requests (pas demandes_premium) — v12 final
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION admin_lister_demandes(p_cle text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_valide boolean;
BEGIN
  v_valide := (p_cle IS NOT NULL AND length(trim(p_cle)) >= 4);
  IF NOT v_valide THEN
    RAISE EXCEPTION 'CLE_INVALIDE';
  END IF;

  RETURN (
    SELECT jsonb_agg(
      jsonb_build_object(
        'id',          pr.id,
        'code',        pr.tontine_code,
        'statut',      pr.status,
        'gestionnaire', pr.requester_name,
        'nom',         pr.requester_name,
        'contact',     pr.contact,
        'formule',     pr.plan,
        'montant',     pr.amount,
        'plateforme',  pr.platform,
        'motif_refus', pr.rejection_reason,
        'traite_par',  pr.reviewed_by,
        'traite_le',   pr.reviewed_at,
        'quand',       to_char(pr.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
        'nom_tontine', coalesce(
                          t.data->>'nom',
                          t.data->>'titre',
                          pr.tontine_code
                        ),
        'nb_membres',  coalesce(
                          jsonb_array_length(t.data->'membres'),
                          0
                        )
      )
      ORDER BY pr.created_at DESC
    )
    FROM premium_requests pr
    LEFT JOIN tontines t ON upper(t.code) = upper(pr.tontine_code)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION admin_lister_demandes(text) TO anon;
GRANT EXECUTE ON FUNCTION admin_lister_demandes(text) TO authenticated;

-- ────────────────────────────────────────────────────────────
-- 13. admin_activer_premium  [SOURCE: supabase-fix-v12-premium-requests.sql]
--     Active le plan Premium + met à jour premium_requests
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION admin_activer_premium(
  p_cle  text,
  p_code text,
  p_mois integer DEFAULT 1
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_code      text := upper(trim(p_code));
  v_expire    timestamptz;
  v_rows      integer;
BEGIN
  IF p_cle IS NULL OR length(trim(p_cle)) < 4 THEN
    RAISE EXCEPTION 'CLE_INVALIDE';
  END IF;

  v_expire := now() + (p_mois || ' months')::interval;

  UPDATE tontines
  SET
    plan        = 'premium',
    plan_expire = v_expire,
    updated_at  = now()
  WHERE upper(code) = v_code;

  GET DIAGNOSTICS v_rows = ROW_COUNT;

  IF v_rows = 0 THEN
    BEGIN
      UPDATE tontines
      SET plan = 'premium', updated_at = now()
      WHERE upper(code) = v_code;
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
  END IF;

  UPDATE premium_requests
  SET
    status      = 'approuvee',
    reviewed_by = 'admin',
    reviewed_at = now()
  WHERE tontine_code = v_code
    AND status       = 'en_attente';

  RETURN true;
END;
$$;

GRANT EXECUTE ON FUNCTION admin_activer_premium(text, text, integer) TO anon;
GRANT EXECUTE ON FUNCTION admin_activer_premium(text, text, integer) TO authenticated;

-- ────────────────────────────────────────────────────────────
-- 14. admin_refuser_demande  [SOURCE: supabase-fix-v12-premium-requests.sql]
--     Refuse une demande Premium avec motif
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION admin_refuser_demande(
  p_cle   text,
  p_code  text,
  p_motif text DEFAULT ''
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_code text := upper(trim(p_code));
BEGIN
  IF p_cle IS NULL OR length(trim(p_cle)) < 4 THEN
    RAISE EXCEPTION 'CLE_INVALIDE';
  END IF;

  UPDATE premium_requests
  SET
    status           = 'refusee',
    rejection_reason = coalesce(nullif(trim(p_motif), ''), 'Demande refusée par l''administrateur.'),
    reviewed_by      = 'admin',
    reviewed_at      = now()
  WHERE tontine_code = v_code
    AND status       = 'en_attente';

  RETURN true;
END;
$$;

GRANT EXECUTE ON FUNCTION admin_refuser_demande(text, text, text) TO anon;
GRANT EXECUTE ON FUNCTION admin_refuser_demande(text, text, text) TO authenticated;

-- ────────────────────────────────────────────────────────────
-- RLS pour les tables admin (accès uniquement via RPC)
-- ────────────────────────────────────────────────────────────
drop policy if exists "abonnements_no_direct" on abonnements;
create policy "abonnements_no_direct"
  on abonnements for all to anon using (false);

drop policy if exists "admin_actions_no_direct" on admin_actions;
create policy "admin_actions_no_direct"
  on admin_actions for all to anon using (false);

drop policy if exists "admin_config_no_access" on admin_config;
create policy "admin_config_no_access"
  on admin_config for all to anon using (false);

drop policy if exists "demandes_premium_insert" on demandes_premium;
create policy "demandes_premium_insert"
  on demandes_premium for insert to anon with check (true);

drop policy if exists "demandes_premium_select" on demandes_premium;
create policy "demandes_premium_select"
  on demandes_premium for select to anon using (true);

-- ────────────────────────────────────────────────────────────
-- Vérification post-déploiement
-- ────────────────────────────────────────────────────────────
DO $verify008$
DECLARE
  v_fns text[] := ARRAY[
    '_verif_admin_cle','admin_stats_globales','admin_dashboard_tontines',
    'admin_lister_abonnements','admin_alertes','admin_enregistrer_abonnement',
    'admin_stats_mensuelles','admin_top_tontines',
    'admin_tontine_counts','admin_lister_tontines','tontines_set_updated_at',
    'admin_lister_demandes','admin_activer_premium','admin_refuser_demande'
  ];
  v_fn text;
  v_ok boolean;
BEGIN
  FOREACH v_fn IN ARRAY v_fns LOOP
    SELECT EXISTS(SELECT 1 FROM pg_proc WHERE proname = v_fn) INTO v_ok;
    RAISE NOTICE '008 % : %', v_fn, CASE WHEN v_ok THEN 'OK' ELSE 'MANQUANT' END;
  END LOOP;
END;
$verify008$;
-- ============================================================
-- FIN 008_rpcs_admin.sql
-- ============================================================
