# Website redesign with a Download button (owner request, 2026-10-23)

Owner: "design the vercel page and give shortcut to download the app on the page"

The site is `site/` (Vercel project "uncloud"). Today it is a "coming soon" page:
- a waitlist form ("Notify Me")
- a pain section, How It Works, the features, privacy, FAQ, a CTA band and a footer

Now the app can be downloaded, so the page becomes a **download page**.

## Download link

- Stable URL: `https://github.com/bariscoach/Uncloud/releases/latest/download/Uncloud.dmg`. The owner publishes each
  DMG as a GitHub release asset named `Uncloud.dmg`.
- Secondary link: "All versions", which goes to `https://github.com/bariscoach/Uncloud/releases`.
- Show the version and requirements next to the button: "Version 0.1.23 · macOS 14 or later · 39 MB". Keep them in
  one place in the HTML so they are easy to bump.

## Structure (top to bottom)

1. **Top bar.**
   - Brand: the logo plus the Plus Jakarta Sans wordmark, as now.
   - Right side: a compact "Download" button that links to the DMG URL.
   - Remove "Get Notified".
2. **Hero.** Keep the animated logo layers, centred.
   - H1 "Take Your Photos Home".
   - Lead: "Export full-quality originals from iCloud Photos to your own drive, without filling up your Mac. Free."
   - Primary button "Download for Mac", large and in the accent colour. It carries the download icon as an inline
     SVG. **No Apple logo.**
   - Under the button, in small muted text: "Version 0.1.23 · macOS 14 or later · All versions".
3. **Install in three steps.** This is a new section with the id `install`, and the hero links to it with "How to
   install". Show three numbered cards:
   1. "Open Uncloud.dmg and drag Uncloud to Applications."
   2. "Open Uncloud from Applications. The first time, if macOS says it can't be opened, go to System Settings ›
      Privacy & Security and click Open Anyway."
   3. "Create your free Uncloud account and sign in to iCloud Photos."
4. **How It Works.** Keep it, and tighten the copy if it mentions the waitlist.
5. **Features.** Keep the five tiles from the last change:
   - Export from iCloud
   - Export Photos by Date
   - Automatic backups
   - Browse Backup
   - Delete from iCloud

   Use a responsive grid: 3, then 2, then 1 column.
6. **Privacy.** Keep it.
7. **FAQ.** Keep it and update:
   - Remove the waitlist answers.
   - Add "Why does macOS warn me the first time?": "This test build isn't notarized by Apple yet. Use Open Anyway
     in System Settings › Privacy & Security once."
   - Add "Is it free?": "Yes. Create an Uncloud account in the app."
8. **CTA band.** "Ready to take your photos home?" with the same Download button.
9. **Footer.** Keep Terms, Privacy and Contact, and add GitHub (the releases URL).

**Remove:** the waitlist forms and their JS (`app.js`) **only if** nothing else needs it. If the waitlist JS is used
only by the forms, delete it and the `connect-src` stays harmless. Also remove "Coming soon" from the meta
description and OG text.

## Visual design

- Apple-like and calm. Use the existing tokens and colours in `styles.css`, in light and dark (`prefers-color-scheme`).
  Generous whitespace and one accent colour.
- Phone width: 16px gutters, no horizontal scroll, and buttons full width under 480px.
- Visible focus rings. The buttons are real `<a>` links with an accessible name ("Download Uncloud for Mac").
- Keep the current rules: no inline scripts or styles and no third-party scripts or fonts. Add one allowed outbound
  origin, `https://github.com`, for links only.
- Keep the OG image and favicons.

## Checks

- Update `site/checks/site.test.mjs` for the new copy:
  - title and description without "Coming soon"
  - `github.com` allowed for links
  - the download link present at least twice (the hero and the CTA band)
  - the install section present
- Run `node --test site/checks` and make sure it passes.
- Take screenshots at 1280 and 390 widths in light and dark, using a headless browser if one is available locally,
  such as `npx playwright` or Chrome with `--headless --screenshot`. Look at them. If no browser is available, say so.

## Constraints

- Don't deploy. The owner deploys.
- Don't touch `server/`.
- No secrets.
