// ─── Edge Function Supabase : verifier_echeances ─────────────────────────────
//
// Rôle : Parcourt toutes les tontines actives, calcule les échéances,
//        et envoie des push FCM aux membres quand une cotisation approche.
//
// Appels possibles :
//   • Déclenchement cron (automatique, sans body)
//   • Déclenchement manuel via POST /functions/v1/verifier_echeances
//     Body optionnel : { "code": "TONTINE123" }  → traite une seule tontine
//
// Seuils de rappel : J-3, J-1, J-0, et retard (joursRestants < 0)
//
// Anti-spam : stocké dans la table `rappels_envoyes`
//   (code TEXT, date DATE, PRIMARY KEY(code, date))
//   → une seule notification push par tontine par jour.
//
// Variables d'environnement requises (Supabase Project Settings > Edge Functions):
//   FIREBASE_PROJECT_ID      ex: "tontineclair"
//   FIREBASE_SERVICE_ACCOUNT ex: '{"type":"service_account","client_email":...}'
//   SUPABASE_URL             injecté automatiquement
//   SUPABASE_SERVICE_ROLE_KEY injecté automatiquement
// ─────────────────────────────────────────────────────────────────────────────

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// ─────────────────────────────────────────────────────────────────────────────
// Types internes
// ─────────────────────────────────────────────────────────────────────────────

interface TontineLigne {
  code: string;
  nom: string;
  montant: number;
  devise: string;
  periode: string;
  echeance: string | null;
  cycle_termine: boolean;
  membres: MembreLigne[];
}

interface MembreLigne {
  paye: boolean;
}

interface TextesNotif {
  titre: string;
  corps: string;
}

// ─────────────────────────────────────────────────────────────────────────────
// Calcul d'échéance (réplique de EcheanceService.dart en TypeScript)
// ─────────────────────────────────────────────────────────────────────────────

function joursCycle(periode: string): number {
  switch (periode) {
    case "journalier":  return 1;
    case "hebdo":       return 7;
    case "mensuel":     return 30;
    case "bimensuel":   return 60;
    case "trimestriel": return 90;
    case "annuel":      return 365;
    default:            return 30;
  }
}

function addMois(d: Date, nbMois: number): Date {
  const result = new Date(d);
  result.setMonth(result.getMonth() + nbMois);
  return result;
}

function prochaineDateDepuis(depuis: Date, periode: string, maintenant: Date): Date {
  let next = new Date(depuis);

  if (["mensuel", "bimensuel", "trimestriel", "annuel"].includes(periode)) {
    const nbMois =
      periode === "mensuel" ? 1
      : periode === "bimensuel" ? 2
      : periode === "trimestriel" ? 3
      : 12;
    while (next <= maintenant) {
      next = addMois(next, nbMois);
    }
  } else {
    const nbJours = joursCycle(periode);
    while (next <= maintenant) {
      next = new Date(next.getTime() + nbJours * 86_400_000);
    }
  }
  return next;
}

function prochaineEcheance(echeanceStockee: string | null, periode: string): Date {
  const maintenant = new Date();

  if (echeanceStockee) {
    const d = new Date(echeanceStockee);
    if (!isNaN(d.getTime())) {
      if (d > maintenant) return d;
      return prochaineDateDepuis(d, periode, maintenant);
    }
  }
  return prochaineDateDepuis(maintenant, periode, maintenant);
}

/**
 * Retourne le nombre de jours entre maintenant et l'échéance.
 * Négatif si l'échéance est déjà passée.
 */
function joursRestants(echeance: Date): number {
  const now = new Date();
  const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  const target = new Date(echeance.getFullYear(), echeance.getMonth(), echeance.getDate());
  const diffMs = target.getTime() - today.getTime();
  return Math.round(diffMs / 86_400_000);
}

// ─────────────────────────────────────────────────────────────────────────────
// Construction des textes de notification
// ─────────────────────────────────────────────────────────────────────────────

function formaterMontant(montant: number, devise: string): string {
  const symboles: Record<string, string> = {
    XOF: "FCFA", XAF: "FCFA", EUR: "€",
    USD: "$", GHS: "GH₵", NGN: "₦",
    MAD: "MAD", TND: "TND",
  };
  const symbole = symboles[devise] ?? devise;
  // Formatage avec séparateur de milliers (espace)
  const str = Math.round(montant).toString();
  let formatted = "";
  for (let i = 0; i < str.length; i++) {
    if (i > 0 && (str.length - i) % 3 === 0) formatted += " ";
    formatted += str[i];
  }
  return `${formatted} ${symbole}`;
}

