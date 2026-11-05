# Our extensions: repositories and releases

| Package | Repository | Packagist | What for |
|---|---|---|---|
| `kopexa/mautic-oauth-bundle` | [kopexa-grc/mautic-oauth-bundle](https://github.com/kopexa-grc/mautic-oauth-bundle) | [link](https://packagist.org/packages/kopexa/mautic-oauth-bundle) | OAuth 2.1 authorization server ([docs/oauth.md](oauth.md)) |
| `kopexa/mautic-mcp-bundle` | [kopexa-grc/mautic-mcp-bundle](https://github.com/kopexa-grc/mautic-mcp-bundle) | [link](https://packagist.org/packages/kopexa/mautic-mcp-bundle) | MCP server for AI assistants ([docs/mcp.md](mcp.md)) |
| `kopexa/mautic-postal-bundle` | [kopexa-grc/mautic-postal-bundle](https://github.com/kopexa-grc/mautic-postal-bundle) | [link](https://packagist.org/packages/kopexa/mautic-postal-bundle) | Postal bounce webhooks ([docs/postal.md](postal.md)) |
| `kopexa/mautic-preferences-center` | [kopexa-grc/mautic-preferences-center](https://github.com/kopexa-grc/mautic-preferences-center) | [link](https://packagist.org/packages/kopexa/mautic-preferences-center) | Topics, hidden topics kept on save, webhooks ([docs/preferences.md](preferences.md)) |
| `kopexa/mautic-theme-kopexa` | this repository, [`image/extensions/mautic-theme-kopexa`](../image/extensions/mautic-theme-kopexa) | – | Kopexa email theme (with fonts, logo, placeholder images, QA tooling); internal, not published |
| `kopexa/mautic-theme-kopexa-confirm`, `-hero` | this repository, `image/extensions/mautic-theme-kopexa-*` | – | variants of the theme (a Mautic theme holds one email template); use the base theme's assets |
| `kopexa/mautic-theme-kopexa-page` | this repository, [`image/extensions/mautic-theme-kopexa-page`](../image/extensions/mautic-theme-kopexa-page) | – | Kopexa landing page theme (white base, mobile first); uses the base theme's fonts and logo |

The three bundles live in their own repositories, with their history from
this one. Each one has:

- **CI**: lint, `composer validate`, version consistency (`bin/check.sh`).
- **Releases** with [release-please](https://github.com/googleapis/release-please):
  - Conventional commits on `main` keep a release PR open, which bumps
    `VERSION`, the plugin version and `CHANGELOG.md`.
  - Merging it tags `v<version>`, creates the GitHub release and notifies
    Packagist.
- **Renovate**:
  - Composer constraint updates are `fix(deps):` and are released.
  - GitHub Actions updates are `ci:`, automerged and not released.

## How the image gets them

[`image/plugins.txt`](../image/plugins.txt) pins the released versions
(`kopexa/mautic-mcp-bundle:0.4.0`, …), installed from Packagist. Renovate
opens a grouped PR for new releases. Our smoke test then exercises them end
to end:

- OAuth flow
- MCP tools and campaign scenarios
- Postal webhooks

The PR is merged automatically when that is green.

So a change to a bundle goes like this:

1. PR with a conventional commit in the bundle's repository, merge.
2. Merge the release PR that release-please opens. That tags the release
   and Packagist updates.
3. Renovate updates `image/plugins.txt` here. The smoke test decides, and
   the PR is automerged when it is green.

## Testing unreleased bundle changes in the image

Place a checkout in `image/extensions/` (ignored by git); it replaces the
pinned release in the build:

```bash
git clone https://github.com/kopexa-grc/mautic-mcp-bundle image/extensions/mautic-mcp-bundle
docker build -t mautic:dev image
test/smoke.sh mautic:dev
```

Its `VERSION` must satisfy the constraints of the other bundles (e.g. the
MCP bundle requires `kopexa/mautic-oauth-bundle` `^0.2`).

## Packagist updates

The packages are on Packagist. New tags reach Packagist in two ways.
Either is enough; with both, an update never goes missing.

- **Packagist's GitHub integration** (preferred). Packagist account →
  *Settings → Connect GitHub*. The GitHub OAuth app *Packagist* must also be
  granted access to the `kopexa-grc` organisation. Then Packagist creates
  the webhooks itself; *Your packages* no longer shows "not auto-updated".
- **Release workflow.** After release-please creates a release, each
  repository calls Packagist's update API. This needs the
  organisation secrets `PACKAGIST_USERNAME` and `PACKAGIST_API_TOKEN`
  (Packagist → *Profile → Show API Token*, the main token), made available
  to the three bundle repositories. Without them the step is skipped.

## Mautic Marketplace (optional)

The marketplace lists Packagist packages of type `mautic-plugin`. While it
is in beta, packages need to be allowlisted; see Mautic's developer docs
([listing a plugin](https://devdocs.mautic.org/en/7.0/marketplace/listing.html)).

Packagist links are `nofollow`. The value is the listing and the people
who find Kopexa through it, not search-engine link equity.
