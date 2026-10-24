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

test('there are pages for the home page, the 404 page and the legal pages', () => {
  assert.deepEqual(pages.sort(), ['public/404.html', 'public/index.html', 'public/privacy.html', 'public/terms.html']);
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

test('no script, inline style or inline event handler: the pages need no JavaScript', () => {
  for (const page of pages) {
    const html = read(page);
    assert.doesNotMatch(html, /<script\b/i, page);
    assert.doesNotMatch(html, /<style[\s>]/i, page);
    assert.doesNotMatch(html, /\sstyle\s*=/i, `${page} has a style attribute`);
    assert.doesNotMatch(html, /\son[a-z]+\s*=/i, `${page} has an inline event handler`);
  }
});

test('no page mentions payments, plans or prices', () => {
  for (const page of pages) {
    const html = read(page);
    assert.doesNotMatch(html, /stripe|subscription|subscribe|checkout|refund|\$\d|uncloud plus|\bplus\b|renew/i, page);
  }
});

test('the 404 page keeps its return link to the app', () => {
  assert.match(read('public/404.html'), /href="uncloud:\/\/account\/refresh"/);
});

test('the final copy is present verbatim', () => {
  const copy = {
    'public/404.html': ['Page not found', 'There’s nothing here. If you came from Uncloud, return to the app and try again.'],
    'public/index.html': ['Take Your Photos Home. Export full-quality originals from iCloud to your own drive.', 'This address is Uncloud’s account service. To use Uncloud, open the app on your Mac.'],
    'public/terms.html': [
      'Uncloud is free. There are no paid plans.',
      'Uncloud only deletes photos you select, and only after you confirm.',
      'Uncloud is also not affiliated with Google LLC. Google Photos and Google Takeout are trademarks of Google LLC.',
      'import photos and videos from a Google Takeout download',
    ],
    'public/privacy.html': [
      'your photos and your Apple account never reach us.',
      'Uncloud reads them on your Mac; nothing is sent to Google or to us.',
    ],
  };
  for (const [page, strings] of Object.entries(copy)) {
    for (const text of strings) assert.ok(read(page).includes(text), `${page}: ${text}`);
  }
});

test('the vercel.json sends the CSP with no unsafe directives, and the no-store API cache header', () => {
  const config = JSON.parse(read('vercel.json'));
  const headers = config.headers.flatMap((h) => h.headers.map((x) => [h.source, x.key, x.value]));
  const csp = headers.find(([, key]) => key === 'Content-Security-Policy')[2];
  assert.doesNotMatch(csp, /unsafe-/);
  assert.match(csp, /script-src 'self'/);
  assert.match(csp, /frame-ancestors 'none'/);
  assert.ok(headers.some(([source, key, value]) => source === '/v1/(.*)' && key === 'Cache-Control' && value === 'no-store'));
  assert.deepEqual(config.rewrites, [{ source: '/v1/:path*', destination: '/api/v1/:path*' }]);
});

test('the stylesheet has the dark-mode guard and no external resources', () => {
  const css = read('public/assets/site.css');
  assert.match(css, /@media \(prefers-color-scheme: dark\)/);
  assert.match(css, /:root:not\(\[data-theme="light"\]\)/);
  assert.match(css, /:root\[data-theme="dark"\]/);
  assert.doesNotMatch(css, /@import|https?:\/\//);
});

test('the legal pages say Uncloud is not affiliated with Apple, and give the support address', () => {
  for (const page of ['public/terms.html', 'public/privacy.html']) {
    assert.match(read(page), /not affiliated with, endorsed, sponsored, or approved by Apple Inc\./, page);
    assert.match(read(page), /mailto:barishiz@gmail\.com/, page);
  }
});
