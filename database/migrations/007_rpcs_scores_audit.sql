-- ============================================================
-- TontineClair — Migration 007 : RPCs Score de Confiance & Audit
-- Source     : supabase-v6.sql (v6.2) + supabase-v14-FINAL.sql
-- Dépendances: 001_tables_core.sql, 002_tables_scores_audit.sql
-- Idempotent : CREATE OR REPLACE FUNCTION partout
-- ============================================================
-- Fonctions incluses (11) :
--   enregistrer_score, lire_historique_score, lire_scores_tontine,
--   proposer_retrait, lire_propositions_retrait, maj_statut_retrait,
--   lire_journal_audit, init_score_membre,
--   modifier_score_membre (v14-FINAL),
--   lire_score_membre    (v14-FINAL),
--   reinitialiser_score_override (v14-FINAL)
-- ============================================================

-- ────────────────────────────────────────────────────────────
-- 1. enregistrer_score
--    Enregistre un événement de score dans scores_historique + journal_audit
-- ────────────────────────────────────────────────────────────
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
  if p_score      < 0 or p_score      > 100 then return false; end if;
  if p_score_prec < 0 or p_score_prec > 100 then return false; end if;
  if p_code is null or p_membre_id is null   then return false; end if;

  insert into scores_historique(
    code, membre_id, score, score_prec, evenement, description, gestionnaire
  )
  values (
    upper(p_code), p_membre_id, p_score, p_score_prec,
    p_evenement, p_description, p_gestionnaire
  );

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

  begin
    insert into audit(code, gestionnaire, empreinte)
    values (
      upper(p_code),
      coalesce(p_gestionnaire, 'SYSTEME'),
      'SCORE:' || p_membre_id || ':' || p_score_prec || '->' || p_score
      || ':' || p_evenement
    );
  exception when undefined_table then null;
  end;

  return true;
end $$;

grant execute on function enregistrer_score(text, text, int, int, text, text, text) to anon;

-- ────────────────────────────────────────────────────────────
-- 2. lire_historique_score
--    Retourne l'historique des scores d'un membre (JSON)
-- ────────────────────────────────────────────────────────────
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

grant execute on function lire_historique_score(text, text) to anon;

-- ────────────────────────────────────────────────────────────
-- 3. lire_scores_tontine
--    Dernier score de chaque membre d'une tontine
-- ────────────────────────────────────────────────────────────
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

grant execute on function lire_scores_tontine(text) to anon;

-- ────────────────────────────────────────────────────────────
-- 4. proposer_retrait
--    Crée une proposition de retrait de membre + audit
-- ────────────────────────────────────────────────────────────
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
  if not exists (
    select 1 from tontines
    where code = upper(p_code)
      and gestionnaires @> jsonb_build_array(
            jsonb_build_object('nom', p_nom, 'pin', p_pin)
          )
  ) then return false; end if;

  if p_quorum   < 0  or p_quorum   > 100 then return false; end if;
  if p_majorite < 50 or p_majorite > 100 then return false; end if;

  insert into propositions_retrait(
    code, membre_id, membre_nom, score_moment,
    motif, propose_par, vote_id, quorum, majorite, statut
  )
  values (
    upper(p_code), p_membre_id, p_membre_nom, p_score,
    p_motif, p_nom, p_vote_id, p_quorum, p_majorite, 'vote_ouvert'
  );

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

grant execute on function proposer_retrait(text, text, text, text, text, int, text, text, int, int) to anon;

-- ────────────────────────────────────────────────────────────
-- 5. lire_propositions_retrait
--    Toutes les propositions de retrait d'une tontine
-- ────────────────────────────────────────────────────────────
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

grant execute on function lire_propositions_retrait(text) to anon;

-- ────────────────────────────────────────────────────────────
-- 6. maj_statut_retrait
--    Clôture une proposition : accepté ou refusé
-- ────────────────────────────────────────────────────────────
create or replace function maj_statut_retrait(
  p_code     text,
  p_nom      text,
  p_pin      text,
  p_vote_id  text,
  p_statut   text,
  p_oui      int default 0,
  p_non      int default 0,
  p_abs      int default 0
)
returns boolean
language plpgsql security definer set search_path = public
as $$
begin
  if p_statut not in ('accepte','refuse') then return false; end if;

  if not exists (
    select 1 from tontines
    where code = upper(p_code)
      and gestionnaires @> jsonb_build_array(
            jsonb_build_object('nom', p_nom, 'pin', p_pin)
          )
  ) then return false; end if;

  update propositions_retrait
  set
    statut       = p_statut,
    clos_le      = now(),
    resultat_oui = p_oui,
    resultat_non = p_non,
    resultat_abs = p_abs
  where code = upper(p_code) and vote_id = p_vote_id;

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

