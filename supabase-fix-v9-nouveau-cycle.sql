-- ============================================================
-- TontineClair — Migration v9 : Nouveau Cycle par Vote
-- À exécuter dans Supabase SQL Editor
-- ============================================================
-- Cette migration ajoute le support complet du "Nouveau Cycle" :
--   1. RPC proposer_nouveau_cycle  — crée le vote de redémarrage
--   2. RPC lire_etat_cycle         — lit le statut + vote de redémarrage
--   3. RPC demarrer_nouveau_cycle  — démarre le cycle si vote accepté
--   4. RPC clore_vote_redemarrage  — clôture le vote et applique le résultat
--   5. RPC annuler_proposition     — annule une proposition refusée
-- ============================================================

-- ============================================================
-- SECTION 1 : RPC proposer_nouveau_cycle
-- Créée par le gestionnaire quand cycleTermine == true.
-- Ajoute un vote de type 'nouveau_cycle' dans data['votes'].
-- Prévient les doublons : un seul vote 'nouveau_cycle' ouvert à la fois.
-- ============================================================

create or replace function proposer_nouveau_cycle(
  p_code      text,
  p_nom       text,
  p_pin       text,
  p_question  text  default 'Souhaitez-vous recommencer un nouveau cycle de tontine ?'
)
returns jsonb
language plpgsql
security definer
as $$
declare
  v_code   text := upper(trim(p_code));
  v_ok     boolean;
  v_data   jsonb;
  v_votes  jsonb;
  v_vote   jsonb;
  v_vote_id text;
  v_now    text;
  v_nb_membres int;
  v_cycle_termine boolean;
