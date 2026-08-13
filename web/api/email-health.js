import { Resend } from 'resend';

const FROM_EMAIL = 'Foldiq <receipts@foldiq.app>';

export function createEmailHealthHandler({ resendClient } = {}) {
  return async function emailHealthHandler(req, res) {
    if (req.method !== 'POST') return res.status(405).json({ error: 'Method not allowed' });
    const expected = process.env.EMAIL_HEALTH_SECRET;
    if (!expected || req.headers?.authorization !== `Bearer ${expected}`) {
      return res.status(401).json({ error: 'Unauthorized' });
    }

    const recipient = process.env.EMAIL_HEALTH_RECIPIENT;
    if (!recipient) return res.status(503).json({ error: 'Health recipient unavailable' });

    const client = resendClient || new Resend(process.env.RESEND_API_KEY);
    const result = await client.emails.send({
      from: FROM_EMAIL,
      to: recipient,
      replyTo: process.env.SUPPORT_REPLY_TO || recipient,
      subject: 'Foldiq receipt delivery check',
      html: '<p>The production sender <strong>receipts@foldiq.app</strong> is working.</p>',
    }, {
      headers: { 'Idempotency-Key': 'foldiq-receipt-health-v1' },
    });

    if (result?.error) return res.status(502).json({ error: result.error.message || 'Delivery failed' });
    return res.status(200).json({ ok: true, id: result?.data?.id || null });
  };
}

export default createEmailHealthHandler();
