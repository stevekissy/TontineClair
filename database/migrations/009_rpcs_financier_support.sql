-- ============================================================
-- TontineClair — Migration 009 : RPCs Financier, KYC & Support
-- Sources    : supabase-subscriptions.sql
--              supabase-prets-pending.sql
--              supabase-decaissements-pending.sql
--              supabase-depenses-pending.sql
--              supabase-kyc.sql
--              supabase-admin-team.sql (support + admin team RPCs)
-- Dépendances: 003_tables_financier.sql, 004_tables_kyc_notifs.sql,
--              005_tables_admin_team_support.sql, 008_rpcs_admin.sql
-- Idempotent : CREATE OR REPLACE FUNCTION partout
-- ============================================================
-- Fonctions incluses (27) :
--   Abonnements (6): est_premium, lire_abonnement_tontine, verif_limite_tontines,
--     verif_limite_membres, enregistrer_abonnement_web, expirer_abonnements_obsoletes
--   Prêts (3): admin_valider_pret, admin_rejeter_pret, crediter_remboursement_sycapay
--   Décaissements (3): admin_lister_decaissements, admin_valider_decaissement,
--     admin_rejeter_decaissement
--   Dépenses (2): admin_valider_depense, admin_rejeter_depense
--   KYC (3): admin_lister_kyc, admin_valider_kyc, admin_rejeter_kyc
--   Admin Team (4): admin_lister_membres, admin_creer_membre, admin_modifier_membre,
--     admin_auth_membre
--   Messagerie (4): admin_lister_messages, admin_envoyer_message, admin_marquer_lu,
--     admin_compter_non_lus
--   Support (6): generer_ref_ticket, support_ouvrir_ticket, support_mes_tickets,
--     admin_lister_tickets, support_messages_ticket, support_repondre,
--     admin_changer_statut_ticket
-- ============================================================

-- ============================================================
-- SECTION A : Abonnements & Limites
-- Source : supabase-subscriptions.sql
-- ============================================================

-- ────────────────────────────────────────────────────────────
-- A1. _sub_update_modifie_le (trigger helper pour subscriptions)
-- ────────────────────────────────────────────────────────────
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

-- ────────────────────────────────────────────────────────────
-- A2. est_premium
--     Vérifie si une tontine a un abonnement Premium actif
--     Double source : subscriptions (nouvelle) + tontines.plan (fallback)
-- ────────────────────────────────────────────────────────────
create or replace function est_premium(p_code text)
returns boolean
language plpgsql security definer set search_path = public
as $$
declare
  v_ok boolean := false;
begin
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

  begin
    select exists(
      select 1 from tontines
      where code = upper(p_code)
        and plan = 'premium'
        and (plan_expire is null or plan_expire > now())
    ) into v_ok;
  exception when undefined_column then
    v_ok := false;
  end;

  return coalesce(v_ok, false);
end $$;

grant execute on function est_premium(text) to anon;

-- ────────────────────────────────────────────────────────────
-- A3. lire_abonnement_tontine
--     Retourne le détail de l'abonnement actif pour une tontine
-- ────────────────────────────────────────────────────────────
create or replace function lire_abonnement_tontine(p_code text)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_sub   subscriptions%rowtype;
  v_plan  text := 'free';
  v_exp   timestamptz;
begin
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

  begin
    select t.plan, t.plan_expire
    into v_plan, v_exp
    from tontines t
    where t.code = upper(p_code)
    limit 1;
  exception when others then null;
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

  return jsonb_build_object(
    'plan',     'free',
    'status',   'active',
    'platform', 'web',
    'provider', 'web',
    'auto_renew', false
  );
end $$;

grant execute on function lire_abonnement_tontine(text) to anon;

-- ────────────────────────────────────────────────────────────
-- A4. verif_limite_tontines (toujours autorisé — logique côté Flutter)
-- ────────────────────────────────────────────────────────────
create or replace function verif_limite_tontines(p_code_proprietaire text)
returns jsonb
language plpgsql security definer set search_path = public
as $$
begin
  return jsonb_build_object(
    'autorise', true,
    'premium',  false,
    'nb',       0,
    'message',  ''
  );
end $$;

grant execute on function verif_limite_tontines(text) to anon;

-- ────────────────────────────────────────────────────────────
-- A5. verif_limite_membres
--     Vérifie si l'ajout d'un membre est autorisé (5 max gratuit)
-- ────────────────────────────────────────────────────────────
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
  v_premium := est_premium(p_code);

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

-- ────────────────────────────────────────────────────────────
-- A6. enregistrer_abonnement_web
--     Crée un abonnement web validé + synchronise tontines.plan
-- ────────────────────────────────────────────────────────────
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
  v_expires_at := case p_plan
    when 'premium_yearly'  then now() + interval '1 year'
    else                        now() + interval '1 month'
  end;

  update subscriptions
  set status     = 'expired',
      modifie_le = now()
  where code = upper(p_code)
    and status in ('active','grace_period');

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

  begin
    update tontines
    set plan       = 'premium',
        plan_expire = v_expires_at
    where code = upper(p_code);
  exception when undefined_column then null;
  end;

  begin
    insert into admin_actions(code, action, detail, effectue_par)
    values (
      upper(p_code),
      'ABONNEMENT_WEB_CREE',
      'Plan: ' || p_plan || ' | Montant: ' || coalesce(p_montant::text,'2500') || ' FCFA | Réf: ' || coalesce(p_reference,'-'),
      coalesce(p_active_par, 'ADMIN')
    );
  exception when others then null;
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

-- ────────────────────────────────────────────────────────────
-- A7. expirer_abonnements_obsoletes
--     Cron/trigger : passe statut → 'expired' pour les abonnements périmés
-- ────────────────────────────────────────────────────────────
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

  begin
    update tontines t
    set plan       = 'free',
        plan_expire = t.plan_expire
    where t.plan = 'premium'
      and t.plan_expire is not null
      and t.plan_expire <= now()
      and not exists (
        select 1 from subscriptions s
        where s.code = t.code
          and s.status in ('active','grace_period')
      );
  exception when undefined_column then null;
  end;

  return v_nb;
end $$;

grant execute on function expirer_abonnements_obsoletes() to anon;

-- RLS subscriptions
alter table subscriptions enable row level security;
drop policy if exists "subscriptions_no_direct" on subscriptions;
create policy "subscriptions_no_direct"
  on subscriptions for all to anon using (false);

