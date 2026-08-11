import assert from 'node:assert/strict';
import { Readable } from 'node:stream';
import test from 'node:test';
import Stripe from 'stripe';

process.env.STRIPE_SECRET_KEY ||= 'sk_test_placeholder';
process.env.RESEND_API_KEY ||= 're_test_placeholder';
process.env.STRIPE_WEBHOOK_SECRET ||= 'whsec_foldiq_test';

const { buildInvoiceHTML, default: webhookHandler, escapeHTML, readRawBody } = await import('../api/webhook.js');

test('readRawBody preserves direct body representations', async () => {
  const json = '{"id":"evt_test","type":"foldiq.webhook.smoke"}';

  assert.equal((await readRawBody({ body: Buffer.from(json) })).toString(), json);
  assert.equal((await readRawBody({ body: new Uint8Array(Buffer.from(json)) })).toString(), json);
  assert.equal((await readRawBody({ body: json })).toString(), json);
  assert.equal(
    (await readRawBody({ body: { id: 'evt_test', type: 'foldiq.webhook.smoke' } })).toString(),
    json
  );
});

test('readRawBody falls back to an unconsumed request stream', async () => {
  const request = Readable.from(['{"id":', '"evt_stream"}']);
  request.body = undefined;

  assert.equal((await readRawBody(request)).toString(), '{"id":"evt_stream"}');
});

test('handler verifies a signed event when Vercel supplies a parsed body', async () => {
  const payload = JSON.stringify({
    id: 'evt_foldiq_smoke',
    type: 'foldiq.webhook.smoke',
    data: { object: {} },
  });
  const signature = Stripe.webhooks.generateTestHeaderString({
    payload,
    secret: process.env.STRIPE_WEBHOOK_SECRET,
  });
  const response = {
    statusCode: 0,
    body: '',
    status(code) {
      this.statusCode = code;
      return this;
    },
    send(body) {
      this.body = body;
      return this;
    },
  };

  await webhookHandler({
    method: 'POST',
    body: JSON.parse(payload),
    headers: { 'stripe-signature': signature },
  }, response);

  assert.equal(response.statusCode, 200);
  assert.equal(response.body, 'Ignored');
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
