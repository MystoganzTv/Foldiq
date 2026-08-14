import Stripe from 'stripe';
import { isOwnerRequest } from '../lib/owner-auth.js';
import { aggregateTelemetry } from '../lib/telemetry.js';
import { aggregateAppleRows } from '../lib/apple-analytics.js';
import { databaseConfigured, queryDatabase } from '../lib/database.js';

const REPOSITORY = 'MystoganzTv/Foldiq';
const OWNER_EMAILS = new Set((process.env.OWNER_EMAILS || 'enrique.padron853@gmail.com,enriquespangberg@gmail.com')
  .split(',').map(value => value.trim().toLowerCase()).filter(Boolean));
const DOWNLOAD_TRACKING_STARTED_AT = '2026-08-14T00:00:00.000Z';
const APPLE_AUDITED_SNAPSHOT = {
  period: 'May 15–Aug 12, 2026',
  capturedAt: '2026-08-13T04:00:00.000Z',
  downloads: 6,
  redownloads: 1,
  updates: 3,
  impressions: 274,
  pageViews: 40,
  conversionRate: 3.98,
  salesUSD: 36,
  proceedsUSD: 23,
  proceedsBySource: [
    { source: 'App Store Browse', usd: 11 },
    { source: 'App Store Search', usd: 4 },
    { source: 'App Referrer', usd: 4 },
    { source: 'Web Referrer', usd: 4 },
  ],
  proceedsByTerritory: [
    { territory: 'United States', usd: 7 },
    { territory: 'France', usd: 4 },
    { territory: 'Germany', usd: 4 },
    { territory: 'United Kingdom', usd: 4 },
  ],
};

function utcDay(unixSeconds) {
  return new Date(unixSeconds * 1000).toISOString().slice(0, 10);
}

function paymentEmail(item) {
  const charge = typeof item.latest_charge === 'object' ? item.latest_charge : null;
  return String(item.receipt_email || charge?.billing_details?.email || '').toLowerCase();
}

async function stripeMetrics(stripe) {
  const payments = [];
  let startingAfter;
  do {
    const page = await stripe.paymentIntents.list({
      limit: 100,
      ...(startingAfter ? { starting_after: startingAfter } : {}),
      expand: ['data.latest_charge.balance_transaction'],
    });
    payments.push(...page.data.filter(item => item.status === 'succeeded'));
    startingAfter = page.has_more ? page.data.at(-1)?.id : undefined;
  } while (startingAfter && payments.length < 1000);
  const paid = payments.filter(item => !item.metadata?.platform || item.metadata.platform === 'windows');
  const external = paid.filter(item => !OWNER_EMAILS.has(paymentEmail(item)));
  const explicitWindows = external.filter(item => item.metadata?.platform === 'windows');
  const legacyUnlabeled = external.filter(item => !item.metadata?.platform);
  const downloaded = paid.filter(item => item.metadata?.platform === 'windows' && Number.parseInt(item.metadata?.foldiq_download_count, 10) > 0);
  const externalDownloaded = explicitWindows.filter(item => Number.parseInt(item.metadata?.foldiq_download_count, 10) > 0);
  const nowSeconds = Math.floor(Date.now() / 1000);
  const external7d = external.filter(item => item.created >= nowSeconds - 7 * 86400);
  const external30d = external.filter(item => item.created >= nowSeconds - 30 * 86400);
  const trackingStartSeconds = Date.parse(DOWNLOAD_TRACKING_STARTED_AT) / 1000;
  const trackingEligible = explicitWindows.filter(item => item.created >= trackingStartSeconds);
  const dailyMap = new Map();
  const countryMap = new Map();
  let externalFeesCents = 0;
  let externalNetCents = 0;
  let hasNetData = true;
  let refundedCents = 0;
  let refundedPurchases = 0;
  for (const item of external) {
    const charge = typeof item.latest_charge === 'object' ? item.latest_charge : null;
    const balance = charge && typeof charge.balance_transaction === 'object' ? charge.balance_transaction : null;
    const amount = item.amount_received || item.amount || 0;
    const day = utcDay(item.created);
    const daily = dailyMap.get(day) || { date: day, purchases: 0, grossCents: 0, netCents: 0 };
    daily.purchases += 1;
    daily.grossCents += amount;
    if (balance) {
      daily.netCents += balance.net || 0;
      externalFeesCents += balance.fee || 0;
      externalNetCents += balance.net || 0;
    } else {
      hasNetData = false;
    }
    dailyMap.set(day, daily);
    const country = charge?.billing_details?.address?.country || 'Unknown';
    countryMap.set(country, (countryMap.get(country) || 0) + 1);
    if ((charge?.amount_refunded || 0) > 0) {
      refundedPurchases += 1;
      refundedCents += charge.amount_refunded;
    }
  }
  const recentPurchases = external.slice(0, 10).map(item => {
    const charge = typeof item.latest_charge === 'object' ? item.latest_charge : null;
    const balance = charge && typeof charge.balance_transaction === 'object' ? charge.balance_transaction : null;
    return {
      date: new Date(item.created * 1000).toISOString(),
      country: charge?.billing_details?.address?.country || 'Unknown',
      grossCents: item.amount_received || item.amount || 0,
      netCents: balance?.net ?? null,
      downloadCount: Number.parseInt(item.metadata?.foldiq_download_count, 10) || 0,
    };
  });
  return {
    configured: true,
    purchases: paid.length,
    externalPurchases: external.length,
    externalCustomers: external.length,
    verifiedWindowsPurchases: explicitWindows.length,
    legacyDirectMacPurchases: legacyUnlabeled.length,
    grossCents: paid.reduce((sum, item) => sum + (item.amount_received || item.amount || 0), 0),
    externalGrossCents: external.reduce((sum, item) => sum + (item.amount_received || item.amount || 0), 0),
    externalFeesCents: hasNetData ? externalFeesCents : null,
    externalNetCents: hasNetData ? externalNetCents : null,
    externalCustomers7d: external7d.length,
    externalCustomers30d: external30d.length,
    refundedPurchases,
    refundedCents,
    buyerDownloads: downloaded.length,
    externalBuyerDownloads: externalDownloaded.length,
    trackedDownloadRequests: downloaded.reduce((sum, item) => sum + (Number.parseInt(item.metadata?.foldiq_download_count, 10) || 0), 0),
    trackingEligibleCustomers: trackingEligible.length,
    downloadConversionRate: trackingEligible.length
      ? Math.round((externalDownloaded.filter(item => item.created >= trackingStartSeconds).length / trackingEligible.length) * 1000) / 10
      : null,
    downloadTrackingSince: DOWNLOAD_TRACKING_STARTED_AT,
    daily: [...dailyMap.values()].sort((a, b) => a.date.localeCompare(b.date)),
    countries: [...countryMap.entries()].map(([country, customers]) => ({ country, customers })).sort((a, b) => b.customers - a.customers),
    recentPurchases,
    currency: paid[0]?.currency || 'usd',
  };
}

