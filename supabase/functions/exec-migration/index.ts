/**
 * exec-migration — Edge Function pour exécuter des migrations SQL
 *
 * ⚠️  USAGE ADMIN UNIQUEMENT : Protégée par DEPLOY_SECRET.
 *     Supprimer cette fonction après avoir déployé toutes les migrations.
 *
 * Stratégie d'exécution SQL :
 *   1. API Management Supabase (/v1/projects/{ref}/database/query) — si MGMT_TOKEN fourni
 *   2. RPC PostgreSQL directe via service_role key
 *   3. Retour d'instructions manuelles si tout échoue
 *
 * Usage :
 *   POST /functions/v1/exec-migration
 *   Headers: Authorization: Bearer <anon_key>
 *   Body: {
 *     "sql": "CREATE OR REPLACE FUNCTION ...",
 *     "secret": "tontineclair-deploy-2025"
 *   }
 *
 * Secrets requis dans Supabase :
 *   DEPLOY_SECRET  → secret de protection (défaut: "tontineclair-deploy-2025")
 *   MGMT_TOKEN     → optionnel, token API Management (sbp_xxxx)
 */

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL    = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY     = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const DEPLOY_SECRET   = Deno.env.get("DEPLOY_SECRET") ?? "tontineclair-deploy-2025";
const PROJECT_REF     = SUPABASE_URL?.split(".")[0]?.split("//")[1] ?? "";
const MGMT_TOKEN      = Deno.env.get("MGMT_TOKEN") ?? "";

const CORS = {
  "Access-Control-Allow-Origin":  "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json",
};

// ─── Méthode 1 : API Management Supabase ──────────────────────────────────────
async function execViaMgmtApi(sql: string, mgmtToken: string): Promise<{ ok: boolean; detail: string }> {
  if (!mgmtToken) return { ok: false, detail: "MGMT_TOKEN absent" };

  try {
    const resp = await fetch(
      `https://api.supabase.com/v1/projects/${PROJECT_REF}/database/query`,
      {
        method: "POST",
        headers: {
          "Content-Type":  "application/json",
          "Authorization": `Bearer ${mgmtToken}`,
        },
        body: JSON.stringify({ query: sql }),
      }
    );
    const body = await resp.text();
    console.log(`[exec-migration] Mgmt API → HTTP ${resp.status}: ${body.slice(0, 300)}`);
    return {
      ok:     resp.ok,
      detail: `HTTP ${resp.status}: ${body.slice(0, 500)}`,
    };
  } catch (err) {
    return { ok: false, detail: String(err) };
  }
}

// ─── Méthode 2 : RPC PostgreSQL via service_role ──────────────────────────────
// Utilise une fonction SQL helper pour exécuter du DDL dynamiquement.
// Note : cette méthode ne fonctionne que si la fonction _exec_sql_helper existe.
async function execViaRpc(sql: string): Promise<{ ok: boolean; detail: string }> {
  try {
    const supabase = createClient(SUPABASE_URL, SERVICE_KEY);

    // Tentative via rpc custom
    const { data, error } = await supabase.rpc("_exec_sql", { sql_text: sql });
    if (!error) {
      return { ok: true, detail: `RPC ok: ${JSON.stringify(data).slice(0, 200)}` };
    }

    // Si la fonction n'existe pas, on retourne l'erreur
    return { ok: false, detail: `RPC error: ${error.message}` };
  } catch (err) {
    return { ok: false, detail: String(err) };
  }
}

