# CLAUDE.md — mon-crm-immo

Contexte pour Claude Code. À lire avant toute modification.

## Le projet en une phrase

`mon-crm-immo` (anciennement « ImmoAI Pro », d'où le nom du dossier `immoai-pro`) est
un CRM immobilier pour agents et mandataires indépendants, avec des assistants IA
intégrés. Produit en ligne : **https://mon-crm-immo.fr** — dépôt GitHub :
`pmcorporation/immoai-pro`.

> ⚠️ Le nom du dossier, le nom du dépôt et le nom du produit diffèrent. C'est la
> raison principale pour laquelle ce projet est difficile à retrouver.

## Les 2 fichiers qui comptent

| Fichier | Rôle | Taille |
|---|---|---|
| **`app/index.html`** | **L'application CRM entière** (HTML + CSS + JS dans un seul fichier) | ~10 300 lignes / 674 Ko |
| `index.html` | Le site vitrine / landing page (racine du domaine) | ~5 750 lignes / 204 Ko |

**Pour travailler sur le CRM, c'est `app/index.html`.** Tout le reste est du contenu
marketing ou de l'infra.

## Architecture

Pas de build, pas de bundler, pas de `package.json`. Ce sont des fichiers HTML
statiques déployés sur Vercel, avec Supabase en backend.

```
immoai-pro/
├── app/index.html          ← LE CRM (monofichier)
├── index.html              ← landing page
├── tarifs/index.html       ← page tarifs
├── merci/index.html        ← page de confirmation après paiement
├── legal/                  ← mentions, cgv, cgu, privacy
├── blog/                   ← 20 articles SEO + index
├── assets/styles.css       ← CSS du site vitrine uniquement
├── public/                 ← favicons
├── supabase/
│   ├── functions/
│   │   ├── stripe-webhook/       ← abonnements Stripe → Supabase + email Brevo
│   │   └── admin-alert-email/    ← alertes sécurité admin par email (Brevo)
│   └── migrations/         ← VIDE (voir « Points d'attention »)
├── vercel.json             ← rewrites : /app/* → /app/index.html
├── robots.txt / sitemap.xml
└── google...html           ← vérification Google Search Console
```

### Dépendances (toutes en CDN, dans le `<head>` de `app/index.html`)

- `@supabase/supabase-js@2` (UMD)
- `leaflet@1.9.4` (carte des secteurs / prospects)
- Google Fonts (Inter, Plus Jakarta Sans — le CSS référence aussi Manrope)

## Où vivent les données — important

Le stockage est **hybride**, et c'est le point le plus contre-intuitif du projet :

- **localStorage (~76 appels)** = les données métier de l'agent : prospects, mandats,
  RDV, finance, profil, réseau, logs. Clés préfixées `immoai_` :
  `immoai_crm`, `immoai_mandats`, `immoai_rdvs`, `immoai_shared`, `immoai_reseau`,
  `immoai_finance`, `immoai_logs`, `immoai_profile`, `immoai_subs`.
  Budget estimé dans le code : 5 Mo (`STORAGE_MAX_KB`).
- **sessionStorage** : `immoai_session` (session courante).
- **Supabase (~19 requêtes)** = auth, comptes et facturation :
  `profiles`, `prospects`, `rdvs`, `mandats`, `activation_codes`, `google_tokens`,
  `audit_log`, `stripe_events`, `admin_allowlist`, `admin_users_overview` (vue).

Autrement dit : les tables `prospects` / `mandats` / `rdvs` existent côté Supabase mais
l'app travaille encore majoritairement en local. Toute évolution sérieuse passe par
une décision explicite sur cette migration.

Projet Supabase : `wwqccgacezbzkbaptyup` (la clé `anon` est en clair dans
`app/index.html` — c'est normal, elle est publique).

## Fonctionnement de l'app

### Navigation
`app/index.html` est une SPA maison. Une seule fonction pilote tout :

```js
const ALL_VIEWS = ['dashboard','crm','pipeline','mandats','agenda','finance',
                   'gmb','linkedin','prosp','instagram','facebook','juridique',
                   'visual','partners','products','profile'];
function nav(btn, id) { ... }   // ~ligne 4374
```

Chaque vue est un `<div id="v-{nom}">` ; `nav()` retire/ajoute la classe `active`,
met à jour le titre de la topbar via `TB_TITLES`, appelle le `render*()` de la vue,
puis vérifie le plan (`isPlanLocked`).

### Plans et verrouillage
```js
PLAN_ACCESS.crm_only_modules = ['gmb','linkedin','prosp','instagram','facebook','juridique']
```
`free` / `crm` → ces 6 modules IA sont floutés par un overlay (`showPlanGate`).
`pro` / `agency` → tout est ouvert. Le plan vient de Supabase avec fallback
localStorage (`immoai_subs`) et un cache mémoire de 5 min (`getUserCurrentPlan`).

### Assistants IA
Appels **directs depuis le navigateur** vers `https://api.anthropic.com/v1/messages`
avec l'en-tête `anthropic-dangerous-direct-browser-access: true`. La clé API est
saisie par l'utilisateur (doit commencer par `sk-ant`) et stockée côté client.
Prompts système regroupés dans l'objet `SP` (un par assistant).
Modèles actuellement référencés : `claude-haiku-4-5-20251001`,
`claude-sonnet-4-20250514`, `claude-opus-4-6`.

### Intégrations
- **Google Calendar** : OAuth via `signInWithOAuth`, tokens dans `google_tokens`,
  lecture/écriture d'events sur `calendar/v3/calendars/primary/events`.
- **Stripe** : géré côté edge function `stripe-webhook` (jamais côté client).
- **Brevo** : emails transactionnels et alertes admin.

## Commandes

Il n'y a rien à installer ni à compiler.

```bash
# Prévisualiser en local
python3 -m http.server 8000
# puis http://localhost:8000/app/index.html

# Déployer : un push sur main suffit (Vercel auto-deploy)
git push origin main

# Edge functions
supabase functions deploy stripe-webhook
supabase functions deploy admin-alert-email
```

Secrets des edge functions (à définir dans Supabase, jamais dans le dépôt) :
`STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET`, `SUPABASE_SERVICE_ROLE_KEY`,
`BREVO_API_KEY`, `BREVO_FROM_EMAIL`, `BREVO_FROM_NAME`, `APP_URL`,
`PRICE_ID_STARTER`, `PRICE_ID_PRO`, `ADMIN_ALERT_EMAIL`.

## Conventions du code

- Tout en français : identifiants, commentaires, textes d'interface.
- CSS : variables dans `:root` en tête de fichier (`--brand`, `--ink`, `--g100`…),
  sections séparées par des bandeaux `/* ══ NOM ══ */`. Pas de framework CSS.
- JS : `function` classiques, pas de modules, pas de framework. ~460 déclarations de fonctions/lambdas,
  toutes dans le même scope global. Les handlers sont en `onclick="..."` dans le HTML.
- Messages de commit : `feat: …` / `fix: …`, en français, souvent versionnés
  (`feat: V25 - sitemap.xml + robots.txt pour SEO`).

## Points d'attention avant de reprendre

1. **`supabase/migrations/` est vide.** Le schéma des 10 tables n'existe nulle part
   dans le dépôt — il ne vit que dans le projet Supabase distant. À dumper en
   priorité (`supabase db pull`) sinon le schéma est irrécupérable en cas de pépin.
2. **Le nommage est incohérent** : dossier `immoai-pro`, produit `mon-crm-immo`,
   design system commenté « IMMOAI PRO v3 », clés localStorage `immoai_*`.
   Renommer est possible mais touche beaucoup de lignes — décision à prendre avant,
   pas pendant.
3. **`app/index.html` fait 674 Ko en un seul fichier.** Toute recherche se fait au
   `grep` sur ce fichier. Un découpage (JS/CSS extraits) serait le premier vrai
   chantier de refonte, mais casserait la simplicité du déploiement actuel.
4. **Deux bugs faciles à corriger** :
   - le bouton du plan-gate ouvre `immoai-landing.html#pricing`, un fichier qui
     n'existe plus — il devrait pointer vers `/tarifs` ;
   - le CSS déclare `--fd`/`--fb` en **Manrope**, mais le `<link>` Google Fonts ne
     charge que Inter et Plus Jakarta Sans. L'app tombe donc sur `system-ui`.
5. **Données en localStorage** : pas de sauvegarde, pas de multi-appareil, plafond
   à ~5 Mo. C'est la limite structurelle du produit aujourd'hui.
6. Le dépôt est propre au dernier commit (`7cba78e`, 4 mai 2026). Branche de
   sauvegarde disponible : `backup-avant-landing`.

## Compte de démonstration

`agent@immoai.pro` / `immoai2025`
