-- ═══════════════════════════════════════════════════════════════
-- 08 · SÉQUENCES DE RELANCE AUTOMATIQUE
-- ═══════════════════════════════════════════════════════════════
--
-- Dans l'immobilier, la vitesse de réponse décide de la conversion.
-- Un lead publicitaire rappelé dans l'heure n'a rien à voir avec le
-- même rappelé le lendemain — et c'est le troisième contact, pas le
-- premier, qui décroche la plupart des estimations.
--
-- L'automatisation vit côté serveur, dans un déclencheur, et non dans
-- l'application. Trois raisons :
--
--   • Un lead qui arrivera par le webhook Meta n'ouvre aucun
--     navigateur. Si la logique était côté client, ses relances ne
--     seraient créées qu'au prochain passage de l'agent — trop tard.
--   • L'agent ferme son onglet ; le serveur, non.
--   • Une règle qui décide de l'activité commerciale n'a rien à faire
--     dans du JavaScript qu'on peut désactiver depuis la console.
--
-- Les relances se matérialisent dans prospect_relances, la table qui
-- alimente déjà l'écran de suivi et le panneau de notifications. Rien
-- de nouveau à afficher : ce qui existe se remplit tout seul.
--
-- ═══════════════════════════════════════════════════════════════

begin;

-- ═══ 1. TABLES ═════════════════════════════════════════════════

create table if not exists public.sequences (
  id          uuid        primary key default extensions.gen_random_uuid(),
  org_id      uuid        not null references public.organisations(id) on delete cascade,
  nom         text        not null check (length(trim(nom)) > 0),
  actif       boolean     not null default true,
  declencheur text        not null default 'nouveau_prospect'
                          check (declencheur in ('nouveau_prospect')),
  -- Restreindre à un type de prospect, ou NULL pour tous : on ne relance
  -- pas un vendeur comme un investisseur.
  type_cible  text        check (type_cible is null
                                 or type_cible in ('acheteur', 'vendeur', 'investisseur')),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

comment on table public.sequences is
  'Séquence de relances appliquée automatiquement à l''arrivée d''un prospect.';

-- Une seule séquence active par organisation et par cible : sinon deux
-- séquences se déclencheraient et l'agent croulerait sous les tâches.
create unique index if not exists sequences_une_active
  on public.sequences (org_id, coalesce(type_cible, 'tous'))
  where actif;

create index if not exists sequences_org_idx on public.sequences (org_id);

create table if not exists public.sequence_etapes (
  id          uuid        primary key default extensions.gen_random_uuid(),
  sequence_id uuid        not null references public.sequences(id) on delete cascade,
  ordre       integer     not null check (ordre >= 0),
  delai_jours integer     not null check (delai_jours between 0 and 365),
  titre       text        not null check (length(trim(titre)) > 0),
  note        text,
  created_at  timestamptz not null default now(),
  unique (sequence_id, ordre)
);

comment on column public.sequence_etapes.delai_jours is
  'Décalage en jours depuis la création du prospect. 0 = le jour même.';

create index if not exists sequence_etapes_idx
  on public.sequence_etapes (sequence_id, ordre);

select public.installer_touch('sequences'::text);

alter table public.sequences       enable row level security;
alter table public.sequence_etapes enable row level security;

-- ═══ 2. POLITIQUES ═════════════════════════════════════════════
-- Tout le monde lit — un commercial doit comprendre d'où viennent ses
-- tâches. Seule la direction modifie.

drop policy if exists sequences_lecture   on public.sequences;
drop policy if exists sequences_direction on public.sequences;
drop policy if exists etapes_lecture      on public.sequence_etapes;
drop policy if exists etapes_direction    on public.sequence_etapes;

create policy sequences_lecture on public.sequences
  for select to authenticated
  using (org_id = public.mon_org());

create policy sequences_direction on public.sequences
  for all to authenticated
  using      (org_id = public.mon_org() and public.est_direction())
  with check (org_id = public.mon_org() and public.est_direction());

create policy etapes_lecture on public.sequence_etapes
  for select to authenticated
  using (exists (select 1 from public.sequences s
                  where s.id = sequence_etapes.sequence_id
                    and s.org_id = public.mon_org()));

create policy etapes_direction on public.sequence_etapes
  for all to authenticated
  using (exists (select 1 from public.sequences s
                  where s.id = sequence_etapes.sequence_id
                    and s.org_id = public.mon_org() and public.est_direction()))
  with check (exists (select 1 from public.sequences s
                  where s.id = sequence_etapes.sequence_id
                    and s.org_id = public.mon_org() and public.est_direction()));

-- ═══ 3. LE DÉCLENCHEUR ═════════════════════════════════════════

create or replace function public.appliquer_sequence()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_seq uuid;
  e     record;
begin
  -- Un prospect importé avec une date de création ancienne ne doit pas
  -- déclencher une volée de relances déjà échues.
  if new.created_at < now() - interval '1 day' then
    return new;
  end if;

  -- La séquence ciblée sur le type prime sur la séquence générale.
  select s.id into v_seq
    from public.sequences s
   where s.org_id = new.org_id and s.actif
     and (s.type_cible = new.type or s.type_cible is null)
   order by (s.type_cible is not null) desc
   limit 1;

  if v_seq is null then return new; end if;

  for e in
    select * from public.sequence_etapes where sequence_id = v_seq order by ordre
  loop
    insert into public.prospect_relances (prospect_id, titre, echeance)
    values (new.id, e.titre, (new.created_at + (e.delai_jours || ' days')::interval)::date);
  end loop;

  return new;
end;
$$;

revoke all on function public.appliquer_sequence() from public;

drop trigger if exists prospects_appliquer_sequence on public.prospects;
create trigger prospects_appliquer_sequence
  after insert on public.prospects
  for each row execute function public.appliquer_sequence();

-- ═══ 4. LECTURE ET ÉCRITURE DEPUIS L'APPLICATION ═══════════════

create or replace function public.mes_sequences()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare v_org uuid := public.mon_org();
begin
  if v_org is null then return '[]'::jsonb; end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', s.id, 'nom', s.nom, 'actif', s.actif,
             'typeCible', s.type_cible,
             'etapes', coalesce((
               select jsonb_agg(jsonb_build_object(
                        'ordre', e.ordre, 'delaiJours', e.delai_jours,
                        'titre', e.titre, 'note', e.note) order by e.ordre)
                 from public.sequence_etapes e where e.sequence_id = s.id), '[]'::jsonb))
           order by s.created_at)
      from public.sequences s where s.org_id = v_org), '[]'::jsonb);
