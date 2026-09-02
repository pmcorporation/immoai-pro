-- ═══════════════════════════════════════════════════════════════
-- 18 · COHÉRENCE DU VIVIER
-- ═══════════════════════════════════════════════════════════════
--
-- Deux défauts relevés en auditant l'écran Leads de bout en bout.
--
-- 1. RÉVOQUER SUR `anon` NE SUFFIT PAS
--
-- prendre_lead() et ceder_lead() restaient joignables sans session.
-- Elles ne livrent rien — auth.uid() et mon_org() sont nuls hors
-- session, donc elles échouent aussitôt — mais une fonction
-- `security definer` ouverte à tous n'a pas à exister.
--
-- La cause est la même que pour le fichier 13 : le droit d'exécution
-- vient du pseudo-rôle PUBLIC, et `revoke from anon` ne retire pas un
-- droit hérité de PUBLIC. Il faut révoquer sur les deux.
--
-- 2. LE VIVIER ÉTAIT LISIBLE PAR TOUS, ÉCRIVABLE PAR UN SEUL
--
-- La politique d'écriture exigeait que le lead reste attribué à celui
-- qui écrit. Conséquence non voulue : un commercial qui notait un
-- appel sur un lead attribué à un collègue voyait sa modification
-- refusée par Postgres, et l'opération restait bloquée dans la file
-- de synchronisation, sans message.
--
-- Le défaut était invisible pour la direction, qui passe par
-- est_direction() quoi qu'il arrive. Il n'aurait frappé que les
-- agents — c'est-à-dire tout le monde sauf ceux qui testent.
--
-- La règle devient celle d'un vivier réel : qui travaille le lead le
-- prend. L'écriture reste donc nominative, mais l'attribution suit le
-- geste au lieu de le bloquer. C'est prendre_lead() côté application
-- qui pose le nom ; ici, on cesse simplement de refuser.
--
-- ═══════════════════════════════════════════════════════════════

begin;

-- ═══ 1. RÉVOCATIONS COMPLÈTES ══════════════════════════════════

revoke all on function public.prendre_lead(uuid)       from public, anon;
revoke all on function public.ceder_lead(uuid, uuid)   from public, anon;
revoke all on function public.mon_equipe()             from public, anon;
revoke all on function public.definir_attribution_par_defaut(uuid) from public, anon;

grant execute on function public.prendre_lead(uuid)     to authenticated;
grant execute on function public.ceder_lead(uuid, uuid) to authenticated;
grant execute on function public.mon_equipe()           to authenticated;
grant execute on function public.definir_attribution_par_defaut(uuid) to authenticated;

-- ═══ 2. ÉCRIRE DANS LE VIVIER SANS ÊTRE BLOQUÉ ═════════════════

-- Le `with check` ne réclame plus que l'appartenance à
-- l'organisation. Ce n'est pas un relâchement : un lead du vivier est
-- par définition à prendre, et l'application appelle prendre_lead()
-- avant toute écriture, ce qui inscrit le nom au journal.
--
-- Ce qui n'est pas relâché : dès qu'un lead quitte l'étape
-- « nouveau », cette politique cesse de s'appliquer et l'ancienne
-- reprend la main. Un portefeuille en cours reste cloisonné.
drop policy if exists prospects_vivier_prise on public.prospects;
create policy prospects_vivier_prise on public.prospects
  for update to authenticated
  using      (org_id = public.mon_org() and etape = 'nouveau')
  with check (org_id = public.mon_org());

-- ═══ 3. mon_equipe() DOIT DIRE QUI REÇOIT LES LEADS ════════════

-- L'écran affichait « personne » alors que la base désignait Simon :
-- la fonction a été écrite avant la colonne attribution_par_defaut.
-- Un menu qui affiche le contraire de la vérité est pire qu'un menu
-- absent — la direction croit corriger un oubli et écrase un réglage
-- correct.
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
               -- prenom et nom viennent de `membres` : c'est là que la
               -- fonction edge « equipe » les écrit, et profiles n'est
               -- pas toujours renseigné.
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

revoke all on function public.mon_equipe() from public, anon;
grant execute on function public.mon_equipe() to authenticated;

commit;

-- ═══ Vérification ═══
-- Doit afficher l'organisation avec son destinataire par défaut.
select o.nom, o.slug,
       (select m.prenom || ' ' || m.nom from public.membres m
         where m.utilisateur_id = o.attribution_par_defaut) as leads_attribues_a
  from public.organisations o where o.slug = 'manalex';
