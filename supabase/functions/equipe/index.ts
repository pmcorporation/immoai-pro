// ═══════════════════════════════════════════════════════════════
// ÉQUIPE — ouverture et entretien des comptes par la direction
// ═══════════════════════════════════════════════════════════════
//
// Créer un compte exige la clé de service. Cette clé contourne le RLS
// intégralement : elle ne peut donc jamais descendre dans un
// navigateur, et rien de ce qui la détient ne doit croire l'appelant
// sur parole.
//
// D'où la règle qui structure ce fichier : l'identité de l'appelant
// n'est JAMAIS lue dans le corps de la requête. Elle est extraite du
// jeton par Supabase, puis confrontée à la base via
// peut_administrer_equipe(). Un agent qui rejouerait cet appel en
// s'attribuant le rôle « direction » dans le JSON se ferait refuser :
// le JSON ne porte aucune identité.
//
// Le mot de passe posé ici est provisoire. L'agent le remplace à sa
// première connexion — voir mdp_a_changer.
//
// ═══════════════════════════════════════════════════════════════

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const SUPABASE_URL      = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY  = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON_KEY          = Deno.env.get("SUPABASE_ANON_KEY")!;

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Max-Age": "86400",
};

type Action = "creer" | "reinitialiser" | "desactiver" | "reactiver";

interface Corps {
  action: Action;
  email?: string;
  prenom?: string;
  nom?: string;
  role?: "direction" | "agent";
  motdepasse?: string;
  membre_id?: string;   // utilisateur_id de la cible
}

