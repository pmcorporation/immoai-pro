-- ═══════════════════════════════════════════════════════════════
-- 10 · INSTALLER UNE AGENCE
-- ═══════════════════════════════════════════════════════════════
--
-- Tout compte créé arrive en 'solo' avec un siège. Un dirigeant
-- d'agence qui tente d'inviter son premier commercial lit donc
-- « Plus de siège disponible : 1 occupé sur 1 ». Bloquant dès le
-- premier jour, et découvert devant le client si on ne le prépare pas.
--
-- Les premières agences seront installées à la main, une par une :
-- c'est le bon moment pour apprendre ce dont elles ont réellement
-- besoin avant d'automatiser quoi que ce soit. Cette fonction est
-- l'outil de cette installation manuelle — une ligne à exécuter, et
-- le compte est prêt.
--
-- ═══════════════════════════════════════════════════════════════

begin;

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
  -- Appelable depuis le SQL Editor, où il n'y a pas de session, ou par
  -- un administrateur via l'API. Jamais par un client authentifié
  -- ordinaire, ni par un visiteur : le droit d'exécution n'est pas
  -- accordé à anon.
  if auth.uid() is not null and not public.is_admin() then
    raise exception 'Réservé à l''administration'
      using errcode = 'insufficient_privilege';
  end if;

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
    raise exception 'Ce compte n''a pas d''organisation. Cas anormal — vérifiez le déclencheur profils_org_par_defaut.';
  end if;

  update public.organisations
     set type   = 'agence',
         nom    = coalesce(nullif(trim(p_nom), ''), nom),
         sieges = p_sieges,
         plan   = p_plan,
         -- Un client qui paie n'a pas d'essai en cours ; un client en
         -- démonstration en reçoit un, explicitement dimensionné.
         essai_fin_le = case
           when p_jours_essai is null then null
           else now() + (p_jours_essai || ' days')::interval end,
         statut_abonnement = case when p_plan = 'free' then null else 'active' end
   where id = v_org;

  -- Le dirigeant doit pouvoir inviter : on s'assure qu'il est bien
  -- propriétaire, et pas simple agent.
  update public.membres
     set role = 'proprietaire'
   where org_id = v_org and utilisateur_id = v_user
     and role <> 'proprietaire';

  select jsonb_build_object(
    'organisation', o.nom,
    'type',         o.type,
    'plan',         o.plan,
    'sieges',       o.sieges,
    'occupes',      (select count(*) from public.membres where org_id = o.id),
    'essaiFinLe',   o.essai_fin_le,
    'dirigeant',    p_email
  ) into v_res
  from public.organisations o where o.id = v_org;

  insert into public.audit_log (actor_id, actor_email, action, target_type, target_id, details)
  values (auth.uid(),
          coalesce((select email from public.profiles where id = auth.uid()), 'sql-editor'),
          'agence.installee', 'organisation', v_org::text, v_res);

  return v_res;
end;
$$;

comment on function public.installer_agence(text, text, integer, text, integer) is
  'Transforme un compte en agence : type, nom, sièges, plan. Outil d''installation manuelle des premiers clients.';

revoke all on function public.installer_agence(text, text, integer, text, integer) from public;
grant execute on function public.installer_agence(text, text, integer, text, integer) to authenticated;

-- ── État d'une agence, pour vérifier après coup ──

create or replace function public.etat_agences()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if auth.uid() is not null and not public.is_admin() then
    raise exception 'Réservé à l''administration'
      using errcode = 'insufficient_privilege';
  end if;

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

revoke all on function public.etat_agences() from public;
grant execute on function public.etat_agences() to authenticated;

commit;
