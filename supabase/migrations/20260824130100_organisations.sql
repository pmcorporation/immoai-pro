-- ═══════════════════════════════════════════════════════════════
-- 02 · ORGANISATIONS, MEMBRES ET CONTEXTE RLS
-- ═══════════════════════════════════════════════════════════════
--
-- Modèle métier :
--   • La licence appartient à l'ORGANISATION, pas à l'utilisateur.
--   • Un agent indépendant est une organisation d'une seule personne.
--     Pas de cas particulier dans le code : un seul modèle de droits
--     pour l'indépendant comme pour l'agence de quinze commerciaux.
--   • Trois rôles : proprietaire (paie), direction (voit et distribue),
--     agent (voit uniquement ce qui lui est attribué).
--
-- Ordre imposé par PostgreSQL : les tables d'abord, les fonctions de
-- contexte ensuite. Une fonction `language sql` est analysée dès sa
-- création et refuse de naître si ses tables manquent.
--
-- ═══════════════════════════════════════════════════════════════

begin;

-- ═══ 1. TABLES ═════════════════════════════════════════════════

create table if not exists public.organisations (
  id                      uuid        primary key default extensions.gen_random_uuid(),
  nom                     text        not null check (length(trim(nom)) > 0),
  type                    text        not null default 'solo'
                                      check (type in ('solo', 'agence')),

  -- Facturation : portée ici, plus sur le profil
  plan                    text        not null default 'free'
                                      check (plan in ('free', 'starter', 'pro', 'agency')),
  sieges                  integer     not null default 1 check (sieges between 1 and 500),
  stripe_customer_id      text        unique,
  stripe_subscription_id  text        unique,
  statut_abonnement       text        check (statut_abonnement in
                                        ('active', 'trialing', 'past_due', 'canceled', 'unpaid')),
  abonnement_debute_le    timestamptz,
  abonnement_renouvele_le timestamptz,

  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now()
);

comment on table  public.organisations        is 'Agence ou agent indépendant. Porte la licence et l''abonnement.';
comment on column public.organisations.sieges is 'Nombre de commerciaux autorisés par l''abonnement.';

create table if not exists public.membres (
  org_id          uuid        not null references public.organisations(id) on delete cascade,
  utilisateur_id  uuid        not null references auth.users(id)           on delete cascade,
  role            text        not null default 'agent'
                              check (role in ('proprietaire', 'direction', 'agent')),
  invite_par      uuid        references auth.users(id) on delete set null,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  primary key (org_id, utilisateur_id)
);

comment on table public.membres is
  'Rattachement d''un utilisateur à son organisation, avec son rôle.';

-- Un utilisateur n'appartient qu'à une organisation à la fois : c'est
-- ce qui rend mon_org() déterministe.
create unique index if not exists membres_un_seul_org
  on public.membres (utilisateur_id);

-- Une organisation a exactement un propriétaire.
create unique index if not exists membres_un_seul_proprietaire
  on public.membres (org_id)
  where role = 'proprietaire';

create index if not exists membres_org_idx on public.membres (org_id);

select public.installer_touch('organisations'::text);
select public.installer_touch('membres'::text);

-- RLS activé dès la création, avant toute écriture : un ALTER TABLE
-- est refusé si la table porte des événements de déclencheur différés
-- en attente, ce qui est le cas dès la première insertion.
alter table public.organisations enable row level security;
alter table public.membres enable row level security;

-- ═══ 2. CONTEXTE DE L'UTILISATEUR COURANT ══════════════════════
--
-- Socle de toutes les politiques RLS du schéma. En security definer
-- pour une raison précise : une politique posée sur `membres` qui
-- interrogerait `membres` sans cela partirait en récursion infinie.

create or replace function public.mon_org()
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select org_id from public.membres where utilisateur_id = auth.uid() limit 1;
$$;

create or replace function public.mon_role()
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select role from public.membres where utilisateur_id = auth.uid() limit 1;
$$;

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
      limit 1),
    false);
$$;

-- Plan effectif : celui de l'organisation, jamais celui du profil.
-- Seule source de vérité pour le verrouillage des modules.
create or replace function public.mon_plan()
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (select o.plan
       from public.membres m
       join public.organisations o on o.id = m.org_id
      where m.utilisateur_id = auth.uid()
      limit 1),
    'free');
$$;

comment on function public.mon_org()       is 'Organisation de l''utilisateur courant.';
comment on function public.mon_role()      is 'Rôle de l''utilisateur dans son organisation.';
comment on function public.est_direction() is 'Vrai si propriétaire ou direction.';
comment on function public.mon_plan()      is 'Plan facturé de l''organisation.';

