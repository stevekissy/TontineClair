# TontineClair — Base de données Supabase

## Vue d'ensemble

Ce dossier contient la **reconstruction consolidée** de toute la base Supabase de TontineClair, issue de l'analyse de 31 fichiers SQL sources accumulés au fil du développement.

See [`audit_report.md`](./audit_report.md) for the full cross-reference audit (Q1: full reconstruction, Q2: RPC coverage, Q3: safe-to-delete source files).

```
database/
├── init.sql                    ← Script maître : reconstruit la base entière
└── migrations/
    ├── 001_tables_core.sql
    ├── 002_tables_scores_audit.sql
    ├── 003_tables_financier.sql
    ├── 004_tables_kyc_notifs.sql
    ├── 005_tables_admin_team_support.sql
    ├── 006_rpcs_tontines_core.sql
    ├── 007_rpcs_scores_audit.sql
    ├── 008_rpcs_admin.sql
    ├── 009_rpcs_financier_support.sql
    ├── 010_rpcs_notifs_sycapay.sql
    └── 011_rpcs_core_v1.sql       ← RPCs fondamentales v1 reconstruites
├── audit_report.md               ← Rapport d'audit complet
```

---

## Reconstruction depuis zéro

### Via psql (recommandé)

```bash
psql postgresql://postgres:<PASSWORD>@<HOST>:5432/postgres \
  -v DATESTRING="$(date)" \
  -f database/init.sql
```

### Via Supabase SQL Editor

Les commandes `\i` ne fonctionnent pas dans l'éditeur web. Utiliser le contenu
inline :

```bash
# Générer un fichier SQL unique
cat database/migrations/*.sql > database/init_inline.sql
```

Puis copier-coller `init_inline.sql` dans le SQL Editor Supabase.

---

## Contenu des migrations

| Fichier | Tables / Fonctions | Lignes |
|---------|-------------------|--------|
| `001_tables_core.sql` | `tontines`, `audit_log`, `demandes_premium`, `config`, `app_config`, `admin_config` | ~180 |
| `002_tables_scores_audit.sql` | `scores_historique`, `propositions_retrait`, `journal_audit` | ~120 |
| `003_tables_financier.sql` | `subscriptions`, `abonnements`, `admin_actions`, `sycapay_transactions`, `prets_pending`, `decaissements_pending`, `depenses_pending`, `premium_requests` | ~280 |
| `004_tables_kyc_notifs.sql` | `kyc_submissions`, `fcm_tokens`, `rappels_envoyes` | ~100 |
| `005_tables_admin_team_support.sql` | `admin_membres`, `admin_messages`, `support_tickets`, `support_messages` | ~140 |
| `006_rpcs_tontines_core.sql` | 17 RPCs : `lire_tontine`, `ecrire_tontine_sans_pin`, `verifier_gestionnaire`, `check_invitation_code` (v17), `join_tontine_by_code`, `delete_tontine`, `restore_deleted_tontine`, `maj_echeance`, `lire_config_tontine`, `voter` (v18), `cloturer_tour` (v11), `proposer_nouveau_cycle` (v15), `lire_etat_cycle`, `clore_vote_redemarrage`, `demarrer_nouveau_cycle`, `demander_premium` (v12) | ~625 |
| `007_rpcs_scores_audit.sql` | 11 RPCs : `enregistrer_score`, `lire_historique_score`, `lire_scores_tontine`, `proposer_retrait`, `lire_propositions_retrait`, `maj_statut_retrait`, `lire_journal_audit`, `init_score_membre`, `modifier_score_membre` (v14-FINAL), `lire_score_membre`, `reinitialiser_score_override` | ~470 |
| `008_rpcs_admin.sql` | 14 RPCs + 1 trigger : `_verif_admin_cle`, `admin_stats_globales`, `admin_dashboard_tontines`, `admin_lister_abonnements`, `admin_alertes` (v1.2), `admin_enregistrer_abonnement`, `admin_stats_mensuelles`, `admin_top_tontines`, `admin_tontine_counts` (v17), `admin_lister_tontines` (v17-FINAL), `tontines_set_updated_at`, `admin_lister_demandes` (v12-FINAL), `admin_activer_premium` (v12), `admin_refuser_demande` (v12) | ~680 |
| `009_rpcs_financier_support.sql` | 31 RPCs : abonnements (7), prêts (3), décaissements (3), dépenses (2), KYC (3), admin team (4), messagerie (4), support (7) | ~1 400 |
| `010_rpcs_notifs_sycapay.sql` | 8 RPCs : `sauvegarder_token`, `creer_transaction_sycapay`, `get_pending_sycapay_transactions`, `crediter_caisse_sycapay`, `crediter_cotisation_sycapay`, `crediter_penalite_sycapay`, `recalculer_echeances_expir`, `distribuer_tour` | ~700 |
| `011_rpcs_core_v1.sql` | 10 RPCs reconstruites : `creer_tontine`, `ecrire_tontine`, `lire_voix_tontine`, `lire_plan`, `membres_avec_pin`, `definir_pin_membre`, `changer_pin_membre`, `admin_desactiver_premium`, `sauvegarder_langue_appareil`, `charger_langue_appareil` | ~380 |

