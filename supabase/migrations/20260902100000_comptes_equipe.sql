-- ═══════════════════════════════════════════════════════════════
-- 12 · COMPTES DE L'ÉQUIPE — CRÉÉS PAR LA DIRECTION
-- ═══════════════════════════════════════════════════════════════
--
-- L'invitation par lien laissait l'agent choisir son mot de passe et
-- le faisait passer par les écrans de Supabase. Une agence veut
-- l'inverse : la direction ouvre le compte, l'agent se connecte, et
-- il n'entend jamais parler du fournisseur d'authentification.
--
-- Le mot de passe posé par la direction est donc **provisoire**.
-- L'agent le remplace à sa première connexion, et personne d'autre
-- que lui ne connaît le définitif. C'est ce qui distingue un compte
-- ouvert par un tiers d'un compte détenu par un tiers — et c'est ce
-- qui rend l'imputabilité réelle : « ce lead a été traité par Simon »
-- ne veut rien dire si le gérant peut se connecter en tant que Simon.
--
-- La création elle-même n'est pas ici : elle exige la clé de service,
-- qui ne descend jamais dans un navigateur. Elle vit dans la fonction
-- edge `equipe`, qui appelle `peut_administrer_equipe()` ci-dessous
-- avant d'agir.
--
-- ═══════════════════════════════════════════════════════════════

begin;

-- ═══ 1. IDENTITÉ ET ÉTAT DU MEMBRE ═════════════════════════════

-- Le prénom et le nom vivaient dans les métadonnées de auth.users,
-- illisibles en SQL sans passer par la clé de service. L'écran de
-- connexion et l'attribution des leads en ont besoin : ils
-- descendent dans la table métier.
alter table public.membres add column if not exists prenom text;
alter table public.membres add column if not exists nom    text;

-- Vrai tant que l'agent n'a pas remplacé le mot de passe provisoire.
alter table public.membres add column if not exists mdp_a_changer boolean not null default false;

-- Départ d'un collaborateur : on désactive, on ne supprime pas. Ses
-- leads, ses mandats et ses rendez-vous doivent rester attribuables,
-- sinon l'historique de l'agence se troue à chaque départ.
alter table public.membres add column if not exists desactive_le timestamptz;

comment on column public.membres.mdp_a_changer is
  'Mot de passe encore provisoire : la direction l''a posé, l''agent ne l''a pas remplacé.';
comment on column public.membres.desactive_le is
  'Départ du collaborateur. Jamais de suppression : ses leads doivent rester attribuables.';

-- ═══ 2. QUI PEUT ADMINISTRER L'ÉQUIPE ══════════════════════════

-- La fonction edge détient la clé de service : elle contourne le RLS
-- par construction. Elle ne peut donc pas se fier au RLS pour savoir
-- si l'appelant a le droit d'agir — c'est à cette fonction de le lui
-- dire, à partir de l'identifiant réel extrait du jeton.
--
-- En plpgsql et non en sql : le corps n'est vérifié qu'à l'exécution,
-- ce qui évite toute contrainte d'ordre de création.
create or replace function public.peut_administrer_equipe(p_acteur uuid, p_org uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_role text;
begin
  select role into v_role
    from public.membres
   where utilisateur_id = p_acteur
     and org_id         = p_org
     and desactive_le is null;

  return coalesce(v_role in ('proprietaire', 'direction'), false);
end;
$$;

comment on function public.peut_administrer_equipe(uuid, uuid) is
  'Vrai si cet utilisateur dirige cette organisation. Appelée par la fonction edge « equipe ».';

revoke all on function public.peut_administrer_equipe(uuid, uuid) from public;
grant execute on function public.peut_administrer_equipe(uuid, uuid) to service_role;

-- ═══ 3. ANNUAIRE DE L'ÉCRAN DE CONNEXION ═══════════════════════

-- Le slug désigne une organisation sans exposer son identifiant. Il
-- est posé avant la fonction qui le lit : les corps plpgsql ne sont
-- vérifiés qu'à l'exécution, mais s'appuyer là-dessus rend l'ordre du
-- fichier trompeur pour qui le relit.
alter table public.organisations add column if not exists slug text;

create unique index if not exists organisations_slug_unique
  on public.organisations (slug) where slug is not null;

-- L'écran de connexion affiche les visages avant toute
-- authentification : il est donc lu par un client anonyme.
--
-- Ce qui sort ici est délibérément pauvre — prénom, nom, fonction,
-- adresse. Rien d'autre. Ces informations sont déjà publiées sur le
-- site de l'agence ; ce sont les seules dont l'écran a besoin.
--
-- Une fonction plutôt qu'une vue : une vue lisible par « anon »
-- exposerait l'annuaire de **toutes** les organisations d'un coup.
-- Ici, une organisation à la fois, désignée explicitement.
create or replace function public.annuaire_connexion(p_slug text default null)
returns table (prenom text, nom text, role text, email text)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_org uuid;
begin
  if p_slug is null then
    -- Déploiement mono-agence : s'il n'y a qu'une organisation, elle
    -- va de soi. Au-delà, il faut la nommer — ne rien renvoyer vaut
    -- mieux que livrer l'annuaire du voisin.
    if (select count(*) from public.organisations) <> 1 then
      return;
    end if;
    select o.id into v_org from public.organisations o;
  else
    select o.id into v_org from public.organisations o where o.slug = p_slug;
  end if;

  if v_org is null then return; end if;

  return query
    select m.prenom, m.nom, m.role, u.email::text
      from public.membres m
      join auth.users u on u.id = m.utilisateur_id
     where m.org_id = v_org
       and m.desactive_le is null
       and m.prenom is not null
     order by
       case m.role when 'proprietaire' then 1 when 'direction' then 2 else 3 end,
       m.prenom;
end;
$$;

comment on function public.annuaire_connexion(text) is
  'Trombinoscope de l''écran de connexion. Volontairement pauvre : prénom, nom, fonction, adresse.';

revoke all on function public.annuaire_connexion(text) from public;
grant execute on function public.annuaire_connexion(text) to anon, authenticated;

-- ═══ 4. L'AGENT DÉCLARE AVOIR CHANGÉ SON MOT DE PASSE ══════════

-- Le changement lui-même passe par updateUser() côté client, qui
-- exige la session de l'intéressé — donc nul ne peut changer le mot
-- de passe d'un autre. Reste à lever le drapeau, et seulement pour
-- soi : d'où le auth.uid() en dur dans le where.
create or replace function public.mdp_change()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.membres
     set mdp_a_changer = false,
         updated_at    = now()
   where utilisateur_id = auth.uid();
end;
$$;

comment on function public.mdp_change() is
  'L''agent signale avoir remplacé son mot de passe provisoire. N''agit que sur sa propre ligne.';

revoke all on function public.mdp_change() from public;
grant execute on function public.mdp_change() to authenticated;

-- ═══ 5. LES MEMBRES DÉSACTIVÉS PERDENT LA MAIN ═════════════════

-- est_direction() décidait sans regarder les départs : un gérant
-- désactivé aurait conservé la vue d'ensemble.
create or replace function public.est_direction()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (select role in ('proprietaire', 'direction')
       from public.membres
      where utilisateur_id = auth.uid()
        and desactive_le is null
      limit 1),
    false);
$$;

commit;
