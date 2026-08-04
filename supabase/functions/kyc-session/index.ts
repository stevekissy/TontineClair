// ═══════════════════════════════════════════════════════════════════════════
// TontineClair — Edge Function : kyc-session
// Route : POST /functions/v1/kyc-session
//
// Rôle : Créer une session de vérification Smile ID (Web API v2).
//        Les clés Smile ID ne sont JAMAIS exposées côté Flutter.
//
// Variables d'environnement requises (Supabase → Settings → Secrets) :
//   SMILE_ID_PARTNER_ID   : "9035"
//   SMILE_ID_AUTH_TOKEN   : le auth_token du smile_config.json
//   SMILE_ID_SID_SERVER   : "0" (sandbox/test) ou "1" (production)
//   SUPABASE_SERVICE_ROLE_KEY : clé service_role Supabase
//
// Smile ID Web API v2 :
//   sandbox : https://testapi.smileidentity.com/v1/
//   prod    : https://api.smileidentity.com/v1/
// ═══════════════════════════════════════════════════════════════════════════

import { serve }        from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

// ── CORS ──────────────────────────────────────────────────────────────────
const CORS = {
  'Access-Control-Allow-Origin':  '*',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

const json = (data: unknown, status = 200) =>
  new Response(JSON.stringify(data), {
    status,
    headers: { ...CORS, 'Content-Type': 'application/json' },
  });

// ── Mapping types documents TontineClair → Smile ID ──────────────────────
const SMILE_DOC_TYPE: Record<string, string> = {
  'national_id':      'NATIONAL_ID',
  'passport':         'PASSPORT',
  'drivers_license':  'DRIVERS_LICENSE',
  'residence_permit': 'ALIEN_CARD',
  'voter_id':         'VOTER_ID',
};

// ── Mapping pays ISO-2 → Smile ID country ────────────────────────────────
const SMILE_COUNTRY: Record<string, string> = {
  'CI': 'CI', 'SN': 'SN', 'CM': 'CM', 'BF': 'BF',
  'ML': 'ML', 'GN': 'GN', 'TG': 'TG', 'BJ': 'BJ',
  'NE': 'NE', 'GH': 'GH', 'NG': 'NG', 'FR': 'FR',
  'BE': 'BE', 'CD': 'CD', 'CG': 'CG', 'GA': 'GA',
  'KE': 'KE', 'TZ': 'TZ', 'ZA': 'ZA',
};

// ── Types ─────────────────────────────────────────────────────────────────
interface KycSessionRequest {
  user_id:       string;
  full_name:     string;
  date_of_birth: string;    // YYYY-MM-DD
  country:       string;    // ISO 3166-1 alpha-2 (ex: "CI")
  document_type: string;    // national_id | passport | ...
  doc_front_b64: string;    // Base64 image recto
  doc_back_b64?: string;    // Base64 image verso (optionnel)
  selfie_b64:    string;    // Base64 selfie
}

// ─────────────────────────────────────────────────────────────────────────
serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST')   return json({ error: 'Method not allowed' }, 405);

  try {
    // 1. Vérifier l'authentification
    const authHeader = req.headers.get('Authorization');
    if (!authHeader) return json({ error: 'Unauthorized' }, 401);

    // 2. Parser le body
    const body: KycSessionRequest = await req.json();
    if (!body.user_id || !body.full_name || !body.country || !body.document_type) {
      return json({ error: 'Missing required fields: user_id, full_name, country, document_type' }, 400);
    }

    // 3. Lire les secrets Smile ID
    const partnerId  = Deno.env.get('SMILE_ID_PARTNER_ID');
    const authToken  = Deno.env.get('SMILE_ID_AUTH_TOKEN');
    const sidServer  = Deno.env.get('SMILE_ID_SID_SERVER') ?? '0';  // '0'=test, '1'=prod

    // ── Si pas de clés → mode simulation ─────────────────────────────────
    if (!partnerId || !authToken) {
      console.log('[kyc-session] MODE SIMULATION — configurez SMILE_ID_PARTNER_ID + SMILE_ID_AUTH_TOKEN');
      const mockJobId = `MOCK-${Date.now()}-${Math.random().toString(36).substring(2, 8).toUpperCase()}`;
      await _updateKycReference(body.user_id, mockJobId, 'mock', 'processing');
      return json({
        smile_job_id: mockJobId,
        mode:         'simulation',
        message:      'KYC simulé. Configurez les secrets Smile ID pour activer la vérification réelle.',
      });
    }

    // ── PRODUCTION : Smile ID Web API v2 ─────────────────────────────────
    const baseUrl = sidServer === '1'
      ? 'https://api.smileidentity.com/v1'
      : 'https://testapi.smileidentity.com/v1';

    // Générer timestamp + signature HMAC-SHA256
    const timestamp = new Date().toISOString();
    const signature = await _generateSignature(partnerId, authToken, timestamp);

    const smileDocType = SMILE_DOC_TYPE[body.document_type] ?? 'NATIONAL_ID';
    const smileCountry = SMILE_COUNTRY[body.country] ?? body.country;

    // Job ID unique
    const jobId = `TC-${body.user_id.substring(0, 8)}-${Date.now()}`;

    // Construire la requête Smile ID (Document Verification + Selfie = job_type 6)
    const payload = {
      partner_id:  partnerId,
      signature:   signature,
      timestamp:   timestamp,
      partner_params: {
        job_id:    jobId,
        user_id:   `tc_${body.user_id.replace(/-/g, '').substring(0, 20)}`,
        job_type:  6,  // DocV + Selfie (Enhanced Document Verification)
      },
      id_info: {
        first_name: body.full_name.split(' ')[0] ?? '',
        last_name:  body.full_name.split(' ').slice(1).join(' ') ?? '',
        country:    smileCountry,
        id_type:    smileDocType,
        entered:    true,
      },
      images: [
        { image_type_id: 2, image: body.selfie_b64   },  // 2 = selfie (live)
        { image_type_id: 3, image: body.doc_front_b64 },  // 3 = recto document
        ...(body.doc_back_b64
          ? [{ image_type_id: 6, image: body.doc_back_b64 }]  // 6 = verso
          : []),
      ],
      options: {
        return_job_status: true,
        return_history:    false,
        return_images:     false,
      },
    };

    console.log(`[kyc-session] Appel Smile ID ${baseUrl}/upload — partner_id=${partnerId} job_type=6`);

    const smileResp = await fetch(`${baseUrl}/upload`, {
      method:  'POST',
      headers: { 'Content-Type': 'application/json' },
      body:    JSON.stringify(payload),
    });

    const smileData = await smileResp.json() as Record<string, unknown>;

    if (!smileResp.ok) {
      console.error('[kyc-session] Smile ID erreur:', JSON.stringify(smileData));
      return json({
        error:   'Smile ID error',
        code:    smileResp.status,
        details: smileData,
      }, 500);
    }

    // Extraire le smile_job_id retourné par Smile ID
    const smileJobId = (smileData.smile_job_id as string)
      ?? (smileData.job_id as string)
      ?? jobId;

    await _updateKycReference(body.user_id, smileJobId, 'smile_id', 'processing');

    console.log(`[kyc-session] Succès — smile_job_id=${smileJobId}`);

    return json({
      smile_job_id: smileJobId,
      job_id:       jobId,
      mode:         sidServer === '1' ? 'production' : 'sandbox',
      message:      'Dossier KYC soumis à Smile ID avec succès. Résultat sous 24–48h.',
    });

  } catch (error) {
    console.error('[kyc-session] Erreur inattendue:', error);
    return json({
      error:   'Internal server error',
      message: 'Une erreur inattendue s\'est produite. Réessayez.',
    }, 500);
  }
});

