-- ============================================================
-- TontineClair — Migration Admin Dashboard v1.0
-- Tables et fonctions pour le Dashboard Global Administrateur
--
-- INSTRUCTIONS :
--   1. Supabase > SQL Editor > New query
--   2. Copier-coller ce fichier complet
--   3. Cliquer Run
--   4. Message attendu : "Success. No rows returned."
--
-- PRÉREQUIS : supabase-v6.sql déjà exécuté
-- CE SCRIPT : idempotent, safe à relancer
-- ============================================================

-- ============================================================
-- SECTION 1 : Table des abonnements Premium
-- Trace chaque activation/désactivation Premium
-- ============================================================
create table if not exists abonnements (
  id            bigint generated always as identity primary key,
  code          text        not null,          -- code de la tontine
  formule       text        not null default 'mensuel',
  -- 'mensuel' = 2500 FCFA/mois | 'annuel' = 25000 FCFA/an
  montant       int         not null default 2500,
  devise        text        not null default 'FCFA',
  date_debut    timestamptz not null default now(),
  date_fin      timestamptz,
  statut        text        not null default 'actif'
                  check (statut in ('actif','expire','annule','en_attente')),
  active_par    text,                           -- nom du gestionnaire admin
  moyen_paiement text,                         -- 'wave','orange_money','mtn','especes','virement'
  reference_paiement text,
  note          text,
  quand         timestamptz not null default now()
);
create index if not exists idx_abonnements_code
  on abonnements(code);
create index if not exists idx_abonnements_statut
  on abonnements(statut, date_fin);
alter table abonnements enable row level security;

-- ============================================================
-- SECTION 2 : Table des actions administrateur
-- Journal de toutes les actions admin (audit complet)
-- ============================================================
create table if not exists admin_actions (
  id            bigint generated always as identity primary key,
  code          text,                           -- code tontine concernée (null si global)
  action        text        not null,
  -- 'PREMIUM_ACTIVE','PREMIUM_DESACTIVE','TONTINE_SUPPRIMEE',
  -- 'MEMBRE_SUSPENDU','DASHBOARD_CONSULTE','ABONNEMENT_CREE'
  detail        text,
  effectue_par  text        not null default 'ADMIN',
  quand         timestamptz not null default now()
);
create index if not exists idx_admin_actions_quand
  on admin_actions(quand desc);
create index if not exists idx_admin_actions_code
  on admin_actions(code);
alter table admin_actions enable row level security;

-- ============================================================
-- SECTION 3 : Fonctions RPC Dashboard
-- ============================================================

-- 3a) Statistiques globales de la plateforme
--     Retourne tous les KPIs du dashboard en une seule requête
create or replace function admin_stats_globales(p_cle text)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_cle_valide boolean;
  v_now timestamptz := now();
  v_debut_mois timestamptz := date_trunc('month', now());
  v_debut_annee timestamptz := date_trunc('year', now());
  v_total_tontines int;
  v_premium_actives int;
  v_premium_expires int;
  v_gratuites int;
  v_total_membres int;
  v_montant_prix_mensuel int := 2500;
  v_montant_prix_annuel int  := 25000;
