// Provider-agnostic license keys. No account, and no payment-provider secret.
//
// A key is `UC1.<tier>.<seats>.<flag>.<nonce>`:
//   tier: plus | pro | family
//   seats: 1 for Plus, 2 for Pro, 5 for Family (must match the tier)
//   flag: s (standard) or g (grandfathered lifetime Plus, for people who already use Uncloud)
//   nonce: 8–64 letters or digits
//
// POST /v1/licenses/verify checks that shape and returns the entitlement. It does not
// store the key. Replace this with signature checks before turning license limits on
// in the app (UncloudLicenseGating). While it is a stub, any well-formed key is accepted.
//
// POST /v1/webhooks/payments accepts a Lemon Squeezy-style or Paddle-style JSON body,
// does not check a signature, and does not issue or store a license.

import { json, logEvent, readJSON } from './http.js';

export const FREE_ITEM_CAP = 1000;

const TIERS = ['plus', 'pro', 'family'];
const SEATS = { plus: 1, pro: 2, family: 5 };

const PLUS_FEATURES = [
  'unlimitedExport',
  'automaticBackups',
  'allLayouts',
  'mapPlaceBrowse',
  'xmpSidecars',
];

const PRO_FEATURES = [
  ...PLUS_FEATURES,
  'verifiedICloudCleanup',
  'verifyBackup',
  'secondDestination',
  'emailSupport',
];

export function featuresFor(tier) {
  if (tier === 'plus') return [...PLUS_FEATURES];
  if (tier === 'pro' || tier === 'family') return [...PRO_FEATURES];
  return [];
}

// Trimmed key, or null when it is not a license this stub understands.
export function parseLicenseKey(raw) {
  if (typeof raw !== 'string') return null;
  const key = raw.trim();
  const parts = key.split('.');
  if (parts.length !== 5 || parts[0] !== 'UC1') return null;
  const tier = parts[1];
  if (!TIERS.includes(tier)) return null;
  const seatsText = parts[2];
  const seats = Number(seatsText);
  if (!Number.isInteger(seats) || String(seats) !== seatsText || seats !== SEATS[tier]) return null;
  const flag = parts[3];
  if (flag !== 's' && flag !== 'g') return null;
  if (flag === 'g' && tier !== 'plus') return null;
  const nonce = parts[4];
  if (!/^[A-Za-z0-9]{8,64}$/.test(nonce)) return null;
  return { key, tier, seats, grandfathered: flag === 'g' };
}

export function verifyLicenseKey(raw) {
  const parsed = parseLicenseKey(raw);
  if (!parsed) {
    return { valid: false, mode: 'stub', reason: 'unrecognized_key', accountRequired: false };
  }
  return {
    valid: true,
    mode: 'stub',
    tier: parsed.tier,
    seats: parsed.seats,
    grandfathered: parsed.grandfathered,
    features: featuresFor(parsed.tier),
    accountRequired: false,
  };
}

export async function verifyLicenseRequest(request) {
  const body = await readJSON(request);
  const result = verifyLicenseKey(body.key);
  logEvent({ evt: 'license_verify', result: result.valid ? 'valid' : 'invalid', mode: 'stub' });
  return json(result);
}

function tierFromText(value) {
  if (typeof value !== 'string') return null;
  const text = value.trim().toLowerCase();
  if (text === 'plus' || text === 'pro' || text === 'family') return text;
  if (text.includes('family')) return 'family';
  if (/\bpro\b/.test(text)) return 'pro';
  if (/\bplus\b/.test(text)) return 'plus';
  return null;
}

function firstTier(values) {
  for (const value of values) {
    const tier = tierFromText(value);
    if (tier) return tier;
  }
  return null;
}

function itemTier(item) {
  if (!item || typeof item !== 'object') return null;
  const price = item.price && typeof item.price === 'object' ? item.price : {};
  const custom = price.custom_data && typeof price.custom_data === 'object' ? price.custom_data : {};
  const product = item.product && typeof item.product === 'object' ? item.product : {};
  return firstTier([custom.tier, price.name, price.description, product.name, item.name]);
}

// Reads a tier from the few fields a checkout webhook uses for the product name.
// Does not scan the whole body, so an email address cannot be mistaken for a tier.
export function webhookTier(body) {
  const data = body.data && typeof body.data === 'object' && !Array.isArray(body.data) ? body.data : {};
  const attributes = data.attributes && typeof data.attributes === 'object' ? data.attributes : {};
  const firstItem = attributes.first_order_item && typeof attributes.first_order_item === 'object'
    ? attributes.first_order_item
    : {};
  const custom = data.custom_data && typeof data.custom_data === 'object' ? data.custom_data : {};
  const items = Array.isArray(data.items) ? data.items : [];
  return firstTier([
    custom.tier,
    attributes.product_name,
    attributes.variant_name,
    firstItem.product_name,
    firstItem.variant_name,
    ...items.map(itemTier),
  ]);
}

export function describeWebhook(body) {
  let provider = 'unknown';
  let event = null;
  if (body.meta && typeof body.meta === 'object' && typeof body.meta.event_name === 'string') {
    provider = 'lemonsqueezy';
    event = body.meta.event_name;
  } else if (typeof body.event_type === 'string') {
    provider = 'paddle';
    event = body.event_type;
  } else if (typeof body.type === 'string') {
    event = body.type;
  }
  if (typeof event === 'string' && event.length > 80) event = event.slice(0, 80);
  return { provider, event, tier: webhookTier(body) };
}

export async function paymentWebhookRequest(request) {
  const body = await readJSON(request);
  const described = describeWebhook(body);
  logEvent({
    evt: 'payment_webhook',
    provider: described.provider,
    event: described.event,
    tier: described.tier,
    result: 'stub',
  });
  return json({
    received: true,
    fulfilled: false,
    mode: 'stub',
    provider: described.provider,
    event: described.event,
    tier: described.tier,
    signatureChecked: false,
    accountRequired: false,
    reason: 'No license is issued until a payment provider is connected. This stub stores nothing.',
  });
}
