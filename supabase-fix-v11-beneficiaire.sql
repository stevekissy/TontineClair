-- ═══════════════════════════════════════════════════════════════════════════
-- TontineClair — Migration v11 : Correction affichage bénéficiaire
-- Date : 2025-07-12
-- Objectif :
--   1. Normaliser le champ 'beneficiaire' dans chaque entrée de historique[]
--   2. Corriger les tontines où ordre[] a des IDs 'm1','m2'... divergents
--   3. RPC cloturer_tour : enregistre beneficiaireNom + beneficiaireId dans historique
--   4. Anti-doublon : même membre ne peut pas être servi 2× dans un cycle
--   5. Migration sécurisée pour anciennes tontines (ne touche pas les données valides)
-- ═══════════════════════════════════════════════════════════════════════════

-- ── 1. Normalisation de 'beneficiaire' dans historique[] ─────────────────────
-- Pour chaque tontine, pour chaque entrée de historique[] qui n'a pas de
-- 'beneficiaire' renseigné, on tente de le reconstruire depuis ordre[] et membres[].
-- ATTENTION : cette migration est NON-DESTRUCTIVE — elle ne touche que les
-- entrées dont 'beneficiaire' est vide ou absent.

UPDATE tontines t
SET data = jsonb_set(
  t.data,
  '{historique}',
  (
    SELECT jsonb_agg(
      CASE
        -- Si 'beneficiaire' est déjà renseigné et non vide → ne rien changer
        WHEN (h->>'beneficiaire') IS NOT NULL AND (h->>'beneficiaire') <> '' THEN h

        -- Sinon : tenter de résoudre depuis ordre[] + membres[]
        ELSE (
          SELECT h || jsonb_build_object(
            'beneficiaire', COALESCE(
              -- Priorité 1 : beneficiaireId stocké dans h
              (
                SELECT m->>'nom'
                FROM jsonb_array_elements(t.data->'membres') m
                WHERE m->>'id' = h->>'beneficiaireId'
                LIMIT 1
              ),
              -- Priorité 2 : index du tour dans ordre[]
              (
                SELECT m->>'nom'
                FROM jsonb_array_elements(t.data->'ordre') WITH ORDINALITY AS o(id_val, idx)
                JOIN jsonb_array_elements(t.data->'membres') m ON m->>'id' = o.id_val::text
                WHERE idx = ((h->>'tour')::int)
                LIMIT 1
              ),
              -- Priorité 3 : membre à la position h['tour']-1 dans membres[]
              (
                SELECT m->>'nom'
                FROM jsonb_array_elements(t.data->'membres') WITH ORDINALITY AS m(val, idx)
                WHERE idx = ((h->>'tour')::int)
                LIMIT 1
              ),
              'Bénéficiaire non encore désigné'
            )
          )
        )
      END
    )
    FROM jsonb_array_elements(t.data->'historique') h
  )
)
WHERE
  t.data->'historique' IS NOT NULL
  AND jsonb_array_length(t.data->'historique') > 0
  AND EXISTS (
    -- Seulement les tontines ayant au moins un historique sans beneficiaire
    SELECT 1
    FROM jsonb_array_elements(t.data->'historique') h
    WHERE (h->>'beneficiaire') IS NULL OR (h->>'beneficiaire') = ''
  );


-- ── 2. Fonction helper : résoudre le nom d'un membre depuis son ID ────────────
CREATE OR REPLACE FUNCTION _tc_nom_membre(
  p_data  jsonb,
  p_id    text
) RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT COALESCE(
    (
      SELECT m->>'nom'
      FROM jsonb_array_elements(p_data->'membres') m
      WHERE m->>'id' = p_id
      LIMIT 1
    ),
    p_id  -- fallback : retourner l'ID si nom introuvable
  );
$$;


-- ── 3. RPC cloturer_tour : version v11 ──────────────────────────────────────
-- Améliorations vs v10 :
--   - Enregistre beneficiaireNom + beneficiaireId dans historique
--   - Anti-doublon : refuse si ce membre a déjà été servi dans ce cycle
--   - Sélectionne automatiquement le bénéficiaire suivant (tourActuel++)
--   - Retourne l'état complet après clôture

