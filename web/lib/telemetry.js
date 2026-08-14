import { createHash } from 'node:crypto';

export const EVENT_NAMES = new Set(['scan_completed', 'apply_completed', 'undo_completed']);
export const PLATFORMS = new Set(['macos', 'windows']);
export const DURATION_BUCKETS = new Set(['under_30s', '30s_2m', '2m_5m', '5m_15m', 'over_15m']);
export const ITEM_BUCKETS = new Set(['0', '1_49', '50_199', '200_999', '1000_4999', '5000_plus']);

function clean(value, max = 40) {
  return typeof value === 'string' ? value.trim().slice(0, max) : '';
}

export function normalizeTelemetry(body, hashSalt = process.env.TELEMETRY_HASH_SALT) {
  if (!body || typeof body !== 'object' || Array.isArray(body) || !hashSalt) return null;
  const eventId = clean(body.eventId, 36);
  const installId = clean(body.installId, 80);
  const eventName = clean(body.eventName);
  const platform = clean(body.platform);
  const appVersion = clean(body.appVersion, 24);
  const durationBucket = clean(body.durationBucket, 16);
  const itemCountBucket = clean(body.itemCountBucket, 16);
  if (!/^[0-9a-f-]{36}$/i.test(eventId) || !/^[0-9a-f-]{36}$/i.test(installId)) return null;
  if (!EVENT_NAMES.has(eventName) || !PLATFORMS.has(platform)) return null;
  if (!/^\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?$/.test(appVersion)) return null;
  if (!DURATION_BUCKETS.has(durationBucket) || !ITEM_BUCKETS.has(itemCountBucket)) return null;
  if (typeof body.success !== 'boolean') return null;
  return {
    event_id: eventId,
    install_hash: createHash('sha256').update(`${hashSalt}:${installId}`).digest('hex'),
    event_name: eventName,
    platform,
    app_version: appVersion,
    success: body.success,
    duration_bucket: durationBucket,
    item_count_bucket: itemCountBucket,
  };
}

export function aggregateTelemetry(rows = []) {
  const result = { events: rows.length, activeInstalls: 0, successRate: null, byPlatform: {}, byEvent: {} };
  const installs = new Set();
  let successes = 0;
  for (const row of rows) {
    installs.add(row.install_hash);
    if (row.success) successes++;
    result.byPlatform[row.platform] = (result.byPlatform[row.platform] || 0) + 1;
    const current = result.byEvent[row.event_name] || { total: 0, successful: 0 };
    current.total++;
    if (row.success) current.successful++;
    result.byEvent[row.event_name] = current;
  }
  result.activeInstalls = installs.size;
  result.successRate = rows.length ? Math.round((successes / rows.length) * 1000) / 10 : null;
  return result;
}