**Total : 20 tables · 93 fonctions RPC · 1 trigger**  
*(+10 fonctions v1 reconstruites dans migration 011 — jamais sauvegardées en repo avant cet audit)*

---

## Analyse des sources — Fichiers archivables

### Légende

- ✅ **CANONIQUE** — contenu intégré dans les migrations 001-010
- 🗑️ **ARCHIVER** — doublon ou version obsolète, safe to delete
- ⚠️ **PARTIEL** — certaines fonctions supersédées, d'autres réutilisées

---

### Tableau complet des 27 fichiers sources

| Fichier source | Statut | Raison | Contenu migré dans |
|----------------|--------|--------|-------------------|
| `supabase-v6.sql` | ✅ CANONIQUE | Version définitive des tables scores/audit + 8 RPCs | 002 + 007 |
| `supabase-v14-FINAL.sql` | ✅ CANONIQUE | Versions FINALES de modifier_score_membre, lire_score_membre, reinitialiser_score_override | 007 |
| `supabase-admin-fix.sql` | ✅ CANONIQUE | v1.2 FINAL — corrige ORDER BY sur colonne SQL "prio" (erreur 42703) | 008 |
| `supabase-v17-fix-soft-delete.sql` | ✅ CANONIQUE | Soft-delete (status, deleted_at, deleted_by) + admin_lister_tontines v17-FINAL | 006 + 008 |
| `supabase-fix-v12-premium-requests.sql` | ✅ CANONIQUE | admin_lister_demandes FINAL (lit premium_requests, pas demandes_premium) | 006 + 008 |
| `supabase-subscriptions.sql` | ✅ CANONIQUE | Table subscriptions + 7 RPCs abonnements | 003 + 009 |
| `supabase-prets-pending.sql` | ✅ CANONIQUE | Table prets_pending + 3 RPCs prêts admin | 003 + 009 |
| `supabase-decaissements-pending.sql` | ✅ CANONIQUE | Table decaissements_pending + 3 RPCs décaissements | 003 + 009 |
| `supabase-depenses-pending.sql` | ✅ CANONIQUE | Table depenses_pending + 2 RPCs dépenses | 003 + 009 |
| `supabase-kyc.sql` | ✅ CANONIQUE | Table kyc_submissions + 3 RPCs KYC admin | 004 + 009 |
| `supabase-admin-team.sql` | ✅ CANONIQUE | 4 tables team/support + 15 RPCs messagerie/tickets | 005 + 009 |
| `supabase-sycapay-v2.sql` | ✅ CANONIQUE | Version v2 FINALE sycapay_transactions + crediter_caisse/cotisation_sycapay | 003 + 010 |
| `supabase-penalite-sycapay.sql` | ✅ CANONIQUE | crediter_penalite_sycapay | 010 |
| `supabase/migrations/001_fcm_tokens.sql` | ✅ CANONIQUE | Table fcm_tokens + sauvegarder_token | 004 + 010 |
| `supabase-fix-v8-periodicitee.sql` | ✅ CANONIQUE | recalculer_echeances_expir (périodicités : journalier/hebdo/mensuel/…) | 010 |
| `supabase-fix-v11-beneficiaire.sql` | ✅ CANONIQUE | distribuer_tour v11 (anti-doublon bénéficiaire) | 010 |
| **`supabase-admin.sql`** | 🗑️ ARCHIVER | Supersédé intégralement par `supabase-admin-fix.sql` (v1.2) | — |
| **`supabase-fix-v7.sql`** | 🗑️ ARCHIVER | admin_lister_demandes v7 lit demandes_premium (table obsolète) ; supersédé par v12 | — |
| **`supabase-sycapay-transactions.sql`** | 🗑️ ARCHIVER | v1 de sycapay_transactions sans colonnes sycapay_reference, user_id, membre_nom ; supersédé par v2 | — |
| **`supabase-fix-v9-nouveau-cycle.sql`** | 🗑️ ARCHIVER | proposer_nouveau_cycle v9 supersédé par v15 | — |
| **`supabase-fix-v10-cycle-logique.sql`** | 🗑️ ARCHIVER | Logique de cycle v10 supersédée par v15 | — |
| **`supabase-EXECUTER-v14-score.sql`** | 🗑️ ARCHIVER | Contenu identique à `supabase-v14-FINAL.sql` (doublon exact) | — |
| **`supabase-fix-v13-score-sync.sql`** | 🗑️ ARCHIVER | Versions intermédiaires de modifier_score_membre supersédées par v14-FINAL | — |
| `supabase-fix-v15-cycle.sql` | ⚠️ PARTIEL | proposer_nouveau_cycle v15 → migré dans 006 ; autres fonctions déjà couvertes | 006 |
| `supabase-fix-v16-soft-delete.sql` | ⚠️ PARTIEL | lire_tontine v16 (soft-delete) → migré dans 006 ; supersédé sur admin_lister_tontines par v17 | 006 |
| `supabase-fix-v18-votes.sql` | ⚠️ PARTIEL | voter v18 (logique votes corrigée) → migré dans 006 | 006 |
| `supabase-fix-v1-initial.sql` | ⚠️ PARTIEL | Script initial — tables core et RPCs de base ; toutes les fonctions remplacées par versions ultérieures | 001 |

