const fs = require('fs');
const path = require('path');
const { randomUUID } = require('crypto');

const ENDPOINT = 'https://foldiq.app/api/telemetry';
const EVENTS = new Set(['scan_completed', 'apply_completed', 'undo_completed', 'app_crashed']);

function durationBucket(elapsedMs) {
  if (elapsedMs < 30000) return 'under_30s';
  if (elapsedMs < 120000) return '30s_2m';
  if (elapsedMs < 300000) return '2m_5m';
  if (elapsedMs < 900000) return '5m_15m';
  return 'over_15m';
}

function itemCountBucket(count) {
  if (count <= 0) return '0';
  if (count < 50) return '1_49';
  if (count < 200) return '50_199';
  if (count < 1000) return '200_999';
  if (count < 5000) return '1000_4999';
  return '5000_plus';
}

function installId(filePath) {
  try {
    const existing = fs.readFileSync(filePath, 'utf8').trim();
    if (/^[0-9a-f-]{36}$/i.test(existing)) return existing;
  } catch {}
  const value = randomUUID();
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, value, { encoding: 'utf8', flag: 'w' });
  return value;
}

async function send({ enabled, idPath, appVersion, eventName, success, elapsedMs, itemCount, fetchImpl = globalThis.fetch }) {
  if (!enabled || !EVENTS.has(eventName) || typeof fetchImpl !== 'function') return false;
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 3000);
  try {
    const response = await fetchImpl(ENDPOINT, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      signal: controller.signal,
      body: JSON.stringify({
        eventId: randomUUID(),
        installId: installId(idPath),
        eventName,
        platform: 'windows',
        appVersion,
        success: success === true,
        durationBucket: durationBucket(Math.max(0, Number(elapsedMs) || 0)),
        itemCountBucket: itemCountBucket(Math.max(0, Number(itemCount) || 0)),
      }),
    });
    return response.ok;
  } catch {
    return false;
  } finally {
    clearTimeout(timeout);
  }
}

// Anonymous crash ping: no error text, no stack, no paths — only that a crash
// happened, the app version and how long the app had been running (bucketed).
function sendCrash({ enabled, idPath, appVersion, uptimeMs, fetchImpl }) {
  return send({
    enabled, idPath, appVersion, fetchImpl,
    eventName: 'app_crashed',
    success: false,
    elapsedMs: uptimeMs,
    itemCount: 0,
  });
}

module.exports = { durationBucket, itemCountBucket, installId, send, sendCrash, ENDPOINT };
