-- ═══════════════════════════════════════════════════════════════
-- 14 · LEADS ENTRANTS — LE SAS AVANT LE PIPELINE
-- ═══════════════════════════════════════════════════════════════
--
-- Un lead publicitaire qui vient de laisser ses coordonnées n'est pas
-- encore un prospect en « premier contact » : personne ne lui a
-- parlé. Les confondre rend le pipeline menteur — on y compte comme
-- contactées des personnes que nul n'a appelées.
--
-- D'où une étape supplémentaire, en amont : « nouveau ». Le lead y
-- reste tant qu'il n'a pas été joint. Le commercial l'appelle, prend
-- ses notes, puis le fait passer en premier contact. Ce geste est le
-- seul qui compte, et c'est lui qu'on horodate.
--
-- premier_contact_le est la colonne qui donne sa valeur à tout le
-- reste. Quand on achète ses leads, le délai entre l'arrivée et le
-- premier appel décide de la conversion bien plus que le discours.
-- Sans cette date, « est-ce que mes leads sont bien traités » n'a pas
-- de réponse chiffrée.
--
-- ═══════════════════════════════════════════════════════════════

begin;

-- ═══ 1. L'ÉTAPE « NOUVEAU » ════════════════════════════════════

alter table public.prospects drop constraint if exists prospects_etape_check;
alter table public.prospects add constraint prospects_etape_check
  check (etape in ('nouveau', 'contact', 'rdv', 'estimation', 'mandat',
                   'vente', 'offre', 'compromis', 'acte'));

-- Les fiches saisies à la main continuent d'arriver en « contact » :
-- celui qui saisit vient de parler à la personne. Seule l'ingestion
-- publicitaire posera « nouveau ».
comment on column public.prospects.etape is
  'nouveau = lead publicitaire pas encore joint. contact = quelqu''un lui a parlé.';

-- ═══ 2. LA DATE QUI MESURE TOUT ════════════════════════════════

alter table public.prospects add column if not exists premier_contact_le timestamptz;

comment on column public.prospects.premier_contact_le is
  'Premier échange réel. Comparée à created_at, elle donne le délai de traitement.';

-- Le tableau de bord de direction interroge « les leads pas encore
-- joints, du plus vieux au plus récent ». Sans cet index, cette
-- question coûte un parcours complet de la table à chaque affichage.
create index if not exists prospects_non_traites_idx
  on public.prospects (org_id, created_at)
  where etape = 'nouveau' and supprime_le is null;

-- ═══ 3. À QUI VONT LES LEADS ═══════════════════════════════════

-- Un lead qui arrive par webhook n'a personne pour l'attribuer : le
-- destinataire par défaut est donc une propriété de l'organisation,
-- pas une décision prise au coup par coup.
alter table public.organisations
  add column if not exists attribution_par_defaut uuid references auth.users(id) on delete set null;

comment on column public.organisations.attribution_par_defaut is
  'Destinataire des leads entrants tant qu''aucune règle plus fine n''existe.';

create or replace function public.attribuer_lead_entrant()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_defaut uuid;
begin
  -- Ne concerne que les leads entrants non attribués. Une fiche
  -- saisie par un commercial lui appartient déjà.
  if new.attribue_a is not null or new.etape <> 'nouveau' then
    return new;
  end if;

  select attribution_par_defaut into v_defaut
    from public.organisations where id = new.org_id;

  -- Le destinataire doit toujours appartenir à l'organisation et être
  -- actif : sans ce contrôle, le départ d'un commercial enverrait
  -- silencieusement les leads suivants dans le vide.
  if v_defaut is not null and exists (
       select 1 from public.membres
        where org_id = new.org_id and utilisateur_id = v_defaut
          and desactive_le is null)
  then
    new.attribue_a := v_defaut;
  end if;

  return new;
end;
$$;

drop trigger if exists prospects_attribution_entrante on public.prospects;
create trigger prospects_attribution_entrante
  before insert on public.prospects
  for each row execute function public.attribuer_lead_entrant();

-- ═══ 4. HORODATER LE PREMIER CONTACT ═══════════════════════════

-- Posée par la base, jamais par le client : un navigateur peut mentir
-- sur l'heure, et c'est précisément cette date qui sert à juger si le
-- travail a été fait à temps.
create or replace function public.marquer_premier_contact()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.premier_contact_le is null
     and old.etape = 'nouveau' and new.etape <> 'nouveau'
  then
    new.premier_contact_le := now();
  end if;
  return new;
end;
$$;

drop trigger if exists prospects_premier_contact on public.prospects;
create trigger prospects_premier_contact
  before update on public.prospects
  for each row execute function public.marquer_premier_contact();

-- Une activité tracée vaut contact, même si l'étape n'a pas bougé :
-- un commercial qui note « appelé, pas de réponse » a bel et bien
-- traité le lead dans les temps.
create or replace function public.premier_contact_par_activite()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.prospects
     set premier_contact_le = now()
   where id = new.prospect_id
     and premier_contact_le is null;
  return new;
end;
$$;

drop trigger if exists activites_premier_contact on public.prospect_activites;
create trigger activites_premier_contact
  after insert on public.prospect_activites
  for each row execute function public.premier_contact_par_activite();

-- ═══ 5. DÉSIGNER LE DESTINATAIRE ═══════════════════════════════

create or replace function public.definir_attribution_par_defaut(p_membre uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.est_direction() then
    raise exception 'Réservé à la direction' using errcode = 'insufficient_privilege';
  end if;

  if p_membre is not null and not exists (
       select 1 from public.membres
        where org_id = public.mon_org() and utilisateur_id = p_membre
          and desactive_le is null)
  then
    raise exception 'Ce membre n''appartient pas à votre organisation';
  end if;

  update public.organisations
     set attribution_par_defaut = p_membre
   where id = public.mon_org();
end;
$$;

revoke all on function public.definir_attribution_par_defaut(uuid) from anon;
grant execute on function public.definir_attribution_par_defaut(uuid) to authenticated;

-- ═══ 6. SIMON REÇOIT LES LEADS ═════════════════════════════════

update public.organisations o
   set attribution_par_defaut = (
     select m.utilisateur_id from public.membres m
      where m.org_id = o.id and lower(m.prenom) = 'simon' and m.desactive_le is null
      limit 1)
 where o.slug = 'manalex';

commit;