function construireTextes(
  nomTontine: string,
  joursRestantsVal: number,
  montant: number,
  devise: string,
  nbNonPayes: number,
): TextesNotif {
  const montantFmt = formaterMontant(montant, devise);
  const suffixe = nbNonPayes > 0
    ? ` — ${nbNonPayes} membre${nbNonPayes > 1 ? "s" : ""} n'${nbNonPayes > 1 ? "ont" : "a"} pas encore payé`
    : "";

  if (joursRestantsVal < 0) {
    const retard = Math.abs(joursRestantsVal);
    return {
      titre: `❗ Cotisation en retard — ${nomTontine}`,
      corps:  `La cotisation de ${montantFmt} est en retard de ${retard} jour${retard > 1 ? "s" : ""}.${suffixe}`,
    };
  }
  if (joursRestantsVal === 0) {
    return {
      titre: `🔴 Cotisation aujourd'hui — ${nomTontine}`,
      corps:  `La cotisation de ${montantFmt} est à payer aujourd'hui.${suffixe}`,
    };
  }
  if (joursRestantsVal === 1) {
    return {
      titre: `⚠️ Cotisation demain — ${nomTontine}`,
      corps:  `Rappel : la cotisation de ${montantFmt} est à payer demain.${suffixe}`,
    };
  }
  return {
    titre: `⏰ Cotisation dans ${joursRestantsVal} jours — ${nomTontine}`,
    corps:  `Rappel : la cotisation de ${montantFmt} est à payer dans ${joursRestantsVal} jours.${suffixe}`,
  };
}

// ─────────────────────────────────────────────────────────────────────────────
// FCM v1 — même implémentation que envoyer_notification
// ─────────────────────────────────────────────────────────────────────────────

async function getAccessToken(serviceAccount: Record<string, string>): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const header  = { alg: "RS256", typ: "JWT" };
  const payload = {
    iss:   serviceAccount.client_email,
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud:   "https://oauth2.googleapis.com/token",
    iat:   now,
    exp:   now + 3600,
  };
  const encode = (obj: object) =>
    btoa(JSON.stringify(obj)).replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");

  const headerB64  = encode(header);
  const payloadB64 = encode(payload);
  const signingInput = `${headerB64}.${payloadB64}`;

  const pemKey  = serviceAccount.private_key.replace(/\\n/g, "\n");
  const keyData = pemKey
    .replace("-----BEGIN PRIVATE KEY-----", "")
    .replace("-----END PRIVATE KEY-----", "")
    .replace(/\s/g, "");
  const binaryKey = Uint8Array.from(atob(keyData), (c) => c.charCodeAt(0));

  const cryptoKey = await crypto.subtle.importKey(
    "pkcs8", binaryKey,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false, ["sign"],
  );
  const signature = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5", cryptoKey,
    new TextEncoder().encode(signingInput),
  );
  const signatureB64 = btoa(String.fromCharCode(...new Uint8Array(signature)))
    .replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");

  const jwt = `${signingInput}.${signatureB64}`;
  const tokenResponse = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: `grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=${jwt}`,
  });
  const tokenData = await tokenResponse.json();
  return tokenData.access_token as string;
}

