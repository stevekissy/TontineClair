-- ============================================================
-- TontineClair — Migration Abonnements v1.0
-- Fichier  : supabase-subscriptions.sql
-- Version  : 1.0 — Source unique de vérité abonnements
-- Date     : 2025-07
--
-- CE SCRIPT :
--   ✅ Idempotent — safe à relancer plusieurs fois
--   ✅ NE supprime AUCUNE donnée existante
--   ✅ CREATE TABLE IF NOT EXISTS
--   ✅ CREATE OR REPLACE FUNCTION
--   ✅ Compatible avec l'architecture v5/v6 (tontines.plan)
--
-- PRÉREQUIS : supabase-v5.sql + supabase-admin-fix.sql déployés
--
-- INSTRUCTIONS :
--   1. Supabase > SQL Editor > New query
--   2. Copier-coller ce fichier complet
--   3. Run (Ctrl+Enter)
--   4. Message attendu : "Success. No rows returned."
-- ============================================================

-- ============================================================
-- SECTION 1 : Table subscriptions (source unique de vérité)
-- ============================================================

create table if not exists subscriptions (
  id                bigint generated always as identity primary key,
  -- Lien avec la tontine (architecture actuelle)
  code              text        not null,
  -- Identifiant propriétaire (si auth Supabase activée plus tard)
  owner_id          text,
  -- Plan : 'free' | 'premium_monthly' | 'premium_yearly'
  plan              text        not null default 'free'
                      check (plan in ('free','premium_monthly','premium_yearly')),
  -- Plateforme d'achat
  platform          text        not null default 'web'
                      check (platform in ('web','android','ios')),
  -- Fournisseur de paiement
  provider          text        not null default 'web'
                      check (provider in ('web','google_play','apple','admin')),
  -- Identifiants store
  product_id        text,
  purchase_token    text,   -- Google Play
  transaction_id    text,   -- Apple
  -- Dates
  started_at        timestamptz not null default now(),
  expires_at        timestamptz,
  -- Statut
  status            text        not null default 'active'
                      check (status in ('active','expired','cancelled','pending','grace_period')),
  auto_renew        boolean     not null default false,
  last_verified_at  timestamptz,
  -- Montant
  montant_fcfa      int         not null default 0,
  devise            text        not null default 'FCFA',
  -- Méta
  reference         text,
  note              text,
  active_par        text,
  cree_le           timestamptz not null default now(),
  modifie_le        timestamptz not null default now()
);

-- Index pour les requêtes fréquentes
create index if not exists idx_subscriptions_code
  on subscriptions(code);
create index if not exists idx_subscriptions_status
  on subscriptions(status, expires_at);
create index if not exists idx_subscriptions_platform
  on subscriptions(platform);

-- Trigger : mettre à jour modifie_le automatiquement
create or replace function _sub_update_modifie_le()
returns trigger language plpgsql as $$
begin
  new.modifie_le := now();
  return new;
end $$;

drop trigger if exists trg_sub_modifie_le on subscriptions;
create trigger trg_sub_modifie_le
  before update on subscriptions
  for each row execute function _sub_update_modifie_le();

-- RLS : jamais d'accès direct, uniquement via RPC security definer
alter table subscriptions enable row level security;

drop policy if exists "subscriptions_no_direct" on subscriptions;
create policy "subscriptions_no_direct"
  on subscriptions for all to anon using (false);

-- ============================================================
-- SECTION 2 : Vérification du statut d'abonnement actif
-- ============================================================

-- Vérifie si un code tontine a un abonnement Premium actif.
-- Combine :
--   1. La nouvelle table subscriptions
--   2. L'ancien champ tontines.plan (rétrocompatibilité)
create or replace function est_premium(p_code text)
returns boolean
language plpgsql security definer set search_path = public
as $$
declare
  v_ok boolean := false;
begin
  -- Source 1 : nouvelle table subscriptions
  begin
    select exists(
      select 1 from subscriptions
      where code = upper(p_code)
        and plan in ('premium_monthly','premium_yearly')
        and status in ('active','grace_period')
        and (expires_at is null or expires_at > now())
    ) into v_ok;
  exception when undefined_table then
    v_ok := false;
  end;

  if v_ok then return true; end if;

  -- Source 2 : champ plan dans tontines (fallback v5/v6)
  begin
    select exists(
      select 1 from tontines
      where code = upper(p_code)
        and plan = 'premium'
        and (plan_expire is null or plan_expire > now())
    ) into v_ok;
  exception when undefined_column, undefined_table then
    v_ok := false;
  end;

  return coalesce(v_ok, false);
end $$;

grant execute on function est_premium(text) to anon;

-- ============================================================
-- SECTION 3 : Lire l'abonnement complet d'une tontine
-- Utilisé par SubscriptionService.charger() Flutter
-- ============================================================

create or replace function lire_abonnement_tontine(p_code text)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_sub   subscriptions%rowtype;
  v_plan  text := 'free';
  v_exp   timestamptz;
