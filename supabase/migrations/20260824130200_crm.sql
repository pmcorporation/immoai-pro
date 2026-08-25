-- ═══════════════════════════════════════════════════════════════
-- 03 · CRM — PROSPECTS, MANDATS, RENDEZ-VOUS
-- ═══════════════════════════════════════════════════════════════
--
-- Les quatre tables métier existantes (prospects, mandats, rdvs,
-- pipeline) contiennent ZÉRO ligne : la synchronisation n'a jamais
-- écrit en base. Elles sont donc recréées proprement plutôt que
-- rapiécées. C'est le seul moment où cette reprise est gratuite.
--
-- Ce qui change par rapport à l'existant :
--
--   • Clés uuid côté serveur, au lieu de 'p' || Date.now() côté client.
--   • org_id + attribue_a : la règle « chacun ses leads » est portée
--     par la base, pas par l'interface.
--   • supprime_le : sans pierre tombale, une suppression ne peut pas
--     être propagée d'un appareil à l'autre.
--   • Les tableaux JSON (notes, activités, documents, photos) deviennent
--     de vraies tables filles. Ils étaient la cause du rejet des
--     écritures : l'app envoyait 38 champs pour 15 colonnes.
--   • Les photos et documents référencent Supabase Storage, plus de
--     base64 qui saturait le quota du navigateur.
--   • Le pipeline n'est plus une table : l'étape vit sur le prospect,
--     et son historique dans prospect_etapes.
--
-- ═══════════════════════════════════════════════════════════════

begin;

-- ── Table de reprise ────────────────────────────────────────────
-- Vérification explicite : on refuse de continuer s'il y a des
-- données, pour qu'une exécution accidentelle ne détruise rien.

do $$
declare
  t        text;
  v_lignes bigint;
  v_total  bigint := 0;
begin
  foreach t in array array['prospects', 'mandats', 'rdvs', 'pipeline'] loop
    if to_regclass('public.' || t) is not null then
      execute format('select count(*) from public.%I', t) into v_lignes;
      v_total := v_total + v_lignes;
    end if;
  end loop;

  if v_total > 0 then
    raise exception
      'Refus : % ligne(s) métier en base. Cette migration suppose des tables vides.', v_total;
  end if;
end;
$$;

drop table if exists public.pipeline  cascade;
drop table if exists public.prospects cascade;
drop table if exists public.mandats   cascade;
drop table if exists public.rdvs      cascade;

-- ── Prospects ───────────────────────────────────────────────────

create table public.prospects (
  id            uuid        primary key default extensions.gen_random_uuid(),
  org_id        uuid        not null references public.organisations(id) on delete cascade,
  attribue_a    uuid        references auth.users(id) on delete set null,
  cree_par      uuid        references auth.users(id) on delete set null,

  -- Identité
  prenom        text        not null check (length(trim(prenom)) > 0),
  nom           text        not null check (length(trim(nom)) > 0),
  email         text,
  tel           text,
  profession    text,

  -- Qualification
  type          text        not null default 'acheteur'
                            check (type in ('acheteur', 'vendeur', 'investisseur')),
  etape         text        not null default 'contact'
                            check (etape in ('contact', 'rdv', 'estimation', 'mandat',
                                             'vente', 'offre', 'compromis', 'acte')),
  perdu         boolean     not null default false,
  motif_perte   text,

  budget        numeric(12,2) check (budget is null or budget >= 0),
  commission    numeric(12,2) check (commission is null or commission >= 0),
  source        text,

  -- Localisation
  adresse_client text,
  secteur        text,
  rayon_km       integer     check (rayon_km is null or rayon_km between 0 and 500),

  -- Recherche
  type_bien     text,
  bien          text,
  criteres      jsonb       not null default '{}'::jsonb,
  financement   text,
  apport        numeric(12,2),
  horizon       text,

  -- Spécifique vendeur / investisseur
  details       jsonb       not null default '{}'::jsonb,

  note          text,
  relance_le    date,

  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  supprime_le   timestamptz
);

