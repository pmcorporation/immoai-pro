-- ═══════════════════════════════════════════════════════════════
-- 20 · ÉTAT CIBLE — CONSOLIDATION DES FICHIERS 17, 18 ET 19
-- ═══════════════════════════════════════════════════════════════
--
-- Les trois fichiers précédents n'ont pas été appliqués, et ils se
-- contredisent : le 18 élargit l'écriture dans le vivier partagé, le
-- 19 ferme ce vivier. Les rejouer dans l'ordre ferait passer la base
-- par un état intermédiaire qu'elle n'a aucune raison de connaître.
--
-- Celui-ci décrit directement l'état voulu. Il remplace les fichiers
-- 17, 18 et 19, qui ne doivent PAS être appliqués.
--
-- Il est écrit pour être rejouable : chaque objet est supprimé avant
-- d'être recréé, et rien ne dépend de l'ordre dans lequel on l'exécute
-- plusieurs fois.
--
-- CE QU'IL ÉTABLIT
--
--   1. Le vivier partagé est fermé. Un commercial ne voit que ce qui
--      lui est attribué ; la direction voit tout.
--   2. Personne ne peut se servir : prendre_lead() disparaît.
--      La direction distribue, via distribuer_lead().
--   3. Tout lead entrant arrive chez Isabelle.
--   4. mon_equipe() dit enfin qui reçoit les leads, lit les noms là où
--      ils sont réellement écrits, et ignore les membres partis.
--   5. Les fonctions sensibles cessent d'être joignables sans session.
--
-- ═══════════════════════════════════════════════════════════════

begin;

-- ═══ 1. FERMER LE VIVIER PARTAGÉ ═══════════════════════════════
--
-- Ces politiques s'ajoutaient aux règles nominatives par OU. Les
-- retirer suffit à rétablir le cloisonnement : chacun ses leads.
--
-- Le vivier reposait sur un pari — celui qui est disponible décroche,
-- la vitesse prime. Il ne tenait pas ici, parce qu'il cohabitait avec
-- une attribution automatique : chaque lead portait un nom dès la
-- seconde zéro tout en étant ouvert à tous. Deux modèles
-- contradictoires, et un lead peut refroidir pendant que plusieurs
-- personnes pensent qu'une autre s'en occupe.

drop policy if exists prospects_vivier_lecture on public.prospects;
drop policy if exists prospects_vivier_prise   on public.prospects;
drop policy if exists activites_vivier         on public.prospect_activites;
drop policy if exists notes_vivier             on public.prospect_notes;

-- ═══ 2. PERSONNE NE SE SERT ════════════════════════════════════
--
-- prendre_lead() permettait à un commercial de s'attribuer un lead.
-- C'était la contrepartie du vivier ; sans vivier, c'est un vol.
-- Supprimée plutôt que restreinte : une fonction qui ne sert plus
-- mais reste exécutable est une surface d'attaque que personne ne
-- pense à relire.

drop function if exists public.prendre_lead(uuid);

-- ceder_lead() reste : donner ce qu'on détient a toujours été permis,
-- et un commercial qui part en congés doit pouvoir passer la main
-- sans attendre. Prendre reste impossible.

-- ═══ 3. LA DIRECTION DISTRIBUE ═════════════════════════════════

