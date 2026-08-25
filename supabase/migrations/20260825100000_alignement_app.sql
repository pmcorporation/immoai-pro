-- ═══════════════════════════════════════════════════════════════
-- 05 · ALIGNEMENT DU SCHÉMA SUR L'APPLICATION
-- ═══════════════════════════════════════════════════════════════
--
-- Le fichier 03 a été écrit à partir des constantes JavaScript
-- (STAGES, RDV_TYPES, ACT_LABELS). Un relevé plus complet des
-- formulaires révèle des écarts qui auraient fait rejeter des
-- écritures parfaitement légitimes :
--
--   • mandats.type : l'app produit 'coexclu' et 'sousseing', là où
--     la contrainte attendait 'co-exclusivite' et ne connaissait pas
--     le sous-seing privé.
--   • La vente d'un mandat porte cinq informations dans l'app
--     (prix, date, acquéreur, commission, note), le schéma n'en
--     gardait que deux.
--   • Le téléphone du vendeur et la date de signature n'existaient
--     nulle part.
--   • Le champ « prospect » d'un rendez-vous est une saisie libre,
--     pas un choix dans une liste : un RDV chez le notaire ou à la
--     banque n'a pas de prospect associé.
--
-- Règle tirée de l'expérience : toute contrainte check doit être
-- relevée depuis le formulaire, pas depuis la constante d'affichage.
--
-- ═══════════════════════════════════════════════════════════════

begin;

-- ── Mandats : type ──────────────────────────────────────────────

alter table public.mandats drop constraint if exists mandats_type_check;
alter table public.mandats add constraint mandats_type_check
  check (type in ('simple', 'exclusif', 'coexclu', 'recherche', 'sousseing'));

comment on column public.mandats.type is
  'Valeurs alignées sur le select #m-type de l''application.';

-- ── Mandats : informations manquantes ───────────────────────────

alter table public.mandats add column if not exists vendeur_tel     text;
alter table public.mandats add column if not exists date_signature  date;

alter table public.mandats add column if not exists statut text not null default 'actif';
alter table public.mandats drop constraint if exists mandats_statut_check;
alter table public.mandats add constraint mandats_statut_check
  check (statut in ('actif', 'attente', 'vendu', 'expire', 'resilie'));

comment on column public.mandats.statut is
  'Cycle de vie du mandat. La colonne vendu reste le drapeau de vente effective.';

-- ── Mandats : détail de la vente ────────────────────────────────

alter table public.mandats add column if not exists vendu_acquereur  text;
alter table public.mandats add column if not exists vendu_commission numeric(12,2)
  check (vendu_commission is null or vendu_commission >= 0);
alter table public.mandats add column if not exists vendu_note       text;

-- Un mandat vendu doit porter son prix et sa date ; l'acquéreur et la
-- commission peuvent arriver plus tard, ils ne sont pas exigés.
alter table public.mandats drop constraint if exists mandats_vente_coherente;
alter table public.mandats add constraint mandats_vente_coherente
  check (not vendu or (vendu_prix is not null and vendu_le is not null));

-- Cohérence entre le drapeau et le statut, sans les rendre redondants :
-- un mandat vendu porte forcément le statut correspondant.
alter table public.mandats drop constraint if exists mandats_statut_vente;
alter table public.mandats add constraint mandats_statut_vente
  check (not vendu or statut = 'vendu');

-- ── Rendez-vous : interlocuteur en saisie libre ─────────────────

alter table public.rdvs add column if not exists avec_qui text;

comment on column public.rdvs.avec_qui is
  'Interlocuteur en texte libre, pour un rendez-vous sans prospect associé
   (notaire, banque, diagnostiqueur). Complète prospect_id, ne le remplace pas.';

-- ── Index utiles au tri courant ─────────────────────────────────

create index if not exists mandats_statut_idx
  on public.mandats (org_id, statut) where supprime_le is null;

create index if not exists mandats_expiration_idx
  on public.mandats (attribue_a, date_expiration)
  where supprime_le is null and date_expiration is not null;

commit;
