-- ============================================================
-- PRÊTS INTERNES PREMIUM — TABLE + RPCs
-- ============================================================
-- À exécuter dans Supabase SQL Editor
-- 1. Table  prets_pending          : demandes en attente de validation admin
-- 2. RPC    admin_valider_pret      : valide + débite caisse via JSON tontine
-- 3. RPC    admin_rejeter_pret      : rejette la demande
-- 4. RPC    crediter_remboursement_sycapay : crédite caisse + met à jour prêt après SycaPay
-- ============================================================

-- ── 1. Table prets_pending ─────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.prets_pending (
  id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  code                 text        NOT NULL,              -- code tontine (majuscules)
  emprunteur_id        text        NOT NULL,              -- id du membre emprunteur
  emprunteur_nom       text        NOT NULL,
  montant              integer     NOT NULL,              -- montant du prêt
  frais_transaction    integer     NOT NULL DEFAULT 0,    -- 2% du montant
  montant_net          integer     NOT NULL,              -- montant - frais
  taux                 numeric     NOT NULL DEFAULT 5,    -- taux d'intérêt (%)
  durees_mois          integer     NOT NULL DEFAULT 3,
  operateur            text        NOT NULL,              -- ex: 'orange','moov','mtn','wave'
  numero_beneficiaire  text        NOT NULL,              -- numéro Mobile Money de l'emprunteur
  nom_beneficiaire     text        NOT NULL,
  description          text        DEFAULT '',
  gestionnaire         text        NOT NULL,
  reference            text        NOT NULL UNIQUE,
  devise               text        DEFAULT 'XOF',
  statut               text        NOT NULL DEFAULT 'pending'
                         CHECK (statut IN ('pending','validee','rejetee')),
  motif_rejet          text,
  created_at           timestamptz DEFAULT now(),
  validated_at         timestamptz
);

ALTER TABLE public.prets_pending ENABLE ROW LEVEL SECURITY;
CREATE POLICY "service_role_all" ON public.prets_pending
  FOR ALL TO service_role USING (true) WITH CHECK (true);

-- ── 2. RPC admin_valider_pret ──────────────────────────────────────────────
-- Valide une demande de prêt :
--   • Vérifie solde caisse suffisant (montant_net, pas le montant brut)
--   • Débite caisse du montant_net (montant - frais)
--   • Crée le prêt dans tontines.data.prets[]
--   • Ajoute mouvement 'depense' dans tontines.data.caisse.mouvements[]
--   • Journal
--   • Marque prets_pending.statut = 'validee'