create or replace function public.distribuer_lead(p_prospect uuid, p_vers uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_org    uuid := public.mon_org();
  v_actuel uuid;
begin
  if not public.est_direction() then
    raise exception 'Seule la direction distribue les leads'
      using errcode = 'insufficient_privilege';
  end if;

  select attribue_a into v_actuel
    from public.prospects
   where id = p_prospect and org_id = v_org and supprime_le is null;

  if not found then
    raise exception 'Ce lead n''existe pas dans votre organisation';
  end if;

  -- Le destinataire doit être actif : distribuer à quelqu'un qui vient
  -- de partir revient à faire disparaître le lead, sans que personne
  -- ne s'en aperçoive.
  if p_vers is not null and not exists (
       select 1 from public.membres
        where utilisateur_id = p_vers and org_id = v_org and desactive_le is null) then
    raise exception 'Ce membre ne fait pas partie de l''équipe';
  end if;

  update public.prospects
     set attribue_a = p_vers, updated_at = now()
   where id = p_prospect;

  insert into public.audit_log (actor_id, action, target_type, target_id, details)
  values (auth.uid(), 'lead.distribue', 'prospect', p_prospect::text,
          jsonb_build_object('de', v_actuel, 'vers', p_vers));

  return jsonb_build_object('ok', true);
end;
$$;

-- ═══ 4. mon_equipe() DIT QUI REÇOIT LES LEADS ══════════════════
--
-- L'écran affichait « personne » alors que la base désignait
-- quelqu'un : la fonction a été écrite avant la colonne
-- attribution_par_defaut. Un menu qui affiche le contraire de la
-- vérité est pire qu'un menu absent — la direction croit corriger un
-- oubli et écrase un réglage correct.

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
               'plan', o.plan, 'sieges', o.sieges, 'slug', o.slug,
               'attributionParDefaut', o.attribution_par_defaut)
        from public.organisations o where o.id = v_org),
    'monRole', public.mon_role(),
    'membres', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', m.utilisateur_id, 'role', m.role,
               'email', p.email,
               -- prenom et nom viennent d'abord de `membres` : c'est là
               -- que la fonction edge « equipe » les écrit à la création
               -- d'un compte, et profiles n'est pas toujours renseigné.
               'prenom', coalesce(m.prenom, p.prenom),
               'nom',    coalesce(m.nom, p.nom),
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

-- ═══ 5. RÉVOQUER SUR PUBLIC, PAS SEULEMENT SUR anon ════════════
--
-- Leçon apprise deux fois : le droit d'exécution vient du pseudo-rôle
-- PUBLIC, et « revoke from anon » ne retire pas un droit hérité de
-- PUBLIC. Il faut révoquer sur les deux.

revoke all on function public.distribuer_lead(uuid, uuid) from public, anon;
revoke all on function public.ceder_lead(uuid, uuid)      from public, anon;
revoke all on function public.mon_equipe()                from public, anon;
revoke all on function public.definir_attribution_par_defaut(uuid) from public, anon;
revoke all on function public.mdp_change()                from public, anon;
revoke all on function public.est_direction()             from public, anon;
revoke all on function public.mon_org()                   from public, anon;

grant execute on function public.distribuer_lead(uuid, uuid) to authenticated;
grant execute on function public.ceder_lead(uuid, uuid)      to authenticated;
grant execute on function public.mon_equipe()                to authenticated;
grant execute on function public.definir_attribution_par_defaut(uuid) to authenticated;
grant execute on function public.mdp_change()                to authenticated;
grant execute on function public.est_direction()             to authenticated;
grant execute on function public.mon_org()                   to authenticated;

-- annuaire_connexion() reste ouverte à anon, et c'est délibéré :
-- l'écran de connexion affiche les visages avant toute
-- authentification. C'est la seule dans ce cas, et elle ne renvoie que
-- ce qui est déjà publié sur le site de l'agence.
grant execute on function public.annuaire_connexion(text) to anon, authenticated;

-- ═══ 6. TOUT ARRIVE CHEZ ISABELLE ══════════════════════════════

update public.organisations o
   set attribution_par_defaut = (
     select m.utilisateur_id from public.membres m
      where m.org_id = o.id and lower(m.prenom) = 'isabelle'
        and m.desactive_le is null
      limit 1)
 where o.slug = 'manalex';

commit;

-- ═══════════════════════════════════════════════════════════════
-- VÉRIFICATION — trois lignes attendues
-- ═══════════════════════════════════════════════════════════════

select 'destinataire des leads' as controle,
       coalesce((select m.prenom || ' ' || m.nom
                   from public.membres m
                   join public.organisations o on o.attribution_par_defaut = m.utilisateur_id
                  where o.slug = 'manalex'), '⚠ AUCUN') as resultat,
       'doit afficher Isabelle Lacroix' as attendu

union all

select 'politiques du vivier',
       (select count(*)::text from pg_policies
         where schemaname = 'public' and policyname like '%vivier%'),
       'doit afficher 0'

union all

select 'prendre_lead',
       case when exists (select 1 from pg_proc p
                          join pg_namespace n on n.oid = p.pronamespace
                         where n.nspname = 'public' and p.proname = 'prendre_lead')
            then '⚠ EXISTE ENCORE' else 'supprimée' end,
       'doit afficher supprimée';
