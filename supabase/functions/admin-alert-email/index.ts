import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const BREVO_API_KEY = Deno.env.get("BREVO_API_KEY")!;
const BREVO_FROM_EMAIL = Deno.env.get("BREVO_FROM_EMAIL") || "contact@mon-crm-immo.fr";
const BREVO_FROM_NAME = Deno.env.get("BREVO_FROM_NAME") || "mon-crm-immo Sécurité";
const ALERT_TO_EMAIL = Deno.env.get("ADMIN_ALERT_EMAIL") || "alexis@pmcorp.fr";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Max-Age": "86400"
};

interface AlertPayload {
  type: "login_success" | "login_failed" | "rate_limit_hit" | "new_admin_added";
  email: string;
  ip?: string;
  user_agent?: string;
  failure_reason?: string;
  details?: Record<string, unknown>;
}

function buildEmailHtml(payload: AlertPayload): { subject: string; html: string } {
  const now = new Date().toLocaleString("fr-FR", {
    dateStyle: "full",
    timeStyle: "medium",
    timeZone: "Europe/Paris"
  });

  const ip = payload.ip || "inconnue";
  const ua = payload.user_agent || "inconnu";
  const browser = ua.match(/(Chrome|Safari|Firefox|Edge)\/[\d.]+/)?.[0] || "Inconnu";

  let subject = "";
  let icon = "";
  let titleText = "";
  let mainColor = "";

  switch (payload.type) {
    case "login_success":
      subject = `🔓 Connexion admin — ${payload.email}`;
      icon = "🔓";
      titleText = "Connexion admin réussie";
      mainColor = "#16A34A";
      break;
    case "login_failed":
      subject = `⚠️ Tentative admin échouée — ${payload.email}`;
      icon = "⚠️";
      titleText = "Tentative de connexion admin échouée";
      mainColor = "#DC2626";
      break;
    case "rate_limit_hit":
      subject = `🚨 BLOCAGE rate-limit — ${payload.email}`;
      icon = "🚨";
      titleText = "Email bloqué après 3 tentatives échouées";
      mainColor = "#DC2626";
      break;
    case "new_admin_added":
      subject = `➕ Nouvel admin ajouté — ${payload.email}`;
      icon = "➕";
      titleText = "Nouvel email ajouté à l'allowlist admin";
      mainColor = "#3B82F6";
      break;
  }

  const reasonRow = payload.failure_reason
    ? `<tr><td style="padding:8px 12px;border-bottom:1px solid #EAEAEA;color:#737373;font-size:13px;width:140px">Raison</td><td style="padding:8px 12px;border-bottom:1px solid #EAEAEA;color:#0F0F11;font-size:13px;font-weight:600">${payload.failure_reason}</td></tr>`
    : "";

  const html = `<!DOCTYPE html>
<html><head><meta charset="UTF-8"></head>
<body style="margin:0;padding:24px;background:#F5F5F5;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif">
  <div style="max-width:560px;margin:0 auto;background:#fff;border-radius:12px;overflow:hidden;border:1px solid #EAEAEA">
    <div style="background:${mainColor};color:#fff;padding:18px 22px">
      <div style="font-size:32px;line-height:1">${icon}</div>
      <div style="font-size:18px;font-weight:700;margin-top:6px">${titleText}</div>
    </div>
    <div style="padding:22px">
      <p style="margin:0 0 18px;color:#525252;font-size:14px;line-height:1.5">
        Une activité admin a été détectée sur <strong>mon-crm-immo</strong>.
        Si ce n'est pas vous, agissez immédiatement.
      </p>
      <table style="width:100%;border-collapse:collapse;border:1px solid #EAEAEA;border-radius:8px;overflow:hidden">
        <tr><td style="padding:8px 12px;border-bottom:1px solid #EAEAEA;color:#737373;font-size:13px;width:140px">Email</td><td style="padding:8px 12px;border-bottom:1px solid #EAEAEA;color:#0F0F11;font-size:13px;font-weight:600">${payload.email}</td></tr>
        <tr><td style="padding:8px 12px;border-bottom:1px solid #EAEAEA;color:#737373;font-size:13px">Date</td><td style="padding:8px 12px;border-bottom:1px solid #EAEAEA;color:#0F0F11;font-size:13px;font-weight:600">${now}</td></tr>
        <tr><td style="padding:8px 12px;border-bottom:1px solid #EAEAEA;color:#737373;font-size:13px">Adresse IP</td><td style="padding:8px 12px;border-bottom:1px solid #EAEAEA;color:#0F0F11;font-size:13px;font-weight:600;font-family:monospace">${ip}</td></tr>
        <tr><td style="padding:8px 12px;border-bottom:1px solid #EAEAEA;color:#737373;font-size:13px">Navigateur</td><td style="padding:8px 12px;border-bottom:1px solid #EAEAEA;color:#0F0F11;font-size:13px;font-weight:600">${browser}</td></tr>
        ${reasonRow}
      </table>
      <div style="margin-top:22px;padding:14px;background:#FEF3C7;border-left:3px solid #D97706;border-radius:4px">
        <p style="margin:0;color:#92400E;font-size:13px;line-height:1.5">
          ℹ️ Vous recevez cet email car votre adresse est configurée comme destinataire des alertes admin.
        </p>
      </div>
      <div style="margin-top:22px;text-align:center">
        <a href="https://mon-crm-immo.fr/#admin" style="display:inline-block;background:#0F0F11;color:#fff;text-decoration:none;padding:11px 22px;border-radius:8px;font-size:13px;font-weight:600">
          Ouvrir le backoffice
        </a>
      </div>
    </div>
    <div style="padding:14px 22px;background:#FAFAFA;border-top:1px solid #EAEAEA;color:#A3A3A3;font-size:11px;text-align:center">
      mon-crm-immo · Système d'alertes sécurité
    </div>
  </div>
</body></html>`;

  return { subject, html };
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: CORS_HEADERS });
  }

  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405, headers: CORS_HEADERS });
  }

  try {
    const payload = await req.json() as AlertPayload;

    if (!payload.type || !payload.email) {
      return new Response(JSON.stringify({ error: "missing_fields" }), {
        status: 400,
        headers: { ...CORS_HEADERS, "Content-Type": "application/json" }
      });
    }

    const { subject, html } = buildEmailHtml(payload);

    const brevoRes = await fetch("https://api.brevo.com/v3/smtp/email", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "api-key": BREVO_API_KEY,
        "accept": "application/json"
      },
      body: JSON.stringify({
        sender: { email: BREVO_FROM_EMAIL, name: BREVO_FROM_NAME },
        to: [{ email: ALERT_TO_EMAIL }],
        subject,
        htmlContent: html
      })
    });

    if (!brevoRes.ok) {
      const errText = await brevoRes.text();
      console.error("Brevo error:", brevoRes.status, errText);
      return new Response(JSON.stringify({ error: "brevo_failed", detail: errText }), {
        status: 502,
        headers: { ...CORS_HEADERS, "Content-Type": "application/json" }
      });
    }

    return new Response(JSON.stringify({ ok: true }), {
      status: 200,
      headers: { ...CORS_HEADERS, "Content-Type": "application/json" }
    });
  } catch (e) {
    console.error("Error:", e);
    return new Response(JSON.stringify({ error: "internal", detail: String(e) }), {
      status: 500,
      headers: { ...CORS_HEADERS, "Content-Type": "application/json" }
    });
  }
});
