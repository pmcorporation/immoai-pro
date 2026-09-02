-- ═══════════════════════════════════════════════════════════════
-- 19 · LA DIRECTION DISTRIBUE, PERSONNE NE SE SERT
-- ═══════════════════════════════════════════════════════════════
--
-- Retour en arrière assumé sur le vivier partagé du fichier 15.
--
-- Le vivier reposait sur un pari : celui qui est disponible décroche,
-- et la vitesse prime. Le pari ne tient pas ici, parce qu'il
-- cohabitait avec une attribution automatique — chaque lead portait un
-- nom dès la seconde zéro tout en étant ouvert à tous. Les deux
-- modèles se contredisaient, et cette contradiction produit le pire
-- résultat possible : un lead peut refroidir pendant que plusieurs
-- personnes pensent qu'une autre s'en occupe.
--
-- Le modèle retenu est nominatif de bout en bout. Tout lead entrant
-- arrive chez la direction. Elle seule voit l'ensemble, et elle
-- distribue. Un commercial ne voit que ce qu'on lui a confié.
--
-- Ce que ça coûte : un lead qui arrive à 22 h attend le lendemain que
-- quelqu'un le distribue. C'est le prix de la responsabilité claire,
-- et il se paie en délai. Une distribution automatique à tour de rôle
-- lèverait ce défaut sans rouvrir le vivier — à décider plus tard, au
-- vu des délais réellement constatés.
--
-- ═══════════════════════════════════════════════════════════════

begin;

-- ═══ 1. FERMER LE VIVIER ═══════════════════════════════════════

-- Ces politiques s'ajoutaient aux règles nominatives par OU. Les
-- retirer suffit à rétablir le cloisonnement d'origine : un agent ne
-- voit que les lignes qui lui sont attribuées, la direction voit tout.
drop policy if exists prospects_vivier_lecture on public.prospects;
drop policy if exists prospects_vivier_prise   on public.prospects;
drop policy if exists activites_vivier         on public.prospect_activites;
drop policy if exists notes_vivier             on public.prospect_notes;

-- ═══ 2. PLUS PERSONNE NE SE SERT ═══════════════════════════════

-- prendre_lead() permettait à un commercial de s'attribuer un lead.
-- C'était la contrepartie du vivier ; sans vivier, c'est un vol.
-- La fonction disparaît plutôt que d'être restreinte : une fonction
-- qui ne sert plus mais reste exécutable est une surface d'attaque
-- que personne ne pense à relire.
drop function if exists public.prendre_lead(uuid);

-- ceder_lead() reste : donner ce qu'on détient a toujours été permis,
-- et un commercial qui part en congés doit pouvoir passer la main
-- sans attendre. Prendre reste impossible.

-- ═══ 3. DISTRIBUER, VU DE LA DIRECTION ═════════════════════════

-- attribuer_lead() existait déjà mais visait n'importe quelle table
-- par son nom, ce qui obligeait l'appelant à savoir ce qu'il fait.
-- Celle-ci ne fait qu'une chose, et la trace.
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

revoke all on function public.distribuer_lead(uuid, uuid) from public, anon;
grant execute on function public.distribuer_lead(uuid, uuid) to authenticated;

-- ═══ 4. TOUT ARRIVE CHEZ ISABELLE ══════════════════════════════

update public.organisations o
   set attribution_par_defaut = (
     select m.utilisateur_id from public.membres m
      where m.org_id = o.id and lower(m.prenom) = 'isabelle'
        and m.desactive_le is null
      limit 1)
 where o.slug = 'manalex';

commit;

-- ═══ Vérification ═══
-- Doit afficher Isabelle, et aucune politique « vivier ».
select
  (select m.prenom || ' ' || m.nom
     from public.membres m
     join public.organisations o on o.attribution_par_defaut = m.utilisateur_id
    where o.slug = 'manalex')                                   as leads_recus_par,
  (select count(*) from pg_policies
    where schemaname = 'public' and policyname like '%vivier%') as politiques_vivier_restantes;
