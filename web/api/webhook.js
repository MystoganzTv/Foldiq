// Vercel Serverless Function — Stripe webhook handler.
// Listens for checkout.session.completed and emails an order confirmation with
// the download link via Resend, plus a sale notification to the owner. Stripe's
// own "Successful payments" email is the authoritative payment receipt.
//
// IMPORTANT: Stripe signs the exact bytes it sends (pretty-printed JSON). This
// function is a Web handler (export POST) so it reads those bytes with
// request.arrayBuffer(). The old Node handler read req.body, which Vercel has
// already parsed into an object; re-serialising it with JSON.stringify changes
// the whitespace, so every real Stripe event failed signature verification.
//
// Required env vars (Vercel → Project → Settings → Environment Variables):
//   STRIPE_SECRET_KEY       — sk_live_...
//   STRIPE_WEBHOOK_SECRET   — whsec_... (from Stripe Dashboard → Webhooks)
//   RESEND_API_KEY          — re_...    (from resend.com)
//   GITHUB_RELEASE_TOKEN    — fine-grained token, Contents: read for Foldiq

import Stripe from 'stripe';
import { Resend } from 'resend';
import { channelFromMetadata } from '../lib/attribution.js';

const stripe = new Stripe(process.env.STRIPE_SECRET_KEY);
const resend = new Resend(process.env.RESEND_API_KEY);

const SITE = 'https://foldiq.app';
const OWNER_EMAIL = 'enrique.padron853@gmail.com';
const RECEIPTS_FROM_EMAIL = process.env.RECEIPTS_FROM_EMAIL || 'Foldiq <receipts@foldiq.app>';

// Both installers are served by a payment-verified endpoint backed by a
// private GitHub release (Foldiq-Setup.exe and the notarized Foldiq.dmg).

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
    ? 'One-time purchase · macOS 14 or later · No subscription'
    : 'One-time purchase · No subscription';
  // The same link always serves the newest version, so it also works for updates.
  const downloadUrl = `${SITE}/api/download?session_id=${encodeURIComponent(checkoutSessionId)}`;
  const downloadLabel = isMac ? '⬇ Download Foldiq for Mac' : '⬇ Download Foldiq for Windows';
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

// Internal sale notification for the owner. Deliberately separate from the
// customer's receipt: a short summary plus the IDs needed to find the payment.
export function buildOwnerSaleHTML({
  amount, platform, channel, campaign, referrer, country,
  customerEmail, customerName, date, paymentIntent, checkoutSessionId, livemode = true,
}) {
  const platformLabel = platform === 'mac' ? 'Mac' : 'Windows';
  const stripeBase = livemode === false
    ? 'https://dashboard.stripe.com/test/payments/'
    : 'https://dashboard.stripe.com/payments/';
  const stripeLink = paymentIntent ? `${stripeBase}${encodeURIComponent(paymentIntent)}` : '';
  const row = (label, value) => `
          <tr>
            <td style="padding:8px 0;font-size:13px;color:#64748B;width:110px;vertical-align:top;">${label}</td>
            <td style="padding:8px 0;font-size:14px;color:#0F172A;">${escapeHTML(value || '—')}</td>
          </tr>`;

  return `<!DOCTYPE html>
<html lang="en">
<head><meta charset="UTF-8" /><meta name="viewport" content="width=device-width, initial-scale=1.0" /></head>
<body style="margin:0;padding:0;background:#F1F5F9;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;">
  <table width="100%" cellpadding="0" cellspacing="0" style="background:#F1F5F9;padding:32px 16px;">
    <tr><td align="center">
      <table width="100%" cellpadding="0" cellspacing="0" style="max-width:480px;background:#FFFFFF;border-radius:12px;padding:28px;">
        <tr><td>
          <p style="margin:0;font-size:12px;letter-spacing:0.08em;text-transform:uppercase;color:#10B981;font-weight:600;">New sale · Foldiq for ${platformLabel}</p>
          <p style="margin:6px 0 20px;font-size:30px;font-weight:700;color:#0F172A;">${escapeHTML(amount)}</p>
          <table width="100%" cellpadding="0" cellspacing="0" style="border-top:1px solid #E2E8F0;">
            ${row('Customer', customerName ? `${customerName} · ${customerEmail}` : customerEmail)}
            ${row('Channel', channel)}
            ${row('Campaign', campaign)}
            ${row('Referrer', referrer)}
            ${row('Country', country)}
            ${row('Date', date)}
          </table>
          ${stripeLink ? `<p style="margin:20px 0 0;"><a href="${stripeLink}" style="display:inline-block;background:#0F172A;color:#FFFFFF;text-decoration:none;font-size:14px;font-weight:600;padding:10px 18px;border-radius:8px;">Open payment in Stripe</a></p>` : ''}
          <p style="margin:20px 0 0;font-size:11px;color:#94A3B8;line-height:1.6;font-family:Menlo,Consolas,monospace;word-break:break-all;">
            ${escapeHTML(paymentIntent || '—')}<br/>${escapeHTML(checkoutSessionId)}
          </p>
          <p style="margin:16px 0 0;font-size:12px;color:#94A3B8;">The customer was sent their receipt and download link separately.</p>
        </td></tr>
      </table>
    </td></tr>
  </table>
</body>
</html>`;
}