-- ============================================================
-- SECTION B : Prêts Internes
-- Source : supabase-prets-pending.sql
-- ============================================================

-- ────────────────────────────────────────────────────────────
-- B1. admin_valider_pret
--     Valide un prêt pending : débite caisse + crée prêt JSON + journal
-- ────────────────────────────────────────────────────────────
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
  IF p_cle IS DISTINCT FROM current_setting('app.admin_key', true) THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.admin_config WHERE cle = p_cle AND actif = true LIMIT 1
    ) THEN
      RETURN jsonb_build_object('ok', false, 'erreur', 'Clé admin invalide');
    END IF;
  END IF;

  SELECT * INTO v_row FROM public.prets_pending WHERE id = p_id AND statut = 'pending';
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Demande introuvable ou déjà traitée');
  END IF;

  SELECT * INTO v_tontine FROM public.tontines
    WHERE UPPER(code) = UPPER(v_row.code) LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Tontine introuvable');
  END IF;

  v_data := v_tontine.data;
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

  IF v_solde < v_row.montant_net THEN
    RETURN jsonb_build_object(
      'ok',     false,
      'erreur', format('Solde insuffisant : %s disponible, %s requis', v_solde, v_row.montant_net)
    );
  END IF;

  v_mouvements := v_mouvements || jsonb_build_object(
    'id',          v_row.reference || 'D',
    'type',        'depense',
    'montant',     v_row.montant_net,
    'description', format('Prêt à %s (Mobile Money %s)', v_row.emprunteur_nom, v_row.operateur),
    'gestionnaire', v_row.gestionnaire,
    'date',        v_now,
    'reference',   v_row.reference,
    'methode',     v_row.operateur,
    'beneficiaire', v_row.numero_beneficiaire
  );
  v_caisse := jsonb_set(v_caisse, '{mouvements}', v_mouvements);
  v_data   := jsonb_set(v_data, '{caisse}', v_caisse);

  v_interet    := round(v_row.montant * v_row.taux / 100);
  v_total_du   := v_row.montant + v_interet;
  v_mensualite := round(v_total_du::numeric / v_row.durees_mois);

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

  v_journal := COALESCE(v_data->'journal', '[]'::jsonb);
  v_journal := jsonb_build_array(
    jsonb_build_object(
      'quoi',        format('PRÊT VALIDÉ — %s — %s %s — %s%% — %s mois — via %s',
                            v_row.emprunteur_nom, v_row.montant_net, v_row.devise,
                            v_row.taux, v_row.durees_mois, v_row.operateur),
      'gestionnaire', v_row.gestionnaire,
      'quand',       v_now,
      'reference',   v_row.reference
    )
  ) || v_journal;
  v_data := jsonb_set(v_data, '{journal}', v_journal);

  UPDATE public.tontines SET data = v_data WHERE UPPER(code) = UPPER(v_row.code);
  UPDATE public.prets_pending SET statut = 'validee', validated_at = now() WHERE id = p_id;

  RETURN jsonb_build_object('ok', true, 'pret_reference', v_row.reference,
    'montant_net', v_row.montant_net, 'emprunteur', v_row.emprunteur_nom);
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_valider_pret(text, bigint) TO anon, authenticated;

-- ────────────────────────────────────────────────────────────
-- B2. admin_rejeter_pret
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_rejeter_pret(
  p_cle   text,
  p_id    bigint,
  p_motif text DEFAULT 'Rejeté par l''administrateur'
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.prets_pending WHERE id = p_id AND statut = 'pending') THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Demande introuvable ou déjà traitée');
  END IF;
  UPDATE public.prets_pending
    SET statut = 'rejetee', motif_rejet = p_motif, validated_at = now()
    WHERE id = p_id;
  RETURN jsonb_build_object('ok', true);
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_rejeter_pret(text, bigint, text) TO anon, authenticated;

-- ────────────────────────────────────────────────────────────
-- B3. crediter_remboursement_sycapay
--     Crédite caisse + met à jour prêt après remboursement SycaPay
-- ────────────────────────────────────────────────────────────
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

  SELECT * INTO v_tontine FROM public.tontines WHERE UPPER(code) = UPPER(p_code) LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Tontine introuvable');
  END IF;

  v_data := v_tontine.data;

  -- Idempotence
  FOR v_p IN SELECT jsonb_array_elements(COALESCE(v_data->'prets', '[]'::jsonb)) LOOP
    FOR v_i IN 0..(jsonb_array_length(COALESCE(v_p->'remboursements','[]'::jsonb))-1) LOOP
      IF (v_p->'remboursements'->v_i->>'reference') = p_reference
      OR (v_p->'remboursements'->v_i->>'id') = p_reference THEN
        RETURN jsonb_build_object('ok', true, 'idempotent', true);
      END IF;
    END LOOP;
  END LOOP;

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

  v_prets := COALESCE(v_data->'prets', '[]'::jsonb);
  v_idx   := -1;
  FOR v_i IN 0..(jsonb_array_length(v_prets)-1) LOOP
    IF (v_prets->v_i->>'id') = p_pret_id THEN v_idx := v_i; EXIT; END IF;
  END LOOP;

  IF v_idx >= 0 THEN
    v_pret  := v_prets->v_idx;
    v_rembs := COALESCE(v_pret->'remboursements', '[]'::jsonb);
    v_rembs := v_rembs || jsonb_build_array(
      jsonb_build_object('id', p_reference, 'montant', p_montant, 'date', v_now,
        'methode', p_operateur, 'reference', p_reference, 'numCommande', p_num_commande)
    );
    SELECT COALESCE(SUM((r->>'montant')::integer), 0) INTO v_total_remb
    FROM jsonb_array_elements(v_rembs) AS r;
    v_total_du := COALESCE((v_pret->>'totalDu')::integer, (v_pret->>'resteADu')::integer, 0);
    IF v_total_du = 0 THEN
      v_total_du := (v_pret->>'montant')::integer
                  + round(((v_pret->>'montant')::integer * (v_pret->>'taux')::numeric / 100));
    END IF;
    v_reste      := GREATEST(0, v_total_du - v_total_remb);
    v_pret_solde := v_reste = 0;
    v_pret := v_pret || jsonb_build_object(
      'remboursements', v_rembs, 'resteADu', v_reste, 'totalRembourse', v_total_remb,
      'statut', CASE WHEN v_pret_solde THEN 'soldé' ELSE 'en_cours' END);
    v_prets := jsonb_set(v_prets, ARRAY[v_idx::text], v_pret);
    v_data  := jsonb_set(v_data, '{prets}', v_prets);
  END IF;

  v_journal := COALESCE(v_data->'journal', '[]'::jsonb);
  v_journal := jsonb_build_array(jsonb_build_object(
    'quoi', format('REMBOURSEMENT SycaPay — %s — %s XOF — Réf: %s%s',
                   p_emprunteur_nom, p_montant, p_reference,
                   CASE WHEN v_pret_solde THEN ' — SOLDÉ ✓' ELSE '' END),
    'gestionnaire', p_emprunteur_nom, 'quand', v_now, 'reference', p_reference
  )) || v_journal;
  v_data := jsonb_set(v_data, '{journal}', v_journal);

  UPDATE public.tontines SET data = v_data WHERE UPPER(code) = UPPER(p_code);
  RETURN jsonb_build_object('ok', true, 'pret_solde', v_pret_solde, 'reste', v_reste);
