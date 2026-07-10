# TontineClair

Application Flutter de gestion de tontines — mobile Android et Web.

## Architecture de déploiement

```
Code Flutter (local / sandbox)
        │
        ▼
   GitHub (source)
        │
        ▼ (déploiement automatique à chaque push)
   Netlify (hébergement web)
     flutter build web --release
     --dart-define=SUPABASE_URL=...
     --dart-define=SUPABASE_ANON_KEY=...
        │
        ▼
   Supabase (base de données, RPC, authentification)
   POST /rest/v1/rpc/<fonction>
```

## Stack technique

| Composant       | Technologie                     |
|-----------------|---------------------------------|
| Application     | Flutter 3.35.4 / Dart 3.9.2     |
| Web (prod)      | Netlify (auto-deploy)           |
| Android         | APK signé (release-key.jks)     |
| Base de données | Supabase (PostgreSQL + PostgREST)|
| Authentification| Supabase RPC + PIN gestionnaire |
| Stockage        | Supabase Storage                |

## Prérequis développement

- Flutter 3.35.4 (version verrouillée)
- Dart 3.9.2
- Compte Supabase avec les scripts SQL v1→v5 exécutés
- Compte GitHub
- Compte Netlify (pour l'hébergement web)

## Installation locale

```bash
# Cloner le dépôt
git clone https://github.com/<votre-org>/tontineclair.git
cd tontineclair

# Installer les dépendances
flutter pub get

# Build web local (sans variables d'env = utilise les valeurs par défaut)
flutter build web --release

# Build web avec vos propres credentials Supabase
flutter build web --release \
  --dart-define=SUPABASE_URL=https://votre-projet.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=votre_cle_anon
```

## Variables d'environnement

Copier `.env.example` en `.env` et renseigner les valeurs :

```bash
cp .env.example .env
```

| Variable           | Description                                   | Où trouver              |
|--------------------|-----------------------------------------------|-------------------------|
| `SUPABASE_URL`     | URL du projet Supabase                        | Supabase → Settings → API |
| `SUPABASE_ANON_KEY`| Clé publique anon (safe côté client)         | Supabase → Settings → API |

> ⚠️ **NE JAMAIS** utiliser la clé `service_role` côté Flutter Web.

## Déploiement Netlify

### 1. Connecter le dépôt GitHub

1. Aller sur [Netlify](https://netlify.com) → **Add new site** → **Import an existing project**
2. Sélectionner le dépôt GitHub `tontineclair`
3. Branche de production : `main`

### 2. Configurer les variables d'environnement dans Netlify

**Site settings → Environment variables → Add variable** :

| Clé                 | Valeur                              |
|---------------------|-------------------------------------|
| `SUPABASE_URL`      | `https://ubrqtcxbxcmvmxleiglh.supabase.co` |
| `SUPABASE_ANON_KEY` | `eyJhbGci...` (clé anon complète)  |

### 3. Commande de build (netlify.toml)

La commande de build est définie dans `netlify.toml` :

```toml
[build]
  command = "flutter pub get && flutter build web --release --dart-define=SUPABASE_URL=$SUPABASE_URL --dart-define=SUPABASE_ANON_KEY=$SUPABASE_ANON_KEY"
  publish = "build/web"

[[redirects]]
  from   = "/*"
  to     = "/index.html"
  status = 200
```

> **Note** : Netlify ne dispose pas de Flutter installé par défaut.
> Deux options :
> - Utiliser un **build Docker** avec Flutter pré-installé
> - Ou builder localement et uploader `build/web` manuellement
>
> Voir la section [Build manuel pour Netlify](#build-manuel-pour-netlify) ci-dessous.

### 4. Build manuel pour Netlify (méthode recommandée)

Si Netlify ne peut pas installer Flutter automatiquement :

```bash
# 1. Builder localement avec les vrais credentials
flutter build web --release \
  --dart-define=SUPABASE_URL=https://ubrqtcxbxcmvmxleiglh.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=eyJhbGci...

# 2. Uploader le dossier build/web sur Netlify
# Netlify UI → Deploys → Drag and drop build/web folder
# OU via CLI :
netlify deploy --prod --dir=build/web
```

## Déploiement Android

### APK de release

```bash
# Prérequis : android/key.properties + android/release-key.jks configurés
flutter build apk --release

# APK généré dans :
# build/app/outputs/flutter-apk/app-release.apk
```

### Variables de signature (android/key.properties)

```properties
storePassword=<mot_de_passe_keystore>
keyPassword=<mot_de_passe_cle>
keyAlias=release
storeFile=../release-key.jks
```

> ⚠️ `key.properties` et `release-key.jks` sont exclus de Git (voir `.gitignore`).

## Déploiement iOS

> ⚠️ **Non disponible dans ce sandbox** (Linux uniquement).
> 
> Pour construire l'IPA iOS, il faut :
> - Un Mac avec Xcode installé
> - Un compte Apple Developer (99 $/an)
> - Certificats de signature iOS
>
> Le code Flutter est cross-platform et peut être compilé pour iOS localement sur Mac :
> ```bash
> flutter build ios --release
> ```

## Sécurité Supabase (RLS)

Les politiques Row Level Security doivent être configurées directement dans la console Supabase.

### Politiques RLS recommandées

À configurer dans **Supabase Console → Authentication → Policies** :

```sql
-- Exemple : les tontines ne sont accessibles qu'avec le bon code
CREATE POLICY "tontines_acces_par_code"
  ON tontines FOR SELECT
  USING (true); -- La sécurité est gérée par les fonctions RPC côté Supabase

-- Toutes les opérations sensibles passent par des fonctions RPC
-- qui vérifient les PIN gestionnaires avant d'autoriser les modifications.
```

> **Architecture de sécurité actuelle** :
> L'app utilise des fonctions RPC Supabase (`POST /rest/v1/rpc/<fn>`) qui vérifient
> les autorisations côté serveur avant tout accès aux données. La clé anon seule
> ne permet pas d'accéder aux données sans passer par ces fonctions.

## Structure du projet

```
tontineclair/
├── lib/
│   ├── main.dart                  # Point d'entrée
│   ├── models/
│   │   └── tontine.dart           # Modèles de données
│   ├── screens/
│   │   ├── accueil_screen.dart    # Écran d'accueil
│   │   ├── dashboard_screen.dart  # Tableau de bord
│   │   ├── caisse_screen.dart     # Gestion caisse
│   │   ├── votes_screen.dart      # Système de votes
│   │   ├── prets_screen.dart      # Gestion des prêts
│   │   ├── cotisations_screen.dart# Cotisations
│   │   └── config_screen.dart     # Config (mode dev)
│   ├── services/
│   │   ├── supabase_service.dart  # Client HTTP Supabase RPC
│   │   ├── storage_service.dart   # Stockage local
│   │   ├── pdf_service.dart       # Génération PDF
│   │   └── tontine_provider.dart  # State management
│   ├── utils/
│   │   └── formatters.dart        # Formatage dates/montants
│   └── widgets/                   # Widgets réutilisables
├── android/
│   ├── app/
│   │   ├── build.gradle.kts       # Config Gradle
│   │   └── src/main/
│   │       ├── AndroidManifest.xml
│   │       └── res/xml/
│   │           └── network_security_config.xml
│   ├── key.properties             # ⚠️ Exclu de Git
│   └── release-key.jks            # ⚠️ Exclu de Git
├── web/
│   └── index.html                 # Point d'entrée web
├── assets/                        # Images, icônes
├── pubspec.yaml                   # Dépendances Flutter
├── pubspec.lock                   # Versions verrouillées
├── netlify.toml                   # Config déploiement Netlify
├── .env.example                   # Modèle variables d'env
└── .gitignore                     # Fichiers exclus de Git
```

## Workflow de développement

```bash
# 1. Modifier le code
# 2. Vérifier la qualité
flutter analyze

# 3. Builder web pour test
flutter build web --release

# 4. Committer et pousser
git add .
git commit -m "Description des modifications"
git push origin main

# → Netlify détecte le push et redéploie automatiquement
```

## Fonctionnalités principales

- **Gestion de tontines** : création, code d'accès unique, gestion des membres
- **Caisse** : cotisations, dépenses, pénalités, suivi du solde
- **Votes** : vote par tour selon l'ordre des membres (`ordre[]`)
- **Prêts** : gestion des emprunts et remboursements
- **PDF** : export des rapports financiers
- **Premium** : plan d'abonnement avec fonctionnalités avancées
- **Multi-plateforme** : Web (Netlify) + Android (APK)

## Support et contact

Pour toute question sur le déploiement ou la configuration Supabase,
consulter la documentation officielle :
- [Flutter Web deployment](https://docs.flutter.dev/deployment/web)
- [Netlify docs](https://docs.netlify.com/)
- [Supabase docs](https://supabase.com/docs)