---

### Résumé archivage

#### 🗑️ Fichiers **sans risque à supprimer** (7 fichiers)

Ces fichiers sont soit des doublons exacts, soit intégralement supersédés :

```
supabase-admin.sql                ← remplacé par supabase-admin-fix.sql (v1.2)
supabase-fix-v7.sql               ← admin v7 remplacé par v12 (mauvaise table cible)
supabase-sycapay-transactions.sql ← v1 remplacée par supabase-sycapay-v2.sql
supabase-fix-v9-nouveau-cycle.sql ← remplacé par v15
supabase-fix-v10-cycle-logique.sql← remplacé par v15
supabase-EXECUTER-v14-score.sql   ← doublon exact de supabase-v14-FINAL.sql
supabase-fix-v13-score-sync.sql   ← versions intermédiaires score, remplacées par v14-FINAL
```

#### ⚠️ Fichiers **partiellement archivables** (4 fichiers)

Contenu intégré dans les migrations, mais conserver comme référence historique si souhaité :

```
supabase-fix-v15-cycle.sql        → contenu dans 006
supabase-fix-v16-soft-delete.sql  → contenu dans 006
supabase-fix-v18-votes.sql        → contenu dans 006
supabase-fix-v1-initial.sql       → tables de base dans 001
```

---

## Chaîne de supersession des fonctions dupliquées

### admin_lister_demandes

```
v1 (supabase-admin.sql)           lit demandes_premium  🗑️
  → v7 (supabase-fix-v7.sql)      lit demandes_premium  🗑️
    → v12 (supabase-fix-v12-premium-requests.sql)
         lit premium_requests      ✅ FINAL → migration 008
```

### admin_activer_premium / admin_refuser_demande

```
v1/v7 → met à jour demandes_premium.statut   🗑️
  → v12 → met à jour premium_requests.status  ✅ FINAL → migration 008
```

### admin_lister_tontines

```
v1 (sans soft-delete)  🗑️
  → v16 (supabase-fix-v16-soft-delete.sql)   ⚠️ intermédiaire
    → v17 (supabase-v17-fix-soft-delete.sql)
         status, deleted_at, deleted_by, suspension  ✅ FINAL → migration 008
```

### admin_alertes

```
v1.0 (supabase-admin.sql) → ORDER BY sur clé JSONB → erreur 42703  🗑️
  → v1.2 FIX (supabase-admin-fix.sql) → ORDER BY sur colonne SQL "prio"  ✅ FINAL → migration 008
```

### modifier_score_membre / lire_score_membre

```
v1 (supabase-v6.sql)              simple lecture/écriture  ⚠️
  → v13 (supabase-fix-v13.sql)    sync score JSONB         🗑️
    → v14-FINAL (supabase-v14-FINAL.sql)
         scoreOverride + dual auth check                     ✅ FINAL → migration 007
```

### proposer_nouveau_cycle / demarrer_nouveau_cycle

```
v9 → v10 → v15  ✅ FINAL → migration 006
```

### voter

```
v1 → … → v18  ✅ FINAL → migration 006
```

### sycapay_transactions

```
v1 (supabase-sycapay-transactions.sql) → sans colonnes étendues  🗑️
  → v2 (supabase-sycapay-v2.sql)
       + sycapay_reference, user_id, membre_nom, pret_id, emprunteur_id  ✅ FINAL → migration 003 + 010
```

