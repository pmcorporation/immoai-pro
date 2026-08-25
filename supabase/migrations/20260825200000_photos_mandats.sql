-- ═══════════════════════════════════════════════════════════════
-- 09 · PHOTOS DE MANDAT — ALIGNEMENT SUR LE CODE EXISTANT
-- ═══════════════════════════════════════════════════════════════
--
-- Le fichier 03 avait déplacé les photos vers une table fille
-- mandat_photos, en supposant qu'elles étaient encore stockées en
-- base64. C'était vrai de la version que j'avais sous les yeux — mais
-- pas de celle en production : l'upload vers Supabase Storage existait
-- déjà, sur une branche que je n'avais pas.
--
-- Ce code fonctionne et fait la bonne chose. On s'aligne dessus plutôt
-- que de le réécrire : les photos restent un tableau d'URL Storage sur
-- le mandat. mandat_photos disparaît — elle n'a jamais servi, et deux
-- endroits pour la même information, c'est un endroit de trop.
--
-- ═══════════════════════════════════════════════════════════════

begin;

alter table public.mandats
  add column if not exists photos jsonb not null default '[]'::jsonb;

comment on column public.mandats.photos is
  'URL publiques des photos dans le bucket mandats-photos. Jamais de contenu binaire ici.';

-- Sécurité : on ne supprime la table fille que si elle est vide.
do $$
declare v_lignes bigint;
begin
  if to_regclass('public.mandat_photos') is null then return; end if;
  execute 'select count(*) from public.mandat_photos' into v_lignes;
  if v_lignes > 0 then
    raise exception 'mandat_photos contient % ligne(s) : migration manuelle requise', v_lignes;
  end if;
  drop table public.mandat_photos cascade;
end;
$$;

commit;
