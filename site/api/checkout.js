// Vercel function for the marketing site. Returns public checkout URLs only.
// UNCLOUD_CHECKOUT_PLUS_URL, UNCLOUD_CHECKOUT_PRO_URL, and UNCLOUD_CHECKOUT_FAMILY_URL
// override site/checkout.config.json. No secrets.

import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { checkoutLinks } from '../checkout-links.js';

export function checkoutResponse(env, root) {
  let file = {};
  try {
    file = JSON.parse(readFileSync(join(root, 'checkout.config.json'), 'utf8'));
  } catch {
    file = {};
  }
  return checkoutLinks(env, file);
}

export default function handler(_req, res) {
  const root = join(dirname(fileURLToPath(import.meta.url)), '..');
  res.setHeader('Cache-Control', 'no-store');
  res.setHeader('Content-Type', 'application/json; charset=utf-8');
  res.status(200).json(checkoutResponse(process.env, root));
}
