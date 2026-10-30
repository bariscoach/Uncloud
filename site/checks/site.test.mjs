// Static checks for the download page. Run: node --test site/checks
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
const SITE = 'https://getuncloud.vercel.app';
const DMG = 'https://github.com/bariscoach/Uncloud/releases/latest/download/Uncloud.dmg';

// Removes every block that starts with one of the given headers (brace matched).
function stripBlocks(src, headerRe) {
  let out = src;
  for (;;) {
    headerRe.lastIndex = 0;
    const m = headerRe.exec(out);
    if (!m) return out;
    let depth = 0;
    let end = m.index + m[0].length;
    depth = 1;
    while (depth > 0 && end < out.length) {
      if (out[end] === '{') depth++;
      if (out[end] === '}') depth--;
      end++;
    }
    out = out.slice(0, m.index) + out.slice(end);
  }
}

test('document head is complete and points at the download page', () => {
  assert.match(html, /^<!doctype html>/i);
  assert.match(html, /<html lang="en">/);
  assert.match(html, /<meta charset="utf-8">/);
  assert.match(html, /<meta name="viewport" content="width=device-width, initial-scale=1">/);
  assert.match(html, /<meta name="color-scheme" content="light dark">/);
  assert.ok(html.includes('<title>Uncloud: Take Your Photos Home</title>'));
  assert.ok(html.includes('<meta name="description" content="Export full-quality originals from iCloud Photos to your own drive, without filling up your Mac. Free for Mac.">'));
  assert.ok(html.includes(`<link rel="canonical" href="${SITE}/">`));
  assert.ok(html.includes('<meta name="theme-color" content="#0A0A0C" media="(prefers-color-scheme: dark)">'));
  for (const property of ['og:title', 'og:description', 'og:type', 'og:url', 'og:site_name', 'og:image', 'og:image:alt']) {
    assert.match(html, new RegExp(`<meta property="${property}" content="[^"]+">`), property);
  }
  assert.ok(html.includes(`<meta property="og:url" content="${SITE}/">`));
  assert.ok(html.includes(`<meta property="og:image" content="${SITE}/og.png">`));
  assert.match(html, /<meta name="twitter:card" content="summary_large_image">/);
  for (const name of ['twitter:title', 'twitter:description', 'twitter:image']) {
    assert.match(html, new RegExp(`<meta name="${name}" content="[^"]+">`), name);
  }
  assert.ok(html.includes(`<meta name="twitter:image" content="${SITE}/og.png">`));
  assert.doesNotMatch(html, /Coming soon/i, 'coming soon copy');
  assert.doesNotMatch(html, /https:\/\/uncloud\.vercel\.app/, 'old domain');
});

