const assert = require('node:assert/strict');
const test = require('node:test');
const fs = require('fs');
const os = require('os');
const path = require('path');
const telemetry = require('../electron/services/telemetry');

test('telemetry uses broad non-identifying buckets', () => {
  assert.equal(telemetry.durationBucket(180001), '2m_5m');
  assert.equal(telemetry.itemCountBucket(170), '50_199');
  assert.equal(telemetry.itemCountBucket(5001), '5000_plus');
});

test('telemetry is a no-op unless the user opted in', async () => {
  let called = false;
  const sent = await telemetry.send({ enabled: false, eventName: 'scan_completed', fetchImpl: async () => { called = true; } });
  assert.equal(sent, false);
  assert.equal(called, false);
});

test('opted-in payload never contains paths, names, dates, or media metadata', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'foldiq-telemetry-'));
  let body;
  const sent = await telemetry.send({
    enabled: true,
    idPath: path.join(dir, 'id'),
    appVersion: '1.0.18',
    eventName: 'apply_completed',
    success: true,
    elapsedMs: 190000,
    itemCount: 170,
    fetchImpl: async (_url, options) => { body = JSON.parse(options.body); return { ok: true }; },
  });
  assert.equal(sent, true);
  assert.deepEqual(Object.keys(body).sort(), ['appVersion','durationBucket','eventId','eventName','installId','itemCountBucket','platform','success'].sort());
  assert.equal(JSON.stringify(body).includes('photo'), false);
});
