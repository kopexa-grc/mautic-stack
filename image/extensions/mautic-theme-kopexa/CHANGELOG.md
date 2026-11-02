# Changelog

## 0.2.0 – 2026-11-02

- Fix: header and footer turned white after an email was saved and reopened in the builder (logo and claim invisible). The builder gives sections without an `mj-class` its white surface token and drops inline attributes equal to MJML's defaults. Header and footer now use their own tokens (`k-navy`, `k-claim`, `k-fine`); `qa/check.mjs` enforces both builder rules.
- Shared tokens for the theme variants: `k-note`, `k-hero`, `k-hero-label`, `k-hero-h1`, `k-hero-lead`.
- New variants in their own packages: *Kopexa · Anmeldung bestätigen* (`kopexa-confirm`, double opt-in with `{doi_link}`) and *Kopexa · Hero + Split* (`kopexa-hero`).

## 0.1.0 – 2026-11-01

- Kopexa email theme for the GrapesJS MJML builder, with header, footer, buttons and typography tokens (`t-*` classes).
- Quality gate in `qa/` (not part of the package). It checks:
  - HTML size and links
  - contrast
  - email client compatibility
  - spam score
  - rendering screenshots