begin
  -- Vérifier la clé admin
  select exists(
    select 1 from admin_config where cle = p_cle
  ) into v_cle_valide;

  if not v_cle_valide then
    -- Fallback: vérifier si la clé correspond au hash stocké
    select exists(
      select 1 from admin_config where cle = encode(sha256(p_cle::bytea), 'hex')
    ) into v_cle_valide;
  end if;

  if not v_cle_valide then return null; end if;

  -- Compter les tontines
  select count(*) into v_total_tontines from tontines;

  select count(*) into v_premium_actives
  from tontines
  where plan = 'premium'
    and (plan_expire is null or plan_expire > v_now);

  select count(*) into v_premium_expires
  from tontines
  where plan = 'premium'
    and plan_expire is not null
    and plan_expire <= v_now;

  v_gratuites := v_total_tontines - v_premium_actives - v_premium_expires;
  if v_gratuites < 0 then v_gratuites := 0; end if;

  -- Compter les membres (depuis le JSONB data)
  select coalesce(sum(jsonb_array_length(data->'membres')), 0)
  into v_total_membres
  from tontines;

  return jsonb_build_object(
    'total_tontines',       v_total_tontines,
    'premium_actives',      v_premium_actives,
    'premium_expires',      v_premium_expires,
    'gratuites',            v_gratuites,
    'total_membres',        v_total_membres,
    -- Revenus estimés depuis la table abonnements
    'abonnements_actifs',   (select count(*) from abonnements where statut = 'actif' and (date_fin is null or date_fin > v_now)),
    'montant_mensuel_fcfa', (select coalesce(sum(montant), 0) from abonnements where statut = 'actif' and formule = 'mensuel' and (date_fin is null or date_fin > v_now)),
    'montant_annuel_fcfa',  (select coalesce(sum(montant), 0) from abonnements where statut = 'actif' and formule = 'annuel' and (date_fin is null or date_fin > v_now)),
    'encaisse_ce_mois',     (select coalesce(sum(montant), 0) from abonnements where statut = 'actif' and quand >= v_debut_mois),
    'encaisse_annee',       (select coalesce(sum(montant), 0) from abonnements where statut = 'actif' and quand >= v_debut_annee),
    'revenu_mensuel_estime', v_premium_actives * v_montant_prix_mensuel,
    'revenu_annuel_estime',  v_premium_actives * v_montant_prix_mensuel * 12,
    'alertes',              (
      select count(*) from tontines
      where plan = 'premium'
        and plan_expire is not null
        and plan_expire > v_now
        and plan_expire < v_now + interval '7 days'
    ),
    'calcule_le',           v_now
  );
end $$;

-- 3b) Liste complète des tontines pour le dashboard
--     Format enrichi avec stats membres, abonnement, dernière activité
create or replace function admin_dashboard_tontines(
  p_cle    text,
  p_filtre text    default 'toutes',  -- 'toutes','premium','gratuites','expires'
  p_limit  int     default 100,
  p_offset int     default 0
)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_cle_valide boolean;
begin
  select exists(select 1 from admin_config where cle = p_cle)
    or exists(select 1 from admin_config where cle = encode(sha256(p_cle::bytea), 'hex'))
  into v_cle_valide;

  if not v_cle_valide then return '[]'::jsonb; end if;

  return (
    select coalesce(jsonb_agg(row_json order by cree desc), '[]'::jsonb)
    from (
      select jsonb_build_object(
        'code',           t.code,
        'nom',            t.data->>'nom',
        'plan',           coalesce(t.plan, 'free'),
        'plan_expire',    t.plan_expire,
        'cree',           t.cree,
        'nb_membres',     jsonb_array_length(coalesce(t.data->'membres', '[]'::jsonb)),
        'nb_votes',       jsonb_array_length(coalesce(t.data->'votes', '[]'::jsonb)),
        'nb_prets',       jsonb_array_length(coalesce(t.data->'prets', '[]'::jsonb)),
        'montant_cotis',  (t.data->>'montant')::int,
        'periodicite',    t.data->>'periodicite',
        'gestionnaires',  t.data->'gestionnaires',
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
            'formule', a.formule,
            'montant', a.montant,
            'date_debut', a.date_debut,
            'date_fin', a.date_fin,
            'statut', a.statut,
            'moyen_paiement', a.moyen_paiement,
            'reference', a.reference_paiement
          )
          from abonnements a
          where a.code = t.code
          order by a.quand desc
          limit 1
        )
      ) as row_json,
      t.cree
      from tontines t
      where
        case p_filtre
          when 'premium'   then t.plan = 'premium' and (t.plan_expire is null or t.plan_expire > now())
          when 'gratuites' then t.plan != 'premium' or t.plan is null
          when 'expires'   then t.plan = 'premium' and t.plan_expire is not null and t.plan_expire <= now()
          else true
        end
      order by t.cree desc
      limit p_limit offset p_offset
    ) sub
  );
