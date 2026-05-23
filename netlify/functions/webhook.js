// webhook.js — Stripe webhook handler
// Listens for checkout.session.completed and sends a professional invoice email
// via Resend to the customer + a copy to the owner.
//
// Required env vars (set in Netlify Dashboard → Environment variables):
//   STRIPE_SECRET_KEY       — sk_live_...
//   STRIPE_WEBHOOK_SECRET   — whsec_... (from Stripe Dashboard → Webhooks)
//   RESEND_API_KEY          — re_...    (from resend.com)

const stripe = require('stripe')(process.env.STRIPE_SECRET_KEY);
const { Resend } = require('resend');

const resend = new Resend(process.env.RESEND_API_KEY);

const OWNER_EMAIL = 'enrique.padron853@gmail.com';
const DOWNLOAD_URL = 'https://github.com/MystoganzTv/Foldiq/releases/download/1.0/Foldiq-1.0.dmg';

// ── Email template ────────────────────────────────────────────────────────────
function buildInvoiceHTML({ customerName, customerEmail, invoiceId, date, amount }) {
  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>Your Foldiq Receipt</title>
</head>
<body style="margin:0;padding:0;background:#F8FAFC;font-family:'Helvetica Neue',Helvetica,Arial,sans-serif;-webkit-font-smoothing:antialiased;">
  <table width="100%" cellpadding="0" cellspacing="0" style="background:#F8FAFC;padding:48px 0;">
    <tr><td align="center">
      <table width="560" cellpadding="0" cellspacing="0" style="max-width:560px;width:100%;">

        <!-- Logo -->
        <tr><td align="center" style="padding-bottom:32px;">
          <img src="https://foldiq.netlify.app/icon.png" width="56" height="56"
               style="border-radius:14px;display:block;margin:0 auto 12px;" alt="Foldiq" />
          <span style="font-size:22px;font-weight:800;color:#0F172A;letter-spacing:-.3px;">Foldiq</span>
        </td></tr>

        <!-- Card -->
        <tr><td style="background:#ffffff;border-radius:20px;padding:40px 48px;
                       box-shadow:0 4px 24px rgba(0,0,0,0.07);">

          <!-- Header -->
          <p style="margin:0 0 4px;font-size:13px;font-weight:600;letter-spacing:.08em;
                    text-transform:uppercase;color:#3B82F6;">Receipt</p>
          <h1 style="margin:0 0 8px;font-size:26px;font-weight:800;color:#0F172A;">
            Thanks for your purchase!
          </h1>
          <p style="margin:0 0 32px;font-size:15px;color:#475569;line-height:1.6;">
            Hi ${customerName || 'there'}, your payment was successful.
            Here's your receipt and download link.
          </p>

          <!-- Divider -->
          <hr style="border:none;border-top:1px solid #E2E8F0;margin:0 0 28px;" />

          <!-- Line item -->
          <table width="100%" cellpadding="0" cellspacing="0" style="margin-bottom:28px;">
            <tr>
              <td style="font-size:15px;font-weight:600;color:#0F172A;">Foldiq for Mac</td>
              <td align="right" style="font-size:15px;font-weight:700;color:#0F172A;">${amount}</td>
            </tr>
            <tr>
              <td style="font-size:13px;color:#64748B;padding-top:4px;">
                One-time purchase · Lifetime license · All future updates
              </td>
              <td></td>
            </tr>
          </table>

          <!-- Total -->
          <table width="100%" cellpadding="0" cellspacing="0"
                 style="background:#F1F5F9;border-radius:10px;padding:14px 16px;margin-bottom:32px;">
            <tr>
              <td style="font-size:14px;color:#64748B;">Total paid</td>
              <td align="right" style="font-size:16px;font-weight:800;color:#0F172A;">${amount}</td>
            </tr>
          </table>

          <!-- Download button -->
          <table width="100%" cellpadding="0" cellspacing="0" style="margin-bottom:32px;">
            <tr><td align="center">
              <a href="${DOWNLOAD_URL}"
                 style="display:inline-block;background:#3B82F6;color:#ffffff;
                        font-size:16px;font-weight:700;text-decoration:none;
                        padding:16px 36px;border-radius:12px;">
                ⬇ Download Foldiq 1.0
              </a>
            </td></tr>
          </table>

          <hr style="border:none;border-top:1px solid #E2E8F0;margin:0 0 24px;" />

          <!-- Meta -->
          <table width="100%" cellpadding="0" cellspacing="0">
            <tr>
              <td style="font-size:13px;color:#94A3B8;">Receipt #</td>
              <td align="right" style="font-size:13px;color:#64748B;font-family:monospace;">${invoiceId}</td>
            </tr>
            <tr>
              <td style="font-size:13px;color:#94A3B8;padding-top:6px;">Date</td>
              <td align="right" style="font-size:13px;color:#64748B;padding-top:6px;">${date}</td>
            </tr>
            <tr>
              <td style="font-size:13px;color:#94A3B8;padding-top:6px;">Email</td>
              <td align="right" style="font-size:13px;color:#64748B;padding-top:6px;">${customerEmail}</td>
            </tr>
          </table>

        </td></tr>

        <!-- Footer -->
        <tr><td align="center" style="padding-top:32px;">
          <p style="margin:0;font-size:13px;color:#94A3B8;line-height:1.7;">
            Questions? Reply to this email or visit
            <a href="https://foldiq.netlify.app/contact" style="color:#3B82F6;text-decoration:none;">foldiq.netlify.app/contact</a>
          </p>
          <p style="margin:8px 0 0;font-size:12px;color:#CBD5E1;">
            © 2026 Foldiq · Made for Mac
          </p>
        </td></tr>

      </table>
    </td></tr>
  </table>
</body>
</html>`;
}

// ── Handler ───────────────────────────────────────────────────────────────────
exports.handler = async (event) => {
  if (event.httpMethod !== 'POST') {
    return { statusCode: 405, body: 'Method not allowed' };
  }

  // Verify Stripe signature
  const sig = event.headers['stripe-signature'];
  let stripeEvent;

  try {
    stripeEvent = stripe.webhooks.constructEvent(
      event.body,
      sig,
      process.env.STRIPE_WEBHOOK_SECRET
    );
  } catch (err) {
    console.error('Webhook signature failed:', err.message);
    return { statusCode: 400, body: `Webhook Error: ${err.message}` };
  }

  // Only handle successful checkouts
  if (stripeEvent.type !== 'checkout.session.completed') {
    return { statusCode: 200, body: 'Ignored' };
  }

  const session = stripeEvent.data.object;
  const customerEmail = session.customer_details?.email || session.customer_email;
  const customerName  = session.customer_details?.name || '';
  const amountTotal   = session.amount_total || 499;
  const amount        = `$${(amountTotal / 100).toFixed(2)}`;
  const invoiceId     = session.id.replace('cs_live_', '').replace('cs_test_', '').slice(0, 16).toUpperCase();
  const date          = new Date().toLocaleDateString('en-US', { year: 'numeric', month: 'long', day: 'numeric' });

  if (!customerEmail) {
    console.error('No customer email found in session');
    return { statusCode: 200, body: 'No email' };
  }

  const html = buildInvoiceHTML({ customerName, customerEmail, invoiceId, date, amount });

  try {
    // Send to customer
    await resend.emails.send({
      from: 'Foldiq <receipts@foldiq.app>',
      to: customerEmail,
      subject: `Your Foldiq receipt — ${amount}`,
      html,
    });

    // Send copy to owner
    await resend.emails.send({
      from: 'Foldiq <receipts@foldiq.app>',
      to: OWNER_EMAIL,
      subject: `[New Sale] Foldiq ${amount} — ${customerEmail}`,
      html,
    });

    console.log(`Receipt sent to ${customerEmail} and ${OWNER_EMAIL}`);
    return { statusCode: 200, body: 'OK' };

  } catch (err) {
    console.error('Email send failed:', err.message);
    return { statusCode: 500, body: 'Email failed' };
  }
};
