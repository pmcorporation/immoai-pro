// ═══════════════════════════════════════════════════════════════
// LEAD ENTRANT — la porte unique
// ═══════════════════════════════════════════════════════════════
//
// Une seule fonction, plusieurs sources. Ajouter un fournisseur de
// leads, c'est écrire un adaptateur d'une vingtaine de lignes ; le
// reste — authentification, normalisation, insertion, attribution —
// ne bouge pas.
//
//   POST /lead-entrant?source=systeme&cle=…   webhook systeme.io
//   POST /lead-entrant?source=generique&cle=… n'importe quel outil
//   GET  /lead-entrant?hub.mode=subscribe…    vérification Meta
//   POST /lead-entrant  (signé X-Hub-Signature-256)  Meta Lead Ads
//
// Meta est prêt mais dort : il faut la permission leads_retrieval,
// qui suppose la Business Verification. Le jour où elle tombe, il n'y
// a qu'une URL à coller dans la configuration de la Page.
//
// Aucune authentification d'utilisateur ici : un webhook n'ouvre pas
// de session. La preuve d'origine est donc le secret partagé pour
// systeme.io, la signature HMAC pour Meta. Sans l'un ou l'autre, on
// refuse — sinon n'importe qui pourrait remplir le pipeline de
// l'agence de fiches inventées.
//
// ═══════════════════════════════════════════════════════════════

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const SUPABASE_URL     = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

// À définir dans les secrets Supabase, jamais dans le dépôt.
const CLE_WEBHOOK   = Deno.env.get("LEAD_WEBHOOK_SECRET") ?? "";
const META_VERIFY   = Deno.env.get("META_VERIFY_TOKEN")   ?? "";
const META_SECRET   = Deno.env.get("META_APP_SECRET")     ?? "";
const META_TOKEN    = Deno.env.get("META_PAGE_TOKEN")     ?? "";
const ORG_SLUG      = Deno.env.get("LEAD_ORG_SLUG")       ?? "manalex";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
  "Access-Control-Allow-Headers": "content-type, x-hub-signature-256",
};

const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
  auth: { autoRefreshToken: false, persistSession: false },
});

interface Lead {
  prenom: string;
  nom: string;
  tel?: string;
  email?: string;
  source: string;
  bien?: string;
  ville?: string;
  note?: string;
  reference?: string;   // identifiant chez la source, pour ne pas doublonner
}

function json(d: unknown, s = 200) {
  return new Response(JSON.stringify(d), {
    status: s, headers: { ...CORS, "Content-Type": "application/json" },
  });
}

// Les formulaires publicitaires livrent rarement prénom et nom
// séparés : le plus souvent un seul champ « full name ».
function couperNom(complet: string): { prenom: string; nom: string } {
  const bouts = String(complet ?? "").trim().split(/\s+/).filter(Boolean);
  if (!bouts.length) return { prenom: "Lead", nom: "sans nom" };
  if (bouts.length === 1) return { prenom: bouts[0], nom: bouts[0] };
  return { prenom: bouts[0], nom: bouts.slice(1).join(" ") };
}

// Les sources écrivent leurs champs comme elles veulent. Plutôt que
// d'exiger un format, on accepte les noms courants.
function normaliser(c: Record<string, unknown>, source: string): Lead {
  const pioche = (...cles: string[]) => {
    for (const k of cles) {
      for (const [kk, vv] of Object.entries(c)) {
        if (kk.toLowerCase().replace(/[\s_-]/g, "") === k && vv) return String(vv).trim();
      }
    }
    return "";
  };

  const complet = pioche("fullname", "name", "nomcomplet", "nom");
  let prenom = pioche("firstname", "prenom", "prénom");
  let nom    = pioche("lastname", "surname", "nomdefamille");

  if (!prenom && complet) ({ prenom, nom } = couperNom(complet));
  if (!nom) nom = prenom || "sans nom";

  return {
    prenom: prenom || "Lead",
    nom,
    tel:   pioche("phone", "phonenumber", "tel", "telephone", "téléphone", "mobile"),
    email: pioche("email", "mail", "courriel"),
    bien:  pioche("bien", "property", "typedebien", "projet", "message"),
    // La ville décide qui rappelle : un commercial ne se déplace pas
    // à quarante minutes pour une estimation. C'est la première chose
    // qu'on regarde sur une fiche.
    ville: pioche("ville", "city", "commune", "localite", "localité", "secteur", "zone", "codepostal"),
    note:  pioche("note", "commentaire", "comments"),
    source,
    reference: pioche("leadid", "id", "reference"),
  };
}

