// Vercel Serverless Function — creates a Stripe Checkout session.
// POST /api/create-checkout  body: { platform: "windows" | "mac" }
//
// Both desktop apps are sold here. The Mac build sold on the web is signed with
// Developer ID and notarized by Apple (see notarize.sh) — an unsigned .dmg is
// rejected by Gatekeeper as "damaged", which is what went wrong before. The Mac
// App Store keeps selling its own copy at the price set in App Store Connect.
//
// Required env vars (Vercel → Project → Settings → Environment Variables):
//   STRIPE_SECRET_KEY    — sk_live_...
//   STRIPE_AUTOMATIC_TAX — "true" once Stripe Tax is set up (see lib/commerce.js)

import Stripe from 'stripe';
import { WEB_PRODUCTS, automaticTaxEnabled } from '../lib/commerce.js';
import { attributionMetadata } from '../lib/attribution.js';

const stripe = new Stripe(process.env.STRIPE_SECRET_KEY);

const SITE = 'https://foldiq.app';

export function checkoutSessionParams(platform, attribution, env = process.env) {
  const product = WEB_PRODUCTS[platform];
  if (!product) return null;
  const taxed = automaticTaxEnabled(env);

  return {
    payment_method_types: ['card'],
    line_items: [
      {
        price_data: {
          currency: 'usd',
          product_data: {
            name: product.name,
            description: product.description,
            images: [`${SITE}/icon.png`],
          },
          unit_amount: product.priceCents,
          // The advertised price is what the customer pays; any tax is inside it.
          ...(taxed ? { tax_behavior: 'inclusive' } : {}),
        },
        quantity: 1,
      },
    ],
    automatic_tax: { enabled: taxed },
    mode: 'payment',
    success_url: `${SITE}/success.html?session_id={CHECKOUT_SESSION_ID}&platform=${platform}`,
    cancel_url: `${SITE}/`,
    // Records which platform and channel produced the sale. Sanitized
    // server-side, so a crafted request cannot put arbitrary text into Stripe.
    metadata: { platform, ...attributionMetadata(attribution) },
  };
}

export default async function handler(req, res) {
  if (req.method !== 'POST') {
    res.status(405).json({ error: 'Method not allowed' });
    return;
  }

  try {
    const body = req.body || {};
    const params = checkoutSessionParams(body.platform, body.attribution);
    if (!params) {
      res.status(400).json({ error: 'Choose Mac or Windows.' });
      return;
    }

    const session = await stripe.checkout.sessions.create(params);
    res.status(200).json({ url: session.url });
  } catch (err) {
    console.error('Stripe error:', err.message);
    res.status(500).json({ error: err.message });
  }
}