comment on table  public.prospects            is 'Fiche prospect. Visible du seul commercial à qui elle est attribuée.';
comment on column public.prospects.attribue_a is 'Commercial propriétaire du lead. NULL = dans le vivier, à distribuer.';
comment on column public.prospects.criteres   is 'Critères de recherche libres (pièces, extérieur, étage…).';
comment on column public.prospects.details    is 'Champs propres au type : motivation vendeur, structure SCI, rendement visé…';
comment on column public.prospects.supprime_le is 'Pierre tombale. Permet de propager la suppression aux autres appareils.';

-- ── Tables filles du prospect ───────────────────────────────────

create table public.prospect_notes (
  id          uuid        primary key default extensions.gen_random_uuid(),
  prospect_id uuid        not null references public.prospects(id) on delete cascade,
  auteur_id   uuid        references auth.users(id) on delete set null,
  texte       text        not null check (length(trim(texte)) > 0),
  created_at  timestamptz not null default now()
);

create table public.prospect_activites (
  id            uuid        primary key default extensions.gen_random_uuid(),
  prospect_id   uuid        not null references public.prospects(id) on delete cascade,
  auteur_id     uuid        references auth.users(id) on delete set null,
  type          text        not null
                            check (type in ('call', 'email', 'rdv', 'visite',
                                            'offre', 'notaire', 'autre')),
  note          text,
  date_activite date        not null default current_date,
  created_at    timestamptz not null default now()
);

create table public.prospect_relances (
  id          uuid        primary key default extensions.gen_random_uuid(),
  prospect_id uuid        not null references public.prospects(id) on delete cascade,
  titre       text        not null,
  echeance    date        not null,
  faite       boolean     not null default false,
  faite_le    timestamptz,
  created_at  timestamptz not null default now()
);

create table public.prospect_documents (
  id             uuid        primary key default extensions.gen_random_uuid(),
  prospect_id    uuid        not null references public.prospects(id) on delete cascade,
  nom            text        not null,
  categorie      text,
  chemin_storage text        not null,        -- bucket documents, jamais le contenu en base
  type_mime      text,
  taille_octets  bigint      check (taille_octets is null or taille_octets >= 0),
  depose_par     uuid        references auth.users(id) on delete set null,
  created_at     timestamptz not null default now()
);

comment on column public.prospect_documents.chemin_storage is
  'Chemin dans Supabase Storage. Le fichier lui-même n''est jamais stocké en base.';

create table public.prospect_etapes (
  id           uuid        primary key default extensions.gen_random_uuid(),
  prospect_id  uuid        not null references public.prospects(id) on delete cascade,
  etape        text        not null,
  etape_avant  text,
  par          uuid        references auth.users(id) on delete set null,
  created_at   timestamptz not null default now()
);

comment on table public.prospect_etapes is
  'Historique des passages d''étape. Remplace l''ancienne table pipeline.';

-- ── Mandats ─────────────────────────────────────────────────────

create table public.mandats (
  id           uuid        primary key default extensions.gen_random_uuid(),
  org_id       uuid        not null references public.organisations(id) on delete cascade,
  attribue_a   uuid        references auth.users(id) on delete set null,
  cree_par     uuid        references auth.users(id) on delete set null,
  prospect_id  uuid        references public.prospects(id) on delete set null,

  num_mandat   text,
  type         text        not null default 'simple'
                           check (type in ('simple', 'exclusif', 'co-exclusivite', 'recherche')),
  vendeur      text,
  bien         text,
  surface      numeric(8,2)  check (surface is null or surface > 0),
  pieces       integer       check (pieces is null or pieces between 1 and 50),
  adresse      text,
  ville        text,
  code_postal  text,
  prix         numeric(12,2) check (prix is null or prix >= 0),
  honoraires   numeric(12,2) check (honoraires is null or honoraires >= 0),
  dpe          text          check (dpe is null or dpe in ('A','B','C','D','E','F','G','vierge')),
  date_expiration date,
  note         text,
  portails     jsonb       not null default '[]'::jsonb,

  vendu        boolean     not null default false,
  vendu_prix   numeric(12,2),
  vendu_le     date,

  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  supprime_le  timestamptz,

  constraint mandats_vente_coherente
    check (not vendu or (vendu_prix is not null and vendu_le is not null))
);

comment on constraint mandats_vente_coherente on public.mandats is
  'Un mandat marqué vendu doit porter son prix et sa date de vente.';

