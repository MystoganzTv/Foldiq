import { normalizeTelemetry } from '../lib/telemetry.js';

export function createTelemetryHandler({ fetchImpl = globalThis.fetch } = {}) {
  return async function telemetryHandler(req, res) {
    res.setHeader('Cache-Control', 'no-store');
    if (req.method !== 'POST') return res.status(405).json({ error: 'Method not allowed' });
    const contentLength = Number(req.headers?.['content-length'] || 0);
    if (contentLength > 4096) return res.status(413).json({ error: 'Payload too large' });
    const event = normalizeTelemetry(req.body);
    if (!event) return res.status(400).json({ error: 'Invalid anonymous event' });
    const baseURL = process.env.SUPABASE_URL;
    const secret = process.env.SUPABASE_SECRET_KEY;
    if (!baseURL || !secret) return res.status(503).json({ error: 'Anonymous metrics are not configured' });
    try {
      const authHeaders = {
        apikey: secret,
        ...(secret.startsWith('eyJ') ? { Authorization: `Bearer ${secret}` } : {}),
      };
      const response = await fetchImpl(`${baseURL}/rest/v1/product_events`, {
        method: 'POST',
        headers: {
          ...authHeaders,
          'Content-Type': 'application/json',
          Prefer: 'return=minimal,resolution=ignore-duplicates',
        },
        body: JSON.stringify(event),
      });
      if (!response.ok) throw new Error(`Metrics storage returned ${response.status}`);
      return res.status(202).json({ ok: true });
    } catch (error) {
      console.error('Anonymous telemetry delivery failed:', error.message);
      return res.status(503).json({ error: 'Anonymous metrics are temporarily unavailable' });
    }
  };
}

export default createTelemetryHandler();
