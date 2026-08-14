import { createHash, sign } from 'node:crypto';
import { gunzipSync } from 'node:zlib';
import { queryDatabase } from './database.js';

const APPLE_API = 'https://api.appstoreconnect.apple.com';
const MAX_PAGES = 20;
const REPORTS = [
  { key: 'downloads', match: /^App(?: Store)? Downloads Standard$/i, metrics: { Counts: 'counts' } },
  { key: 'purchases', match: /^App Store Purchases Detailed$/i, metrics: { Purchases: 'purchases', 'Proceeds in USD': 'proceeds_usd', 'Sales in USD': 'sales_usd', 'Paying Users': 'paying_users' } },
  { key: 'discovery', match: /^App Store Discovery and Engagement Standard$/i, metrics: { Counts: 'counts', 'Unique Counts': 'unique_counts' } },
  { key: 'crashes', match: /^App Crashes(?: Standard)?$/i, metrics: { Crashes: 'crashes', 'Unique Devices': 'unique_devices' } },
  { key: 'installs', match: /^App Store Installations? and Deletions? Standard$/i, metrics: { Counts: 'counts', 'Unique Devices': 'unique_devices' } },
  { key: 'sessions', match: /^App Sessions Standard$/i, metrics: { Sessions: 'sessions', 'Total Session Duration': 'total_session_duration', 'Unique Devices': 'unique_devices' } },
];
const DIMENSIONS = {
  'Download Type': 'download_type',
  'App Version': 'app_version',
  Device: 'device',
  'Platform Version': 'platform_version',
  'Source Type': 'source_type',
  'Source Info': 'source_info',
  'Page Type': 'page_type',
  'Pre-Order': 'pre_order',
  Territory: 'territory',
  'Purchase Type': 'purchase_type',
  'Content Name': 'content_name',
  Event: 'event',
  'Engagement Type': 'engagement_type',
  'App Download Date': 'app_download_date',
};

function base64url(value) {
  return Buffer.from(value).toString('base64url');
}

export function createAppleToken({ issuerId, keyId, privateKey, now = Date.now() }) {
  if (!issuerId || !keyId || !privateKey) throw new Error('App Store Connect credentials are incomplete');
  const issuedAt = Math.floor(now / 1000);
  const header = base64url(JSON.stringify({ alg: 'ES256', kid: keyId, typ: 'JWT' }));
  const payload = base64url(JSON.stringify({ iss: issuerId, iat: issuedAt, exp: issuedAt + 15 * 60, aud: 'appstoreconnect-v1' }));
  const unsigned = `${header}.${payload}`;
  const key = privateKey.replaceAll('\\n', '\n').trim();
  const signature = sign('sha256', Buffer.from(unsigned), { key, dsaEncoding: 'ieee-p1363' });
  return `${unsigned}.${base64url(signature)}`;
}

function cleanHeader(value) {
  return String(value || '').replace(/^\uFEFF/, '').replaceAll('\u00a0', ' ').replace(/\s+/g, ' ').trim();
}

function parseLine(line) {
  const values = [];
  let value = '';
  let quoted = false;
  for (let index = 0; index < line.length; index++) {
    const character = line[index];
    if (character === '"') {
      if (quoted && line[index + 1] === '"') {
        value += '"';
        index++;
      } else {
        quoted = !quoted;
      }
    } else if (character === '\t' && !quoted) {
      values.push(value);
      value = '';
    } else {
      value += character;
    }
  }
  values.push(value);
  return values;
}

export function parseTsv(text) {
  const lines = String(text || '').split(/\r?\n/).filter(line => line.trim());
  if (!lines.length) return [];
  const headers = parseLine(lines[0]).map(cleanHeader);
  return lines.slice(1).map(line => {
    const values = parseLine(line);
    return Object.fromEntries(headers.map((header, index) => [header, values[index]?.trim() || '']));
  });
}

function numeric(value) {
  if (value == null || String(value).trim() === '') return null;
  const parsed = Number(String(value).replaceAll(',', '').trim());
  return Number.isFinite(parsed) ? parsed : null;
}

function reportDefinition(name) {
  return REPORTS.find(report => report.match.test(name));
}

