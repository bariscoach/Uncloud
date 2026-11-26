// Checkout URLs for the pricing page. Environment variables win over checkout.config.json.
// Empty or non-https values become null so the page can show a placeholder.
// Stripe test payment links (buy.stripe.com/test_*) are used only on Preview (and local
// development). Production builds never return them, even if they are in the config file.

export function httpsCheckoutURL(value) {
  if (typeof value !== 'string') return null;
  const trimmed = value.trim();
  if (trimmed === '') return null;
  let url;
  try {
    url = new URL(trimmed);
  } catch {
    return null;
  }
  if (url.protocol !== 'https:') return null;
  if (!url.host) return null;
  return url.href;
}

export function isStripeTestCheckoutURL(value) {
  const href = typeof value === 'string' && value.includes('://') ? httpsCheckoutURL(value) : value;
  if (!href) return false;
  try {
    const url = new URL(href);
    return url.hostname === 'buy.stripe.com' && url.pathname.startsWith('/test_');
  } catch {
    return false;
  }
}

export function allowTestCheckout(env = {}) {
  const vercel = String(env.VERCEL_ENV ?? '').trim().toLowerCase();
  if (vercel === 'preview' || vercel === 'development') return true;
  if (vercel === 'production') return false;
  const node = String(env.NODE_ENV ?? '').trim().toLowerCase();
  return node === 'development';
}

export function checkoutLinks(env = {}, file = {}) {
  const allowTest = allowTestCheckout(env);
  const pick = (name, fileValue) => {
    const href = httpsCheckoutURL(env[name]) ?? httpsCheckoutURL(fileValue);
    if (!href) return null;
    if (isStripeTestCheckoutURL(href) && !allowTest) return null;
    return href;
  };
  return {
    plus: pick('UNCLOUD_CHECKOUT_PLUS_URL', file.plus),
    pro: pick('UNCLOUD_CHECKOUT_PRO_URL', file.pro),
    family: pick('UNCLOUD_CHECKOUT_FAMILY_URL', file.family),
  };
}
