#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# TontineClair — Script de nettoyage et setup iOS
# À exécuter depuis la racine du projet flutter_app/ sur votre Mac
#
# Usage :
#   cd /chemin/vers/flutter_app
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

# ── Vérifications préalables ──────────────────────────────────────────────────
step "Vérification de l'environnement"

command -v flutter >/dev/null 2>&1 || err "Flutter non trouvé. Installer Flutter 3.35.4"
command -v pod     >/dev/null 2>&1 || err "CocoaPods non trouvé. Installer : sudo gem install cocoapods"
command -v xcodebuild >/dev/null 2>&1 || err "Xcode non trouvé. Installer Xcode depuis le Mac App Store"

FLUTTER_VER=$(flutter --version 2>/dev/null | head -1 | grep -o '3\.[0-9]*\.[0-9]*' || echo "inconnu")
echo "  Flutter    : $FLUTTER_VER"
echo "  CocoaPods  : $(pod --version)"
echo "  Xcode      : $(xcodebuild -version 2>/dev/null | head -1)"
ok "Environnement OK"

# ── Étape 1 : flutter pub get ────────────────────────────────────────────────
step "1/6 — flutter pub get"
flutter pub get
ok "Dépendances Flutter installées"

# ── Étape 2 : Nettoyage complet iOS ──────────────────────────────────────────
step "2/6 — Nettoyage Pods, .symlinks, Podfile.lock, DerivedData"

cd ios

# Pods et fichiers CocoaPods
rm -rf Pods
rm -rf .symlinks
rm -f  Podfile.lock

# Désactiver SPM dans le workspace (au cas où Xcode l'aurait réactivé)
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

# Nettoyer DerivedData Xcode (peut prendre de la place)
DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData"
if [ -d "$DERIVED_DATA" ]; then
  # Supprimer uniquement les entrées TontineClair/Runner
  find "$DERIVED_DATA" -maxdepth 1 -name "Runner-*" -exec rm -rf {} + 2>/dev/null || true
  find "$DERIVED_DATA" -maxdepth 1 -name "tontine-*" -exec rm -rf {} + 2>/dev/null || true
  ok "DerivedData nettoyé"
else
  warn "DerivedData non trouvé (premier build ?)"
fi

# Nettoyer le cache CocoaPods local (optionnel mais recommandé)
warn "Nettoyage cache Pod local (peut être long)..."
pod cache clean --all 2>/dev/null || true

ok "Nettoyage terminé"

# ── Étape 3 : Supprimer FlutterGeneratedPluginSwiftPackage du pbxproj ────────
step "3/6 — Vérification références SPM dans project.pbxproj"

PBXPROJ="Runner.xcodeproj/project.pbxproj"
SPM_COUNT=$(grep -c "FlutterGeneratedPluginSwiftPackage\|XCRemoteSwiftPackageReference\|XCSwiftPackageProductDependency\|packageReferences" "$PBXPROJ" 2>/dev/null || echo 0)

if [ "$SPM_COUNT" -gt "0" ]; then
  warn "Références SPM détectées ($SPM_COUNT lignes) — suppression en cours..."
  # Supprimer les lignes FlutterGeneratedPluginSwiftPackage
  sed -i.bak '/FlutterGeneratedPluginSwiftPackage/d' "$PBXPROJ"
  sed -i.bak '/XCRemoteSwiftPackageReference/d' "$PBXPROJ"
  sed -i.bak '/XCSwiftPackageProductDependency/d' "$PBXPROJ"
  # Supprimer les blocs packageReferences = ( ... );
  perl -i.bak -0pe 's/packageReferences\s*=\s*\([^)]*\);//g' "$PBXPROJ"
  rm -f Runner.xcodeproj/project.pbxproj.bak
  ok "Références SPM supprimées"
else
  ok "Aucune référence SPM trouvée dans project.pbxproj"
fi

# ── Étape 4 : pod repo update + pod install ───────────────────────────────────
step "4/6 — pod repo update (mise à jour des specs)"
pod repo update

step "5/6 — pod install"
pod install --repo-update
ok "Pods installés avec succès"

cd ..

# ── Étape 5 : Vérification finale ────────────────────────────────────────────
step "6/6 — Vérification finale"

echo ""
echo "  Bundle ID    : com.tontineclair.app"
echo "  iOS target   : 15.0 (min)"
echo "  SPM disabled : IDEPackageResolutionDisabled = true"
echo "  Workspace    : ios/Runner.xcworkspace"
echo ""

# Vérifier que le workspace existe
[ -d "ios/Runner.xcworkspace" ] || err "Runner.xcworkspace introuvable !"
[ -d "ios/Pods" ]               || err "Pods non installés !"

ok "Configuration iOS prête !"

# ── Message final ─────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Prochaine étape : ouvrir dans Xcode${NC}"
echo -e "${GREEN}  open ios/Runner.xcworkspace${NC}"
echo ""
echo -e "${YELLOW}  ⚠️  IMPORTANT : ouvrir Runner.xcworkspace${NC}"
echo -e "${YELLOW}     et NON Runner.xcodeproj${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
echo ""
echo "  Dans Xcode :"
echo "  1. Runner → Signing & Capabilities"
echo "  2. Sélectionner votre Team Apple Developer"
echo "  3. Bundle ID = com.tontineclair.app  ✅ déjà configuré"
echo "  4. Product → Archive → Distribute App"
echo ""

# Optionnel : ouvrir Xcode automatiquement
read -p "  Ouvrir Xcode maintenant ? [o/N] " OPEN_XCODE
if [[ "$OPEN_XCODE" =~ ^[oOyY]$ ]]; then
  open ios/Runner.xcworkspace
fi
