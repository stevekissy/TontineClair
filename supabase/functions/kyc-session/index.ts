// ═══════════════════════════════════════════════════════════════════════════
// TontineClair — Edge Function : kyc-session
// Route : POST /functions/v1/kyc-session
//
// Rôle : Créer une session de vérification Smile ID de façon sécurisée.
//        Les clés Smile ID ne sont JAMAIS exposées côté Flutter.
//
// Variables d'environnement requises (Supabase → Settings → Secrets) :
//   SMILE_ID_PARTNER_ID   : votre Partner ID (ex: "1234")
//   SMILE_ID_API_KEY      : votre clé API RSA privée Smile ID (PEM format)
//   SMILE_ID_SID_SERVER   : "0" = sandbox, "1" = production
//   SMILE_ID_ENVIRONMENT  : "sandbox" ou "production"
//   SUPABASE_SERVICE_ROLE_KEY : clé service_role (pour mise à jour BDD)
// ═══════════════════════════════════════════════════════════════════════════

import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

// ── Types ─────────────────────────────────────────────────────────────────
interface KycSessionRequest {
  user_id:       string;
  full_name:     string;
  date_of_birth: string;    // YYYY-MM-DD
  country:       string;    // ISO 3166-1 alpha-2
  document_type: string;    // national_id | passport | ...
  doc_front_b64: string;    // Base64 image recto
  doc_back_b64?: string;    // Base64 image verso (optionnel)
  selfie_b64:    string;    // Base64 selfie
}

