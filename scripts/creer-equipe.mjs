// ═══════════════════════════════════════════════════════════════
// OUVERTURE DES COMPTES DE L'ÉQUIPE — passage unique
// ═══════════════════════════════════════════════════════════════
//
//   node scripts/creer-equipe.mjs            (aperçu, n'écrit rien)
//   node scripts/creer-equipe.mjs --appliquer
//
// Ce que fait l'écran Équipe, en une fois, pour l'installation
// initiale. Ensuite tout se passe dans l'application.
//
// La clé de service est lue depuis .env, jamais écrite ici et jamais
// versionnée. Elle traverse le RLS intégralement : ce fichier est le
// seul endroit du dépôt qui la touche, et il ne tourne qu'à la main.
//
// Les mots de passe sont PROVISOIRES. Chacun choisit le sien à sa
// première connexion — c'est ce qui fait qu'« Untel a traité ce
// lead » désigne bien Untel.
//
// ═══════════════════════════════════════════════════════════════

import { readFileSync, writeFileSync } from 'node:fs';
import { randomInt } from 'node:crypto';

const RACINE = new URL('..', import.meta.url).pathname;
const URL_SB = 'https://wwqccgacezbzkbaptyup.supabase.co';

// ── L'équipe, telle qu'elle est publiée sur le site de l'agence ──
const EQUIPE = [
  { prenom: 'Alexis',   nom: 'Lacroix',          role: 'proprietaire', mail: 'alexis@manalex-immobilier.fr'   },
  { prenom: 'Isabelle', nom: 'Lacroix',          role: 'direction',    mail: 'isabelle@manalex-immobilier.fr' },
  { prenom: 'Didier',   nom: 'Lacroix',          role: 'agent',        mail: 'didier@manalex-immobilier.fr'   },
  { prenom: 'Simon',    nom: 'Lardet',           role: 'agent',        mail: 'simon@manalex-immobilier.fr'    },
  { prenom: 'Frédéric', nom: 'Billet',           role: 'agent',        mail: 'frederic@manalex-immobilier.fr' },
  { prenom: 'Tiffani',  nom: 'Barlerin Portier', role: 'agent',        mail: 'tiffani@manalex-immobilier.fr'  },
];

// Sans les glyphes qu'on fait répéter au téléphone : ni O/0, ni I/l/1.
const ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789';
function motDePasse(n = 12) {
  let m = '';
  for (let i = 0; i < n; i++) m += ALPHABET[randomInt(ALPHABET.length)];
  // Garantir la robustesse exigée côté serveur plutôt que d'espérer
  // que le hasard la produise.
  if (!/[A-Z]/.test(m) || !/[a-z]/.test(m) || !/[0-9]/.test(m)) return motDePasse(n);
  return m;
}

function cle() {
  let brut;
  try { brut = readFileSync(RACINE + '.env', 'utf8'); }
  catch { throw new Error('Fichier .env introuvable à la racine du projet.'); }
  const m = brut.match(/^SUPABASE_SERVICE_ROLE_KEY\s*=\s*(.+)$/m);
  if (!m) throw new Error('SUPABASE_SERVICE_ROLE_KEY absente du .env');
  const k = m[1].trim().replace(/^["']|["']$/g, '');
  if (k.length < 40) throw new Error('La clé lue semble tronquée.');
  return k;
}

async function api(chemin, options, k) {
  const r = await fetch(URL_SB + chemin, {
    ...options,
    headers: {
      'apikey': k,
      'Authorization': 'Bearer ' + k,
      'Content-Type': 'application/json',
      ...(options.headers || {}),
    },
  });
  const texte = await r.text();
  let corps; try { corps = JSON.parse(texte); } catch { corps = texte; }
  if (!r.ok) throw new Error(`${r.status} — ${typeof corps === 'string' ? corps : JSON.stringify(corps)}`);
  return corps;
}

const appliquer = process.argv.includes('--appliquer');

console.log(appliquer ? '\n▶ Création réelle\n' : '\n▶ Aperçu — rien ne sera écrit. Ajouter --appliquer pour agir.\n');

// L'aperçu doit fonctionner sans clé : c'est justement ce qu'on
// regarde avant d'aller la chercher.
const k = appliquer ? cle() : null;
const resultats = [];

for (const p of EQUIPE) {
  const mdp = motDePasse();

  if (!appliquer) {
    resultats.push({ ...p, mdp, etat: 'à créer' });
    continue;
  }

  try {
    // email_confirm : le compte naît confirmé, donc aucun courriel
    // ne part. L'équipe ne doit jamais croiser Supabase.
    const u = await api('/auth/v1/admin/users', {
      method: 'POST',
      body: JSON.stringify({
        email: p.mail,
        password: mdp,
        email_confirm: true,
        user_metadata: { prenom: p.prenom, nom: p.nom },
      }),
    }, k);

    resultats.push({ ...p, mdp, id: u.id, etat: 'créé' });
    console.log(`  ✔ ${p.prenom} ${p.nom}`);
  } catch (e) {
    const deja = /already|exist|duplicate/i.test(e.message);
    resultats.push({ ...p, mdp: deja ? '—' : mdp, etat: deja ? 'existait déjà' : 'ÉCHEC : ' + e.message });
    console.log(`  ${deja ? '•' : '✖'} ${p.prenom} ${p.nom} — ${deja ? 'existait déjà' : e.message}`);
  }
}

// ── Sortie ──
const large = (s, n) => String(s).padEnd(n);
let sortie = '\nIDENTIFIANTS — MANALEX IMMOBILIER\n'
           + 'Mots de passe PROVISOIRES : chacun choisit le sien à sa première connexion.\n'
           + 'Supprimez ce fichier une fois les identifiants transmis.\n\n'
           + large('NOM', 26) + large('ADRESSE', 38) + large('MOT DE PASSE', 16) + 'RÔLE\n'
           + '─'.repeat(94) + '\n';

for (const r of resultats) {
  sortie += large(r.prenom + ' ' + r.nom, 26) + large(r.mail, 38) + large(r.mdp, 16) + r.role
          + (r.etat.startsWith('créé') || r.etat === 'à créer' ? '' : `   [${r.etat}]`) + '\n';
}

console.log(sortie);

if (appliquer) {
  const chemin = RACINE + 'identifiants-equipe.txt';
  writeFileSync(chemin, sortie, 'utf8');
  console.log('Écrit dans identifiants-equipe.txt (ignoré par git).');
  console.log('Reste à faire, une fois dans le SQL Editor :');
  console.log("  select public.installer_agence('alexis@manalex-immobilier.fr', 'Manalex Immobilier', 8, 'agency');\n");
}
