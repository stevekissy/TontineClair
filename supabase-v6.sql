-- ============================================================
-- TontineClair — Migration v6.2 : Score de Confiance IA
-- Version     : v6.2 (idempotente, safe à relancer plusieurs fois)
-- Projet      : ubrqtcxbxcmvmxleiglh (Supabase)
--
-- INSTRUCTIONS DE DÉPLOIEMENT :
--   1. Ouvrir https://supabase.com/dashboard/project/ubrqtcxbxcmvmxleiglh
--   2. Menu gauche : "SQL Editor" → "New query"
--   3. Copier-coller tout ce fichier
--   4. Cliquer "Run" (raccourci : Ctrl+Enter)
--   5. Vérifier le message : "Success. No rows returned."
--
-- CE SCRIPT :
--   ✅ Ne supprime AUCUNE donnée existante
--   ✅ Peut être relancé sans risque (IF NOT EXISTS / OR REPLACE)
--   ✅ Ne touche pas aux tables existantes (tontines, voix, audit, etc.)
--   ✅ Crée uniquement les nouvelles tables et fonctions v6
-- ============================================================

-- ============================================================
-- SECTION 1 : Tables v6 (création idempotente)
-- ============================================================

-- 1a) Historique des scores de confiance
--     Une ligne est insérée à chaque événement impactant le score.
create table if not exists scores_historique (
  id           bigint generated always as identity primary key,
  code         text        not null,
  membre_id    text        not null,
  score        int         not null check (score between 0 and 100),
  score_prec   int         not null check (score_prec between 0 and 100),
  evenement    text        not null,
  -- Valeurs attendues : 'cotisation','retard','pret','remboursement',
  --                     'vote','admin','sanction','retrait','anciennete','init'
  description  text        not null,
  gestionnaire text,          -- null = calcul automatique système
  quand        timestamptz not null default now()
);
create index if not exists idx_scores_hist_code_membre
  on scores_historique(code, membre_id);
create index if not exists idx_scores_hist_code_quand
  on scores_historique(code, quand desc);
alter table scores_historique enable row level security;

-- 1b) Propositions de retrait de membre
create table if not exists propositions_retrait (
  id            bigint generated always as identity primary key,
  code          text        not null,
  membre_id     text        not null,
  membre_nom    text        not null,
  score_moment  int         not null,
  motif         text        not null,
  propose_par   text        not null,
  vote_id       text,          -- ID du vote créé dans tontines.data
  quorum        int         not null default 50,   -- % participation requis
  majorite      int         not null default 67,   -- % Pour requis (≈2/3)
  statut        text        not null default 'en_attente'
                  check (statut in ('en_attente','vote_ouvert','accepte','refuse')),
  quand         timestamptz not null default now(),
  clos_le       timestamptz,
  resultat_oui  int         default 0,
  resultat_non  int         default 0,
  resultat_abs  int         default 0
);
create index if not exists idx_prop_retrait_code
  on propositions_retrait(code);
create index if not exists idx_prop_retrait_membre
  on propositions_retrait(code, membre_id);
alter table propositions_retrait enable row level security;

-- 1c) Journal d'audit détaillé (modifications sensibles)
create table if not exists journal_audit (
  id           bigint generated always as identity primary key,
  code         text        not null,
  gestionnaire text        not null,
  action       text        not null,
  -- Valeurs : 'SCORE_MODIF','RETRAIT_PROPOSE','RETRAIT_ACCEPTE',
  --           'RETRAIT_REFUSE','MEMBRE_RETIRE','SCORE_AUTO','SCORE_INIT'
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
-- SECTION 2 : Colonnes additionnelles (idempotentes)
-- Ajouter des colonnes manquantes sans casser l'existant.
-- ============================================================

-- Rien à ajouter dans cette version — les tables sont nouvelles.

-- ============================================================
-- SECTION 3 : Fonctions RPC (CREATE OR REPLACE = idempotent)
-- ============================================================

-- 3a) Enregistrer un événement de score
--     Appelé depuis Flutter après cotisation, vote, prêt, etc.
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
  -- Validations
  if p_score      < 0 or p_score      > 100 then return false; end if;
  if p_score_prec < 0 or p_score_prec > 100 then return false; end if;
  if p_code is null or p_membre_id is null   then return false; end if;

  -- Insérer dans l'historique
  insert into scores_historique(
    code, membre_id, score, score_prec, evenement, description, gestionnaire
  )
  values (
    upper(p_code), p_membre_id, p_score, p_score_prec,
    p_evenement, p_description, p_gestionnaire
  );

  -- Enregistrer dans le journal d'audit v6
  insert into journal_audit(
    code, gestionnaire, action, detail, membre_id, ancien_val, nouveau_val
  )
  values (
    upper(p_code),
    coalesce(p_gestionnaire, 'SYSTEME'),
    'SCORE_' || upper(p_evenement),
    p_description,
    p_membre_id,
    p_score_prec::text,
    p_score::text
  );

  -- Enregistrer dans la table audit principale si elle existe
  begin
    insert into audit(code, gestionnaire, empreinte)
    values (
      upper(p_code),
      coalesce(p_gestionnaire, 'SYSTEME'),
      'SCORE:' || p_membre_id || ':' || p_score_prec || '->' || p_score
      || ':' || p_evenement
    );
  exception when undefined_table then
    -- table audit absente — silencieux
    null;
  end;

  return true;