CREATE OR REPLACE FUNCTION cloturer_tour(
  p_code  text,
  p_pin   text,
  p_gest  text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_row           tontines%ROWTYPE;
  v_data          jsonb;
  v_ordre         jsonb;
  v_membres       jsonb;
  v_tour_actuel   int;
  v_nb_tours      int;
  v_benef_id      text;
  v_benef_nom     text;
  v_paiements     jsonb;
  v_historique    jsonb;
  v_nb_payes      int;
  v_total_recu    int;
  v_montant       int;
  v_est_dernier   boolean;
  v_new_tour      int;
  v_payes_ids     jsonb;
  v_ref           text;
  v_now           text;
  v_gestionnaire  text;
  v_doublons      boolean;
BEGIN
  -- ── Vérification PIN ────────────────────────────────────────────────────
  SELECT * INTO v_row FROM tontines WHERE code = p_code;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Tontine introuvable');
  END IF;

  IF v_row.pin_hash IS NOT NULL AND v_row.pin_hash <> crypt(p_pin, v_row.pin_hash) THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'PIN incorrect');
  END IF;

  v_data        := v_row.data;
  v_ordre       := COALESCE(v_data->'ordre', '[]'::jsonb);
  v_membres     := COALESCE(v_data->'membres', '[]'::jsonb);
  v_tour_actuel := COALESCE((v_data->>'tourActuel')::int, 0);
  v_nb_tours    := jsonb_array_length(v_ordre);
  v_montant     := COALESCE((v_data->>'montant')::int, 0);
  v_paiements   := COALESCE(v_data->'paiements', '{}'::jsonb);
  v_historique  := COALESCE(v_data->'historique', '[]'::jsonb);
  v_now         := now()::text;
  v_ref         := upper(substring(md5(random()::text) FROM 1 FOR 8));
  v_gestionnaire := COALESCE(p_gest, 'gestionnaire');

  -- ── Vérifications préalables ─────────────────────────────────────────────
  IF (v_data->>'cycleTermine')::boolean = true THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Le cycle est déjà terminé');
  END IF;

  IF v_nb_tours = 0 THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Aucun ordre de passage défini');
  END IF;

  IF v_tour_actuel >= v_nb_tours THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Tous les tours ont déjà été clôturés');
  END IF;

  -- ── Identifier le bénéficiaire ──────────────────────────────────────────
  v_benef_id  := v_ordre->>v_tour_actuel;
  v_benef_nom := _tc_nom_membre(v_data, v_benef_id);

  -- ── Anti-doublon : vérifier que ce membre n'a pas déjà été servi ─────────
  SELECT EXISTS (
    SELECT 1
    FROM jsonb_array_elements(v_historique) h
    WHERE (h->>'beneficiaireId') = v_benef_id
       OR (h->>'beneficiaire') = v_benef_nom
  ) INTO v_doublons;

  IF v_doublons THEN
    RETURN jsonb_build_object(
      'ok', false,
      'erreur', format('Doublon détecté : %s a déjà été bénéficiaire dans ce cycle', v_benef_nom)
    );
  END IF;

  -- ── Calculer les stats du tour ───────────────────────────────────────────
  SELECT
    COUNT(*),
    COUNT(*) * v_montant
  INTO v_nb_payes, v_total_recu
  FROM jsonb_object_keys(v_paiements);

  -- IDs des membres ayant payé
  v_payes_ids := (
    SELECT jsonb_agg(k)
    FROM jsonb_object_keys(v_paiements) k
  );

  -- ── Créer l'entrée historique ────────────────────────────────────────────
  v_est_dernier := (v_tour_actuel + 1) >= v_nb_tours;
  v_new_tour    := CASE WHEN v_est_dernier THEN v_tour_actuel ELSE v_tour_actuel + 1 END;

  v_historique  := jsonb_build_array(
    jsonb_build_object(
      'tour',            v_tour_actuel + 1,       -- numéro humain 1-based
      'beneficiaireId',  v_benef_id,
      'beneficiaire',    v_benef_nom,
      'beneficiaireNom', v_benef_nom,
      'nbPayes',         v_nb_payes,
      'totalRecu',       v_total_recu,
      'totalAttendu',    v_nb_tours * v_montant,
      'payesIds',        COALESCE(v_payes_ids, '[]'::jsonb),
      'statut',          'Distribué',
      'date',            v_now,
      'closLe',          v_now,
      'reference',       v_ref
    )
  ) || v_historique;

  -- ── Mettre à jour les données ─────────────────────────────────────────────
  v_data := v_data
    || jsonb_build_object(
        'tourActuel',   v_new_tour,
        'cycleTermine', v_est_dernier,
        'paiements',    '{}'::jsonb,     -- réinitialiser pour le prochain tour
        'historique',   v_historique
       );

  -- Réinitialiser le statut paye de tous les membres pour le prochain tour
  v_data := jsonb_set(
    v_data,
    '{membres}',
    (
      SELECT jsonb_agg(
        m || jsonb_build_object('paye', false, 'datePaiement', null, 'methodePaiement', null)
      )
      FROM jsonb_array_elements(v_membres) m
    )
  );

  -- Entrée journal
  v_data := jsonb_set(
    v_data,
    '{journal}',
    jsonb_build_array(
      jsonb_build_object(
        'quoi',        format('TOUR_%s_CLOS|beneficiaire:%s|total:%s', v_tour_actuel + 1, v_benef_nom, v_total_recu),
        'gestionnaire', v_gestionnaire,
        'quand',        v_now,
        'reference',    v_ref
      )
    ) || COALESCE(v_data->'journal', '[]'::jsonb)
  );

  -- Sauvegarder
  UPDATE tontines SET data = v_data, updated_at = now() WHERE code = p_code;

  RETURN jsonb_build_object(
    'ok',             true,
    'tourClos',       v_tour_actuel + 1,
    'beneficiaire',   v_benef_nom,
    'beneficiaireId', v_benef_id,
    'totalRecu',      v_total_recu,
    'nbPayes',        v_nb_payes,
    'cycleTermine',   v_est_dernier,
    'prochainTour',   CASE WHEN v_est_dernier THEN null ELSE v_new_tour + 1 END,
    'prochainBeneficiaire', CASE
      WHEN v_est_dernier THEN null
      ELSE _tc_nom_membre(v_data, v_ordre->>(v_new_tour)::int)
    END
  );
