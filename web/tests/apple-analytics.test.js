import assert from 'node:assert/strict';
import { createHash, generateKeyPairSync } from 'node:crypto';
import { gzipSync } from 'node:zlib';
import test from 'node:test';

import {
  aggregateAppleRows,
  createAppleToken,
  normalizeAppleReport,
  parseTsv,
  syncAppleAnalytics,
} from '../lib/apple-analytics.js';
import { createAppleMetricsSyncHandler } from '../api/apple-metrics-sync.js';

const { privateKey } = generateKeyPairSync('ec', { namedCurve: 'P-256' });
const testPrivateKey = privateKey.export({ format: 'pem', type: 'pkcs8' }).toString();

function response() {
  return {
    statusCode: 0, body: null, headers: {},
    status(code) { this.statusCode = code; return this; },
    json(body) { this.body = body; return this; },
    setHeader(name, value) { this.headers[name.toLowerCase()] = value; },
  };
}

test('creates a short-lived ES256 App Store Connect token', () => {
  const token = createAppleToken({ issuerId: 'issuer', keyId: 'KEY123', privateKey: testPrivateKey, now: 1_700_000_000_000 });
  const [header, payload, signature] = token.split('.');
  assert.deepEqual(JSON.parse(Buffer.from(header, 'base64url')), { alg: 'ES256', kid: 'KEY123', typ: 'JWT' });
  const claims = JSON.parse(Buffer.from(payload, 'base64url'));
  assert.equal(claims.iss, 'issuer');
  assert.equal(claims.aud, 'appstoreconnect-v1');
  assert.equal(claims.exp - claims.iat, 900);
  assert.equal(Buffer.from(signature, 'base64url').length, 64);
});

test('parses quoted Apple TSV fields and normalizes non-breaking headers', () => {
  const rows = parseTsv('\uFEFFDate\tSource\u00a0Type\tTerritory\n2026-08-14\t"App Store\tsearch"\tUS\n');
  assert.deepEqual(rows, [{ Date: '2026-08-14', 'Source Type': 'App Store\tsearch', Territory: 'US' }]);
});

test('normalizes only approved aggregate fields and excludes app identity columns', () => {
  const text = [
    'Date\tApp Name\tApp Apple Identifier\tDownload Type\tApp Version\tDevice\tSource Type\tTerritory\tCounts',
    '2026-08-13\tFoldiq\t6772513569\tFirst-time Download\t1.0.18\tDesktop\tApp Store search\tUS\t2',
  ].join('\n');
  const rows = normalizeAppleReport({ reportName: 'App Store Downloads Standard', text, processingDate: '2026-08-14', instanceId: 'instance-1', appId: '6772513569' });
  assert.equal(rows.length, 1);
  assert.deepEqual(rows[0].metrics, { counts: 2 });
  assert.deepEqual(rows[0].dimensions, { download_type: 'First-time Download', app_version: '1.0.18', device: 'Desktop', source_type: 'App Store search', territory: 'US' });
  assert.equal(JSON.stringify(rows).includes('Foldiq'), false);
  assert.equal(JSON.stringify(rows).includes('6772513569'), false);
});

test('recognizes Apple production names for downloads and installation reports', () => {
  const downloads = normalizeAppleReport({
    reportName: 'App Downloads Standard',
    text: 'Date\tApp Apple Identifier\tDownload Type\tCounts\n2026-08-13\t6772513569\tFirst-Time Download\t2',
    processingDate: '2026-08-14',
    instanceId: 'download-instance',
    appId: '6772513569',
  });
  const installations = normalizeAppleReport({
    reportName: 'App Store Installation and Deletion Standard',
    text: 'Date\tApp Apple Identifier\tEvent\tCounts\n2026-08-13\t6772513569\tInstall\t1',
    processingDate: '2026-08-14',
    instanceId: 'install-instance',
    appId: '6772513569',
  });
  assert.equal(downloads[0].report_name, 'downloads');
  assert.equal(installations[0].report_name, 'installs');
});

