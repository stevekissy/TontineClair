#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# TontineClair — Script de nettoyage et setup iOS
# CocoaPods uniquement (SPM désactivé)
#
# Usage : depuis la racine du projet flutter_app/
#   chmod +x ios/setup_ios.sh
#   ./ios/setup_ios.sh
# ─────────────────────────────────────────────────────────────────────────────

set -e
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

step() { echo -e "\n${CYAN}▶ $1${NC}"; }
ok()   { echo -e "${GREEN}✅ $1${NC}"; }
warn() { echo -e "${YELLOW}⚠️  $1${NC}"; }
err()  { echo -e "${RED}❌ $1${NC}"; exit 1; }

# ── Vérifier qu'on est bien à la racine du projet ─────────────────────────────
[ -f "pubspec.yaml" ] || err "Exécuter ce script depuis la racine du projet flutter_app/ (là où se trouve pubspec.yaml)"

# ── Vérifications préalables ──────────────────────────────────────────────────
step "0/5 — Vérification de l'environnement"

command -v flutter    >/dev/null 2>&1 || err "Flutter non trouvé. Installer Flutter 3.35.4 : https://docs.flutter.dev/get-started/install/macos"
command -v pod        >/dev/null 2>&1 || err "CocoaPods non trouvé. Exécuter : sudo gem install cocoapods"
command -v xcodebuild >/dev/null 2>&1 || err "Xcode non trouvé. Installer depuis le Mac App Store"

echo "  Flutter    : $(flutter --version 2>/dev/null | head -1)"
echo "  CocoaPods  : $(pod --version 2>/dev/null)"
echo "  Xcode      : $(xcodebuild -version 2>/dev/null | head -1)"
ok "Environnement OK"

# ── Étape 1 : flutter pub get → génère Generated.xcconfig ────────────────────
# CRITIQUE : doit être fait AVANT pod install.
# Generated.xcconfig contient FLUTTER_ROOT= pointant vers le SDK Flutter
# de CETTE machine. Le Podfile le lit pour charger podhelper.rb.
step "1/5 — flutter pub get (génère ios/Flutter/Generated.xcconfig)"
flutter pub get
ok "Dépendances Flutter installées"

# ── Vérification que Generated.xcconfig est bien régénéré ────────────────────
GENERATED="ios/Flutter/Generated.xcconfig"
if ! grep -q "^FLUTTER_ROOT=" "$GENERATED" 2>/dev/null; then
  err "Generated.xcconfig ne contient pas FLUTTER_ROOT après flutter pub get.\nVérifier que Flutter est bien dans votre PATH."
fi

FLUTTER_ROOT_MAC=$(grep "^FLUTTER_ROOT=" "$GENERATED" | cut -d= -f2 | tr -d '[:space:]')
echo "  FLUTTER_ROOT détecté : $FLUTTER_ROOT_MAC"

# Vérifier que le SDK existe vraiment sur ce Mac
[ -d "$FLUTTER_ROOT_MAC" ] || err "FLUTTER_ROOT=$FLUTTER_ROOT_MAC introuvable sur ce Mac.\nVérifier votre installation Flutter."
[ -f "$FLUTTER_ROOT_MAC/packages/flutter_tools/bin/podhelper.rb" ] || \
  err "podhelper.rb introuvable dans $FLUTTER_ROOT_MAC/packages/flutter_tools/bin/\nFlutter SDK incomplet ou mauvaise version."

ok "Generated.xcconfig valide — FLUTTER_ROOT=$FLUTTER_ROOT_MAC"

# ── Étape 2 : Nettoyage complet iOS ──────────────────────────────────────────
step "2/5 — Nettoyage (Pods, .symlinks, Podfile.lock, DerivedData, cache SmileIDSDK)"

cd ios

rm -rf Pods
rm -rf .symlinks
rm -f  Podfile.lock

# ── Nettoyage du cache CocoaPods SmileIDSDK ───────────────────────────────────
# CRITIQUE : si SmileIDSDK 11.2.0 (bugguée) est en cache, pod install la réutilise
# même si pubspec.yaml demande smile_id: 11.2.12 (SmileIDSDK 11.2.1+).
# Le crash "Swift runtime failure: Unexpectedly found nil while unwrapping an
# Optional value" vient de SmileIDSDK 11.2.0 qui a un force-unwrap non-protégé
# lors de l'enregistrement du plugin (GeneratedPluginRegistrant.m, natif).
echo "  → Nettoyage cache CocoaPods SmileIDSDK (force la version 11.2.1+) ..."
pod cache clean SmileIDSDK --all 2>/dev/null || true
pod cache clean smile_id   --all 2>/dev/null || true
ok "Cache SmileIDSDK nettoyé"

# Forcer SPM désactivé dans le workspace (Xcode peut le réactiver)
mkdir -p Runner.xcworkspace/xcshareddata
cat > Runner.xcworkspace/xcshareddata/WorkspaceSettings.xcsettings << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>IDEPackageResolutionDisabled</key>
	<true/>
	<key>PreviewsEnabled</key>
	<false/>
</dict>
</plist>
PLIST

# Nettoyer DerivedData pour Runner uniquement
DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData"
if [ -d "$DERIVED_DATA" ]; then
  find "$DERIVED_DATA" -maxdepth 1 \( -name "Runner-*" -o -name "tontine-*" \) -exec rm -rf {} + 2>/dev/null || true
  ok "DerivedData nettoyé"
fi

