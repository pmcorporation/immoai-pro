// Fabrique le bloc SQL d'ouverture des comptes, mots de passe compris.
//   node scripts/generer-sql-equipe.mjs
// Écrit creer-equipe.sql (ignoré par git) et affiche la liste à dicter.

import { writeFileSync } from 'node:fs';
import { randomInt } from 'node:crypto';

const RACINE = new URL('..', import.meta.url).pathname;

const EQUIPE = [
  { prenom: 'Alexis',   nom: 'Lacroix',          role: 'proprietaire', mail: 'alexis@manalex-immobilier.fr'   },
  { prenom: 'Isabelle', nom: 'Lacroix',          role: 'direction',    mail: 'isabelle@manalex-immobilier.fr' },
  { prenom: 'Didier',   nom: 'Lacroix',          role: 'agent',        mail: 'didier@manalex-immobilier.fr'   },
  { prenom: 'Simon',    nom: 'Lardet',           role: 'agent',        mail: 'simon@manalex-immobilier.fr'    },
  { prenom: 'Frédéric', nom: 'Billet',           role: 'agent',        mail: 'frederic@manalex-immobilier.fr' },
  { prenom: 'Tiffani',  nom: 'Barlerin Portier', role: 'agent',        mail: 'tiffani@manalex-immobilier.fr'  },
];

// Ni O/0 ni I/l/1 : ces mots de passe se dictent au téléphone.
const A = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789';
function mdp(n = 12) {
  let m = '';
  for (let i = 0; i < n; i++) m += A[randomInt(A.length)];
  if (!/[A-Z]/.test(m) || !/[a-z]/.test(m) || !/[0-9]/.test(m)) return mdp(n);
  return m;
}

const avecMdp = EQUIPE.map((p) => ({ ...p, mdp: mdp() }));
const q = (s) => "'" + String(s).replace(/'/g, "''") + "'";

const lignes = avecMdp
  .map((p) => `      (${q(p.mail)}, ${q(p.prenom)}, ${q(p.nom)}, ${q(p.role)}, ${q(p.mdp)})`)
  .join(',\n');

const sql = `-- ═══════════════════════════════════════════════════════════════
-- OUVERTURE DES COMPTES — MANALEX IMMOBILIER
-- ═══════════════════════════════════════════════════════════════
--
-- À coller dans le SQL Editor de Supabase, comme les précédents.
--
-- Relançable sans risque : un compte déjà présent n'est pas recréé,
-- seuls son rôle et son rattachement sont remis d'équerre.
--
-- Les mots de passe sont provisoires. Chacun choisit le sien à sa
-- première connexion, et personne ne peut alors se connecter à la
-- place d'un autre.
-- ═══════════════════════════════════════════════════════════════

begin;

do $manalex$
declare
  v_org uuid;
  v_id  uuid;
  r     record;
begin
  -- ── 1. L'organisation ────────────────────────────────────────
  select id into v_org from public.organisations
   where lower(nom) = 'manalex immobilier' limit 1;

  if v_org is null then
    insert into public.organisations (nom, type, plan, sieges)
    values ('Manalex Immobilier', 'agence', 'agency', 8)
    returning id into v_org;
  else
    update public.organisations
       set type = 'agence', plan = 'agency', sieges = greatest(sieges, 8)
     where id = v_org;
  end if;

  -- ── 2. Les comptes ───────────────────────────────────────────
  for r in
    select * from (values
${lignes}
    ) as t(email, prenom, nom, role, mdp)
  loop
    select id into v_id from auth.users where lower(email) = lower(r.email);

    if v_id is null then
      v_id := extensions.gen_random_uuid();

      -- email_confirmed_at posé d'emblée : aucun courriel de
      -- validation ne part, l'équipe ne croise jamais Supabase.
      insert into auth.users (
        instance_id, id, aud, role, email, encrypted_password,
        email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
        created_at, updated_at)
      values (
        '00000000-0000-0000-0000-000000000000', v_id,
        'authenticated', 'authenticated', lower(r.email),
        extensions.crypt(r.mdp, extensions.gen_salt('bf')),
        now(),
        '{"provider":"email","providers":["email"]}'::jsonb,
        jsonb_build_object('prenom', r.prenom, 'nom', r.nom),
        now(), now());

      -- Sans cette ligne, GoTrue ne reconnaît pas le fournisseur
      -- « email » et la connexion échoue malgré le mot de passe juste.
      insert into auth.identities (
        id, user_id, provider_id, identity_data, provider,
        last_sign_in_at, created_at, updated_at)
      values (
        extensions.gen_random_uuid(), v_id, v_id::text,
        jsonb_build_object('sub', v_id::text, 'email', lower(r.email),
                           'email_verified', true),
        'email', now(), now(), now());
    end if;

    -- ── 3. Le profil ───────────────────────────────────────────
    insert into public.profiles (id, email, prenom, nom)
    values (v_id, lower(r.email), r.prenom, r.nom)
    on conflict (id) do update
      set prenom = excluded.prenom, nom = excluded.nom;

    -- ── 4. Le rattachement ─────────────────────────────────────
    -- Le déclencheur profils_org_par_defaut donne une organisation
    -- solo à tout nouveau profil. On défait ce réflexe : ici tout le
    -- monde appartient à Manalex.
    delete from public.membres where utilisateur_id = v_id and org_id <> v_org;

    insert into public.membres (org_id, utilisateur_id, role, prenom, nom, mdp_a_changer)
    values (v_org, v_id, r.role, r.prenom, r.nom, true)
    on conflict (org_id, utilisateur_id) do update
      set role = excluded.role, prenom = excluded.prenom, nom = excluded.nom;
  end loop;

  -- ── 5. Les organisations restées vides ───────────────────────
  delete from public.organisations o
   where not exists (select 1 from public.membres m where m.org_id = o.id)
     and o.id <> v_org;
end
$manalex$;

commit;

-- ═══ Vérification — doit afficher six lignes ═══
select m.prenom, m.nom, m.role, u.email, m.mdp_a_changer
  from public.membres m
  join auth.users u on u.id = m.utilisateur_id
  join public.organisations o on o.id = m.org_id
 where lower(o.nom) = 'manalex immobilier'
 order by case m.role when 'proprietaire' then 1 when 'direction' then 2 else 3 end,
          m.prenom;
`;

writeFileSync(RACINE + 'creer-equipe.sql', sql, 'utf8');

const l = (s, n) => String(s).padEnd(n);
console.log('\n  Écrit : creer-equipe.sql\n');
console.log('  ' + l('NOM', 26) + l('ADRESSE', 38) + 'MOT DE PASSE');
console.log('  ' + '─'.repeat(80));
for (const p of avecMdp) {
  console.log('  ' + l(p.prenom + ' ' + p.nom, 26) + l(p.mail, 38) + p.mdp);
}
console.log('');
