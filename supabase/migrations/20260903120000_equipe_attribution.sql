-- ═══════════════════════════════════════════════════════════════
-- 17 · mon_equipe() DOIT DIRE QUI REÇOIT LES LEADS
-- ═══════════════════════════════════════════════════════════════
--
-- L'écran Leads propose à la direction de choisir le destinataire des
-- leads entrants. Le menu affichait « personne » alors que la base
-- désignait bien Simon : mon_equipe() a été écrite avant la colonne
-- attribution_par_defaut et ne la renvoyait pas.
--
-- Un menu qui affiche le contraire de la vérité est pire qu'un menu
-- absent : la direction croit corriger un oubli, et écrase en réalité
-- un réglage correct.
--
-- On ajoute aussi les membres désactivés à l'exclusion : un départ ne
-- doit plus figurer dans la liste des destinataires possibles.
--
-- ═══════════════════════════════════════════════════════════════

begin;

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
  if v_org is null then
    return jsonb_build_object('erreur', 'aucune organisation');
  end if;

  select jsonb_build_object(
    'organisation', (
      select jsonb_build_object(
               'id', o.id, 'nom', o.nom, 'type', o.type,
               'plan', o.plan, 'sieges', o.sieges,
               'slug', o.slug,
               -- La clé qui manquait.
               'attributionParDefaut', o.attribution_par_defaut)
        from public.organisations o where o.id = v_org),
    'monRole', public.mon_role(),
    'membres', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', m.utilisateur_id, 'role', m.role,
               'email', p.email, 'prenom', m.prenom, 'nom', m.nom,
               'prospects', (select count(*) from public.prospects x
                              where x.attribue_a = m.utilisateur_id and x.supprime_le is null),
               'mandats',   (select count(*) from public.mandats x
                              where x.attribue_a = m.utilisateur_id and x.supprime_le is null))
             order by case m.role when 'proprietaire' then 1 when 'direction' then 2 else 3 end,
                      m.nom)
        from public.membres m
        left join public.profiles p on p.id = m.utilisateur_id
       where m.org_id = v_org
         -- Un collaborateur parti n'est plus un destinataire possible.
         and m.desactive_le is null), '[]'::jsonb),
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

-- prenom et nom sont désormais lus depuis `membres` plutôt que
-- `profiles` : c'est là que la fonction edge « equipe » les écrit à la
-- création d'un compte, et profiles n'est pas toujours renseigné.

revoke all on function public.mon_equipe() from anon;
grant execute on function public.mon_equipe() to authenticated;

commit;