grant execute on function maj_statut_retrait(text, text, text, text, text, int, int, int) to anon;

-- ────────────────────────────────────────────────────────────
-- 7. lire_journal_audit
--    Journal d'audit d'une tontine (N dernières entrées)
-- ────────────────────────────────────────────────────────────
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

grant execute on function lire_journal_audit(text, int) to anon;

-- ────────────────────────────────────────────────────────────
-- 8. init_score_membre
--    Backfill : initialise le score si aucun historique n'existe
-- ────────────────────────────────────────────────────────────
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

grant execute on function init_score_membre(text, text, int, text) to anon;

-- ────────────────────────────────────────────────────────────
-- 9. modifier_score_membre  [SOURCE: supabase-v14-FINAL.sql]
--    Modification manuelle du score par un gestionnaire
--    Écrit dans tontines.data.membres[].scoreOverride
--    + scores_historique + journal_audit + audit
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION modifier_score_membre(
  p_code       text,
  p_nom        text,
  p_pin        text,
  p_membre_id  text,
  p_nouveau    integer,
  p_motif      text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $func$
DECLARE
  v_code    text    := upper(trim(p_code));
  v_ancien  integer := 50;
  v_data    jsonb;
  v_membres jsonb;
  v_membre  jsonb;
  v_idx     integer := -1;
  v_found   boolean := false;
  v_now     text    := to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"');
  i         integer;
BEGIN
  IF p_nouveau < 0 OR p_nouveau > 100 THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Score invalide 0-100');
  END IF;
  IF p_motif IS NULL OR length(trim(p_motif)) < 3 THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Motif trop court');
  END IF;

  SELECT data INTO v_data FROM tontines WHERE code = v_code;
  IF v_data IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Tontine introuvable');
  END IF;

  IF NOT (
    (v_data->'gestionnaires' IS NOT NULL
     AND v_data->'gestionnaires' @> jsonb_build_array(
           jsonb_build_object('nom', p_nom, 'pin', p_pin)))
    OR EXISTS (
      SELECT 1 FROM tontines
      WHERE code = v_code
        AND gestionnaires @> jsonb_build_array(
              jsonb_build_object('nom', p_nom, 'pin', p_pin)))
    OR EXISTS (
      SELECT 1 FROM tontines t,
             jsonb_array_elements(COALESCE(t.gestionnaires, '[]'::jsonb)) g
      WHERE t.code = v_code
        AND (g->>'nom') = p_nom
        AND (g->>'pin') = p_pin)
  ) THEN
    RETURN jsonb_build_object('ok', false, 'message', 'PIN gestionnaire incorrect');
  END IF;

  v_membres := coalesce(v_data->'membres', '[]'::jsonb);

  FOR i IN 0 .. jsonb_array_length(v_membres) - 1 LOOP
    v_membre := v_membres->i;
    IF (v_membre->>'id') = p_membre_id THEN
      v_ancien := COALESCE(
        (v_membre->>'scoreOverride')::integer,
        (v_membre->>'score')::integer,
        50);
      v_idx   := i;
      v_found := true;
      EXIT;
    END IF;
  END LOOP;

  IF NOT v_found THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Membre introuvable');
  END IF;

  v_membres := jsonb_set(
    v_membres,
    ARRAY[v_idx::text],
    (v_membres->v_idx) || jsonb_build_object(
      'scoreOverride', p_nouveau,
      'motifOverride', trim(p_motif),
      'dateOverride',  v_now,
      'adminOverride', p_nom,
      'score',         p_nouveau),
    false);

  UPDATE tontines
  SET data = jsonb_set(v_data, '{membres}', v_membres, false)
  WHERE code = v_code;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Echec update');
  END IF;

  BEGIN
    INSERT INTO scores_historique(code, membre_id, score, score_prec, evenement, description, gestionnaire)
    VALUES (v_code, p_membre_id, p_nouveau, v_ancien, 'admin',
            'Modif manuelle par ' || p_nom || ' : ' || trim(p_motif), p_nom);
  EXCEPTION WHEN others THEN NULL;
  END;

  BEGIN
    INSERT INTO journal_audit(code, gestionnaire, action, detail, membre_id, ancien_val, nouveau_val)
    VALUES (v_code, p_nom, 'SCORE_MODIF', trim(p_motif), p_membre_id, v_ancien::text, p_nouveau::text);
  EXCEPTION WHEN others THEN NULL;
  END;

  BEGIN
    INSERT INTO audit(code, gestionnaire, empreinte)
    VALUES (v_code, p_nom, 'SCORE:' || p_membre_id || ':' || v_ancien || '->' || p_nouveau);
  EXCEPTION WHEN others THEN NULL;
  END;

  RETURN jsonb_build_object('ok', true, 'ancien', v_ancien, 'nouveau', p_nouveau,
    'message', 'Score ' || v_ancien || ' -> ' || p_nouveau);
END;
$func$;

GRANT EXECUTE ON FUNCTION modifier_score_membre(text,text,text,text,integer,text) TO anon, authenticated;

-- ────────────────────────────────────────────────────────────
-- 10. lire_score_membre  [SOURCE: supabase-v14-FINAL.sql]
--     Lit le score effectif (override ou calculé) depuis tontines.data
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION lire_score_membre(p_code text, p_membre_id text)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $func$
  SELECT jsonb_build_object(
    'membre_id',     p_membre_id,
    'score',         COALESCE((m->>'scoreOverride')::integer, (m->>'score')::integer, 50),
    'scoreOverride', (m->>'scoreOverride')::integer,
    'motifOverride', m->>'motifOverride',
    'dateOverride',  m->>'dateOverride',
    'adminOverride', m->>'adminOverride'
  )
  FROM tontines t,
       jsonb_array_elements(COALESCE(t.data->'membres', '[]'::jsonb)) AS m
  WHERE t.code = upper(p_code)
    AND (m->>'id') = p_membre_id
  LIMIT 1;
$func$;

GRANT EXECUTE ON FUNCTION lire_score_membre(text,text) TO anon, authenticated;

-- ────────────────────────────────────────────────────────────
-- 11. reinitialiser_score_override  [SOURCE: supabase-v14-FINAL.sql]
--     Supprime les champs scoreOverride/* du JSON membres
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION reinitialiser_score_override(p_code text, p_nom text, p_pin text, p_membre_id text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $func$
DECLARE
  v_code    text := upper(trim(p_code));
  v_data    jsonb;
  v_membres jsonb;
  v_membre  jsonb;
  i         integer;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM tontines t,
           jsonb_array_elements(COALESCE(t.gestionnaires, '[]'::jsonb)) g
    WHERE t.code = v_code AND (g->>'nom') = p_nom AND (g->>'pin') = p_pin
  ) THEN RETURN false; END IF;

  SELECT data INTO v_data FROM tontines WHERE code = v_code;
  IF v_data IS NULL THEN RETURN false; END IF;

  v_membres := COALESCE(v_data->'membres', '[]'::jsonb);

  FOR i IN 0 .. jsonb_array_length(v_membres) - 1 LOOP
    IF (v_membres->i->>'id') = p_membre_id THEN
      v_membre  := (v_membres->i) - 'scoreOverride' - 'motifOverride' - 'dateOverride' - 'adminOverride';
      v_membres := jsonb_set(v_membres, ARRAY[i::text], v_membre, false);
      EXIT;
    END IF;
  END LOOP;

  UPDATE tontines SET data = jsonb_set(v_data, '{membres}', v_membres, false) WHERE code = v_code;
  RETURN true;
END;
$func$;

GRANT EXECUTE ON FUNCTION reinitialiser_score_override(text,text,text,text) TO anon, authenticated;

-- ────────────────────────────────────────────────────────────
-- RLS : accès en lecture directe (protégé via security definer)
-- ────────────────────────────────────────────────────────────
drop policy if exists "scores_historique_select" on scores_historique;
create policy "scores_historique_select"
  on scores_historique for select to anon using (true);

drop policy if exists "propositions_retrait_select" on propositions_retrait;
create policy "propositions_retrait_select"
  on propositions_retrait for select to anon using (true);

drop policy if exists "journal_audit_select" on journal_audit;
create policy "journal_audit_select"
  on journal_audit for select to anon using (true);

-- ────────────────────────────────────────────────────────────
-- Vérification post-déploiement
-- ────────────────────────────────────────────────────────────
DO $verify007$
DECLARE
  v_fns text[] := ARRAY[
    'enregistrer_score','lire_historique_score','lire_scores_tontine',
    'proposer_retrait','lire_propositions_retrait','maj_statut_retrait',
    'lire_journal_audit','init_score_membre',
    'modifier_score_membre','lire_score_membre','reinitialiser_score_override'
  ];
  v_fn text;
  v_ok boolean;
BEGIN
  FOREACH v_fn IN ARRAY v_fns LOOP
    SELECT EXISTS(SELECT 1 FROM pg_proc WHERE proname = v_fn) INTO v_ok;
    RAISE NOTICE '007 % : %', v_fn, CASE WHEN v_ok THEN 'OK' ELSE 'MANQUANT' END;
  END LOOP;
END;
$verify007$;
-- ============================================================
-- FIN 007_rpcs_scores_audit.sql
-- ============================================================