// ─── Méthode 3 : Créer la fonction helper puis exécuter ───────────────────────
// On crée une fonction SQL qui peut exécuter du DDL, puis on l'appelle.
// Nécessite que PostgREST permette l'exécution de fonctions avec SECURITY DEFINER.
async function execViaHelperCreation(sql: string): Promise<{ ok: boolean; detail: string }> {
  try {
    // Créer la fonction helper via l'API REST (ne fonctionnera que si on a service_role)
    const helperSql = `
      CREATE OR REPLACE FUNCTION _exec_sql_temp(sql_text TEXT)
      RETURNS TEXT LANGUAGE plpgsql SECURITY DEFINER AS $$
      BEGIN
        EXECUTE sql_text;
        RETURN 'ok';
      EXCEPTION WHEN OTHERS THEN
        RETURN SQLERRM;
      END;
      $$;
      GRANT EXECUTE ON FUNCTION _exec_sql_temp(TEXT) TO service_role;
    `;

    // Cette approche ne fonctionnera pas sans accès DDL via REST
    // On log l'essai pour debug
    console.log("[exec-migration] Méthode 3 : helper creation — limitée sans DDL access");
    return { ok: false, detail: "Méthode helper création non disponible via REST anon/service_role" };
  } catch (err) {
    return { ok: false, detail: String(err) };
  }
}

serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: CORS });
  }

  if (req.method !== "POST") {
    return new Response(JSON.stringify({ success: false, error: "POST requis" }), {
      status: 405, headers: CORS,
    });
  }

  let body: { sql?: string; secret?: string; action?: string };
  try {
    body = await req.json();
  } catch {
    return new Response(JSON.stringify({ success: false, error: "JSON invalide" }), {
      status: 400, headers: CORS,
    });
  }

  // ── Vérification du secret ────────────────────────────────────────────────
  if (body.secret !== DEPLOY_SECRET) {
    console.warn("[exec-migration] Secret invalide :", body.secret?.slice(0, 10));
    return new Response(JSON.stringify({ success: false, error: "Secret invalide" }), {
      status: 403, headers: CORS,
    });
  }

  // ── Action diagnostic : retourner l'état de l'environnement ──────────────
  if (body.action === "diagnostic") {
    return new Response(JSON.stringify({
      success:       true,
      supabase_url:  SUPABASE_URL,
      project_ref:   PROJECT_REF,
      has_service_key: !!SERVICE_KEY,
      has_mgmt_token:  !!MGMT_TOKEN,
      deploy_secret_set: !!Deno.env.get("DEPLOY_SECRET"),
    }), { status: 200, headers: CORS });
  }

  const sql = body.sql;
  if (!sql || typeof sql !== "string" || sql.trim().length === 0) {
    return new Response(JSON.stringify({ success: false, error: "sql requis" }), {
      status: 400, headers: CORS,
    });
  }

  console.log(`[exec-migration] SQL reçu : ${sql.slice(0, 100)}... (${sql.length} chars)`);

  const results: Record<string, any> = {};

  // ── Méthode 1 : Management API ────────────────────────────────────────────
  const mgmtToken = MGMT_TOKEN || (body as any).mgmt_token || "";
  const mgmtResult = await execViaMgmtApi(sql, mgmtToken);
  results.mgmt_api = mgmtResult;

  if (mgmtResult.ok) {
    console.log("[exec-migration] ✅ Succès via Management API");
    return new Response(JSON.stringify({
      success: true,
      method:  "management_api",
      detail:  mgmtResult.detail,
    }), { status: 200, headers: CORS });
  }

  // ── Méthode 2 : RPC ───────────────────────────────────────────────────────
  const rpcResult = await execViaRpc(sql);
  results.rpc = rpcResult;

  if (rpcResult.ok) {
    console.log("[exec-migration] ✅ Succès via RPC");
    return new Response(JSON.stringify({
      success: true,
      method:  "rpc",
      detail:  rpcResult.detail,
    }), { status: 200, headers: CORS });
  }

  // ── Toutes les méthodes ont échoué ────────────────────────────────────────
  console.error("[exec-migration] ❌ Toutes les méthodes ont échoué");

  return new Response(JSON.stringify({
    success:  false,
    error:    "Impossible d'exécuter le SQL automatiquement",
    methods:  results,
    manual_url: `https://supabase.com/dashboard/project/${PROJECT_REF}/sql/new`,
    hint: [
      "Option 1 : Fournir MGMT_TOKEN dans les secrets Supabase (sbp_xxxx)",
      "Option 2 : Copier le SQL dans Dashboard → SQL Editor → Run",
      "Option 3 : supabase db push --project-ref " + PROJECT_REF,
    ],
  }), { status: 500, headers: CORS });
});
