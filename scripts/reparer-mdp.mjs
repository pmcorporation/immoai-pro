// Réinitialise les mots de passe par l'API d'administration, seule
// voie qui fabrique un compte tel que le service d'authentification
// l'attend. L'écriture directe dans auth.users laissait des colonnes
// à NULL, et la connexion échouait malgré un mot de passe juste.
import { readFileSync, writeFileSync } from 'node:fs';
import { randomInt } from 'node:crypto';
const RACINE = new URL('..', import.meta.url).pathname;
const URL_SB = 'https://wwqccgacezbzkbaptyup.supabase.co';
const K = readFileSync(RACINE + '.env', 'utf8').match(/^SUPABASE_SERVICE_ROLE_KEY\s*=\s*(.+)$/m)[1].trim();
const H = { apikey: K, Authorization: 'Bearer ' + K, 'Content-Type': 'application/json' };

const EQUIPE = ['alexis','isabelle','didier','simon','frederic','tiffani']
  .map(p => p + '@manalex-immobilier.fr');

const A = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789';
const mdp = (n=12) => { let m=''; for(let i=0;i<n;i++) m+=A[randomInt(A.length)];
  return (/[A-Z]/.test(m)&&/[a-z]/.test(m)&&/[0-9]/.test(m)) ? m : mdp(n); };

// L'API admin ne cherche pas par adresse : on liste puis on associe.
const liste = await (await fetch(URL_SB + '/auth/v1/admin/users?per_page=200', { headers: H })).json();
const par_mail = new Map((liste.users||[]).map(u => [String(u.email).toLowerCase(), u.id]));

const out = [];
for (const mail of EQUIPE) {
  const id = par_mail.get(mail);
  if (!id) { out.push({ mail, mdp: '—', etat: 'compte introuvable' }); continue; }
  const m = mdp();
  const r = await fetch(URL_SB + '/auth/v1/admin/users/' + id, {
    method: 'PUT', headers: H,
    body: JSON.stringify({ password: m, email_confirm: true }),
  });
  out.push({ mail, mdp: m, etat: r.ok ? 'ok' : 'ÉCHEC ' + r.status + ' ' + (await r.text()).slice(0,120) });
}

// Vérification réelle : on tente la connexion avec la clé publique,
// exactement comme le fera le navigateur.
const ANON = readFileSync(RACINE + 'app/index.html','utf8').match(/const SUPABASE_KEY = '([^']+)'/)[1];
for (const o of out) {
  if (o.etat !== 'ok') continue;
  const r = await fetch(URL_SB + '/auth/v1/token?grant_type=password', {
    method: 'POST', headers: { apikey: ANON, 'Content-Type': 'application/json' },
    body: JSON.stringify({ email: o.mail, password: o.mdp }),
  });
  const d = await r.json();
  o.connexion = d.access_token ? 'CONNEXION VÉRIFIÉE' : ('refus : ' + (d.error_code || d.msg));
}

const l = (s,n) => String(s).padEnd(n);
let t = '\n' + l('ADRESSE',38) + l('MOT DE PASSE',16) + 'CONNEXION\n' + '─'.repeat(78) + '\n';
for (const o of out) t += l(o.mail,38) + l(o.mdp,16) + (o.connexion || o.etat) + '\n';
console.log(t);
writeFileSync(RACINE + 'identifiants-equipe.txt', t, 'utf8');
