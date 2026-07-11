-- ============================================================
-- TontineClair — Mise à jour v6 : Score de Confiance IA
-- Version : v6.1 (quorum/majorité configurables, audit complet)
-- À coller dans : Supabase > SQL Editor > New query > Run
-- (à exécuter APRÈS supabase-v5.sql)
-- ============================================================

-- ============================================================
-- 1) TABLE : Historique des scores de confiance par membre
--    Une ligne est insérée à chaque événement impactant le score.
-- ============================================================
create table if not exists scores_historique (
  id           bigint generated always as identity primary key,
  code         text not null,
  membre_id    text not null,
  score        int  not null check (score between 0 and 100),
  score_prec   int  not null check (score_prec between 0 and 100),
  evenement    text not null,
  -- Valeurs : 'cotisation','retard','pret','remboursement','vote',
  --           'admin','sanction','retrait','anciennete'
  description  text not null,
  gestionnaire text,          -- null = calcul automatique
  quand        timestamptz not null default now()
);
create index if not exists idx_scores_hist_code_membre
  on scores_historique(code, membre_id);
create index if not exists idx_scores_hist_code_quand
  on scores_historique(code, quand desc);
alter table scores_historique enable row level security;

-- ============================================================
-- 2) TABLE : Propositions de retrait de membre
-- ============================================================
create table if not exists propositions_retrait (
  id            bigint generated always as identity primary key,
  code          text not null,
  membre_id     text not null,
  membre_nom    text not null,
  score_moment  int  not null,
  motif         text not null,
  propose_par   text not null,
  vote_id       text,          -- ID du vote créé dans tontines.data
  quorum        int  not null default 50,   -- % participation requis
  majorite      int  not null default 67,   -- % Pour requis (≈2/3)
  statut        text not null default 'en_attente'
                  check (statut in ('en_attente','vote_ouvert','accepte','refuse')),
  quand         timestamptz not null default now(),
  clos_le       timestamptz,
  resultat_oui  int default 0,
  resultat_non  int default 0,
  resultat_abs  int default 0
);
create index if not exists idx_prop_retrait_code
  on propositions_retrait(code);
create index if not exists idx_prop_retrait_membre
  on propositions_retrait(code, membre_id);
alter table propositions_retrait enable row level security;

-- ============================================================
-- 3) TABLE : Journal d'audit complet (modificiations sensibles)
-- ============================================================
create table if not exists journal_audit (
  id           bigint generated always as identity primary key,
  code         text not null,
  gestionnaire text not null,
  action       text not null,
  -- Valeurs : 'SCORE_MODIF','RETRAIT_PROPOSE','RETRAIT_ACCEPTE',
  --           'RETRAIT_REFUSE','MEMBRE_RETIRE','VOTE_CLOS','SCORE_AUTO'
  detail       text,
  membre_id    text,
  ancien_val   text,          -- valeur avant modification
  nouveau_val  text,          -- valeur après modification
  quand        timestamptz not null default now()
);
create index if not exists idx_journal_audit_code
  on journal_audit(code, quand desc);
alter table journal_audit enable row level security;

-- ============================================================
-- 4) FUNCTION : Enregistrer un événement de score
--    Appel automatique après cotisation, retard, prêt, vote, etc.
-- ============================================================
create or replace function enregistrer_score(
  p_code        text,
  p_membre_id   text,
  p_score       int,
  p_score_prec  int,
  p_evenement   text,
  p_description text,
  p_gestionnaire text default null
)
returns boolean
language plpgsql security definer set search_path = public
as $$
begin
  -- Validation
  if p_score < 0 or p_score > 100 then return false; end if;
  if p_score_prec < 0 or p_score_prec > 100 then return false; end if;

  -- Insérer dans l'historique
  insert into scores_historique(
    code, membre_id, score, score_prec, evenement, description, gestionnaire
  )
  values (
    upper(p_code), p_membre_id, p_score, p_score_prec,
    p_evenement, p_description, p_gestionnaire
  );

  -- Enregistrer dans le journal d'audit (table principale)
  insert into audit(code, gestionnaire, empreinte)
  values (
    upper(p_code),
    coalesce(p_gestionnaire, 'SYSTEME'),
    'SCORE:' || p_membre_id || ':' || p_score_prec || '->' || p_score || ':' || p_evenement
  );

  -- Enregistrer dans le journal d'audit détaillé (table v6)
  insert into journal_audit(code, gestionnaire, action, detail, membre_id, ancien_val, nouveau_val)
  values (
    upper(p_code),
    coalesce(p_gestionnaire, 'SYSTEME'),
    'SCORE_' || upper(p_evenement),
    p_description,
    p_membre_id,
    p_score_prec::text,
    p_score::text
  );

  return true;
