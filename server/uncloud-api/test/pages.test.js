import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { join, relative } from 'node:path';

const root = fileURLToPath(new URL('..', import.meta.url));
const read = (path) => readFileSync(join(root, path), 'utf8');

function htmlPages(dir = join(root, 'public')) {
  return readdirSync(dir).flatMap((name) => {
    const full = join(dir, name);
    if (statSync(full).isDirectory()) return htmlPages(full);
    return name.endsWith('.html') ? [relative(root, full)] : [];
  });
}

const pages = htmlPages();

test('there are pages for every route the app and Stripe use', () => {
  for (const expected of [
    'public/index.html', 'public/404.html', 'public/terms.html', 'public/privacy.html',
    'public/checkout/success.html', 'public/checkout/cancelled.html', 'public/account/return.html',
  ]) {
    assert.ok(pages.includes(expected), expected);
  }
});

test('every page is a complete light/dark document with a viewport and the shared stylesheet', () => {
  for (const page of pages) {
    const html = read(page);
    assert.match(html, /^<!doctype html>/i, page);
    assert.match(html, /<meta name="viewport" content="width=device-width, initial-scale=1">/, page);
    assert.match(html, /<meta charset="utf-8">/, page);
    assert.match(html, /<title>[^<]+<\/title>/, page);
    assert.match(html, /<link rel="stylesheet" href="\/assets\/site\.css">/, page);
  }
});

test('no inline script or style: CSP forbids them', () => {
  for (const page of pages) {
    const html = read(page);
    assert.doesNotMatch(html, /<style[\s>]/i, page);
    assert.doesNotMatch(html, /\sstyle\s*=/i, `${page} has a style attribute`);
    const scripts = [...html.matchAll(/<script\b([^>]*)>/gi)];
    for (const [, attributes] of scripts) {
      assert.match(attributes, /\ssrc="\/assets\/return\.js"/, `${page} has a non-file script`);
    }
    assert.doesNotMatch(html, /\son[a-z]+\s*=/i, `${page} has an inline event handler`);
  }
});

test('only the return script is loaded, and only on the return pages', () => {
  const withScript = pages.filter((p) => read(p).includes('/assets/return.js')).sort();
  assert.deepEqual(withScript, ['public/account/return.html', 'public/checkout/cancelled.html', 'public/checkout/success.html']);
});

test('the success page is the only one that syncs the session, and it is marked for it', () => {
  for (const page of pages) {
    const marked = /data-checkout-sync/.test(read(page));
    assert.equal(marked, page === 'public/checkout/success.html', page);
  }
});

test('return pages open the expected app URLs', () => {
  assert.match(read('public/checkout/success.html'), /data-app-url="uncloud:\/\/checkout\/success"/);
  assert.match(read('public/checkout/cancelled.html'), /data-app-url="uncloud:\/\/checkout\/cancel"/);
  assert.match(read('public/account/return.html'), /data-app-url="uncloud:\/\/account\/refresh"/);
  assert.match(read('public/404.html'), /href="uncloud:\/\/account\/refresh"/);
});

test('the final copy from the plan is present verbatim', () => {
  const copy = {
    'public/checkout/success.html': ['You’re all set', 'Your payment went through and Uncloud Plus is on.', 'Uncloud didn’t open? Switch to it from the Dock. Your plan shows up within a minute.', 'A receipt is on its way to your email.'],
    'public/checkout/cancelled.html': ['Checkout cancelled', 'You haven’t been charged. You can get Uncloud Plus anytime from Uncloud.'],
    'public/account/return.html': ['Changes saved', 'Uncloud will show your updated plan in a moment.'],
    'public/index.html': ['Take Your Photos Home. Export full-quality originals from iCloud to your own drive.', 'This address is Uncloud’s account service. To use Uncloud, open the app on your Mac.'],
    'public/404.html': ['Page not found', 'There’s nothing here. If you came from Uncloud, return to the app and try again.'],
    'public/terms.html': ['Uncloud Plus costs $9.99 USD per year, plus any tax that applies where you live. Tax is shown before you pay.', 'Clean Up iCloud deletes photos from your iCloud library only when you confirm. Recently Deleted keeps them for up to 30 days.'],
    'public/privacy.html': ['Your email address, a Stripe customer ID, and your plan’s status and renewal date. Nothing else.'],
  };
  for (const [page, strings] of Object.entries(copy)) {
    for (const text of strings) assert.ok(read(page).includes(text), `${page}: ${text}`);
  }
});

test('the success sync posts to the same-origin endpoint with a validated session id', () => {
  const script = read('public/assets/return.js');
  assert.ok(script.includes("fetch('/v1/checkout/sync'") || script.includes("'/v1/checkout/sync'"));
  assert.match(script, /\^cs_\(test\|live\)_\[A-Za-z0-9\]\+\$/);
  assert.match(script, /4000/);
  assert.doesNotMatch(script, /\beval\(|new Function|innerHTML/);
});

test('the stylesheet has the dark-mode guard and no external resources', () => {
  const css = read('public/assets/site.css');
  assert.match(css, /@media \(prefers-color-scheme: dark\)/);
  assert.match(css, /:root:not\(\[data-theme="light"\]\)/);
  assert.match(css, /:root\[data-theme="dark"\]/);
  assert.doesNotMatch(css, /@import|https?:\/\//);
});

test('vercel.json sends the CSP with no unsafe directives, and the no-store API cache header', () => {
  const config = JSON.parse(read('vercel.json'));
  const headers = config.headers.flatMap((h) => h.headers.map((x) => [h.source, x.key, x.value]));
  const csp = headers.find(([, key]) => key === 'Content-Security-Policy')[2];
  assert.doesNotMatch(csp, /unsafe-/);
  assert.match(csp, /script-src 'self'/);
  assert.match(csp, /frame-ancestors 'none'/);
  assert.ok(headers.some(([source, key, value]) => source === '/v1/(.*)' && key === 'Cache-Control' && value === 'no-store'));
  assert.deepEqual(config.rewrites, [{ source: '/v1/:path*', destination: '/api/v1/:path*' }]);
});

test('the legal pages carry a draft banner and the support placeholder is visible', () => {
  for (const page of ['public/terms.html', 'public/privacy.html']) {
    assert.match(read(page), /class="placeholder"/, page);
    assert.match(read(page), /\[support email\]/, page);
  }
});