revoke all on function
  public.mon_org(), public.mon_role(),
  public.est_direction(), public.mon_plan()
from public;

grant execute on function
  public.mon_org(), public.mon_role(),
  public.est_direction(), public.mon_plan()
to authenticated;

-- ═══ 3. POLITIQUES ═════════════════════════════════════════════

drop policy if exists organisations_lecture on public.organisations;
drop policy if exists organisations_modification on public.organisations;

create policy organisations_lecture on public.organisations
  for select to authenticated
  using (id = public.mon_org());

-- Les colonnes de facturation ne sont écrites que par le webhook
-- Stripe, qui utilise la clé service_role et n'est pas soumis au RLS.
create policy organisations_modification on public.organisations
  for update to authenticated
  using      (id = public.mon_org() and public.est_direction())
  with check (id = public.mon_org());

drop policy if exists membres_lecture on public.membres;
drop policy if exists membres_direction on public.membres;

-- Chacun voit ses collègues : nécessaire à l'écran d'attribution et
-- à l'affichage du nom du commercial sur une fiche.
create policy membres_lecture on public.membres
  for select to authenticated
  using (org_id = public.mon_org());

create policy membres_direction on public.membres
  for all to authenticated
  using      (org_id = public.mon_org() and public.est_direction())
  with check (org_id = public.mon_org() and public.est_direction());

-- ═══ 4. GARDE-FOUS ═════════════════════════════════════════════

-- Ne pas dépasser le nombre de sièges de l'abonnement.
-- En security definer : sans cela, le RLS masquerait une partie des
-- membres au comptage et le contrôle laisserait passer.
create or replace function public.verifier_sieges()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_occupes integer;
  v_sieges  integer;
begin
  select count(*) into v_occupes from public.membres      where org_id = new.org_id;
  select sieges   into v_sieges  from public.organisations where id     = new.org_id;

  if v_occupes > v_sieges then
    raise exception
      'Organisation complète : % siège(s) sur l''abonnement, % occupé(s). Ajoutez un siège avant d''inviter.',
      v_sieges, v_occupes
      using errcode = 'check_violation';
  end if;

  return new;
end;
$$;

drop trigger if exists membres_verifier_sieges on public.membres;
create constraint trigger membres_verifier_sieges
  after insert on public.membres
  deferrable initially deferred
  for each row execute function public.verifier_sieges();

-- Rattachement automatique d'un nouveau compte : sans organisation,
-- un compte fraîchement créé ne verrait rien du tout, toutes les
-- politiques filtrant sur mon_org().
create or replace function public.creer_org_par_defaut()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_org uuid;
begin
  if exists (select 1 from public.membres where utilisateur_id = new.id) then
    return new;
  end if;

  insert into public.organisations (nom, type, plan, sieges)
  values (
    coalesce(
      nullif(trim(new.agence), ''),
      nullif(trim(concat_ws(' ', new.prenom, new.nom)), ''),
      new.email),
    'solo',
    case when new.plan in ('free', 'starter', 'pro', 'agency')
         then new.plan else 'free' end,
    1)
  returning id into v_org;

  insert into public.membres (org_id, utilisateur_id, role)
  values (v_org, new.id, 'proprietaire');

  return new;
end;
$$;

revoke all on function public.creer_org_par_defaut(), public.verifier_sieges() from public;

drop trigger if exists profils_org_par_defaut on public.profiles;
create trigger profils_org_par_defaut
  after insert on public.profiles
  for each row execute function public.creer_org_par_defaut();

-- ═══ 5. REPRISE DES COMPTES EXISTANTS ═════════════════════════
-- Toute écriture vient en dernier : une insertion met des événements
-- de déclencheur différés en attente, et plus aucun ALTER TABLE ne
-- passe ensuite dans la même transaction.
-- Une organisation par profil, dans une boucle : un appariement par
-- nom serait ambigu dès que deux profils portent le même libellé.

do $$
declare
  r     record;
  v_org uuid;
begin
  for r in
    select p.id, p.email, p.prenom, p.nom, p.agence, p.plan
      from public.profiles p
     where not exists (select 1 from public.membres m where m.utilisateur_id = p.id)
  loop
    insert into public.organisations (nom, type, plan, sieges)
    values (
      coalesce(
        nullif(trim(r.agence), ''),
        nullif(trim(concat_ws(' ', r.prenom, r.nom)), ''),
        r.email),
      'solo',
      case when r.plan in ('free', 'starter', 'pro', 'agency')
           then r.plan else 'free' end,
      1)
    returning id into v_org;

    insert into public.membres (org_id, utilisateur_id, role)
    values (v_org, r.id, 'proprietaire');
  end loop;
end;
$$;

commit;
