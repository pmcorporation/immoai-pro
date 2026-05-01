// ═══════════════════════════════════════════════════════════════
// Edge Function : stripe-webhook
// Reçoit les events Stripe, génère un code d'activation et envoie
// l'email de bienvenue via Brevo.
// ═══════════════════════════════════════════════════════════════
//
// Endpoint Stripe à configurer :
//   https://wwqccgacezbzkbaptyup.supabase.co/functions/v1/stripe-webhook
//
// Events à écouter :
//   - checkout.session.completed       (paiement initial réussi)
//   - customer.subscription.updated    (changement de plan / renouvellement)
//   - customer.subscription.deleted    (résiliation)
//   - invoice.payment_failed           (paiement échoué)
//
// Variables d'environnement Supabase (Settings → Edge Functions → Secrets) :
//   STRIPE_SECRET_KEY        sk_live_xxx ou sk_test_xxx
//   STRIPE_WEBHOOK_SECRET    whsec_xxx (depuis Stripe Dashboard → Webhooks)
//   BREVO_API_KEY            xkeysib-xxx
//   BREVO_FROM_EMAIL         contact@mon-crm-immo.fr
//   BREVO_FROM_NAME          mon-crm-immo
//   APP_URL                  https://mon-crm-immo.fr
//   PRICE_ID_STARTER         price_xxx (Stripe Price ID du plan Starter 35€)
//   PRICE_ID_PRO             price_xxx (Stripe Price ID du plan Pro 75€)
// ═══════════════════════════════════════════════════════════════

import Stripe from 'https://esm.sh/stripe@14.21.0?target=deno';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const stripe = new Stripe(Deno.env.get('STRIPE_SECRET_KEY')!, {
  apiVersion: '2024-06-20',
  httpClient: Stripe.createFetchHttpClient(),
});

const cryptoProvider = Stripe.createSubtleCryptoProvider();

const supabase = createClient(
  Deno.env.get('SUPABASE_URL')!,
  Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  { auth: { persistSession: false } },
);

const WEBHOOK_SECRET   = Deno.env.get('STRIPE_WEBHOOK_SECRET')!;
const BREVO_API_KEY    = Deno.env.get('BREVO_API_KEY')!;
const BREVO_FROM_EMAIL = Deno.env.get('BREVO_FROM_EMAIL') ?? 'contact@mon-crm-immo.fr';
const BREVO_FROM_NAME  = Deno.env.get('BREVO_FROM_NAME')  ?? 'mon-crm-immo';
const APP_URL          = Deno.env.get('APP_URL')          ?? 'https://mon-crm-immo.fr';
const PRICE_STARTER    = Deno.env.get('PRICE_ID_STARTER') ?? '';
const PRICE_PRO        = Deno.env.get('PRICE_ID_PRO')     ?? '';

// ── Génération de codes d'activation lisibles ──
// Format : MCI-XXXX-XXXX (12 chars dont 2 tirets)
function generateActivationCode(): string {
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; // pas de 0/O/1/I
  const block = (n: number) => Array.from(
    { length: n },
    () => alphabet[Math.floor(Math.random() * alphabet.length)],
  ).join('');
  return `MCI-${block(4)}-${block(4)}`;
}

// ── Mappe un Stripe Price ID vers un plan interne ──
function planFromPriceId(priceId: string): 'starter' | 'pro' | null {
  if (priceId === PRICE_STARTER) return 'starter';
  if (priceId === PRICE_PRO)     return 'pro';
  // Fallback : si pas configuré, essayer de deviner par metadata
  return null;
}

