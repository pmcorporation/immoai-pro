# mon-crm-immo

CRM immobilier avec assistants IA pour agents et mandataires indépendants.
Produit en ligne : **https://mon-crm-immo.fr**

> Le dossier et le dépôt s'appellent encore `immoai-pro` (ancien nom du produit).

## Structure

- **`app/index.html`** — l'application CRM, en un seul fichier (HTML + CSS + JS)
- `index.html` — le site vitrine
- `tarifs/`, `merci/`, `legal/`, `blog/` — pages marketing, légales et 20 articles SEO
- `supabase/functions/` — edge functions (webhook Stripe, alertes admin)
- `vercel.json` — rewrites pour servir `/app/*`

## Stack

HTML/CSS/JS statiques, sans build ni bundler. Supabase pour l'auth et la facturation,
localStorage pour les données métier, Stripe pour les abonnements, API Anthropic
appelée directement depuis le navigateur pour les assistants IA.

## Lancer en local

```bash
python3 -m http.server 8000
# → http://localhost:8000/app/index.html
```

## Déployer

Push sur `main` : Vercel déploie automatiquement.

```bash
supabase functions deploy stripe-webhook
supabase functions deploy admin-alert-email
```

## Compte de démonstration

`agent@immoai.pro` / `immoai2025`

## Reprendre le projet

Voir **`CLAUDE.md`** : architecture détaillée, conventions, et les points à traiter
en priorité (schéma Supabase non versionné, nommage, taille du monofichier).
