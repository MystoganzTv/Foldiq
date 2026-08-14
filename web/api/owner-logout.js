import { clearedOwnerCookie } from '../lib/owner-auth.js';

export default function handler(req, res) {
  if (req.method !== 'POST') return res.status(405).json({ error: 'Method not allowed' });
  res.setHeader('Set-Cookie', clearedOwnerCookie());
  res.setHeader('Cache-Control', 'private, no-store');
  return res.status(200).json({ ok: true });
}
