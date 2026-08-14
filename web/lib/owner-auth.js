import { createHmac, timingSafeEqual } from 'node:crypto';

const COOKIE_NAME = 'foldiq_owner';

function safeEqual(left, right) {
  const a = Buffer.from(String(left || ''));
  const b = Buffer.from(String(right || ''));
  return a.length === b.length && timingSafeEqual(a, b);
}

export function ownerSessionValue(secret = process.env.OWNER_DASHBOARD_TOKEN) {
  if (!secret) return '';
  return createHmac('sha256', secret).update('foldiq-owner-session-v1').digest('hex');
}

export function isOwnerRequest(req, secret = process.env.OWNER_DASHBOARD_TOKEN) {
  if (!secret) return false;
  const authorization = req.headers?.authorization || '';
  if (authorization.startsWith('Bearer ') && safeEqual(authorization.slice(7), secret)) return true;
  const cookie = String(req.headers?.cookie || '')
    .split(';')
    .map(value => value.trim().split('='))
    .find(([name]) => name === COOKIE_NAME)?.[1];
  return safeEqual(cookie, ownerSessionValue(secret));
}

export function ownerCookie(secret = process.env.OWNER_DASHBOARD_TOKEN) {
  return `${COOKIE_NAME}=${ownerSessionValue(secret)}; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=43200`;
}

export function clearedOwnerCookie() {
  return `${COOKIE_NAME}=; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=0`;
}

export { COOKIE_NAME, safeEqual };
