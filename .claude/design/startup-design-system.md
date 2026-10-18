---
version: alpha
name: Startup
description: Vibrant purple-to-pink gradient energy - modern SaaS, Vercel/Linear-inspired
colors:
  primary: "#7c3aed"
  secondary: "#f5f5f4"
  tertiary: "#7c3aed"
  background: "#ffffff"
  surface: "#f5f3ff"
  elevated: "#ffffff"
  foreground: "#18181b"
  foreground-muted: "#a1a1aa"
  border: "#ddd6fe"
  error: "#dc2626"
  on-primary: "#ffffff"
typography:
  headline-display:
    fontFamily: "'Plus Jakarta Sans', 'Inter', sans-serif"
    fontSize: 3rem
    fontWeight: 700
    lineHeight: 1.25
  headline-lg:
    fontFamily: "'Plus Jakarta Sans', 'Inter', sans-serif"
    fontSize: 2.25rem
    fontWeight: 700
    lineHeight: 1.25
  headline-md:
    fontFamily: "'Plus Jakarta Sans', 'Inter', sans-serif"
    fontSize: 1.875rem
    fontWeight: 700
    lineHeight: 1.25
  headline-sm:
    fontFamily: "'Plus Jakarta Sans', 'Inter', sans-serif"
    fontSize: 1.5rem
    fontWeight: 700
    lineHeight: 1.25
  body-lg:
    fontFamily: "'Inter', system-ui, -apple-system, sans-serif"
    fontSize: 1.125rem
    fontWeight: 400
    lineHeight: 1.5
  body-md:
    fontFamily: "'Inter', system-ui, -apple-system, sans-serif"
    fontSize: 1rem
    fontWeight: 400
    lineHeight: 1.5
  body-sm:
    fontFamily: "'Inter', system-ui, -apple-system, sans-serif"
    fontSize: 0.875rem
    fontWeight: 400
    lineHeight: 1.5
  label-md:
    fontFamily: "'Inter', system-ui, -apple-system, sans-serif"
    fontSize: 0.875rem
    fontWeight: 500
    lineHeight: 1.375
  label-sm:
    fontFamily: "'Inter', system-ui, -apple-system, sans-serif"
    fontSize: 0.75rem
    fontWeight: 500
    lineHeight: 1.375
  label-strong:
    fontFamily: "'Inter', system-ui, -apple-system, sans-serif"
    fontSize: 1rem
    fontWeight: 600
    lineHeight: 1.375
  code-md:
    fontFamily: "'JetBrains Mono', 'Fira Code', monospace"
    fontSize: 0.875rem
    fontWeight: 400
    lineHeight: 1.5
  display-xxl:
    fontFamily: "'Plus Jakarta Sans', 'Inter', sans-serif"
    fontSize: 4.5rem
    fontWeight: 700
    lineHeight: 1
rounded:
  none: 0px
  sm: 0.375rem
  md: 0.5rem
  lg: 0.75rem
  xl: 1rem
  2xl: 1.25rem
  full: 9999px
spacing:
  base: 1rem
  xs: 0.25rem
  sm: 0.5rem
  md: 1rem
  lg: 1.5rem
  xl: 2rem
  2xl: 3rem
  3xl: 4rem
  section: 6rem
components:
  button-primary:
    backgroundColor: "{colors.primary}"
    textColor: "{colors.on-primary}"
    rounded: "{rounded.md}"
    padding: "{spacing.md}"
    typography: "{typography.label-strong}"
  button-secondary:
    backgroundColor: "{colors.secondary}"
    textColor: "{colors.foreground}"
    rounded: "{rounded.md}"
    padding: "{spacing.md}"
    typography: "{typography.label-strong}"
  button-destructive:
    backgroundColor: "{colors.error}"
    textColor: "{colors.on-primary}"
    rounded: "{rounded.md}"
    padding: "{spacing.md}"
    typography: "{typography.label-strong}"
  input-default:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.foreground}"
    borderColor: "{colors.border}"
    rounded: "{rounded.md}"
    padding: "{spacing.sm}"
    typography: "{typography.body-md}"
  card-default:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.foreground}"
    rounded: "{rounded.lg}"
    padding: "{spacing.lg}"
  badge-default:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.foreground-muted}"
    rounded: "{rounded.full}"
    padding: "{spacing.xs}"
    typography: "{typography.label-sm}"
---

# Startup

## Overview

Startup is the marketing-forward preset for early-stage product surfaces. Brighter accents, larger headline scale, more confident shadow elevation. Reads as kinetic without being noisy.

Comfortable density with marketing-scale headline sizes; body text remains at 16px for readability.

## Colors

Startup centers on a single `primary` accent (`#7c3aed`) on a `background` of `#ffffff`. Every accent / surface / foreground pair below has been measured against WCAG 2.1 contrast ratios; ratios at or above 4.5:1 clear AA at body size.

### WCAG contrast pairs

