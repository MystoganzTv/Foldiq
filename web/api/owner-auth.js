import { ownerCookie, safeEqual } from '../lib/owner-auth.js';

export default function handler(req, res) {
  res.setHeader('Cache-Control', 'private, no-store');
  if (req.method !== 'POST') return res.status(405).json({ error: 'Method not allowed' });
  const configured = process.env.OWNER_DASHBOARD_TOKEN;
  if (!configured || !safeEqual(req.body?.token, configured)) {
    return res.status(401).json({ error: 'Incorrect access code' });
  }
  res.setHeader('Set-Cookie', ownerCookie(configured));
  return res.status(200).json({ ok: true });
}