function mergeRows(rows) {
  const merged = new Map();
  for (const row of rows) {
    const key = `${row.report_name}:${row.event_date}:${row.dimension_hash}`;
    const current = merged.get(key);
    if (!current) {
      merged.set(key, row);
      continue;
    }
    for (const [metric, value] of Object.entries(row.metrics)) {
      current.metrics[metric] = (current.metrics[metric] || 0) + value;
    }
  }
  return [...merged.values()];
}

export function normalizeAppleReport({ reportName, text, processingDate, instanceId, appId, now = new Date().toISOString() }) {
  const definition = reportDefinition(reportName);
  if (!definition) return [];
  const normalized = [];
  for (const source of parseTsv(text)) {
    const eventDate = source.Date;
    const sourceAppId = source['App Apple Identifier'];
    if (!/^\d{4}-\d{2}-\d{2}$/.test(eventDate) || (sourceAppId && String(sourceAppId) !== String(appId))) continue;
    const dimensions = {};
    for (const [appleName, key] of Object.entries(DIMENSIONS)) {
      if (source[appleName]) dimensions[key] = source[appleName];
    }
    const metrics = {};
    for (const [appleName, key] of Object.entries(definition.metrics)) {
      const value = numeric(source[appleName]);
      if (value != null) metrics[key] = value;
    }
    if (!Object.keys(metrics).length) continue;
    const canonicalDimensions = JSON.stringify(Object.fromEntries(Object.entries(dimensions).sort(([a], [b]) => a.localeCompare(b))));
    normalized.push({
      report_name: definition.key,
      event_date: eventDate,
      dimension_hash: createHash('sha256').update(canonicalDimensions).digest('hex'),
      dimensions,
      metrics,
      processing_date: processingDate,
      source_instance_id: instanceId,
      updated_at: now,
    });
  }
  return mergeRows(normalized);
}

function add(target, key, value) {
  target[key] = (target[key] || 0) + (Number(value) || 0);
}

function displayPeriod(minDate, maxDate) {
  if (!minDate || !maxDate) return 'No imported Apple data yet';
  return minDate === maxDate ? minDate : `${minDate}–${maxDate}`;
}

export function aggregateAppleRows(rows = []) {
  const result = {
    period: 'No imported Apple data yet', capturedAt: null,
    downloads: 0, redownloads: 0, updates: 0,
    impressions: 0, uniqueImpressions: 0, pageViews: 0, conversionRate: null,
    purchases: 0, salesUSD: 0, proceedsUSD: 0,
    sessions: 0, averageSessionSeconds: null, crashes: 0, installs: 0, deletions: 0,
    proceedsBySource: [], proceedsByReferrer: [], proceedsByTerritory: [],
  };
  const sources = {};
  const referrers = {};
  const territories = {};
  let sessionDuration = 0;
  let minDate = null;
  let maxDate = null;
  let latestProcessingDate = null;
  for (const row of rows) {
    const date = row.event_date;
    if (date && (!minDate || date < minDate)) minDate = date;
    if (date && (!maxDate || date > maxDate)) maxDate = date;
    if (row.processing_date && (!latestProcessingDate || row.processing_date > latestProcessingDate)) latestProcessingDate = row.processing_date;
    const dimensions = row.dimensions || {};
    const metrics = row.metrics || {};
    if (row.report_name === 'downloads') {
      const type = String(dimensions.download_type || '').toLowerCase();
      if (type.includes('first-time')) result.downloads += Number(metrics.counts) || 0;
      else if (type.includes('redownload')) result.redownloads += Number(metrics.counts) || 0;
      else if (type.includes('update')) result.updates += Number(metrics.counts) || 0;
    } else if (row.report_name === 'discovery') {
      const event = String(dimensions.event || '').toLowerCase();
      if (event === 'impression') {
        result.impressions += Number(metrics.counts) || 0;
        result.uniqueImpressions += Number(metrics.unique_counts) || 0;
      } else if (event === 'page view') result.pageViews += Number(metrics.counts) || 0;
    } else if (row.report_name === 'purchases') {
      result.purchases += Number(metrics.purchases) || 0;
      result.salesUSD += Number(metrics.sales_usd) || 0;
      result.proceedsUSD += Number(metrics.proceeds_usd) || 0;
      if (dimensions.source_type) add(sources, dimensions.source_type, metrics.proceeds_usd);
      if (dimensions.source_info) add(referrers, dimensions.source_info, metrics.proceeds_usd);
      if (dimensions.territory) add(territories, dimensions.territory, metrics.proceeds_usd);
    } else if (row.report_name === 'sessions') {
      result.sessions += Number(metrics.sessions) || 0;
      sessionDuration += Number(metrics.total_session_duration) || 0;
    } else if (row.report_name === 'crashes') result.crashes += Number(metrics.crashes) || 0;
    else if (row.report_name === 'installs') {
      const event = String(dimensions.event || '').toLowerCase();
      if (event === 'install') result.installs += Number(metrics.counts) || 0;
      else if (event === 'delete') result.deletions += Number(metrics.counts) || 0;
    }
  }
  result.period = displayPeriod(minDate, maxDate);
  result.capturedAt = latestProcessingDate ? `${latestProcessingDate}T12:00:00.000Z` : null;
  result.conversionRate = result.uniqueImpressions
    ? Math.round(((result.downloads + result.redownloads) / result.uniqueImpressions) * 10000) / 100
    : null;
  result.averageSessionSeconds = result.sessions ? Math.round(sessionDuration / result.sessions) : null;
  result.salesUSD = Math.round(result.salesUSD * 100) / 100;
  result.proceedsUSD = Math.round(result.proceedsUSD * 100) / 100;
  result.proceedsBySource = Object.entries(sources).map(([source, usd]) => ({ source, usd: Math.round(usd * 100) / 100 })).sort((a, b) => b.usd - a.usd);
  result.proceedsByReferrer = Object.entries(referrers).map(([referrer, usd]) => ({ referrer, usd: Math.round(usd * 100) / 100 })).sort((a, b) => b.usd - a.usd);
  result.proceedsByTerritory = Object.entries(territories).map(([territory, usd]) => ({ territory, usd: Math.round(usd * 100) / 100 })).sort((a, b) => b.usd - a.usd);
  return result;
}

