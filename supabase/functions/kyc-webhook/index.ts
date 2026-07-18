// ═══════════════════════════════════════════════════════════════════════════
// TontineClair — Edge Function : kyc-webhook
// Route : POST /functions/v1/kyc-webhook
//
// Rôle : Recevoir les callbacks Smile ID, vérifier leur authenticité,
//        et mettre à jour le statut KYC dans Supabase.
//
// Configuration Smile ID → Webhooks :
//   URL : https://<project-ref>.supabase.co/functions/v1/kyc-webhook
//   Events : JOB_COMPLETE
//
// Variables d'environnement requises :
//   SMILE_ID_PARTNER_ID         : Partner ID Smile ID
//   SMILE_ID_API_KEY            : Clé API RSA (pour vérification signature)
//   SMILE_ID_WEBHOOK_SECRET     : Secret webhook Smile ID (optionnel mais recommandé)
//   SUPABASE_SERVICE_ROLE_KEY   : Clé service_role Supabase
// ═══════════════════════════════════════════════════════════════════════════

import { serve }        from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const CORS_HEADERS = {
  'Access-Control-Allow-Origin':  '*',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-smile-signature',
};

// ── Mapping résultats Smile ID → statuts TontineClair ─────────────────────
function mapSmileResult(resultCode: string | undefined, actions: Record<string, string>): {
  status: string;
  rejection_reason?: string;
  rejection_code?: string;
  confidence_score?: number;
} {
  // Codes résultat Smile ID : 0 = approved, 1 = rejected, ...
  switch (resultCode) {
    case '0':  // Approved
      return { status: 'verified' };

    case '1':  // Rejected by AI
      return {
        status:           'rejected',
        rejection_code:   resultCode,
        rejection_reason: _buildRejectionReason(actions),
      };

    case '2':  // Rejected by admin
      return {
        status:           'rejected',
        rejection_code:   resultCode,
        rejection_reason: 'Document refusé après vérification manuelle.',
      };

    case '4':  // Under review
      return { status: 'manual_review' };

    case '5':  // Unknown result
      return { status: 'processing' };

    default:
      return { status: 'manual_review' };
  }
}

function _buildRejectionReason(actions: Record<string, string>): string {
  const reasons: string[] = [];
  if (actions['Liveness_Check'] === 'Rejected') reasons.push('Contrôle de présence réelle échoué.');
  if (actions['Selfie_To_ID_Face_Comparison'] === 'Rejected') reasons.push('Le visage ne correspond pas au document.');
  if (actions['Human_Review_Compare'] === 'Rejected') reasons.push('Vérification manuelle échouée.');
  if (actions['ID_Verification'] === 'Rejected') reasons.push('Document invalide ou expiré.');
  return reasons.length > 0 ? reasons.join(' ') : 'Vérification refusée. Veuillez recommencer.';
}