create table public.mandat_photos (
  id             uuid        primary key default extensions.gen_random_uuid(),
  mandat_id      uuid        not null references public.mandats(id) on delete cascade,
  chemin_storage text        not null,        -- bucket mandats-photos
  ordre          integer     not null default 0,
  created_at     timestamptz not null default now()
);

comment on table public.mandat_photos is
  'Photos du bien. Chemin Storage uniquement : le base64 en localStorage saturait le quota de 5 Mo.';

-- ── Rendez-vous ─────────────────────────────────────────────────

create table public.rdvs (
  id              uuid        primary key default extensions.gen_random_uuid(),
  org_id          uuid        not null references public.organisations(id) on delete cascade,
  attribue_a      uuid        references auth.users(id) on delete set null,
  prospect_id     uuid        references public.prospects(id) on delete set null,
  mandat_id       uuid        references public.mandats(id)   on delete set null,

  type            text        not null default 'autre'
                              check (type in ('estimation', 'visite', 'signature',
                                              'compromis', 'acte', 'autre')),
  titre           text,
  date_rdv        date        not null,
  heure           time,
  duree_min       integer     not null default 60 check (duree_min between 5 and 1440),
  adresse         text,
  note            text,
  lien_visio      text,

  google_event_id text,
  google_synced   boolean     not null default false,

  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  supprime_le     timestamptz
);

-- ── Index ───────────────────────────────────────────────────────
-- Toute clé étrangère et tout filtre courant sont indexés.

create index prospects_org_attrib_idx  on public.prospects (org_id, attribue_a) where supprime_le is null;
create index prospects_etape_idx       on public.prospects (org_id, etape)      where supprime_le is null;
create index prospects_relance_idx     on public.prospects (attribue_a, relance_le) where supprime_le is null and relance_le is not null;
create index prospects_maj_idx         on public.prospects (org_id, updated_at);

create index mandats_org_attrib_idx    on public.mandats (org_id, attribue_a) where supprime_le is null;
create index mandats_prospect_idx      on public.mandats (prospect_id);
create index mandats_maj_idx           on public.mandats (org_id, updated_at);

create index rdvs_org_attrib_idx       on public.rdvs (org_id, attribue_a) where supprime_le is null;
create index rdvs_date_idx             on public.rdvs (attribue_a, date_rdv) where supprime_le is null;
create index rdvs_prospect_idx         on public.rdvs (prospect_id);
create index rdvs_mandat_idx           on public.rdvs (mandat_id);
create index rdvs_maj_idx              on public.rdvs (org_id, updated_at);

create index prospect_notes_idx        on public.prospect_notes (prospect_id, created_at desc);
create index prospect_activites_idx    on public.prospect_activites (prospect_id, date_activite desc);
create index prospect_relances_idx     on public.prospect_relances (prospect_id) where not faite;
create index prospect_documents_idx    on public.prospect_documents (prospect_id);
create index prospect_etapes_idx       on public.prospect_etapes (prospect_id, created_at desc);
create index mandat_photos_idx         on public.mandat_photos (mandat_id, ordre);

-- ── Horodatage automatique ──────────────────────────────────────

select public.installer_touch('prospects'::text);
select public.installer_touch('mandats'::text);
select public.installer_touch('rdvs'::text);

-- ── Historisation automatique des changements d'étape ───────────

create or replace function public.tracer_etape()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.etape is distinct from old.etape then
    insert into public.prospect_etapes (prospect_id, etape, etape_avant, par)
    values (new.id, new.etape, old.etape, auth.uid());
  end if;
  return new;
end;
$$;

revoke all on function public.tracer_etape() from public;

drop trigger if exists prospects_tracer_etape on public.prospects;
create trigger prospects_tracer_etape
  after update of etape on public.prospects
  for each row execute function public.tracer_etape();

-- ── Politiques ──────────────────────────────────────────────────
--
-- LA RÈGLE CENTRALE, en une ligne :
--
--     org_id = mon_org() and (attribue_a = auth.uid() or est_direction())
--
-- Un agent ne voit que ses leads. Comme il ne peut pas voir la ligne
-- d'un collègue, il ne peut ni la modifier ni se l'attribuer. Il peut
-- en revanche céder un lead — donner est permis, prendre ne l'est pas.

