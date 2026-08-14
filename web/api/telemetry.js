import { normalizeTelemetry } from '../lib/telemetry.js';
import { databaseConfigured, queryDatabase } from '../lib/database.js';

export function createTelemetryHandler({ queryImpl = queryDatabase, env = process.env } = {}) {
  return async function telemetryHandler(req, res) {
    res.setHeader('Cache-Control', 'no-store');
    if (req.method !== 'POST') return res.status(405).json({ error: 'Method not allowed' });
    const contentLength = Number(req.headers?.['content-length'] || 0);
    if (contentLength > 4096) return res.status(413).json({ error: 'Payload too large' });
    const event = normalizeTelemetry(req.body);
    if (!event) return res.status(400).json({ error: 'Invalid anonymous event' });
    if (!databaseConfigured(env)) return res.status(503).json({ error: 'Anonymous metrics are not configured' });
    try {
      await queryImpl(
        `insert into product_events
          (event_id, install_hash, event_name, platform, app_version, success, duration_bucket, item_count_bucket)
         values ($1::uuid, $2, $3, $4, $5, $6, $7, $8)
         on conflict (event_id) do nothing`,
        [event.event_id, event.install_hash, event.event_name, event.platform, event.app_version, event.success, event.duration_bucket, event.item_count_bucket],
      );
      return res.status(202).json({ ok: true });
    } catch (error) {
      console.error('Anonymous telemetry delivery failed:', error.message);
      return res.status(503).json({ error: 'Anonymous metrics are temporarily unavailable' });
    }
  };
}

export default createTelemetryHandler();