// ── Constantes ────────────────────────────────────────────────────────────
const CORS_HEADERS = {
  'Access-Control-Allow-Origin':  '*',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

// ── Mapping types documents TontineClair → Smile ID ──────────────────────
const SMILE_DOC_TYPE: Record<string, string> = {
  'national_id':      'NATIONAL_ID',
  'passport':         'PASSPORT',
  'drivers_license':  'DRIVERS_LICENSE',
  'residence_permit': 'ALIEN_CARD',
  'voter_id':         'VOTER_ID',
};

// ── Mapping pays → Smile ID country code ─────────────────────────────────
const SMILE_COUNTRY: Record<string, string> = {
  'CI': 'CIV', 'SN': 'SEN', 'CM': 'CMR', 'BF': 'BFA',
  'ML': 'MLI', 'GN': 'GIN', 'TG': 'TGO', 'BJ': 'BEN',
  'NE': 'NER', 'GH': 'GHA', 'NG': 'NGA', 'FR': 'FRA',
  'BE': 'BEL',
};

// ─────────────────────────────────────────────────────────────────────────
serve(async (req) => {
  // Handle preflight
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: CORS_HEADERS });
  }

  if (req.method !== 'POST') {
    return new Response(JSON.stringify({ error: 'Method not allowed' }), {
      status: 405, headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
    });
  }

  try {
    // 1. Authentifier l'appelant (doit avoir un JWT valide)
    const authHeader = req.headers.get('Authorization');
    if (!authHeader) {
      return new Response(JSON.stringify({ error: 'Unauthorized' }), {
        status: 401, headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
      });
    }

    // 2. Parser la requête
    const body: KycSessionRequest = await req.json();
    if (!body.user_id || !body.full_name || !body.country || !body.document_type) {
      return new Response(JSON.stringify({ error: 'Missing required fields' }), {
        status: 400, headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
      });
    }

    // 3. Lire les secrets Smile ID
    const partnerId   = Deno.env.get('SMILE_ID_PARTNER_ID');
    const apiKey      = Deno.env.get('SMILE_ID_API_KEY');
    const sidServer   = Deno.env.get('SMILE_ID_SID_SERVER') ?? '0';
    const environment = Deno.env.get('SMILE_ID_ENVIRONMENT') ?? 'sandbox';

    if (!partnerId || !apiKey) {
      // ── MODE SIMULATION : pas encore de clés Smile ID ──────────────────
      // Retourner un job_id simulé pour les tests
      console.log('[kyc-session] Running in SIMULATION mode (no Smile ID keys configured)');

      const mockJobId = `MOCK-${Date.now()}-${Math.random().toString(36).substring(2, 8).toUpperCase()}`;

      // Mettre à jour la BDD avec la référence simulée
      await _updateKycReference(body.user_id, mockJobId, 'mock');

      return new Response(JSON.stringify({
        smile_job_id: mockJobId,
        mode:         'simulation',
        message:      'Session KYC simulée créée. Configurez SMILE_ID_PARTNER_ID et SMILE_ID_API_KEY pour activer la vérification réelle.',
      }), {
        status: 200,
        headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
      });
    }

    // 4. ── PRODUCTION : Appel Smile ID WebAPI 2.0 ──────────────────────
    const smileApiUrl = sidServer === '0'
      ? 'https://testapi.smileidentity.com/v1'
      : 'https://api.smileidentity.com/v1';

    const timestamp = new Date().toISOString();
    const signature = await _generateSignature(partnerId, apiKey, timestamp);

    const smileDocType = SMILE_DOC_TYPE[body.document_type] ?? 'NATIONAL_ID';
    const smileCountry = SMILE_COUNTRY[body.country] ?? body.country;

    // Construire la requête Smile ID
    const smilePayload: Record<string, unknown> = {
      partner_id:       partnerId,
      signature:        signature,
      timestamp:        timestamp,
      partner_params: {
        job_id:       `TC-${body.user_id}-${Date.now()}`,
        user_id:      body.user_id,
        job_type:     1,  // DocV + Selfie
      },
      id_info: {
        first_name:     body.full_name.split(' ')[0] ?? '',
        last_name:      body.full_name.split(' ').slice(1).join(' ') ?? '',
        country:        smileCountry,
        id_type:        smileDocType,
        entered:        true,
      },
      images: [
        // Type 2 = selfie live
        { image_type_id: 2, image: body.selfie_b64 },
        // Type 3 = recto document
        { image_type_id: 3, image: body.doc_front_b64 },
        // Type 6 = verso document (si fourni)
        ...(body.doc_back_b64 ? [{ image_type_id: 6, image: body.doc_back_b64 }] : []),
      ],
      options: {
        return_job_status:          true,
        return_history:             false,
        return_images:              false,
        use_enrolled_image:         false,
      },
    };

    const smileResp = await fetch(`${smileApiUrl}/smile_links`, {
      method:  'POST',
      headers: { 'Content-Type': 'application/json' },
      body:    JSON.stringify(smilePayload),
    });

    const smileData = await smileResp.json() as Record<string, unknown>;

    if (!smileResp.ok) {
      console.error('[kyc-session] Smile ID error:', smileData);
      return new Response(JSON.stringify({
        error:   'Smile ID error',
        details: smileData,
      }), {
        status: 500,
        headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
      });
    }

    // 5. Extraire le Job ID et le stocker
    const jobId = smileData.smile_job_id as string ?? smileData.job_id as string;
    await _updateKycReference(body.user_id, jobId, 'smile_id');

    return new Response(JSON.stringify({
      smile_job_id: jobId,
      mode:         environment,
      message:      'Dossier KYC soumis à Smile ID avec succès.',
    }), {
      status: 200,
      headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
    });

  } catch (error) {
    console.error('[kyc-session] Unexpected error:', error);
    return new Response(JSON.stringify({
      error:   'Internal server error',
      message: 'Une erreur inattendue s\'est produite.',
    }), {
      status: 500,
      headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
    });
  }
});

// ── Générer la signature HMAC-SHA256 pour Smile ID ───────────────────────
async function _generateSignature(
  partnerId: string,
  apiKey: string,
  timestamp: string
): Promise<string> {
  const message = `${timestamp}${partnerId}smile_notification`;
  const encoder = new TextEncoder();
  const keyData = encoder.encode(apiKey);
  const msgData = encoder.encode(message);

  const cryptoKey = await crypto.subtle.importKey(
    'raw', keyData,
    { name: 'HMAC', hash: 'SHA-256' },
    false, ['sign']
  );

  const signature = await crypto.subtle.sign('HMAC', cryptoKey, msgData);
  return btoa(String.fromCharCode(...new Uint8Array(signature)));
}

// ── Mettre à jour la référence provider dans Supabase ────────────────────
async function _updateKycReference(
  userId: string,
  reference: string,
  provider: string
): Promise<void> {
  const supabaseUrl     = Deno.env.get('SUPABASE_URL') ?? '';
  const serviceRoleKey  = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';

  if (!supabaseUrl || !serviceRoleKey) return;

  const supabase = createClient(supabaseUrl, serviceRoleKey);

  await supabase
    .from('kyc_verifications')
    .update({
      provider_reference: reference,
      provider:           provider,
      status:             'processing',
      updated_at:         new Date().toISOString(),
    })
    .eq('user_id', userId);
}
