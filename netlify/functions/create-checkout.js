const stripe = require('stripe')(process.env.STRIPE_SECRET_KEY);

exports.handler = async (event) => {
  const headers = {
    'Access-Control-Allow-Origin': 'https://foldiq.netlify.app',
    'Access-Control-Allow-Headers': 'Content-Type',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
  };

  if (event.httpMethod === 'OPTIONS') {
    return { statusCode: 200, headers, body: '' };
  }

  if (event.httpMethod !== 'POST') {
    return { statusCode: 405, headers, body: JSON.stringify({ error: 'Method not allowed' }) };
  }

  try {
    let body = {};
    try { body = JSON.parse(event.body || '{}'); } catch (_) {}
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
              images: ['https://foldiq.netlify.app/icon.png'],
            },
            unit_amount: 499, // $4.99
          },
          quantity: 1,
        },
      ],
      mode: 'payment',
      success_url: `https://foldiq.netlify.app/success.html?session_id={CHECKOUT_SESSION_ID}&platform=${platform}`,
      cancel_url: 'https://foldiq.netlify.app/',
      metadata: { platform },
    });

    return {
      statusCode: 200,
      headers,
      body: JSON.stringify({ url: session.url }),
    };
  } catch (err) {
    console.error('Stripe error:', err.message);
    return {
      statusCode: 500,
      headers,
      body: JSON.stringify({ error: err.message }),
    };
  }
};