END;
$$;

GRANT EXECUTE ON FUNCTION public.crediter_remboursement_sycapay(
  text, integer, text, text, text, text, text, text, text, text
) TO anon, authenticated;

-- ============================================================
-- SECTION C : Décaissements
-- Source : supabase-decaissements-pending.sql
-- ============================================================

-- ────────────────────────────────────────────────────────────
-- C1. admin_lister_decaissements
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_lister_decaissements(
  p_cle    TEXT,
  p_statut TEXT DEFAULT 'tous'
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_cle_attendue TEXT := current_setting('app.admin_key', true);
  v_rows         JSONB;
BEGIN
  IF v_cle_attendue IS NULL OR v_cle_attendue = '' THEN
    IF p_cle NOT LIKE 'tc-admin%' THEN
      RETURN jsonb_build_object('ok', false, 'erreur', 'Clé admin invalide');
    END IF;
  ELSIF p_cle <> v_cle_attendue THEN
    IF NOT EXISTS (SELECT 1 FROM public.admin_config WHERE cle = p_cle AND actif = true LIMIT 1) THEN
      RETURN jsonb_build_object('ok', false, 'erreur', 'Clé admin invalide');
    END IF;
  END IF;

  IF p_statut = 'tous' THEN
    SELECT jsonb_agg(row_to_json(d.*)::jsonb ORDER BY d.created_at DESC) INTO v_rows
    FROM public.decaissements_pending d;
  ELSE
    SELECT jsonb_agg(row_to_json(d.*)::jsonb ORDER BY d.created_at DESC) INTO v_rows
    FROM public.decaissements_pending d WHERE d.statut = p_statut;
  END IF;

  RETURN COALESCE(v_rows, '[]'::jsonb);
EXCEPTION WHEN OTHERS THEN
  RETURN '[]'::jsonb;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_lister_decaissements(TEXT, TEXT) TO anon, authenticated;

-- ────────────────────────────────────────────────────────────
-- C2. admin_valider_decaissement
--     Débite caisse + ajoute mouvement JSON + marque validée
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_valider_decaissement(
  p_cle TEXT,
  p_id  BIGINT
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_cle_attendue  TEXT := current_setting('app.admin_key', true);
  v_dec           public.decaissements_pending%ROWTYPE;
  v_tontine_data  JSONB;
  v_caisse        JSONB;
  v_mouvements    JSONB;
  v_journal       JSONB;
  v_solde         INTEGER;
  v_ref           TEXT;
  v_now           TEXT;
  v_new_mouvement JSONB;
BEGIN
  IF v_cle_attendue IS NULL OR v_cle_attendue = '' THEN
    IF p_cle NOT LIKE 'tc-admin%' THEN
      RETURN jsonb_build_object('ok', false, 'erreur', 'Clé admin invalide');
    END IF;
  ELSIF p_cle <> v_cle_attendue THEN
    IF NOT EXISTS (SELECT 1 FROM public.admin_config WHERE cle = p_cle AND actif = true LIMIT 1) THEN
      RETURN jsonb_build_object('ok', false, 'erreur', 'Clé admin invalide');
    END IF;
  END IF;

  SELECT * INTO v_dec FROM public.decaissements_pending WHERE id = p_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'erreur', 'Décaissement introuvable'); END IF;
  IF v_dec.statut <> 'pending' THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Décaissement déjà traité (statut: ' || v_dec.statut || ')');
  END IF;

  SELECT data INTO v_tontine_data FROM public.tontines WHERE UPPER(code) = UPPER(v_dec.code);
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'erreur', 'Tontine introuvable: ' || v_dec.code); END IF;

  v_caisse     := COALESCE(v_tontine_data->'caisse', '{"mouvements":[]}'::jsonb);
  v_mouvements := COALESCE(v_caisse->'mouvements', '[]'::jsonb);

  SELECT COALESCE(SUM(CASE
    WHEN (m->>'type') IN ('depot','cotisation','remboursement','apport') THEN  (m->>'montant')::integer
    WHEN (m->>'type') IN ('depense','pret','penalite','correction','decaissement') THEN -((m->>'montant')::integer)
    ELSE 0 END), 0)
  INTO v_solde FROM jsonb_array_elements(v_mouvements) AS m;

  IF v_solde < v_dec.montant_net THEN
    RETURN jsonb_build_object('ok', false, 'erreur',
      format('Solde caisse insuffisant : %s %s disponible, %s %s requis',
             v_solde, v_dec.devise, v_dec.montant_net, v_dec.devise));
  END IF;

  v_ref := COALESCE(NULLIF(v_dec.reference, ''), 'DEC-' || EXTRACT(EPOCH FROM NOW())::BIGINT::TEXT);
  v_now := to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"');

  v_new_mouvement := jsonb_build_object(
    'id', v_ref, 'type', 'decaissement', 'montant', v_dec.montant_net,
    'description', format('Décaissement tour %s — %s — Mobile Money %s',
                          v_dec.numer_tour, v_dec.beneficiaire_nom, upper(v_dec.operateur)),
    'gestionnaire', v_dec.gestionnaire, 'date', v_now, 'reference', v_ref,
    'methode', v_dec.operateur, 'numero_beneficiaire', v_dec.numero_beneficiaire,
    'beneficiaire_id', v_dec.beneficiaire_id, 'beneficiaire_nom', v_dec.beneficiaire_nom,
    'numer_tour', v_dec.numer_tour, 'commission', v_dec.commission,
    'montant_brut', v_dec.montant, 'decaissement_id', p_id
  );

  IF jsonb_typeof(v_caisse) = 'object' THEN
    v_mouvements := COALESCE(v_caisse->'mouvements', '[]'::jsonb);
    v_caisse := jsonb_set(v_caisse, '{mouvements}', v_mouvements || jsonb_build_array(v_new_mouvement));
  ELSIF jsonb_typeof(v_caisse) = 'array' THEN
    v_caisse := jsonb_build_object('mouvements', v_caisse || jsonb_build_array(v_new_mouvement));
  ELSE
    v_caisse := jsonb_build_object('mouvements', jsonb_build_array(v_new_mouvement));
  END IF;

  v_tontine_data := jsonb_set(v_tontine_data, '{caisse}', v_caisse);
  v_journal := COALESCE(v_tontine_data->'journal', '[]'::jsonb);
  v_journal := jsonb_build_array(jsonb_build_object(
    'quoi', format('DÉCAISSEMENT VALIDÉ — Tour %s — %s — %s %s (net) — %s [commission: %s %s] — %s',
                   v_dec.numer_tour, v_dec.beneficiaire_nom, v_dec.montant_net, v_dec.devise,
                   upper(v_dec.operateur), v_dec.commission, v_dec.devise, v_dec.numero_beneficiaire),
    'gestionnaire', v_dec.gestionnaire, 'quand', v_now, 'reference', v_ref
  )) || v_journal;
  v_tontine_data := jsonb_set(v_tontine_data, '{journal}', v_journal);

  UPDATE public.tontines SET data = v_tontine_data, modifie_le = NOW() WHERE UPPER(code) = UPPER(v_dec.code);
  UPDATE public.decaissements_pending SET statut = 'validee', validated_at = NOW(), valide_par = 'admin' WHERE id = p_id;

  RETURN jsonb_build_object('ok', true,
    'message', format('Décaissement validé — caisse débitée de %s %s (commission %s %s déduite)',
                      v_dec.montant_net, v_dec.devise, v_dec.commission, v_dec.devise),
    'montant_net', v_dec.montant_net, 'commission', v_dec.commission,
    'beneficiaire', v_dec.beneficiaire_nom, 'numer_tour', v_dec.numer_tour);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'erreur', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_valider_decaissement(TEXT, BIGINT) TO anon, authenticated;