CREATE OR REPLACE FUNCTION public.admin_valider_pret(
  p_cle  text,
  p_id   bigint
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_row        public.prets_pending%ROWTYPE;
  v_tontine    public.tontines%ROWTYPE;
  v_data       jsonb;
  v_caisse     jsonb;
  v_mouvements jsonb;
  v_prets      jsonb;
  v_journal    jsonb;
  v_solde      integer;
  v_now        text := to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"');
  v_interet    integer;
  v_total_du   integer;
  v_mensualite integer;
  v_echeancier jsonb;
  v_i          integer;
  v_date_ech   text;
BEGIN
  -- Vérification clé admin
  IF p_cle IS DISTINCT FROM current_setting('app.admin_key', true) THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.admin_config WHERE cle = p_cle AND actif = true LIMIT 1
    ) THEN
      RETURN jsonb_build_object('ok', false, 'erreur', 'Clé admin invalide');
    END IF;
  END IF;

  -- Lire la demande
  SELECT * INTO v_row FROM public.prets_pending WHERE id = p_id AND statut = 'pending';
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Demande introuvable ou déjà traitée');
  END IF;

  -- Lire la tontine
  SELECT * INTO v_tontine FROM public.tontines
    WHERE UPPER(code) = UPPER(v_row.code) LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Tontine introuvable');
  END IF;

  v_data := v_tontine.data;

  -- Calculer le solde caisse
  v_caisse     := COALESCE(v_data->'caisse', '{"mouvements":[]}'::jsonb);
  v_mouvements := COALESCE(v_caisse->'mouvements', '[]'::jsonb);
  SELECT COALESCE(SUM(
    CASE
      WHEN (m->>'type') IN ('depot','cotisation','remboursement','apport') THEN (m->>'montant')::integer
      WHEN (m->>'type') IN ('depense','pret','penalite','correction','decaissement') THEN -((m->>'montant')::integer)
      ELSE 0
    END
  ), 0)
  INTO v_solde
  FROM jsonb_array_elements(v_mouvements) AS m;

  -- Vérifier le solde (on débite montant_net, les frais partent au bénéficiaire)
  IF v_solde < v_row.montant_net THEN
    RETURN jsonb_build_object(
      'ok',     false,
      'erreur', format('Solde insuffisant : %s disponible, %s requis',
                       v_solde, v_row.montant_net)
    );
  END IF;

  -- ── Ajouter mouvement dépense dans caisse ──
  v_mouvements := v_mouvements || jsonb_build_object(
    'id',          v_row.reference || 'D',
    'type',        'depense',
    'montant',     v_row.montant_net,
    'description', format('Prêt à %s (Mobile Money %s)',
                          v_row.emprunteur_nom,
                          v_row.operateur),
    'gestionnaire', v_row.gestionnaire,
    'date',        v_now,
    'reference',   v_row.reference,
    'methode',     v_row.operateur,
    'beneficiaire', v_row.numero_beneficiaire
  );
  v_caisse := jsonb_set(v_caisse, '{mouvements}', v_mouvements);
  v_data   := jsonb_set(v_data, '{caisse}', v_caisse);

  -- ── Créer le prêt dans prets[] ──
  v_interet    := round(v_row.montant * v_row.taux / 100);
  v_total_du   := v_row.montant + v_interet;
  v_mensualite := round(v_total_du::numeric / v_row.durees_mois);

  -- Construire l'échéancier
  v_echeancier := '[]'::jsonb;
  FOR v_i IN 1..v_row.durees_mois LOOP
    v_date_ech := to_char(
      (now() AT TIME ZONE 'UTC') + (v_i * interval '30 days'),
      'YYYY-MM-DD"T"HH24:MI:SS"Z"'
    );
    v_echeancier := v_echeancier || jsonb_build_array(
      jsonb_build_object(
        'mois',    v_i,
        'date',    v_date_ech,
        'montant', CASE WHEN v_i = v_row.durees_mois
                        THEN v_total_du - v_mensualite * (v_row.durees_mois - 1)
                        ELSE v_mensualite END
      )
    );
  END LOOP;

  v_prets := COALESCE(v_data->'prets', '[]'::jsonb);
  v_prets := v_prets || jsonb_build_array(
    jsonb_build_object(
      'id',              v_row.reference,
      'emprunteurId',    v_row.emprunteur_id,
      'emprunteurNom',   v_row.emprunteur_nom,
      'montant',         v_row.montant,
      'fraisTransaction', v_row.frais_transaction,
      'montantNet',      v_row.montant_net,
      'taux',            v_row.taux,
      'dureesMois',      v_row.durees_mois,
      'dateDebut',       v_now,
      'statut',          'en_cours',
      'remboursements',  '[]'::jsonb,
      'echeancier',      v_echeancier,
      'gestionnaire',    v_row.gestionnaire,
      'reference',       v_row.reference,
      'operateur',       v_row.operateur,
      'numeroBeneficiaire', v_row.numero_beneficiaire,
      'nomBeneficiaire', v_row.nom_beneficiaire,
      'resteADu',        v_total_du,
      'totalDu',         v_total_du
    )
  );
  v_data := jsonb_set(v_data, '{prets}', v_prets);

  -- ── Journal ──
  v_journal := COALESCE(v_data->'journal', '[]'::jsonb);
  v_journal := jsonb_build_array(
    jsonb_build_object(
      'quoi',        format('PRÊT VALIDÉ — %s — %s %s — %s%% — %s mois — via %s',
                            v_row.emprunteur_nom,
                            v_row.montant_net, v_row.devise,
                            v_row.taux, v_row.durees_mois,
                            v_row.operateur),
      'gestionnaire', v_row.gestionnaire,
      'quand',       v_now,
      'reference',   v_row.reference
    )
  ) || v_journal;
  v_data := jsonb_set(v_data, '{journal}', v_journal);

  -- Sauvegarder
  UPDATE public.tontines SET data = v_data
    WHERE UPPER(code) = UPPER(v_row.code);

  -- Marquer validée
  UPDATE public.prets_pending
    SET statut = 'validee', validated_at = now()
    WHERE id = p_id;

  RETURN jsonb_build_object(
    'ok',             true,
    'pret_reference', v_row.reference,
    'montant_net',    v_row.montant_net,
    'emprunteur',     v_row.emprunteur_nom
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_valider_pret(text, bigint) TO service_role;

-- ── 3. RPC admin_rejeter_pret ──────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.admin_rejeter_pret(
  p_cle   text,
  p_id    bigint,
  p_motif text DEFAULT 'Rejeté par l''administrateur'
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.prets_pending WHERE id = p_id AND statut = 'pending'
  ) THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Demande introuvable ou déjà traitée');
  END IF;

  UPDATE public.prets_pending
    SET statut = 'rejetee', motif_rejet = p_motif, validated_at = now()
    WHERE id = p_id;

  RETURN jsonb_build_object('ok', true);
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_rejeter_pret(text, bigint, text) TO service_role;

-- ── 4. RPC crediter_remboursement_sycapay ──────────────────────────────────
-- Appelé par l'Edge Function après confirmation SycaPay d'un remboursement.
-- • Crédite caisse (type=remboursement)
-- • Met à jour le prêt : ajoute le remboursement, recalcule resteADu, passe 'soldé' si 0
-- • Idempotence sur p_reference (UNIQUE dans remboursements)

CREATE OR REPLACE FUNCTION public.crediter_remboursement_sycapay(
  p_code         text,
  p_montant      integer,
  p_reference    text,
  p_num_commande text,
  p_operateur    text,
  p_pret_id      text,
  p_emprunteur_id   text,
  p_emprunteur_nom  text,
  p_description  text,
  p_now          text DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_tontine      public.tontines%ROWTYPE;
  v_data         jsonb;
  v_caisse       jsonb;
  v_mouvements   jsonb;
  v_prets        jsonb;
  v_pret         jsonb;
  v_rembs        jsonb;
  v_journal      jsonb;
  v_now          text;
  v_idx          integer := -1;
  v_i            integer := 0;
  v_total_du     integer;
  v_total_remb   integer;
  v_reste        integer;
  v_pret_solde   boolean := false;
  v_p            jsonb;
BEGIN
  v_now := COALESCE(p_now, to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'));

  -- Lire tontine
  SELECT * INTO v_tontine FROM public.tontines
    WHERE UPPER(code) = UPPER(p_code) LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Tontine introuvable');
  END IF;

  v_data := v_tontine.data;

  -- Idempotence : vérifier si reference déjà dans un remboursement
  FOR v_p IN SELECT jsonb_array_elements(COALESCE(v_data->'prets', '[]'::jsonb)) LOOP
    FOR v_i IN 0..(jsonb_array_length(COALESCE(v_p->'remboursements','[]'::jsonb))-1) LOOP
      IF (v_p->'remboursements'->v_i->>'reference') = p_reference
      OR (v_p->'remboursements'->v_i->>'id') = p_reference THEN
        RETURN jsonb_build_object('ok', true, 'idempotent', true);
      END IF;
    END LOOP;
  END LOOP;

  -- ── Crédit caisse ──
  v_caisse     := COALESCE(v_data->'caisse', '{"mouvements":[]}'::jsonb);
  v_mouvements := COALESCE(v_caisse->'mouvements', '[]'::jsonb);
  v_mouvements := v_mouvements || jsonb_build_object(
    'id',          p_reference || 'R',
    'type',        'remboursement',
    'montant',     p_montant,
    'description', CASE WHEN p_description <> ''
                        THEN p_description
                        ELSE format('Remboursement prêt %s via SycaPay', p_emprunteur_nom) END,
    'gestionnaire', p_emprunteur_nom,
    'date',        v_now,
    'reference',   p_reference,
    'methode',     p_operateur,
    'numCommande', p_num_commande
  );
  v_caisse := jsonb_set(v_caisse, '{mouvements}', v_mouvements);
  v_data   := jsonb_set(v_data, '{caisse}', v_caisse);

  -- ── Mise à jour du prêt ──
  v_prets := COALESCE(v_data->'prets', '[]'::jsonb);
  v_idx   := -1;
  FOR v_i IN 0..(jsonb_array_length(v_prets)-1) LOOP
    IF (v_prets->v_i->>'id') = p_pret_id THEN
      v_idx := v_i;
      EXIT;
    END IF;
  END LOOP;

  IF v_idx >= 0 THEN
    v_pret  := v_prets->v_idx;
    v_rembs := COALESCE(v_pret->'remboursements', '[]'::jsonb);

    -- Ajouter le nouveau remboursement
    v_rembs := v_rembs || jsonb_build_array(
      jsonb_build_object(
        'id',        p_reference,
        'montant',   p_montant,
        'date',      v_now,
        'methode',   p_operateur,
        'reference', p_reference,
        'numCommande', p_num_commande
      )
    );

    -- Calculer totalRembourse
    SELECT COALESCE(SUM((r->>'montant')::integer), 0)
    INTO v_total_remb
    FROM jsonb_array_elements(v_rembs) AS r;

    v_total_du := COALESCE((v_pret->>'totalDu')::integer,
                           (v_pret->>'resteADu')::integer, 0);
    IF v_total_du = 0 THEN
      -- Recalculer depuis montant + taux
      v_total_du := (v_pret->>'montant')::integer
                  + round(((v_pret->>'montant')::integer * (v_pret->>'taux')::numeric / 100));
    END IF;

    v_reste       := GREATEST(0, v_total_du - v_total_remb);
    v_pret_solde  := v_reste = 0;

    -- Mettre à jour le prêt
    v_pret := v_pret
      || jsonb_build_object(
           'remboursements', v_rembs,
           'resteADu',       v_reste,
           'totalRembourse', v_total_remb,
           'statut',         CASE WHEN v_pret_solde THEN 'soldé' ELSE 'en_cours' END
         );

    v_prets := jsonb_set(v_prets, ARRAY[v_idx::text], v_pret);
    v_data  := jsonb_set(v_data, '{prets}', v_prets);
  END IF;

  -- ── Journal ──
  v_journal := COALESCE(v_data->'journal', '[]'::jsonb);
  v_journal := jsonb_build_array(
    jsonb_build_object(
      'quoi',        format('REMBOURSEMENT SycaPay — %s — %s XOF — Réf: %s%s',
                            p_emprunteur_nom, p_montant, p_reference,
                            CASE WHEN v_pret_solde THEN ' — SOLDÉ ✓' ELSE '' END),
      'gestionnaire', p_emprunteur_nom,
      'quand',       v_now,
      'reference',   p_reference
    )
  ) || v_journal;
  v_data := jsonb_set(v_data, '{journal}', v_journal);

  -- Sauvegarder
  UPDATE public.tontines SET data = v_data
    WHERE UPPER(code) = UPPER(p_code);

  RETURN jsonb_build_object(
    'ok',         true,
    'pret_solde', v_pret_solde,
    'reste',      v_reste
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.crediter_remboursement_sycapay(
  text, integer, text, text, text, text, text, text, text, text
) TO service_role;