begin
  -- 1. Chercher dans la table subscriptions
  select * into v_sub
  from subscriptions
  where code = upper(p_code)
    and status in ('active','grace_period','pending')
  order by cree_le desc
  limit 1;

  if found then
    return jsonb_build_object(
      'plan',             v_sub.plan,
      'status',           v_sub.status,
      'platform',         v_sub.platform,
      'provider',         v_sub.provider,
      'product_id',       v_sub.product_id,
      'started_at',       v_sub.started_at,
      'expires_at',       v_sub.expires_at,
      'auto_renew',       v_sub.auto_renew,
      'last_verified_at', v_sub.last_verified_at,
      'montant_fcfa',     v_sub.montant_fcfa
    );
  end if;

  -- 2. Fallback : champ plan dans tontines
  begin
    select t.plan, t.plan_expire
    into v_plan, v_exp
    from tontines t
    where t.code = upper(p_code)
    limit 1;
  exception when others then
    null;
  end;

  if v_plan = 'premium' then
    return jsonb_build_object(
      'plan',     'premium_monthly',
      'status',   case when (v_exp is null or v_exp > now()) then 'active' else 'expired' end,
      'platform', 'web',
      'provider', 'web',
      'expires_at', v_exp,
      'auto_renew', false
    );
  end if;

  -- 3. Compte gratuit par défaut
  return jsonb_build_object(
    'plan',     'free',
    'status',   'active',
    'platform', 'web',
    'provider', 'web',
    'auto_renew', false
  );
end $$;

grant execute on function lire_abonnement_tontine(text) to anon;

-- ============================================================
-- SECTION 4 : Vérification limites Gratuit
-- Appelées avant création tontine / ajout membre
-- ============================================================

-- Vérifie si la création d'une nouvelle tontine est autorisée
-- Retourne un objet JSON : {autorise: bool, message: text}
create or replace function verif_limite_tontines(
  p_code_proprietaire text   -- code de la tontine "propriétaire" (ou user_id futur)
)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_premium boolean := false;
  v_nb      int     := 0;
begin
  -- Pour l'instant, la vérification est simplifiée (architecture v5/v6)
  -- Dans l'architecture avec auth Supabase, on utilisera user_id
  v_premium := false; -- sera enrichi quand auth sera activée

  -- Toujours autorisé pour l'instant (limite appliquée côté Flutter)
  return jsonb_build_object(
    'autorise', true,
    'premium',  v_premium,
    'nb',       v_nb,
    'message',  ''
  );
end $$;

grant execute on function verif_limite_tontines(text) to anon;

-- Vérifie si l'ajout d'un membre est autorisé dans une tontine
create or replace function verif_limite_membres(p_code text)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_premium  boolean := false;
  v_nb       int     := 0;
  v_max      int     := 5;
  v_autorise boolean := false;
begin
  -- Statut Premium de la tontine
  v_premium := est_premium(p_code);

  -- Nombre de membres actuels
  begin
    select
      case
        when jsonb_typeof(data->'membres') = 'array'
          then jsonb_array_length(data->'membres')
        else 0
      end
    into v_nb
    from tontines
    where code = upper(p_code)
    limit 1;
  exception when others then
    v_nb := 0;
  end;

  v_max      := case when v_premium then 999 else 5 end;
  v_autorise := v_nb < v_max;

  return jsonb_build_object(
    'autorise', v_autorise,
    'premium',  v_premium,
    'nb',       v_nb,
    'max',      v_max,
    'message',  case when not v_autorise then
      case when v_premium then
        'Limite de membres Premium atteinte.'
      else
        'La formule gratuite est limitée à 5 membres. Passez à Premium pour ajouter davantage de membres.'
      end
    else '' end
  );
end $$;

grant execute on function verif_limite_membres(text) to anon;

-- ============================================================
-- SECTION 5 : Enregistrer un abonnement web validé
-- ============================================================

create or replace function enregistrer_abonnement_web(
  p_code       text,
  p_plan       text    default 'premium_monthly',
  p_montant    int     default 2500,
  p_reference  text    default null,
  p_note       text    default null,
  p_active_par text    default 'ADMIN'
)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_expires_at timestamptz;
  v_new_id     bigint;
begin
  -- Calculer la date d'expiration
  v_expires_at := case p_plan
    when 'premium_yearly'  then now() + interval '1 year'
    else                        now() + interval '1 month'
  end;

  -- Expirer les abonnements actifs existants pour ce code
  update subscriptions
  set status     = 'expired',
      modifie_le = now()
  where code = upper(p_code)
    and status in ('active','grace_period');

  -- Créer le nouvel abonnement
  insert into subscriptions(
    code, plan, platform, provider,
    started_at, expires_at, status, auto_renew,
    montant_fcfa, reference, note, active_par,
    last_verified_at
  )
  values (
    upper(p_code), p_plan, 'web', 'web',
    now(), v_expires_at, 'active', false,
    case p_plan when 'premium_yearly' then 25000 else coalesce(p_montant, 2500) end,
    p_reference, p_note, p_active_par,
    now()
  )
  returning id into v_new_id;

  -- Mettre à jour tontines.plan (synchronisation rétrocompatible)
  begin
    update tontines
    set plan       = 'premium',
        plan_expire = v_expires_at
    where code = upper(p_code);
  exception when undefined_column then
    null;
  end;

  -- Logger dans admin_actions
  begin
    insert into admin_actions(code, action, detail, effectue_par)
    values (
      upper(p_code),
      'ABONNEMENT_WEB_CREE',
      'Plan: ' || p_plan || ' | Montant: ' || coalesce(p_montant::text,'2500') || ' FCFA | Réf: ' || coalesce(p_reference,'-'),
      coalesce(p_active_par, 'ADMIN')
    );
  exception when undefined_table, undefined_column then
    null;
  end;

  return jsonb_build_object(
    'ok',         true,
    'id',         v_new_id,
    'code',       upper(p_code),
    'plan',       p_plan,
    'expires_at', v_expires_at
  );
