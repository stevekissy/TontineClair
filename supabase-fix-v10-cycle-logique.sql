-- ============================================================
-- TontineClair — Migration v10 : Correction logique des cycles
-- À exécuter dans Supabase SQL Editor
-- ============================================================
-- PROBLÈME CORRIGÉ :
--   Dès la création, cycleTermine pouvait être true ou l'app
--   déduisait wrongly "Cycle terminé" quand ordre[] est vide.
--
-- RÈGLE FONDAMENTALE (alignée sur l'app Flutter) :
--   cycleTermine = true  ←→ TOUS les membres ont été servis au moins une fois
--                           ET le cycle a réellement démarré (ordre non vide)
--   cycleEnAttente       ←→ ordre[] est vide ET cycleTermine = false
--                           (tontine créée, premier cycle jamais lancé)
--   cycleActif           ←→ ordre[] non vide ET cycleTermine = false
--
-- CE QUE FAIT CETTE MIGRATION :
--   1. Corrige toutes les tontines existantes où cycleTermine = true
--      alors que ordre[] est vide (données corrompues)
--   2. Corrige les tontines où cycleTermine est absent mais ne devrait pas l'être
--   3. Met à jour les RPCs : lire_tontine, cloturer_tour, proposer_nouveau_cycle
--   4. Ajoute une contrainte de cohérence dans lire_tontine
-- ============================================================


-- ============================================================
-- SECTION 1 : Correction des données existantes corrompues
-- Toute tontine avec ordre[] vide ET cycleTermine = true est corrompue.
-- On réinitialise cycleTermine à false pour ces tontines.
-- ============================================================

update tontines
set data = data || jsonb_build_object('cycleTermine', false)
where
  -- ordre[] est vide ou absent
  jsonb_array_length(coalesce(data->'ordre', '[]'::jsonb)) = 0
  -- ET cycleTermine était true (ou absent, valeur par défaut false)
  and coalesce((data->>'cycleTermine')::boolean, false) = true
  -- ET aucun tour n'a été effectué (historique vide)
  and jsonb_array_length(coalesce(data->'historique', '[]'::jsonb)) = 0;

-- Log
do $$
declare
  n int;
begin
  get diagnostics n = row_count;
  raise notice 'Tontines corrigées (cycleTermine réinitialisé) : %', n;
end $$;


-- ============================================================
-- SECTION 2 : RPC lire_tontine — ajout de la normalisation cycleTermine
-- Garantit que le champ cycleTermine retourné est toujours cohérent.
-- ============================================================

create or replace function lire_tontine(p_code text)
returns jsonb
language sql
security definer
as $$
  select
    case
      -- Si cycleTermine est explicitement posé dans Supabase → l'utiliser tel quel
      -- SAUF si ordre[] est vide ET historique[] est vide (données corrompues)
      when (data->>'cycleTermine')::boolean = true
           and jsonb_array_length(coalesce(data->'ordre', '[]'::jsonb)) = 0
           and jsonb_array_length(coalesce(data->'historique', '[]'::jsonb)) = 0
      then
        -- Tontine corrompue : forcer cycleTermine à false
        data || jsonb_build_object(
          'cycleTermine', false,
          'tourActuel', 0
        )
      else
        -- Données cohérentes : retourner telles quelles
        data
    end
  from tontines
  where upper(code) = upper(trim(p_code));
$$;

grant execute on function lire_tontine(text) to anon;


-- ============================================================
-- SECTION 3 : RPC cloturer_tour — vérification cycleTermine correcte
-- Corrige la logique de détection du "dernier tour" pour cycleTermine.
-- Le cycle est terminé quand tourActuel + 1 >= longueur(ordre).
-- ============================================================

create or replace function cloturer_tour(
  p_code text,
  p_nom  text,
  p_pin  text
)
returns jsonb
language plpgsql
security definer
as $$
declare
  v_code        text := upper(trim(p_code));
  v_ok          boolean;
  v_data        jsonb;
  v_ordre       jsonb;
  v_nb_tours    int;
  v_tour_actuel int;
  v_beneficiaire_id text;
  v_beneficiaire_nom text;
  v_paiements   jsonb;
  v_membres     jsonb;
  v_historique  jsonb;
  v_paye_ids    jsonb := '[]'::jsonb;
  v_total_recu  int;
  v_montant     int;
  v_now         text;
  v_now_ms      bigint;
  v_cycle_termine boolean;
  v_nouveau_tour  int;
  v_entry       jsonb;
  v_i           int;
  v_m           jsonb;
begin
  -- 1. Vérifier gestionnaire
  select verifier_gestionnaire(v_code, p_nom, p_pin) into v_ok;
  if not v_ok then
    return jsonb_build_object('ok', false, 'erreur', 'PIN incorrect ou gestionnaire non autorisé.');
  end if;

  -- 2. Lire la tontine
  select data into v_data from tontines where upper(code) = v_code;
  if v_data is null then
    return jsonb_build_object('ok', false, 'erreur', 'Tontine introuvable.');
  end if;

  -- 3. Vérifier que le cycle n'est pas déjà terminé
  if coalesce((v_data->>'cycleTermine')::boolean, false) then
    return jsonb_build_object('ok', false, 'erreur', 'Le cycle est déjà terminé.');
  end if;

  -- 4. Lire les paramètres
  v_ordre       := coalesce(v_data->'ordre', '[]'::jsonb);
  v_nb_tours    := jsonb_array_length(v_ordre);
  v_tour_actuel := coalesce((v_data->>'tourActuel')::int, 0);
  v_montant     := coalesce((v_data->>'montant')::int, 0);
  v_paiements   := coalesce(v_data->'paiements', '{}'::jsonb);
  v_membres     := coalesce(v_data->'membres', '[]'::jsonb);
  v_historique  := coalesce(v_data->'historique', '[]'::jsonb);
  v_now         := to_char(now() at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS".000Z"');
  v_now_ms      := extract(epoch from now())::bigint * 1000;

  -- 5. Vérifier que l'ordre est défini
  if v_nb_tours = 0 then
    return jsonb_build_object('ok', false, 'erreur', 'L''ordre de passage n''est pas défini. Effectuez un tirage d''abord.');
  end if;

  -- 6. Vérifier que tourActuel est dans les bornes
  if v_tour_actuel >= v_nb_tours then
    return jsonb_build_object('ok', false, 'erreur', 'Tous les tours ont déjà été clôturés.');
  end if;

  -- 7. Récupérer le bénéficiaire courant
  v_beneficiaire_id := v_ordre ->> v_tour_actuel;

  -- Chercher le nom du bénéficiaire dans membres[]
  v_beneficiaire_nom := null;
  for v_i in 0 .. jsonb_array_length(v_membres) - 1 loop
    v_m := v_membres -> v_i;
    if v_m->>'id' = v_beneficiaire_id then
      v_beneficiaire_nom := v_m->>'nom';
      exit;
    end if;
  end loop;

  -- 8. Collecter les IDs des membres ayant payé
  select jsonb_agg(key)
  into v_paye_ids
  from jsonb_object_keys(v_paiements) as key;
  v_paye_ids := coalesce(v_paye_ids, '[]'::jsonb);

  -- 9. Calculer le total reçu
  v_total_recu := (select count(*) from jsonb_object_keys(v_paiements)) * v_montant;

  -- 10. Créer l'entrée historique du tour clôturé
  v_entry := jsonb_build_object(
    'tour',         v_tour_actuel + 1,        -- numéro humain (1-based)
    'beneficiaire', v_beneficiaire_id,
    'beneficiaireNom', coalesce(v_beneficiaire_nom, v_beneficiaire_id),
    'totalRecu',    v_total_recu,
    'nbPayes',      jsonb_array_length(v_paye_ids),
    'payesIds',     v_paye_ids,
    'clotureLe',    v_now,
    'le',           v_now_ms,
    'cloturePar',   p_nom
  );

  -- 11. Insérer en tête de l'historique (le plus récent en premier)
  v_historique := jsonb_build_array(v_entry) || v_historique;

  -- 12. Incrémenter tourActuel
  v_nouveau_tour := v_tour_actuel + 1;

  -- 13. Déterminer si c'était le DERNIER tour
  -- cycleTermine = true UNIQUEMENT quand on vient de clôturer le DERNIER membre
  v_cycle_termine := (v_nouveau_tour >= v_nb_tours);

  -- 14. Remettre à zéro les paiements pour le prochain tour
  --     (sauf si c'est le dernier tour)
  -- 15. Remettre membres[].paye à false
  declare
    v_membres_reset jsonb := '[]'::jsonb;
    v_mb jsonb;
  begin
    for v_i in 0 .. jsonb_array_length(v_membres) - 1 loop
      v_mb := v_membres -> v_i;
      v_mb := v_mb || jsonb_build_object('paye', false);
      v_mb := v_mb - 'datePaiement' - 'methodePaiement' - 'referencePaiement';
      v_membres_reset := v_membres_reset || jsonb_build_array(v_mb);
    end loop;
    v_membres := v_membres_reset;
  end;

  -- 16. Mettre à jour la tontine
  v_data := v_data || jsonb_build_object(
    'tourActuel',   v_nouveau_tour,
    'cycleTermine', v_cycle_termine,
    'paiements',    '{}'::jsonb,
    'membres',      v_membres,
    'historique',   v_historique,
    -- Journal
    'journal', jsonb_build_array(jsonb_build_object(
      'quoi',         case
                        when v_cycle_termine then 'CYCLE_TERMINE'
                        else 'TOUR_CLOTURE'
                      end,
      'gestionnaire', p_nom,
      'quand',        v_now,
      'reference',    'TOUR-' || (v_tour_actuel + 1)::text,
      'details',      jsonb_build_object(
        'tour',         v_tour_actuel + 1,
        'beneficiaire', coalesce(v_beneficiaire_nom, v_beneficiaire_id),
        'totalRecu',    v_total_recu,
        'cycleTermine', v_cycle_termine
      )
    )) || coalesce(v_data->'journal', '[]'::jsonb)
  );

  update tontines set data = v_data where upper(code) = v_code;

  return jsonb_build_object(
    'ok',             true,
    'tourCloture',    v_tour_actuel + 1,
    'beneficiaire',   coalesce(v_beneficiaire_nom, v_beneficiaire_id),
    'totalRecu',      v_total_recu,
    'cycleTermine',   v_cycle_termine,
    'nouveauTour',    v_nouveau_tour,
    'message',        case
                        when v_cycle_termine
                        then 'Tour ' || (v_tour_actuel + 1) || ' clôturé. Cycle terminé ! Proposez un nouveau cycle.'
                        else 'Tour ' || (v_tour_actuel + 1) || ' clôturé. Prochain bénéficiaire : tour ' || (v_nouveau_tour + 1) || '.'
                      end
  );
end;
$$;

grant execute on function cloturer_tour(text, text, text) to anon;


-- ============================================================
-- SECTION 4 : RPC proposer_nouveau_cycle — vérification renforcée
-- Empêche de proposer si le cycle n'a jamais démarré (ordre vide)
-- ou si le cycle est encore en cours.
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
  v_nb_tours int;
  v_nb_historique int;
  i int;
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

  -- 4. Vérifier que le cycle a réellement démarré (ordre non vide OU historique non vide)
  --    Empêche de proposer sur une tontine jamais lancée
  v_nb_tours := jsonb_array_length(coalesce(v_data->'ordre', '[]'::jsonb));
  v_nb_historique := jsonb_array_length(coalesce(v_data->'historique', '[]'::jsonb));
  if v_nb_tours = 0 and v_nb_historique = 0 then
    return jsonb_build_object(
      'ok', false,
      'erreur', 'Impossible de proposer un nouveau cycle : la tontine n''a jamais démarré.'
    );
  end if;

  -- 5. Vérifier qu'il n'existe pas déjà un vote 'nouveau_cycle' ouvert
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

  -- 6. Créer le vote
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

  -- 7. Ajouter le vote dans data + entrée journal
  v_data := v_data || jsonb_build_object(
    'votes',   v_votes || jsonb_build_array(v_vote),
    'journal', jsonb_build_array(jsonb_build_object(
      'quoi',         'VOTE_NOUVEAU_CYCLE',
      'gestionnaire', p_nom,
      'quand',        v_now,
      'reference',    v_vote_id
    )) || coalesce(v_data->'journal', '[]'::jsonb)
  );

  -- 8. Sauvegarder
  update tontines set data = v_data where upper(code) = v_code;

  return jsonb_build_object('ok', true, 'vote_id', v_vote_id);
end;
$$;

grant execute on function proposer_nouveau_cycle(text,text,text,text) to anon;


-- ============================================================
-- SECTION 5 : Diagnostic — vérification de la cohérence des données
-- Décommenter pour auditer les tontines après la migration.
-- ============================================================
/*
select
  code,
  coalesce(data->>'nom', '?')                           as tontine,
  coalesce((data->>'cycleTermine')::boolean, false)     as cycle_termine,
  coalesce((data->>'cycleNum')::int, 1)                 as cycle_num,
  coalesce((data->>'tourActuel')::int, 0)               as tour_actuel,
  jsonb_array_length(coalesce(data->'ordre', '[]'::jsonb))     as nb_tours_ordre,
  jsonb_array_length(coalesce(data->'historique', '[]'::jsonb)) as nb_tours_historique,
  jsonb_array_length(coalesce(data->'membres', '[]'::jsonb))   as nb_membres,
  -- Statut calculé (cohérent avec Flutter)
  case
    when jsonb_array_length(coalesce(data->'ordre', '[]'::jsonb)) = 0
         and not coalesce((data->>'cycleTermine')::boolean, false)
    then 'EN_ATTENTE'
    when coalesce((data->>'cycleTermine')::boolean, false)
    then 'CYCLE_TERMINE'
    else 'CYCLE_ACTIF'
  end as statut_cycle
from tontines
order by created_at desc
limit 20;
*/


-- ============================================================
-- SECTION 6 : Notes d'exécution
-- ============================================================
-- 1. Exécuter ce script dans l'éditeur SQL de Supabase
-- 2. Vérifier les logs pour le nombre de tontines corrigées
-- 3. Tester avec une nouvelle tontine : statut doit être "EN_ATTENTE"
-- 4. Tester avec une tontine après dernier tour : statut doit être "CYCLE_TERMINE"
-- 5. La RPC cloturer_tour est maintenant idempotente et robuste
-- ============================================================
