-- ═══════════════════════════════════════════════════════════════
-- 16 · CÉDER UN LEAD À UN COLLÈGUE
-- ═══════════════════════════════════════════════════════════════
--
-- attribuer_lead() est réservée à la direction. C'était voulu : on ne
-- veut pas qu'un commercial se serve dans le portefeuille d'un autre.
--
-- Mais l'inverse doit rester possible. Un agent qui part en congés,
-- qui reconnaît un contact déjà suivi par un collègue, ou qui n'est
-- pas sur le bon secteur doit pouvoir passer la main sans attendre
-- que la direction s'en aperçoive. Un lead payé qui attend une
-- validation hiérarchique est un lead qui refroidit.
--
-- La règle tient en une phrase : donner est permis, prendre ne l'est
-- pas. On ne peut céder que ce qu'on détient — le `where` sur
-- attribue_a s'en assure — et la direction garde le droit de trancher
-- pour tout le monde.
--
-- ═══════════════════════════════════════════════════════════════

begin;

create or replace function public.ceder_lead(p_prospect uuid, p_vers uuid)
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

  -- Détenteur ou direction. Un tiers ne peut pas déplacer le travail
  -- d'un collègue vers un autre collègue.
  if v_actuel is distinct from auth.uid() and not public.est_direction() then
    raise exception 'Vous ne pouvez céder que les leads qui vous sont attribués'
      using errcode = 'insufficient_privilege';
  end if;

  if p_vers is null then
    raise exception 'Indiquez à qui céder ce lead';
  end if;

  -- Le destinataire doit être dans l'organisation ET actif : céder à
  -- quelqu'un qui vient de partir revient à jeter le lead.
  if not exists (select 1 from public.membres
                  where utilisateur_id = p_vers and org_id = v_org
                    and desactive_le is null) then
    raise exception 'Ce collègue ne fait pas partie de l''équipe';
  end if;

  update public.prospects
     set attribue_a = p_vers, updated_at = now()
   where id = p_prospect;

  insert into public.audit_log (actor_id, action, target_type, target_id, details)
  values (auth.uid(), 'lead.cede', 'prospect', p_prospect::text,
          jsonb_build_object('de', v_actuel, 'vers', p_vers));

  return jsonb_build_object('ok', true);
end;
$$;

comment on function public.ceder_lead(uuid, uuid) is
  'Passer la main sur un lead. Donner est permis, prendre ne l''est pas.';

revoke all on function public.ceder_lead(uuid, uuid) from anon;
grant execute on function public.ceder_lead(uuid, uuid) to authenticated;

commit;
