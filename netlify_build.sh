#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# TontineClair — Script de build Netlify (Flutter Web)
#
# Ce script est appelé par Netlify à chaque déploiement.
# Il installe Flutter 3.35.4, récupère les dépendances et génère build/web.
#
# Variables d'environnement à configurer dans Netlify UI > Site settings >
# Environment variables :
#   SUPABASE_URL       = https://xxxxx.supabase.co
#   SUPABASE_ANON_KEY  = eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...
# ═══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

FLUTTER_VERSION="3.35.4"
FLUTTER_DIR="$HOME/flutter"
FLUTTER_BIN="$FLUTTER_DIR/bin/flutter"

# ── 1. Vérifier si Flutter est déjà en cache (Netlify cache les répertoires) ──
if [ -f "$FLUTTER_BIN" ]; then
  INSTALLED_VERSION=$("$FLUTTER_BIN" --version 2>/dev/null | grep -oP 'Flutter \K[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "unknown")
  echo "✓ Flutter $INSTALLED_VERSION trouvé dans le cache"
else
  echo "⬇ Installation de Flutter $FLUTTER_VERSION..."
  git clone https://github.com/flutter/flutter.git \
    --branch "$FLUTTER_VERSION" \
    --depth 1 \
    "$FLUTTER_DIR"
  echo "✓ Flutter $FLUTTER_VERSION installé"
fi

# ── 2. Ajouter Flutter au PATH ─────────────────────────────────────────────────
export PATH="$FLUTTER_DIR/bin:$PATH"

# ── 3. Vérifier les variables d'environnement obligatoires ────────────────────
if [ -z "${SUPABASE_URL:-}" ]; then
  echo "❌ ERREUR : SUPABASE_URL non définie dans les variables Netlify"
  exit 1
fi
if [ -z "${SUPABASE_ANON_KEY:-}" ]; then
  echo "❌ ERREUR : SUPABASE_ANON_KEY non définie dans les variables Netlify"
  exit 1
fi

# ── 4. Préconfiguration Flutter Web (désactive analytics/telemetrie) ──────────
flutter config --no-analytics
flutter precache --web

# ── 5. Récupérer les dépendances ──────────────────────────────────────────────
echo "📦 flutter pub get..."
flutter pub get

# ── 6. Build Flutter Web release avec les credentials Supabase ────────────────
echo "🔨 flutter build web --release..."
flutter build web --release \
  --dart-define="SUPABASE_URL=${SUPABASE_URL}" \
  --dart-define="SUPABASE_ANON_KEY=${SUPABASE_ANON_KEY}"

# ── 7. Vérifier que build/web existe ─────────────────────────────────────────
if [ ! -f "build/web/index.html" ]; then
  echo "❌ ERREUR : build/web/index.html introuvable après le build"
  exit 1
fi

echo "✅ Build terminé — dossier build/web généré avec succès"
ls -lh build/web/