// ── Email Brevo : Bienvenue + code d'activation ──
async function sendWelcomeEmail(
  to: string,
  prenom: string,
  plan: 'starter' | 'pro',
  code: string,
) {
  const planLabel = plan === 'pro' ? 'Pro — 75€/mois' : 'Starter — 35€/mois';
  const planColor = plan === 'pro' ? '#F08A6E' : '#1D6FE8';
  const activationUrl = `${APP_URL}/activate?code=${encodeURIComponent(code)}`;

  const html = `<!DOCTYPE html>
<html lang="fr"><head><meta charset="UTF-8"></head>
<body style="margin:0;padding:0;background:#F8F9FC;font-family:'Helvetica Neue',Arial,sans-serif">
<div style="max-width:580px;margin:40px auto;background:#fff;border-radius:16px;overflow:hidden;box-shadow:0 4px 24px rgba(0,0,0,.08)">
  <div style="background:#2A211B;padding:32px 40px;text-align:center">
    <div style="display:inline-flex;align-items:center;gap:10px">
      <div style="width:36px;height:36px;background:#F08A6E;border-radius:9px;display:inline-flex;align-items:center;justify-content:center;font-weight:800;font-size:11px;color:#fff;letter-spacing:.04em">MCI</div>
      <span style="font-weight:700;font-size:16px;color:#fff;letter-spacing:-.01em">mon-<span style="color:#F08A6E">crm</span>-immo</span>
    </div>
  </div>
  <div style="padding:40px">
    <h1 style="font-size:24px;font-weight:800;color:#2A211B;margin:0 0 8px;letter-spacing:-.03em">Merci pour votre paiement ${prenom} ! 🎉</h1>
    <p style="font-size:15px;color:#6B7280;margin:0 0 24px;line-height:1.6">Votre abonnement <strong>${planLabel}</strong> est confirmé. Voici votre code d'activation pour créer votre compte :</p>

    <div style="background:#FFF7ED;border:2px dashed ${planColor};border-radius:12px;padding:24px;text-align:center;margin-bottom:24px">
      <div style="font-size:11px;font-weight:700;color:#9CA3AF;text-transform:uppercase;letter-spacing:.08em;margin-bottom:8px">Votre code d'activation</div>
      <div style="font-family:'Courier New',monospace;font-size:24px;font-weight:800;color:#2A211B;letter-spacing:.05em">${code}</div>
    </div>

    <a href="${activationUrl}" style="display:block;text-align:center;background:#F08A6E;color:#fff;text-decoration:none;padding:14px 28px;border-radius:11px;font-weight:700;font-size:15px;margin-bottom:24px">
      Activer mon compte →
    </a>

    <div style="background:#F8F9FC;border-radius:10px;padding:16px;margin-bottom:24px;font-size:13px;color:#6B7280;line-height:1.6">
      <strong style="color:#2A211B">Comment ça marche :</strong><br>
      1. Cliquez sur le bouton ci-dessus (ou copiez le code)<br>
      2. Créez votre compte avec votre email et un mot de passe<br>
      3. Profitez immédiatement de toutes les fonctionnalités
    </div>

    <p style="font-size:13px;color:#9CA3AF;text-align:center;margin:0">
      Une question ? <a href="mailto:contact@mon-crm-immo.fr" style="color:#F08A6E">contact@mon-crm-immo.fr</a>
    </p>
  </div>
  <div style="background:#F8F9FC;padding:20px 40px;text-align:center;border-top:1px solid #E5E7EB">
    <p style="font-size:12px;color:#9CA3AF;margin:0">© 2026 mon-crm-immo · <a href="${APP_URL}" style="color:#9CA3AF">mon-crm-immo.fr</a></p>
  </div>
</div></body></html>`;

  const resp = await fetch('https://api.brevo.com/v3/smtp/email', {
    method:  'POST',
    headers: {
      'Content-Type': 'application/json',
      'api-key':      BREVO_API_KEY,
      'accept':       'application/json',
    },
    body: JSON.stringify({
      sender: { email: BREVO_FROM_EMAIL, name: BREVO_FROM_NAME },
      to:     [{ email: to, name: prenom }],
      subject: `🎉 Votre code d'activation mon-crm-immo (${planLabel})`,
      htmlContent: html,
    }),
  });

  if (!resp.ok) {
    const errText = await resp.text();
    console.error('Brevo error:', resp.status, errText);
    throw new Error(`Brevo send failed: ${resp.status}`);
  }
  return await resp.json();
}