// ── Générer la signature HMAC-SHA256 pour Smile ID ───────────────────────
// Format : HMAC-SHA256(timestamp + partner_id + "smile_notification", api_key)
async function _generateSignature(
  partnerId: string,
  apiKey:    string,
  timestamp: string,
): Promise<string> {
  const message = `${timestamp}${partnerId}smile_notification`;
  const encoder = new TextEncoder();

  const cryptoKey = await crypto.subtle.importKey(
    'raw',
    encoder.encode(apiKey),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  );

  const sig = await crypto.subtle.sign('HMAC', cryptoKey, encoder.encode(message));
  return btoa(String.fromCharCode(...new Uint8Array(sig)));
}

// ── Mettre à jour la référence KYC dans Supabase ─────────────────────────
async function _updateKycReference(
  userId:    string,
  reference: string,
  provider:  string,
  status:    string,
): Promise<void> {
  const supabaseUrl    = Deno.env.get('SUPABASE_URL') ?? '';
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
  if (!supabaseUrl || !serviceRoleKey) return;

  const sb = createClient(supabaseUrl, serviceRoleKey);
  const { error } = await sb
    .from('kyc_verifications')
    .update({
      provider_reference: reference,
      provider:           provider,
      status:             status,
      updated_at:         new Date().toISOString(),
    })
    .eq('user_id', userId);

  if (error) console.error('[kyc-session] _updateKycReference error:', error);
}
