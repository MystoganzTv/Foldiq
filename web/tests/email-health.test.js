import assert from 'node:assert/strict';
import test from 'node:test';

process.env.EMAIL_HEALTH_SECRET = 'test-secret';
process.env.EMAIL_HEALTH_RECIPIENT = 'owner@example.com';

const { createEmailHealthHandler } = await import('../api/email-health.js');

function response() {
  return {
    statusCode: 0,
    body: null,
    status(code) { this.statusCode = code; return this; },
    json(body) { this.body = body; return this; },
  };
}

test('receipt health check is private and sends from receipts@foldiq.app', async () => {
  const deliveries = [];
  const handler = createEmailHealthHandler({
    resendClient: { emails: { send: async (...args) => { deliveries.push(args); return { data: { id: 'email-health-1' } }; } } },
  });

  const denied = response();
  await handler({ method: 'POST', headers: {} }, denied);
  assert.equal(denied.statusCode, 401);

  const accepted = response();
  await handler({ method: 'POST', headers: { authorization: 'Bearer test-secret' } }, accepted);
  assert.equal(accepted.statusCode, 200);
  assert.equal(deliveries[0][0].from, 'Foldiq <receipts@foldiq.app>');
  assert.equal(deliveries[0][0].to, 'owner@example.com');
  assert.match(deliveries[0][1].idempotencyKey, /foldiq-receipt-health/);
});