do $$
declare t text;
begin
  foreach t in array array['prospects', 'mandats', 'rdvs'] loop

    execute format('alter table public.%I enable row level security', t);

    execute format($p$
      create policy %1$s_lecture on public.%1$I
        for select to authenticated
        using (org_id = public.mon_org()
               and (attribue_a = auth.uid() or public.est_direction()))
    $p$, t);

    execute format($p$
      create policy %1$s_creation on public.%1$I
        for insert to authenticated
        with check (org_id = public.mon_org()
                    and (attribue_a = auth.uid() or public.est_direction()))
    $p$, t);

    execute format($p$
      create policy %1$s_maj on public.%1$I
        for update to authenticated
        using (org_id = public.mon_org()
               and (attribue_a = auth.uid() or public.est_direction()))
        with check (org_id = public.mon_org())
    $p$, t);

    -- Suppression physique réservée à la direction : les agents
    -- passent par supprime_le, ce qui préserve la synchronisation.
    execute format($p$
      create policy %1$s_suppression on public.%1$I
        for delete to authenticated
        using (org_id = public.mon_org() and public.est_direction())
    $p$, t);

  end loop;
end;
$$;

-- Les tables filles héritent des droits de leur prospect ou mandat.

do $$
declare t text;
begin
  foreach t in array array['prospect_notes', 'prospect_activites',
                           'prospect_relances', 'prospect_documents',
                           'prospect_etapes'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format($p$
      create policy %1$s_acces on public.%1$I
        for all to authenticated
        using (exists (select 1 from public.prospects p
                        where p.id = %1$I.prospect_id
                          and p.org_id = public.mon_org()
                          and (p.attribue_a = auth.uid() or public.est_direction())))
        with check (exists (select 1 from public.prospects p
                        where p.id = %1$I.prospect_id
                          and p.org_id = public.mon_org()
                          and (p.attribue_a = auth.uid() or public.est_direction())))
    $p$, t);
  end loop;
end;
$$;

alter table public.mandat_photos enable row level security;
create policy mandat_photos_acces on public.mandat_photos
  for all to authenticated
  using (exists (select 1 from public.mandats m
                  where m.id = mandat_photos.mandat_id
                    and m.org_id = public.mon_org()
                    and (m.attribue_a = auth.uid() or public.est_direction())))
  with check (exists (select 1 from public.mandats m
                  where m.id = mandat_photos.mandat_id
                    and m.org_id = public.mon_org()
                    and (m.attribue_a = auth.uid() or public.est_direction())));

-- ── Distribution des leads par la direction ─────────────────────
-- Seul chemin d'attribution. Un agent ne peut pas l'appeler à son
-- profit : la fonction vérifie le rôle avant toute chose.

create or replace function public.attribuer_lead(
  p_table text,
  p_id    uuid,
  p_agent uuid
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_org uuid := public.mon_org();
begin
  if not public.est_direction() then
    raise exception 'Seule la direction peut attribuer un lead'
      using errcode = 'insufficient_privilege';
  end if;

  if p_table not in ('prospects', 'mandats', 'rdvs') then
    raise exception 'Table non autorisée : %', p_table;
  end if;

  if p_agent is not null
     and not exists (select 1 from public.membres
                      where utilisateur_id = p_agent and org_id = v_org) then
    raise exception 'Ce commercial ne fait pas partie de votre organisation';
  end if;

  execute format(
    'update public.%I set attribue_a = $1 where id = $2 and org_id = $3', p_table)
    using p_agent, p_id, v_org;

  if not found then
    raise exception 'Lead introuvable dans votre organisation';
  end if;

  insert into public.audit_log (actor_id, actor_email, action, target_type, target_id, details)
  values (
    auth.uid(),
    coalesce((select email from public.profiles where id = auth.uid()), 'inconnu'),
    'lead.attribue', p_table, p_id::text,
    jsonb_build_object('agent', p_agent, 'org', v_org));

  return true;
end;
$$;

comment on function public.attribuer_lead(text, uuid, uuid) is
  'Attribue un lead à un commercial. Réservé à la direction, tracé dans audit_log. p_agent NULL remet le lead au vivier.';

revoke all on function public.attribuer_lead(text, uuid, uuid) from public;
grant execute on function public.attribuer_lead(text, uuid, uuid) to authenticated;

commit;
