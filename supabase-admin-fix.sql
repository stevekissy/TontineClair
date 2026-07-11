-- ============================================================
-- TontineClair — Migration Admin Dashboard v1.2 (FIX)
-- Fichier   : supabase-admin-fix.sql
-- Version   : 1.2 — corrige admin_alertes ORDER BY (42703)
-- Date      : 2025-07
--
-- PROBLÈME CORRIGÉ :
--   supabase-admin.sql (v1.0) créait une table admin_config indépendante
--   alors que la clé admin est déjà stockée dans la table "config" (v5.sql).
--   Cette version lit la clé depuis "config" (source de vérité v5) ET depuis
--   "admin_config" en fallback → rétrocompatible avec les deux.
--
-- CE SCRIPT :
--   ✅ NE supprime AUCUNE table existante
--   ✅ NE vide AUCUNE table existante (pas de TRUNCATE)
--   ✅ Idempotent — safe à relancer plusieurs fois
--   ✅ CREATE TABLE IF NOT EXISTS pour toutes les tables
--   ✅ CREATE OR REPLACE FUNCTION pour toutes les fonctions
--   ✅ Lit la clé admin depuis "config" (v5) ou "admin_config" en fallback
--
-- PRÉREQUIS : supabase-v5.sql déjà exécuté (tables tontines, config,
--             demandes_premium présentes)
--
-- INSTRUCTIONS :
--   1. Supabase > SQL Editor > New query
--   2. Copier-coller ce fichier complet
--   3. Cliquer Run (Ctrl+Enter)
--   4. Message attendu : "Success. No rows returned."
--   5. Vérifier : SELECT routine_name FROM information_schema.routines
--                 WHERE routine_name = 'admin_stats_mensuelles';
-- ============================================================

-- ============================================================
-- SECTION 1 : Tables du dashboard admin
-- ============================================================

-- 1a) Table des abonnements Premium
--     Trace chaque activation/désactivation et son paiement.
--     ⚠️ NE PAS supprimer si elle existe déjà.
create table if not exists abonnements (
  id                 bigint generated always as identity primary key,
  code               text        not null,
  formule            text        not null default 'mensuel',
  -- 'mensuel' = 2 500 FCFA/mois | 'annuel' = 25 000 FCFA/an
  montant            int         not null default 2500,
  devise             text        not null default 'FCFA',
  date_debut         timestamptz not null default now(),
  date_fin           timestamptz,
  statut             text        not null default 'actif'
                       check (statut in ('actif','expire','annule','en_attente')),
  active_par         text,
  moyen_paiement     text,
  -- 'wave','orange_money','mtn','especes','virement'
  reference_paiement text,
  note               text,
  quand              timestamptz not null default now()
);
create index if not exists idx_abonnements_code
  on abonnements(code);
create index if not exists idx_abonnements_statut
  on abonnements(statut, date_fin);
alter table abonnements enable row level security;

-- 1b) Journal des actions administrateur (audit)
create table if not exists admin_actions (
  id           bigint generated always as identity primary key,
  code         text,
  action       text        not null,
  -- 'PREMIUM_ACTIVE','PREMIUM_DESACTIVE','ABONNEMENT_CREE','DASHBOARD_CONSULTE'
  detail       text,
  effectue_par text        not null default 'ADMIN',
  quand        timestamptz not null default now()
);
create index if not exists idx_admin_actions_quand
  on admin_actions(quand desc);
create index if not exists idx_admin_actions_code
  on admin_actions(code);
alter table admin_actions enable row level security;

-- 1c) Table admin_config (clé admin sécurisée)
--     ⚠️ Si elle existe déjà (de l'ancien supabase-admin.sql), on la garde.
--     La clé admin principale est dans "config" (v5) — admin_config est
--     un second facteur optionnel.
create table if not exists admin_config (
  id   int primary key default 1,
  cle  text not null,
  note text
);
alter table admin_config enable row level security;

-- Aucune policy de lecture directe (security definer uniquement)
drop policy if exists "admin_config_no_access" on admin_config;
create policy "admin_config_no_access"
  on admin_config for all to anon using (false);

-- ============================================================
-- SECTION 2 : Fonction helper — vérification de la clé admin
-- Lit depuis "config" (v5) EN PRIORITÉ, puis "admin_config" en fallback.
-- ============================================================
create or replace function _verif_admin_cle(p_cle text)
returns boolean
language plpgsql security definer set search_path = public
as $$
declare
  v_ok boolean := false;
begin
  -- Source 1 : table "config" de supabase-v5.sql (source de vérité)
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

  -- Source 2 : table "admin_config" (fallback, peut être absente)
  begin
    select exists(
      select 1 from admin_config where cle = p_cle
    ) into v_ok;
  exception when undefined_table then
    v_ok := false;
  end;

  -- Source 3 : hash SHA-256 (compatibilité versions futures)
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

-- ============================================================
-- SECTION 3 : RPCs Dashboard Admin
-- Toutes utilisent _verif_admin_cle() — compatible v5 + admin_config
-- ============================================================

-- 3a) Statistiques globales de la plateforme (KPI cards)
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

  -- Membres : somme des tableaux JSON membres dans chaque tontine
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
    -- Abonnements (table abonnements — peut être vide si pas encore utilisée)
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
    -- Revenus estimés (calcul simple : premium * tarif)
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

-- ─────────────────────────────────────────────────────────────

-- 3b) Liste complète des tontines enrichie (filtres + pagination)
create or replace function admin_dashboard_tontines(
  p_cle    text,
  p_filtre text  default 'toutes',
  -- 'toutes' | 'premium' | 'gratuites' | 'expires'
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

-- ─────────────────────────────────────────────────────────────

-- 3c) Liste des abonnements (filtrée par statut)
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

