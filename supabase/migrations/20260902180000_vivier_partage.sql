-- ═══════════════════════════════════════════════════════════════
-- 15 · LE VIVIER EST PARTAGÉ, LA PRISE EST NOMINATIVE
-- ═══════════════════════════════════════════════════════════════
--
-- Jusqu'ici un commercial ne voyait que les leads qui lui étaient
-- attribués. Bonne règle pour un portefeuille en cours, mauvaise pour
-- des leads publicitaires qui viennent d'arriver : celui qui est
-- disponible ne peut pas décrocher son téléphone parce que la fiche
-- appartient à un collègue en rendez-vous. Le lead refroidit pendant
-- qu'on attend la bonne personne.
--
-- On sépare donc les deux temps :
--
--   • Tant que le lead est « nouveau », il est visible de toute
--     l'équipe. C'est un vivier, pas un portefeuille.
--   • Dès que quelqu'un le travaille, il porte son nom — et les
--     règles d'origine reprennent la main.
--
-- La contrepartie est écrite dans le `with check` : toute écriture sur
-- un lead du vivier doit le laisser attribué à celui qui écrit. On ne
-- peut donc pas faire avancer un lead anonymement. « Ce lead a été
-- traité par Simon » reste vrai — c'est ce qui compte quand on paie
-- pour les faire venir.
--
-- Ces politiques s'ajoutent aux précédentes sans les remplacer :
-- PostgreSQL combine les politiques permissives par OU. L'ancienne
-- règle continue donc de protéger tout ce qui n'est pas « nouveau ».
--
-- ═══════════════════════════════════════════════════════════════

begin;

-- ═══ 1. TOUTE L'ÉQUIPE VOIT LE VIVIER ══════════════════════════

drop policy if exists prospects_vivier_lecture on public.prospects;
create policy prospects_vivier_lecture on public.prospects
  for select to authenticated
  using (org_id = public.mon_org() and etape = 'nouveau');

-- ═══ 2. PRENDRE UN LEAD, PAS LE FAIRE AVANCER ANONYMEMENT ══════

-- `using` : on ne peut agir que sur un lead encore dans le vivier.
-- `with check` : après l'écriture, il doit porter le nom de celui qui
-- a écrit. Un agent ne peut donc ni qualifier un lead sans se le
-- attribuer, ni le passer à un collègue à son insu.
drop policy if exists prospects_vivier_prise on public.prospects;
create policy prospects_vivier_prise on public.prospects
  for update to authenticated
  using      (org_id = public.mon_org() and etape = 'nouveau')
  with check (org_id = public.mon_org()
              and (attribue_a = auth.uid() or public.est_direction()));

-- ═══ 3. LES NOTES DU VIVIER SUIVENT LE VIVIER ══════════════════

-- Sans cela, deux commerciaux appelleraient le même lead sans voir
-- que l'autre a déjà essayé. La note « injoignable, rappeler ce soir »
-- n'a de valeur que si elle est lue par le suivant.
drop policy if exists activites_vivier on public.prospect_activites;
create policy activites_vivier on public.prospect_activites
  for all to authenticated
  using (exists (
    select 1 from public.prospects p
     where p.id = prospect_activites.prospect_id
       and p.org_id = public.mon_org()
       and p.etape = 'nouveau'))
  with check (exists (
    select 1 from public.prospects p
     where p.id = prospect_activites.prospect_id
       and p.org_id = public.mon_org()
       and p.etape = 'nouveau'));

drop policy if exists notes_vivier on public.prospect_notes;
create policy notes_vivier on public.prospect_notes
  for all to authenticated
  using (exists (
    select 1 from public.prospects p
     where p.id = prospect_notes.prospect_id
       and p.org_id = public.mon_org()
       and p.etape = 'nouveau'))
  with check (exists (
    select 1 from public.prospects p
     where p.id = prospect_notes.prospect_id
       and p.org_id = public.mon_org()
       and p.etape = 'nouveau'));

-- ═══ 4. PRENDRE UN LEAD, EN UN GESTE TRACÉ ═════════════════════

-- Passer par une fonction plutôt que par un UPDATE direct : la prise
-- d'un lead est l'instant où quelqu'un s'engage sur un contact payé.
-- Elle mérite d'être refusée proprement quand un collègue a été plus
-- rapide, et d'être inscrite au journal.
create or replace function public.prendre_lead(p_prospect uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_org    uuid := public.mon_org();
  v_actuel uuid;
  v_etape  text;
begin
  select attribue_a, etape into v_actuel, v_etape
    from public.prospects
   where id = p_prospect and org_id = v_org and supprime_le is null;

  if v_etape is null then
    raise exception 'Ce lead n''existe pas dans votre organisation';
  end if;

  if v_etape <> 'nouveau' then
    raise exception 'Ce lead est déjà en cours de traitement';
  end if;

  update public.prospects
     set attribue_a = auth.uid(), updated_at = now()
   where id = p_prospect;

  insert into public.audit_log (actor_id, action, target_type, target_id, details)
  values (auth.uid(), 'lead.pris', 'prospect', p_prospect::text,
          jsonb_build_object('precedent', v_actuel));

  return jsonb_build_object('ok', true, 'precedent', v_actuel);
end;
$$;

revoke all on function public.prendre_lead(uuid) from anon;
grant execute on function public.prendre_lead(uuid) to authenticated;

commit;