// ── Handler ───────────────────────────────────────────────────────────────────
// Verifies and handles one Stripe event. Returns { status, body } so the
// logic can be tested without a running server.
export async function processStripeWebhook(rawBody, sig) {
  let stripeEvent;

  try {
    stripeEvent = stripe.webhooks.constructEvent(
      rawBody,
      sig,
      process.env.STRIPE_WEBHOOK_SECRET
    );
  } catch (err) {
    console.error('Webhook signature failed:', err.message);
    return { status: 400, body: `Webhook Error: ${err.message}` };
  }

  if (stripeEvent.type !== 'checkout.session.completed') {
    return { status: 200, body: 'Ignored' };
  }

  const session = stripeEvent.data.object;
  const customerEmail = session.customer_details?.email || session.customer_email;
  const customerName  = session.customer_details?.name || '';
  const platform      = session.metadata?.platform === 'mac' ? 'mac' : 'windows';
  const channel       = channelFromMetadata(session.metadata);
  const amountTotal   = session.amount_total;
  const currency      = (session.currency || 'usd').toUpperCase();
  const amount        = amountTotal == null
    ? 'See Stripe receipt'
    : new Intl.NumberFormat('en-US', { style: 'currency', currency }).format(amountTotal / 100);
  const invoiceId     = session.id.replace('cs_live_', '').replace('cs_test_', '').slice(0, 16).toUpperCase();
  const eventDate     = stripeEvent.created ? new Date(stripeEvent.created * 1000) : new Date();
  const date          = eventDate.toLocaleDateString('en-US', { year: 'numeric', month: 'long', day: 'numeric' });

  if (!customerEmail) {
    console.error('No customer email found in session');
    return { status: 200, body: 'No email' };
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
      from: RECEIPTS_FROM_EMAIL,
      to: customerEmail,
      replyTo: process.env.SUPPORT_REPLY_TO || OWNER_EMAIL,
      subject: 'Your Foldiq order — download inside',
      html,
    }, {
      idempotencyKey: `foldiq-order-${session.id}`,
    });
    assertEmailSent(customerResult, 'Customer order email failed');

    // Do not make Stripe retry (and duplicate the customer's email) if only the
    // internal owner notification fails.
    try {
      const ownerResult = await resend.emails.send({
        from: RECEIPTS_FROM_EMAIL,
        to: OWNER_EMAIL,
        subject: `[New Sale] Foldiq ${platform} ${amount} · ${channel} — ${customerEmail.replace(/[\r\n]/g, ' ')}`,
        html: buildOwnerSaleHTML({
          amount,
          platform,
          channel,
          campaign: session.metadata?.attribution_campaign,
          referrer: session.metadata?.attribution_referrer,
          country: session.customer_details?.address?.country,
          customerEmail,
          customerName,
          date,
          paymentIntent: session.payment_intent,
          checkoutSessionId: session.id,
          livemode: session.livemode,
        }),
      }, {
        idempotencyKey: `foldiq-owner-sale-${session.id}`,
      });
      assertEmailSent(ownerResult, 'Owner sale notification failed');
    } catch (ownerError) {
      console.error(ownerError.message);
    }

    console.log(`Order email sent for checkout session ${session.id}`);
    return { status: 200, body: 'OK' };
  } catch (err) {
    console.error('Email send failed:', err.message);
    return { status: 500, body: 'Email failed' };
  }
}

// Vercel Web handler: the request body is untouched, so the signature check
// sees exactly what Stripe signed. Other methods get a 405 from Vercel.
export async function POST(request) {
  const rawBody = Buffer.from(await request.arrayBuffer());
  const { status, body } = await processStripeWebhook(rawBody, request.headers.get('stripe-signature'));
  return new Response(body, {
    status,
    headers: { 'Content-Type': 'text/plain; charset=utf-8' },
  });
}
