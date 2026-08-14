import { syncAppleAnalytics } from '../lib/apple-analytics.js';
import { deleteExpiredProductEvents, queryDatabase } from '../lib/database.js';

function bearer(req) {
  return String(req.headers?.authorization || req.headers?.Authorization || '');
}

export function createAppleMetricsSyncHandler({ fetchImpl = globalThis.fetch, queryImpl = queryDatabase, env = process.env } = {}) {
  return async function appleMetricsSyncHandler(req, res) {
    res.setHeader('Cache-Control', 'no-store');
    if (req.method !== 'GET') return res.status(405).json({ error: 'Method not allowed' });
    if (!env.CRON_SECRET || bearer(req) !== `Bearer ${env.CRON_SECRET}`) return res.status(401).json({ error: 'Unauthorized' });
    try {
      await deleteExpiredProductEvents(queryImpl);
      return res.status(200).json(await syncAppleAnalytics({ fetchImpl, queryImpl, env }));
    } catch (error) {
      console.error('Apple analytics sync failed:', error.message);
      return res.status(503).json({ error: 'Apple analytics sync failed' });
    }
  };
}

export default createAppleMetricsSyncHandler();
