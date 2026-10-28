# Site redesign: modern, sleek, chic

Owner's brief: "I want the website really modern, sleek, chic."
Scope: `site/index.html`, `site/styles.css`, `site/checks/site.test.mjs`. `site/app.js` stays as it is.
Builder: **web-builder** (Haiku). Follow this file literally. Where it says "copy verbatim", copy the existing markup character for character.

---

## 1. Review of the current page (from screenshots, 2026-10-27)

| Area | Score /10 | What's wrong |
|---|---|---|
| Hierarchy | 5 | The hero stacks icon, then a second "Uncloud" wordmark (already in the top bar), then the h1. The brand shows up three times before the promise. "How to install" sits on its own underlined line like a footnote. |
| Typography | 5 | The h1 is 60px with -0.02em tracking, so it reads as a heading, not a statement. Title Case on every h2 ("Everything Your Photos Need") feels corporate. Section headings are all the same size and weight, so the page has no rhythm. |
| Spacing | 4 | There are 250px of dead white space under the hero scene. Every section has the same 96px padding and centered heading, so the page reads as one long list. |
| Color | 5 | Generic SaaS blue (#1E6FD9) on everything: buttons, numbers, links, glow. The gray surfaces are slightly blue (#F5F7FA). Nothing uses the warmth of the logo (sun gold + sky). |
| Imagery | 4 | The hero scene is small (560px), pale and floats unanchored, so it looks like a placeholder. The feature grid is 3 + 2 and leaves an empty slot on the right (`.tiles`, desktop). |
| Motion | 6 | The logo reveal is lovely. The pulsing glow behind the button (`.hero-cta::before`) looks cheap. Nothing animates in the hero on page load. |
| Dark mode | 6 | It works, but it is flat: #111214 with #1C1E22 cards and no depth. The privacy band is just a slightly lighter gray stripe. |
| Mobile | 5 | Long and repetitive: two consecutive "1-2-3" lists (Install, then How It Works) with identical blue circles. Real 390px render: the h1 breaks into "Take Your / Photos Home" and is fine, but the scene is tiny. |
| Conversion | 6 | The Download button is clear, but the secondary path (install help) is a weak text link. The closing CTA band is plain text with no visual pull. |

Root causes: no type scale, no depth system, one accent used everywhere, and section order that interrupts the pitch (install help comes before the features).

**Note for the builder about screenshots.** Headless Chrome won't make a window narrower than 500px, so `phone-*.png` from `scripts/site-shots.sh` is a 500px layout cut off at 390. It is **not** a real overflow bug. For a true 390px check, use the iframe recipe in section 10.

## 2. Direction

**"Gallery quiet."** The look is monochrome and confident, like Linear, Raycast or Things:

- **Ink primary buttons**: near-black pills in light mode and near-white pills in dark mode. Blue is kept only for links, focus rings and the small accents inside illustrations.
- **Warmth comes from the logo**: a faint sky-blue and sun-gold aurora behind the hero and the closing panel, plus one gold dot in the eyebrow pill.
- **Big, tight display type** in sentence case, with real size steps between display, h2 and body.
- **Depth through panels**: the hero scene sits on a framed "stage", features are a bento grid, privacy is an inverted statement panel, and the closing CTA is a glowing panel with the app icon.
- **Glass top bar**: sticky and translucent, with section links on desktop.
- **Calm motion**: a staggered hero entrance on load, gentle scroll reveals, and no pulsing.

New section order: **Hero → How it works → Features → Privacy → Install → Questions → Closing CTA → Footer.** Install moves below the pitch. The hero's "How to install" button still jumps straight to it.

---

## 3. Design tokens

Replace the whole `:root` block and the dark-mode block at the top of `styles.css` with this:

```css
:root {
  /* Color: light */
  --bg: #FFFFFF;
  --surface: #F5F5F7;
  --art-bg: #FFFFFF;
  --border: rgba(0, 0, 0, 0.08);
  --border-strong: rgba(0, 0, 0, 0.14);
  --text: #0B0B0D;
  --text-2: #5E5E66;
  --text-3: #8A8A93;
  --ink: #0B0B0D;
  --ink-hover: #2A2A2F;
  --on-ink: #FFFFFF;
  --accent: #0A66E8;
  --accent-text: #0059D6;
  --on-accent: #FFFFFF;
  --accent-wash: rgba(10, 102, 232, 0.08);
  --focus: #0A66E8;
  --sun: #F5A524;
  --glow-sky: rgba(56, 140, 255, 0.16);
  --glow-sun: rgba(255, 180, 60, 0.14);
  --dot: rgba(0, 0, 0, 0.07);
  --hover-wash: rgba(0, 0, 0, 0.04);
  --topbar-bg: rgba(255, 255, 255, 0.72);
  --glass: rgba(255, 255, 255, 0.6);
  --scene-stroke: #D8D8DE;
  --panel-bg: #0B0B0D;
  --panel-text: #F5F5F7;
  --panel-text-2: #A1A1AA;
  --panel-border: rgba(255, 255, 255, 0.10);
  --panel-glow: rgba(61, 139, 255, 0.22);

  /* Type */
  --font: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
  --font-display: -apple-system, BlinkMacSystemFont, "SF Pro Display", "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
  --fs-display: clamp(2.75rem, 1.6rem + 5.2vw, 5.25rem);
  --fs-h2: clamp(2rem, 1.4rem + 2.6vw, 3rem);
  --fs-lede: clamp(1.125rem, 1rem + 0.5vw, 1.3125rem);
  --fs-sub: 1.125rem;
  --fs-body: 1.0625rem;
  --fs-small: 0.9375rem;
  --fs-xs: 0.8125rem;

  /* Space */
  --space-section: clamp(80px, 10vw, 136px);

  /* Radii */
  --r-sm: 10px;
  --r-md: 14px;
  --r-lg: 20px;
  --r-xl: 28px;
  --r-pill: 999px;

  /* Shadows */
  --shadow-btn: inset 0 1px 0 rgba(255, 255, 255, 0.12), 0 1px 2px rgba(0, 0, 0, 0.20), 0 8px 24px -8px rgba(0, 0, 0, 0.35);
  --shadow-lg: 0 1px 2px rgba(0, 0, 0, 0.04), 0 24px 64px -24px rgba(16, 24, 40, 0.18);

  /* Motion */
  --ease-out: cubic-bezier(0.22, 1, 0.36, 1);
  --dur-fast: 160ms;
  --dur: 240ms;
  --dur-slow: 800ms;

  color-scheme: light dark;
}

@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) {
    --bg: #0A0A0C;
    --surface: #141417;
    --art-bg: #0E0E11;
    --border: rgba(255, 255, 255, 0.08);
    --border-strong: rgba(255, 255, 255, 0.16);
    --text: #F5F5F7;
    --text-2: #A1A1AA;
    --text-3: #6B6B74;
    --ink: #F5F5F7;
    --ink-hover: #FFFFFF;
    --on-ink: #0A0A0C;
    --accent: #3D8BFF;
    --accent-text: #6AAAFF;
    --on-accent: #FFFFFF;
    --accent-wash: rgba(61, 139, 255, 0.14);
    --focus: #6AAAFF;
    --glow-sky: rgba(61, 139, 255, 0.22);
    --glow-sun: rgba(255, 170, 50, 0.10);
    --dot: rgba(255, 255, 255, 0.06);
    --hover-wash: rgba(255, 255, 255, 0.06);
    --topbar-bg: rgba(10, 10, 12, 0.72);
    --glass: rgba(20, 20, 23, 0.6);
    --scene-stroke: #2E2E35;
    --panel-bg: #141417;
    --panel-glow: rgba(61, 139, 255, 0.20);
    --shadow-btn: inset 0 1px 0 rgba(255, 255, 255, 0.5), 0 1px 2px rgba(0, 0, 0, 0.4), 0 8px 24px -8px rgba(0, 0, 0, 0.6);
    --shadow-lg: inset 0 1px 0 rgba(255, 255, 255, 0.04), 0 24px 64px -24px rgba(0, 0, 0, 0.7);
  }
}
```

Contrast checks: `--text-2` passes AA on `--bg` and on `--surface` in both modes, and `--panel-text-2` passes AA on `--panel-bg`. `--text-3` is used only for the decorative, `aria-hidden` step numerals.

Delete the old `--glow` token and every use of it.

---

## 4. Global CSS (replace the corresponding existing rules)

```css
*, *::before, *::after { box-sizing: border-box; }

html { -webkit-text-size-adjust: 100%; text-size-adjust: 100%; }

[id] { scroll-margin-top: 76px; }

body {
  margin: 0;
  background: var(--bg);
  color: var(--text);
  font-family: var(--font);
  font-size: var(--fs-body);
  line-height: 1.55;
  -webkit-font-smoothing: antialiased;
  text-rendering: optimizeLegibility;
  overflow-x: clip;
}

img, svg { display: block; max-width: 100%; }
h1, h2, h3, p, ul, ol { margin: 0; }
ul, ol { padding: 0; }
a { color: var(--accent-text); }

::selection { background: var(--accent-wash); }

:focus-visible { outline: 2px solid var(--focus); outline-offset: 3px; }

.wrap { max-width: 1120px; margin: 0 auto; padding-left: 20px; padding-right: 20px; }
@media (min-width: 720px) { .wrap { padding-left: 32px; padding-right: 32px; } }
```

Keep `.sr-only` and `.skip` as they are, but change `.skip`'s `z-index` to `100` and its `border-radius` to `var(--r-pill)`, and use `background: var(--ink); color: var(--on-ink);`.

Delete these rules entirely: `.centered`, `.muted`, `.text-link`, `.hero-wordmark`, `.hero-cta`, `.hero-cta .btn`, `.hero-cta::before`, `.privacy-inner`, `.cta-band` (and its media query), the old `.num` base rule, and `.steps .num`.

---

## 5. Section by section: HTML and CSS

Where you see "copy verbatim from current file", copy that exact SVG or element. Indent with 2 spaces like the current file.

### 5.0 `<head>` changes

Only change the two theme-color metas:

```html
  <meta name="theme-color" content="#FFFFFF" media="(prefers-color-scheme: light)">
  <meta name="theme-color" content="#0A0A0C" media="(prefers-color-scheme: dark)">
```

Also fix the stray indentation: `<script type="module" src="app.js"></script>` gets 2 spaces, not 4. Everything else in `<head>` stays.

### 5.1 Top bar

```html
  <header class="topbar">
    <div class="wrap topbar-inner">
      <a class="brand" href="/">
        <img src="icon.png" width="24" height="24" alt="" decoding="async">
        <!-- the existing <svg class="wordmark brand-wordmark" …>…</svg>, copy verbatim from current file -->
      </a>
      <nav class="topnav" aria-label="Sections">
        <ul>
          <li><a href="#features">Features</a></li>
          <li><a href="#privacy">Privacy</a></li>
          <li><a href="#install">Install</a></li>
          <li><a href="#faq">FAQ</a></li>
        </ul>
      </nav>
      <a class="btn btn-sm topbar-download" href="https://github.com/bariscoach/Uncloud/releases/latest/download/Uncloud.dmg">Download<span class="sr-only"> Uncloud</span></a>
    </div>
  </header>
```

```css
.topbar {
  position: sticky;
  top: 0;
  z-index: 50;
  height: 60px;
  background: var(--topbar-bg);
  -webkit-backdrop-filter: saturate(180%) blur(16px);
  backdrop-filter: saturate(180%) blur(16px);
  border-bottom: 1px solid var(--border);
}
@supports not ((backdrop-filter: blur(1px)) or (-webkit-backdrop-filter: blur(1px))) {
  .topbar { background: var(--bg); }
}
.topbar-inner {
  height: 100%;
  display: grid;
  grid-template-columns: 1fr auto 1fr;
  align-items: center;
  gap: 16px;
}
.brand {
  justify-self: start;
  display: inline-flex;
  align-items: center;
  gap: 10px;
  min-height: 44px;
  color: var(--text);
  text-decoration: none;
  border-radius: var(--r-sm);
}
.brand img { width: 24px; height: 24px; border-radius: 6px; }

.wordmark {                       /* keep this rule as is */
  display: block;
  width: auto;
  height: auto;
  aspect-ratio: 3825 / 769;
  fill: currentColor;
  color: var(--text);
}
.brand-wordmark { height: 17px; width: auto; }

.topnav ul { display: flex; gap: 4px; list-style: none; }
.topnav a {
  display: inline-flex;
  align-items: center;
  min-height: 36px;
  padding: 0 12px;
  border-radius: var(--r-pill);
  color: var(--text-2);
  font-size: 0.875rem;
  font-weight: 500;
  text-decoration: none;
}
.topbar-download { justify-self: end; }

@media (hover: hover) {
  .topnav a:hover { color: var(--text); background: var(--hover-wash); }
}
@media (max-width: 759px) {
  .topnav { display: none; }
  .topbar-inner { grid-template-columns: 1fr auto; }
}
```

### 5.2 Buttons

```css
.btn {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  gap: 10px;
  min-height: 44px;
  padding: 0 20px;
  border: 1px solid transparent;
  border-radius: var(--r-pill);
  background: var(--ink);
  color: var(--on-ink);
  font: inherit;
  font-weight: 600;
  letter-spacing: -0.01em;
  text-decoration: none;
  cursor: pointer;
  box-shadow: var(--shadow-btn);
}
.btn-sm { min-height: 36px; padding: 0 16px; font-size: 0.875rem; }
.btn-lg { min-height: 52px; padding: 0 26px; font-size: 1.0625rem; }
.btn-ghost {
  background: var(--glass);
  color: var(--text);
  border-color: var(--border-strong);
  box-shadow: none;
}
.btn-icon {                        /* keep as is, size changes */
  width: 18px;
  height: 18px;
  flex: 0 0 auto;
  fill: none;
  stroke: currentColor;
  stroke-width: 2;
  stroke-linecap: round;
  stroke-linejoin: round;
}
.btn-chevron { width: 16px; height: 16px; }

@media (hover: hover) {
  .btn:hover { background: var(--ink-hover); }
  .btn-ghost:hover { background: var(--hover-wash); border-color: var(--text-3); }
}
@media (max-width: 759px) {
  .btn-sm { min-height: 40px; }
}
```

### 5.3 Hero

```html
    <section class="hero" aria-labelledby="hero-title">
      <div class="hero-glow" aria-hidden="true"></div>
      <div class="wrap hero-inner">
        <div class="hero-icon" aria-hidden="true">
          <!-- the six hero-layer <img> elements and .hero-mask, copy verbatim from current file -->
        </div>
        <p class="eyebrow"><span class="eyebrow-dot" aria-hidden="true"></span>Free for Mac · No account needed</p>
        <h1 id="hero-title">Take your photos home.</h1>
        <p class="lede">Export full-quality originals from iCloud Photos to your own drive, without filling up your Mac. Free.</p>

        <div class="actions">
          <a class="btn btn-lg" href="https://github.com/bariscoach/Uncloud/releases/latest/download/Uncloud.dmg">
            <svg class="btn-icon" viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="M12 4v11"/><path d="M7.5 10.5 12 15l4.5-4.5"/><path d="M5 19.5h14"/></svg>
            <span class="btn-label">Download <span class="sr-only">Uncloud </span>for Mac</span>
          </a>
          <a class="btn btn-lg btn-ghost" href="#install">
            How to install
            <svg class="btn-icon btn-chevron" viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="M12 5v14"/><path d="m6 13 6 6 6-6"/></svg>
          </a>
        </div>
        <p class="meta">Version 0.1.25 · macOS 14 or later · <a href="https://github.com/bariscoach/Uncloud/releases">All versions</a></p>

        <div class="stage">
          <div class="scene" aria-hidden="true">
            <!-- the existing <svg viewBox="0 0 560 180" …>…</svg>, copy verbatim from current file -->
          </div>
          <div class="stage-labels" aria-hidden="true"><span>iCloud Photos</span><span>Your drive</span></div>
        </div>
      </div>
    </section>
```

The second "Uncloud" wordmark in the hero is **removed**. The old `<p class="meta"><a class="text-link" href="#install">How to install</a></p>` is **removed**; the ghost button replaces it.

```css
.hero {
  position: relative;
  overflow: hidden;
  padding: clamp(56px, 8vw, 104px) 0 clamp(72px, 9vw, 120px);
  text-align: center;
}
.hero-glow {
  position: absolute;
  inset: 0 0 auto 0;
  height: 720px;
  pointer-events: none;
  background:
    radial-gradient(42% 55% at 32% 0%, var(--glow-sky), transparent 70%),
    radial-gradient(36% 48% at 70% 4%, var(--glow-sun), transparent 70%);
}
.hero-glow::after {
  content: "";
  position: absolute;
  inset: 0;
  background-image: radial-gradient(var(--dot) 1px, transparent 1.2px);
  background-size: 22px 22px;
  -webkit-mask-image: radial-gradient(55% 60% at 50% 20%, #000 0%, transparent 75%);
  mask-image: radial-gradient(55% 60% at 50% 20%, #000 0%, transparent 75%);
}
.hero-inner { position: relative; display: flex; flex-direction: column; align-items: center; }

.hero-icon { position: relative; width: 96px; height: 96px; margin-bottom: 28px; }
/* keep .hero-icon .hero-layer, .hero-mask and .hero-rays exactly as they are */

.eyebrow {
  display: inline-flex;
  align-items: center;
  gap: 8px;
  min-height: 30px;
  padding: 0 14px;
  border: 1px solid var(--border);
  border-radius: var(--r-pill);
  background: var(--glass);
  color: var(--text-2);
  font-size: var(--fs-xs);
  font-weight: 500;
}
.eyebrow-dot { width: 6px; height: 6px; border-radius: 50%; background: var(--sun); }

h1 {
  margin-top: 20px;
  max-width: 12ch;
  font-family: var(--font-display);
  font-size: var(--fs-display);
  font-weight: 700;
  line-height: 1.02;
  letter-spacing: -0.04em;
  text-wrap: balance;
}
.lede {
  margin-top: 24px;
  max-width: 34rem;
  color: var(--text-2);
  font-size: var(--fs-lede);
  line-height: 1.5;
  text-wrap: balance;
}

.actions { display: flex; flex-wrap: wrap; justify-content: center; gap: 12px; }
.hero .actions { margin-top: 36px; }

.meta { margin-top: 18px; color: var(--text-2); font-size: 0.875rem; }
.meta a {
  color: var(--text-2);
  font-weight: 500;
  text-decoration: underline;
  text-decoration-color: var(--border-strong);
  text-underline-offset: 3px;
}
@media (hover: hover) { .meta a:hover { color: var(--text); } }

.stage {
  position: relative;
  width: min(920px, 100%);
  margin-top: clamp(56px, 8vw, 88px);
  padding: clamp(40px, 6vw, 72px) clamp(16px, 4vw, 56px) clamp(28px, 4vw, 44px);
  border: 1px solid var(--border);
  border-radius: var(--r-xl);
  background: linear-gradient(180deg, var(--surface) 0%, var(--bg) 100%);
  box-shadow: var(--shadow-lg);
}
.stage .scene { width: min(640px, 100%); margin: 0 auto; aspect-ratio: 560 / 180; }
.scene svg { width: 100%; height: 100%; overflow: visible; }   /* keep */
.stage-labels {
  display: grid;
  grid-template-columns: 34% 1fr 28%;
  width: min(640px, 100%);
  margin: 16px auto 0;
  color: var(--text-2);
  font-size: var(--fs-xs);
  font-weight: 500;
}
.stage-labels span:first-child { grid-column: 1; text-align: center; }
.stage-labels span:last-child { grid-column: 3; text-align: center; }

@media (max-width: 559px) {
  .actions { flex-direction: column; align-items: stretch; width: 100%; }
  .actions .btn { width: 100%; }
}
```

Keep the scene's internal rules (`.cloud`, `.arc`, `.drive`, `.slot`, `.light`, `.glow`) exactly as they are. The new tokens recolor them.

### 5.4 Shared section and heading styles

```css
.section { padding: var(--space-section) 0; }

.section-head { max-width: 720px; margin: 0 auto clamp(40px, 5vw, 64px); text-align: center; }
.h2 {
  font-family: var(--font-display);
  font-size: var(--fs-h2);
  font-weight: 700;
  line-height: 1.08;
  letter-spacing: -0.03em;
  text-wrap: balance;
}
.section-sub { margin-top: 14px; color: var(--text-2); font-size: var(--fs-sub); text-wrap: balance; }
```

### 5.5 How it works (moves up, directly after the hero)

```html
    <section class="section" id="how" aria-labelledby="how-title">
      <div class="wrap">
        <div class="section-head">
          <h2 class="h2" id="how-title">How it works</h2>
          <p class="section-sub">Connect, pick, export. That’s it.</p>
        </div>
        <ol class="steps" data-reveal>
          <li>
            <span class="num" aria-hidden="true">01</span>
            <h3>Connect a drive.</h3>
            <p>Any external drive or SSD.</p>
          </li>
          <li>
            <span class="num" aria-hidden="true">02</span>
            <h3>Pick your photos.</h3>
            <p>iCloud Photos, or Photos on this Mac.</p>
          </li>
          <li>
            <span class="num" aria-hidden="true">03</span>
            <h3>Export.</h3>
            <p>Full-quality originals land on your drive, organized by date.</p>
          </li>
        </ol>
      </div>
    </section>
```

```css
.steps {
  display: grid;
  grid-template-columns: repeat(3, 1fr);
  gap: 0 32px;
  max-width: 1000px;
  margin: 0 auto;
  list-style: none;
}
.steps li { padding-top: 24px; border-top: 1px solid var(--border-strong); }
.steps .num {
  display: block;
  margin-bottom: 40px;
  color: var(--text-3);
  font-size: var(--fs-xs);
  font-weight: 600;
  letter-spacing: 0.08em;
  font-variant-numeric: tabular-nums;
}
.steps h3 { margin-bottom: 6px; font-size: 1.25rem; font-weight: 600; letter-spacing: -0.015em; line-height: 1.3; }
.steps p { color: var(--text-2); }
@media (max-width: 759px) {
  .steps { grid-template-columns: 1fr; gap: 32px; }
  .steps .num { margin-bottom: 16px; }
}
```

### 5.6 Features: bento grid

```html
    <section class="section" id="features" aria-labelledby="features-title">
      <div class="wrap">
        <div class="section-head">
          <h2 class="h2" id="features-title">Everything your photos need</h2>
          <p class="section-sub">Get your library out of the cloud and keep it safe.</p>
        </div>
        <ul class="tiles">
          <!-- the five <li class="tile" data-reveal> … </li> items, copy verbatim from current file (same order, same SVGs, same h3/p) -->
        </ul>
        <p class="tiles-note">Free. No account, no sign-up.</p>
      </div>
    </section>
```

Do **not** add classes to `<li class="tile" data-reveal>`, because the tests match `class="tile"` exactly. The layout uses `:nth-child`.

```css
.tiles {
  display: grid;
  grid-template-columns: repeat(6, 1fr);
  gap: 16px;
  list-style: none;
}
.tile {
  grid-column: span 2;
  display: flex;
  flex-direction: column;
  padding: 8px;
  border: 1px solid var(--border);
  border-radius: var(--r-lg);
  background: var(--surface);
}
.tile:nth-child(-n+2) { grid-column: span 3; }
.tile-art {
  aspect-ratio: 2 / 1;
  border: 1px solid var(--border);
  border-radius: var(--r-md);
  background: var(--art-bg);
  overflow: hidden;
}
.tile:nth-child(-n+2) .tile-art { aspect-ratio: 16 / 7; }
.tile-art svg { width: 100%; height: 100%; }
.tile h3 { padding: 18px 12px 0; font-size: var(--fs-body); font-weight: 600; letter-spacing: -0.01em; line-height: 1.3; }
.tile p { padding: 4px 12px 14px; color: var(--text-2); font-size: var(--fs-small); }

.tiles-note { margin-top: 32px; text-align: center; color: var(--text-2); font-size: var(--fs-small); }

@media (max-width: 1023px) {
  .tiles { grid-template-columns: repeat(2, 1fr); }
  .tile, .tile:nth-child(-n+2) { grid-column: span 1; }
  .tile:nth-child(5) { grid-column: span 2; }
  .tile:nth-child(-n+2) .tile-art { aspect-ratio: 2 / 1; }
  .tile:nth-child(5) .tile-art { aspect-ratio: 4 / 1; }
}
@media (max-width: 639px) {
  .tiles { grid-template-columns: 1fr; }
  .tile:nth-child(5) { grid-column: auto; }
  .tile:nth-child(5) .tile-art { aspect-ratio: 2 / 1; }
}
```

Keep **all** `.tile-art …` illustration rules (`.cloud-shape`, `.drive-body`, `.slot`, `.light`, `.c1`–`.c8`, `.track`, `.ring`, `.check`, `.plug-*`, `.cal`, `.cal-rule`, `.day`, `.range`, `.pick`, `.pin-*`, `.tick`, `.tick-mark`, `.label`, `.value`, `.cnt*`) exactly as they are.

### 5.7 Privacy: inverted statement panel

```html
    <section class="section privacy" id="privacy" aria-labelledby="privacy-title">
      <div class="wrap">
        <div class="privacy-panel" data-reveal>
          <span class="lock-chip" aria-hidden="true">
            <svg class="lock" viewBox="0 0 24 24" aria-hidden="true" focusable="false"><rect x="5" y="10.5" width="14" height="10" rx="2.5"/><path d="M8 10.5V8a4 4 0 0 1 8 0v2.5"/></svg>
          </span>
          <h2 class="h2" id="privacy-title">Your photos stay yours</h2>
          <ul class="privacy-list">
            <li>Photos go straight from Apple to your drive.</li>
            <li>Uncloud never sees, stores or uploads them.</li>
            <li>No ads. No tracking. Not even on this page.</li>
          </ul>
        </div>
      </div>
    </section>
```

```css
.privacy { padding-top: 0; }
.privacy-panel {
  position: relative;
  overflow: hidden;
  padding: clamp(48px, 7vw, 96px) clamp(20px, 5vw, 72px);
  border: 1px solid var(--panel-border);
  border-radius: var(--r-xl);
  background: radial-gradient(60% 80% at 50% 0%, var(--panel-glow), transparent 70%), var(--panel-bg);
  color: var(--panel-text);
  text-align: center;
}
.lock-chip {
  display: inline-grid;
  place-items: center;
  width: 56px;
  height: 56px;
  margin-bottom: 24px;
  border: 1px solid var(--panel-border);
  border-radius: var(--r-md);
  background: rgba(255, 255, 255, 0.04);
}
.lock {
  width: 26px;
  height: 26px;
  fill: none;
  stroke: var(--panel-text);
  stroke-width: 1.6;
  stroke-linecap: round;
  stroke-linejoin: round;
}
.privacy-list {
  display: grid;
  grid-template-columns: repeat(3, 1fr);
  gap: 24px;
  max-width: 920px;
  margin: 48px auto 0;
  list-style: none;
  text-align: left;
}
.privacy-list li {
  padding-top: 16px;
  border-top: 1px solid var(--panel-border);
  color: var(--panel-text-2);
  font-size: 1rem;
  line-height: 1.5;
}
@media (max-width: 759px) {
  .privacy-list { grid-template-columns: 1fr; gap: 16px; margin-top: 32px; }
}
```

`.privacy { padding-top: 0; }` is there because the features section above already gives the spacing. The panel sits flush below it.

### 5.8 Install: one segmented panel

```html
    <section class="section" id="install" aria-labelledby="install-title">
      <div class="wrap">
        <div class="section-head">
          <h2 class="h2" id="install-title">Install in three steps</h2>
          <p class="section-sub">Takes about a minute.</p>
        </div>
        <ol class="install-steps" data-reveal>
          <!-- the three <li class="install-card"> … </li> items, copy verbatim from current file -->
        </ol>
      </div>
    </section>
```

The opening tag must stay exactly `<section class="section" id="install"`, because a test matches it.

```css
.install-steps {
  display: grid;
  grid-template-columns: repeat(3, 1fr);
  max-width: 1000px;
  margin: 0 auto;
  list-style: none;
  border: 1px solid var(--border);
  border-radius: var(--r-xl);
  background: var(--surface);
  overflow: hidden;
}
.install-card { padding: 32px 28px; }
.install-card + .install-card { border-left: 1px solid var(--border); }
.install-card .num {
  display: inline-grid;
  place-items: center;
  width: 28px;
  height: 28px;
  margin-bottom: 20px;
  border-radius: 50%;
  background: var(--ink);
  color: var(--on-ink);
  font-size: var(--fs-xs);
  font-weight: 700;
}
.install-card h3 { margin-bottom: 6px; font-size: var(--fs-body); font-weight: 600; letter-spacing: -0.01em; }
.install-card p { color: var(--text-2); font-size: var(--fs-small); }
@media (max-width: 759px) {
  .install-steps { grid-template-columns: 1fr; }
  .install-card { padding: 24px 20px; }
  .install-card + .install-card { border-left: 0; border-top: 1px solid var(--border); }
}
```

### 5.9 Questions

```html
    <section class="section" id="faq" aria-labelledby="faq-title">
      <div class="wrap">
        <div class="section-head">
          <h2 class="h2" id="faq-title">Questions</h2>
        </div>
        <div class="faq" data-reveal>
          <!-- the five <details> … </details> items, copy verbatim from current file -->
        </div>
      </div>
    </section>
```

```css
.faq { max-width: 760px; margin: 0 auto; border-top: 1px solid var(--border); }
.faq details { border-bottom: 1px solid var(--border); }
.faq summary {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 24px;
  min-height: 64px;
  padding: 18px 0;
  font-size: var(--fs-body);
  font-weight: 600;
  letter-spacing: -0.01em;
  cursor: pointer;
  list-style: none;
  border-radius: var(--r-sm);
}
.faq summary::-webkit-details-marker { display: none; }
.faq summary::after {
  content: "";
  flex: 0 0 auto;
  width: 16px;
  height: 16px;
  background:
    linear-gradient(var(--text-2), var(--text-2)) center / 12px 1.5px no-repeat,
    linear-gradient(var(--text-2), var(--text-2)) center / 1.5px 12px no-repeat;
}
.faq details[open] summary::after { transform: rotate(45deg); }
.faq details p { max-width: 62ch; padding: 0 40px 24px 0; color: var(--text-2); }
```

This is a plus sign that turns into × when open. The old chevron rule is removed.

### 5.10 Closing CTA panel

```html
    <section class="cta" aria-labelledby="cta-title">
      <div class="wrap">
        <div class="cta-panel" data-reveal>
          <img class="cta-icon" src="icon.png" srcset="icon.png 1x, icon@2x.png 2x" width="80" height="80" alt="" decoding="async" loading="lazy">
          <h2 class="h2" id="cta-title">Ready to take your photos home?</h2>
          <div class="actions">
            <a class="btn btn-lg" href="https://github.com/bariscoach/Uncloud/releases/latest/download/Uncloud.dmg">
              <svg class="btn-icon" viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="M12 4v11"/><path d="M7.5 10.5 12 15l4.5-4.5"/><path d="M5 19.5h14"/></svg>
              <span class="btn-label">Download <span class="sr-only">Uncloud </span>for Mac</span>
            </a>
          </div>
          <p class="meta">Free. macOS 14 or later.</p>
        </div>
      </div>
    </section>
```

```css
.cta { padding: 0 0 var(--space-section); }
.cta-panel {
  display: flex;
  flex-direction: column;
  align-items: center;
  padding: clamp(56px, 8vw, 96px) clamp(20px, 5vw, 64px);
  border: 1px solid var(--border);
  border-radius: var(--r-xl);
  background:
    radial-gradient(50% 70% at 50% 0%, var(--glow-sky), transparent 70%),
    radial-gradient(40% 60% at 80% 100%, var(--glow-sun), transparent 70%),
    var(--surface);
  text-align: center;
}
.cta-icon { width: 80px; height: 80px; margin-bottom: 28px; filter: drop-shadow(0 12px 24px rgba(0, 0, 0, 0.18)); }
.cta-panel .actions { margin-top: 32px; }
.cta-panel .meta { margin-top: 16px; }
```

There are now exactly **three** DMG links: top bar, hero and CTA panel. The ghost button points to `#install`.

### 5.11 Footer

```html
  <footer class="footer">
    <div class="wrap">
      <div class="footer-row">
        <p class="copy">© 2026 Uncloud</p>
        <ul class="footer-links">
          <!-- the four <li> links, copy verbatim from current file -->
        </ul>
      </div>
      <p class="made">Made by Baris Hiz. For inquiries and sponsorship: <a href="mailto:barishiz@gmail.com">barishiz@gmail.com</a></p>
      <p class="disclaimer">Uncloud is an independent app and is not affiliated with, endorsed, sponsored, or approved by Apple Inc. Apple, iCloud, iCloud Photos and Mac are trademarks of Apple Inc., registered in the U.S. and other countries and regions.</p>
    </div>
  </footer>
```

```css
.footer { padding: 32px 0 56px; border-top: 1px solid var(--border); color: var(--text-2); font-size: 0.875rem; }
.footer-row { display: flex; flex-wrap: wrap; align-items: center; justify-content: space-between; gap: 8px 24px; }
.footer-links { display: flex; flex-wrap: wrap; gap: 0 20px; list-style: none; }
.footer-links a { display: inline-flex; align-items: center; min-height: 44px; color: var(--text-2); text-decoration: none; }
.made { margin-top: 16px; }
.made a { color: var(--text-2); text-decoration: underline; text-decoration-color: var(--border-strong); text-underline-offset: 3px; }
.disclaimer { max-width: 680px; margin-top: 8px; color: var(--text-2); font-size: var(--fs-xs); }
@media (hover: hover) {
  .footer-links a:hover, .made a:hover { color: var(--text); }
}
@media (max-width: 559px) {
  .footer-row { flex-direction: column; align-items: flex-start; }
}
```

The disclaimer uses `--text-2`, not `--text-3`: `--text-3` fails AA at 13px.

### 5.12 Final `<main>` order

```
<main id="main">
  hero → #how → #features → #privacy → #install → #faq → .cta
</main>
```

---

## 6. Motion

Replace the whole `@media (prefers-reduced-motion: no-preference) { … }` block with the block below. Inside it, keep the hero-logo, scene and tile-illustration rules verbatim.

```css
@media (prefers-reduced-motion: no-preference) {

  html { scroll-behavior: smooth; }

  /* Hero entrance: children rise in, one after another. */
  .hero-inner > * { animation: rise var(--dur-slow) var(--ease-out) both; }
  .hero-inner > :nth-child(2) { animation-delay: 60ms; }
  .hero-inner > :nth-child(3) { animation-delay: 120ms; }
  .hero-inner > :nth-child(4) { animation-delay: 180ms; }
  .hero-inner > :nth-child(5) { animation-delay: 240ms; }
  .hero-inner > :nth-child(6) { animation-delay: 300ms; }
  .hero-inner > :nth-child(7) { animation-delay: 420ms; }

  /* Scroll reveal: only hidden when app.js has set html.js. */
  html.js [data-reveal] {
    opacity: 0;
    transform: translateY(24px);
    transition: opacity var(--dur-slow) var(--ease-out), transform var(--dur-slow) var(--ease-out);
  }
  html.js [data-reveal].is-in { opacity: 1; transform: none; }

  html.js .tiles > .tile:nth-child(2) { transition-delay: 60ms; }
  html.js .tiles > .tile:nth-child(3) { transition-delay: 120ms; }
  html.js .tiles > .tile:nth-child(4) { transition-delay: 180ms; }
  html.js .tiles > .tile:nth-child(5) { transition-delay: 240ms; }

  /* Install numbers pop in one after another (keep from current file). */
  html.js .install-steps .num {
    opacity: 0;
    transform: scale(0.4);
    transition: opacity 400ms ease-out, transform 500ms var(--ease-out);
  }
  html.js .install-steps.is-in .num { opacity: 1; transform: none; }
  .install-card:nth-child(2) .num { transition-delay: 180ms; }
  .install-card:nth-child(3) .num { transition-delay: 360ms; }

  /* Buttons */
  .btn { transition: transform var(--dur-fast) var(--ease-out), background-color var(--dur) var(--ease-out), border-color var(--dur) var(--ease-out); }
  .btn:active { transform: scale(0.98); }
  .topnav a { transition: color var(--dur) var(--ease-out), background-color var(--dur) var(--ease-out); }

  /* FAQ: plus turns into ×, the answer fades in. */
  .faq summary::after { transition: transform var(--dur) var(--ease-out); }
  .faq details[open] p { animation: fade-in 320ms var(--ease-out) both; }

  /* KEEP VERBATIM from the current file:
     .hero-cloud, .hero-sun, .hero-motion, .hero-rays,
     .glow, .photo, .photo-1 … .photo-5,
     every .tile-art … animation rule (ph, light, range, plug, ring, check, pin, del-card, del-tick, cnt-0/1/2). */

}
```

**Removed:** `.hero-icon { animation: hero-float … }` (the hero icon now gets `rise` from `.hero-inner > *`), `.hero-cta::before` glow-pulse, and the `.hero-cta .btn` hover lift and shadow.

Keyframes: delete `hero-float` and `glow-pulse`, keep all the others, and add these two:

```css
@keyframes rise {
  from { opacity: 0; transform: translateY(12px); }
  to { opacity: 1; transform: none; }
}

@keyframes fade-in {
  from { opacity: 0; transform: translateY(-4px); }
  to { opacity: 1; transform: none; }
}
```

Keep the final `@media (prefers-reduced-motion: reduce)` block exactly as it is. With reduced motion, nothing moves and everything shows its final state. Hero children have no hidden base state, because the `both` fill only applies inside the no-preference block.

Durations: entrance 800ms with a 60ms stagger (420ms for the stage); reveal 800ms; buttons 160ms; FAQ 240ms/320ms. Only `transform` and `opacity` animate. Color transitions are plain `transition`s, which are allowed.

---

## 7. Mobile (390px) and breakpoints

Breakpoints: **559px** (actions stack, footer stacks), **639px** (tiles go to 1 column), **759px** (top nav hidden, steps, install and privacy go to 1 column), **1023px** (tiles go to 2 columns).

At 390px:
- Gutter is 20px. Top bar: icon, wordmark and a 40px-tall "Download" pill. No nav.
- Hero: 96px icon, eyebrow pill (fits on one line at 13px), h1 at 44px on 2–3 lines with balanced wrapping, then the lede. Download and How to install stack full width (52px tall each, 12px gap), with meta below.
- The stage spans the full width minus the gutters, with about 16px inner padding; the scene and labels scale down with it.
- No horizontal scroll anywhere. The `overflow-x: clip` on body is a safety net, not a fix: if something overflows, fix its width.
- Tiles are one column, each with a 2:1 art box.
- Privacy panel: the list is stacked, left-aligned, with hairlines.
- Install is one stacked panel with horizontal dividers.

---

## 8. Keep list (do not change)

- All `<head>` meta, the title, description, canonical, OG and Twitter tags (only the dark `theme-color` value changes).
- The three DMG links (`https://github.com/bariscoach/Uncloud/releases/latest/download/Uncloud.dmg`) and the accessible name "Download Uncloud for Mac" on the hero and CTA buttons.
- `Version 0.1.25 · macOS 14 or later · All versions` (exact text and link).
- `#install` with `<section class="section" id="install"` and three `<li class="install-card">` items with their copy.
- The five tiles: `<li class="tile" data-reveal>`, their SVG art, titles and lines.
- The FAQ questions and answers verbatim.
- The footer disclaimer sentences verbatim, the "Made by Baris Hiz…" line, © line and the four footer links.
- The hero logo layers in `logo/` with the `.hero-mask` mask, the hero scene SVG, `aria-hidden` on `.hero-icon` and `.scene`.
- `app.js`, unchanged.
- One `h1`.

---

## 9. Test changes (`site/checks/site.test.mjs`)

1. In **"the hero, tiles, FAQ and disclaimer copy are present"**, replace these entries in the list:
   - `'How It Works'` → `'How it works'`
   - `'Everything Your Photos Need'` → `'Everything your photos need'`
   - `'Your Photos Stay Yours'` → `'Your photos stay yours'`
   - keep `'Take Your Photos Home'` (the `<title>` still contains it)
   
   and add after the loop:
   ```js
   assert.ok(html.includes('<h1 id="hero-title">Take your photos home.</h1>'), 'hero h1');
   ```
2. Add a new test:
   ```js
   test('sections have ids and the top bar links to them', () => {
     for (const id of ['how', 'features', 'privacy', 'install', 'faq']) {
       assert.ok(html.includes(`id="${id}"`), `section id ${id}`);
     }
     assert.match(html, /<nav class="topnav" aria-label="Sections">/);
     for (const href of ['#features', '#privacy', '#install', '#faq']) {
       assert.ok(html.includes(`href="${href}"`), `nav link ${href}`);
     }
   });
   ```
3. Add a new test:
   ```js
   test('the hero has a secondary install button and no pulsing glow', () => {
     assert.match(html, /<a class="btn btn-lg btn-ghost" href="#install">/);
     assert.doesNotMatch(css, /glow-pulse|hero-float/);
     assert.doesNotMatch(html, /hero-wordmark/);
   });
   ```
4. Add to the head test: `assert.ok(html.includes('<meta name="theme-color" content="#0A0A0C" media="(prefers-color-scheme: dark)">'));`
5. No other test changes. All existing assertions must still pass: three DMG links, `html.js [data-reveal]`, the no-preference and reduce blocks, no animation outside them, tile regexes, and the Apple-mention whitelist (the new "iCloud Photos" stage label and the eyebrow don't mention Apple).

Copy guard: none of the new copy may include "plan", "price", "Plus", "subscri", "free up", "duplicates", "forever" or "Apple". The new strings are: "Free for Mac · No account needed", "Take your photos home.", "How to install", "iCloud Photos", "Your drive", "Connect, pick, export. That’s it.", "Get your library out of the cloud and keep it safe.", "Takes about a minute.", and the nav labels. All of them pass.

---

## 10. Build checklist (in order)

1. Replace the tokens (section 3) and global CSS (section 4); delete the rules listed in section 4.
2. Top bar HTML and CSS (5.1), then buttons (5.2).
3. Hero HTML and CSS (5.3): remove the hero wordmark and the old "How to install" line, then add the eyebrow, actions with the ghost button, stage and labels.
4. Add the shared section styles (5.4).
5. Reorder `<main>` as in 5.12, rewriting each section's HTML per 5.5–5.10, with `data-reveal` only where shown (remove it from `<section>` elements).
6. Footer (5.11).
7. Motion block and keyframes (section 6).
8. Update the two theme-color metas (5.0).
9. Update the tests (section 9) and run `node --test site/checks`; all must pass.
10. Screenshots: run `scripts/site-shots.sh <scratch>/shots` and Read the desktop and hero PNGs in light and dark.
11. **True 390px check.** Headless Chrome's minimum window is 500px, so phone-*.png is not a real 390px render. In your scratchpad, create `frame/index.html` containing exactly:
    `<!doctype html><meta charset="utf-8"><body style="margin:0"><iframe src="http://127.0.0.1:8911/" width="390" height="2400" style="border:0;display:block"></iframe>`
    (this is a scratch file outside `site/`, so the CSP rule doesn't apply). Serve `site/` on port 8911 and the frame folder on port 8912 with `python3 -m http.server`, then run Chrome with `--headless=new --window-size=500,2400 --virtual-time-budget=4000 --screenshot=<scratch>/p390.png http://127.0.0.1:8912/`. Add `--force-dark-mode --blink-settings=preferredColorScheme=0` for dark. Kill both servers afterwards. Scroll-revealed sections lower down may look faded in this shot because of how the iframe works; only judge layout and overflow there.
12. Check against these: one h1; Download is the most prominent element on the first screen in both modes; ink buttons are readable in dark mode (light pill, dark text); no `style=""`, `<style>` or inline scripts; focus ring visible on the nav links, buttons and FAQ summaries (Tab through).
13. Don't commit, push or deploy. Report the deviations.