| Pair | Foreground | Background | Ratio | AA body | AA large |
| --- | --- | --- | --- | --- | --- |
| foreground on background | `#18181b` | `#ffffff` | 17.72 | pass | pass |
| foreground on surface | `#18181b` | `#f5f3ff` | 16.15 | pass | pass |
| foreground-muted on background | `#a1a1aa` | `#ffffff` | 2.56 | fail | fail |
| on-primary on primary | `#ffffff` | `#7c3aed` | 5.70 | pass | pass |
| border on background | `#ddd6fe` | `#ffffff` | 1.39 | fail | fail |

## Typography

Display set in **Plus Jakarta Sans** for headline weight and presence; body in **Inter** for sustained reading; **JetBrains Mono** for code, telemetry, and tabular data. Sizes use `clamp()` for fluid scaling between 320px and 1536px viewports so layouts settle without breakpoint-specific overrides.

Eleven typography levels are emitted in the front matter, grouped as headlines (display, lg, md, sm), body (lg, md, sm), labels (md, sm, strong), and code (md). Display runs as large as the 7xl scale token allows; the `display-xxl` level captures it.

## Layout

A 5-breakpoint grid: 640px (sm) -> 768px (md) -> 1024px (lg) -> 1280px (xl) -> 1536px (2xl). Mobile-first: every component renders at 320px and grows up from there. Visual regression baselines exist for each breakpoint so layout drift surfaces in CI.

Spacing follows a 4px base scale (`xs: 4px, sm: 8px, md: 16px, lg: 24px, xl: 32px, 2xl: 48px, 3xl: 64px`) with section-level rhythm at `section: 96px`. Touch targets stay at 44x44px minimum below the lg breakpoint.

## Elevation & Depth

Eight elevation tokens (`none, xs, sm, md, lg, xl, 2xl, inner`) plus role-named aliases (`card`, `card-hover`, `dropdown`, `modal`, `popover`, `toast`, `navbar`, `sidebar`). Shadows are tuned per preset; flat presets like Brutalist use `none` across the board and convey hierarchy through borders or color contrast instead.

Reference values: `sm = 0 1px 3px 0 rgba(124, 58, 237, 0.06)`, `md = 0 4px 6px -1px rgba(124, 58, 237, 0.08), 0 2px 4px -2px rgba(124, 58, 237, 0.04)`, `lg = 0 10px 15px -3px rgba(124, 58, 237, 0.1), 0 4px 6px -4px rgba(124, 58, 237, 0.05)`. Cards default to `sm`, hover lifts to `md`, modals sit at `xl`.

## Shapes

Default component radius is `0.5rem` for buttons, inputs, and badges; `0.75rem` for cards; `9999px` for pill-shaped elements (avatars, badges with rounded variants). Brutalist and Editorial presets override every radius to `0` for a hard, architectural shape language.

## Motion

Snappy: shorter durations, sharper easings. Interactions confirm immediately; nothing lingers.

Per-preset durations: `fast = 100ms`, `normal = 200ms`, `slow = 300ms`. All transitions collapse to `0ms` under `prefers-reduced-motion: reduce`. The Arcana `<FadeIn>`, `<Stagger>`, `<CountUp>`, and `<GradientBorder>` motion primitives respect this token chain end-to-end.

## Components

Arcana ships 108 components in five tiers: primitives (Button, Input, Textarea, Select, Checkbox, Radio, Toggle, Badge, Avatar), composites (Card, Modal, Alert, Toast, Tabs, Accordion, Banner, Skeleton, Spinner, ErrorBoundary), 47 patterns (Navbar, Sidebar, DataTable, Hero, PricingCard, CommandPalette, and more), layout primitives (Stack, HStack, Grid, Container), and editor components (ColorPicker, FontPicker).

The front matter `components` section captures only the most-used atoms (`button-primary`, `button-secondary`, `button-destructive`, `input-default`, `card-default`, `badge-default`). Every property points at a token reference, so a Claude Design import lands with a coherent component layer rather than a flat token dump.

Variants (hover, active, disabled, focus) follow the `<component>-<state>` naming convention from the spec.

## Do's and Don'ts

- Do reference tokens, not literal values. `{colors.primary}` survives theme switches; `#3b82f6` doesn't.
- Do use `primary` for the single most important action per screen. Secondary CTAs use `secondary` or the `outline` variant.
- Do keep WCAG AA contrast (4.5:1 body, 3:1 large text and UI). Every contrast pair in the front matter has been verified.
- Do respect `prefers-reduced-motion`. Every transition collapses to 0ms under the user preference.
- Do scale typography with the fluid clamp() values; avoid breakpoint-specific font-size overrides.
- Don't mix radius scales on the same surface. Buttons and inputs share a radius; cards step up one tier.
- Don't introduce new color literals. Add a token if a hue is missing.
- Don't ship hover-only interactions. Every hover state needs a focus or tap equivalent.
- Don't use shadow elevation for hierarchy in flat presets (Brutalist, Editorial). Use borders or color contrast.
