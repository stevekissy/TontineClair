# TontineClair — Guide d'intégration KYC Smile ID

## 1. Variables d'environnement à configurer

### Dans Supabase Dashboard → Settings → Edge Functions → Secrets

| Variable                    | Description                              | Exemple                    |
|-----------------------------|------------------------------------------|----------------------------|
| `SMILE_ID_PARTNER_ID`       | Votre Partner ID Smile ID                | `1234`                     |
| `SMILE_ID_API_KEY`          | Votre clé API (RSA Private Key, format PEM) | `-----BEGIN RSA...`     |
| `SMILE_ID_SID_SERVER`       | `0` = sandbox, `1` = production          | `0`                        |
| `SMILE_ID_ENVIRONMENT`      | `sandbox` ou `production`                | `sandbox`                  |
| `SMILE_ID_WEBHOOK_SECRET`   | Secret pour valider les webhooks Smile ID | (obtenu dans le portail) |
| `SUPABASE_SERVICE_ROLE_KEY` | Clé service_role Supabase (auto-injectée)| (automatique)              |

**⚠️ Ces clés ne doivent JAMAIS être dans le code Flutter.**
Elles vivent exclusivement dans les secrets des Edge Functions Supabase.

---

## 2. Étapes d'activation Smile ID

### Quand vous recevez vos identifiants Smile ID :

1. **Dans Supabase Dashboard** :
   - Aller dans Settings → Edge Functions → Secrets
   - Ajouter `SMILE_ID_PARTNER_ID` avec votre Partner ID
   - Ajouter `SMILE_ID_API_KEY` avec votre clé RSA privée
   - Définir `SMILE_ID_SID_SERVER=0` (sandbox d'abord)
   - Définir `SMILE_ID_ENVIRONMENT=sandbox`

2. **Dans l'app Flutter** (`lib/services/kyc_service.dart`) :
   ```dart
   // Ligne à modifier :
   static bool useMock = false;  // ← Changer true → false
   ```

3. **Déployer les Edge Functions** :
   ```bash
   supabase functions deploy kyc-session
   supabase functions deploy kyc-webhook
   ```

4. **Configurer le webhook Smile ID** :
   - Dans le portail Smile ID → Webhooks
   - URL : `https://<project-ref>.supabase.co/functions/v1/kyc-webhook`
   - Event : `JOB_COMPLETE`
   - Copier le webhook secret → l'ajouter dans `SMILE_ID_WEBHOOK_SECRET`

5. **Tester en sandbox** :
   - Utiliser les documents de test fournis par Smile ID
   - Vérifier que le webhook met bien à jour le statut

6. **Passer en production** :
   - Changer `SMILE_ID_SID_SERVER=1`
   - Changer `SMILE_ID_ENVIRONMENT=production`
   - Tester avec un vrai document

---

## 3. Exécuter les migrations SQL

Dans Supabase → SQL Editor, exécuter dans cet ordre :

```sql
-- Copier-coller le contenu de :
supabase/migrations/kyc_verifications.sql
```

---

## 4. Créer le bucket Storage pour les fichiers KYC

Dans Supabase → Storage → Create Bucket :
- Nom : `kyc-documents`
- Type : **Private** (⚠️ jamais public)
- Activer la politique RLS sur ce bucket

---

## 5. Architecture actuelle (mode simulation)

```
Flutter App
    │
    ▼
KycService.submit()
    │
    ▼
MockKycProvider  ──► Simule un résultat aléatoire
    │                (80% pending → verified après 10s)
    ▼
SupabaseService.kycUpsert()
    │
    ▼
Table: kyc_verifications  ──► Persistance en BDD
```

## 6. Architecture future (Smile ID actif)

```
Flutter App
    │
    ▼
KycService.submit()
    │
    ▼
SmileIdKycProvider
    │
    ▼ POST (images en base64)
Edge Function: kyc-session
    │
    ▼ API Call
Smile ID WebAPI 2.0
    │
    ▼ Webhook callback
Edge Function: kyc-webhook
    │
    ▼
Table: kyc_verifications  (status mis à jour)
Table: kyc_audit_log      (trace immuable)
```

---

## 7. Actions qui nécessitent le KYC

Configurées dans `KycService.canPerformFinancialAction()` :

| Action            | KYC requis ? | Seuil montant |
|-------------------|--------------|---------------|
| `withdrawal`      | Toujours     | —             |
| `disbursement`    | Toujours     | —             |
| `loan`            | Toujours     | —             |
| `premium_create`  | Toujours     | —             |
| `large_transfer`  | Si montant   | > 50 000 XOF  |

Pour modifier le seuil : `KycConfig.kycThreshold` dans `kyc_service.dart`.

---

## 8. Politique de rétention des fichiers

Les images des documents sont supprimées 30 jours après la vérification.

Configurer un Cron Job Supabase pour exécuter quotidiennement :
```sql
SELECT purge_expired_kyc_files();
```

Dans Supabase → Database → Extensions → Activer `pg_cron`
Puis dans SQL Editor :
```sql
SELECT cron.schedule(
  'purge-kyc-files',
  '0 2 * * *',  -- Tous les jours à 2h du matin UTC
  'SELECT purge_expired_kyc_files();'
);
```