end $$;

-- ============================================================
-- 5) FUNCTION : Lire l'historique des scores d'un membre
-- ============================================================
create or replace function lire_historique_score(
  p_code text,
  p_membre_id text
)
returns jsonb
language sql security definer set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',             id,
    'score',          score,
    'scorePrecedent', score_prec,
    'evenement',      evenement,
    'description',    description,
    'gestionnaire',   gestionnaire,
    'quand',          quand
  ) order by quand desc), '[]'::jsonb)
  from scores_historique
  where code = upper(p_code) and membre_id = p_membre_id;
$$;

-- ============================================================
-- 6) FUNCTION : Lire le dernier score de tous les membres
-- ============================================================
create or replace function lire_scores_tontine(p_code text)
returns jsonb
language sql security definer set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'membre_id',    membre_id,
    'dernier_score', score,
    'quand',        quand
  )), '[]'::jsonb)
  from (
    select distinct on (membre_id)
      membre_id, score, quand
    from scores_historique
    where code = upper(p_code)
    order by membre_id, quand desc
  ) t;
$$;

-- ============================================================
-- 7) FUNCTION : Créer une proposition de retrait
--    Vérifie le PIN gestionnaire, crée la proposition,
--    enregistre dans l'audit.
-- ============================================================
create or replace function proposer_retrait(
  p_code       text,
  p_nom        text,
  p_pin        text,
  p_membre_id  text,
  p_membre_nom text,
  p_score      int,
  p_motif      text,
  p_vote_id    text,
  p_quorum     int default 50,
  p_majorite   int default 67
)
returns boolean
language plpgsql security definer set search_path = public
as $$
begin
  -- Vérifier que le demandeur est gestionnaire authentifié
  if not exists (
    select 1 from tontines
    where code = upper(p_code)
      and gestionnaires @> jsonb_build_array(
            jsonb_build_object('nom', p_nom, 'pin', p_pin)
          )
  ) then return false; end if;

  -- Valider quorum et majorité
  if p_quorum < 0 or p_quorum > 100 then return false; end if;
  if p_majorite < 50 or p_majorite > 100 then return false; end if;

  -- Créer la proposition
  insert into propositions_retrait(
    code, membre_id, membre_nom, score_moment,
    motif, propose_par, vote_id, quorum, majorite, statut
  )
  values (
    upper(p_code), p_membre_id, p_membre_nom, p_score,
    p_motif, p_nom, p_vote_id, p_quorum, p_majorite, 'vote_ouvert'
  );

  -- Audit table principale
  insert into audit(code, gestionnaire, empreinte)
  values (
    upper(p_code), p_nom,
    'RETRAIT_PROPOSE:' || p_membre_id || ':score=' || p_score
    || ':quorum=' || p_quorum || ':majorite=' || p_majorite
    || ':' || left(p_motif, 80)
  );

  -- Audit détaillé
  insert into journal_audit(code, gestionnaire, action, detail, membre_id, nouveau_val)
  values (
    upper(p_code), p_nom, 'RETRAIT_PROPOSE',
    'Motif: ' || left(p_motif, 200) || ' | Quorum: ' || p_quorum
    || '% | Majorité: ' || p_majorite || '% | Score: ' || p_score,
    p_membre_id,
    p_vote_id
  );

  return true;
end $$;

-- ============================================================
-- 8) FUNCTION : Lire les propositions de retrait d'une tontine
-- ============================================================
create or replace function lire_propositions_retrait(p_code text)
returns jsonb
language sql security definer set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',           id,
    'membreId',     membre_id,
    'membreNom',    membre_nom,
    'scoreAuMoment', score_moment,
    'motif',        motif,
    'proposePar',   propose_par,
    'voteId',       vote_id,
    'quorum',       quorum,
    'majorite',     majorite,
    'statut',       statut,
    'quand',        quand,
    'closLe',       clos_le,
    'resultatOui',  resultat_oui,
    'resultatNon',  resultat_non,
    'resultatAbs',  resultat_abs
  ) order by quand desc), '[]'::jsonb)
  from propositions_retrait
  where code = upper(p_code);