-- ────────────────────────────────────────────────────────────
-- C3. admin_rejeter_decaissement
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_rejeter_decaissement(
  p_cle   TEXT,
  p_id    BIGINT,
  p_motif TEXT DEFAULT 'Rejeté par l''administrateur'
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_cle_attendue TEXT := current_setting('app.admin_key', true);
  v_dec          public.decaissements_pending%ROWTYPE;
BEGIN
  IF v_cle_attendue IS NULL OR v_cle_attendue = '' THEN
    IF p_cle NOT LIKE 'tc-admin%' THEN
      RETURN jsonb_build_object('ok', false, 'erreur', 'Clé admin invalide');
    END IF;
  ELSIF p_cle <> v_cle_attendue THEN
    IF NOT EXISTS (SELECT 1 FROM public.admin_config WHERE cle = p_cle AND actif = true LIMIT 1) THEN
      RETURN jsonb_build_object('ok', false, 'erreur', 'Clé admin invalide');
    END IF;
  END IF;

  SELECT * INTO v_dec FROM public.decaissements_pending WHERE id = p_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'erreur', 'Décaissement introuvable'); END IF;
  IF v_dec.statut <> 'pending' THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Décaissement déjà traité (statut: ' || v_dec.statut || ')');
  END IF;

  UPDATE public.decaissements_pending
    SET statut = 'rejetee', motif_rejet = p_motif, validated_at = NOW(), valide_par = 'admin'
    WHERE id = p_id;

  RETURN jsonb_build_object('ok', true, 'message', 'Décaissement rejeté. La caisse n''a pas été modifiée.',
    'beneficiaire', v_dec.beneficiaire_nom, 'numer_tour', v_dec.numer_tour);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'erreur', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_rejeter_decaissement(TEXT, BIGINT, TEXT) TO anon, authenticated;

-- ============================================================
-- SECTION D : Dépenses
-- Source : supabase-depenses-pending.sql
-- ============================================================

-- ────────────────────────────────────────────────────────────
-- D1. admin_valider_depense
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_valider_depense(
  p_cle TEXT,
  p_id  BIGINT
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_cle_attendue TEXT := current_setting('app.admin_key', true);
  v_depense       public.depenses_pending%ROWTYPE;
  v_tontine_data  JSONB;
  v_caisse        JSONB;
  v_mouvements    JSONB;
  v_ref           TEXT;
  v_now           TEXT;
  v_new_mouvement JSONB;
BEGIN
  IF v_cle_attendue IS NULL OR v_cle_attendue = '' THEN
    IF p_cle NOT LIKE 'tc-admin%' THEN
      RETURN jsonb_build_object('ok', false, 'erreur', 'Clé admin invalide');
    END IF;
  ELSIF p_cle <> v_cle_attendue THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Clé admin invalide');
  END IF;

  SELECT * INTO v_depense FROM public.depenses_pending WHERE id = p_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'erreur', 'Dépense introuvable'); END IF;
  IF v_depense.statut <> 'pending' THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Dépense déjà traitée (statut: ' || v_depense.statut || ')');
  END IF;

  SELECT data INTO v_tontine_data FROM public.tontines WHERE code = v_depense.code;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'erreur', 'Tontine introuvable: ' || v_depense.code); END IF;

  v_ref := 'DEP-' || EXTRACT(EPOCH FROM NOW())::BIGINT::TEXT;
  v_now := NOW()::TEXT;

  v_new_mouvement := jsonb_build_object(
    'id', v_ref, 'type', 'depense', 'montant', v_depense.montant,
    'description', COALESCE(NULLIF(v_depense.description, ''), 'Dépense Mobile Money — ' || v_depense.operateur),
    'gestionnaire', v_depense.gestionnaire, 'date', v_now, 'reference', v_ref,
    'methode', v_depense.operateur, 'numero_beneficiaire', v_depense.numero_beneficiaire,
    'nom_beneficiaire', v_depense.nom_beneficiaire, 'depense_id', p_id
  );

  v_caisse := COALESCE(v_tontine_data->'caisse', '{}'::jsonb);
  IF jsonb_typeof(v_caisse) = 'object' THEN
    v_mouvements := COALESCE(v_caisse->'mouvements', '[]'::jsonb);
    v_caisse := jsonb_set(v_caisse, '{mouvements}', v_mouvements || jsonb_build_array(v_new_mouvement));
  ELSIF jsonb_typeof(v_caisse) = 'array' THEN
    v_caisse := jsonb_build_object('mouvements', v_caisse || jsonb_build_array(v_new_mouvement));
  ELSE
    v_caisse := jsonb_build_object('mouvements', jsonb_build_array(v_new_mouvement));
  END IF;

  v_tontine_data := jsonb_set(v_tontine_data, '{caisse}', v_caisse);
  UPDATE public.tontines SET data = v_tontine_data, modifie_le = NOW() WHERE code = v_depense.code;
  UPDATE public.depenses_pending SET statut = 'validee', valide_le = NOW(), valide_par = 'admin' WHERE id = p_id;

  RETURN jsonb_build_object('ok', true,
    'message', 'Dépense validée — caisse débitée de ' || v_depense.montant::TEXT || ' ' || v_depense.devise);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'erreur', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_valider_depense TO anon, authenticated;

