// Wires Buy buttons to checkout URLs from /api/checkout (env) or checkout.config.json.
// Without a URL, the placeholder already on the page stays visible.

import { checkoutLinks } from './checkout-links.js';

const tiers = ['plus', 'pro', 'family'];

async function load() {
  for (const path of ['/api/checkout', '/checkout.config.json']) {
    try {
      const response = await fetch(path, { headers: { accept: 'application/json' } });
      if (!response.ok) continue;
      return checkoutLinks({}, await response.json());
    } catch {
      // Try the next source. A missing function is normal before the site is hosted.
    }
  }
  return null;
}

function apply(links) {
  for (const tier of tiers) {
    const href = links?.[tier];
    const note = document.getElementById(`checkout-${tier}`);
    const buy = document.getElementById(`buy-${tier}`);
    if (!href || !note || !buy) continue;
    buy.href = href;
    buy.hidden = false;
    note.hidden = true;
  }
}

load().then((links) => {
  if (links) apply(links);
});
