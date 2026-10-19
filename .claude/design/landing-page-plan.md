# Uncloud Landing Page ("Coming Soon") — Plan + Final Copy

Branch `feature/duplicates-and-icloud-cleanup`, at c6b542f. Plan only. One build chunk, at the end.

Owner: *"let's build it [a one-page website] with a coming soon message. use simple language, highlight key
features but not long sentences. Use your marketing PR skills."*

Sources: `polish-plan.md` §2 glossary, `account-paywall-plan.md` and `stripe-payments-plan.md` owner and orchestrator
decisions, `export-new-only-plan.md`, `Uncloud/Views/Account/WelcomeView.swift`, `PaidFeature` in
`Uncloud/Account/AccountTypes.swift`, `server/uncloud-api/lib/*`, `server/supabase/migrations/*`.

---

## 0. Decisions at a glance

| Topic | Decision |
|---|---|
| Message | One idea: your photos, on your own drive, at full quality, without filling your Mac. |
| Headline | **Take Your Photos Home** (the app's Welcome hero, so the site and app match). |
| Tone | Short, plain, calm. One idea per line. No hype words ("revolutionary", "seamless", "effortless"). |
| Free claim | "**Export is free.**" No "forever". "Forever" is a promise about the future, and the owner hasn't made it. If the owner approves, change the line to "Export is free. Always." in one place (§1.7). |
| Price | "$9.99/year + tax". "Renew every year, or buy one year at a time." No trial, so no trial copy. |
| Dates | None. "Coming soon to Mac" only. |
| Social proof | None. No testimonials, counts or logos. |
| Trademarks | No Apple logo, no SF Symbols (they are Apple's licensed glyphs; draw our own SVGs), no Apple-style device art. "iCloud", "Photos" and "Mac" appear only as descriptions, never first in the hero, never in the brand slot. Footer disclaimer on the page. |
| "Already joined" | The API answers the same for new and existing emails. The "already on the list" message comes only from this browser's own memory (`localStorage`), never from the server. |
| Tracking | None. No analytics, no cookies, no third-party requests. The privacy block can then say so truthfully. |
| Hosting | Static `site/` → Vercel project **`uncloud`** → `https://uncloud.vercel.app` (fallbacks in §4). The form posts to `https://uncloud-api.vercel.app/v1/waitlist`. |

---

## 1. Final page copy

Typography rules for the builder: curly apostrophes and quotes (’ “ ”), US English, sentence case for body and Title
Case for headings, as in the app. Prefer no em dashes in body copy. Copy below is final. Paste it exactly.

### 1.1 Head metadata

- `<title>`: **Uncloud: Take Your Photos Home**
- `<meta name="description">`: **Export full-quality originals from iCloud Photos to your own drive, without filling up your Mac. Coming soon to Mac.**
- Open Graph
  - `og:title`: **Uncloud: Take Your Photos Home**
  - `og:description`: **Full-quality originals from iCloud, straight to your own drive. Coming soon to Mac.**
  - `og:type`: `website`; `og:url`: `https://uncloud.vercel.app/`; `og:site_name`: `Uncloud`
  - `og:image`: `https://uncloud.vercel.app/og.png` (1200 × 630, absolute URL); `og:image:alt`: **Uncloud app icon with the words “Take Your Photos Home”**
- Twitter: `twitter:card` = `summary_large_image`; `twitter:title` and `twitter:description` the same as OG.
- `<meta name="theme-color" content="#FFFFFF" media="(prefers-color-scheme: light)">` and `#111214` for dark.
- `<meta name="color-scheme" content="light dark">`. `<html lang="en">`. Canonical `https://uncloud.vercel.app/`.
- Favicon: `favicon.png` (64 × 64) + `favicon-32.png`, `apple-touch-icon.png` (180 × 180), all from
  `Uncloud/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png` via `sips -z`.

### 1.2 Top bar

- Left: app icon (28 px) + wordmark **Uncloud**.
- Right: a quiet text button **Get Notified** that jumps to `#notify`, the hero form.

### 1.3 Hero

- Badge (pill, above the headline): **Coming soon to Mac**
- H1: **Take Your Photos Home**
- Subhead (one line on desktop): **Export every photo from iCloud to your own drive. Full quality, without filling up your Mac.**
- Form block `id="notify"` (see §1.4)
- Under the form, a muted spec line: **For macOS Sonoma 14 or later**

### 1.4 Email sign-up

| Element | Copy |
|---|---|
| Form heading (visible, small, above the field) | **Get notified at launch** |
| Field label (visible to screen readers, `for=` linked; visually the heading serves sighted users) | **Email address** |
| Placeholder | **you@example.com** |
| Button | **Notify Me** |
| Button while sending | **Joining…** (disabled) |
| Privacy microcopy (under the field) | **One email when we launch. No spam. We never share your address.** |
| Success (new or existing, from the server) | **You’re on the list. We’ll email you when Uncloud is ready.** |
| Already joined (this browser joined before; shown on load in place of the form, with a "Use a different email" link that shows the form again) | **You’re already on the list. See you at launch.** |
| Invalid email (client check or server 400) | **Enter a valid email address.** |
| Rate limited (429) | **Too many tries. Try again in a few minutes.** |
| Network or server error | **Couldn’t add you just now. Check your connection and try again.** |
| No JavaScript (`<noscript>`) | **Turn on JavaScript to join the list.** |

Messages appear in one `role="status" aria-live="polite"` line under the button. Errors also set `aria-invalid="true"`
on the field and `aria-describedby` to the message. On success the form is replaced with the success line, and focus
moves to it.

The bottom of the page repeats the CTA (§1.10) with a second copy of the same form (same JS, its own ids).

### 1.5 "Sound familiar?" (pain strip; four short lines, no icons, muted)

Heading: **Sound familiar?**

- **iCloud storage full. Again.**
- **Your Mac is too small to hold your library.**
- **Big exports stall halfway through.**
- **iCloud.com deletes only 1,000 photos at a time.**

Closing line under them, in the accent colour: **Uncloud fixes all four.**

### 1.6 How it works (3 steps, numbered)

Heading: **How It Works**

1. **Connect a drive.** Any external drive or SSD.
2. **Pick your photos.** iCloud Photos, or Photos on this Mac.
3. **Export.** Full-quality originals land on your drive, organized and checked.

### 1.7 Key features (8 tiles; title ≤ 3 words, line ≤ 10 words)

Heading: **Everything Your Photos Need**

| # | Tile title | Line | Badge |
|---|---|---|---|
| 1 | **Full-Quality Originals** | The real files, never compressed copies. | Free |
| 2 | **Skips Your Mac** | Photos go to your drive. Your Mac stays roomy. | Free |
| 3 | **Never Twice** | Next time, only new photos are exported. | Free |
| 4 | **Picks Up Again** | Interrupted? It resumes right where it stopped. | Free |
| 5 | **Neatly Organized** | Folders by month, year or album. | Free |
| 6 | **Automatic Backups** | Plug in your drive. New photos back up. | Plus |
| 7 | **Browse Backup** | Find any photo by date or on a map. | Plus |
| 8 | **Clean Up iCloud** | Delete backed-up photos in bulk. No 1,000 limit. | Plus |

Badge copy is exactly **Free** or **Plus**. Desktop: 4 × 2 grid. Tablet: 2 columns. Phone: 1 column.
Each tile has an inline SVG line icon (24 px, `stroke="currentColor"`, accent-tinted tile behind it, like the app's
`IconTile`): 1 photo-stack, 2 drive, 3 checkmark-in-circle, 4 circular arrow, 5 folder, 6 clock-with-arrow, 7 map pin,
8 cloud-with-minus. Hand-drawn simple paths, not SF Symbols.

### 1.8 Free vs Plus (two cards side by side; stacked on phone)

Heading: **Simple Pricing**

**Card 1: Free**
- Price line: **$0**
- Lead: **Export is free.**
- List:
  - Full-quality originals
  - Organized folders
  - Only new photos next time
  - Resumes after interruptions
  - Export history

**Card 2: Uncloud Plus** (accent border; this is the only accent-bordered card on the page)
- Price line: **$9.99/year** with **+ tax** in smaller muted text beside it
- Lead: **Everything in Free, plus:**
- List:
  - Automatic backups when your drive connects
  - New-photo reminders
  - Browse Backup by date, place or map
  - Find Duplicates
  - Verify Backup
  - Free Up Space on your Mac
  - Clean Up iCloud, with Recover
- Small print: **Renew every year, or buy one year at a time. Cancel anytime.**

No buttons on the cards (nothing to buy yet). Under both cards, centred: **Both come with the app at launch.**

### 1.9 Privacy block (full-width soft surface, lock icon)

Heading: **Your Photos Stay Yours**

- **Photos go straight from Apple to your drive.**
- **Uncloud never sees, stores or uploads them.**
- **No ads. No tracking. Not even on this page.**

### 1.10 FAQ (native `<details>`/`<summary>`; all closed by default)

Heading: **Questions**

1. **When does Uncloud launch?**
   Soon. Join the list and we’ll email you on launch day.
2. **Is it really free?**
   Yes. Export is free. Uncloud Plus adds extra tools for $9.99 a year.
3. **Can Uncloud see my photos?**
   No. Photos go straight from Apple to your drive. They never pass through us.
4. **Will it delete anything from iCloud?**
   Only if you ask. Export never deletes. Clean Up iCloud asks first, and deleted photos stay in Recently Deleted for 30 days.
5. **My library is huge. Will it cope?**
   Yes. It works in steps, resumes after breaks and skips what’s already done.

Then the closing CTA band:
- Heading: **Be First to Take Your Photos Home**
- Second form (same states as §1.4)

### 1.11 Footer

- Links: **Terms** → `https://uncloud-api.vercel.app/terms` · **Privacy** → `https://uncloud-api.vercel.app/privacy` ·
  **Contact** → `mailto:[support email]` (placeholder, same token as `public/privacy.html`; TODO(owner), owner Q5 in the
  payments plan)
- **© 2026 Uncloud**
- Disclaimer (small, muted): **iCloud, Photos and Mac are trademarks of Apple Inc., registered in the U.S. and other countries. Uncloud is not affiliated with Apple.**

### 1.12 Privacy policy addition (the waitlist collects email, so the policy must say so)

Add to `server/uncloud-api/public/privacy.html`, as its own section before "Emails":

> **Launch list**
> If you join the launch list on our website, we keep your email address and the date you joined. We use it only to
> tell you when Uncloud launches. We don’t share it. Email [support email] and we’ll delete it.

---

## 2. Visual spec

### 2.1 Files and structure

```
site/
  index.html          the page (no inline <script> or <style>: CSP)
  styles.css          all CSS, one file, ~10 KB
  app.js              the two forms (~3 KB, no dependencies, plain ES module)
  icon.png            256 × 256 (sips from the 1024 icon)
  icon@2x.png         512 × 512 (hero icon, srcset)
  favicon.png         64 × 64;  favicon-32.png 32 × 32
  apple-touch-icon.png 180 × 180
  og.png              1200 × 630, generated once from og-source.html by headless Chrome (§5)
  og-source.html      source for og.png (excluded from deploy)
  vercel.json         headers + cleanUrls
  .vercelignore       og-source.html, checks/
  checks/site.test.mjs  static checks (node --test), excluded from deploy
```

No frameworks, no build step, no web fonts, no CDNs.

### 2.2 Tokens (CSS custom properties on `:root`)

| Token | Light | Dark |
|---|---|---|
| `--bg` | `#FFFFFF` | `#111214` |
| `--surface` (tiles, cards, privacy band) | `#F5F7FA` | `#1C1E22` |
| `--border` | `#E3E7ED` | `#2C2F35` |
| `--text` | `#1D1D1F` | `#F2F3F5` |
| `--text-2` (secondary, ≥ 4.5:1 on bg and surface) | `#5B6270` | `#A3A9B4` |
| `--accent` (buttons, accent border, badges' fill base) | `#1E6FD9` | `#2A74DC` |
| `--accent-text` (accent used as text: links, "Plus" badge, "fixes all four") | `#1E6FD9` | `#6AA5F2` |
| `--on-accent` | `#FFFFFF` | `#FFFFFF` |
| `--accent-wash` (hero top wash, tile backgrounds) | `rgba(30,111,217,.08)` | `rgba(42,116,220,.16)` |
| `--danger-text` (error message) | `#C0262D` | `#FF7A7F` |

Dark values apply under `@media (prefers-color-scheme: dark)`. `body` sets `background: var(--bg); color: var(--text)`.
Note: `#2A74DC` as small text on `#111214` is only ~4.1:1, so dark mode uses `--accent-text` for any accent text.
White on `#1E6FD9` is ~4.9:1 and on `#2A74DC` ~4.6:1, so the buttons pass.

Type: `font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif`
(the system font; naming the stack is fine, we ship no Apple font files).
Sizes: H1 `clamp(2.25rem, 6vw, 3.75rem)` weight 700, letter-spacing −0.02em; H2 `clamp(1.5rem, 3.5vw, 2.25rem)` 700;
subhead 1.25rem `--text-2`; body 1.0625rem / 1.5; small 0.875rem.
Spacing scale 4/8/12/16/24/32/48/64/96 px. Sections are separated by 96 px (64 px on phone). Content max-width 1080 px,
text blocks max 640 px, centred. Radius: tiles and cards 16 px, buttons and field 10 px, badges 999 px.

### 2.3 Layout, top to bottom

1. **Top bar**: 64 px tall, not sticky, icon + wordmark left, "Get Notified" link right.
2. **Hero**: centred. Accent wash gradient fading from the top (280 px, like WelcomeView). App icon 112 px
   (`icon@2x.png` srcset, `alt=""` since the wordmark names it), then badge, H1, subhead, form, spec line.
   The form is one row on desktop (field 320 px + button), stacked at ≤ 480 px with a full-width button.
3. **Hero visual** below the form (§2.4).
4. **Sound familiar?**: four lines in a 2 × 2 grid (1 column on phone), muted text, closing accent line.
5. **How It Works**: three columns with large accent numerals (1, 2, 3) in 40 px circles; stacked on phone.
6. **Features**: the 8 tiles. Tile = surface background, 16 px radius, 24 px padding, icon tile, title (weight 600),
   line (`--text-2`), badge top-right. Free badges are neutral (border + `--text-2`); Plus badges are accent-wash + `--accent-text`.
7. **Simple Pricing**: two cards, max 760 px together.
8. **Your Photos Stay Yours**: full-width surface band, three lines with a lock SVG.
9. **Questions**: `<details>` list, max 640 px, a chevron that rotates 90° when open (no rotation under reduced motion).
10. **Closing CTA** band + second form.
11. **Footer**.

### 2.4 Hero visual (CSS + inline SVG, `aria-hidden="true"`)

A 560 × 180 px scene (scales with `width: min(560px, 100%)`, `aspect-ratio` kept):
- Left: a soft cloud (SVG path, `--surface` fill, `--border` stroke).
- Right: an external drive (rounded rectangle, `--surface` fill, a tiny accent status light).
- Between them: a dashed arc (SVG path, `--border`), and five small "photo" cards (22 × 18 px rounded rects with a tiny
  sun-and-hill mark and soft accent-to-teal gradients of different hues) that travel along the arc from cloud to drive
  using CSS `offset-path` (with a `transform` keyframe fallback), staggered by 1.2 s, 6 s loop, ease-in-out, fading in at
  the cloud and out at the drive. The drive light pulses gently each time a card lands.
- `@media (prefers-reduced-motion: reduce)`: no animation; the five cards sit still, spaced along the arc, and the light
  is steady.
- No text inside the visual, no Apple device shapes, no Apple cloud logo shape (use a generic three-bump cloud).

### 2.5 Accessibility

- One `h1`; section headings `h2`; tile titles `h3`. Landmarks: `header`, `main`, `footer`; each section `aria-labelledby`.
- Skip link "Skip to sign-up" → `#notify` (visible on focus).
- Visible focus: `:focus-visible { outline: 3px solid var(--accent); outline-offset: 2px; }` on links, buttons,
  field, summaries.
- Field: `type="email" autocomplete="email" inputmode="email" required maxlength="254"`, linked label.
- Honeypot: `<div class="hp" aria-hidden="true"><label>Website <input name="website" tabindex="-1" autocomplete="off"></label></div>`,
  hidden off-screen with CSS (not `display:none`, which some bots skip).
- Contrast: all text ≥ 4.5:1 in both schemes (token table above); badges ≥ 4.5:1.
- Touch targets ≥ 44 px tall. No horizontal scroll at 375 px. Text zoom to 200% doesn't clip.
- `prefers-reduced-motion`: no animation, no smooth scroll.
- Images: decorative icons `alt=""`, SVG icons `aria-hidden="true"`.

### 2.6 Form behaviour (`app.js`)

- On submit: `preventDefault`; trim; check against `/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/` and length ≤ 254; on fail show
  "Enter a valid email address." and focus the field.
- `fetch('https://uncloud-api.vercel.app/v1/waitlist', { method: 'POST', headers: { 'content-type': 'application/json' },
  body: JSON.stringify({ email, website, source }) })`, with a 10 s `AbortController` timeout. `source` is `"landing"`,
  or `"landing-bottom"` for the second form.
- 200 → success line; set `localStorage['uncloud.waitlist'] = '1'` (inside try/catch). 400 → invalid message.
  429 → rate-limit message. Anything else, or a thrown error → network message. Re-enable the button after an error.
- On load, if the flag is set (try/catch), both forms show the "already on the list" line with a "Use a different
  email" button that restores the form.
- The API base URL is one constant at the top of `app.js`.

### 2.7 `site/vercel.json`

```json
{
  "cleanUrls": true,
  "trailingSlash": false,
  "headers": [
    { "source": "/(.*)", "headers": [
      { "key": "Content-Security-Policy", "value": "default-src 'self'; img-src 'self' data:; style-src 'self'; script-src 'self'; connect-src https://uncloud-api.vercel.app; frame-ancestors 'none'; base-uri 'none'; form-action 'none'; object-src 'none'" },
      { "key": "X-Content-Type-Options", "value": "nosniff" },
      { "key": "Referrer-Policy", "value": "strict-origin-when-cross-origin" },
      { "key": "Permissions-Policy", "value": "camera=(), microphone=(), geolocation=(), interest-cohort=()" } ] },
    { "source": "/(.*)\\.(png|css|js)", "headers": [{ "key": "Cache-Control", "value": "public, max-age=3600" }] }
  ]
}
```

---

## 3. Waitlist backend: `POST /v1/waitlist`

Follows `lib/handlers.js` (handler takes `(request, deps)`), `lib/http.js` (`route`, `apiError`, `readJSON`,
`logEvent`), `lib/ratelimit.js` (`enforceRateLimit`, `clientAddress`).

### 3.1 Contract

Request: `POST /v1/waitlist`, `content-type: application/json`, body `{ "email": string, "website"?: string, "source"?: string }`
(16 KB cap via `readJSON`).

| Case | Response |
|---|---|
| Origin header missing or not allowed | `403 { error: { code: "forbidden_origin", message: "This origin is not allowed." } }`, no CORS headers |
| `OPTIONS` preflight from an allowed origin | `204` with CORS headers (below) |
| `OPTIONS` from another origin | `204` without `Access-Control-Allow-Origin` (browser then blocks) |
| Body not a JSON object | `400 bad_request` |
| Honeypot `website` non-empty | `200 { ok: true }`, nothing stored, logged `result: "honeypot"` |
| Invalid email (not a string, trimmed length 3–254, regex above, no control chars) | `400 { error: { code: "invalid_email", message: "Enter a valid email address." } }` |
| Per-IP limit exceeded | `429 rate_limited` |
| Valid, new **or** already on the list | `200 { ok: true }` (identical body, status and headers: no enumeration) |
| Database error | `500 server_error` (via `route`) |

Order: origin check → body → honeypot → validate → rate limits → insert. Rate limiting after validation keeps junk from
burning the bucket, but the honeypot short-circuit comes before it so bots get the cheap path.

Rate limits: `waitlist:ip:<clientAddress>` **5 per hour**, plus a global `waitlist:all` **300 per hour** (bounds a
botnet; tune later). Use `enforceRateLimit` for both.

Normalisation: `email.trim().toLowerCase()` (NFC-normalise first). `source`: kept only if it matches
`/^[a-z0-9_-]{1,32}$/`, otherwise `"landing"`.

Logging: `logEvent({ evt: 'waitlist', result: 'ok' | 'honeypot' | 'invalid' | 'forbidden_origin' })`. Never the
email, never the IP.

### 3.2 CORS

- Allowed origins: env `WAITLIST_ALLOWED_ORIGINS` (comma-separated, exact match, read in `loadConfig` as
  `config.waitlistOrigins`), default `https://uncloud.vercel.app`. Add the custom domain later via the env var only.
- Headers on every response to an allowed origin (success **and** errors, so the page can read the 400/429):
  `Access-Control-Allow-Origin: <origin>`, `Vary: Origin`, `Access-Control-Allow-Methods: POST, OPTIONS`,
  `Access-Control-Allow-Headers: content-type`, `Access-Control-Max-Age: 86400`. No credentials header.
- New `lib/cors.js`: `withCors(handler, { origins })` returns a Vercel handler that answers `OPTIONS` itself, rejects a
  `POST` from a disallowed origin with 403, otherwise calls `route('POST', …)` and copies the CORS headers onto its
  `Response`. Other methods get the existing JSON 405 (with CORS headers when the origin is allowed).

### 3.3 Files

- `server/uncloud-api/api/v1/waitlist.js`: like `me.js`, but `const handler = withCors(route('POST', (r) => waitlist(r, defaultDeps())), …)`
  and `export { handler as GET, handler as POST, handler as PUT, handler as PATCH, handler as DELETE, handler as OPTIONS }`.
  It must not touch Stripe or the signing key (the lazy deps make sure of that).
- `server/uncloud-api/lib/handlers.js`: add `export async function waitlist(request, deps)`.
- `server/uncloud-api/lib/http.js`: add `invalid_email` and `forbidden_origin` to `DEFAULT_MESSAGES`.
- `server/uncloud-api/lib/supabase.js`: add an `ignoreDuplicates` option to `upsert`
  (`prefer: resolution=ignore-duplicates,return=minimal`), so an existing row (and its `created_at`) is left untouched.
- `server/uncloud-api/lib/config.js`: `waitlistOrigins` (non-secret, plain property).
- `server/uncloud-api/test/helpers.js`: `fakeDb` gets a `waitlist` table and honours `ignoreDuplicates`.
- `server/uncloud-api/test/waitlist.test.js`: new.

### 3.4 Migration `server/supabase/migrations/20261018140000_waitlist.sql`

```sql
create table public.waitlist (
  email      text primary key
             check (char_length(email) between 3 and 254 and email = lower(email) and position('@' in email) > 1),
  source     text not null default 'landing' check (source ~ '^[a-z0-9_-]{1,32}$'),
  created_at timestamptz not null default now()
);
alter table public.waitlist enable row level security;
-- No policies: anon and authenticated get nothing. Only the service role (which bypasses RLS) reads or writes.
revoke all on table public.waitlist from public, anon, authenticated;
grant select, insert on table public.waitlist to service_role;
comment on table public.waitlist is 'Launch list emails from the landing page. Service role only.';
```

Mirror the grant/revoke style of `20261018130000_uncloud_plus_hardening.sql`. No user agent, no IP: we don't need
them, and not storing them keeps the privacy line simple. Email as the primary key gives uniqueness with no sequence.

### 3.5 Tests (`node --test`, no network)

1. Valid new email → 200 `{ ok: true }`; one row, lowercased and trimmed; `source` stored; the upsert was called with
   `{ service: true }` and `ignoreDuplicates`.
2. Same email again (different case, spaces) → identical status, body and header set to case 1; still one row; original
   `created_at` kept.
3. Invalid emails (`""`, `"a"`, `"a@b"`, 255 chars, a number, an array, a newline inside) → 400 `invalid_email`, no
   insert, no rate-limit hit.
4. Honeypot filled → 200 `{ ok: true }`, no insert, no rate-limit rpc.
5. Sixth request from one IP within the window → 429 `rate_limited`; a different IP still passes; global limit
   enforced with a low test override.
6. Missing or disallowed `Origin` → 403 `forbidden_origin` with no `Access-Control-Allow-Origin`.
7. `OPTIONS` from the allowed origin → 204 with the exact CORS headers; from another origin → no ACAO.
8. Error responses (400, 429) from an allowed origin carry the CORS headers.
9. `GET` → 405 JSON envelope.
10. A DB failure → 500 `server_error`; the log line contains neither the email nor the IP (assert on the log sink).
11. A bad `source` becomes `"landing"`.
12. Existing suites (`npm test`) still pass, including `pages.test.js` after the privacy.html change.

---

## 4. Hosting

- Separate Vercel project for the static site, **Root Directory `site/`**, framework preset "Other", no build command,
  output = the directory itself. Project name **`uncloud`** → `https://uncloud.vercel.app`.
- `*.vercel.app` names are global. If `uncloud` is taken, Vercel gives a suffixed domain. Then try, in order:
  **`uncloud-app`** → `uncloud-app.vercel.app`, then **`getuncloud`** → `getuncloud.vercel.app`. Whichever is used must
  be put in (a) the API env `WAITLIST_ALLOWED_ORIGINS`, (b) `og:url`, the canonical and the `og:image` URL in
  `index.html`. Nothing else changes.
- The API project (`uncloud-api`) gets `WAITLIST_ALLOWED_ORIGINS` added for Production and Preview, then a redeploy.
  The migration goes up with the existing `supabase db push` flow.
- Custom domain later: add it to the site project, append it to `WAITLIST_ALLOWED_ORIGINS`, update the absolute URLs.
- Reminder (already an open owner question in the payments plan): Vercel Hobby forbids commercial use. A "coming soon"
  page with no sales is a grey area. Move both projects to Pro before launch.
- The page uses `<meta name="robots" content="index,follow">` (unlike the API's `noindex` pages).

Deploy, `db push` and env changes are orchestrator steps after QC review, not part of the Haiku chunk (they need the
owner's CLI sessions).

---

## 5. Build chunk (Haiku): landing page + waitlist API

**Owns**: `site/**` (new), `server/uncloud-api/api/v1/waitlist.js` (new), `server/uncloud-api/lib/{cors.js (new),
handlers.js, http.js, supabase.js, config.js}`, `server/uncloud-api/test/{waitlist.test.js (new), helpers.js}`,
`server/uncloud-api/public/privacy.html` (§1.12 only), `server/supabase/migrations/20261018140000_waitlist.sql` (new).
Touches nothing in `Uncloud/` or `UncloudTests/`.

**Steps**
1. Icons: `sips -z` from `Uncloud/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png` into the sizes in §2.1.
2. Write `site/index.html`, `styles.css`, `app.js` with the §1 copy verbatim and the §2 spec.
3. `og-source.html`: 1200 × 630, `--bg` light, the app icon 200 px left, "Take Your Photos Home" (72 px bold) and
   "Coming soon to Mac" (badge) right, a faint accent wash. Render it:
   `"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new --hide-scrollbars --window-size=1200,630 --screenshot=site/og.png file://$PWD/site/og-source.html`.
4. Backend per §3, migration per §3.4, tests per §3.5.
5. `site/checks/site.test.mjs` (`node --test site/checks`), static checks:
   - doctype, `lang="en"`, charset, viewport, `color-scheme`, `<title>` and description exactly as §1.1, OG/Twitter
     tags present with absolute `og:image`;
   - no inline `<script>` without `src`, no `<style>`, no `style=` attributes; no `http(s)://` resource outside
     `uncloud-api.vercel.app` and `uncloud.vercel.app` (links to terms/privacy are fine);
   - the hero H1, subhead, badge, the four form messages, all 8 tile titles, "$9.99/year", "+ tax", and the full
     disclaimer string appear;
   - the word "Apple" appears only in the privacy block line and the footer disclaimer; no "forever"; no digits that
     look like a date or user count in the hero;
   - every `<input>` has a label; the honeypot input has `tabindex="-1"`;
   - `styles.css` contains `prefers-color-scheme: dark` and `prefers-reduced-motion: reduce`;
   - each tile line ≤ 10 words and each tile title ≤ 3 words (parse the tile markup).
6. Headless render check (record the PNGs in the scratchpad, not the repo). Serve with
   `python3 -m http.server 4173 -d site`, then for each of 1280 × 900 and 375 × 812, light and dark:
   `npx -y playwright@1.48.2 screenshot --channel chrome --full-page --viewport-size "1280,900" --color-scheme dark http://localhost:4173/ <scratch>/site-1280-dark.png`
   (four files: `site-{1280,375}-{light,dark}.png`). Also one reduced-motion check by reading the CSS (static check above).

**Acceptance**
- `cd server/uncloud-api && npm test` passes: all old tests plus the §3.5 list. `node --test site/checks` passes.
- The four screenshots show: no horizontal overflow at 375 px (nothing cut off on the right; the form stacks with a
  full-width button); hero copy readable over the wash in both schemes; tiles 4 × 2 at 1280 and 1 column at 375;
  pricing cards side by side at 1280 and stacked at 375; the dark scheme has no white flashes or unreadable accent
  text; the footer disclaimer is visible.
- Pointing `app.js` at a local `vercel dev` API (or a stub) works through success, invalid, 429 and network error,
  each showing the exact §1.4 strings; a second visit shows "You’re already on the list. See you at launch."
- Keyboard only: Tab reaches the skip link, field, button, FAQ summaries and footer links with a visible ring;
  VoiceOver reads the status message after submit.
- The page makes zero requests to any origin except its own until the form is submitted (check the DevTools network
  panel or the CSP).
- Total transfer for the first load (HTML + CSS + JS + icon) under 150 KB.
- The page has no Apple logo, no SF Symbols and no device art, and doesn't lead with "iCloud", "Photos" or "Mac" in the
  hero or brand position.

**Out of scope**: deploying, `supabase db push`, env changes (orchestrator, after QC), the custom domain, sending launch
emails (later: export the table and send via Resend), an unsubscribe flow (only needed once mail goes out).

---

## 6. Owner questions

1. "Export is free." or "Export is free. Always."? The second is a long-term promise.
2. Support email for the Contact link and the privacy page (the same `[support email]` placeholder used elsewhere).
3. Vercel name: OK to take `uncloud-app` if `uncloud` is taken?
