#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# TontineClair — Script de build Netlify (Flutter Web)
# Technologie : Flutter 3.35.4
#
# Variables à définir dans Netlify UI > Site settings > Environment variables :
#   SUPABASE_URL       https://mkmkpjdcydtpjwrmvbzd.supabase.co
#   SUPABASE_ANON_KEY  eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...  (clé anon uniquement)
#
# NE JAMAIS ajouter service_role ici — la clé anon est suffisante pour le client.
# ═══════════════════════════════════════════════════════════════════════════════

# Arrêt immédiat sur toute erreur non gérée
set -e

FLUTTER_VERSION="3.35.4"
FLUTTER_DIR="${HOME}/flutter"
FLUTTER_BIN="${FLUTTER_DIR}/bin/flutter"

# ── 1. Résolution des credentials ─────────────────────────────────────────────
# Priorité : variable Netlify > defaultValue codée dans supabase_service.dart
# Les defaultValue dans String.fromEnvironment() servent de fallback si les
# variables ne sont pas définies — l'app reste fonctionnelle dans les deux cas.

RESOLVED_URL="${SUPABASE_URL:-}"
RESOLVED_KEY="${SUPABASE_ANON_KEY:-}"

if [ -z "$RESOLVED_URL" ] || [ -z "$RESOLVED_KEY" ]; then
  echo "⚠️  SUPABASE_URL ou SUPABASE_ANON_KEY non définies en variable Netlify."
  echo "   → Le build utilisera les valeurs defaultValue du code source (supabase_service.dart)."
  echo "   → Pour injecter vos propres credentials, ajoutez les variables dans :"
  echo "      Netlify UI > Site settings > Environment variables"
  echo ""
  # On ne bloque PAS le build — String.fromEnvironment prend ses defaultValue
  BUILD_ARGS=""
else
  echo "✓ Credentials Supabase trouvés dans les variables Netlify"
  BUILD_ARGS="--dart-define=SUPABASE_URL=${RESOLVED_URL} --dart-define=SUPABASE_ANON_KEY=${RESOLVED_KEY}"
fi

# ── 2. Installation Flutter (si absent du cache) ───────────────────────────────
if [ -f "$FLUTTER_BIN" ]; then
  INSTALLED_VER=$("$FLUTTER_BIN" --version 2>/dev/null \
    | grep -oE 'Flutter [0-9]+\.[0-9]+\.[0-9]+' \
    | awk '{print $2}' \
    | head -1 || echo "unknown")
  echo "✓ Flutter ${INSTALLED_VER} trouvé dans le cache (${FLUTTER_DIR})"
else
  echo "⬇  Installation de Flutter ${FLUTTER_VERSION} (première fois, ~2 min)..."
  git clone https://github.com/flutter/flutter.git \
    --branch "${FLUTTER_VERSION}" \
    --depth 1 \
    "${FLUTTER_DIR}"
  echo "✓ Flutter ${FLUTTER_VERSION} cloné"
fi

# ── 3. PATH ───────────────────────────────────────────────────────────────────
export PATH="${FLUTTER_DIR}/bin:${HOME}/.pub-cache/bin:${PATH}"

# ── 4. Préconfiguration Flutter (désactive analytics, précharge web) ──────────
flutter config --no-analytics --no-cli-animations 2>/dev/null || true
flutter precache --web 2>/dev/null || true

echo "── Version Flutter active ──────────────────────────────────────────────"
flutter --version
echo "────────────────────────────────────────────────────────────────────────"

# ── 5. Dépendances ───────────────────────────────────────────────────────────
echo "📦  flutter pub get..."
flutter pub get

# ── 6. Build Flutter Web release ─────────────────────────────────────────────
echo "🔨  flutter build web --release ${BUILD_ARGS}..."
# shellcheck disable=SC2086
flutter build web --release \
  --no-tree-shake-icons \
  $BUILD_ARGS

# ── 7. Vérification du dossier de publication ────────────────────────────────
if [ ! -f "build/web/index.html" ]; then
  echo "❌  ERREUR : build/web/index.html introuvable — le build a échoué."
  exit 1
fi

echo "✅  Build terminé avec succès"
echo "── Contenu de build/web ─────────────────────────────────────────────────"
ls -lh build/web/
echo "────────────────────────────────────────────────────────────────────────"