# Supprimer FlutterGeneratedPluginSwiftPackage du pbxproj si présent
PBXPROJ="Runner.xcodeproj/project.pbxproj"
SPM_COUNT=$(grep -c "FlutterGeneratedPluginSwiftPackage\|XCRemoteSwiftPackageReference\|XCSwiftPackageProductDependency" "$PBXPROJ" 2>/dev/null || true)
if [ "${SPM_COUNT:-0}" -gt "0" ]; then
  warn "Références SPM trouvées ($SPM_COUNT) dans project.pbxproj — suppression..."
  cp "$PBXPROJ" "${PBXPROJ}.bak"
  sed -i '' '/FlutterGeneratedPluginSwiftPackage/d' "$PBXPROJ"
  sed -i '' '/XCRemoteSwiftPackageReference/d'      "$PBXPROJ"
  sed -i '' '/XCSwiftPackageProductDependency/d'    "$PBXPROJ"
  perl -i '' -0pe 's/packageReferences\s*=\s*\([^)]*\);//g' "$PBXPROJ"
  ok "Références SPM supprimées"
else
  ok "Aucune référence SPM dans project.pbxproj"
fi

ok "Nettoyage terminé"

# ── Étape 3 : pod repo update ─────────────────────────────────────────────────
step "3/5 — pod repo update (mise à jour des specs CocoaPods)"
pod repo update
ok "Specs CocoaPods à jour"

# ── Étape 4 : pod install ─────────────────────────────────────────────────────
step "4/5 — pod install"
pod install --repo-update
ok "Pods installés avec succès"

# ── Vérification version SmileIDSDK post-install ──────────────────────────────
echo ""
echo "  Vérification de la version SmileIDSDK installée ..."
SMILEID_VERSION=$(grep -A2 "SmileIDSDK" Podfile.lock 2>/dev/null | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+' | head -1 || true)
if [ -z "$SMILEID_VERSION" ]; then
  warn "SmileIDSDK non trouvé dans Podfile.lock — vérifier pod install"
else
  echo "  SmileIDSDK installé : $SMILEID_VERSION"
  # Version minimale requise : 11.2.1 (corrige le crash force-unwrap nil)
  MAJOR=$(echo "$SMILEID_VERSION" | cut -d. -f1)
  MINOR=$(echo "$SMILEID_VERSION" | cut -d. -f2)
  PATCH=$(echo "$SMILEID_VERSION" | cut -d. -f3)
  if [ "$MAJOR" -gt 11 ] || \
     ([ "$MAJOR" -eq 11 ] && [ "$MINOR" -gt 2 ]) || \
     ([ "$MAJOR" -eq 11 ] && [ "$MINOR" -eq 2 ] && [ "$PATCH" -ge 1 ]); then
    ok "SmileIDSDK $SMILEID_VERSION ✅ (≥ 11.2.1 — crash force-unwrap corrigé)"
  else
    warn "SmileIDSDK $SMILEID_VERSION ⚠️ — VERSION TROP ANCIENNE !"
    warn "11.2.0 a un bug Swift force-unwrap nil qui crashe au démarrage iOS."
    warn "Nettoyer le cache CocoaPods et relancer ce script :"
    warn "  pod cache clean SmileIDSDK --all"
    warn "  pod cache clean smile_id --all"
    warn "  ./ios/setup_ios.sh"
  fi
fi

cd ..

# ── Étape 5 : Vérification finale ─────────────────────────────────────────────
step "5/5 — Vérification finale"

[ -d "ios/Pods" ]               || err "Dossier Pods absent — pod install a échoué"
[ -f "ios/Pods/Podfile.lock" ] 2>/dev/null || true
[ -d "ios/Runner.xcworkspace" ] || err "Runner.xcworkspace absent"

echo ""
echo "  Bundle ID    : com.tontineclair.app"
echo "  iOS target   : 15.0"
echo "  Flutter root : $FLUTTER_ROOT_MAC"
echo "  SPM          : désactivé (IDEPackageResolutionDisabled = true)"
echo ""
ok "Tout est prêt !"

echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Ouvrir le projet dans Xcode :${NC}"
echo -e "${GREEN}  open ios/Runner.xcworkspace${NC}"
echo ""
echo -e "${YELLOW}  ⚠️  Toujours ouvrir Runner.xcworkspace${NC}"
echo -e "${YELLOW}     JAMAIS Runner.xcodeproj${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
echo ""
echo "  Dans Xcode :"
echo "  1. Signing & Capabilities → sélectionner votre Team"
echo "  2. Bundle ID = com.tontineclair.app  ✅"
echo "  3. GoogleService-Info.plist déjà présent dans Runner/ ✅"
echo "  4. Product → Clean Build Folder (⇧⌘K) — IMPORTANT après nettoyage Pods"
echo "  5. Product → Run (appareil) ou Archive (distribution)"
echo ""
echo -e "${YELLOW}  ⚠️  IMPORTANT — SmileID désactivé temporairement${NC}"
echo    "     SmileID.initialize() est commenté dans lib/main.dart"
echo    "     (crash Swift force-unwrap nil diagnostiqué)."
echo    "     Réactiver après confirmation que SmileIDSDK ≥ 11.2.1 est bien installé."
echo ""

read -p "  Ouvrir Xcode maintenant ? [o/N] " OPEN_XCODE
if [[ "$OPEN_XCODE" =~ ^[oOyY]$ ]]; then
  open ios/Runner.xcworkspace
fi