// Comparaison à temps constant : une comparaison ordinaire s'arrête au
// premier caractère différent, ce qui laisse deviner le secret par la
// mesure du temps de réponse.
function memeSecret(a: string, b: string): boolean {
  if (!a || !b || a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

async function signatureMetaValide(corps: string, entete: string | null): Promise<boolean> {
  if (!META_SECRET || !entete?.startsWith("sha256=")) return false;
  const cle = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(META_SECRET),
    { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = await crypto.subtle.sign("HMAC", cle, new TextEncoder().encode(corps));
  const attendu = Array.from(new Uint8Array(sig))
    .map((b) => b.toString(16).padStart(2, "0")).join("");
  return memeSecret(attendu, entete.slice(7));
}

// Meta n'envoie pas le lead, seulement son identifiant : il faut
// aller le chercher, jeton de Page en main.
async function lireLeadMeta(leadgenId: string): Promise<Record<string, unknown> | null> {
  if (!META_TOKEN) return null;
  const r = await fetch(
    `https://graph.facebook.com/v21.0/${leadgenId}?access_token=${encodeURIComponent(META_TOKEN)}`);
  if (!r.ok) return null;
  const d = await r.json();
  const champs: Record<string, unknown> = {};
  for (const c of d.field_data ?? []) champs[c.name] = (c.values ?? [])[0];
  return champs;
}

async function enregistrer(leads: Lead[]): Promise<{ crees: number; ignores: number }> {
  const { data: org } = await admin
    .from("organisations").select("id").eq("slug", ORG_SLUG).maybeSingle();
  if (!org) throw new Error(`Aucune organisation pour le slug « ${ORG_SLUG} »`);

  let crees = 0, ignores = 0;

  for (const l of leads) {
    // Un webhook peut être rejoué : Meta réémet en cas de time-out, et
    // un doublon dans le vivier fait appeler deux fois la même
    // personne. On écarte sur le téléphone ou l'adresse, sur les
    // dernières 24 h — au-delà, un même contact qui revient est un
    // vrai signal, pas un doublon.
    if (l.tel || l.email) {
      const veille = new Date(Date.now() - 86400000).toISOString();
      let q = admin.from("prospects").select("id")
        .eq("org_id", org.id).gte("created_at", veille).limit(1);
      q = l.tel ? q.eq("tel", l.tel) : q.eq("email", l.email!);
      const { data: deja } = await q;
      if (deja?.length) { ignores++; continue; }
    }

    // etape « nouveau » : le déclencheur d'attribution prend le relais
    // et pose le destinataire par défaut de l'organisation.
    const { error } = await admin.from("prospects").insert({
      org_id: org.id,
      prenom: l.prenom,
      nom: l.nom,
      tel: l.tel || null,
      email: l.email || null,
      bien: l.bien || null,
      secteur: l.ville || null,
      note: l.note || null,
      source: l.source,
      etape: "nouveau",
      type: "acheteur",
    });

    if (error) console.error("insertion:", error.message);
    else crees++;
  }

  return { crees, ignores };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });

  const url = new URL(req.url);

  // ── Vérification d'abonnement Meta (une seule fois, à la config) ──
  if (req.method === "GET") {
    if (url.searchParams.get("hub.mode") === "subscribe" &&
        META_VERIFY && url.searchParams.get("hub.verify_token") === META_VERIFY) {
      return new Response(url.searchParams.get("hub.challenge") ?? "", { status: 200 });
    }
    return new Response("Forbidden", { status: 403 });
  }

  if (req.method !== "POST") return json({ erreur: "Méthode non autorisée" }, 405);

  const brut = await req.text();
  const source = url.searchParams.get("source") ?? "meta";

  try {
    // ── Meta Lead Ads ──
    if (source === "meta") {
      if (!await signatureMetaValide(brut, req.headers.get("x-hub-signature-256"))) {
        return json({ erreur: "Signature invalide" }, 401);
      }
      const corps = JSON.parse(brut);
      const leads: Lead[] = [];
      for (const entree of corps.entry ?? []) {
        for (const ch of entree.changes ?? []) {
          const id = ch.value?.leadgen_id;
          if (!id) continue;
          const champs = await lireLeadMeta(String(id));
          if (champs) leads.push(normaliser(champs, "Facebook Ads"));
        }
      }
      // Toujours 200 : un code d'erreur ferait réémettre Meta en
      // boucle, et désabonnerait la Page au bout de plusieurs échecs.
      const bilan = leads.length ? await enregistrer(leads) : { crees: 0, ignores: 0 };
      return json({ ok: true, ...bilan });
    }

    // ── systeme.io et tout webhook générique ──
    if (!CLE_WEBHOOK || !memeSecret(url.searchParams.get("cle") ?? "", CLE_WEBHOOK)) {
      return json({ erreur: "Clé absente ou invalide" }, 401);
    }

    const corps = JSON.parse(brut);
    // Un envoi peut contenir une fiche ou un lot.
    const brutes: Record<string, unknown>[] =
      Array.isArray(corps) ? corps
      : Array.isArray(corps.leads) ? corps.leads
      : [corps.contact ?? corps.data ?? corps];

    const nom = source === "systeme" ? "systeme.io" : (url.searchParams.get("nom") ?? "Import");
    const bilan = await enregistrer(brutes.map((c) => normaliser(c, nom)));
    return json({ ok: true, ...bilan });

  } catch (e) {
    console.error(e);
    return json({ erreur: String((e as Error).message ?? e) }, 500);
  }
});
