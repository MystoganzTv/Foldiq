const fs = require('fs');
const path = require('path');

const REQUEST_INTERVAL_MS = 1100;
const REQUEST_TIMEOUT_MS = 12000;
const CACHE_VERSION = 1;

function finiteCoordinate(value, min, max) {
  const number = Number(value);
  return Number.isFinite(number) && number >= min && number <= max ? number : null;
}

function coordinateKey(latitude, longitude) {
  const lat = finiteCoordinate(latitude, -90, 90);
  const lon = finiteCoordinate(longitude, -180, 180);
  if (lat == null || lon == null) return null;
  // A roughly one-kilometre bucket avoids sending thousands of nearly identical
  // photo coordinates while still keeping neighbouring towns distinct.
  return `${lat.toFixed(2)},${lon.toFixed(2)}`;
}

function safeFolderPart(value) {
  if (typeof value !== 'string') return null;
  const cleaned = value
    .normalize('NFKC')
    .replace(/[<>:"/\\|?*\u0000-\u001F]/g, ' ')
    .replace(/[. ]+$/g, '')
    .replace(/\s+/g, ' ')
    .trim()
    .slice(0, 80);
  return cleaned || null;
}

function normalizeLocation(payload) {
  const address = payload?.address || {};
  const city = address.city || address.town || address.village || address.municipality || address.county;
  const state = address.state || address.region || address.state_district;
  const country = address.country;
  const normalized = {
    city: safeFolderPart(city),
    state: safeFolderPart(state),
    country: safeFolderPart(country),
  };
  return normalized.city || normalized.state || normalized.country ? normalized : null;
}

function readCache(cachePath) {
  try {
    const parsed = JSON.parse(fs.readFileSync(cachePath, 'utf8'));
    return parsed?.version === CACHE_VERSION && parsed.entries && typeof parsed.entries === 'object'
      ? parsed.entries
      : {};
  } catch {
    return {};
  }
}

function writeCache(cachePath, entries) {
  fs.mkdirSync(path.dirname(cachePath), { recursive: true });
  const tempPath = `${cachePath}.${process.pid}.tmp`;
  fs.writeFileSync(tempPath, JSON.stringify({ version: CACHE_VERSION, entries }), 'utf8');
  fs.renameSync(tempPath, cachePath);
}

function delay(milliseconds) {
  return new Promise(resolve => setTimeout(resolve, milliseconds));
}

async function requestLocation(latitude, longitude, { appVersion = 'unknown', fetchImpl = globalThis.fetch } = {}) {
  if (typeof fetchImpl !== 'function') throw new Error('Network geocoding is unavailable');
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);
  const query = new URLSearchParams({
    format: 'jsonv2',
    lat: String(latitude),
    lon: String(longitude),
    zoom: '10',
    addressdetails: '1',
    'accept-language': 'en',
  });

  try {
    const response = await fetchImpl(`https://nominatim.openstreetmap.org/reverse?${query}`, {
      signal: controller.signal,
      headers: {
        'User-Agent': `Foldiq/${appVersion} (support@foldiq.app)`,
        Accept: 'application/json',
      },
    });
    if (!response.ok) throw new Error(`Location service returned HTTP ${response.status}`);
    return normalizeLocation(await response.json());
  } finally {
    clearTimeout(timer);
  }
}

async function enrichFiles(files, {
  enabled,
  cachePath,
  appVersion,
  onProgress = () => {},
  fetchImpl = globalThis.fetch,
  requestIntervalMs = REQUEST_INTERVAL_MS,
} = {}) {
  if (!enabled) return { files, warnings: [] };

  const groups = new Map();
  for (const file of files) {
    const key = coordinateKey(file.latitude, file.longitude);
    if (!key) continue;
    if (!groups.has(key)) groups.set(key, { latitude: Number(file.latitude), longitude: Number(file.longitude) });
  }

  const cache = readCache(cachePath);
  const warnings = [];
  const missing = [...groups.entries()].filter(([key]) => !(key in cache));
  let completed = groups.size - missing.length;
  onProgress({ phase: 'locations', current: completed, total: groups.size, cached: completed });

  for (let index = 0; index < missing.length; index++) {
    const [key, coordinate] = missing[index];
    try {
      cache[key] = await requestLocation(coordinate.latitude, coordinate.longitude, { appVersion, fetchImpl });
      writeCache(cachePath, cache);
    } catch (error) {
      warnings.push(error?.name === 'AbortError' ? 'Location lookup timed out.' : (error?.message || 'Location lookup failed.'));
      cache[key] = null;
    }
    completed++;
    onProgress({ phase: 'locations', current: completed, total: groups.size, cached: groups.size - missing.length });
    if (index < missing.length - 1 && requestIntervalMs > 0) await delay(requestIntervalMs);
  }

  return {
    files: files.map(file => {
      const key = coordinateKey(file.latitude, file.longitude);
      return key ? { ...file, location: cache[key] || null } : file;
    }),
    warnings: [...new Set(warnings)],
  };
}

module.exports = {
  coordinateKey,
  safeFolderPart,
  normalizeLocation,
  requestLocation,
  enrichFiles,
};
