// Vercel Serverless Function — creates a Stripe Checkout session.
// POST /api/create-checkout  body: { platform: "windows" }
//
// WINDOWS ONLY. The macOS build is distributed exclusively through the Mac App
// Store, where Apple signs and notarizes it. Selling the self-built .dmg here
// shipped an unsigned app that macOS Gatekeeper rejects with
// "Foldiq is damaged and cannot be opened" — so mac checkout is refused.
//
// Required env var (Vercel → Project → Settings → Environment Variables):
//   STRIPE_SECRET_KEY — sk_live_...

import Stripe from 'stripe';

const stripe = new Stripe(process.env.STRIPE_SECRET_KEY);

const SITE = 'https://foldiq.app';
const MAC_APP_STORE_URL = 'https://apps.apple.com/us/app/foldiq/id6772513569';

export default async function handler(req, res) {
  if (req.method !== 'POST') {
    res.status(405).json({ error: 'Method not allowed' });
    return;
  }

  try {
    const body = req.body || {};
    const platform = body.platform === 'windows' ? 'windows' : 'mac';

    // Never sell the Mac build through Stripe — send buyers to the App Store.
    if (platform !== 'windows') {
      res.status(200).json({ url: MAC_APP_STORE_URL, platform: 'mac' });
      return;
    }

    const session = await stripe.checkout.sessions.create({
      payment_method_types: ['card'],
      line_items: [
        {
          price_data: {
            currency: 'usd',
            product_data: {
              name: 'Foldiq for Windows',
              description: 'One-time purchase — lifetime license, all future updates included. Windows 10/11 64-bit.',
              images: [`${SITE}/icon.png`],
            },
            unit_amount: 499, // $4.99
          },
          quantity: 1,
        },
      ],
      mode: 'payment',
      success_url: `${SITE}/success.html?session_id={CHECKOUT_SESSION_ID}&platform=windows`,
      cancel_url: `${SITE}/`,
      metadata: { platform: 'windows' },
    });

    res.status(200).json({ url: session.url });
  } catch (err) {
    console.error('Stripe error:', err.message);
    res.status(500).json({ error: err.message });
  }
}
