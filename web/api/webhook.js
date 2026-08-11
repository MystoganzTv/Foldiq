// Vercel Serverless Function — Stripe webhook handler.
// Listens for checkout.session.completed and emails an order confirmation with
// the download link via Resend, plus a sale notification to the owner. Stripe's
// own "Successful payments" email is the authoritative payment receipt.
//
// IMPORTANT: bodyParser is disabled so Stripe can verify the raw request body.
//
// Required env vars (Vercel → Project → Settings → Environment Variables):
//   STRIPE_SECRET_KEY       — sk_live_...
//   STRIPE_WEBHOOK_SECRET   — whsec_... (from Stripe Dashboard → Webhooks)
//   RESEND_API_KEY          — re_...    (from resend.com)
//   GITHUB_RELEASE_TOKEN    — fine-grained token, Contents: read for Foldiq

import Stripe from 'stripe';
import { Resend } from 'resend';

// Disable Vercel's automatic body parsing — Stripe needs the raw bytes.
export const config = {
  api: {
    bodyParser: false,
  },
};

const stripe = new Stripe(process.env.STRIPE_SECRET_KEY);
const resend = new Resend(process.env.RESEND_API_KEY);

const SITE = 'https://foldiq.app';
const OWNER_EMAIL = 'enrique.padron853@gmail.com';

// Windows is served by a payment-verified endpoint backed by a private GitHub
// release. Mac ships from the App Store and is not sold here.
const MAC_APP_STORE_URL = 'https://apps.apple.com/us/app/foldiq/id6772513569';

// Vercel may expose the body directly or leave it on the request stream,
// depending on the function runtime. Stripe must receive the exact bytes when
// possible; the parsed-object fallback covers Vercel runtimes that consume the
// stream before invoking the function.
export async function readRawBody(req) {
  if (Buffer.isBuffer(req.body)) {
    return req.body;
  }

  if (req.body instanceof Uint8Array) {
    return Buffer.from(req.body);
  }

  if (typeof req.body === 'string') {
    return Buffer.from(req.body);
  }

  if (req.body && typeof req.body === 'object') {
    return Buffer.from(JSON.stringify(req.body));
  }

  const chunks = [];
  for await (const chunk of req) {
    chunks.push(typeof chunk === 'string' ? Buffer.from(chunk) : chunk);
  }
  return Buffer.concat(chunks);
}

export function escapeHTML(value) {
  return String(value ?? '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');
}

function assertEmailSent(result, label) {
  if (result?.error) {
    throw new Error(`${label}: ${result.error.message || 'unknown Resend error'}`);
  }
}

