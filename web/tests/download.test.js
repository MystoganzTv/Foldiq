import assert from 'node:assert/strict';
import test from 'node:test';

process.env.STRIPE_SECRET_KEY ||= 'sk_test_placeholder';

const { createDownloadHandler, isAllowedGitHubRedirect, recordPurchaseDownload } = await import('../api/download.js');

function response() {
  return {
    statusCode: 0,
    body: '',
    headers: {},
    status(code) { this.statusCode = code; return this; },
    send(body) { this.body = body; return this; },
    setHeader(name, value) { this.headers[name.toLowerCase()] = value; },
  };
}

function session(overrides = {}) {
  return {
    id: 'cs_test_paid123',
    payment_status: 'paid',
    status: 'complete',
    metadata: { platform: 'windows' },
    ...overrides,
  };
}

test('rejects missing and malformed checkout sessions', async () => {
  const handler = createDownloadHandler({
    stripeClient: { checkout: { sessions: { retrieve: async () => session() } } },
    githubToken: 'github-token',
  });
  const res = response();

  await handler({ method: 'GET', query: {} }, res);
  assert.equal(res.statusCode, 400);
});

test('rejects unpaid and non-Windows purchases before calling GitHub', async () => {
  let fetchCalled = false;
  const handler = createDownloadHandler({
    stripeClient: {
      checkout: { sessions: { retrieve: async () => session({ payment_status: 'unpaid' }) } },
    },
    fetchImpl: async () => { fetchCalled = true; },
    githubToken: 'github-token',
  });
  const res = response();

  await handler({ method: 'GET', query: { session_id: 'cs_test_paid123' } }, res);
  assert.equal(res.statusCode, 403);
  assert.equal(fetchCalled, false);
});

test('redirects a verified purchase to GitHub short-lived asset storage', async () => {
  const requests = [];
  const fetchImpl = async (url, options) => {
    requests.push({ url, options });
    if (requests.length === 1) {
      return {
        ok: true,
        status: 200,
        json: async () => ({ assets: [{ name: 'Foldiq-Setup.exe', url: 'https://api.github.com/assets/42' }] }),
      };
    }
    return {
      status: 302,
      headers: new Headers({ location: 'https://release-assets.githubusercontent.com/private/signed' }),
    };
  };
  const handler = createDownloadHandler({
    stripeClient: { checkout: { sessions: { retrieve: async () => session() } } },
    fetchImpl,
    githubToken: 'github-token',
  });
  const res = response();

  await handler({ method: 'GET', query: { session_id: 'cs_test_paid123' } }, res);
  assert.equal(res.statusCode, 302);
  assert.equal(res.headers.location, 'https://release-assets.githubusercontent.com/private/signed');
  assert.equal(requests[1].options.redirect, 'manual');
  assert.equal(requests[1].options.headers.Authorization, 'Bearer github-token');
});

test('records unique purchase fulfillment and repeat requests in Stripe metadata', async () => {
  const updates = [];
  const stripe = { paymentIntents: { update: async (id, value) => { updates.push({ id, value }); } } };
  const now = new Date('2026-08-14T01:02:03.000Z');
  const first = await recordPurchaseDownload(stripe, {
    payment_intent: { id: 'pi_paid', metadata: {} },
  }, now);
  const repeat = await recordPurchaseDownload(stripe, {
    payment_intent: {
      id: 'pi_paid',
      metadata: { foldiq_download_count: '2', foldiq_first_download_at: '2026-08-14T00:00:00.000Z' },
    },
  }, now);

  assert.equal(first, true);
  assert.equal(repeat, true);
  assert.equal(updates[0].value.metadata.foldiq_download_count, '1');
  assert.equal(updates[1].value.metadata.foldiq_download_count, '3');
  assert.equal(updates[1].value.metadata.foldiq_first_download_at, '2026-08-14T00:00:00.000Z');
  assert.equal(updates[1].value.metadata.foldiq_last_download_at, '2026-08-14T01:02:03.000Z');
});

