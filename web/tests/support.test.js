import assert from 'node:assert/strict';
import test from 'node:test';

const { createSupportHandler } = await import('../api/support.js');

function response() {
  return {
    statusCode: 0,
    body: null,
    status(code) { this.statusCode = code; return this; },
    json(body) { this.body = body; return this; },
  };
}

test('support endpoint validates fields and sends a replyable private message', async () => {
  const deliveries = [];
  const handler = createSupportHandler({
    resendClient: { emails: { send: async payload => { deliveries.push(payload); return { data: { id: 'email-1' } }; } } },
    ownerEmail: 'owner@example.com',
  });
  const res = response();

  await handler({
    method: 'POST',
    headers: { 'x-forwarded-for': '203.0.113.10' },
    body: {
      name: 'Jane <Tester>',
      email: 'jane@example.com',
      source: 'foldiq-windows',
      message: 'Scan failed\n--- Foldiq diagnostic summary ---',
    },
  }, res);

  assert.equal(res.statusCode, 200);
  assert.equal(deliveries.length, 1);
  assert.equal(deliveries[0].to, 'owner@example.com');
  assert.equal(deliveries[0].replyTo, 'jane@example.com');
  assert.match(deliveries[0].subject, /Windows diagnostic/);
  assert.doesNotMatch(deliveries[0].html, /Jane <Tester>/);
  assert.match(deliveries[0].html, /Jane &lt;Tester&gt;/);
});

test('support endpoint rejects invalid submissions and silently accepts bots', async () => {
  let deliveries = 0;
  const handler = createSupportHandler({
    resendClient: { emails: { send: async () => { deliveries++; } } },
  });

  const invalid = response();
  await handler({ method: 'POST', headers: {}, body: { name: 'A', email: 'bad', message: 'Hi' } }, invalid);
  assert.equal(invalid.statusCode, 400);

  const bot = response();
  await handler({ method: 'POST', headers: {}, body: { website: 'spam.example' } }, bot);
  assert.equal(bot.statusCode, 200);
  assert.equal(deliveries, 0);
});