end $$;

-- 3b) Lire l'historique des scores d'un membre
create or replace function lire_historique_score(
  p_code      text,
  p_membre_id text
)
returns jsonb
language sql security definer set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',             id,
    'score',          score,
    'scorePrecedent', score_prec,
    'delta',          score - score_prec,
    'evenement',      evenement,
    'description',    description,
    'gestionnaire',   gestionnaire,
    'quand',          to_char(quand at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
  ) order by quand desc), '[]'::jsonb)
  from scores_historique
  where code = upper(p_code) and membre_id = p_membre_id;
$$;

-- 3c) Lire le dernier score enregistré de tous les membres d'une tontine
create or replace function lire_scores_tontine(p_code text)
returns jsonb
language sql security definer set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'membre_id',     membre_id,
    'dernier_score', score,
    'score_prec',    score_prec,
    'delta',         score - score_prec,
    'evenement',     evenement,
    'quand',         to_char(quand at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
  )), '[]'::jsonb)
  from (
    select distinct on (membre_id)
      membre_id, score, score_prec, evenement, quand
    from scores_historique
    where code = upper(p_code)
    order by membre_id, quand desc
  ) t;
$$;

-- 3d) Créer une proposition de retrait
--     Vérifie le PIN gestionnaire, crée la proposition, log l'audit.
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
  if p_quorum   < 0  or p_quorum   > 100 then return false; end if;
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

  -- Audit détaillé v6
  insert into journal_audit(
    code, gestionnaire, action, detail, membre_id, nouveau_val
  )
  values (
    upper(p_code), p_nom, 'RETRAIT_PROPOSE',
    'Motif: ' || left(p_motif, 200)
    || ' | Quorum: '   || p_quorum   || '%'
    || ' | Majorité: ' || p_majorite || '%'
    || ' | Score: '    || p_score,
    p_membre_id,
    p_vote_id
  );

  -- Audit table principale (si elle existe)
  begin
    insert into audit(code, gestionnaire, empreinte)
    values (
      upper(p_code), p_nom,
      'RETRAIT_PROPOSE:' || p_membre_id
      || ':score='    || p_score
      || ':quorum='   || p_quorum
      || ':majorite=' || p_majorite
      || ':' || left(p_motif, 80)
    );
  exception when undefined_table then null; end;

  return true;
end $$;

-- 3e) Lire les propositions de retrait d'une tontine
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
    'quand',        to_char(quand at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'closLe',       to_char(clos_le at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'resultatOui',  resultat_oui,
    'resultatNon',  resultat_non,
    'resultatAbs',  resultat_abs
  ) order by quand desc), '[]'::jsonb)
  from propositions_retrait
  where code = upper(p_code);
$$;