end $$;

-- 3c) Abonnements actifs et historique
create or replace function admin_lister_abonnements(
  p_cle    text,
  p_statut text default 'tous',    -- 'tous','actif','expire','en_attente'
  p_limit  int  default 50
)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_cle_valide boolean;
begin
  select exists(select 1 from admin_config where cle = p_cle)
    or exists(select 1 from admin_config where cle = encode(sha256(p_cle::bytea), 'hex'))
  into v_cle_valide;

  if not v_cle_valide then return '[]'::jsonb; end if;

  return (
    select coalesce(jsonb_agg(jsonb_build_object(
      'id',           a.id,
      'code',         a.code,
      'nom_tontine',  t.data->>'nom',
      'formule',      a.formule,
      'montant',      a.montant,
      'devise',       a.devise,
      'date_debut',   a.date_debut,
      'date_fin',     a.date_fin,
      'statut',       a.statut,
      'active_par',   a.active_par,
      'moyen_paiement', a.moyen_paiement,
      'reference',    a.reference_paiement,
      'note',         a.note,
      'quand',        a.quand
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

-- 3d) Alertes administrateur
create or replace function admin_alertes(p_cle text)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_cle_valide boolean;
begin
  select exists(select 1 from admin_config where cle = p_cle)
    or exists(select 1 from admin_config where cle = encode(sha256(p_cle::bytea), 'hex'))
  into v_cle_valide;

  if not v_cle_valide then return '[]'::jsonb; end if;

  return (
    select coalesce(jsonb_agg(alerte order by priorite), '[]'::jsonb)
    from (
      -- Abonnements qui expirent dans 7 jours
      select jsonb_build_object(
        'type',     'expiration_proche',
        'titre',    count(*)::text || ' abonnement(s) expire(nt) dans moins de 7 jours',
        'detail',   string_agg(code || ' (' || to_char(plan_expire, 'DD/MM/YYYY') || ')', ', '),
        'nb',       count(*),
        'niveau',   'alerte',
        'priorite', 1
      ) as alerte
      from tontines
      where plan = 'premium'
        and plan_expire > now()
        and plan_expire < now() + interval '7 days'
      having count(*) > 0

      union all

      -- Abonnements Premium expirés (non renouvelés)
      select jsonb_build_object(
        'type',     'abonnements_expires',
        'titre',    count(*)::text || ' tontine(s) Premium expirée(s)',
        'detail',   'Ces tontines sont repassées en mode gratuit',
        'nb',       count(*),
        'niveau',   'info',
        'priorite', 2
      )
      from tontines
      where plan = 'premium'
        and plan_expire is not null
        and plan_expire <= now()
      having count(*) > 0

      union all

      -- Demandes Premium en attente
      select jsonb_build_object(
        'type',     'demandes_attente',
        'titre',    count(*)::text || ' demande(s) Premium en attente de validation',
        'detail',   'Vérifier l\'onglet Demandes',
        'nb',       count(*),
        'niveau',   'alerte',
        'priorite', 1
      )
      from demandes_premium
      where statut = 'en attente'
      having count(*) > 0

      union all

      -- Tontines sans activité depuis 30 jours (aucun vote ni paiement récent)
      select jsonb_build_object(
        'type',     'tontines_inactives',
        'titre',    count(*)::text || ' tontine(s) sans activité depuis 30 jours',
        'detail',   'Ces tontines Premium pourraient être des faux comptes',
        'nb',       count(*),
        'niveau',   'info',
        'priorite', 3
      )
      from tontines
      where plan = 'premium'
        and plan_expire > now()
        and cree < now() - interval '30 days'
        and (
          jsonb_array_length(coalesce(data->'votes', '[]')) = 0
          and jsonb_array_length(coalesce(data->'prets', '[]')) = 0
        )
      having count(*) > 0
    ) sub
  );
end $$;

-- 3e) Enregistrer un abonnement (lors d'une activation Premium)
create or replace function admin_enregistrer_abonnement(
  p_cle        text,
  p_code       text,
  p_formule    text    default 'mensuel',
  p_montant    int     default 2500,
  p_moyen      text    default null,
  p_reference  text    default null,
  p_note       text    default null
)
returns boolean
language plpgsql security definer set search_path = public
as $$
declare
  v_cle_valide boolean;
  v_date_fin timestamptz;
begin
  select exists(select 1 from admin_config where cle = p_cle)
    or exists(select 1 from admin_config where cle = encode(sha256(p_cle::bytea), 'hex'))
  into v_cle_valide;

  if not v_cle_valide then return false; end if;

  -- Calculer la date de fin selon la formule
  v_date_fin := case p_formule
    when 'annuel'  then now() + interval '1 year'
    else                now() + interval '1 month'
  end;

  -- Expirer les anciens abonnements actifs pour cette tontine
  update abonnements
  set statut = 'expire'
  where code = upper(p_code) and statut = 'actif';

  -- Créer le nouvel abonnement
  insert into abonnements(
    code, formule, montant, date_debut, date_fin,
    statut, active_par, moyen_paiement, reference_paiement, note
  )
  values (
    upper(p_code), p_formule,
    case p_formule when 'annuel' then 25000 else p_montant end,
    now(), v_date_fin,
    'actif', 'ADMIN', p_moyen, p_reference, p_note
  );

  -- Logger l'action
  insert into admin_actions(code, action, detail, effectue_par)
  values (
    upper(p_code),
    'PREMIUM_ACTIVE',
    'Formule: ' || p_formule || ' | Montant: ' || p_montant || ' FCFA | Réf: ' || coalesce(p_reference, '-'),
    'ADMIN'
  );

  return true;
end $$;

-- 3f) Graphiques : évolution mensuelle des tontines et revenus (12 derniers mois)
create or replace function admin_stats_mensuelles(p_cle text)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_cle_valide boolean;
begin
  select exists(select 1 from admin_config where cle = p_cle)
    or exists(select 1 from admin_config where cle = encode(sha256(p_cle::bytea), 'hex'))
  into v_cle_valide;

  if not v_cle_valide then return '[]'::jsonb; end if;

  return (
    select coalesce(jsonb_agg(jsonb_build_object(
      'mois',              to_char(m.mois, 'YYYY-MM'),
      'mois_label',        to_char(m.mois, 'Mon YYYY'),
      'nouvelles_tontines', coalesce(t.nb, 0),
      'premium_actives',   coalesce(p.nb, 0),
      'revenu_fcfa',       coalesce(a.montant, 0)
    ) order by m.mois), '[]'::jsonb)
    from (
      -- Générer les 12 derniers mois
      select generate_series(
        date_trunc('month', now() - interval '11 months'),
        date_trunc('month', now()),
        interval '1 month'
      ) as mois
    ) m
    left join (
      select date_trunc('month', cree) as mois, count(*) as nb
      from tontines
      group by 1
    ) t on t.mois = m.mois
    left join (
      select date_trunc('month', plan_expire - interval '1 month') as mois, count(*) as nb
      from tontines
      where plan = 'premium'
      group by 1
    ) p on p.mois = m.mois
    left join (
      select date_trunc('month', quand) as mois, sum(montant) as montant
      from abonnements
      where statut = 'actif'
      group by 1
    ) a on a.mois = m.mois
  );
end $$;

-- 3g) Top 10 tontines par nombre de membres
create or replace function admin_top_tontines(p_cle text)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_cle_valide boolean;
begin
  select exists(select 1 from admin_config where cle = p_cle)
    or exists(select 1 from admin_config where cle = encode(sha256(p_cle::bytea), 'hex'))
  into v_cle_valide;

  if not v_cle_valide then return '[]'::jsonb; end if;

  return (
    select coalesce(jsonb_agg(jsonb_build_object(
      'code',       code,
      'nom',        data->>'nom',
      'plan',       coalesce(plan, 'free'),
      'nb_membres', jsonb_array_length(coalesce(data->'membres', '[]')),
      'montant',    (data->>'montant')::int
    ) order by jsonb_array_length(coalesce(data->'membres', '[]')) desc), '[]'::jsonb)
    from (
      select code, data, plan
      from tontines
      order by jsonb_array_length(coalesce(data->'membres', '[]')) desc
      limit 10
    ) t
  );
end $$;

-- ============================================================
-- SECTION 4 : Table admin_config (si elle n'existe pas)
-- Stocke la clé admin de manière sécurisée
-- ============================================================
create table if not exists admin_config (
  id   int primary key default 1,
  cle  text not null,
  note text
);

-- Contrainte: une seule ligne possible
alter table admin_config drop constraint if exists admin_config_single_row;
alter table admin_config add constraint admin_config_single_row check (id = 1);

alter table admin_config enable row level security;
-- RLS: personne ne peut lire admin_config directement (security definer uniquement)
drop policy if exists "admin_config_no_access" on admin_config;
create policy "admin_config_no_access"
  on admin_config for all to anon using (false);

-- ============================================================
-- SECTION 5 : Vérifier/créer la table demandes_premium
-- (peut-être déjà créée sous un autre nom)
-- ============================================================
create table if not exists demandes_premium (
  id          bigint generated always as identity primary key,
  code        text        not null,
  gestionnaire text       not null,
  contact     text,
  statut      text        not null default 'en attente'
                check (statut in ('en attente','activée','refusée')),
  quand       timestamptz not null default now()
);
create index if not exists idx_demandes_premium_statut
  on demandes_premium(statut);
alter table demandes_premium enable row level security;

-- ============================================================
-- SECTION 6 : Autorisations
-- ============================================================
grant execute on function admin_stats_globales(text)            to anon;
grant execute on function admin_dashboard_tontines(text,text,int,int) to anon;
grant execute on function admin_lister_abonnements(text,text,int)     to anon;
grant execute on function admin_alertes(text)                   to anon;
grant execute on function admin_enregistrer_abonnement(text,text,text,int,text,text,text) to anon;
grant execute on function admin_stats_mensuelles(text)          to anon;
grant execute on function admin_top_tontines(text)              to anon;

-- Politique lecture sur abonnements (via security definer)
drop policy if exists "abonnements_anon_read" on abonnements;
create policy "abonnements_anon_read"
  on abonnements for select to anon using (false); -- lecture via RPC uniquement

drop policy if exists "admin_actions_read" on admin_actions;
create policy "admin_actions_read"
  on admin_actions for select to anon using (false); -- lecture via RPC uniquement

drop policy if exists "demandes_premium_insert" on demandes_premium;
create policy "demandes_premium_insert"
  on demandes_premium for insert to anon with check (true);

-- ============================================================
-- SECTION 7 : Migration clé admin depuis la config existante
-- ============================================================
-- IMPORTANT : Exécuter cette instruction SÉPARÉMENT avec votre vraie clé admin :
--
--   INSERT INTO admin_config(id, cle, note)
--   VALUES (1, 'VOTRE_CLE_ADMIN_ICI', 'Clé admin principale')
--   ON CONFLICT (id) DO UPDATE SET cle = EXCLUDED.cle;
--
-- Remplacer VOTRE_CLE_ADMIN_ICI par la clé que vous utilisez
-- dans l'espace admin de TontineClair.
-- ============================================================

-- ============================================================
-- SECTION 8 : Vérification post-migration
-- ============================================================
-- SELECT count(*) FROM abonnements;       -- 0 (nouveau)
-- SELECT count(*) FROM admin_actions;     -- 0 (nouveau)
-- SELECT proname FROM pg_proc WHERE proname LIKE 'admin_%';
-- ============================================================
-- FIN supabase-admin.sql
-- ============================================================