async function githubMetrics(fetchImpl) {
  const token = process.env.GITHUB_RELEASE_TOKEN;
  if (!token) return { configured: false };
  const response = await fetchImpl(`https://api.github.com/repos/${REPOSITORY}/releases?per_page=30`, {
    headers: { Accept: 'application/vnd.github+json', Authorization: `Bearer ${token}`, 'X-GitHub-Api-Version': '2022-11-28', 'User-Agent': 'Foldiq-owner-dashboard' },
  });
  if (!response.ok) throw new Error(`GitHub returned ${response.status}`);
  const releases = await response.json();
  const assets = releases.flatMap(release => (release.assets || []).map(asset => ({ name: asset.name, downloads: asset.download_count, tag: release.tag_name, publishedAt: release.published_at })));
  const installers = assets.filter(asset => /\.exe$/i.test(asset.name));
  return {
    configured: true,
    current: installers[0] || null,
    installerDownloads: installers.reduce((sum, asset) => sum + asset.downloads, 0),
    releases: installers.slice(0, 10),
  };
}

async function telemetryMetrics(queryImpl) {
  if (!databaseConfigured()) return { configured: false };
  const since = new Date(Date.now() - 30 * 86400000).toISOString();
  const rows = await queryImpl(
    'select install_hash, event_name, platform, success from product_events where created_at >= $1::timestamptz order by created_at desc limit 10000',
    [since],
  );
  return { configured: true, periodDays: 30, ...aggregateTelemetry(rows) };
}

async function appleMetrics(queryImpl) {
  if (!databaseConfigured()) return { configured: false, auditedSnapshot: APPLE_AUDITED_SNAPSHOT };
  const rows = await queryImpl('select report_name, event_date::text, dimensions, metrics, processing_date::text from apple_analytics_rows order by event_date asc limit 10000');
  if (!rows.length) return { configured: true, awaitingData: true, auditedSnapshot: APPLE_AUDITED_SNAPSHOT };
  return { configured: true, live: true, auditedSnapshot: aggregateAppleRows(rows) };
}

export function createOwnerMetricsHandler({ stripeClient, fetchImpl = globalThis.fetch, queryImpl = queryDatabase } = {}) {
  return async function ownerMetricsHandler(req, res) {
    res.setHeader('Cache-Control', 'private, no-store');
    if (req.method !== 'GET') return res.status(405).json({ error: 'Method not allowed' });
    if (!isOwnerRequest(req)) return res.status(401).json({ error: 'Sign in required' });
    const stripe = stripeClient || (process.env.STRIPE_SECRET_KEY ? new Stripe(process.env.STRIPE_SECRET_KEY) : null);
    const settled = await Promise.allSettled([
      stripe ? stripeMetrics(stripe) : Promise.resolve({ configured: false }),
      githubMetrics(fetchImpl),
      telemetryMetrics(queryImpl),
      appleMetrics(queryImpl),
    ]);
    const pick = (index, source) => settled[index].status === 'fulfilled'
      ? settled[index].value
      : { configured: true, error: `${source} is temporarily unavailable` };
    return res.status(200).json({
      generatedAt: new Date().toISOString(),
      windows: pick(0, 'Stripe'),
      downloads: pick(1, 'GitHub'),
      product: pick(2, 'Product metrics'),
      apple: pick(3, 'Apple metrics'),
      website: {
        configured: true,
        provider: 'Vercel Web Analytics',
        snapshot: {
          period: 'Aug 6–12, 2026',
          visitors: 3,
          pageViews: 6,
          bounceRate: 67,
          referrers: [{ label: 'chatgpt.com', visitors: 1 }, { label: 'vercel.com', visitors: 1 }],
          countries: [{ label: 'India', visitors: 1 }, { label: 'Saudi Arabia', visitors: 1 }, { label: 'United States', visitors: 1 }],
          devices: [{ label: 'Desktop', share: 67 }, { label: 'Mobile', share: 33 }],
        },
        note: 'Vercel dashboard is the source of truth for current cookie-free visitors and page views.',
      },
    });
  };
}

export default createOwnerMetricsHandler();