-- ────────────────────────────────────────────────────────────
-- D2. admin_rejeter_depense
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_rejeter_depense(
  p_cle   TEXT,
  p_id    BIGINT,
  p_motif TEXT
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_cle_attendue TEXT := current_setting('app.admin_key', true);
  v_depense      public.depenses_pending%ROWTYPE;
BEGIN
  IF v_cle_attendue IS NULL OR v_cle_attendue = '' THEN
    IF p_cle NOT LIKE 'tc-admin%' THEN
      RETURN jsonb_build_object('ok', false, 'erreur', 'Clé admin invalide');
    END IF;
  ELSIF p_cle <> v_cle_attendue THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Clé admin invalide');
  END IF;

  SELECT * INTO v_depense FROM public.depenses_pending WHERE id = p_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'erreur', 'Dépense introuvable'); END IF;
  IF v_depense.statut <> 'pending' THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Dépense déjà traitée');
  END IF;

  UPDATE public.depenses_pending
    SET statut = 'rejetee', motif_rejet = p_motif, valide_le = NOW(), valide_par = 'admin'
    WHERE id = p_id;

  RETURN jsonb_build_object('ok', true, 'message', 'Dépense rejetée.');
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'erreur', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_rejeter_depense TO anon, authenticated;

-- ============================================================
-- SECTION E : KYC
-- Source : supabase-kyc.sql
-- ============================================================

-- ────────────────────────────────────────────────────────────
-- E1. admin_lister_kyc
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_lister_kyc(
  p_cle    TEXT,
  p_statut TEXT DEFAULT 'tous'
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_attendue TEXT;
  v_liste    JSONB;
BEGIN
  SELECT value INTO v_attendue FROM public.app_config WHERE key = 'admin_key' LIMIT 1;
  IF v_attendue IS NULL OR p_cle <> v_attendue THEN
    RAISE EXCEPTION 'Clé admin invalide';
  END IF;

  IF p_statut = 'tous' THEN
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id', k.id, 'code', k.code, 'gestionnaire', k.gestionnaire, 'nom', k.nom,
      'piece_type', k.piece_type, 'piece_numero', k.piece_numero, 'soumis_le', k.soumis_le,
      'statut', k.statut, 'motif_rejet', k.motif_rejet, 'valide_par', k.valide_par,
      'validated_at', k.validated_at, 'created_at', k.created_at
    ) ORDER BY k.created_at DESC), '[]'::jsonb) INTO v_liste FROM public.kyc_submissions k;
  ELSE
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id', k.id, 'code', k.code, 'gestionnaire', k.gestionnaire, 'nom', k.nom,
      'piece_type', k.piece_type, 'piece_numero', k.piece_numero, 'soumis_le', k.soumis_le,
      'statut', k.statut, 'motif_rejet', k.motif_rejet, 'valide_par', k.valide_par,
      'validated_at', k.validated_at, 'created_at', k.created_at
    ) ORDER BY k.created_at DESC), '[]'::jsonb) INTO v_liste FROM public.kyc_submissions k WHERE k.statut = p_statut;
  END IF;

  RETURN v_liste;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_lister_kyc TO anon, authenticated;

-- ────────────────────────────────────────────────────────────
-- E2. admin_valider_kyc
--     Valide KYC : met à jour kyc_submissions + tontines.data.kyc
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_valider_kyc(
  p_cle TEXT,
  p_id  BIGINT
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_attendue   TEXT;
  v_submission RECORD;
  v_now        TIMESTAMPTZ := NOW();
BEGIN
  SELECT value INTO v_attendue FROM public.app_config WHERE key = 'admin_key' LIMIT 1;
  IF v_attendue IS NULL OR p_cle <> v_attendue THEN RAISE EXCEPTION 'Clé admin invalide'; END IF;

  SELECT * INTO v_submission FROM public.kyc_submissions WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'erreur', 'Dossier KYC introuvable.'); END IF;
  IF v_submission.statut <> 'pending' THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Ce dossier a déjà été traité (statut : ' || v_submission.statut || ').');
  END IF;

  UPDATE public.kyc_submissions SET statut = 'valide', validated_at = v_now, valide_par = 'admin' WHERE id = p_id;
  UPDATE public.tontines SET data = jsonb_set(COALESCE(data, '{}'::jsonb), '{kyc, statut}', '"valide"', true)
    WHERE code = v_submission.code;

  RETURN jsonb_build_object('ok', true, 'message', 'Dossier KYC validé avec succès.',
    'gestionnaire', v_submission.gestionnaire, 'code', v_submission.code);
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_valider_kyc TO anon, authenticated;

