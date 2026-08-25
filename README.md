# mon-crm-immo

CRM pour agents immobiliers, centré sur l'acquisition de prospects
publicitaires. En ligne : **https://mon-crm-immo.fr**

> **Trois noms pour une même chose.** Le produit s'appelle
> `mon-crm-immo`, le dossier et le dépôt s'appellent encore
> `immoai-pro` (ancien nom), et les clés de stockage historiques sont
> préfixées `immoai_`. Renommer touche beaucoup de lignes ; tant que ce
> n'est pas fait, retenir que **les trois désignent le même projet**.

## Ce que fait le produit

Un agent connecte son compte publicitaire Facebook. Les prospects
générés par ses annonces arrivent directement dans son pipeline, les
relances partent toutes seules, et le coût par lead se lit à côté des
mandats réellement signés.

Deux usages : l'agent indépendant, et l'agence dont la direction
distribue les leads à ses commerciaux.

## Où se trouve quoi

| Chemin | Rôle |
|---|---|
| **`app/index.html`** | **L'application** — HTML, CSS et JS en un seul fichier (~720 Ko) |
| `app/js/donnees.js` | Couche de données : correspondance app ↔ base, synchronisation |
| `app/js/donnees.test.js` | 41 tests — `node app/js/donnees.test.js` |
| `supabase/migrations/` | Le schéma, versionné et ordonné. Voir son propre README |
| `supabase/functions/` | Fonctions serveur : webhook Stripe, alertes admin |
| `index.html` | Site vitrine (racine du domaine) |
| `tarifs/`, `merci/`, `legal/`, `blog/` | Pages marketing, légales, 21 articles |
| `assets/styles.css` | CSS du site vitrine **uniquement** — l'app a le sien, en interne |
| `vercel.json` | Réécritures. `/app/js/` est exclu, sinon le module ne serait pas servi |

**Pour travailler sur le CRM, c'est `app/index.html`.** Tout le reste
est du contenu ou de l'infrastructure.

## Comment ça tourne

Pas de build, pas de bundler, pas de `package.json`. Des fichiers
statiques sur Vercel, Supabase en backend.

```bash
python3 -m http.server 8000     # http://localhost:8000/app/index.html
git push origin main            # Vercel déploie
```

Dépendances, toutes en CDN : `@supabase/supabase-js@2`, `leaflet@1.9.4`,
Google Fonts.

## Le parcours, de A à Z

### 1 · Entrer dans le produit

Trois portes, une seule destination — un compte rattaché à une
organisation.

| Porte | Parcours | État |
|---|---|---|
| **Essai libre** | Inscription → organisation solo → 14 jours d'essai | ✅ |
| **Invitation** | Lien reçu → compte créé → rejoint l'agence avec son rôle | ✅ |
| **Après paiement** | Stripe → webhook → plan de l'organisation mis à jour | ⏳ à câbler |

Le code d'activation existe encore, en chemin secondaire replié. Il
n'est plus le passage obligé qu'il était.

### 2 · La règle centrale

Tout tourne autour de l'**organisation**. Un agent indépendant est une
organisation d'une personne — pas de cas particulier, un seul modèle de
droits pour tout le monde.

```sql
org_id = mon_org() and (attribue_a = auth.uid() or est_direction())
```

Un commercial ne voit que ses leads. Il peut en céder un, jamais s'en
attribuer un. La direction voit tout et distribue via
`attribuer_lead()`. C'est Postgres qui refuse, pas l'interface.

### 3 · Où vivent les données

**Supabase est la source de vérité. localStorage n'est qu'un cache de
lecture hors ligne.**

Toute écriture passe par `app/js/donnees.js` :

```
l'app mute son tableau  →  saveP_()  →  différentiel contre le cache
                                     →  file d'attente persistante
                                     →  envoi groupé vers Supabase
```

Trois principes qui expliquent le code :

- **Correspondance explicite.** Ce qui n'est pas déclaré n'est pas
  envoyé. L'ancienne synchro expédiait l'objet entier — 38 champs pour
  15 colonnes — et PostgREST rejetait tout en 400.
- **Pierres tombales.** `supprime_le`, jamais de suppression physique.
  Sans trace, un autre appareil ne peut pas apprendre la suppression.
- **File persistante.** Elle survit à un rechargement en plein vol, et
  regroupe les rafales : dix sauvegardes ne déclenchent qu'un envoi.

### 4 · Modules

| Module | État |
|---|---|
| Prospects, Pipeline, Mandats, Agenda | actifs |
| Mon équipe — membres, rôles, invitations, distribution | actif |
| Acquisition Facebook — budget, leads, coût par lead | à construire |
| Automatisations de relance | à construire |
| Assistants IA, Studio Visuel | **en veille** — `MODULES_IA_ACTIFS = false` |
| Finance | codé, masqué derrière un écran « bientôt » |

Les modules IA ne sont pas supprimés : leur code est intact et un seul
drapeau les rouvre.

## Conventions

- **Tout en français** : identifiants, commentaires, textes d'interface.
  Seules `created_at` et `updated_at` restent en anglais, colonnes
  techniques déjà présentes partout.
- **CSS** : variables dans `:root`, sections séparées par des bandeaux
  `/* ══ NOM ══ */`. Pas de framework.
- **JS** : `function` classiques, pas de modules ES, pas de framework.
  Handlers en `onclick` dans le HTML.
- **Commits** : `feat:` / `fix:` / `docs:`, en français.

## À savoir avant de modifier

**`app/index.html` fait 720 Ko en un fichier.** Toute recherche se fait
au `grep`. Deux règles apprises à la dure :

1. **Jamais d'expression régulière gloutonne** sur ce fichier. Un `.*?`
   entre deux balises identiques traverse allègrement la moitié du
   document. Remplacements exacts, avec assertion sur le nombre
   d'occurrences.
2. **Toujours vérifier la syntaxe après édition** :
   ```bash
   python3 -c "import io,re;s=io.open('app/index.html',encoding='utf-8').read();[io.open(f'/tmp/b{i}.js','w').write(b) for i,b in enumerate(re.findall(r'<script>(.*?)</script>',s,re.S))]"
   node --check /tmp/b0.js && node --check /tmp/b1.js
   ```

**Le schéma se pose à la main.** Tant que le distant n'est pas aligné,
`supabase db push` est inutilisable : coller chaque migration dans le
SQL Editor, dans l'ordre.

## Chantiers ouverts

1. **Business Verification Meta** — chemin critique du produit, délai
   incompressible, à déposer au plus tôt
2. Espace Acquisition : connexion Facebook, budget, leads, coût par lead
3. Automatisations de relance
4. Webhook Stripe à basculer sur `organisations` et gérer les sièges
5. Interface mobile — l'app n'a aucune requête `@media`
6. Politique de confidentialité à corriger : elle annonce Frankfurt
   (le projet est à Paris) et décrit un stockage qui a changé

## Compte de démonstration

Il n'y en a plus. Le compte en dur `agent@immoai.pro` a été retiré : il
comparait un mot de passe en clair et contournait Supabase. Créer un
compte d'essai prend trente secondes.