async function envoyerFCM(
  token: string,
  titre: string,
  corps: string,
  data: Record<string, string>,
  projectId: string,
  accessToken: string,
): Promise<boolean> {
  const url = `https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`;
  const res = await fetch(url, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${accessToken}`,
    },
    body: JSON.stringify({
      message: {
        token,
        notification: { title: titre, body: corps },
        data,
        android: {
          priority: "high",
          notification: {
            channel_id: "tontineclair_rappels",   // canal dédié aux rappels
            priority: "high",
            default_sound: true,
          },
        },
      },
    }),
  });
  if (!res.ok) {
    const err = await res.text();
    console.error(`FCM error pour token ${token.substring(0, 20)}...: ${err}`);
  }
  return res.ok;
}

// ─────────────────────────────────────────────────────────────────────────────
// Anti-spam — table `rappels_envoyes` (code TEXT, date DATE, PK(code,date))
//
// SQL de création (à exécuter dans Supabase › SQL Editor) :
//   CREATE TABLE IF NOT EXISTS rappels_envoyes (
//     code TEXT NOT NULL,
//     date DATE NOT NULL DEFAULT CURRENT_DATE,
//     PRIMARY KEY (code, date)
//   );
//   ALTER TABLE rappels_envoyes ENABLE ROW LEVEL SECURITY;
//   -- Lecture/écriture autorisée uniquement côté service_role (Edge Functions)
// ─────────────────────────────────────────────────────────────────────────────

async function dejaNotifieAujourdhui(
  supabase: ReturnType<typeof createClient>,
  code: string,
): Promise<boolean> {
  const today = new Date().toISOString().split("T")[0]; // YYYY-MM-DD
  const { data, error } = await supabase
    .from("rappels_envoyes")
    .select("code")
    .eq("code", code.toUpperCase())
    .eq("date", today)
    .maybeSingle();

  if (error) {
    // Si la table n'existe pas encore → on laisse passer (pas de spam critique)
    console.warn(`Anti-spam read error (${code}): ${error.message}`);
    return false;
  }
  return data !== null;
}

async function marquerNotifieAujourdhui(
  supabase: ReturnType<typeof createClient>,
  code: string,
): Promise<void> {
  const today = new Date().toISOString().split("T")[0];
  const { error } = await supabase
    .from("rappels_envoyes")
    .upsert({ code: code.toUpperCase(), date: today });

  if (error) {
    console.warn(`Anti-spam write error (${code}): ${error.message}`);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Traitement d'une tontine individuelle
// ─────────────────────────────────────────────────────────────────────────────

const SEUILS_JOURS = [3, 1, 0]; // J-3, J-1, J-0

async function traiterTontine(
  supabase: ReturnType<typeof createClient>,
  tontine: TontineLigne,
  projectId: string,
  serviceAccount: Record<string, string>,
): Promise<{ code: string; action: string; envoyes?: number }> {
  const { code, nom, montant, devise, periode, echeance, cycle_termine, membres } = tontine;

  // Ignorer les tontines terminées ou sans membres
  if (cycle_termine) {
    return { code, action: "ignore_termine" };
  }
  if (!membres || membres.length === 0) {
    return { code, action: "ignore_sans_membres" };
  }

  // Calculer l'échéance et les jours restants
  const dateEcheance = prochaineEcheance(echeance, periode);
  const jours = joursRestants(dateEcheance);

  // Vérifier si on doit notifier
  const doitNotifier = jours < 0 || SEUILS_JOURS.includes(jours);
  if (!doitNotifier) {
    return { code, action: `skip_j${jours}` };
  }

  // Anti-spam : max 1 notification push par tontine par jour
  if (await dejaNotifieAujourdhui(supabase, code)) {
    return { code, action: "skip_antispam" };
  }

  // Construire les textes
  const nbNonPayes = membres.filter((m) => !m.paye).length;
  const textes = construireTextes(nom, jours, montant, devise, nbNonPayes);

  // Récupérer les tokens FCM de la tontine
  const { data: tokens, error: tokensError } = await supabase
    .from("fcm_tokens")
    .select("token")
    .eq("tontine_code", code.toUpperCase());

  if (tokensError || !tokens || tokens.length === 0) {
    return { code, action: "skip_no_tokens" };
  }

  // Obtenir le token OAuth2 pour FCM
  let accessToken: string;
  try {
    accessToken = await getAccessToken(serviceAccount);
  } catch (e) {
    console.error(`FCM auth error: ${e}`);
    return { code, action: "error_fcm_auth" };
  }

  // Données supplémentaires dans le payload FCM
  const fcmData: Record<string, string> = {
    code: code.toUpperCase(),
    type: jours < 0 ? "rappel_retard" : "rappel_echeance",
    joursRestants: String(jours),
  };

  // Envoyer à tous les tokens
  let envoyes = 0;
  for (const { token } of tokens) {
    const ok = await envoyerFCM(
      token,
      textes.titre,
      textes.corps,
      fcmData,
      projectId,
      accessToken,
    );
    if (ok) envoyes++;
  }

  console.log(`[${code}] J${jours} → ${envoyes}/${tokens.length} push envoyés`);

  // Marquer comme notifié aujourd'hui
  await marquerNotifieAujourdhui(supabase, code);

  return { code, action: "notifie", envoyes };
}

// ─────────────────────────────────────────────────────────────────────────────
// Récupération des tontines depuis Supabase
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Lit les tontines depuis la table `tontines` (ou via RPC si nécessaire).
 * On utilise la table directement avec service_role pour éviter les RLS.
 *
 * Colonnes minimales requises :
 *   code, nom, montant, devise, periodicite (ou periode), echeance,
 *   cycle_termine, membres (jsonb[])
 */
async function lireTontinesActives(
  supabase: ReturnType<typeof createClient>,
  codeFiltre?: string,
): Promise<TontineLigne[]> {
  let query = supabase
    .from("tontines")
    .select("code, nom, montant, devise, periodicite, echeance, cycle_termine, membres")
    .eq("cycle_termine", false);

  if (codeFiltre) {
    query = query.eq("code", codeFiltre.toUpperCase());
  }

  const { data, error } = await query;

  if (error) {
    throw new Error(`Erreur lecture tontines: ${error.message}`);
  }

  if (!data) return [];

  // Normaliser le champ periodicite → periode
  return data.map((row) => ({
    code:          row.code as string,
    nom:           row.nom as string,
    montant:       (row.montant as number) ?? 0,
    devise:        (row.devise as string) ?? "XOF",
    periode:       (row.periodicite as string) ?? "mensuel",
    echeance:      row.echeance as string | null,
    cycle_termine: (row.cycle_termine as boolean) ?? false,
    membres:       (row.membres as MembreLigne[]) ?? [],
  }));
}

// ─────────────────────────────────────────────────────────────────────────────
// Handler principal Deno.serve
// ─────────────────────────────────────────────────────────────────────────────

Deno.serve(async (req: Request) => {
  // CORS preflight
  if (req.method === "OPTIONS") {
    return new Response(null, {
      headers: {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Headers":
          "authorization, x-client-info, apikey, content-type",
      },
    });
  }

  const debutMs = Date.now();

  try {
    // ── Variables d'environnement ─────────────────────────────────────────
    const projectId = Deno.env.get("FIREBASE_PROJECT_ID") ?? "tontineclair";
    const serviceAccountStr = Deno.env.get("FIREBASE_SERVICE_ACCOUNT");
    if (!serviceAccountStr) {
      return new Response(
        JSON.stringify({ error: "FIREBASE_SERVICE_ACCOUNT non configuré" }),
        { status: 500, headers: { "Content-Type": "application/json" } },
      );
    }
    const serviceAccount = JSON.parse(serviceAccountStr) as Record<string, string>;

    const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
    const supabaseKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
    const supabase = createClient(supabaseUrl, supabaseKey);

    // ── Body optionnel — filtre sur un code précis ────────────────────────
    let codeFiltre: string | undefined;
    if (req.method === "POST") {
      try {
        const body = await req.json();
        codeFiltre = body?.code as string | undefined;
      } catch (_) {
        // Body absent ou invalide → traiter toutes les tontines
      }
    }

    console.log(
      codeFiltre
        ? `verifier_echeances démarré — filtre: ${codeFiltre}`
        : `verifier_echeances démarré — toutes les tontines`,
    );

    // ── Récupérer les tontines actives ────────────────────────────────────
    const tontines = await lireTontinesActives(supabase, codeFiltre);
    console.log(`${tontines.length} tontine(s) active(s) trouvée(s)`);

    if (tontines.length === 0) {
      return new Response(
        JSON.stringify({ traites: 0, resultats: [], dureeMs: Date.now() - debutMs }),
        { headers: { "Content-Type": "application/json" }, status: 200 },
      );
    }

    // ── Traiter chaque tontine ────────────────────────────────────────────
    const resultats: Array<{ code: string; action: string; envoyes?: number }> = [];

    for (const tontine of tontines) {
      try {
        const resultat = await traiterTontine(
          supabase,
          tontine,
          projectId,
          serviceAccount,
        );
        resultats.push(resultat);
      } catch (e) {
        console.error(`Erreur tontine ${tontine.code}: ${e}`);
        resultats.push({ code: tontine.code, action: "error" });
      }
    }

    // ── Résumé ────────────────────────────────────────────────────────────
    const totalEnvoyes = resultats
      .filter((r) => r.action === "notifie")
      .reduce((sum, r) => sum + (r.envoyes ?? 0), 0);
    const totalNotifies = resultats.filter((r) => r.action === "notifie").length;

    console.log(
      `Terminé — ${totalNotifies} tontine(s) notifiée(s), ${totalEnvoyes} push envoyés`
      + ` en ${Date.now() - debutMs}ms`,
    );

    return new Response(
      JSON.stringify({
        traites:       tontines.length,
        notifies:      totalNotifies,
        totalEnvoyes,
        resultats,
        dureeMs:       Date.now() - debutMs,
      }),
      { headers: { "Content-Type": "application/json" }, status: 200 },
    );

  } catch (e) {
    console.error("Erreur critique:", e);
    return new Response(
      JSON.stringify({ error: String(e), dureeMs: Date.now() - debutMs }),
      { status: 500, headers: { "Content-Type": "application/json" } },
    );
  }
});