-- ────────────────────────────────────────────────────────────
-- E3. admin_rejeter_kyc
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_rejeter_kyc(
  p_cle   TEXT,
  p_id    BIGINT,
  p_motif TEXT DEFAULT 'Dossier non conforme.'
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_attendue   TEXT;
  v_submission RECORD;
  v_now        TIMESTAMPTZ := NOW();
BEGIN
  SELECT value INTO v_attendue FROM public.app_config WHERE key = 'admin_key' LIMIT 1;
  IF v_attendue IS NULL OR p_cle <> v_attendue THEN RAISE EXCEPTION 'Clé admin invalide'; END IF;

  SELECT * INTO v_submission FROM public.kyc_submissions WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'erreur', 'Dossier KYC introuvable.'); END IF;
  IF v_submission.statut <> 'pending' THEN
    RETURN jsonb_build_object('ok', false, 'erreur', 'Ce dossier a déjà été traité (statut : ' || v_submission.statut || ').');
  END IF;

  UPDATE public.kyc_submissions SET statut = 'rejete', motif_rejet = p_motif, validated_at = v_now, valide_par = 'admin' WHERE id = p_id;
  UPDATE public.tontines
    SET data = jsonb_set(jsonb_set(COALESCE(data, '{}'::jsonb), '{kyc, statut}', '"rejete"', true),
                         '{kyc, motifRejet}', to_jsonb(p_motif), true)
    WHERE code = v_submission.code;

  RETURN jsonb_build_object('ok', true, 'message', 'Dossier KYC rejeté.',
    'gestionnaire', v_submission.gestionnaire, 'code', v_submission.code, 'motif', p_motif);
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_rejeter_kyc TO anon, authenticated;

GRANT SELECT, INSERT, UPDATE ON public.kyc_submissions TO anon, authenticated;

-- ============================================================
-- SECTION F : Admin Team + Messagerie + Support
-- Source : supabase-admin-team.sql
-- ============================================================

-- ────────────────────────────────────────────────────────────
-- F0. generer_ref_ticket (helper)
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION generer_ref_ticket()
RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE
  annee TEXT := TO_CHAR(NOW(), 'YYYY');
  seq   BIGINT;
BEGIN
  SELECT COALESCE(MAX(id), 0) + 1 INTO seq FROM support_tickets;
  RETURN 'TC-' || annee || '-' || LPAD(seq::TEXT, 4, '0');
END;
$$;