test('aggregates Apple acquisition, commerce, usage, and reliability without summing unique users', () => {
  const rows = [
    { report_name: 'downloads', event_date: '2026-08-10', processing_date: '2026-08-12', dimensions: { download_type: 'First-time Download' }, metrics: { counts: 6 } },
    { report_name: 'downloads', event_date: '2026-08-10', processing_date: '2026-08-12', dimensions: { download_type: 'Redownload' }, metrics: { counts: 1 } },
    { report_name: 'discovery', event_date: '2026-08-10', processing_date: '2026-08-13', dimensions: { event: 'Impression' }, metrics: { counts: 200, unique_counts: 100 } },
    { report_name: 'discovery', event_date: '2026-08-10', processing_date: '2026-08-13', dimensions: { event: 'Page view' }, metrics: { counts: 40, unique_counts: 30 } },
    { report_name: 'purchases', event_date: '2026-08-11', processing_date: '2026-08-13', dimensions: { source_type: 'App Store search', source_info: 'Example Referrer', territory: 'US' }, metrics: { purchases: 2, sales_usd: 12, proceeds_usd: 8, paying_users: 2 } },
    { report_name: 'sessions', event_date: '2026-08-11', processing_date: '2026-08-14', dimensions: {}, metrics: { sessions: 4, total_session_duration: 100, unique_devices: 3 } },
    { report_name: 'crashes', event_date: '2026-08-11', processing_date: '2026-08-14', dimensions: {}, metrics: { crashes: 1, unique_devices: 1 } },
    { report_name: 'installs', event_date: '2026-08-11', processing_date: '2026-08-14', dimensions: { event: 'Install' }, metrics: { counts: 3 } },
    { report_name: 'installs', event_date: '2026-08-11', processing_date: '2026-08-14', dimensions: { event: 'Delete' }, metrics: { counts: 1 } },
  ];
  const result = aggregateAppleRows(rows);
  assert.equal(result.downloads, 6);
  assert.equal(result.conversionRate, 7);
  assert.equal(result.purchases, 2);
  assert.equal(result.proceedsUSD, 8);
  assert.deepEqual(result.proceedsByReferrer, [{ referrer: 'Example Referrer', usd: 8 }]);
  assert.equal(result.sessions, 4);
  assert.equal(result.averageSessionSeconds, 25);
  assert.equal(result.crashes, 1);
  assert.equal(result.installs, 3);
  assert.equal(result.deletions, 1);
  assert.equal('payingUsers' in result, false);
});

test('sync downloads, verifies, imports, and records each Apple instance once', async () => {
  const tsv = 'Date\tApp Name\tApp Apple Identifier\tDownload Type\tTerritory\tCounts\n2026-08-13\tFoldiq\t6772513569\tFirst-time Download\tUS\t2\n';
  const compressed = gzipSync(tsv);
  const checksum = createHash('md5').update(compressed).digest('hex');
  const writes = [];
  const fetchImpl = async (url, options = {}) => {
    const address = String(url);
    if (address.includes('/apps/6772513569/analyticsReportRequests')) return { ok: true, json: async () => ({ data: [{ id: 'request-1', attributes: { accessType: 'ONGOING', stoppedDueToInactivity: false } }], links: {} }) };
    if (address.includes('/analyticsReportRequests/request-1/reports')) return { ok: true, json: async () => ({ data: [{ id: 'report-1', attributes: { name: 'App Store Downloads Standard' } }], links: {} }) };
    if (address.includes('/analyticsReports/report-1/instances')) return { ok: true, json: async () => ({ data: [{ id: 'instance-1', attributes: { granularity: 'DAILY', processingDate: '2026-08-14' } }], links: {} }) };
    if (address.includes('/analyticsReportInstances/instance-1/segments')) return { ok: true, json: async () => ({ data: [{ id: 'segment-1', attributes: { url: 'https://signed.example/report.gz', checksum, sizeInBytes: compressed.length } }], links: {} }) };
    if (address === 'https://signed.example/report.gz') return { ok: true, arrayBuffer: async () => compressed.buffer.slice(compressed.byteOffset, compressed.byteOffset + compressed.byteLength) };
    throw new Error(`Unexpected request: ${address}`);
  };
  const queryImpl = async (text, params = []) => {
    if (/select instance_id/i.test(text)) return [];
    writes.push({ text, params });
    return [];
  };
  const result = await syncAppleAnalytics({
    fetchImpl,
    queryImpl,
    now: new Date('2026-08-14T12:00:00Z'),
    env: {
      APPSTORE_CONNECT_ISSUER_ID: 'issuer', APPSTORE_CONNECT_KEY_ID: 'key', APPSTORE_CONNECT_PRIVATE_KEY: testPrivateKey,
      APPSTORE_APP_ID: '6772513569', DATABASE_URL: 'postgresql://test.invalid/foldiq',
    },
  });
  assert.equal(result.importedInstances, 1);
  assert.equal(result.importedRows, 1);
  assert.equal(writes.length, 2);
  assert.equal(JSON.parse(writes[0].params[0])[0].metrics.counts, 2);
  assert.equal(writes[1].params[0], 'instance-1');
});

test('scheduled sync endpoint requires the private cron bearer token', async () => {
  const handler = createAppleMetricsSyncHandler({ env: { CRON_SECRET: 'private-cron-secret' }, fetchImpl: async () => { throw new Error('should not fetch'); } });
  const res = response();
  await handler({ method: 'GET', headers: {} }, res);
  assert.equal(res.statusCode, 401);
});
