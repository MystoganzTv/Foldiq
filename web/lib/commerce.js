// One web price for Mac and Windows. Apple sets the Mac App Store price on its own.
export const WEB_PRICE_CENTS = 1999;
export const WINDOWS_PRICE_CENTS = WEB_PRICE_CENTS;
export const MAC_PRICE_CENTS = WEB_PRICE_CENTS;

// What each platform sells on the web, and the installer its buyers download
// from the latest GitHub release.
export const WEB_PRODUCTS = {
  windows: {
    name: 'Foldiq for Windows',
    description: 'One-time purchase for Windows 10 and 11 (64-bit).',
    priceCents: WINDOWS_PRICE_CENTS,
    installer: 'Foldiq-Setup.exe',
  },
  mac: {
    name: 'Foldiq for Mac',
    description: 'One-time purchase for macOS 14 Sonoma or later (Apple Silicon and Intel).',
    priceCents: MAC_PRICE_CENTS,
    installer: 'Foldiq.dmg',
  },
};

// Stripe Tax works out and collects VAT / sales tax at checkout. It has to be
// activated in the Stripe dashboard first (business address, tax registrations,
// default product tax code "Downloadable software"): a checkout that asks for
// automatic tax before that fails. Turn it on in Vercel with
// STRIPE_AUTOMATIC_TAX=true once the dashboard side is done.
export function automaticTaxEnabled(env = process.env) {
  return env.STRIPE_AUTOMATIC_TAX === 'true';
}

// Kept for the owner dashboard, which reports whether tax is being collected.
export const WINDOWS_AUTOMATIC_TAX_ENABLED = automaticTaxEnabled();
