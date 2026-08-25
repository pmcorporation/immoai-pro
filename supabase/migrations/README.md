# Migrations SQL — mon-crm-immo

Le schéma vit ici, plus uniquement sur le projet Supabase distant.

## Ordre d'application

| Fichier | Contenu |
|---|---|
| `20260824130000_fondations.sql` | Extensions, déclencheur `updated_at`, outillage. Ne dépend d'aucune table. |
| `20260824130100_organisations.sql` | Organisations, membres, rôles, contrôle des sièges, **fonctions de contexte RLS** |
| `20260824130200_crm.sql` | Prospects, mandats, rendez-vous et tables filles |
| `20260824130300_partages_mandat.sql` | Partage de mandat avec un agent extérieur |

Les fichiers 03 et 04 refusent de s'exécuter si les tables concernées
contiennent des lignes. C'est volontaire : ils recréent des tables
vides, et doivent échouer plutôt que détruire des données.

## Ordre à l'intérieur d'un fichier

Une fonction `language sql` voit son corps analysé dès sa création :
elle refuse de naître si les tables qu'elle lit n'existent pas encore.
C'est pourquoi `mon_org()`, `mon_role()`, `est_direction()` et
`mon_plan()` vivent dans le fichier 02, après `membres`, et non dans
les fondations. Les fonctions `plpgsql` n'ont pas cette contrainte —
leur corps n'est vérifié qu'à l'exécution.

## Conventions

**Identifiants** — `uuid` généré par le serveur.
L'application produisait `'p' || Date.now()` côté client : deux
commerciaux créant une fiche dans la même milliseconde entraient en
collision. Résolution milliseconde, portée mondiale, aucune garantie.

**Vocabulaire** — français pour tout ce qui relève du métier
(`attribue_a`, `relance_le`, `honoraires`, `secteur`), conformément aux
conventions du projet. Seules `created_at` et `updated_at` restent en
anglais : colonnes techniques, déjà présentes sur les quatorze tables
existantes et attendues par l'outillage Supabase.

**Horodatage** — `updated_at` est posé par déclencheur, jamais par le
client. Un navigateur peut mentir sur l'heure ; c'est ce qui rend une
résolution de conflit fiable.

**Suppression** — `supprime_le timestamptz`, jamais de `DELETE` physique
sur les tables métier. Sans cette pierre tombale, une suppression faite
sur un appareil ne peut pas être propagée aux autres : c'est la cause
directe des prospects qui réapparaissaient après suppression.

**Intégrité** — toute clé étrangère est déclarée et indexée ; tout champ
à valeurs finies porte une contrainte `check`. Les valeurs autorisées
sont reprises des constantes de l'application (`STAGES`, `RDV_TYPES`,
`ACT_LABELS`) et doivent être modifiées des deux côtés en même temps.

**Sécurité** — RLS activé sur toutes les tables, politiques adressées à
`authenticated` et jamais à `public`. Les fonctions sensibles sont en
`security definer` avec `search_path = ''` et un `revoke` explicite.

## La règle centrale

Un commercial ne voit que les leads qui lui sont attribués. La direction
voit tout le portefeuille de son organisation et distribue.

```sql
using (org_id = public.mon_org()
       and (attribue_a = auth.uid() or public.est_direction()))
```

Comme un agent ne peut pas *voir* la ligne d'un collègue, il ne peut ni
la modifier ni se l'attribuer. Il peut en revanche céder un lead :
donner est permis, prendre ne l'est pas. La règle est appliquée par
Postgres, pas par l'interface — elle ne se contourne pas depuis la
console du navigateur.

La distribution passe exclusivement par `attribuer_lead()`, qui vérifie
le rôle de l'appelant, vérifie que le destinataire appartient bien à
l'organisation, et trace l'opération dans `audit_log`.

## Application

Tant que le schéma distant n'est pas aligné sur ces fichiers,
`supabase db push` n'est pas utilisable. Coller le contenu de chaque
fichier dans le SQL Editor, dans l'ordre. Chacun est encadré par
`begin; … commit;` : en cas d'erreur, rien n'est appliqué.

Une fois le schéma aligné :

```bash
supabase db pull    # vérifie qu'il n'y a plus d'écart
```

## Reste à traiter

- `profiles.plan` fait doublon avec `organisations.plan` depuis le
  fichier 02. La source de vérité est `mon_plan()`. La colonne doit
  disparaître une fois le webhook Stripe et l'application basculés.
- Trois mécanismes d'administration coexistent : `profiles.is_admin`,
  la table `admin_users` et `admin_allowlist`, avec trois fonctions de
  contrôle différentes (`is_admin()`, `is_user_admin()`, et un `EXISTS`
  écrit à la main dans certaines politiques). À unifier.
- `activation_codes.email` est en `NOT NULL`, ce qui n'a pas de sens
  pour un code généré depuis le backoffice sans acheteur connu.
- Le webhook Stripe écrit dans `profiles` ; il doit écrire dans
  `organisations` et gérer le nombre de sièges.