test('refuses an unexpected redirect host', () => {
  assert.equal(isAllowedGitHubRedirect('https://release-assets.githubusercontent.com/file'), true);
  assert.equal(isAllowedGitHubRedirect('https://evil.example/file'), false);
});

test('a Mac purchase downloads the Mac installer and other platforms are refused', async () => {
  const requested = [];
  const fetchImpl = async (url) => {
    requested.push(url);
    if (requested.length === 1) {
      return {
        ok: true,
        status: 200,
        json: async () => ({ assets: [
          { name: 'Foldiq-Setup.exe', url: 'https://api.github.com/assets/1' },
          { name: 'Foldiq.dmg', url: 'https://api.github.com/assets/2' },
        ] }),
      };
    }
    return { status: 302, headers: new Headers({ location: 'https://release-assets.githubusercontent.com/private/mac' }) };
  };
  const mac = createDownloadHandler({
    stripeClient: { checkout: { sessions: { retrieve: async () => session({ metadata: { platform: 'mac' } }) } } },
    fetchImpl,
    githubToken: 'github-token',
  });
  const res = response();
  await mac({ method: 'GET', query: { session_id: 'cs_test_paid123' } }, res);
  assert.equal(res.statusCode, 302);
  assert.equal(requested[1], 'https://api.github.com/assets/2');

  const unknown = createDownloadHandler({
    stripeClient: { checkout: { sessions: { retrieve: async () => session({ metadata: { platform: 'linux' } }) } } },
    fetchImpl: async () => { throw new Error('GitHub must not be called'); },
    githubToken: 'github-token',
  });
  const refused = response();
  await unknown({ method: 'GET', query: { session_id: 'cs_test_paid123' } }, refused);
  assert.equal(refused.statusCode, 403);
});

test('checkout builds a Mac session and refuses an unknown platform', async () => {
  const { checkoutSessionParams } = await import('../api/create-checkout.js');
  const mac = checkoutSessionParams('mac', {}, {});
  assert.equal(mac.metadata.platform, 'mac');
  assert.equal(mac.line_items[0].price_data.product_data.name, 'Foldiq for Mac');
  assert.equal(mac.line_items[0].price_data.unit_amount, 1999);
  assert.equal(mac.automatic_tax.enabled, false);
  assert.match(mac.success_url, /platform=mac$/);

  const taxed = checkoutSessionParams('windows', {}, { STRIPE_AUTOMATIC_TAX: 'true' });
  assert.equal(taxed.automatic_tax.enabled, true);
  assert.equal(taxed.line_items[0].price_data.tax_behavior, 'inclusive');

  assert.equal(checkoutSessionParams('linux', {}, {}), null);
  assert.equal(checkoutSessionParams(undefined, {}, {}), null);
});

test('finds the Mac installer in an earlier release when the latest one only has Windows', async () => {
  const requested = [];
  const fetchImpl = async (url) => {
    requested.push(url);
    if (url.endsWith('/releases/latest')) {
      return { ok: true, status: 200, json: async () => ({ assets: [{ name: 'Foldiq-Setup.exe', url: 'https://api.github.com/assets/1' }] }) };
    }
    if (url.includes('/releases?per_page=')) {
      return { ok: true, status: 200, json: async () => ([
        { draft: true, assets: [{ name: 'Foldiq.dmg', url: 'https://api.github.com/assets/draft' }] },
        { draft: false, assets: [{ name: 'Foldiq.dmg', url: 'https://api.github.com/assets/9' }] },
      ]) };
    }
    return { status: 302, headers: new Headers({ location: 'https://release-assets.githubusercontent.com/private/mac' }) };
  };
  const handler = createDownloadHandler({
    stripeClient: { checkout: { sessions: { retrieve: async () => session({ metadata: { platform: 'mac' } }) } } },
    fetchImpl,
    githubToken: 'github-token',
  });
  const res = response();
  await handler({ method: 'GET', query: { session_id: 'cs_test_paid123' } }, res);
  assert.equal(res.statusCode, 302);
  assert.equal(requested.at(-1), 'https://api.github.com/assets/9');
});