function repondre(donnees: unknown, statut = 200) {
  return new Response(JSON.stringify(donnees), {
    status: statut,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

function erreur(message: string, statut = 400) {
  return repondre({ erreur: message }, statut);
}

// Un mot de passe provisoire doit résister à une tentative opportuniste
// sans être impossible à dicter au téléphone. Douze caractères sans
// les glyphes qu'on confond à l'oral (0/O, 1/l/I).
function motDePasseProvisoire(): string {
  const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789";
  const octets = new Uint32Array(12);
  crypto.getRandomValues(octets);
  return Array.from(octets, (n) => alphabet[n % alphabet.length]).join("");
}

function motDePasseAcceptable(m: string): string | null {
  if (m.length < 10) return "Le mot de passe doit faire au moins 10 caractères.";
  if (!/[a-z]/.test(m) || !/[A-Z]/.test(m)) return "Il faut des minuscules et des majuscules.";
  if (!/[0-9]/.test(m)) return "Il faut au moins un chiffre.";
  return null;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST")    return erreur("Méthode non autorisée", 405);

  const autorisation = req.headers.get("Authorization");
  if (!autorisation) return erreur("Authentification requise", 401);

  // ── 1. Qui appelle, vraiment ────────────────────────────────
  // Ce client-ci porte le jeton de l'appelant, pas la clé de
  // service : getUser() ne peut renvoyer que l'utilisateur réel.
  const clientAppelant = createClient(SUPABASE_URL, ANON_KEY, {
    global: { headers: { Authorization: autorisation } },
  });

  const { data: { user: acteur }, error: errUser } = await clientAppelant.auth.getUser();
  if (errUser || !acteur) return erreur("Session invalide", 401);

  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  // ── 2. Son organisation et son droit d'agir ─────────────────
  const { data: ligneActeur } = await admin
    .from("membres")
    .select("org_id")
    .eq("utilisateur_id", acteur.id)
    .is("desactive_le", null)
    .maybeSingle();

  if (!ligneActeur) return erreur("Vous n'appartenez à aucune organisation active", 403);
  const orgId = ligneActeur.org_id;

  const { data: autorise } = await admin.rpc("peut_administrer_equipe", {
    p_acteur: acteur.id,
    p_org: orgId,
  });

  if (autorise !== true) {
    return erreur("Seule la direction peut gérer les comptes de l'équipe", 403);
  }

  let corps: Corps;
  try { corps = await req.json(); }
  catch { return erreur("Corps de requête illisible"); }

  // ── 3. Les actions ──────────────────────────────────────────
  switch (corps.action) {

    case "creer": {
      const email  = (corps.email ?? "").trim().toLowerCase();
      const prenom = (corps.prenom ?? "").trim();
      const nom    = (corps.nom ?? "").trim();
      const role   = corps.role === "direction" ? "direction" : "agent";

      if (!email.includes("@")) return erreur("Adresse électronique invalide");
      if (!prenom || !nom)      return erreur("Prénom et nom sont requis");

      const motdepasse = corps.motdepasse?.trim() || motDePasseProvisoire();
      const refus = motDePasseAcceptable(motdepasse);
      if (refus) return erreur(refus);

      // email_confirm : le compte naît déjà confirmé. C'est ce qui
      // évite à l'agent le moindre courriel de Supabase — il ne doit
      // rien avoir à valider, rien à cliquer.
      const { data: cree, error: errCreation } = await admin.auth.admin.createUser({
        email,
        password: motdepasse,
        email_confirm: true,
        user_metadata: { prenom, nom },
      });

      if (errCreation || !cree?.user) {
        const m = errCreation?.message ?? "";
        if (/already|exist/i.test(m)) return erreur("Un compte existe déjà pour cette adresse", 409);
        return erreur(`Création impossible : ${m}`, 500);
      }

      const { error: errMembre } = await admin.from("membres").insert({
        org_id: orgId,
        utilisateur_id: cree.user.id,
        role,
        prenom,
        nom,
        mdp_a_changer: true,
        invite_par: acteur.id,
      });

      if (errMembre) {
        // Sans cette reprise, un échec ici laisserait un compte
        // d'authentification orphelin : connectable, rattaché à
        // aucune organisation, invisible dans l'écran Équipe.
        await admin.auth.admin.deleteUser(cree.user.id);
        return erreur(`Rattachement impossible : ${errMembre.message}`, 500);
      }

      // Le mot de passe ne repart que si le serveur l'a engendré.
      // Celui que la direction a saisi, elle le connaît déjà ; le
      // renvoyer ne ferait que le promener davantage.
      return repondre({
        ok: true,
        utilisateur_id: cree.user.id,
        motdepasse_genere: corps.motdepasse ? null : motdepasse,
      });
    }

    case "reinitialiser": {
      if (!corps.membre_id) return erreur("Membre non désigné");

      const motdepasse = corps.motdepasse?.trim() || motDePasseProvisoire();
      const refus = motDePasseAcceptable(motdepasse);
      if (refus) return erreur(refus);

      // Vérifier l'appartenance avant d'agir : sans ce garde, une
      // direction pourrait réinitialiser le compte d'une personne
      // d'une autre organisation en devinant son identifiant.
      const { data: cible } = await admin
        .from("membres").select("utilisateur_id")
        .eq("utilisateur_id", corps.membre_id).eq("org_id", orgId).maybeSingle();
      if (!cible) return erreur("Ce membre n'appartient pas à votre organisation", 403);

      const { error } = await admin.auth.admin.updateUserById(corps.membre_id, {
        password: motdepasse,
      });
      if (error) return erreur(`Réinitialisation impossible : ${error.message}`, 500);

      await admin.from("membres")
        .update({ mdp_a_changer: true, updated_at: new Date().toISOString() })
        .eq("utilisateur_id", corps.membre_id).eq("org_id", orgId);

      return repondre({ ok: true, motdepasse_genere: corps.motdepasse ? null : motdepasse });
    }

    case "desactiver":
    case "reactiver": {
      if (!corps.membre_id) return erreur("Membre non désigné");
      if (corps.membre_id === acteur.id) {
        return erreur("Vous ne pouvez pas vous désactiver vous-même", 400);
      }

      const sortant = corps.action === "desactiver";

      const { data: cible } = await admin
        .from("membres").select("role")
        .eq("utilisateur_id", corps.membre_id).eq("org_id", orgId).maybeSingle();
      if (!cible) return erreur("Ce membre n'appartient pas à votre organisation", 403);
      if (sortant && cible.role === "proprietaire") {
        return erreur("Le propriétaire de l'organisation ne peut pas être désactivé", 400);
      }

      const { error } = await admin.from("membres")
        .update({
          desactive_le: sortant ? new Date().toISOString() : null,
          updated_at: new Date().toISOString(),
        })
        .eq("utilisateur_id", corps.membre_id).eq("org_id", orgId);

      if (error) return erreur(error.message, 500);

      // Interdire la session en plus de retirer les droits : sans
      // cela, un onglet resté ouvert continuerait de fonctionner
      // jusqu'à l'expiration de son jeton.
      await admin.auth.admin.updateUserById(corps.membre_id, {
        ban_duration: sortant ? "876000h" : "none",
      });

      return repondre({ ok: true });
    }

    default:
      return erreur("Action inconnue");
  }
});