async function jsonRequest(fetchImpl, url, options = {}) {
  const response = await fetchImpl(url, options);
  if (!response.ok) {
    const body = typeof response.text === 'function' ? await response.text() : '';
    throw new Error(`Request failed (${response.status})${body ? `: ${body.slice(0, 180)}` : ''}`);
  }
  return response.json();
}

async function listAppleResources(fetchImpl, url, token) {
  const data = [];
  let next = url;
  for (let page = 0; next && page < MAX_PAGES; page++) {
    const payload = await jsonRequest(fetchImpl, next, { headers: { Authorization: `Bearer ${token}` } });
    data.push(...(payload.data || []));
    next = payload.links?.next || null;
  }
  return data;
}

async function writeAppleRows(queryImpl, rows) {
  if (!rows.length) return;
  for (let offset = 0; offset < rows.length; offset += 250) {
    await queryImpl(
      `insert into apple_analytics_rows
        (report_name, event_date, dimension_hash, dimensions, metrics, processing_date, source_instance_id, updated_at)
       select report_name, event_date::date, dimension_hash, dimensions, metrics, processing_date::date, source_instance_id, updated_at::timestamptz
       from jsonb_to_recordset($1::jsonb) as row(
         report_name text, event_date text, dimension_hash text, dimensions jsonb, metrics jsonb,
         processing_date text, source_instance_id text, updated_at text
       )
       on conflict (report_name, event_date, dimension_hash) do update set
         dimensions = excluded.dimensions,
         metrics = excluded.metrics,
         processing_date = excluded.processing_date,
         source_instance_id = excluded.source_instance_id,
         updated_at = excluded.updated_at`,
      [JSON.stringify(rows.slice(offset, offset + 250))],
    );
  }
}

async function recordImport(queryImpl, { instanceId, reportName, processingDate, rowCount }) {
  await queryImpl(
    `insert into apple_analytics_imports (instance_id, report_name, processing_date, row_count)
     values ($1, $2, $3::date, $4)
     on conflict (instance_id) do update set
       report_name = excluded.report_name,
       processing_date = excluded.processing_date,
       row_count = excluded.row_count,
       imported_at = now()`,
    [instanceId, reportName, processingDate, rowCount],
  );
}

