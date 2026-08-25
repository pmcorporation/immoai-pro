-- ═══════════════════════════════════════════════════════════════
-- 07 · ESSAI GRATUIT ET ÉTAT D'ABONNEMENT
-- ═══════════════════════════════════════════════════════════════
--
-- Le produit passe en libre-service : un agent s'inscrit seul, essaie,
-- puis paie. Il n'y a plus de code d'activation à saisir, donc il faut
-- une période d'essai portée par l'organisation.
--
-- L'essai vit sur l'organisation, comme le plan : une agence essaie une
-- fois, pas une fois par commercial.
--
-- ═══════════════════════════════════════════════════════════════

begin;

-- ═══ 1. COLONNE ════════════════════════════════════════════════

alter table public.organisations
  add column if not exists essai_fin_le timestamptz;

comment on column public.organisations.essai_fin_le is
  'Fin de la période d''essai. NULL = pas d''essai en cours (jamais commencé, ou converti).';

-- ═══ 2. ÉTAT D'ABONNEMENT ══════════════════════════════════════
-- Une seule fonction répond à « cet utilisateur a-t-il le droit
-- d'utiliser le produit, et pour combien de temps encore ». Le client
-- ne recalcule rien : il affiche ce qu'on lui dit.

create or replace function public.mon_abonnement()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  o        record;
  v_jours  integer;
  v_actif  boolean;
  v_etat   text;
begin
  select org.* into o
    from public.membres m
    join public.organisations org on org.id = m.org_id
   where m.utilisateur_id = auth.uid()
   limit 1;

  if not found then
    return jsonb_build_object('etat', 'sans_organisation', 'actif', false);
  end if;

  v_jours := case when o.essai_fin_le is null then null
                  else greatest(0, ceil(extract(epoch from (o.essai_fin_le - now())) / 86400)::integer)
             end;

  -- Un abonnement payant prime toujours sur l'essai.
  if o.plan <> 'free' and coalesce(o.statut_abonnement, '') in ('active', 'trialing') then
    v_etat  := 'abonne';
    v_actif := true;
  elsif o.essai_fin_le is not null and o.essai_fin_le > now() then
    v_etat  := 'essai';
    v_actif := true;
  elsif o.essai_fin_le is not null then
    v_etat  := 'essai_termine';
    v_actif := false;
  else
    v_etat  := 'sans_abonnement';
    v_actif := false;
  end if;

  return jsonb_build_object(
    'etat',        v_etat,
    'actif',       v_actif,
    'plan',        o.plan,
    'organisation', o.nom,
    'type',        o.type,
    'sieges',      o.sieges,
    'joursRestants', v_jours,
    'essaiFinLe',  o.essai_fin_le,
    'estDirection', public.est_direction()
  );
end;
$$;

comment on function public.mon_abonnement() is
  'État d''abonnement de l''organisation courante : essai, abonné, ou expiré.';

revoke all on function public.mon_abonnement() from public;
grant execute on function public.mon_abonnement() to authenticated;

-- ═══ 3. ESSAI POSÉ À LA CRÉATION ═══════════════════════════════
-- On remplace la fonction du fichier 02 pour que toute nouvelle
-- organisation solo démarre avec ses quatorze jours.

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

  insert into public.organisations (nom, type, plan, sieges, essai_fin_le)
  values (
    coalesce(
      nullif(trim(new.agence), ''),
      nullif(trim(concat_ws(' ', new.prenom, new.nom)), ''),
      new.email),
    'solo',
    case when new.plan in ('free', 'starter', 'pro', 'agency')
         then new.plan else 'free' end,
    1,
    now() + interval '14 days')
  returning id into v_org;

  insert into public.membres (org_id, utilisateur_id, role)
  values (v_org, new.id, 'proprietaire');

  return new;
end;
$$;

revoke all on function public.creer_org_par_defaut() from public;

-- ═══ 4. REPRISE DE L'EXISTANT (écriture en dernier) ════════════
-- Toute organisation déjà créée reçoit son essai : sans cela, les
-- comptes existants se retrouveraient bloqués du jour au lendemain.
-- Placé après tout le DDL, conformément à la règle apprise au fichier
-- 02 : une écriture met des événements de déclencheur en attente et
-- plus aucun ALTER TABLE ne passe ensuite dans la même transaction.

update public.organisations
   set essai_fin_le = created_at + interval '14 days'
 where essai_fin_le is null and plan = 'free';

commit;
