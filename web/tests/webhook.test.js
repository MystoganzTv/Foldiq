import assert from 'node:assert/strict';
import test from 'node:test';
import Stripe from 'stripe';

process.env.STRIPE_SECRET_KEY ||= 'sk_test_placeholder';
process.env.RESEND_API_KEY ||= 're_test_placeholder';
process.env.STRIPE_WEBHOOK_SECRET ||= 'whsec_foldiq_test';

const { buildInvoiceHTML, buildOwnerSaleHTML, POST, escapeHTML } = await import('../api/webhook.js');

// Real Stripe deliveries are pretty-printed JSON. The old handler re-serialised
// Vercel's parsed req.body, which dropped this whitespace and made every live
// event fail with "No signatures found matching the expected signature".
function signedStripeRequest(event, { tamper = false } = {}) {
  const payload = JSON.stringify(event, null, 2);
  const signature = Stripe.webhooks.generateTestHeaderString({
    payload,
    secret: process.env.STRIPE_WEBHOOK_SECRET,
  });
  return new Request('https://foldiq.app/api/webhook', {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'stripe-signature': signature },
    body: tamper ? payload.replace('foldiq.webhook.smoke', 'foldiq.webhook.other') : payload,
  });
}

test('a pretty-printed Stripe event passes signature verification', async () => {
  const response = await POST(signedStripeRequest({
    id: 'evt_foldiq_smoke',
    object: 'event',
    type: 'foldiq.webhook.smoke',
    data: { object: {} },
  }));

  assert.equal(response.status, 200);
  assert.equal(await response.text(), 'Ignored');
});

test('a modified body is rejected', async () => {
  const response = await POST(signedStripeRequest({
    id: 'evt_foldiq_smoke',
    object: 'event',
    type: 'foldiq.webhook.smoke',
    data: { object: {} },
  }, { tamper: true }));

  assert.equal(response.status, 400);
  assert.match(await response.text(), /No signatures found/);
});

test('a request without a Stripe signature is rejected', async () => {
  const response = await POST(new Request('https://foldiq.app/api/webhook', { method: 'POST', body: '{}' }));
  assert.equal(response.status, 400);
});

test('email template escapes Stripe-controlled customer fields', () => {
  assert.equal(escapeHTML(`<script>alert("x")</script>`), '&lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt;');

  const html = buildInvoiceHTML({
    customerName: '<img src=x onerror=alert(1)>',
    customerEmail: 'buyer@example.com',
    invoiceId: 'ORDER-1',
    date: 'August 10, 2026',
    amount: '$4.99',
    platform: 'windows',
    checkoutSessionId: 'cs_test_paid123',
  });

  assert.doesNotMatch(html, /<img src=x onerror/);
  assert.match(html, /&lt;img src=x onerror=alert\(1\)&gt;/);
  assert.match(html, /Foldiq for Windows/);
  assert.match(html, /\/api\/download\?session_id=cs_test_paid123/);
});

test('purchase email source is configurable and defaults to the verified Foldiq mailbox', async () => {
  const source = await import('node:fs').then(fs => fs.readFileSync(new URL('../api/webhook.js', import.meta.url), 'utf8'));
  assert.match(source, /RECEIPTS_FROM_EMAIL.*receipts@foldiq\.app/);
  assert.match(source, /idempotencyKey.*foldiq-order-/);
  assert.match(source, /replyTo:/);
});

test('a Mac order email links to the verified Mac download, not the App Store', async () => {
  const { buildInvoiceHTML } = await import('../api/webhook.js');
  const html = buildInvoiceHTML({
    customerName: 'Ana',
    customerEmail: 'ana@example.com',
    invoiceId: 'FQ-1',
    date: 'Nov 15, 2026',
    amount: '$19.99',
    platform: 'mac',
    checkoutSessionId: 'cs_test_mac123',
  });
  assert.match(html, /\/api\/download\?session_id=cs_test_mac123/);
  assert.match(html, /Download Foldiq for Mac/);
  assert.doesNotMatch(html, /apps\.apple\.com/);
});

test('owner sale notification is a summary, not a copy of the customer receipt', () => {
  const html = buildOwnerSaleHTML({
    amount: '$19.99',
    platform: 'mac',
    channel: 'direct',
    customerEmail: 'buyer@example.com',
    customerName: '<b>x</b>',
    date: 'November 17, 2026',
    paymentIntent: 'pi_123',
    checkoutSessionId: 'cs_live_abc',
  });

  assert.match(html, /New sale · Foldiq for Mac/);
  assert.match(html, /https:\/\/dashboard\.stripe\.com\/payments\/pi_123/);
  assert.doesNotMatch(html, /Thanks for your purchase/);
  assert.doesNotMatch(html, /<b>x<\/b>/);
});