async function importedInstances(queryImpl, since) {
  const rows = await queryImpl('select instance_id from apple_analytics_imports where processing_date >= $1::date limit 1000', [since]);
  return new Set(rows.map(item => item.instance_id));
}

function selectedReports(resources) {
  return resources.filter(report => reportDefinition(report.attributes?.name || ''));
}

export async function syncAppleAnalytics({ fetchImpl = globalThis.fetch, queryImpl = queryDatabase, env = process.env, now = new Date() } = {}) {
  const issuerId = env.APPSTORE_CONNECT_ISSUER_ID;
  const keyId = env.APPSTORE_CONNECT_KEY_ID;
  const privateKey = env.APPSTORE_CONNECT_PRIVATE_KEY;
  const appId = env.APPSTORE_APP_ID;
  if (!issuerId || !keyId || !privateKey || !appId || !env.DATABASE_URL) throw new Error('Apple analytics storage is not fully configured');
  const token = createAppleToken({ issuerId, keyId, privateKey, now: now.getTime() });
  let requestId = env.APPSTORE_ANALYTICS_REQUEST_ID;
  if (!requestId) {
    const requests = await listAppleResources(fetchImpl, `${APPLE_API}/v1/apps/${appId}/analyticsReportRequests?filter%5BaccessType%5D=ONGOING&limit=200`, token);
    requestId = requests.find(request => !request.attributes?.stoppedDueToInactivity)?.id;
  }
  if (!requestId) throw new Error('No active ongoing Apple analytics report request exists');
  const reports = selectedReports(await listAppleResources(fetchImpl, `${APPLE_API}/v1/analyticsReportRequests/${requestId}/reports?limit=200`, token));
  const lookbackDays = Math.min(Math.max(Number.parseInt(env.APPLE_SYNC_LOOKBACK_DAYS || '7', 10) || 7, 2), 30);
  const cutoff = new Date(now.getTime() - lookbackDays * 86400000).toISOString().slice(0, 10);
  const instances = [];
  for (const report of reports) {
    const reportInstances = await listAppleResources(fetchImpl, `${APPLE_API}/v1/analyticsReports/${report.id}/instances?filter%5Bgranularity%5D=DAILY&limit=200`, token);
    for (const instance of reportInstances) {
      if (instance.attributes?.processingDate >= cutoff) instances.push({ report, instance });
    }
  }
  const alreadyImported = await importedInstances(queryImpl, cutoff);
  let imported = 0;
  let rowCount = 0;
  for (const { report, instance } of instances.sort((a, b) => a.instance.attributes.processingDate.localeCompare(b.instance.attributes.processingDate))) {
    if (alreadyImported.has(instance.id)) continue;
    const segments = await listAppleResources(fetchImpl, `${APPLE_API}/v1/analyticsReportInstances/${instance.id}/segments?fields%5BanalyticsReportSegments%5D=checksum,sizeInBytes,url&limit=200`, token);
    let rows = [];
    for (const segment of segments) {
      const response = await fetchImpl(segment.attributes?.url);
      if (!response.ok) throw new Error(`Apple report download failed (${response.status})`);
      const compressed = Buffer.from(await response.arrayBuffer());
      if (segment.attributes?.sizeInBytes != null && compressed.length !== Number(segment.attributes.sizeInBytes)) throw new Error('Apple report size verification failed');
      if (segment.attributes?.checksum) {
        const checksum = createHash('md5').update(compressed).digest('hex');
        if (checksum !== String(segment.attributes.checksum).toLowerCase()) throw new Error('Apple report checksum verification failed');
      }
      rows.push(...normalizeAppleReport({
        reportName: report.attributes.name,
        text: gunzipSync(compressed).toString('utf8'),
        processingDate: instance.attributes.processingDate,
        instanceId: instance.id,
        appId,
      }));
    }
    rows = mergeRows(rows);
    await writeAppleRows(queryImpl, rows);
    await recordImport(queryImpl, {
      instanceId: instance.id,
      reportName: report.attributes.name,
      processingDate: instance.attributes.processingDate,
      rowCount: rows.length,
    });
    imported++;
    rowCount += rows.length;
  }
  return { ok: true, requestId, reports: reports.length, availableInstances: instances.length, importedInstances: imported, importedRows: rowCount };
}
