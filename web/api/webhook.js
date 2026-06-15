// Vercel Serverless Function — Stripe webhook handler.
// Listens for checkout.session.completed and emails a receipt + download link
// via Resend to the customer, plus a copy to the owner.
//
// IMPORTANT: bodyParser is disabled so Stripe can verify the raw request body.
//
// Required env vars (Vercel → Project → Settings → Environment Variables):
//   STRIPE_SECRET_KEY       — sk_live_...
//   STRIPE_WEBHOOK_SECRET   — whsec_... (from Stripe Dashboard → Webhooks)
//   RESEND_API_KEY          — re_...    (from resend.com)

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
const DOWNLOAD_URL = 'https://github.com/MystoganzTv/Foldiq/releases/download/1.0/Foldiq-1.0.dmg';

// Read the raw request body as a Buffer.
async function readRawBody(req) {
  const chunks = [];
  for await (const chunk of req) {
    chunks.push(typeof chunk === 'string' ? Buffer.from(chunk) : chunk);
  }
  return Buffer.concat(chunks);
}

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
          <img src="${SITE}/icon.png" width="56" height="56"
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
            <a href="${SITE}/contact" style="color:#3B82F6;text-decoration:none;">foldiq.app/contact</a>
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
  const amountTotal   = session.amount_total || 499;
  const amount        = `$${(amountTotal / 100).toFixed(2)}`;
  const invoiceId     = session.id.replace('cs_live_', '').replace('cs_test_', '').slice(0, 16).toUpperCase();
  const date          = new Date().toLocaleDateString('en-US', { year: 'numeric', month: 'long', day: 'numeric' });

  if (!customerEmail) {
    console.error('No customer email found in session');
    res.status(200).send('No email');
    return;
  }

  const html = buildInvoiceHTML({ customerName, customerEmail, invoiceId, date, amount });

  try {
    await resend.emails.send({
      from: 'Foldiq <receipts@foldiq.app>',
      to: customerEmail,
      subject: `Your Foldiq receipt — ${amount}`,
      html,
    });

    await resend.emails.send({
      from: 'Foldiq <receipts@foldiq.app>',
      to: OWNER_EMAIL,
      subject: `[New Sale] Foldiq ${amount} — ${customerEmail}`,
      html,
    });

    console.log(`Receipt sent to ${customerEmail} and ${OWNER_EMAIL}`);
    res.status(200).send('OK');
  } catch (err) {
    console.error('Email send failed:', err.message);
    res.status(500).send('Email failed');
  }
}