end;
$$;

/**
 * Enregistre une séquence et ses étapes en une fois. Les étapes sont
 * remplacées intégralement : plus simple à raisonner qu'un différentiel,
 * et sans risque de laisser une étape orpheline.
 */
create or replace function public.enregistrer_sequence(
  p_id     uuid,
  p_nom    text,
  p_actif  boolean,
  p_cible  text,
  p_etapes jsonb
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_org uuid := public.mon_org();
  v_id  uuid := p_id;
  e     jsonb;
  i     integer := 0;
begin
  if not public.est_direction() then
    raise exception 'Seule la direction peut modifier les séquences'
      using errcode = 'insufficient_privilege';
  end if;

  if v_id is null then
    insert into public.sequences (org_id, nom, actif, type_cible)
    values (v_org, p_nom, coalesce(p_actif, true), nullif(p_cible, ''))
    returning id into v_id;
  else
    update public.sequences
       set nom = p_nom, actif = coalesce(p_actif, true), type_cible = nullif(p_cible, '')
     where id = v_id and org_id = v_org;
    if not found then raise exception 'Séquence introuvable'; end if;
    delete from public.sequence_etapes where sequence_id = v_id;
  end if;

  for e in select * from jsonb_array_elements(coalesce(p_etapes, '[]'::jsonb))
  loop
    insert into public.sequence_etapes (sequence_id, ordre, delai_jours, titre, note)
    values (v_id, i, greatest(0, (e->>'delaiJours')::integer),
            coalesce(nullif(trim(e->>'titre'), ''), 'Relancer'), nullif(e->>'note', ''));
    i := i + 1;
  end loop;

  return v_id;
end;
$$;

revoke all on function
  public.mes_sequences(), public.enregistrer_sequence(uuid, text, boolean, text, jsonb)
from public;
grant execute on function
  public.mes_sequences(), public.enregistrer_sequence(uuid, text, boolean, text, jsonb)
to authenticated;

-- ═══ 5. SÉQUENCE PAR DÉFAUT (écriture en dernier) ══════════════
-- Une automatisation qu'il faut configurer avant d'en voir l'intérêt
-- ne sert à personne. Chaque organisation démarre avec une séquence
-- déjà utile, qu'elle pourra ajuster.
--
-- Le rythme retenu — le jour même, puis 2, 7, 21 et 60 jours — suit la
-- réalité du métier : on décroche rarement au premier appel, et un
-- prospect « pas maintenant » se réveille souvent deux mois plus tard.

do $$
declare
  o     record;
  v_seq uuid;
  etapes constant text[][] := array[
    ['0',  'Appeler — premier contact'],
    ['2',  'Relancer si pas de réponse'],
    ['7',  'Proposer une estimation'],
    ['21', 'Prendre des nouvelles'],
    ['60', 'Relance longue — le projet a pu mûrir']
  ];
  i integer;
begin
  for o in select id from public.organisations loop
    if exists (select 1 from public.sequences where org_id = o.id) then continue; end if;

    insert into public.sequences (org_id, nom, actif, declencheur)
    values (o.id, 'Suivi standard', true, 'nouveau_prospect')
    returning id into v_seq;

    for i in 1 .. array_length(etapes, 1) loop
      insert into public.sequence_etapes (sequence_id, ordre, delai_jours, titre)
      values (v_seq, i - 1, etapes[i][1]::integer, etapes[i][2]);
    end loop;
  end loop;
end;
$$;

commit;