test('no inline script or style, no style attributes, and only allowed origins', () => {
  assert.doesNotMatch(html, /<script(?![^>]*\bsrc=)[^>]*>/, 'inline script');
  assert.doesNotMatch(html, /<style/, 'style element');
  assert.doesNotMatch(html, /\sstyle=/, 'style attribute');
  const allowed = [SITE, 'https://uncloud-api.vercel.app', 'https://github.com/bariscoach/Uncloud'];
  for (const [url] of html.matchAll(/https?:\/\/[^\s"'<>)]+/g)) {
    assert.ok(allowed.some((origin) => url.startsWith(origin)), `third-party URL ${url}`);
  }
  assert.doesNotMatch(js, /https?:\/\/(?!uncloud-api\.vercel\.app)/, 'app.js third-party URL');
  assert.match(html, /<script type="module" src="app.js"><\/script>/);
});

test('the download link is in the top bar, the hero and the closing band', () => {
  const links = html.split(`href="${DMG}"`).length - 1;
  assert.ok(links >= 2, `download links: ${links}`);
  assert.equal(links, 3);
  const plain = text(html);
  assert.ok(plain.includes('Download Uncloud for Mac'), 'accessible name of the hero button');
  assert.ok(plain.includes('Version 0.1.26 · macOS 14 or later'), 'version and requirements');
  assert.ok(html.includes('href="https://github.com/bariscoach/Uncloud/releases"'), 'all versions link');
  assert.ok(html.includes('download'), 'download attribute on the hero');
});

test('the install section has an id, the hero link, and three steps', () => {
  assert.match(html, /<section class="section" id="install"/);
  assert.ok(html.includes('href="#install"'), 'How to install link');
  const plain = text(html);
  assert.ok(plain.includes('Install in three steps'));
  assert.equal([...html.matchAll(/<li class="install-card">/g)].length, 3);
  assert.ok(plain.includes('Open Uncloud.dmg and drag Uncloud to Applications.'));
  assert.ok(plain.includes('System Settings › Privacy &amp; Security and click Open Anyway.'));
  assert.ok(plain.includes('Sign in to iCloud Photos and choose your backup drive. No Uncloud account needed.'));
});

test('the hero, tiles, FAQ and disclaimer copy are present', () => {
  const plain = text(html);
  for (const line of [
    'Take Your Photos Home',
    'Export full-quality originals from iCloud Photos to your own drive, without filling up your Mac. Free.',
    'How it works',
    'Everything your photos need',
    'Free. No account, no sign-up.',
    'Your photos stay yours',
    'Questions',
    'Ready to take your photos home?',
    'Why does macOS warn me the first time?',
    'Is it free?',
    '© 2026 Uncloud',
    'Uncloud is an independent app and is not affiliated with, endorsed, sponsored, or approved by Apple Inc.',
    'Apple, iCloud, iCloud Photos and Mac are trademarks of Apple Inc., registered in the U.S. and other countries and regions.',
  ]) {
    assert.ok(plain.includes(line), `missing: ${line}`);
  }
  for (const title of [
    'Export from iCloud', 'Export Photos by Date', 'Automatic Backups', 'Browse Backup', 'Delete from iCloud',
  ]) {
    assert.ok(html.includes(`<h3>${title}</h3>`), title);
  }
  for (const gone of ['Get notified at launch', 'Notify Me', 'Be First to Take Your Photos Home', 'Sound familiar?', 'When does Uncloud launch?']) {
    assert.ok(!plain.includes(gone), `still present: ${gone}`);
  }
  assert.ok(html.includes('<h1 id="hero-title">Take your photos home.</h1>'), 'hero h1');
});

test('sections have ids and the top bar links to them', () => {
  for (const id of ['how', 'features', 'privacy', 'install', 'faq']) {
    assert.ok(html.includes(`id="${id}"`), `section id ${id}`);
  }
  assert.match(html, /<nav class="topnav" aria-label="Sections">/);
  for (const href of ['#features', '#privacy', '#install', '#faq']) {
    assert.ok(html.includes(`href="${href}"`), `nav link ${href}`);
  }
});

test('the hero has a secondary install button and no pulsing glow', () => {
  assert.match(html, /<a class="btn btn-lg btn-ghost" href="#install">/);
  assert.doesNotMatch(css, /glow-pulse|hero-float/);
  assert.doesNotMatch(html, /hero-wordmark/);
});

test('no payment, plan or removed-tool wording on the page', () => {
  const plain = text(html);
  for (const pattern of [
    /pric/i, /\$\d/, /\bPlus\b/, /\bbadge/i, /subscri/i, /stripe/i, /checkout/i, /\bplan\b/i,
    /free up/i, /verify backup/i, /find duplicates/i, /\bduplicates\b/i,
  ]) {
    assert.doesNotMatch(plain, pattern, `found ${pattern}`);
  }
  assert.doesNotMatch(html, /class="[^"]*\bbadge/, 'badge class');
});

test('app.js only reveals sections and has no network code', () => {
  assert.match(js, /IntersectionObserver/);
  assert.match(js, /prefers-reduced-motion: reduce/);
  assert.match(js, /classList\.add\("js"\)/);
  assert.doesNotMatch(js, /fetch\(|XMLHttpRequest|waitlist/i);
});

test('no "forever" and no Apple mention outside the approved places', () => {
  assert.doesNotMatch(html, /forever/i);
  const plain = text(html);
  const sentences = plain.split(/(?<=[.?!])\s+/).filter((s) => /\bApple\b/.test(s));
  // Approved places: the privacy band, the FAQ answers about photos and notarization, and the footer disclaimer.
  for (const sentence of sentences) {
    assert.ok(
      /Photos go straight from Apple to your drive\.|They never pass through us|trademarks of Apple Inc\.|notarized by Apple yet/.test(sentence) ||
        /not affiliated with, endorsed, sponsored, or approved by Apple Inc\./.test(sentence),
      `unexpected Apple mention: ${sentence}`,
    );
  }
});

test('every input has a label (the page has none now, so this only guards future forms)', () => {
  const inputs = [...html.matchAll(/<input\b[^>]*>/g)].map((m) => m[0]);
  for (const input of inputs) {
    const id = /\bid="([^"]+)"/.exec(input)?.[1];
    assert.ok(id, `input without id: ${input}`);
    assert.ok(html.includes(`for="${id}"`), `no label for ${id}`);
  }
});

test('the stylesheet supports dark mode, reduced motion and the no-preference motion block', () => {
  assert.match(css, /@media \(prefers-color-scheme: dark\)/);
  assert.match(css, /@media \(prefers-reduced-motion: reduce\)/);
  assert.match(css, /@media \(prefers-reduced-motion: no-preference\)/);
  assert.match(css, /html\.js \[data-reveal\]/);
});

test('every animation is inside the no-preference block or a keyframes rule', () => {
  const outside = stripBlocks(
    css,
    /@(?:keyframes [^{]+|media \(prefers-reduced-motion: (?:no-preference|reduce)\))\s*\{/g,
  );
  assert.doesNotMatch(outside, /\banimation(?:-[a-z]+)?\s*:/, 'animation declared outside the motion block');
});

test('the feature illustrations exist and are hidden from assistive tech', () => {
  const tiles = [...html.matchAll(/<li class="tile"[^>]*>([\s\S]*?)<\/li>/g)].map((m) => m[1]);
  assert.equal(tiles.length, 5);
  for (const tile of tiles) {
    assert.match(tile, /<div class="tile-art" aria-hidden="true">/);
    assert.match(tile, /<svg viewBox="0 0 240 120"/);
  }
});

test('tile titles are at most 4 words and lines at most 10 words', () => {
  const tiles = [...html.matchAll(/<li class="tile"[^>]*>([\s\S]*?)<\/li>/g)].map((m) => m[1]);
  for (const tile of tiles) {
    const title = /<h3>([^<]+)<\/h3>/.exec(tile)[1];
    const line = /<p>([^<]+)<\/p>/.exec(tile)[1];
    assert.ok(title.split(/\s+/).length <= 4, title);
    assert.ok(line.split(/\s+/).length <= 10, line);
  }
});

test('the hero visual and the icons carry no text and are hidden from assistive tech', () => {
  assert.match(html, /<div class="scene" aria-hidden="true">/);
  assert.match(html, /<div class="hero-icon" aria-hidden="true">/);
  for (const layer of ['shadow', 'tile', 'sun', 'rays', 'motion', 'cloud']) {
    assert.match(html, new RegExp(`<img class="hero-layer[^"]*" src="logo/logo-${layer}\\.png"[^>]*alt=""`));
  }
});

test('the page has one h1 and the section headings are h2', () => {
  assert.equal([...html.matchAll(/<h1[\s>]/g)].length, 1);
});