-- ─────────────────────────────────────────────────────────────

-- 3d) Alertes administrateur
-- FIX v1.2 : priorite extraite comme vraie colonne SQL (ORDER BY fonctionne)
--            Dans un UNION ALL, ORDER BY dans jsonb_agg ne peut pas référencer
--            une clé JSONB — on crée une colonne SQL séparée "prio".
create or replace function admin_alertes(p_cle text)
returns jsonb
language plpgsql security definer set search_path = public
as $$
begin
  if not _verif_admin_cle(p_cle) then return '[]'::jsonb; end if;

  return (
    -- ✅ FIX : ORDER BY sur la colonne SQL "prio", pas sur la clé JSONB
    select coalesce(jsonb_agg(alerte order by prio), '[]'::jsonb)
    from (

      -- Abonnements qui expirent dans 7 jours (priorité 1 — critique)
      select jsonb_build_object(
        'type',     'expiration_proche',
        'titre',    count(*)::text || ' abonnement(s) expire(nt) dans moins de 7 jours',
        'detail',   string_agg(code || ' (' || to_char(plan_expire, 'DD/MM/YYYY') || ')', ', '),
        'nb',       count(*),
        'niveau',   'alerte'
      ) as alerte,
      1 as prio   -- ✅ vraie colonne SQL, ORDER BY la trouve
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

      -- Demandes Premium en attente (priorité 1 — critique)
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

      -- Tontines Premium inactives depuis 30 jours (priorité 3 — info)
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

-- ─────────────────────────────────────────────────────────────

-- 3e) Enregistrer un abonnement Premium
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
    upper(p_code),
    p_formule,
    case p_formule when 'annuel' then 25000 else coalesce(p_montant, 2500) end,
    now(), v_date_fin,
    'actif', 'ADMIN', p_moyen, p_reference, p_note
  );

  -- Logger dans admin_actions
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

-- ─────────────────────────────────────────────────────────────

-- 3f) Statistiques mensuelles — évolution 12 derniers mois
--     ⚠️ C'est LA FONCTION MANQUANTE qui causait l'erreur !
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
      -- Générer les 12 derniers mois (inclus le mois courant)
      select generate_series(
        date_trunc('month', now() - interval '11 months'),
        date_trunc('month', now()),
        interval '1 month'
      ) as mois
    ) m
    left join (
      -- Nouvelles tontines créées ce mois
      select date_trunc('month', cree_le) as mois, count(*) as nb
      from tontines
      group by 1
    ) t on t.mois = m.mois
    left join (
      -- Tontines Premium actives ce mois
      select date_trunc('month', coalesce(plan_expire, now()) - interval '1 month') as mois,
             count(*) as nb
      from tontines
      where plan = 'premium'
      group by 1
    ) p on p.mois = m.mois
    left join (
      -- Revenus encaissés ce mois (depuis la table abonnements)
      select date_trunc('month', quand) as mois, sum(montant)::int as montant
      from abonnements
      where statut = 'actif'
      group by 1
    ) a on a.mois = m.mois
  );
end $$;

grant execute on function admin_stats_mensuelles(text) to anon;

-- ─────────────────────────────────────────────────────────────

-- 3g) Top 10 tontines par nombre de membres
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

-- ============================================================
-- SECTION 4 : Politiques RLS
-- ============================================================

-- abonnements : accès uniquement via RPC (security definer)
drop policy if exists "abonnements_no_direct" on abonnements;
create policy "abonnements_no_direct"
  on abonnements for all to anon using (false);

-- admin_actions : accès uniquement via RPC
drop policy if exists "admin_actions_no_direct" on admin_actions;
create policy "admin_actions_no_direct"
  on admin_actions for all to anon using (false);

-- demandes_premium : lecture + insertion directe autorisées (existant depuis v5)
drop policy if exists "demandes_premium_insert" on demandes_premium;
create policy "demandes_premium_insert"
  on demandes_premium for insert to anon with check (true);

drop policy if exists "demandes_premium_select" on demandes_premium;
create policy "demandes_premium_select"
  on demandes_premium for select to anon using (true);

-- ============================================================
-- SECTION 5 : Vérification post-déploiement
-- ============================================================
-- Exécuter ces requêtes SÉPARÉMENT pour valider le déploiement :
--
-- 1) Vérifier que la fonction est créée :
--    SELECT routine_name
--    FROM information_schema.routines
--    WHERE routine_name = 'admin_stats_mensuelles';
--    → Doit retourner 1 ligne
--
-- 2) Vérifier toutes les RPCs admin :
--    SELECT routine_name
--    FROM information_schema.routines
--    WHERE routine_name LIKE 'admin_%'
--    ORDER BY routine_name;
--    → Doit retourner au moins 9 lignes :
--      admin_activer_premium, admin_alertes, admin_dashboard_tontines,
--      admin_desactiver_premium, admin_enregistrer_abonnement,
--      admin_lister_abonnements, admin_lister_demandes, admin_lister_tontines,
--      admin_stats_globales, admin_stats_mensuelles, admin_top_tontines
--
-- 3) Tester admin_stats_mensuelles (remplacer VOTRE_CLE_ADMIN) :
--    SELECT admin_stats_mensuelles('VOTRE_CLE_ADMIN');
--    → Doit retourner un tableau JSON de 12 mois
--
-- 4) Tester admin_stats_globales (remplacer VOTRE_CLE_ADMIN) :
--    SELECT admin_stats_globales('VOTRE_CLE_ADMIN');
--    → Doit retourner un JSON avec total_tontines, premium_actives, etc.
--
-- ============================================================
-- FIN supabase-admin-fix.sql (v1.1)
-- ============================================================
