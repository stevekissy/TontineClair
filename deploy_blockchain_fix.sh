#!/bin/bash
# ═══════════════════════════════════════════════════════════════════
# deploy_blockchain_fix.sh
# Déploie la Edge Function blockchain-tx v7 sur Supabase
# Fix: keccak256 certifié → TX Polygon valides
# ═══════════════════════════════════════════════════════════════════

set -e

SUPABASE_PROJECT_REF="ubrqtcxbxcmvmxleiglh"
FUNCTION_NAME="blockchain-tx"

echo "🔧 Déploiement blockchain-tx v7 (fix keccak256)"
echo "   Projet : $SUPABASE_PROJECT_REF"
echo ""

# Vérifier que le token est défini
if [ -z "$SUPABASE_ACCESS_TOKEN" ]; then
  echo "❌ SUPABASE_ACCESS_TOKEN non défini"
  echo ""
  echo "📋 Comment obtenir votre token :"
  echo "   1. Aller sur https://supabase.com/dashboard/account/tokens"
  echo "   2. Cliquer 'Generate new token'"
  echo "   3. Exporter : export SUPABASE_ACCESS_TOKEN='sbp_...'"
  echo "   4. Relancer ce script"
  exit 1
fi

echo "✅ Token configuré"
echo ""

# Déployer la fonction
echo "📤 Déploiement en cours..."
supabase functions deploy $FUNCTION_NAME \
  --project-ref $SUPABASE_PROJECT_REF \
  --no-verify-jwt

echo ""
echo "✅ Déployé ! Vérification..."
sleep 3

# Vérifier la version déployée
RESPONSE=$(curl -s -X POST \
  "https://${SUPABASE_PROJECT_REF}.supabase.co/functions/v1/${FUNCTION_NAME}" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InVicnF0Y3hieGNtdm14bGVpZ2xoIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NDQ3MjM4MDUsImV4cCI6MjA2MDI5OTgwNX0.hm3fFxqQqjSOQgMMSbqNaAQ-ZzwBDcNVPOqHT6OIAOE" \
  -d '{"action":"debug_env"}')

VERSION=$(echo "$RESPONSE" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('deployed_version','?'))" 2>/dev/null)

echo "📍 Version déployée : $VERSION"

if [ "$VERSION" = "v7-keccak-fix-eth-crypto" ]; then
  echo "✅ Version v7 confirmée ! La correction est active."
  echo ""
  echo "🧪 Pour tester une vraie TX :"
  echo "   curl -X POST https://${SUPABASE_PROJECT_REF}.supabase.co/functions/v1/${FUNCTION_NAME} \\"
  echo "     -H 'Content-Type: application/json' \\"
  echo "     -H 'Authorization: Bearer <anon_key>' \\"
  echo "     -d '{\"action\":\"enregistrer_operation\",\"tontine_code\":\"TEST01\",\"type_operation\":\"cotisation\",\"membre_id\":\"test\",\"montant_xof\":1000,\"ref_interne\":\"test-v7\"}'"
else
  echo "⚠️  Version inattendue : $VERSION"
  echo "   Le déploiement a peut-être utilisé le cache. Attendre 30s et réessayer."
fi