// ── Handler principal ──
Deno.serve(async (req) => {
  if (req.method !== 'POST') {
    return new Response('Method Not Allowed', { status: 405 });
  }

  const sig = req.headers.get('stripe-signature');
  if (!sig) return new Response('Missing signature', { status: 400 });

  const body = await req.text();

  // Vérification de signature (asynchrone car Deno)
  let event: Stripe.Event;
  try {
    event = await stripe.webhooks.constructEventAsync(
      body, sig, WEBHOOK_SECRET, undefined, cryptoProvider,
    );
  } catch (err) {
    console.error('Signature verification failed:', err.message);
    return new Response(`Webhook signature error: ${err.message}`, { status: 400 });
  }

  // Idempotence : on a déjà traité cet event ?
  const { data: existing } = await supabase
    .from('stripe_events')
    .select('id, processed')
    .eq('id', event.id)
    .maybeSingle();

  if (existing?.processed) {
    return new Response(JSON.stringify({ received: true, duplicate: true }), {
      status: 200, headers: { 'Content-Type': 'application/json' },
    });
  }

  // Insertion (ou maj) de l'event
  await supabase.from('stripe_events').upsert({
    id:        event.id,
    type:      event.type,
    payload:   event as unknown as Record<string, unknown>,
    processed: false,
  }, { onConflict: 'id' });

  try {
    switch (event.type) {

      // ── 1. Paiement initial réussi ──────────────────────────
      case 'checkout.session.completed': {
        const session = event.data.object as Stripe.Checkout.Session;

        // Récupérer la subscription pour avoir le price_id
        let priceId = '';
        let subscriptionId = '';
        if (session.subscription && typeof session.subscription === 'string') {
          subscriptionId = session.subscription;
          const sub = await stripe.subscriptions.retrieve(subscriptionId);
          priceId = sub.items.data[0]?.price.id ?? '';
        }

        const plan = planFromPriceId(priceId);
        if (!plan) {
          console.error('Unknown price_id:', priceId);
          throw new Error(`Unknown price_id: ${priceId}`);
        }

        const email      = session.customer_details?.email ?? session.customer_email ?? '';
        const prenom     = session.customer_details?.name?.split(' ')[0] ?? 'cher client';
        const customerId = typeof session.customer === 'string' ? session.customer : '';

        if (!email) throw new Error('No email on checkout session');

        // Générer un code unique (retry max 5 si collision)
        let code = '';
        for (let i = 0; i < 5; i++) {
          const candidate = generateActivationCode();
          const { data: dup } = await supabase
            .from('activation_codes')
            .select('id').eq('code', candidate).maybeSingle();
          if (!dup) { code = candidate; break; }
        }
        if (!code) throw new Error('Could not generate unique code');

        // Sauvegarder en DB
        const { error: insertErr } = await supabase
          .from('activation_codes')
          .insert({
            code,
            plan,
            email,
            stripe_session_id:      session.id,
            stripe_customer_id:     customerId,
            stripe_subscription_id: subscriptionId,
            status: 'pending',
            metadata: { prenom, amount_total: session.amount_total },
          });
        if (insertErr) throw insertErr;

        // Envoyer l'email
        await sendWelcomeEmail(email, prenom, plan, code);

        console.log(`✅ Code ${code} créé pour ${email} (${plan})`);
        break;
      }

      // ── 2. Subscription mise à jour (changement de plan) ────
      case 'customer.subscription.updated': {
        const sub = event.data.object as Stripe.Subscription;
        const priceId = sub.items.data[0]?.price.id ?? '';
        const plan    = planFromPriceId(priceId);
        const renewsAt = sub.current_period_end
          ? new Date(sub.current_period_end * 1000).toISOString()
          : null;

        await supabase
          .from('profiles')
          .update({
            plan: plan ?? undefined,
            subscription_status:   sub.status,
            subscription_renews_at: renewsAt,
            updated_at: new Date().toISOString(),
          })
          .eq('stripe_subscription_id', sub.id);

        console.log(`🔄 Subscription ${sub.id} → ${sub.status} (${plan})`);
        break;
      }

      // ── 3. Subscription annulée ─────────────────────────────
      case 'customer.subscription.deleted': {
        const sub = event.data.object as Stripe.Subscription;
        await supabase
          .from('profiles')
          .update({
            subscription_status:   'canceled',
            subscription_canceled_at: new Date().toISOString(),
            updated_at: new Date().toISOString(),
          })
          .eq('stripe_subscription_id', sub.id);
        console.log(`❌ Subscription ${sub.id} annulée`);
        break;
      }

      // ── 4. Paiement échoué ──────────────────────────────────
      case 'invoice.payment_failed': {
        const inv = event.data.object as Stripe.Invoice;
        const subId = typeof inv.subscription === 'string' ? inv.subscription : '';
        if (subId) {
          await supabase
            .from('profiles')
            .update({
              subscription_status: 'past_due',
              updated_at: new Date().toISOString(),
            })
            .eq('stripe_subscription_id', subId);
        }
        console.log(`⚠️  Paiement échoué : ${inv.id}`);
        break;
      }

      default:
        console.log(`ℹ️  Event ignoré : ${event.type}`);
    }

    // Marquer l'event comme traité
    await supabase
      .from('stripe_events')
      .update({ processed: true, processed_at: new Date().toISOString() })
      .eq('id', event.id);

    return new Response(JSON.stringify({ received: true }), {
      status: 200, headers: { 'Content-Type': 'application/json' },
    });

  } catch (err) {
    console.error('Webhook handler error:', err);
    await supabase
      .from('stripe_events')
      .update({ error: String(err?.message ?? err) })
      .eq('id', event.id);

    return new Response(`Handler error: ${err.message}`, { status: 500 });
  }
});
