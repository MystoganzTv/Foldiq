import Stripe from 'stripe';
import { isOwnerRequest } from '../lib/owner-auth.js';
import { aggregateTelemetry } from '../lib/telemetry.js';

const REPOSITORY = 'MystoganzTv/Foldiq';
const OWNER_EMAILS = new Set((process.env.OWNER_EMAILS || 'enrique.padron853@gmail.com,enriquespangberg@gmail.com')
  .split(',').map(value => value.trim().toLowerCase()).filter(Boolean));

async function stripeMetrics(stripe) {
  const payments = [];
  let startingAfter;
  do {
    const page = await stripe.paymentIntents.list({
      limit: 100,
      ...(startingAfter ? { starting_after: startingAfter } : {}),
      expand: ['data.latest_charge'],
    });
    payments.push(...page.data.filter(item => item.status === 'succeeded'));
    startingAfter = page.has_more ? page.data.at(-1)?.id : undefined;
  } while (startingAfter && payments.length < 1000);
  const paid = payments.filter(item => !item.metadata?.platform || item.metadata.platform === 'windows');
  const external = paid.filter(item => {
    const charge = typeof item.latest_charge === 'object' ? item.latest_charge : null;
    const email = item.receipt_email || charge?.billing_details?.email || '';
    return !OWNER_EMAILS.has(String(email).toLowerCase());
  });
  return {
    configured: true,
    purchases: paid.length,
    externalCustomers: external.length,
    grossCents: paid.reduce((sum, item) => sum + (item.amount_received || item.amount || 0), 0),
    externalGrossCents: external.reduce((sum, item) => sum + (item.amount_received || item.amount || 0), 0),
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

async function telemetryMetrics(fetchImpl) {
  const baseURL = process.env.SUPABASE_URL;
  const secret = process.env.SUPABASE_SECRET_KEY;
  if (!baseURL || !secret) return { configured: false };
  const authHeaders = {
    apikey: secret,
    ...(secret.startsWith('eyJ') ? { Authorization: `Bearer ${secret}` } : {}),
  };
  const since = new Date(Date.now() - 30 * 86400000).toISOString();
  const response = await fetchImpl(`${baseURL}/rest/v1/product_events?select=install_hash,event_name,platform,success&created_at=gte.${encodeURIComponent(since)}&limit=10000`, {
    headers: authHeaders,
  });
  if (!response.ok) throw new Error(`Metrics storage returned ${response.status}`);
  return { configured: true, periodDays: 30, ...aggregateTelemetry(await response.json()) };
}

export function createOwnerMetricsHandler({ stripeClient, fetchImpl = globalThis.fetch } = {}) {
  return async function ownerMetricsHandler(req, res) {
    res.setHeader('Cache-Control', 'private, no-store');
    if (req.method !== 'GET') return res.status(405).json({ error: 'Method not allowed' });
    if (!isOwnerRequest(req)) return res.status(401).json({ error: 'Sign in required' });
    const stripe = stripeClient || (process.env.STRIPE_SECRET_KEY ? new Stripe(process.env.STRIPE_SECRET_KEY) : null);
    const settled = await Promise.allSettled([
      stripe ? stripeMetrics(stripe) : Promise.resolve({ configured: false }),
      githubMetrics(fetchImpl),
      telemetryMetrics(fetchImpl),
    ]);
    const pick = (index, source) => settled[index].status === 'fulfilled'
      ? settled[index].value
      : { configured: true, error: `${source} is temporarily unavailable` };
    return res.status(200).json({
      generatedAt: new Date().toISOString(),
      windows: pick(0, 'Stripe'),
      downloads: pick(1, 'GitHub'),
      product: pick(2, 'Product metrics'),
      apple: {
        configured: false,
        auditedSnapshot: { period: 'May 15–Aug 12, 2026', downloads: 6, redownloads: 1, updates: 3, impressions: 274, pageViews: 40, conversionRate: 3.98, salesUSD: 36, proceedsUSD: 23 },
      },
      website: { configured: true, provider: 'Vercel Web Analytics', note: 'Open Vercel for live cookie-free visitors and page views.' },
    });
  };
}

export default createOwnerMetricsHandler();
