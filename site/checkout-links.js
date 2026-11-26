// Checkout URLs for the pricing page. Environment variables win over checkout.config.json.
// Empty or non-https values become null so the page can show a placeholder.

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

export function checkoutLinks(env = {}, file = {}) {
  const pick = (name, fileValue) => httpsCheckoutURL(env[name]) ?? httpsCheckoutURL(fileValue);
  return {
    plus: pick('UNCLOUD_CHECKOUT_PLUS_URL', file.plus),
    pro: pick('UNCLOUD_CHECKOUT_PRO_URL', file.pro),
    family: pick('UNCLOUD_CHECKOUT_FAMILY_URL', file.family),
  };
}
