-- ═══════════════════════════════════════════════════════════════
-- 01 · FONDATIONS
-- ═══════════════════════════════════════════════════════════════
--
-- Ce fichier ne dépend d'aucune table : uniquement des extensions et
-- de l'outillage réutilisé partout ensuite. Les fonctions de contexte
-- (mon_org, est_direction…) vivent dans le fichier 02, avec la table
-- `membres` qu'elles interrogent — une fonction `language sql` voit
-- son corps analysé dès sa création et exige que ses tables existent.
--
-- Conventions retenues pour tout le schéma :
--
--   IDENTIFIANTS   uuid généré par le serveur. Jamais par le client :
--                  l'app produisait 'p' || Date.now(), ce qui entre en
--                  collision dès que deux agents créent une fiche dans
--                  la même milliseconde — cas courant en agence.
--
--   HORODATAGE     created_at / updated_at conservés en anglais : ce
--                  sont des colonnes techniques, présentes sur toutes
--                  les tables existantes et attendues par l'outillage
--                  Supabase. Tout le reste du vocabulaire est français,
--                  conformément aux conventions du projet.
--                  updated_at est posé par déclencheur, jamais par le
--                  client — un client peut mentir sur l'heure.
--
--   SUPPRESSION    supprime_le timestamptz, jamais de DELETE physique
--                  sur les tables métier. Sans cette pierre tombale,
--                  une suppression faite sur un appareil ne peut pas
--                  être propagée aux autres : c'est la cause directe
--                  des prospects « ressuscités ».
--
--   INTÉGRITÉ      toute clé étrangère est déclarée et indexée. Tout
--                  champ à valeurs finies porte une contrainte check.
--
--   SÉCURITÉ       RLS activé partout, politiques adressées à
--                  `authenticated` et jamais à `public`. Les fonctions
--                  sensibles sont en security definer avec
--                  search_path = '' et un revoke explicite.
--
-- ═══════════════════════════════════════════════════════════════

begin;

-- ── Extensions ──────────────────────────────────────────────────

create extension if not exists pgcrypto with schema extensions;

-- ── Horodatage automatique ──────────────────────────────────────
-- Un seul déclencheur réutilisé par toutes les tables, plutôt qu'une
-- fonction par table.

create or replace function public.touch_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

comment on function public.touch_updated_at() is
  'Déclencheur générique : pose updated_at à chaque UPDATE.';

-- Applique le déclencheur à une table, sans le dupliquer s'il existe.
create or replace function public.installer_touch(p_table text)
returns void
language plpgsql
set search_path = ''
as $$
begin
  execute format(
    'drop trigger if exists touch_%1$s on public.%1$I', p_table);
  execute format(
    'create trigger touch_%1$s before update on public.%1$I
       for each row execute function public.touch_updated_at()', p_table);
end;
$$;

comment on function public.installer_touch(text) is
  'Pose le déclencheur touch_updated_at sur la table indiquée.';

revoke all on function
  public.touch_updated_at(), public.installer_touch(text)
from public;

commit;