-- ────────────────────────────────────────────────────────────
-- F1. admin_lister_membres (super_admin only)
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION admin_lister_membres(p_cle TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_cle TEXT;
BEGIN
  SELECT valeur INTO v_cle FROM app_config WHERE cle = 'admin_key';
  IF v_cle IS NULL OR p_cle != v_cle THEN RAISE EXCEPTION 'Clé admin invalide'; END IF;
  RETURN (
    SELECT JSONB_AGG(JSONB_BUILD_OBJECT(
      'id', m.id, 'nom', m.nom, 'pseudo', m.pseudo, 'role', m.role,
      'actif', m.actif, 'cree_par', m.cree_par, 'cree_le', m.cree_le,
      'derniere_connexion', m.derniere_connexion
    ) ORDER BY m.cree_le ASC)
    FROM admin_membres m
  );
END;
$$;

-- ────────────────────────────────────────────────────────────
-- F2. admin_creer_membre
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION admin_creer_membre(
  p_cle TEXT, p_nom TEXT, p_pseudo TEXT, p_cle_perso TEXT, p_role TEXT, p_cree_par TEXT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_cle TEXT; v_hash TEXT; v_nouveau admin_membres;
BEGIN
  SELECT valeur INTO v_cle FROM app_config WHERE cle = 'admin_key';
  IF v_cle IS NULL OR p_cle != v_cle THEN RAISE EXCEPTION 'Clé admin invalide'; END IF;
  IF p_role NOT IN ('super_admin','comptable','conformite') THEN
    RAISE EXCEPTION 'Rôle invalide: %', p_role;
  END IF;
  v_hash := ENCODE(SHA256(p_cle_perso::BYTEA), 'hex');
  INSERT INTO admin_membres (nom, pseudo, cle_hash, role, actif, cree_par)
  VALUES (p_nom, p_pseudo, v_hash, p_role, TRUE, p_cree_par)
  RETURNING * INTO v_nouveau;
  RETURN JSONB_BUILD_OBJECT('id', v_nouveau.id, 'pseudo', v_nouveau.pseudo,
    'role', v_nouveau.role, 'actif', v_nouveau.actif);
END;
$$;

-- ────────────────────────────────────────────────────────────
-- F3. admin_modifier_membre
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION admin_modifier_membre(
  p_cle TEXT, p_id BIGINT, p_role TEXT DEFAULT NULL, p_actif BOOLEAN DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_cle TEXT;
BEGIN
  SELECT valeur INTO v_cle FROM app_config WHERE cle = 'admin_key';
  IF v_cle IS NULL OR p_cle != v_cle THEN RAISE EXCEPTION 'Clé admin invalide'; END IF;
  UPDATE admin_membres SET role = COALESCE(p_role, role), actif = COALESCE(p_actif, actif) WHERE id = p_id;
  RETURN JSONB_BUILD_OBJECT('ok', TRUE, 'id', p_id);
END;
$$;

-- ────────────────────────────────────────────────────────────
-- F4. admin_auth_membre
--     Authentifie un membre admin par pseudo + clé personnelle (hash SHA-256)
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION admin_auth_membre(p_pseudo TEXT, p_cle_perso TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_membre admin_membres%ROWTYPE;
  v_hash   TEXT;
BEGIN
  v_hash := ENCODE(SHA256(p_cle_perso::BYTEA), 'hex');
  SELECT * INTO v_membre FROM admin_membres WHERE pseudo = p_pseudo AND cle_hash = v_hash AND actif = TRUE;
  IF NOT FOUND THEN
    RETURN JSONB_BUILD_OBJECT('ok', FALSE, 'erreur', 'Identifiants incorrects');
  END IF;
  UPDATE admin_membres SET derniere_connexion = NOW() WHERE id = v_membre.id;
  RETURN JSONB_BUILD_OBJECT('ok', TRUE, 'id', v_membre.id, 'nom', v_membre.nom,
    'pseudo', v_membre.pseudo, 'role', v_membre.role);
END;
$$;

-- ────────────────────────────────────────────────────────────
-- F5. admin_lister_messages
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION admin_lister_messages(
  p_pseudo TEXT, p_cle_perso TEXT, p_boite TEXT DEFAULT 'recus'
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_hash TEXT; v_ok BOOLEAN;
BEGIN
  v_hash := ENCODE(SHA256(p_cle_perso::BYTEA), 'hex');
  SELECT EXISTS(SELECT 1 FROM admin_membres WHERE pseudo = p_pseudo AND cle_hash = v_hash AND actif) INTO v_ok;
  IF NOT v_ok THEN RAISE EXCEPTION 'Authentification requise'; END IF;
  RETURN (
    SELECT JSONB_AGG(JSONB_BUILD_OBJECT(
      'id', m.id, 'expediteur', m.expediteur, 'destinataire', m.destinataire,
      'sujet', m.sujet, 'corps', m.corps, 'lu', m.lu, 'lu_le', m.lu_le, 'envoye_le', m.envoye_le
    ) ORDER BY m.envoye_le DESC)
    FROM admin_messages m
    WHERE CASE p_boite
      WHEN 'recus'   THEN m.destinataire IN (p_pseudo, 'tous')
      WHEN 'envoyes' THEN m.expediteur = p_pseudo
      ELSE                m.destinataire IN (p_pseudo, 'tous') OR m.expediteur = p_pseudo
    END
  );
END;
$$;

-- ────────────────────────────────────────────────────────────
-- F6. admin_envoyer_message
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION admin_envoyer_message(
  p_pseudo TEXT, p_cle_perso TEXT, p_destinataire TEXT, p_sujet TEXT, p_corps TEXT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_hash TEXT; v_ok BOOLEAN; v_id BIGINT;
BEGIN
  v_hash := ENCODE(SHA256(p_cle_perso::BYTEA), 'hex');
  SELECT EXISTS(SELECT 1 FROM admin_membres WHERE pseudo = p_pseudo AND cle_hash = v_hash AND actif) INTO v_ok;
  IF NOT v_ok THEN RAISE EXCEPTION 'Authentification requise'; END IF;
  INSERT INTO admin_messages (expediteur, destinataire, sujet, corps)
  VALUES (p_pseudo, p_destinataire, p_sujet, p_corps) RETURNING id INTO v_id;
  RETURN JSONB_BUILD_OBJECT('ok', TRUE, 'id', v_id);
END;
$$;

-- ────────────────────────────────────────────────────────────
-- F7. admin_marquer_lu
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION admin_marquer_lu(
  p_pseudo TEXT, p_cle_perso TEXT, p_message_id BIGINT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_hash TEXT; v_ok BOOLEAN;
BEGIN
  v_hash := ENCODE(SHA256(p_cle_perso::BYTEA), 'hex');
  SELECT EXISTS(SELECT 1 FROM admin_membres WHERE pseudo = p_pseudo AND cle_hash = v_hash AND actif) INTO v_ok;
  IF NOT v_ok THEN RAISE EXCEPTION 'Authentification requise'; END IF;
  UPDATE admin_messages SET lu = TRUE, lu_le = NOW()
    WHERE id = p_message_id AND destinataire IN (p_pseudo, 'tous');
  RETURN JSONB_BUILD_OBJECT('ok', TRUE);
END;
$$;

-- ────────────────────────────────────────────────────────────
-- F8. admin_compter_non_lus
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION admin_compter_non_lus(p_pseudo TEXT, p_cle_perso TEXT)
RETURNS BIGINT LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_hash TEXT; v_ok BOOLEAN; v_count BIGINT;
BEGIN
  v_hash := ENCODE(SHA256(p_cle_perso::BYTEA), 'hex');
  SELECT EXISTS(SELECT 1 FROM admin_membres WHERE pseudo = p_pseudo AND cle_hash = v_hash AND actif) INTO v_ok;
  IF NOT v_ok THEN RETURN 0; END IF;
  SELECT COUNT(*) INTO v_count FROM admin_messages
    WHERE destinataire IN (p_pseudo, 'tous') AND lu = FALSE AND expediteur != p_pseudo;
  RETURN v_count;
END;
$$;

-- ────────────────────────────────────────────────────────────
-- F9. support_ouvrir_ticket (client)
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION support_ouvrir_ticket(
  p_gestionnaire TEXT, p_code_tontine TEXT, p_categorie TEXT,
  p_sujet TEXT, p_description TEXT, p_priorite TEXT DEFAULT 'normale'
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_ref TEXT; v_id BIGINT;
BEGIN
  v_ref := generer_ref_ticket();
  INSERT INTO support_tickets (ref, gestionnaire, code_tontine, categorie, sujet, description, priorite)
  VALUES (v_ref, p_gestionnaire, p_code_tontine, p_categorie, p_sujet, p_description, p_priorite)
  RETURNING id INTO v_id;
  INSERT INTO support_messages (ticket_id, auteur, est_admin, corps, lu_admin)
  VALUES (v_id, p_gestionnaire, FALSE, p_description, FALSE);
  RETURN JSONB_BUILD_OBJECT('ok', TRUE, 'id', v_id, 'ref', v_ref);
END;
$$;

-- ────────────────────────────────────────────────────────────
-- F10. support_mes_tickets (client — par gestionnaire)
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION support_mes_tickets(p_gestionnaire TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  RETURN (
    SELECT JSONB_AGG(JSONB_BUILD_OBJECT(
      'id', t.id, 'ref', t.ref, 'categorie', t.categorie, 'sujet', t.sujet,
      'statut', t.statut, 'priorite', t.priorite, 'assigne_a', t.assigne_a,
      'cree_le', t.cree_le, 'mis_a_jour', t.mis_a_jour,
      'nb_non_lus', (SELECT COUNT(*) FROM support_messages sm
                     WHERE sm.ticket_id = t.id AND sm.est_admin = TRUE AND sm.lu_client = FALSE)
    ) ORDER BY t.cree_le DESC)
    FROM support_tickets t WHERE t.gestionnaire = p_gestionnaire
  );
END;
$$;

-- ────────────────────────────────────────────────────────────
-- F11. admin_lister_tickets (admin)
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION admin_lister_tickets(
  p_cle TEXT, p_statut TEXT DEFAULT 'tous'
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_cle TEXT;
BEGIN
  SELECT valeur INTO v_cle FROM app_config WHERE cle = 'admin_key';
  IF v_cle IS NULL OR p_cle != v_cle THEN RAISE EXCEPTION 'Clé admin invalide'; END IF;
  RETURN (
    SELECT JSONB_AGG(JSONB_BUILD_OBJECT(
      'id', t.id, 'ref', t.ref, 'gestionnaire', t.gestionnaire, 'code_tontine', t.code_tontine,
      'categorie', t.categorie, 'sujet', t.sujet, 'statut', t.statut, 'priorite', t.priorite,
      'assigne_a', t.assigne_a, 'cree_le', t.cree_le, 'mis_a_jour', t.mis_a_jour,
      'nb_non_lus', (SELECT COUNT(*) FROM support_messages sm
                     WHERE sm.ticket_id = t.id AND sm.est_admin = FALSE AND sm.lu_admin = FALSE)
    ) ORDER BY CASE t.priorite WHEN 'urgente' THEN 1 WHEN 'haute' THEN 2 WHEN 'normale' THEN 3 ELSE 4 END,
               t.mis_a_jour DESC)
    FROM support_tickets t WHERE p_statut = 'tous' OR t.statut = p_statut
  );
END;
$$;

-- ────────────────────────────────────────────────────────────
-- F12. support_messages_ticket (client ou admin — marque lu)
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION support_messages_ticket(
  p_ticket_id BIGINT, p_est_admin BOOLEAN DEFAULT FALSE, p_cle_ou_gest TEXT DEFAULT ''
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_cle TEXT; v_ok BOOLEAN := FALSE;
BEGIN
  IF p_est_admin THEN
    SELECT valeur INTO v_cle FROM app_config WHERE cle = 'admin_key';
    v_ok := (v_cle IS NOT NULL AND p_cle_ou_gest = v_cle);
    IF v_ok THEN
      UPDATE support_messages SET lu_admin = TRUE
        WHERE ticket_id = p_ticket_id AND est_admin = FALSE AND lu_admin = FALSE;
    END IF;
  ELSE
    SELECT EXISTS(SELECT 1 FROM support_tickets WHERE id = p_ticket_id AND gestionnaire = p_cle_ou_gest) INTO v_ok;
    IF v_ok THEN
      UPDATE support_messages SET lu_client = TRUE
        WHERE ticket_id = p_ticket_id AND est_admin = TRUE AND lu_client = FALSE;
    END IF;
  END IF;
  IF NOT v_ok THEN RAISE EXCEPTION 'Accès refusé'; END IF;
  RETURN (
    SELECT JSONB_AGG(JSONB_BUILD_OBJECT(
      'id', sm.id, 'auteur', sm.auteur, 'est_admin', sm.est_admin,
      'corps', sm.corps, 'envoye_le', sm.envoye_le
    ) ORDER BY sm.envoye_le ASC)
    FROM support_messages sm WHERE sm.ticket_id = p_ticket_id
  );
END;
$$;

-- ────────────────────────────────────────────────────────────
-- F13. support_repondre (client ou admin)
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION support_repondre(
  p_ticket_id BIGINT, p_auteur TEXT, p_corps TEXT,
  p_est_admin BOOLEAN DEFAULT FALSE, p_cle_ou_gest TEXT DEFAULT ''
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_cle TEXT; v_ok BOOLEAN := FALSE; v_id BIGINT;
BEGIN
  IF p_est_admin THEN
    SELECT valeur INTO v_cle FROM app_config WHERE cle = 'admin_key';
    v_ok := (v_cle IS NOT NULL AND p_cle_ou_gest = v_cle);
  ELSE
    SELECT EXISTS(SELECT 1 FROM support_tickets WHERE id = p_ticket_id AND gestionnaire = p_cle_ou_gest) INTO v_ok;
  END IF;
  IF NOT v_ok THEN RAISE EXCEPTION 'Accès refusé'; END IF;
  INSERT INTO support_messages (ticket_id, auteur, est_admin, corps)
  VALUES (p_ticket_id, p_auteur, p_est_admin, p_corps) RETURNING id INTO v_id;
  UPDATE support_tickets SET mis_a_jour = NOW(),
    statut = CASE WHEN p_est_admin AND statut = 'ouvert' THEN 'en_cours' ELSE statut END
    WHERE id = p_ticket_id;
  RETURN JSONB_BUILD_OBJECT('ok', TRUE, 'id', v_id);
END;
$$;

-- ────────────────────────────────────────────────────────────
-- F14. admin_changer_statut_ticket
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION admin_changer_statut_ticket(
  p_cle TEXT, p_ticket_id BIGINT, p_statut TEXT, p_assigne_a TEXT DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_cle TEXT;
BEGIN
  SELECT valeur INTO v_cle FROM app_config WHERE cle = 'admin_key';
  IF v_cle IS NULL OR p_cle != v_cle THEN RAISE EXCEPTION 'Clé admin invalide'; END IF;
  UPDATE support_tickets SET statut = p_statut, assigne_a = COALESCE(p_assigne_a, assigne_a),
    mis_a_jour = NOW(),
    resolu_le = CASE WHEN p_statut IN ('resolu','ferme') THEN NOW() ELSE resolu_le END
    WHERE id = p_ticket_id;
  RETURN JSONB_BUILD_OBJECT('ok', TRUE);
END;
$$;

-- ────────────────────────────────────────────────────────────
-- Vérification post-déploiement
-- ────────────────────────────────────────────────────────────
DO $verify009$
DECLARE
  v_fns text[] := ARRAY[
    'est_premium','lire_abonnement_tontine','verif_limite_membres',
    'enregistrer_abonnement_web','expirer_abonnements_obsoletes',
    'admin_valider_pret','admin_rejeter_pret','crediter_remboursement_sycapay',
    'admin_lister_decaissements','admin_valider_decaissement','admin_rejeter_decaissement',
    'admin_valider_depense','admin_rejeter_depense',
    'admin_lister_kyc','admin_valider_kyc','admin_rejeter_kyc',
    'admin_lister_membres','admin_creer_membre','admin_modifier_membre','admin_auth_membre',
    'admin_lister_messages','admin_envoyer_message','admin_marquer_lu','admin_compter_non_lus',
    'generer_ref_ticket','support_ouvrir_ticket','support_mes_tickets',
    'admin_lister_tickets','support_messages_ticket','support_repondre',
    'admin_changer_statut_ticket'
  ];
  v_fn text;
  v_ok boolean;
BEGIN
  FOREACH v_fn IN ARRAY v_fns LOOP
    SELECT EXISTS(SELECT 1 FROM pg_proc WHERE proname = v_fn) INTO v_ok;
    RAISE NOTICE '009 % : %', v_fn, CASE WHEN v_ok THEN 'OK' ELSE 'MANQUANT' END;
  END LOOP;
END;
$verify009$;
-- ============================================================
-- FIN 009_rpcs_financier_support.sql
-- ============================================================