// ─────────────────────────────────────────────────────────────────────────
serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: CORS_HEADERS });
  }

  if (req.method !== 'POST') {
    return new Response('Method not allowed', {
      status: 405, headers: CORS_HEADERS,
    });
  }

  const supabaseUrl    = Deno.env.get('SUPABASE_URL') ?? '';
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
  const webhookSecret  = Deno.env.get('SMILE_ID_WEBHOOK_SECRET');

  const supabase = createClient(supabaseUrl, serviceRoleKey);

  try {
    const rawBody = await req.text();

    // 1. Vérifier la signature si le secret est configuré
    if (webhookSecret) {
      const signature = req.headers.get('x-smile-signature');
      if (!signature) {
        console.warn('[kyc-webhook] Missing signature header');
        return new Response('Unauthorized', { status: 401, headers: CORS_HEADERS });
      }

      const isValid = await _verifyWebhookSignature(rawBody, signature, webhookSecret);
      if (!isValid) {
        console.warn('[kyc-webhook] Invalid signature');
        return new Response('Unauthorized — invalid signature', {
          status: 401, headers: CORS_HEADERS,
        });
      }
    }

    // 2. Parser le payload Smile ID
    const payload = JSON.parse(rawBody) as Record<string, unknown>;
    console.log('[kyc-webhook] Received payload:', JSON.stringify(payload).substring(0, 500));

    const smileJobId    = payload.smile_job_id  as string;
    const userId        = (payload.partner_params as Record<string, string>)?.user_id;
    const resultText    = payload.result_text    as string;
    const resultCode    = payload.result_code    as string;
    const actions       = (payload.actions       as Record<string, string>) ?? {};
    const confidence    = (payload as Record<string, number>).confidence_value;

    if (!smileJobId || !userId) {
      console.error('[kyc-webhook] Missing smile_job_id or user_id in payload');
      return new Response('Bad request', { status: 400, headers: CORS_HEADERS });
    }

    // 3. Chercher l'entrée KYC correspondante
    const { data: kycRow, error: fetchErr } = await supabase
      .from('kyc_verifications')
      .select('id, status, user_id')
      .eq('provider_reference', smileJobId)
      .single();

    if (fetchErr || !kycRow) {
      console.error('[kyc-webhook] KYC not found for job:', smileJobId);
      // On retourne 200 pour ne pas déclencher de retry Smile ID
      return new Response('OK (not found)', { status: 200, headers: CORS_HEADERS });
    }

    // 4. Mapper le résultat
    const { status, rejection_reason, rejection_code } = mapSmileResult(resultCode, actions);

    const now = new Date().toISOString();
    const updateData: Record<string, unknown> = {
      status:     status,
      updated_at: now,
    };

    if (status === 'verified') {
      updateData['verified_at'] = now;
      updateData['expires_at']  = new Date(Date.now() + 365 * 24 * 3600 * 1000).toISOString();
    }
    if (rejection_reason) updateData['rejection_reason'] = rejection_reason;
    if (rejection_code)   updateData['rejection_code']   = rejection_code;
    if (confidence)       updateData['confidence_score'] = confidence;

    // 5. Mettre à jour le statut KYC
    const { error: updateErr } = await supabase
      .from('kyc_verifications')
      .update(updateData)
      .eq('id', kycRow.id);

    if (updateErr) {
      console.error('[kyc-webhook] Update error:', updateErr);
      return new Response('Internal error', { status: 500, headers: CORS_HEADERS });
    }

    // 6. Journaliser dans kyc_audit_log
    await supabase.from('kyc_audit_log').insert({
      kyc_id:       kycRow.id,
      user_id:      userId,
      action:       'status_changed',
      old_status:   kycRow.status,
      new_status:   status,
      performed_by: 'webhook:smile_id',
      notes:        rejection_reason ?? resultText ?? '',
      metadata: {
        smile_job_id: smileJobId,
        result_code:  resultCode,
        result_text:  resultText,
        actions:      actions,
      },
    });

    // 7. Envoyer une notification in-app (via table notifications si elle existe)
    try {
      await supabase.from('notifications').insert({
        gestionnaire: userId,
        type:         'kyc_result',
        titre:        status === 'verified'
                        ? 'Identité vérifiée ✓'
                        : status === 'rejected'
                            ? 'Vérification refusée'
                            : 'Vérification en cours de traitement',
        message:      status === 'verified'
                        ? 'Votre identité a été vérifiée avec succès. Vous avez accès à toutes les fonctionnalités.'
                        : status === 'rejected'
                            ? `Votre vérification a été refusée. ${rejection_reason ?? ''} Veuillez recommencer.`
                            : 'Votre dossier nécessite une vérification manuelle. Notre équipe vous contactera.',
        lu:           false,
        cree_le:      now,
      });
    } catch (_) {
      // Les notifications ne sont pas bloquantes
    }

    console.log(`[kyc-webhook] ✓ Updated user=${userId} job=${smileJobId} status=${status}`);

    return new Response(JSON.stringify({ ok: true, status }), {
      status:  200,
      headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
    });

  } catch (err) {
    console.error('[kyc-webhook] Fatal error:', err);
    return new Response('Internal server error', { status: 500, headers: CORS_HEADERS });
  }
});

// ── Vérifier la signature HMAC-SHA256 du webhook Smile ID ─────────────────
async function _verifyWebhookSignature(
  body:      string,
  signature: string,
  secret:    string
): Promise<boolean> {
  try {
    const encoder  = new TextEncoder();
    const keyData  = encoder.encode(secret);
    const msgData  = encoder.encode(body);

    const cryptoKey = await crypto.subtle.importKey(
      'raw', keyData,
      { name: 'HMAC', hash: 'SHA-256' },
      false, ['verify']
    );

    const sigBytes = Uint8Array.from(atob(signature), c => c.charCodeAt(0));
    return await crypto.subtle.verify('HMAC', cryptoKey, sigBytes, msgData);
  } catch {
    return false;
  }
}