---

## Architecture technique

### Principes de conception

- **Idempotence** : toutes les migrations utilisent `CREATE OR REPLACE FUNCTION`,
  `CREATE TABLE IF NOT EXISTS`, `CREATE INDEX IF NOT EXISTS`,
  `DROP POLICY IF EXISTS` / `CREATE POLICY` — réexécutables sans erreur.

- **SECURITY DEFINER** : toutes les fonctions RPC utilisent
  `SECURITY DEFINER SET search_path = public` pour bypasser les RLS côté Flutter
  (connexion via anon key).

- **Vérification duale admin** : `_verif_admin_cle()` lit `config.admin_cle`,
  puis fallback sur `admin_config.cle`, puis hash SHA-256.

- **JSON embarqué** : les données membres, paiements, historique, caisse et
  journal sont stockées en JSONB dans `tontines.data` — modèle document.

- **Soft-delete tontines** : colonnes `status`, `deleted_at`, `deleted_by`,
  `deletion_reason`, `invitation_code_active` (v16+).

### Tables et leur rôle

| Table | Rôle |
|-------|------|
| `tontines` | Tontine + toutes ses données JSONB (membres, caisse, historique, votes, ordre) |
| `audit_log` | Traçabilité des opérations critiques |
| `demandes_premium` | Demandes upgrade (legacy — remplacé par `premium_requests`) |
| `premium_requests` | Demandes upgrade (courant) |
| `config` | Configuration globale (clé admin principale) |
| `app_config` | Configuration applicative (admin_key pour KYC) |
| `admin_config` | Clé admin secondaire (fallback `_verif_admin_cle`) |
| `scores_historique` | Historique des scores de fiabilité membres |
| `propositions_retrait` | Propositions de retrait en attente de validation |
| `journal_audit` | Journal d'audit des actions sensibles |
| `subscriptions` | Abonnements Premium tontines |
| `abonnements` | Table admin des abonnements |
| `admin_actions` | Log des actions administrateur |
| `sycapay_transactions` | Transactions Mobile Money SycaPay (idempotentes) |
| `prets_pending` | Prêts en attente de validation admin |
| `decaissements_pending` | Décaissements en attente de validation admin |
| `depenses_pending` | Dépenses en attente de validation admin |
| `kyc_submissions` | Soumissions KYC (vérification identité) |
| `fcm_tokens` | Tokens FCM pour notifications push |
| `rappels_envoyes` | Suivi des rappels envoyés |
| `admin_membres` | Membres de l'équipe admin (app admin_app) |
| `admin_messages` | Messages internes équipe admin |
| `support_tickets` | Tickets support client |
| `support_messages` | Messages des tickets support |

---

## Deux applications Flutter

| App | Package | Branche git | Backend |
|-----|---------|-------------|---------|
| `flutter_app` | `com.tontineclair.app` | `main` | Supabase partagé |
| `admin_app` | `com.tontineclair.admin` | `admin-app` | Supabase partagé |

Les deux apps utilisent le **même projet Supabase** et les mêmes tables/fonctions.
L'app admin accède aux RPCs `admin_*` protégées par `_verif_admin_cle()`.

---

## Versions verrouillées

| Fonction | Version finale | Source |
|----------|---------------|--------|
| `voter` | v18 | `supabase-fix-v18-votes.sql` |
| `cloturer_tour` | v11 | `supabase-fix-v11-beneficiaire.sql` |
| `lire_tontine` | v16 | `supabase-fix-v16-soft-delete.sql` |
| `proposer_nouveau_cycle` | v15 | `supabase-fix-v15-cycle.sql` |
| `demarrer_nouveau_cycle` | v15 | `supabase-fix-v15-cycle.sql` |
| `check_invitation_code` | v17 | `supabase-v17-fix-soft-delete.sql` |
| `admin_lister_tontines` | v17 FINAL | `supabase-v17-fix-soft-delete.sql` |
| `admin_tontine_counts` | v17 | `supabase-v17-fix-soft-delete.sql` |
| `admin_alertes` | v1.2 FIX | `supabase-admin-fix.sql` |
| `admin_lister_demandes` | v12 FINAL | `supabase-fix-v12-premium-requests.sql` |
| `modifier_score_membre` | v14-FINAL | `supabase-v14-FINAL.sql` |
| `demander_premium` | v12 | `supabase-fix-v12-premium-requests.sql` |
| `distribuer_tour` | v11 | `supabase-fix-v11-beneficiaire.sql` |
