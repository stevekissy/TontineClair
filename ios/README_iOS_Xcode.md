# TontineClair — Guide Build iOS avec Xcode

## Infos projet
| Clé | Valeur |
|-----|--------|
| **App Name** | TontineClair |
| **Bundle ID** | com.tontineclair.app |
| **Version** | 1.2.47 (build 51) |
| **iOS min** | 14.0 |
| **Flutter** | 3.35.4 |

---

## Prérequis sur votre Mac

| Outil | Version min | Vérification |
|-------|-------------|--------------|
| macOS | 13 Ventura+ | `sw_vers` |
| Xcode | 15.0+ | `xcodebuild -version` |
| Flutter SDK | 3.35.4 | `flutter --version` |
| CocoaPods | 1.15+ | `pod --version` |
| Apple Dev Account | Payant ($99/an) | developer.apple.com |

### Installer Flutter (si pas encore fait)
```bash
# Option 1 : via FVM (recommandé)
dart pub global activate fvm
fvm install 3.35.4
fvm use 3.35.4

# Option 2 : téléchargement direct
# https://storage.googleapis.com/flutter_infra_release/releases/stable/macos/flutter_macos_3.35.4-stable.zip
```

### Installer CocoaPods
```bash
sudo gem install cocoapods
# OU via Homebrew :
brew install cocoapods
```

---

## Étape 1 — Extraire et préparer le projet

```bash
# Extraire l'archive
tar -xzf TontineClair_iOS_source.tar.gz
cd flutter_app

# Installer les dépendances Flutter
flutter pub get

# Vérifier que flutter est bien configuré
flutter doctor
```

---

## Étape 2 — Firebase iOS (OBLIGATOIRE)

### 2a. Créer l'app iOS dans Firebase Console
1. Aller sur https://console.firebase.google.com/
2. Sélectionner le projet **tontineclair**
3. Cliquer **Ajouter une application** → icône iOS
4. Bundle ID : **com.tontineclair.app**
5. Télécharger **GoogleService-Info.plist**

### 2b. Placer le fichier dans le projet
```bash
# Copier le fichier téléchargé dans le bon répertoire
cp ~/Downloads/GoogleService-Info.plist ios/Runner/GoogleService-Info.plist
```

### 2c. L'ajouter dans Xcode
1. Ouvrir `ios/Runner.xcworkspace` dans Xcode
2. Dans le navigateur gauche : clic-droit sur **Runner** → **Add Files to "Runner"**
3. Sélectionner `GoogleService-Info.plist`
4. ✅ Cocher **"Copy items if needed"** et **"Add to target: Runner"**

### 2d. Mettre à jour le REVERSED_CLIENT_ID dans Info.plist
1. Ouvrir `GoogleService-Info.plist`
2. Copier la valeur de `REVERSED_CLIENT_ID` (ressemble à `com.googleusercontent.apps.XXXXX`)
3. Ouvrir `ios/Runner/Info.plist`
4. Remplacer `com.tontineclair.app` dans `CFBundleURLSchemes` par votre `REVERSED_CLIENT_ID`

---

## Étape 3 — Installer les pods CocoaPods

```bash
cd ios
pod install --repo-update
cd ..
```

> ⚠️ Toujours utiliser `Runner.xcworkspace` (pas `Runner.xcodeproj`) après `pod install`

---

## Étape 4 — Configurer la signature dans Xcode

1. Ouvrir **`ios/Runner.xcworkspace`** dans Xcode
2. Cliquer sur **Runner** (en haut dans le navigateur)
3. Onglet **Signing & Capabilities**
4. **Team** : sélectionner votre Apple Developer Account
5. **Bundle Identifier** : vérifier qu'il affiche `com.tontineclair.app`
6. Laisser **"Automatically manage signing"** coché

---

## Étape 5 — Capabilities nécessaires

Dans Xcode → Runner → **Signing & Capabilities**, ajouter :

| Capability | Pourquoi |
|------------|----------|
| **Push Notifications** | Firebase Cloud Messaging |
| **Background Modes** | `Remote notifications` + `Background fetch` |
| **In-App Purchase** | Abonnements Premium |

> Cliquer **"+ Capability"** pour chaque capability à ajouter

---

