// Static checks for the landing page. Run: node --test site/checks
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const html = readFileSync(join(root, 'index.html'), 'utf8');
const css = readFileSync(join(root, 'styles.css'), 'utf8');
const js = readFileSync(join(root, 'app.js'), 'utf8');
const text = (s) => s.replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ');

test('document head is complete and matches the approved copy', () => {
  assert.match(html, /^<!doctype html>/i);
  assert.match(html, /<html lang="en">/);
  assert.match(html, /<meta charset="utf-8">/);
  assert.match(html, /<meta name="viewport" content="width=device-width, initial-scale=1">/);
  assert.match(html, /<meta name="color-scheme" content="light dark">/);
  assert.ok(html.includes('<title>Uncloud: Take Your Photos Home</title>'));
  assert.ok(html.includes('<meta name="description" content="Export full-quality originals from iCloud Photos to your own drive, without filling up your Mac. Coming soon to Mac.">'));
  assert.ok(html.includes('<link rel="canonical" href="https://uncloud.vercel.app/">'));
  for (const property of ['og:title', 'og:description', 'og:type', 'og:url', 'og:site_name', 'og:image', 'og:image:alt']) {
    assert.match(html, new RegExp(`<meta property="${property}" content="[^"]+">`), property);
  }
  assert.match(html, /<meta property="og:image" content="https:\/\/uncloud\.vercel\.app\/og\.png">/);
  assert.match(html, /<meta name="twitter:card" content="summary_large_image">/);
  for (const name of ['twitter:title', 'twitter:description', 'twitter:image']) {
    assert.match(html, new RegExp(`<meta name="${name}" content="[^"]+">`), name);
  }
});

test('no inline script or style, no style attributes, and no third-party origins', () => {
  assert.doesNotMatch(html, /<script(?![^>]*\bsrc=)[^>]*>/, 'inline script');
  assert.doesNotMatch(html, /<style/, 'style element');
  assert.doesNotMatch(html, /\sstyle=/, 'style attribute');
  const allowed = ['https://uncloud-api.vercel.app', 'https://uncloud.vercel.app'];
  for (const [url] of html.matchAll(/https?:\/\/[^\s"'<>)]+/g)) {
    assert.ok(allowed.some((origin) => url.startsWith(origin)), `third-party URL ${url}`);
  }
  assert.doesNotMatch(js, /https?:\/\/(?!uncloud-api\.vercel\.app)/, 'app.js third-party URL');
});

test('the hero, form messages, tiles, pricing and disclaimer copy are present', () => {
  const plain = text(html);
  for (const line of [
    'Coming soon to Mac',
    'Take Your Photos Home',
    'Export every photo from iCloud to your own drive. Full quality, without filling up your Mac.',
    'For macOS Sonoma 14 or later',
    'Get notified at launch',
    'One email when we launch. No spam. We never share your address.',
    'Sound familiar?',
    'Uncloud fixes all four.',
    'How It Works',
    'Everything Your Photos Need',
    'Simple Pricing',
    '$9.99/year',
    '+ tax',
    'Export is free.',
    'Renew every year, or buy one year at a time. Cancel anytime.',
    'Both come with the app at launch.',
    'Your Photos Stay Yours',
    'Questions',
    'Be First to Take Your Photos Home',
    '© 2026 Uncloud',
    'iCloud, Photos and Mac are trademarks of Apple Inc., registered in the U.S. and other countries. Uncloud is not affiliated with Apple.',
  ]) {
    assert.ok(plain.includes(line), `missing: ${line}`);
  }
  for (const title of [
    'Full-Quality Originals', 'Skips Your Mac', 'Never Twice', 'Picks Up Again',
    'Neatly Organized', 'Automatic Backups', 'Browse Backup', 'Clean Up iCloud',
  ]) {
    assert.ok(html.includes(`<h3>${title}</h3>`), title);
  }
});

test('the four form messages are in the script with the approved wording', () => {
  for (const line of [
    'Enter a valid email address.',
    'Too many tries. Try again in a few minutes.',
    'Couldn’t add you just now. Check your connection and try again.',
    'You’re on the list. We’ll email you when Uncloud is ready.',
    'You’re already on the list. See you at launch.',
    'Joining…',
  ]) {
    assert.ok(js.includes(line), `missing: ${line}`);
  }
  assert.match(html, /Turn on JavaScript to join the list\./);
});

test('no "forever" and no Apple mention outside the approved places', () => {
  assert.doesNotMatch(html, /forever/i);
  const plain = text(html);
  const sentences = plain.split(/(?<=[.?!])\s+/).filter((s) => /\bApple\b/.test(s));
  // Approved places: the privacy band, the FAQ answer about photos, and the footer disclaimer.
  for (const sentence of sentences) {
    assert.ok(
      /Photos go straight from Apple to your drive\.|They never pass through us|trademarks of Apple Inc\./.test(sentence) ||
        /Uncloud is not affiliated with Apple\./.test(sentence),
      `unexpected Apple mention: ${sentence}`,
    );
  }
});

test('every input has a label and the honeypot is hidden from keyboard focus', () => {
  const inputs = [...html.matchAll(/<input\b[^>]*>/g)].map((m) => m[0]);
  for (const input of inputs) {
    const id = /\bid="([^"]+)"/.exec(input)?.[1];
    const named = /\bname="website"/.test(input);
    if (named) {
      assert.match(input, /tabindex="-1"/, 'honeypot tabindex');
    } else {
      assert.ok(id, `input without id: ${input}`);
      assert.ok(html.includes(`for="${id}"`), `no label for ${id}`);
    }
  }
});

test('the stylesheet supports dark mode and reduced motion', () => {
  assert.match(css, /@media \(prefers-color-scheme: dark\)/);
  assert.match(css, /@media \(prefers-reduced-motion: reduce\)/);
});

test('tile titles are at most 3 words and lines at most 10 words', () => {
  const tiles = [...html.matchAll(/<li class="tile">([\s\S]*?)<\/li>/g)].map((m) => m[1]);
  assert.equal(tiles.length, 8);
  for (const tile of tiles) {
    const title = /<h3>([^<]+)<\/h3>/.exec(tile)[1];
    const line = /<p>([^<]+)<\/p>/.exec(tile)[1];
    assert.ok(title.split(/\s+/).length <= 3, title);
    assert.ok(line.split(/\s+/).length <= 10, line);
    assert.match(tile, /<span class="badge badge-(free|plus)">(Free|Plus)<\/span>/);
  }
});

test('the hero visual and the icons carry no text and are hidden from assistive tech', () => {
  assert.match(html, /<div class="scene" aria-hidden="true">/);
  assert.match(html, /<img class="hero-icon" src="icon@2x\.png"[^>]*alt=""/);
});

test('the privacy band uses a single h2 and the page has one h1', () => {
  assert.equal([...html.matchAll(/<h1[\s>]/g)].length, 1);
});
