-- ═══════════════════════════════════════════════════════════════
-- 04 · PARTAGE DE MANDAT ENTRE AGENTS
-- ═══════════════════════════════════════════════════════════════
--
-- L'ancienne table shared_mandats portait un mandat_id de type text,
-- devenu incohérent maintenant que mandats.id est un uuid. Elle est
-- vide, donc recréée proprement.
--
-- Deux corrections de fond :
--   • L'ancienne politique read_published_mandats exposait agent_tel
--     et comm_shared à tout visiteur non connecté. Le partage est
--     désormais réservé aux comptes authentifiés.
--   • Le partage appartient à l'organisation, pas à l'individu : si un
--     commercial quitte l'agence, le partage reste.
--
-- ═══════════════════════════════════════════════════════════════

begin;

do $$
declare v_total bigint;
begin
  -- La table peut avoir déjà disparu si ce fichier est rejoué.
  if to_regclass('public.shared_mandats') is null then
    return;
  end if;
  execute 'select count(*) from public.shared_mandats' into v_total;
  if v_total > 0 then
    raise exception 'Refus : % partage(s) en base.', v_total;
  end if;
end;
$$;

drop table if exists public.shared_mandats cascade;

create table public.partages_mandat (
  id              uuid        primary key default extensions.gen_random_uuid(),
  mandat_id       uuid        not null references public.mandats(id) on delete cascade,
  org_id          uuid        not null references public.organisations(id) on delete cascade,
  propose_par     uuid        references auth.users(id) on delete set null,

  -- Agent destinataire, hors de l'organisation (apporteur d'affaires)
  agent_nom       text        not null check (length(trim(agent_nom)) > 0),
  agent_tel       text,
  agent_email     text,
  secteur         text,

  commission_part numeric(5,2) check (commission_part is null
                                      or commission_part between 0 and 100),
  note            text,

  statut          text        not null default 'propose'
                              check (statut in ('propose', 'accepte', 'refuse', 'clos')),
  motif_refus     text,
  repondu_le      timestamptz,

  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),

  constraint partages_refus_motive
    check (statut <> 'refuse' or motif_refus is not null)
);

comment on table  public.partages_mandat                 is 'Partage d''un mandat avec un agent extérieur, avec répartition d''honoraires.';
comment on column public.partages_mandat.commission_part is 'Part de commission cédée, en pourcentage.';

create index partages_mandat_idx  on public.partages_mandat (mandat_id);
create index partages_org_idx     on public.partages_mandat (org_id, statut);

select public.installer_touch('partages_mandat'::text);

-- ── Politiques ──────────────────────────────────────────────────
-- Même règle que les mandats : on voit le partage si l'on a accès au
-- mandat correspondant. Plus rien en lecture anonyme.

alter table public.partages_mandat enable row level security;

create policy partages_mandat_acces on public.partages_mandat
  for all to authenticated
  using (exists (select 1 from public.mandats m
                  where m.id = partages_mandat.mandat_id
                    and m.org_id = public.mon_org()
                    and (m.attribue_a = auth.uid() or public.est_direction())))
  with check (org_id = public.mon_org()
              and exists (select 1 from public.mandats m
                           where m.id = partages_mandat.mandat_id
                             and m.org_id = public.mon_org()
                             and (m.attribue_a = auth.uid() or public.est_direction())));

commit;