$$;

-- ============================================================
-- 9) FUNCTION : Mettre à jour le statut d'une proposition
--    Appelée lors de la clôture d'un vote de retrait.
-- ============================================================
create or replace function maj_statut_retrait(
  p_code     text,
  p_nom      text,
  p_pin      text,
  p_vote_id  text,
  p_statut   text,  -- 'accepte' ou 'refuse'
  p_oui      int default 0,
  p_non      int default 0,
  p_abs      int default 0
)
returns boolean
language plpgsql security definer set search_path = public
as $$
begin
  if p_statut not in ('accepte','refuse') then return false; end if;

  -- Vérifier le gestionnaire
  if not exists (
    select 1 from tontines
    where code = upper(p_code)
      and gestionnaires @> jsonb_build_array(
            jsonb_build_object('nom', p_nom, 'pin', p_pin)
          )
  ) then return false; end if;

  -- Mettre à jour la proposition
  update propositions_retrait
  set
    statut       = p_statut,
    clos_le      = now(),
    resultat_oui = p_oui,
    resultat_non = p_non,
    resultat_abs = p_abs
  where code = upper(p_code) and vote_id = p_vote_id;

  -- Audit table principale
  insert into audit(code, gestionnaire, empreinte)
  values (
    upper(p_code), p_nom,
    'RETRAIT_' || upper(p_statut) || ':vote=' || p_vote_id
    || ':oui=' || p_oui || ':non=' || p_non || ':abs=' || p_abs
  );

  -- Audit détaillé
  insert into journal_audit(code, gestionnaire, action, detail, nouveau_val)
  values (
    upper(p_code), p_nom,
    'RETRAIT_' || upper(p_statut),
    'Vote ' || p_vote_id || ' | Oui: ' || p_oui || ' Non: ' || p_non || ' Abs: ' || p_abs,
    p_statut
  );

  return found;
end $$;

-- ============================================================
-- 10) FUNCTION : Lire le journal d'audit d'une tontine (v6)
-- ============================================================
create or replace function lire_journal_audit(
  p_code text,
  p_limite int default 50
)
returns jsonb
language sql security definer set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',           id,
    'gestionnaire', gestionnaire,
    'action',       action,
    'detail',       detail,
    'membreId',     membre_id,
    'ancienVal',    ancien_val,
    'nouveauVal',   nouveau_val,
    'quand',        quand
  ) order by quand desc), '[]'::jsonb)
  from (
    select * from journal_audit
    where code = upper(p_code)
    order by quand desc
    limit p_limite
  ) t;
$$;

-- ============================================================
-- 11) AUTORISATIONS pour le rôle anon (clients Flutter/Web)
-- ============================================================
grant execute on function enregistrer_score(text, text, int, int, text, text, text)
  to anon;
grant execute on function lire_historique_score(text, text)
  to anon;
grant execute on function lire_scores_tontine(text)
  to anon;
grant execute on function proposer_retrait(text, text, text, text, text, int, text, text, int, int)
  to anon;
grant execute on function lire_propositions_retrait(text)
  to anon;
grant execute on function maj_statut_retrait(text, text, text, text, text, int, int, int)
  to anon;
grant execute on function lire_journal_audit(text, int)
  to anon;

-- ============================================================
-- 12) POLICIES RLS — accès public (sécurité assurée par les RPCs)
-- ============================================================
-- scores_historique : lecture publique, écriture via RPC seulement
drop policy if exists "scores_historique_select" on scores_historique;
create policy "scores_historique_select"
  on scores_historique for select to anon using (true);

-- propositions_retrait : lecture publique, écriture via RPC seulement
drop policy if exists "propositions_retrait_select" on propositions_retrait;
create policy "propositions_retrait_select"
  on propositions_retrait for select to anon using (true);

-- journal_audit : lecture publique (filtré par RPC), écriture via RPC
drop policy if exists "journal_audit_select" on journal_audit;
create policy "journal_audit_select"
  on journal_audit for select to anon using (true);

-- ============================================================
-- FIN du script supabase-v6.sql
-- Vérification : SELECT count(*) FROM scores_historique;
-- ============================================================