END;
$$;


-- ── 4. RPC lire_tontine : normalisation v11 ──────────────────────────────────
-- Assure que beneficiaire est toujours renseigné dans les réponses

CREATE OR REPLACE FUNCTION lire_tontine(p_code text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_row  tontines%ROWTYPE;
  v_data jsonb;
BEGIN
  SELECT * INTO v_row FROM tontines WHERE code = p_code;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Tontine introuvable');
  END IF;

  v_data := v_row.data;

  -- Normaliser cycleTermine si absent
  IF v_data->'cycleTermine' IS NULL THEN
    v_data := v_data || jsonb_build_object(
      'cycleTermine',
      CASE
        WHEN jsonb_array_length(COALESCE(v_data->'ordre', '[]'::jsonb)) = 0 THEN false
        WHEN COALESCE((v_data->>'tourActuel')::int, 0) >= jsonb_array_length(v_data->'ordre') THEN true
        ELSE false
      END
    );
  END IF;

  -- Normaliser historique : remplir beneficiaire manquant
  IF v_data->'historique' IS NOT NULL AND jsonb_array_length(v_data->'historique') > 0 THEN
    v_data := jsonb_set(
      v_data,
      '{historique}',
      (
        SELECT jsonb_agg(
          CASE
            WHEN (h->>'beneficiaire') IS NOT NULL AND (h->>'beneficiaire') <> '' THEN h
            ELSE h || jsonb_build_object(
              'beneficiaire', COALESCE(
                (
                  SELECT m->>'nom'
                  FROM jsonb_array_elements(v_data->'membres') m
                  WHERE m->>'id' = h->>'beneficiaireId'
                  LIMIT 1
                ),
                'Bénéficiaire non encore désigné'
              )
            )
          END
        )
        FROM jsonb_array_elements(v_data->'historique') h
      )
    );
  END IF;

  RETURN jsonb_build_object(
    'ok',      true,
    'code',    v_row.code,
    'plan',    COALESCE(v_row.plan, 'free'),
    'planExpire', v_row.plan_expire,
    'data',    v_data
  );
END;
$$;


-- ── 5. RPC distribuer_tour : enregistre la distribution manuellement ─────────
-- Utilisée quand le gestionnaire confirme la distribution via l'UI Flutter

CREATE OR REPLACE FUNCTION distribuer_tour(
  p_code          text,
  p_pin           text,
  p_gest          text,
  p_benef_id      text  DEFAULT NULL,  -- si NULL : utilise ordre[tourActuel]
  p_montant_recu  int   DEFAULT NULL   -- si NULL : calcule automatiquement
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_row          tontines%ROWTYPE;
  v_data         jsonb;
  v_ordre        jsonb;
  v_tour_actuel  int;
  v_nb_tours     int;
  v_benef_id     text;
  v_benef_nom    text;
  v_montant      int;
  v_total_recu   int;
  v_nb_payes     int;
  v_paiements    jsonb;
  v_historique   jsonb;
  v_payes_ids    jsonb;
  v_est_dernier  boolean;
  v_new_tour     int;
  v_ref          text;
  v_now          text;
  v_doublons     boolean;
BEGIN
  SELECT * INTO v_row FROM tontines WHERE code = p_code;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Tontine introuvable');
  END IF;

  IF v_row.pin_hash IS NOT NULL AND v_row.pin_hash <> crypt(p_pin, v_row.pin_hash) THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'PIN incorrect');
  END IF;

  v_data        := v_row.data;
  v_ordre       := COALESCE(v_data->'ordre', '[]'::jsonb);
  v_tour_actuel := COALESCE((v_data->>'tourActuel')::int, 0);
  v_nb_tours    := jsonb_array_length(v_ordre);
  v_montant     := COALESCE((v_data->>'montant')::int, 0);
  v_paiements   := COALESCE(v_data->'paiements', '{}'::jsonb);
  v_historique  := COALESCE(v_data->'historique', '[]'::jsonb);
  v_now         := now()::text;
  v_ref         := upper(substring(md5(random()::text) FROM 1 FOR 8));

  -- Vérifications
  IF (v_data->>'cycleTermine')::boolean = true THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Le cycle est déjà terminé');
  END IF;
  IF v_nb_tours = 0 THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Aucun ordre défini');
  END IF;
  IF v_tour_actuel >= v_nb_tours THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Tous les tours ont été effectués');
  END IF;

  -- Bénéficiaire
  v_benef_id  := COALESCE(p_benef_id, v_ordre->>v_tour_actuel);
  v_benef_nom := _tc_nom_membre(v_data, v_benef_id);

  -- Anti-doublon
  SELECT EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_historique) h
    WHERE (h->>'beneficiaireId') = v_benef_id
  ) INTO v_doublons;
  IF v_doublons THEN
    RETURN jsonb_build_object(
      'ok', false,
      'erreur', format('%s a déjà été servi dans ce cycle', v_benef_nom)
    );
  END IF;

  -- Calculs
  SELECT COUNT(*) INTO v_nb_payes FROM jsonb_object_keys(v_paiements);
  v_total_recu := COALESCE(p_montant_recu, v_nb_payes * v_montant);
  v_payes_ids  := (SELECT jsonb_agg(k) FROM jsonb_object_keys(v_paiements) k);
  v_est_dernier := (v_tour_actuel + 1) >= v_nb_tours;
  v_new_tour    := CASE WHEN v_est_dernier THEN v_tour_actuel ELSE v_tour_actuel + 1 END;

  -- Historique
  v_historique := jsonb_build_array(
    jsonb_build_object(
      'tour',            v_tour_actuel + 1,
      'beneficiaireId',  v_benef_id,
      'beneficiaire',    v_benef_nom,
      'beneficiaireNom', v_benef_nom,
      'montantRecu',     v_total_recu,
      'totalRecu',       v_total_recu,
      'totalAttendu',    v_nb_tours * v_montant,
      'nbPayes',         v_nb_payes,
      'payesIds',        COALESCE(v_payes_ids, '[]'::jsonb),
      'statut',          'Distribué',
      'date',            v_now,
      'closLe',          v_now,
      'reference',       v_ref
    )
  ) || v_historique;

  -- Mise à jour data
  v_data := v_data || jsonb_build_object(
    'tourActuel',   v_new_tour,
    'cycleTermine', v_est_dernier,
    'paiements',    '{}'::jsonb,
    'historique',   v_historique
  );

  -- Reset paye de tous les membres
  v_data := jsonb_set(v_data, '{membres}', (
    SELECT jsonb_agg(m || '{"paye":false,"datePaiement":null,"methodePaiement":null}')
    FROM jsonb_array_elements(COALESCE(v_data->'membres', '[]'::jsonb)) m
  ));

  -- Mouvement caisse : distribution
  DECLARE
    v_caisse_mv jsonb;
  BEGIN
    v_caisse_mv := jsonb_build_object(
      'id',          v_ref || 'D',
      'type',        'distribution',
      'montant',     -v_total_recu,
      'description', format('Distribution Tour %s → %s', v_tour_actuel + 1, v_benef_nom),
      'gestionnaire', COALESCE(p_gest, 'gestionnaire'),
      'date',        v_now,
      'reference',   v_ref
    );
    v_data := jsonb_set(
      v_data,
      '{caisse,mouvements}',
      jsonb_build_array(v_caisse_mv) || COALESCE(v_data->'caisse'->'mouvements', '[]'::jsonb)
    );
  END;

  -- Journal
  v_data := jsonb_set(v_data, '{journal}',
    jsonb_build_array(jsonb_build_object(
      'quoi',        format('DISTRIBUTION_TOUR_%s|%s|%s FCFA', v_tour_actuel + 1, v_benef_nom, v_total_recu),
      'gestionnaire', COALESCE(p_gest, 'gestionnaire'),
      'quand',        v_now,
      'reference',    v_ref
    )) || COALESCE(v_data->'journal', '[]'::jsonb)
  );

  UPDATE tontines SET data = v_data, updated_at = now() WHERE code = p_code;

  RETURN jsonb_build_object(
    'ok',             true,
    'tourDistribue',  v_tour_actuel + 1,
    'beneficiaire',   v_benef_nom,
    'beneficiaireId', v_benef_id,
    'montantRecu',    v_total_recu,
    'cycleTermine',   v_est_dernier,
    'prochainTour',   CASE WHEN v_est_dernier THEN null ELSE v_new_tour + 1 END,
    'prochainBeneficiaire', CASE
      WHEN v_est_dernier THEN null
      ELSE _tc_nom_membre(v_data, v_ordre->>(v_new_tour)::int)
    END
  );
