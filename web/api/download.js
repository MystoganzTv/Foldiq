import Stripe from 'stripe';

const REPOSITORY = 'MystoganzTv/Foldiq';
const ASSET_NAME = 'Foldiq-Setup.exe';
const GITHUB_API = 'https://api.github.com';

function send(res, status, message) {
  res.status(status).send(message);
}

function githubHeaders(token, accept = 'application/vnd.github+json') {
  return {
    Accept: accept,
    Authorization: `Bearer ${token}`,
    'X-GitHub-Api-Version': '2022-11-28',
    'User-Agent': 'Foldiq-private-downloads',
  };
}

function parseDownloadCount(value) {
  const count = Number.parseInt(value, 10);
  return Number.isSafeInteger(count) && count >= 0 ? count : 0;
}

export async function recordPurchaseDownload(stripe, session, now = new Date()) {
  const paymentIntent = session?.payment_intent;
  if (!paymentIntent || typeof paymentIntent !== 'object' || !paymentIntent.id) return false;
  const timestamp = now.toISOString();
  const metadata = paymentIntent.metadata || {};
  await stripe.paymentIntents.update(paymentIntent.id, {
    metadata: {
      ...metadata,
      foldiq_download_count: String(parseDownloadCount(metadata.foldiq_download_count) + 1),
      foldiq_first_download_at: metadata.foldiq_first_download_at || timestamp,
      foldiq_last_download_at: timestamp,
    },
  });
  return true;
}

export function isAllowedGitHubRedirect(value) {
  try {
    const url = new URL(value);
    return url.protocol === 'https:' && (
      url.hostname === 'github.com' ||
      url.hostname.endsWith('.githubusercontent.com')
    );
  } catch {
    return false;
  }
}

export function createDownloadHandler({
  stripeClient,
  fetchImpl = globalThis.fetch,
  githubToken = process.env.GITHUB_RELEASE_TOKEN,
} = {}) {
  const stripe = stripeClient || new Stripe(process.env.STRIPE_SECRET_KEY);

  return async function downloadHandler(req, res) {
    res.setHeader('Cache-Control', 'private, no-store, max-age=0');
    res.setHeader('Referrer-Policy', 'no-referrer');

    if (req.method !== 'GET') {
      res.setHeader('Allow', 'GET');
      send(res, 405, 'Method not allowed');
      return;
    }

    const sessionId = Array.isArray(req.query?.session_id)
      ? req.query.session_id[0]
      : req.query?.session_id;

    if (typeof sessionId !== 'string' || !/^cs_(?:live|test)_[A-Za-z0-9]+$/.test(sessionId)) {
      send(res, 400, 'A valid checkout session is required');
      return;
    }

    if (!githubToken) {
      console.error('GITHUB_RELEASE_TOKEN is not configured');
      send(res, 503, 'Download service is temporarily unavailable');
      return;
    }

    let session;
    try {
      session = await stripe.checkout.sessions.retrieve(sessionId, {
        expand: ['payment_intent'],
      });
    } catch (error) {
      console.error('Checkout session validation failed:', error.message);
      send(res, 403, 'Purchase could not be verified');
      return;
    }

    if (
      session.id !== sessionId ||
      session.payment_status !== 'paid' ||
      session.status !== 'complete' ||
      session.metadata?.platform !== 'windows'
    ) {
      send(res, 403, 'A completed Windows purchase is required');
      return;
    }

    try {
      const releaseResponse = await fetchImpl(
        `${GITHUB_API}/repos/${REPOSITORY}/releases/latest`,
        { headers: githubHeaders(githubToken) }
      );
      if (!releaseResponse.ok) throw new Error(`GitHub release lookup returned ${releaseResponse.status}`);

      const release = await releaseResponse.json();
      const asset = release.assets?.find(item => item.name === ASSET_NAME);
      if (!asset?.url) throw new Error(`${ASSET_NAME} is missing from the latest release`);

      const assetResponse = await fetchImpl(asset.url, {
        headers: githubHeaders(githubToken, 'application/octet-stream'),
        redirect: 'manual',
      });
      const location = assetResponse.headers.get('location');
      if (![301, 302, 303, 307, 308].includes(assetResponse.status) || !isAllowedGitHubRedirect(location)) {
        throw new Error(`GitHub asset request returned an unsafe response (${assetResponse.status})`);
      }

      try {
        await recordPurchaseDownload(stripe, session);
      } catch (error) {
        // Fulfillment must still work if Stripe has a temporary metadata error.
        console.error('Purchase download tracking failed:', error.message);
      }

      res.status(302);
      res.setHeader('Location', location);
      res.send('Redirecting to your private Foldiq download');
    } catch (error) {
      console.error('Private release download failed:', error.message);
      send(res, 502, 'The installer is temporarily unavailable');
    }
  };
}

export default createDownloadHandler();