-- 3f) Mettre à jour le statut d'une proposition de retrait
--     Appelée lors de la clôture d'un vote de retrait.
create or replace function maj_statut_retrait(
  p_code     text,
  p_nom      text,
  p_pin      text,
  p_vote_id  text,
  p_statut   text,   -- 'accepte' ou 'refuse'
  p_oui      int     default 0,
  p_non      int     default 0,
  p_abs      int     default 0
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

  -- Audit v6
  insert into journal_audit(
    code, gestionnaire, action, detail, nouveau_val
  )
  values (
    upper(p_code), p_nom,
    'RETRAIT_' || upper(p_statut),
    'Vote ' || p_vote_id
    || ' | Oui: ' || p_oui
    || ' Non: '   || p_non
    || ' Abs: '   || p_abs,
    p_statut
  );

  -- Audit principal
  begin
    insert into audit(code, gestionnaire, empreinte)
    values (
      upper(p_code), p_nom,
      'RETRAIT_' || upper(p_statut)
      || ':vote=' || p_vote_id
      || ':oui='  || p_oui
      || ':non='  || p_non
      || ':abs='  || p_abs
    );
  exception when undefined_table then null; end;

  return found;
end $$;

-- 3g) Lire le journal d'audit d'une tontine
create or replace function lire_journal_audit(
  p_code   text,
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
    'quand',        to_char(quand at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
  ) order by quand desc), '[]'::jsonb)
  from (
    select * from journal_audit
    where code = upper(p_code)
    order by quand desc
    limit p_limite
  ) t;
$$;

-- 3h) Initialiser/recalculer le score d'un membre (backfill)
--     Insère une entrée d'init uniquement si aucun historique n'existe.
--     Idempotent : si score déjà présent, n'insère pas de doublon.
create or replace function init_score_membre(
  p_code      text,
  p_membre_id text,
  p_score     int,
  p_desc      text default 'Score initial calculé depuis les données existantes'
)
returns boolean
language plpgsql security definer set search_path = public
as $$
begin
  if p_score < 0 or p_score > 100 then return false; end if;

  -- N'insérer que si aucun historique n'existe pour ce membre
  if not exists (
    select 1 from scores_historique
    where code = upper(p_code) and membre_id = p_membre_id
  ) then
    insert into scores_historique(
      code, membre_id, score, score_prec, evenement, description, gestionnaire
    )
    values (
      upper(p_code), p_membre_id, p_score, p_score, 'init', p_desc, 'SYSTEME'
    );

    insert into journal_audit(
      code, gestionnaire, action, detail, membre_id, ancien_val, nouveau_val
    )
    values (
      upper(p_code), 'SYSTEME', 'SCORE_INIT',
      p_desc, p_membre_id, '50', p_score::text
    );
  else
    -- Mettre à jour uniquement si le score a changé
    update scores_historique
    set score = p_score
    where id = (
      select id from scores_historique
      where code = upper(p_code) and membre_id = p_membre_id
        and evenement = 'init'
      order by quand asc
      limit 1
    )
    and score != p_score;
  end if;

  return true;
end $$;

-- ============================================================
-- SECTION 4 : Autorisations (GRANT)
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
grant execute on function init_score_membre(text, text, int, text)
  to anon;

-- ============================================================
-- SECTION 5 : Politiques RLS
-- ============================================================

-- scores_historique : lecture publique via RPC, écriture via security definer
drop policy if exists "scores_historique_select" on scores_historique;
create policy "scores_historique_select"
  on scores_historique for select to anon using (true);

-- propositions_retrait : lecture publique, écriture via RPC seulement
drop policy if exists "propositions_retrait_select" on propositions_retrait;
create policy "propositions_retrait_select"
  on propositions_retrait for select to anon using (true);

-- journal_audit : lecture publique (filtrée par RPC), écriture via RPC
drop policy if exists "journal_audit_select" on journal_audit;
create policy "journal_audit_select"
  on journal_audit for select to anon using (true);

-- ============================================================
-- SECTION 6 : Vérification post-migration
-- ============================================================
-- Lancer ces requêtes pour vérifier le déploiement :

-- SELECT count(*) FROM scores_historique;       -- doit retourner 0 (ou N si backfill)
-- SELECT count(*) FROM propositions_retrait;    -- doit retourner 0
-- SELECT count(*) FROM journal_audit;           -- doit retourner 0 (ou N si backfill)
-- SELECT proname FROM pg_proc
--   WHERE proname IN (
--     'enregistrer_score','lire_historique_score','lire_scores_tontine',
--     'proposer_retrait','lire_propositions_retrait','maj_statut_retrait',
--     'lire_journal_audit','init_score_membre'
--   ); -- doit retourner 8 lignes

-- ============================================================
-- FIN de la migration supabase-v6.sql (v6.2)
-- ============================================================
