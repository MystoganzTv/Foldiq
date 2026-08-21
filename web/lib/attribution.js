// Purchase-channel attribution for direct (Stripe) sales.
//
// Apple already reports where an App Store sale came from. Stripe reports
// nothing, so a launch on Product Hunt or Reddit is unmeasurable without this.
// The landing page captures how a visitor arrived and sends it with the
// checkout request; the values are recorded on the Stripe session so the sale
// notification and the owner dashboard can credit a channel.
//
// PRIVACY: only coarse labels survive — campaign tags and the referring host.
// Never a full URL, a query string, a path, or anything identifying a visitor.
// Values are aggressively narrowed to [a-z0-9._-] so a crafted request cannot
// smuggle arbitrary text into Stripe metadata or into the owner's inbox.

const MAX_VALUE_LENGTH = 60;
const FIELDS = ['source', 'medium', 'campaign', 'referrer'];
const UNKNOWN_CHANNEL = 'unknown';
const DIRECT_CHANNEL = 'direct';

export function sanitizeAttributionValue(value) {
  if (typeof value !== 'string' && typeof value !== 'number') return '';
  return String(value)
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9._-]+/g, '-')
    .replace(/^[-.]+|[-.]+$/g, '')
    .slice(0, MAX_VALUE_LENGTH);
}

export function normalizeAttribution(input) {
  if (!input || typeof input !== 'object' || Array.isArray(input)) return {};
  const normalized = {};
  for (const field of FIELDS) {
    const value = sanitizeAttributionValue(input[field]);
    if (value) normalized[field] = value;
  }
  return normalized;
}

/// The single label the dashboard groups by. A campaign tag wins over the
/// referring host because it is the deliberate one; with neither, the visitor
/// typed the address or arrived without a referrer, which is a real answer.
export function attributionChannel(input) {
  const normalized = normalizeAttribution(input);
  return normalized.source || normalized.referrer || DIRECT_CHANNEL;
}

/// Stripe metadata: at most 50 keys, keys ≤40 chars, values ≤500 chars. Every
/// key below is well inside those limits.
export function attributionMetadata(input) {
  const normalized = normalizeAttribution(input);
  const metadata = { attribution_channel: attributionChannel(normalized) };
  for (const [field, value] of Object.entries(normalized)) {
    metadata[`attribution_${field}`] = value;
  }
  return metadata;
}

/// Reads the channel back off a payment. Purchases made before attribution
/// shipped carry no marker at all, and reporting those as "direct" would
/// silently inflate it — they are genuinely unknown.
export function channelFromMetadata(metadata) {
  if (!metadata || typeof metadata !== 'object') return UNKNOWN_CHANNEL;
  const recorded = sanitizeAttributionValue(metadata.attribution_channel);
  if (recorded) return recorded;
  const legacy = attributionChannel({
    source: metadata.attribution_source,
    referrer: metadata.attribution_referrer,
  });
  return legacy === DIRECT_CHANNEL ? UNKNOWN_CHANNEL : legacy;
}