begin
  -- 1. Vérifier le gestionnaire
  select verifier_gestionnaire(v_code, p_nom, p_pin) into v_ok;
  if not v_ok then
    return jsonb_build_object('ok', false, 'erreur', 'PIN incorrect ou gestionnaire non autorisé.');
  end if;

  -- 2. Lire la tontine
  select data into v_data from tontines where upper(code) = v_code;
  if v_data is null then
    return jsonb_build_object('ok', false, 'erreur', 'Tontine introuvable.');
  end if;

  -- 3. Vérifier que le cycle est bien terminé
  v_cycle_termine := coalesce((v_data->>'cycleTermine')::boolean, false);
  if not v_cycle_termine then
    return jsonb_build_object('ok', false, 'erreur', 'Le cycle n''est pas encore terminé.');
  end if;

  -- 4. Vérifier qu'il n'existe pas déjà un vote 'nouveau_cycle' ouvert
  v_votes := coalesce(v_data->'votes', '[]'::jsonb);
  for i in 0 .. jsonb_array_length(v_votes) - 1 loop
    v_vote := v_votes -> i;
    if (v_vote->>'type' = 'nouveau_cycle')
       and coalesce(v_vote->>'statut', 'ouvert') = 'ouvert'
       and coalesce((v_vote->>'clos')::boolean, false) = false
    then
      return jsonb_build_object(
        'ok', false,
        'erreur', 'Un vote de redémarrage est déjà en cours.',
        'vote_id', v_vote->>'id'
      );
    end if;
  end loop;

  -- 5. Créer le vote
  v_vote_id := 'NC-' || to_char(now(), 'YYYYMMDDHH24MISS') || '-' || substr(md5(random()::text), 1, 4);
  v_now := to_char(now() at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS".000Z"');
  v_nb_membres := coalesce(jsonb_array_length(v_data->'membres'), 0);

  v_vote := jsonb_build_object(
    'id',           v_vote_id,
    'type',         'nouveau_cycle',
    'sujet',        p_question,
    'question',     p_question,
    'creePar',      p_nom,
    'createur',     p_nom,
    'le',           v_now,
    'dateCreation', v_now,
    'statut',       'ouvert',
    'clos',         false,
    'voix',         '{}'::jsonb,
    'decompte',     jsonb_build_object('oui', 0, 'non', 0, 'abstention', 0),
    'description',  'Vote de redémarrage — Cycle ' || coalesce(v_data->>'cycleNum', '1'),
    'mode',         'securise',
    'quorum',       ceil(v_nb_membres::float / 2)::int,
    'cycleRefConfig', jsonb_build_object(
      'montant',      (v_data->>'montant')::int,
      'periodicite',  coalesce(v_data->>'periodicite', v_data->>'periode', 'mensuel'),
      'methodeOrdre', coalesce(v_data->>'methodeOrdre', 'rotation')
    )
  );

  -- 6. Ajouter le vote dans data + entrée journal
  v_data := v_data || jsonb_build_object(
    'votes',   v_votes || jsonb_build_array(v_vote),
    'journal', jsonb_build_array(jsonb_build_object(
      'quoi',         'VOTE_NOUVEAU_CYCLE',
      'gestionnaire', p_nom,
      'quand',        v_now,
      'reference',    v_vote_id
    )) || coalesce(v_data->'journal', '[]'::jsonb)
  );

  -- 7. Sauvegarder
  update tontines set data = v_data where upper(code) = v_code;

  return jsonb_build_object('ok', true, 'vote_id', v_vote_id);
end;
$$;

grant execute on function proposer_nouveau_cycle(text,text,text,text) to anon;


-- ============================================================
-- SECTION 2 : RPC lire_etat_cycle
-- Retourne le statut du cycle + le vote de redémarrage s'il existe.
-- Lecture publique (anon) — ne retourne pas les PINs.
-- ============================================================

create or replace function lire_etat_cycle(p_code text)
returns jsonb
language sql
security definer
as $$
  with t as (
    select data from tontines where upper(code) = upper(trim(p_code))
  ),
  vote_nc as (
    select v
    from t, jsonb_array_elements(coalesce(t.data->'votes', '[]'::jsonb)) v
    where v->>'type' = 'nouveau_cycle'
    order by v->>'dateCreation' desc
    limit 1
  )
  select jsonb_build_object(
    'cycleTermine',      coalesce((t.data->>'cycleTermine')::boolean, false),
    'cycleNum',          coalesce((t.data->>'cycleNum')::int, 1),
    'tourActuel',        coalesce((t.data->>'tourActuel')::int, 0),
    'nbMembres',         coalesce(jsonb_array_length(t.data->'membres'), 0),
    'nbTours',           coalesce(jsonb_array_length(t.data->'ordre'), 0),
    'voteRedemarrage',   (select v from vote_nc),
    'peutProposer',      coalesce((t.data->>'cycleTermine')::boolean, false)
                         and not exists (
                           select 1 from jsonb_array_elements(coalesce(t.data->'votes', '[]'::jsonb)) vv
                           where vv->>'type' = 'nouveau_cycle'
                           and coalesce(vv->>'statut', 'ouvert') = 'ouvert'
                         )
  )
  from t;
$$;

grant execute on function lire_etat_cycle(text) to anon;


-- ============================================================
-- SECTION 3 : RPC demarrer_nouveau_cycle
-- Démarre réellement le nouveau cycle UNIQUEMENT si :
--   - cycleTermine == true
--   - le vote 'nouveau_cycle' est CLOS et adopté
--   - aucun cycle plus récent n'a déjà été créé
-- Préserve l'intégralité de l'historique + caisse + prêts + votes.
-- Remet à zéro uniquement les données du cycle courant.
-- ============================================================

create or replace function demarrer_nouveau_cycle(
  p_code         text,
  p_nom          text,
  p_pin          text,
  p_vote_id      text,
  p_montant      int     default null,   -- null = conserver l'ancien
  p_periodicite  text    default null,   -- null = conserver l'ancienne
  p_echeance     text    default null,   -- null = calculer automatiquement
  p_methode_ordre text   default null    -- null = conserver l'ancienne
)
returns jsonb
language plpgsql
security definer
as $$
declare
  v_code         text := upper(trim(p_code));
  v_ok           boolean;
  v_data         jsonb;
  v_votes        jsonb;
  v_vote         jsonb;
  v_vote_idx     int  := -1;
  v_now          text;
  v_cycle_num    int;
  v_nouveau_montant int;
  v_nouvelle_periode text;
  v_nouvelle_methode text;
  v_nouvelle_echeance text;
  v_ancienne_historique jsonb;
  v_archive_cycle jsonb;
  v_membres      jsonb;
  v_i            int;
  v_membre       jsonb;
  v_ordre_ancien jsonb;
begin
  -- 1. Vérifier le gestionnaire
  select verifier_gestionnaire(v_code, p_nom, p_pin) into v_ok;
  if not v_ok then
    return jsonb_build_object('ok', false, 'erreur', 'PIN incorrect.');
  end if;

  -- 2. Lire la tontine
  select data into v_data from tontines where upper(code) = v_code;
  if v_data is null then
    return jsonb_build_object('ok', false, 'erreur', 'Tontine introuvable.');
  end if;

  -- 3. Vérifier cycleTermine
  if not coalesce((v_data->>'cycleTermine')::boolean, false) then
    return jsonb_build_object('ok', false, 'erreur', 'Le cycle n''est pas encore terminé.');
  end if;

  -- 4. Trouver le vote de redémarrage par ID
  v_votes := coalesce(v_data->'votes', '[]'::jsonb);
  for v_i in 0 .. jsonb_array_length(v_votes) - 1 loop
    v_vote := v_votes -> v_i;
    if v_vote->>'id' = p_vote_id then
      v_vote_idx := v_i;
      exit;
    end if;
  end loop;

  if v_vote_idx = -1 then
    return jsonb_build_object('ok', false, 'erreur', 'Vote de redémarrage introuvable.');
  end if;

  -- 5. Vérifier que le vote est clos et adopté
  if coalesce(v_vote->>'statut', 'ouvert') != 'clos' then
    return jsonb_build_object('ok', false, 'erreur', 'Le vote de redémarrage n''est pas encore clôturé.');
  end if;
  if not coalesce((v_vote->>'adopte')::boolean, false) then
    return jsonb_build_object('ok', false, 'erreur', 'Le vote de redémarrage a été refusé.');
  end if;

  -- 6. Vérifier qu'on n'a pas déjà démarré un cycle depuis ce vote
  if coalesce((v_vote->>'cycleCreePar')::boolean, false) then
    return jsonb_build_object('ok', false, 'erreur', 'Un nouveau cycle a déjà été créé depuis ce vote.');
  end if;

  -- 7. Préparer les paramètres du nouveau cycle
  v_now := to_char(now() at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS".000Z"');
  v_cycle_num := coalesce((v_data->>'cycleNum')::int, 1) + 1;

  v_nouveau_montant := coalesce(p_montant, (v_data->>'montant')::int);
  v_nouvelle_periode := coalesce(p_periodicite, v_data->>'periodicite', v_data->>'periode', 'mensuel');
  v_nouvelle_methode := coalesce(p_methode_ordre, v_data->>'methodeOrdre', 'rotation');

  -- Calcul échéance automatique si non fournie
  if p_echeance is not null and p_echeance != '' then
    v_nouvelle_echeance := p_echeance;
  else
    case v_nouvelle_periode
      when 'journalier'  then v_nouvelle_echeance := to_char(now() + interval '1 day', 'YYYY-MM-DD"T"HH24:MI:SS".000Z"');
      when 'hebdo'       then v_nouvelle_echeance := to_char(now() + interval '7 days', 'YYYY-MM-DD"T"HH24:MI:SS".000Z"');
      when 'mensuel'     then v_nouvelle_echeance := to_char(now() + interval '1 month', 'YYYY-MM-DD"T"HH24:MI:SS".000Z"');
      when 'trimestriel' then v_nouvelle_echeance := to_char(now() + interval '3 months', 'YYYY-MM-DD"T"HH24:MI:SS".000Z"');
      else v_nouvelle_echeance := to_char(now() + interval '1 month', 'YYYY-MM-DD"T"HH24:MI:SS".000Z"');
    end case;
  end if;

  -- 8. Archiver le cycle terminé dans historique des cycles
  v_ancienne_historique := coalesce(v_data->'historique', '[]'::jsonb);
  v_ordre_ancien := coalesce(v_data->'ordre', '[]'::jsonb);

  v_archive_cycle := jsonb_build_object(
    'cycleNum',      coalesce((v_data->>'cycleNum')::int, 1),
    'termineLe',     v_now,
    'montant',       (v_data->>'montant')::int,
    'periodicite',   coalesce(v_data->>'periodicite', v_data->>'periode', 'mensuel'),
    'nbMembres',     coalesce(jsonb_array_length(v_data->'membres'), 0),
    'historiqueTours', v_ancienne_historique,
    'ordre',         v_ordre_ancien,
    'voteId',        p_vote_id
  );

  -- 9. Remettre à zéro les membres (paye=false, garder le reste)
  v_membres := coalesce(v_data->'membres', '[]'::jsonb);
  declare
    v_membres_reset jsonb := '[]'::jsonb;
    v_m jsonb;
  begin
    for v_i in 0 .. jsonb_array_length(v_membres) - 1 loop
      v_m := v_membres -> v_i;
      -- Conserver id, nom, tel, role, score — reset paye
      v_m := v_m || jsonb_build_object('paye', false);
      -- Supprimer datePaiement, methodePaiement, referencePaiement
      v_m := v_m - 'datePaiement' - 'methodePaiement' - 'referencePaiement';
      v_membres_reset := v_membres_reset || jsonb_build_array(v_m);
    end loop;
    v_membres := v_membres_reset;
  end;

  -- 10. Marquer le vote comme "cycle créé" pour éviter les doublons
  v_vote := v_vote || jsonb_build_object('cycleCreePar', true, 'cycleNum', v_cycle_num);
  v_votes := jsonb_set(v_votes, array[v_vote_idx::text], v_vote);

  -- 11. Construire le nouveau data en préservant :
  --     caisse, prets, votes, journal, stats, gestionnaires
  --     Et en ajoutant cyclesArchives
  v_data := v_data
    -- Nouveau cycle
    || jsonb_build_object(
         'cycleTermine',   false,
         'tourActuel',     0,
         'cycleNum',       v_cycle_num,
         'montant',        v_nouveau_montant,
         'periodicite',    v_nouvelle_periode,
         'periode',        v_nouvelle_periode,
         'methodeOrdre',   v_nouvelle_methode,
         'echeance',       v_nouvelle_echeance,
         -- Remise à zéro des données du cycle
         'paiements',      '{}'::jsonb,
         'historique',     '[]'::jsonb,
         'ordre',          '[]'::jsonb,
         'ordreVerrouille', false,
         'ordreMeta',      jsonb_build_object('verrouille', false, 'methode', v_nouvelle_methode, 'tirage', null),
         -- Membres réinitialisés
         'membres',        v_membres,
         -- Votes mis à jour (vote marqué cycleCreePar)
         'votes',          v_votes,
         -- Archives des anciens cycles
         'cyclesArchives', jsonb_build_array(v_archive_cycle)
                           || coalesce(v_data->'cyclesArchives', '[]'::jsonb),
         -- Journal
         'journal',        jsonb_build_array(jsonb_build_object(
                             'quoi',         'NOUVEAU_CYCLE_DEMARRE',
                             'gestionnaire', p_nom,
                             'quand',        v_now,
                             'reference',    'CYCLE-' || v_cycle_num::text,
                             'details',      jsonb_build_object(
                               'cycleNum',   v_cycle_num,
                               'montant',    v_nouveau_montant,
                               'periodicite', v_nouvelle_periode,
                               'voteId',     p_vote_id
                             )
                           )) || coalesce(v_data->'journal', '[]'::jsonb)
       );

  -- 12. Sauvegarder
  update tontines set data = v_data where upper(code) = v_code;

  return jsonb_build_object(
    'ok',         true,
    'cycleNum',   v_cycle_num,
    'montant',    v_nouveau_montant,
    'periodicite', v_nouvelle_periode,
    'echeance',   v_nouvelle_echeance,
    'message',    'Cycle ' || v_cycle_num || ' démarré avec succès.'
  );
end;
$$;

grant execute on function demarrer_nouveau_cycle(text,text,text,text,int,text,text,text) to anon;


-- ============================================================
-- SECTION 4 : RPC clore_vote_redemarrage
-- Clôture le vote de redémarrage et calcule le résultat.
-- Appelée par le gestionnaire quand le délai est écoulé ou manuellement.
-- ============================================================

create or replace function clore_vote_redemarrage(
  p_code    text,
  p_nom     text,
  p_pin     text,
  p_vote_id text
)
returns jsonb
language plpgsql
security definer
as $$
declare
  v_code    text := upper(trim(p_code));
  v_ok      boolean;
  v_data    jsonb;
  v_votes   jsonb;
  v_vote    jsonb;
  v_i       int;
  v_vote_idx int := -1;
  v_voix    jsonb;
  v_nb_oui  int := 0;
  v_nb_non  int := 0;
  v_nb_abs  int := 0;
  v_quorum  int;
  v_nb_membres int;
  v_adopte  boolean;
  v_now     text;
  v_choix   text;
begin
  select verifier_gestionnaire(v_code, p_nom, p_pin) into v_ok;
  if not v_ok then
    return jsonb_build_object('ok', false, 'erreur', 'PIN incorrect.');
  end if;

  select data into v_data from tontines where upper(code) = v_code;
  if v_data is null then
    return jsonb_build_object('ok', false, 'erreur', 'Tontine introuvable.');
  end if;

  v_votes := coalesce(v_data->'votes', '[]'::jsonb);
  for v_i in 0 .. jsonb_array_length(v_votes) - 1 loop
    if (v_votes -> v_i)->>'id' = p_vote_id then
      v_vote := v_votes -> v_i;
      v_vote_idx := v_i;
      exit;
    end if;
  end loop;

  if v_vote_idx = -1 then
    return jsonb_build_object('ok', false, 'erreur', 'Vote introuvable.');
  end if;

  if coalesce(v_vote->>'statut', 'ouvert') = 'clos' then
    return jsonb_build_object('ok', false, 'erreur', 'Ce vote est déjà clôturé.');
  end if;

  -- Compter les voix
  v_voix := coalesce(v_vote->'voix', '{}'::jsonb);
  v_nb_membres := coalesce(jsonb_array_length(v_data->'membres'), 0);
  v_quorum := coalesce((v_vote->>'quorum')::int, ceil(v_nb_membres::float / 2)::int);

  for v_choix in select jsonb_object_keys(v_voix) loop
    case (v_voix ->> v_choix)
      when 'oui'        then v_nb_oui  := v_nb_oui  + 1;
      when 'non'        then v_nb_non  := v_nb_non  + 1;
      when 'abstention' then v_nb_abs  := v_nb_abs  + 1;
      else null;
    end case;
  end loop;

  -- Règle : adopté si Oui strict > Non et quorum atteint
  v_adopte := (v_nb_oui > v_nb_non) and ((v_nb_oui + v_nb_non + v_nb_abs) >= v_quorum);
  v_now := to_char(now() at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS".000Z"');

  -- Mettre à jour le vote
  v_vote := v_vote || jsonb_build_object(
    'statut',    'clos',
    'clos',      true,
    'closLe',    v_now,
    'dateCloture', v_now,
    'adopte',    v_adopte,
    'resultat',  case when v_adopte then 'ACCEPTÉ' else 'REFUSÉ' end,
    'decompte',  jsonb_build_object('oui', v_nb_oui, 'non', v_nb_non, 'abstention', v_nb_abs)
  );

  v_votes := jsonb_set(v_votes, array[v_vote_idx::text], v_vote);

  -- Journal
  v_data := v_data || jsonb_build_object(
    'votes',  v_votes,
    'journal', jsonb_build_array(jsonb_build_object(
      'quoi',         case when v_adopte then 'VOTE_REDEMARRAGE_ACCEPTE' else 'VOTE_REDEMARRAGE_REFUSE' end,
      'gestionnaire', p_nom,
      'quand',        v_now,
      'reference',    p_vote_id,
      'details',      jsonb_build_object('oui', v_nb_oui, 'non', v_nb_non, 'abstention', v_nb_abs, 'adopte', v_adopte)
    )) || coalesce(v_data->'journal', '[]'::jsonb)
  );

  update tontines set data = v_data where upper(code) = v_code;

  return jsonb_build_object(
    'ok',        true,
    'adopte',    v_adopte,
    'oui',       v_nb_oui,
    'non',       v_nb_non,
    'abstention', v_nb_abs,
    'message',   case when v_adopte then 'Vote ACCEPTÉ — nouveau cycle autorisé.' else 'Vote REFUSÉ — cycle non redémarré.' end
  );
end;
$$;

grant execute on function clore_vote_redemarrage(text,text,text,text) to anon;


-- ============================================================
-- SECTION 5 : Vue audit des cycles (diagnostic optionnel)
-- ============================================================
-- Décommenter pour vérifier l'état des cycles :
/*
select
  code,
  coalesce(data->>'nom', '?')                 as tontine,
  coalesce((data->>'cycleTermine')::boolean, false) as cycle_termine,
  coalesce((data->>'cycleNum')::int, 1)         as cycle_num,
  coalesce((data->>'tourActuel')::int, 0)       as tour_actuel,
  jsonb_array_length(coalesce(data->'ordre', '[]'::jsonb)) as nb_tours,
  (
    select count(*) from jsonb_array_elements(coalesce(data->'votes', '[]'::jsonb)) v
    where v->>'type' = 'nouveau_cycle' and coalesce(v->>'statut','ouvert') = 'ouvert'
  ) as votes_redemarrage_ouverts
from tontines
order by created_at desc
limit 20;
*/