## Étape 6 — Smile ID (KYC biométrique)

Le SDK Smile ID (`smile_id: 11.2.11`) nécessite :

### Dans Xcode → Build Settings :
- `ENABLE_BITCODE` = **NO**

### Privacy Manifest (iOS 17+) :
Si Xcode signale des **"Required Reasons API"**, créer `ios/Runner/PrivacyInfo.xcprivacy` :
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "...">
<plist version="1.0">
<dict>
    <key>NSPrivacyTracking</key><false/>
    <key>NSPrivacyTrackingDomains</key><array/>
    <key>NSPrivacyCollectedDataTypes</key><array/>
    <key>NSPrivacyAccessedAPITypes</key>
    <array>
        <dict>
            <key>NSPrivacyAccessedAPIType</key>
            <string>NSPrivacyAccessedAPICategoryFileTimestamp</string>
            <key>NSPrivacyAccessedAPITypeReasons</key>
            <array><string>C617.1</string></array>
        </dict>
    </array>
</dict>
</plist>
```

---

## Étape 7 — Build depuis terminal (optionnel)

```bash
# Build iOS en mode release (sans signer — pour vérification)
flutter build ios --release --no-codesign

# Build avec signature (nécessite Xcode configuré)
flutter build ios --release
```

---

## Étape 8 — Archiver et exporter l'IPA dans Xcode

1. Dans Xcode : **Product** → **Archive**
2. Attendre la fin de l'archivage (5-15 min)
3. Dans **Organizer** → sélectionner l'archive
4. Cliquer **"Distribute App"**
5. Choisir : **App Store Connect** (publication) ou **Ad Hoc** (test interne)
6. Suivre l'assistant de signature
7. L'IPA sera exporté dans le dossier choisi

### Via terminal avec ExportOptions.plist :
```bash
# 1. Archiver
xcodebuild -workspace ios/Runner.xcworkspace \
           -scheme Runner \
           -configuration Release \
           -destination 'generic/platform=iOS' \
           -archivePath build/Runner.xcarchive \
           archive

# 2. Exporter l'IPA
# (éditer d'abord ios/ExportOptions.plist avec votre Team ID)
xcodebuild -exportArchive \
           -archivePath build/Runner.xcarchive \
           -exportPath build/ios_ipa \
           -exportOptionsPlist ios/ExportOptions.plist
```

---

## Dépannage fréquent

| Erreur | Solution |
|--------|----------|
| `pod install` échoue | `sudo gem update cocoapods` puis `pod repo update` |
| `"Provisioning profile doesn't include..."` | Vérifier Bundle ID = `com.tontineclair.app` dans Apple Dev Portal |
| Smile ID crash au lancement | Ajouter `NSCameraUsageDescription` dans Info.plist ✅ déjà fait |
| `"No such module 'Firebase'"` | Ouvrir `.xcworkspace` et non `.xcodeproj` |
| Build M1/M2 simulator fail | Dans Podfile `EXCLUDED_ARCHS[sdk=iphonesimulator*] = arm64` ✅ déjà fait |
| `ITMS-90683` Privacy manifest | Ajouter `PrivacyInfo.xcprivacy` (voir Étape 6) |
| Firebase pas initialisé | Vérifier que `GoogleService-Info.plist` est dans le target Runner |

---

## Structure du projet iOS

```
ios/
├── Runner/
│   ├── Info.plist              ✅ Configuré (TontineClair, permissions)
│   ├── AppDelegate.swift       ← Firebase + notifications
│   ├── GoogleService-Info.plist  ⚠️  À ajouter depuis Firebase Console
│   └── Assets.xcassets/        ← Icônes app
├── Runner.xcodeproj/
│   └── project.pbxproj         ✅ Bundle ID corrigé
├── Runner.xcworkspace/         ← Toujours ouvrir CE fichier
├── Podfile                     ✅ Créé (iOS 14.0, tous pods)
└── ExportOptions.plist         ✅ Créé (à remplir avec Team ID)
```

---

## Contact support

Si vous avez des problèmes de build, vérifiez :
1. `flutter doctor` → tous les items ✅
2. `pod install` s'est exécuté sans erreur
3. Vous ouvrez bien `Runner.xcworkspace` et non `Runner.xcodeproj`
