-- ═══════════════════════════════════════════════════════════════
-- 11 · CORRECTIF DE SÉCURITÉ — garde administrateur inversée
-- ═══════════════════════════════════════════════════════════════
--
-- Le fichier 10 protégeait ses deux fonctions ainsi :
--
--     if auth.uid() is not null and not public.is_admin() then
--       raise exception 'Réservé à l''administration';
--     end if;
--
-- L'intention était de laisser passer le SQL Editor, où il n'y a pas
-- de session. Mais un visiteur anonyme n'a pas de session non plus :
-- auth.uid() y vaut null, la condition est fausse, et la fonction
-- répondait. etat_agences() livrait donc la liste des organisations,
-- leurs plans, leurs sièges et leurs volumes à qui la demandait.
--
-- La bonne distinction n'est pas « avec ou sans session » mais « quel
-- rôle exécute la requête » :
--
--   • SQL Editor          → session_user = 'postgres'
--   • appel via l'API     → session_user = 'authenticator'
--
-- On exige donc explicitement l'un ou l'autre : administrateur
-- authentifié, ou exécution directe en base. Le silence n'ouvre plus
-- la porte.
--
-- ═══════════════════════════════════════════════════════════════

begin;

-- Garde commune, pour ne pas réécrire la même condition à deux
-- endroits et risquer de n'en corriger qu'un.
create or replace function public.exige_administration()
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if session_user = 'postgres' then return; end if;   -- SQL Editor
  if auth.uid() is not null and public.is_admin() then return; end if;
  raise exception 'Réservé à l''administration'
    using errcode = 'insufficient_privilege';
end;
$$;

revoke all on function public.exige_administration() from public;

create or replace function public.etat_agences()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform public.exige_administration();

  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'organisation', o.nom,
             'type',   o.type,
             'plan',   o.plan,
             'sieges', o.sieges,
             'occupes', (select count(*) from public.membres m where m.org_id = o.id),
             'invitationsEnAttente', (select count(*) from public.invitations v
                                       where v.org_id = o.id and v.accepte_le is null
                                         and v.annule_le is null and v.expire_le > now()),
             'prospects', (select count(*) from public.prospects p
                            where p.org_id = o.id and p.supprime_le is null),
             'essaiFinLe', o.essai_fin_le)
           order by o.created_at)
      from public.organisations o), '[]'::jsonb);
end;
$$;

create or replace function public.installer_agence(
  p_email   text,
  p_nom     text    default null,
  p_sieges  integer default 5,
  p_plan    text    default 'agency',
  p_jours_essai integer default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid;
  v_org  uuid;
  v_res  jsonb;
begin
  perform public.exige_administration();

  if p_plan not in ('free', 'starter', 'pro', 'agency') then
    raise exception 'Plan inconnu : %', p_plan;
  end if;
  if p_sieges < 1 then
    raise exception 'Il faut au moins un siège';
  end if;

  select id into v_user from public.profiles where lower(email) = lower(trim(p_email));
  if v_user is null then
    raise exception 'Aucun compte pour %. Créez-le d''abord dans Authentication → Users.', p_email;
  end if;

  select org_id into v_org from public.membres where utilisateur_id = v_user;
  if v_org is null then
    raise exception 'Ce compte n''a pas d''organisation. Vérifiez le déclencheur profils_org_par_defaut.';
  end if;

  update public.organisations
     set type   = 'agence',
         nom    = coalesce(nullif(trim(p_nom), ''), nom),
         sieges = p_sieges,
         plan   = p_plan,
         essai_fin_le = case
           when p_jours_essai is null then null
           else now() + (p_jours_essai || ' days')::interval end,
         statut_abonnement = case when p_plan = 'free' then null else 'active' end
   where id = v_org;

  update public.membres
     set role = 'proprietaire'
   where org_id = v_org and utilisateur_id = v_user
     and role <> 'proprietaire';

  select jsonb_build_object(
    'organisation', o.nom, 'type', o.type, 'plan', o.plan,
    'sieges', o.sieges,
    'occupes', (select count(*) from public.membres where org_id = o.id),
    'essaiFinLe', o.essai_fin_le, 'dirigeant', p_email
  ) into v_res
  from public.organisations o where o.id = v_org;

  insert into public.audit_log (actor_id, actor_email, action, target_type, target_id, details)
  values (auth.uid(),
          coalesce((select email from public.profiles where id = auth.uid()), 'sql-editor'),
          'agence.installee', 'organisation', v_org::text, v_res);

  return v_res;
end;
$$;

revoke all on function public.etat_agences() from public;
revoke all on function public.installer_agence(text, text, integer, text, integer) from public;
grant execute on function public.etat_agences() to authenticated;
grant execute on function public.installer_agence(text, text, integer, text, integer) to authenticated;

commit;
