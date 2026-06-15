// Vercel Serverless Function — creates a Stripe Checkout session.
// POST /api/create-checkout  body: { platform: "mac" | "windows" }
//
// Required env var (Vercel → Project → Settings → Environment Variables):
//   STRIPE_SECRET_KEY — sk_live_...

import Stripe from 'stripe';

const stripe = new Stripe(process.env.STRIPE_SECRET_KEY);

const SITE = 'https://foldiq.app';

export default async function handler(req, res) {
  if (req.method !== 'POST') {
    res.status(405).json({ error: 'Method not allowed' });
    return;
  }

  try {
    const body = req.body || {};
    const platform = body.platform === 'windows' ? 'windows' : 'mac';

    const productName = platform === 'windows' ? 'Foldiq for Windows' : 'Foldiq for Mac';
    const productDesc = platform === 'windows'
      ? 'One-time purchase — lifetime license, all future updates included. Windows 10/11 64-bit.'
      : 'One-time purchase — lifetime license, all future updates included. macOS 14 Sonoma or later.';

    const session = await stripe.checkout.sessions.create({
      payment_method_types: ['card'],
      line_items: [
        {
          price_data: {
            currency: 'usd',
            product_data: {
              name: productName,
              description: productDesc,
              images: [`${SITE}/icon.png`],
            },
            unit_amount: 499, // $4.99
          },
          quantity: 1,
        },
      ],
      mode: 'payment',
      success_url: `${SITE}/success.html?session_id={CHECKOUT_SESSION_ID}&platform=${platform}`,
      cancel_url: `${SITE}/`,
      metadata: { platform },
    });

    res.status(200).json({ url: session.url });
  } catch (err) {
    console.error('Stripe error:', err.message);
    res.status(500).json({ error: err.message });
  }
}