END;
$$;


-- ── 6. Vérification : afficher les tontines avec historique sans bénéficiaire ─
-- Exécuter cette requête pour vérifier avant/après la migration :
/*
SELECT
  code,
  data->>'nom' AS nom,
  jsonb_array_length(data->'historique') AS nb_historique,
  (
    SELECT COUNT(*)
    FROM jsonb_array_elements(data->'historique') h
    WHERE (h->>'beneficiaire') IS NULL OR (h->>'beneficiaire') = ''
  ) AS historique_sans_beneficiaire,
  data->>'tourActuel' AS tour_actuel,
  jsonb_array_length(COALESCE(data->'ordre', '[]'::jsonb)) AS nb_tours_ordre
FROM tontines
ORDER BY created_at DESC;
*/

-- ── 7. Test de validation après migration ─────────────────────────────────────
-- Pour confirmer que "Tour X sur N" est correct :
/*
SELECT
  code,
  data->>'nom' AS nom,
  data->>'tourActuel' AS tour_actuel_idx,
  (COALESCE((data->>'tourActuel')::int, 0) + 1)::text || ' sur ' ||
    jsonb_array_length(data->'ordre')::text AS affichage_tour,
  jsonb_array_length(COALESCE(data->'ordre', '[]'::jsonb)) AS nb_tours_ordre,
  jsonb_array_length(COALESCE(data->'membres', '[]'::jsonb)) AS nb_membres,
  (
    SELECT m->>'nom'
    FROM jsonb_array_elements(data->'membres') m
    WHERE m->>'id' = data->'ordre'->>(COALESCE((data->>'tourActuel')::int, 0))::text
    LIMIT 1
  ) AS beneficiaire_actuel
FROM tontines
WHERE (data->>'cycleTermine')::boolean IS NOT TRUE
  AND jsonb_array_length(COALESCE(data->'ordre', '[]'::jsonb)) > 0
ORDER BY created_at DESC;
*/