// ── Email template ────────────────────────────────────────────────────────────
export function buildInvoiceHTML({ customerName, customerEmail, invoiceId, date, amount, platform, checkoutSessionId }) {
  const isMac = platform === 'mac';
  const productLabel = isMac ? 'Foldiq for Mac' : 'Foldiq for Windows';
  const platformNote = isMac
    ? 'One-time purchase · Lifetime license · Delivered via the Mac App Store'
    : 'One-time purchase · Lifetime license · All future updates';
  const downloadUrl = isMac
    ? MAC_APP_STORE_URL
    : `${SITE}/api/download?session_id=${encodeURIComponent(checkoutSessionId)}`;
  const downloadLabel = isMac ? ' Open on the Mac App Store' : '⬇ Download Foldiq for Windows';
  const safeCustomerName = escapeHTML(customerName || 'there');
  const safeCustomerEmail = escapeHTML(customerEmail);
  const safeInvoiceId = escapeHTML(invoiceId);
  const safeDate = escapeHTML(date);
  const safeAmount = escapeHTML(amount);

  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>Your Foldiq Order</title>
</head>
<body style="margin:0;padding:0;background:#F8FAFC;font-family:'Helvetica Neue',Helvetica,Arial,sans-serif;-webkit-font-smoothing:antialiased;">
  <table width="100%" cellpadding="0" cellspacing="0" style="background:#F8FAFC;padding:48px 0;">
    <tr><td align="center">
      <table width="560" cellpadding="0" cellspacing="0" style="max-width:560px;width:100%;">

        <!-- Logo -->
        <tr><td align="center" style="padding-bottom:32px;">
          <img src="${SITE}/icon.png" width="56" height="56"
               style="border-radius:14px;display:block;margin:0 auto 12px;" alt="Foldiq" />
          <span style="font-size:22px;font-weight:800;color:#0F172A;letter-spacing:-.3px;">Foldiq</span>
        </td></tr>

        <!-- Card -->
        <tr><td style="background:#ffffff;border-radius:20px;padding:40px 48px;
                       box-shadow:0 4px 24px rgba(0,0,0,0.07);">

          <!-- Header -->
          <p style="margin:0 0 4px;font-size:13px;font-weight:600;letter-spacing:.08em;
                    text-transform:uppercase;color:#3B82F6;">Order confirmation</p>
          <h1 style="margin:0 0 8px;font-size:26px;font-weight:800;color:#0F172A;">
            Thanks for your purchase!
          </h1>
          <p style="margin:0 0 32px;font-size:15px;color:#475569;line-height:1.6;">
            Hi ${safeCustomerName}, your payment was successful.
            Here's your order confirmation and download link.
          </p>

          <!-- Divider -->
          <hr style="border:none;border-top:1px solid #E2E8F0;margin:0 0 28px;" />

          <!-- Line item -->
          <table width="100%" cellpadding="0" cellspacing="0" style="margin-bottom:28px;">
            <tr>
              <td style="font-size:15px;font-weight:600;color:#0F172A;">${productLabel}</td>
              <td align="right" style="font-size:15px;font-weight:700;color:#0F172A;">${safeAmount}</td>
            </tr>
            <tr>
              <td style="font-size:13px;color:#64748B;padding-top:4px;">
                ${platformNote}
              </td>
              <td></td>
            </tr>
          </table>

          <!-- Total -->
          <table width="100%" cellpadding="0" cellspacing="0"
                 style="background:#F1F5F9;border-radius:10px;padding:14px 16px;margin-bottom:32px;">
            <tr>
              <td style="font-size:14px;color:#64748B;">Total paid</td>
              <td align="right" style="font-size:16px;font-weight:800;color:#0F172A;">${safeAmount}</td>
            </tr>
          </table>

          <!-- Download button -->
          <table width="100%" cellpadding="0" cellspacing="0" style="margin-bottom:32px;">
            <tr><td align="center">
              <a href="${downloadUrl}"
                 style="display:inline-block;background:#3B82F6;color:#ffffff;
                        font-size:16px;font-weight:700;text-decoration:none;
                        padding:16px 36px;border-radius:12px;">
                ${downloadLabel}
              </a>
            </td></tr>
          </table>

          <hr style="border:none;border-top:1px solid #E2E8F0;margin:0 0 24px;" />

          <!-- Meta -->
          <table width="100%" cellpadding="0" cellspacing="0">
            <tr>
              <td style="font-size:13px;color:#94A3B8;">Order #</td>
              <td align="right" style="font-size:13px;color:#64748B;font-family:monospace;">${safeInvoiceId}</td>
            </tr>
            <tr>
              <td style="font-size:13px;color:#94A3B8;padding-top:6px;">Date</td>
              <td align="right" style="font-size:13px;color:#64748B;padding-top:6px;">${safeDate}</td>
            </tr>
            <tr>
              <td style="font-size:13px;color:#94A3B8;padding-top:6px;">Email</td>
              <td align="right" style="font-size:13px;color:#64748B;padding-top:6px;">${safeCustomerEmail}</td>
            </tr>
          </table>

        </td></tr>

        <!-- Footer -->
        <tr><td align="center" style="padding-top:32px;">
          <p style="margin:0;font-size:13px;color:#94A3B8;line-height:1.7;">
            Questions? Reply to this email or visit
            <a href="${SITE}/contact" style="color:#3B82F6;text-decoration:none;">foldiq.app/contact</a>
          </p>
          <p style="margin:8px 0 0;font-size:12px;color:#CBD5E1;">
            © 2026 Foldiq · Made for Mac &amp; Windows
          </p>
        </td></tr>

      </table>
    </td></tr>
  </table>
</body>
</html>`;
}

// ── Handler ───────────────────────────────────────────────────────────────────
export default async function handler(req, res) {
  if (req.method !== 'POST') {
    res.status(405).send('Method not allowed');
    return;
  }

  const rawBody = await readRawBody(req);
  const sig = req.headers['stripe-signature'];
  let stripeEvent;

  try {
    stripeEvent = stripe.webhooks.constructEvent(
      rawBody,
      sig,
      process.env.STRIPE_WEBHOOK_SECRET
    );
  } catch (err) {
    console.error('Webhook signature failed:', err.message);
    res.status(400).send(`Webhook Error: ${err.message}`);
    return;
  }

  if (stripeEvent.type !== 'checkout.session.completed') {
    res.status(200).send('Ignored');
    return;
  }

  const session = stripeEvent.data.object;
  const customerEmail = session.customer_details?.email || session.customer_email;
  const customerName  = session.customer_details?.name || '';
  const platform      = session.metadata?.platform === 'mac' ? 'mac' : 'windows';
  const amountTotal   = session.amount_total ?? 499;
  const currency      = (session.currency || 'usd').toUpperCase();
  const amount        = new Intl.NumberFormat('en-US', {
    style: 'currency',
    currency,
  }).format(amountTotal / 100);
  const invoiceId     = session.id.replace('cs_live_', '').replace('cs_test_', '').slice(0, 16).toUpperCase();
  const eventDate     = stripeEvent.created ? new Date(stripeEvent.created * 1000) : new Date();
  const date          = eventDate.toLocaleDateString('en-US', { year: 'numeric', month: 'long', day: 'numeric' });

  if (!customerEmail) {
    console.error('No customer email found in session');
    res.status(200).send('No email');
    return;
  }

  const html = buildInvoiceHTML({
    customerName,
    customerEmail,
    invoiceId,
    date,
    amount,
    platform,
    checkoutSessionId: session.id,
  });

  try {
    const customerResult = await resend.emails.send({
      from: 'Foldiq <receipts@foldiq.app>',
      to: customerEmail,
      subject: 'Your Foldiq order — download inside',
      html,
    });
    assertEmailSent(customerResult, 'Customer order email failed');

    // Do not make Stripe retry (and duplicate the customer's email) if only the
    // internal owner notification fails.
    try {
      const ownerResult = await resend.emails.send({
        from: 'Foldiq <receipts@foldiq.app>',
        to: OWNER_EMAIL,
        subject: `[New Sale] Foldiq ${platform} ${amount} — ${customerEmail.replace(/[\r\n]/g, ' ')}`,
        html: `<p style="font-family:monospace;font-size:13px;color:#475569;">
                 platform: ${escapeHTML(platform)}<br/>
                 payment_intent: ${escapeHTML(session.payment_intent || '—')}<br/>
                 checkout_session: ${escapeHTML(session.id)}<br/>
                 country: ${escapeHTML(session.customer_details?.address?.country || '—')}
               </p>${html}`,
      });
      assertEmailSent(ownerResult, 'Owner sale notification failed');
    } catch (ownerError) {
      console.error(ownerError.message);
    }

    console.log(`Order email sent for checkout session ${session.id}`);
    res.status(200).send('OK');
  } catch (err) {
    console.error('Email send failed:', err.message);
    res.status(500).send('Email failed');
  }
}
