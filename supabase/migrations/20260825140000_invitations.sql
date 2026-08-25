-- ═══════════════════════════════════════════════════════════════
-- 06 · INVITATIONS ET GESTION DE L'ÉQUIPE
-- ═══════════════════════════════════════════════════════════════
--
-- Sans ce fichier, une agence ne peut ajouter ses commerciaux qu'en
-- SQL. C'est le dernier verrou avant de pouvoir vendre au segment
-- agence, et le produit doit se déployer sans intervention manuelle.
--
-- Le parcours : la direction saisit un email, obtient un lien
-- d'invitation, le transmet. Le commercial ouvre le lien, crée son
-- compte, et rejoint l'organisation avec le rôle prévu.
--
-- Le jeton est lisible sans être connecté — l'invité n'appartient à
-- rien encore — mais ne révèle que le strict nécessaire : le nom de
-- l'agence et le rôle proposé. Jamais la liste des invitations.
--
-- ═══════════════════════════════════════════════════════════════

begin;

-- ═══ 1. TABLE ══════════════════════════════════════════════════

create table if not exists public.invitations (
  id          uuid        primary key default extensions.gen_random_uuid(),
  org_id      uuid        not null references public.organisations(id) on delete cascade,
  email       text        not null check (position('@' in email) > 1),
  role        text        not null default 'agent'
                          check (role in ('direction', 'agent')),
  jeton       text        not null unique,
  invite_par  uuid        references auth.users(id) on delete set null,
  expire_le   timestamptz not null default now() + interval '14 days',
  accepte_le  timestamptz,
  accepte_par uuid        references auth.users(id) on delete set null,
  annule_le   timestamptz,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

comment on table  public.invitations       is 'Invitation d''un commercial à rejoindre une organisation.';
comment on column public.invitations.jeton is 'Secret transmis dans le lien. Seul élément lisible sans compte.';

-- Une seule invitation en attente par email et par organisation.
create unique index if not exists invitations_une_en_attente
  on public.invitations (org_id, lower(email))
  where accepte_le is null and annule_le is null;

create index if not exists invitations_org_idx   on public.invitations (org_id);
create index if not exists invitations_jeton_idx on public.invitations (jeton);

select public.installer_touch('invitations'::text);

alter table public.invitations enable row level security;

-- ═══ 2. POLITIQUES ═════════════════════════════════════════════
-- Aucune lecture directe : même la direction passe par une fonction.
-- Cela évite qu'un jeton fuite par une requête trop large.

drop policy if exists invitations_direction on public.invitations;

create policy invitations_direction on public.invitations
  for select to authenticated
  using (org_id = public.mon_org() and public.est_direction());

-- ═══ 3. INVITER ════════════════════════════════════════════════

create or replace function public.inviter_membre(
  p_email text,
  p_role  text default 'agent'
)
returns table (jeton text, expire_le timestamptz)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_org      uuid := public.mon_org();
  v_email    text := lower(trim(p_email));
  v_occupes  integer;
  v_sieges   integer;
  v_jeton    text;
  v_expire   timestamptz;
begin
  if not public.est_direction() then
    raise exception 'Seule la direction peut inviter un commercial'
      using errcode = 'insufficient_privilege';
  end if;

  if p_role not in ('direction', 'agent') then
    raise exception 'Rôle invalide : %', p_role;
  end if;

  if position('@' in v_email) < 2 then
    raise exception 'Adresse email invalide';
  end if;

  -- Déjà dans l'équipe ?
  if exists (
    select 1 from public.membres m
      join public.profiles p on p.id = m.utilisateur_id
     where m.org_id = v_org and lower(p.email) = v_email
  ) then
    raise exception 'Cette personne fait déjà partie de votre équipe';
  end if;

  -- Les sièges se comptent membres + invitations en attente : sans
  -- cela, on pourrait inviter dix personnes sur trois sièges et
  -- découvrir le problème seulement à leur arrivée.
  select count(*) into v_occupes from public.membres where org_id = v_org;
  select v_occupes + count(*) into v_occupes
    from public.invitations
   where org_id = v_org and accepte_le is null and annule_le is null
     and expire_le > now();
  select sieges into v_sieges from public.organisations where id = v_org;

  if v_occupes >= v_sieges then
    raise exception
      'Plus de siège disponible : % occupé(s) ou réservé(s) sur % à l''abonnement.',
      v_occupes, v_sieges
      using errcode = 'check_violation';
  end if;

  v_jeton  := encode(extensions.gen_random_bytes(18), 'hex');
  v_expire := now() + interval '14 days';

  -- Une invitation périmée ou annulée pour le même email est remplacée.
  delete from public.invitations
   where org_id = v_org and lower(email) = v_email and accepte_le is null;

  insert into public.invitations (org_id, email, role, jeton, invite_par, expire_le)
  values (v_org, v_email, p_role, v_jeton, auth.uid(), v_expire);

  insert into public.audit_log (actor_id, actor_email, action, target_type, target_id, details)
  values (auth.uid(),
          coalesce((select email from public.profiles where id = auth.uid()), 'inconnu'),
          'equipe.invitation', 'invitation', v_email,
          jsonb_build_object('role', p_role, 'org', v_org));

  return query select v_jeton, v_expire;
end;
$$;

-- ═══ 4. LIRE UNE INVITATION (sans compte) ══════════════════════
-- Appelée depuis l'écran d'inscription, avant toute authentification.
-- Ne renvoie que ce qu'il faut pour afficher « Rejoindre l'agence X ».

create or replace function public.invitation_info(p_jeton text)
returns table (valide boolean, motif text, agence text, email text, role text)
language plpgsql
security definer
set search_path = ''
as $$
declare i record;
begin
  select v.*, o.nom as nom_org into i
    from public.invitations v
    join public.organisations o on o.id = v.org_id
   where v.jeton = p_jeton;

  if not found              then return query select false, 'introuvable', null::text, null::text, null::text; return; end if;
  if i.annule_le is not null then return query select false, 'annulee',     null::text, null::text, null::text; return; end if;
  if i.accepte_le is not null then return query select false, 'deja_acceptee', null::text, null::text, null::text; return; end if;
  if i.expire_le < now()    then return query select false, 'expiree',     null::text, null::text, null::text; return; end if;

  return query select true, null::text, i.nom_org::text, i.email::text, i.role::text;
end;
$$;

-- ═══ 5. ACCEPTER ═══════════════════════════════════════════════

create or replace function public.accepter_invitation(p_jeton text)
returns table (ok boolean, motif text, org_id uuid)
language plpgsql
security definer
set search_path = ''
as $$
declare
  i          record;
  v_occupes  integer;
  v_sieges   integer;
  v_ancienne uuid;
begin
  if auth.uid() is null then
    raise exception 'Connexion requise pour accepter une invitation'
      using errcode = 'insufficient_privilege';
  end if;

  select * into i from public.invitations where jeton = p_jeton for update;

  if not found                then return query select false, 'introuvable',    null::uuid; return; end if;
  if i.annule_le  is not null then return query select false, 'annulee',        null::uuid; return; end if;
  if i.accepte_le is not null then return query select false, 'deja_acceptee',  null::uuid; return; end if;
  if i.expire_le  < now()     then return query select false, 'expiree',        null::uuid; return; end if;

  -- Le siège a pu être pris entre l'envoi et l'acceptation.
  select count(*) into v_occupes from public.membres where org_id = i.org_id;
  select sieges   into v_sieges  from public.organisations where id = i.org_id;
  if v_occupes >= v_sieges then
    return query select false, 'plus_de_siege', null::uuid; return;
  end if;

  -- Un compte n'appartient qu'à une organisation. Rejoindre une agence
  -- signifie donc quitter l'organisation solo créée à l'inscription —
  -- et son portefeuille doit suivre, sinon un indépendant qui rejoint
  -- une agence verrait ses prospects disparaître du jour au lendemain.
  select org_id into v_ancienne from public.membres where utilisateur_id = auth.uid();

  if v_ancienne is not null and v_ancienne <> i.org_id then
    update public.prospects set org_id = i.org_id
     where org_id = v_ancienne and attribue_a = auth.uid();
    update public.mandats   set org_id = i.org_id
     where org_id = v_ancienne and attribue_a = auth.uid();
    update public.rdvs      set org_id = i.org_id
     where org_id = v_ancienne and attribue_a = auth.uid();
  end if;

  delete from public.membres where utilisateur_id = auth.uid();

  -- L'ancienne organisation solo, si elle est désormais vide, n'a plus
  -- de raison d'exister. On ne la supprime qu'après s'être assuré
  -- qu'elle ne contient plus rien : la suppression est en cascade.
  if v_ancienne is not null and v_ancienne <> i.org_id
     and not exists (select 1 from public.membres   where org_id = v_ancienne)
     and not exists (select 1 from public.prospects where org_id = v_ancienne)
     and not exists (select 1 from public.mandats   where org_id = v_ancienne)
     and not exists (select 1 from public.rdvs      where org_id = v_ancienne)
  then
    delete from public.organisations where id = v_ancienne and type = 'solo';
  end if;

  insert into public.membres (org_id, utilisateur_id, role, invite_par)
  values (i.org_id, auth.uid(), i.role, i.invite_par);

  update public.invitations
     set accepte_le = now(), accepte_par = auth.uid()
   where id = i.id;

  insert into public.audit_log (actor_id, actor_email, action, target_type, target_id, details)
  values (auth.uid(),
          coalesce((select email from public.profiles where id = auth.uid()), 'inconnu'),
          'equipe.arrivee', 'organisation', i.org_id::text,
          jsonb_build_object('role', i.role));

  return query select true, null::text, i.org_id;
end;
$$;

-- ═══ 6. ANNULER, RETIRER, CHANGER DE RÔLE ══════════════════════

create or replace function public.annuler_invitation(p_id uuid)
returns boolean
language plpgsql security definer set search_path = '' as $$
begin
  if not public.est_direction() then
    raise exception 'Réservé à la direction' using errcode = 'insufficient_privilege';
  end if;
  update public.invitations set annule_le = now()
   where id = p_id and org_id = public.mon_org() and accepte_le is null;
  return found;
end;
$$;

create or replace function public.retirer_membre(p_utilisateur uuid)
returns boolean
language plpgsql security definer set search_path = '' as $$
declare v_org uuid := public.mon_org();
begin
  if not public.est_direction() then
    raise exception 'Réservé à la direction' using errcode = 'insufficient_privilege';
  end if;
  if p_utilisateur = auth.uid() then
    raise exception 'Vous ne pouvez pas vous retirer vous-même';
  end if;
  if exists (select 1 from public.membres
              where org_id = v_org and utilisateur_id = p_utilisateur
                and role = 'proprietaire') then
    raise exception 'Le propriétaire de l''organisation ne peut pas être retiré';
  end if;

  -- Ses leads retournent au vivier plutôt que de disparaître avec lui.
  update public.prospects set attribue_a = null
   where org_id = v_org and attribue_a = p_utilisateur;
  update public.mandats   set attribue_a = null
   where org_id = v_org and attribue_a = p_utilisateur;
  update public.rdvs      set attribue_a = null
   where org_id = v_org and attribue_a = p_utilisateur;

  delete from public.membres where org_id = v_org and utilisateur_id = p_utilisateur;

  insert into public.audit_log (actor_id, actor_email, action, target_type, target_id, details)
  values (auth.uid(),
          coalesce((select email from public.profiles where id = auth.uid()), 'inconnu'),
          'equipe.depart', 'utilisateur', p_utilisateur::text,
          jsonb_build_object('org', v_org));
  return true;
end;
$$;

create or replace function public.changer_role(p_utilisateur uuid, p_role text)
returns boolean
language plpgsql security definer set search_path = '' as $$
declare v_org uuid := public.mon_org();
begin
  if not public.est_direction() then
    raise exception 'Réservé à la direction' using errcode = 'insufficient_privilege';
  end if;
  if p_role not in ('direction', 'agent') then
    raise exception 'Rôle invalide : %', p_role;
  end if;
  if exists (select 1 from public.membres
              where org_id = v_org and utilisateur_id = p_utilisateur
                and role = 'proprietaire') then
    raise exception 'Le rôle du propriétaire ne se change pas';
  end if;

  update public.membres set role = p_role
   where org_id = v_org and utilisateur_id = p_utilisateur;
  return found;
end;
$$;

-- ═══ 7. VUE D'ÉQUIPE ═══════════════════════════════════════════
-- Un seul appel pour peupler l'écran : membres, charge de travail,
-- invitations en attente et sièges restants.

create or replace function public.mon_equipe()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_org uuid := public.mon_org();
  v_res jsonb;
begin
  if v_org is null then return jsonb_build_object('erreur', 'aucune_organisation'); end if;

  select jsonb_build_object(
    'organisation', (
      select jsonb_build_object('id', o.id, 'nom', o.nom, 'type', o.type,
                                'plan', o.plan, 'sieges', o.sieges)
        from public.organisations o where o.id = v_org),
    'monRole', public.mon_role(),
    'membres', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', m.utilisateur_id, 'role', m.role,
               'email', p.email, 'prenom', p.prenom, 'nom', p.nom,
               'prospects', (select count(*) from public.prospects x
                              where x.attribue_a = m.utilisateur_id and x.supprime_le is null),
               'mandats',   (select count(*) from public.mandats x
                              where x.attribue_a = m.utilisateur_id and x.supprime_le is null))
             order by case m.role when 'proprietaire' then 1 when 'direction' then 2 else 3 end,
                      p.nom)
        from public.membres m
        left join public.profiles p on p.id = m.utilisateur_id
       where m.org_id = v_org), '[]'::jsonb),
    'invitations', case when public.est_direction() then coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', v.id, 'email', v.email, 'role', v.role,
               'jeton', v.jeton, 'expireLe', v.expire_le))
        from public.invitations v
       where v.org_id = v_org and v.accepte_le is null and v.annule_le is null
         and v.expire_le > now()), '[]'::jsonb) else '[]'::jsonb end,
    'vivier', (select count(*) from public.prospects
                where org_id = v_org and attribue_a is null and supprime_le is null)
  ) into v_res;

  return v_res;
end;
$$;

-- ═══ 8. DROITS ═════════════════════════════════════════════════

revoke all on function
  public.inviter_membre(text, text), public.invitation_info(text),
  public.accepter_invitation(text), public.annuler_invitation(uuid),
  public.retirer_membre(uuid), public.changer_role(uuid, text),
  public.mon_equipe()
from public;

-- invitation_info est la seule appelable sans compte : l'invité doit
-- pouvoir lire son invitation avant de s'inscrire.
grant execute on function public.invitation_info(text) to anon, authenticated;

grant execute on function
  public.inviter_membre(text, text), public.accepter_invitation(text),
  public.annuler_invitation(uuid), public.retirer_membre(uuid),
  public.changer_role(uuid, text), public.mon_equipe()
to authenticated;

commit;
