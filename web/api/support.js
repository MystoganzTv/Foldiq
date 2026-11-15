import { Resend } from 'resend';

const OWNER_EMAIL = 'enrique.padron853@gmail.com';
const FROM_EMAIL = process.env.SUPPORT_FROM_EMAIL || 'Foldiq Support <support@foldiq.app>';
const recentRequests = new Map();

const SUBJECT_BY_SOURCE = {
  'foldiq-windows': 'Windows diagnostic',
  'foldiq-windows-review': 'Windows review',
};

function text(value, maxLength) {
  return typeof value === 'string' ? value.trim().slice(0, maxLength) : '';
}

function validEmail(value) {
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value) && value.length <= 254;
}

function escapeHTML(value) {
  return String(value)
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#039;');
}

export function createSupportHandler({ resendClient, ownerEmail = OWNER_EMAIL } = {}) {
  return async function supportHandler(req, res) {
    if (req.method !== 'POST') return res.status(405).json({ error: 'Method not allowed' });

    const ip = text(req.headers?.['x-forwarded-for']?.split(',')[0], 80) || 'unknown';
    const now = Date.now();
    const attempts = (recentRequests.get(ip) || []).filter(time => now - time < 60 * 60 * 1000);
    if (attempts.length >= 4) return res.status(429).json({ error: 'Please wait before sending another message.' });

    const body = req.body && typeof req.body === 'object' ? req.body : {};
    if (text(body.website, 200)) return res.status(200).json({ ok: true });

    const name = text(body.name, 100);
    const email = text(body.email, 254);
    const message = text(body.message, 12_000);
    const source = text(body.source, 40) || 'website';
    if (!name || !validEmail(email) || message.length < 5) {
      return res.status(400).json({ error: 'Please enter your name, email, and message.' });
    }

    const client = resendClient || new Resend(process.env.RESEND_API_KEY);
    try {
      const result = await client.emails.send({
        from: FROM_EMAIL,
        to: ownerEmail,
        replyTo: email,
        subject: `Foldiq support — ${SUBJECT_BY_SOURCE[source] || 'website message'}`,
        text: `Name: ${name}\nEmail: ${email}\nSource: ${source}\n\n${message}`,
        html: `<h2>Foldiq support</h2><p><strong>Name:</strong> ${escapeHTML(name)}<br><strong>Email:</strong> ${escapeHTML(email)}<br><strong>Source:</strong> ${escapeHTML(source)}</p><pre style="white-space:pre-wrap;font:14px/1.5 system-ui">${escapeHTML(message)}</pre>`,
      });
      if (result?.error) throw new Error(result.error.message || 'Email provider rejected the message');
    } catch (error) {
      console.error('Support form delivery failed:', error.message);
      return res.status(502).json({ error: 'Message delivery is temporarily unavailable.' });
    }
    recentRequests.set(ip, [...attempts, now]);
    return res.status(200).json({ ok: true });
  };
}

export default createSupportHandler();
export { escapeHTML, validEmail };
