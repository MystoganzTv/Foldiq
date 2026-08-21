import assert from 'node:assert/strict';
import test from 'node:test';

const {
  attributionChannel,
  attributionMetadata,
  channelFromMetadata,
  normalizeAttribution,
  sanitizeAttributionValue,
} = await import('../lib/attribution.js');

test('attribution keeps only coarse labels and never free text', () => {
  assert.equal(sanitizeAttributionValue('Product Hunt'), 'product-hunt');
  assert.equal(sanitizeAttributionValue('  news.ycombinator.com  '), 'news.ycombinator.com');
  assert.equal(sanitizeAttributionValue('<script>alert(1)</script>'), 'script-alert-1-script');
  assert.equal(sanitizeAttributionValue('https://evil.test/a?b=c'), 'https-evil.test-a-b-c');
  assert.equal(sanitizeAttributionValue('x'.repeat(200)).length, 60);
  assert.equal(sanitizeAttributionValue(null), '');
  assert.equal(sanitizeAttributionValue({ toString: () => 'nope' }), '');
});

test('attribution drops unknown fields so no extra data reaches Stripe', () => {
  const normalized = normalizeAttribution({
    source: 'reddit',
    medium: 'social',
    campaign: 'launch',
    referrer: 'reddit.com',
    email: 'buyer@example.com',
    path: '/private/photo.jpg',
  });
  assert.deepEqual(Object.keys(normalized).sort(), ['campaign', 'medium', 'referrer', 'source']);
  assert.equal(JSON.stringify(normalized).includes('buyer@example.com'), false);
  assert.deepEqual(normalizeAttribution('reddit'), {});
  assert.deepEqual(normalizeAttribution(['reddit']), {});
  assert.deepEqual(normalizeAttribution(null), {});
});

test('a deliberate campaign tag outranks the referring site', () => {
  assert.equal(attributionChannel({ source: 'producthunt', referrer: 'google.com' }), 'producthunt');
  assert.equal(attributionChannel({ referrer: 'google.com' }), 'google.com');
  assert.equal(attributionChannel({}), 'direct');
});

test('checkout metadata stays inside the Stripe key and value limits', () => {
  const metadata = attributionMetadata({
    source: 'Reddit',
    medium: 'social',
    campaign: 'r/MacApps launch',
    referrer: 'www.reddit.com',
  });
  assert.equal(metadata.attribution_channel, 'reddit');
  assert.equal(metadata.attribution_campaign, 'r-macapps-launch');
  assert.equal(metadata.attribution_referrer, 'www.reddit.com');
  for (const [key, value] of Object.entries(metadata)) {
    assert.ok(key.length <= 40, `${key} is too long for Stripe`);
    assert.ok(value.length <= 500, `${key} value is too long for Stripe`);
    assert.equal(typeof value, 'string');
  }
  assert.ok(Object.keys(metadata).length <= 50);
});

test('purchases made before attribution shipped are unknown, not direct', () => {
  assert.equal(channelFromMetadata({ platform: 'windows' }), 'unknown');
  assert.equal(channelFromMetadata(undefined), 'unknown');
  assert.equal(channelFromMetadata({ platform: 'windows', attribution_channel: 'direct' }), 'direct');
  assert.equal(channelFromMetadata({ attribution_source: 'producthunt' }), 'producthunt');
});
