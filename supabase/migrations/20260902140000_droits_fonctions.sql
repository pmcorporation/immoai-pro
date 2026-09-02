-- ═══════════════════════════════════════════════════════════════
-- 13 · CORRECTIF — REVOKE SUR PUBLIC NE SUFFIT PAS
-- ═══════════════════════════════════════════════════════════════
--
-- Le fichier 12 protégeait ses fonctions ainsi :
--
--   revoke all on function ... from public;
--   grant execute on function ... to service_role;
--
-- Insuffisant. Supabase accorde explicitement l'exécution des
-- fonctions du schéma `public` aux rôles `anon` et `authenticated`.
-- Un `REVOKE ... FROM PUBLIC` retire le droit implicite attaché au
-- pseudo-rôle PUBLIC, mais laisse intacts les droits nommément
-- accordés à ces deux rôles.
--
-- Constaté, pas supposé : un client porteur de la seule clé anonyme
-- a exécuté `peut_administrer_equipe` et `mdp_change`.
--
-- Les conséquences étaient minces — `auth.uid()` vaut NULL hors
-- session, donc `mdp_change` ne touchait aucune ligne, et
-- `peut_administrer_equipe` exige deux identifiants qu'un inconnu n'a
-- pas. Ça reste une fonction `security definer` joignable sans être
-- connecté : la corriger coûte cinq lignes, la laisser coûte une
-- surface d'attaque permanente.
--
-- Règle à retenir pour toute fonction sensible ajoutée ensuite :
-- révoquer nommément sur `anon` et `authenticated`, pas seulement sur
-- PUBLIC, puis n'accorder qu'aux rôles qui en ont besoin.
--
-- ═══════════════════════════════════════════════════════════════

begin;

-- ═══ 1. RÉSERVÉE À LA FONCTION EDGE ════════════════════════════

-- Seule la fonction edge « equipe » l'interroge, et elle porte la
-- clé de service. Personne d'autre n'a de raison de l'appeler.
revoke all on function public.peut_administrer_equipe(uuid, uuid) from anon, authenticated;
grant execute on function public.peut_administrer_equipe(uuid, uuid) to service_role;

-- ═══ 2. RÉSERVÉES AUX SESSIONS OUVERTES ════════════════════════

-- Ces trois-là s'appuient sur auth.uid() : hors session elles n'ont
-- aucun sens, et les laisser joignables n'apporte rien.
revoke all on function public.mdp_change()    from anon;
revoke all on function public.est_direction() from anon;
revoke all on function public.mon_org()       from anon;

grant execute on function public.mdp_change()    to authenticated;
grant execute on function public.est_direction() to authenticated;
grant execute on function public.mon_org()       to authenticated;

-- ═══ 3. L'EXCEPTION ASSUMÉE ════════════════════════════════════

-- annuaire_connexion() reste ouverte à `anon`, et c'est délibéré :
-- l'écran de connexion affiche les visages avant toute
-- authentification. C'est la seule fonction dans ce cas, et elle ne
-- renvoie que ce qui est déjà publié sur le site de l'agence.
grant execute on function public.annuaire_connexion(text) to anon, authenticated;

commit;