end $$;

grant execute on function enregistrer_abonnement_web(text, text, int, text, text, text) to anon;

-- ============================================================
-- SECTION 6 : Stats abonnements pour le Dashboard Admin
-- ============================================================

create or replace function admin_stats_abonnements(p_cle text)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare v_now timestamptz := now();
begin
  if not _verif_admin_cle(p_cle) then return null; end if;

  return jsonb_build_object(
    -- Depuis nouvelle table subscriptions
    'sub_total',          (select count(*) from subscriptions),
    'sub_actifs',         (select count(*) from subscriptions
                           where status in ('active','grace_period')
                             and (expires_at is null or expires_at > v_now)),
    'sub_expires',        (select count(*) from subscriptions
                           where status = 'expired'
                              or (expires_at is not null and expires_at <= v_now)),
    'sub_annules',        (select count(*) from subscriptions where status = 'cancelled'),
    'sub_web',            (select count(*) from subscriptions where platform = 'web'),
    'sub_android',        (select count(*) from subscriptions where platform = 'android'),
    'sub_ios',            (select count(*) from subscriptions where platform = 'ios'),
    'sub_mensuel',        (select count(*) from subscriptions
                           where plan = 'premium_monthly' and status = 'active'),
    'sub_annuel',         (select count(*) from subscriptions
                           where plan = 'premium_yearly'  and status = 'active'),
    'revenu_web',         (select coalesce(sum(montant_fcfa),0) from subscriptions
                           where platform = 'web' and status = 'active'),
    'revenu_android',     (select coalesce(sum(montant_fcfa),0) from subscriptions
                           where platform = 'android' and status = 'active'),
    'revenu_ios',         (select coalesce(sum(montant_fcfa),0) from subscriptions
                           where platform = 'ios' and status = 'active'),
    'revenu_total',       (select coalesce(sum(montant_fcfa),0) from subscriptions
                           where status = 'active'),
    'expirent_7j',        (select count(*) from subscriptions
                           where status = 'active'
                             and expires_at is not null
                             and expires_at > v_now
                             and expires_at < v_now + interval '7 days'),
    'calcule_le',         v_now
  );
end $$;

grant execute on function admin_stats_abonnements(text) to anon;

-- ============================================================
-- SECTION 7 : Passer automatiquement les abonnements expirés
-- ============================================================

create or replace function expirer_abonnements_obsoletes()
returns int
language plpgsql security definer set search_path = public
as $$
declare v_nb int;
begin
  update subscriptions
  set status     = 'expired',
      modifie_le = now()
  where status = 'active'
    and expires_at is not null
    and expires_at <= now();

  get diagnostics v_nb = row_count;

  -- Synchroniser tontines.plan (rétrocompatibilité)
  begin
    update tontines t
    set plan       = 'free',
        plan_expire = t.plan_expire  -- laisser la date pour référence
    where t.plan = 'premium'
      and t.plan_expire is not null
      and t.plan_expire <= now()
      and not exists (
        select 1 from subscriptions s
        where s.code = t.code
          and s.status in ('active','grace_period')
      );
  exception when undefined_column then
    null;
  end;

  return v_nb;
end $$;

grant execute on function expirer_abonnements_obsoletes() to anon;

-- ============================================================
-- SECTION 8 : Vérification post-déploiement
-- ============================================================
-- Exécuter SÉPARÉMENT pour valider :
--
-- 1) Toutes les fonctions créées :
--    SELECT routine_name FROM information_schema.routines
--    WHERE routine_name IN (
--      'est_premium','lire_abonnement_tontine','verif_limite_membres',
--      'enregistrer_abonnement_web','admin_stats_abonnements',
--      'expirer_abonnements_obsoletes'
--    );
--    → 6 lignes attendues
--
-- 2) Table subscriptions :
--    SELECT * FROM subscriptions LIMIT 5;
--    → 0 lignes (vide = normal)
--
-- 3) Test est_premium (code existant) :
--    SELECT est_premium('VOTRE_CODE');
--    → false (normal si pas d'abonnement)
--
-- ============================================================
-- FIN supabase-subscriptions.sql (v1.0)
-- ============================================================
