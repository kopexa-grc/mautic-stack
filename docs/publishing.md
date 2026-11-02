# Publishing the extensions as Composer packages

Our four extensions live in this repository under
[`image/extensions/`](../image/extensions) and are built into the image from
there. They can also be published as standalone Composer packages for any
Mautic 7 installation:

| Package | Type | Mirror repository |
|---|---|---|
| `kopexa/mautic-oauth-bundle` | `mautic-plugin` | `kopexa-grc/mautic-oauth-bundle` |
| `kopexa/mautic-mcp-bundle` | `mautic-plugin` | `kopexa-grc/mautic-mcp-bundle` |
| `kopexa/mautic-postal-bundle` | `mautic-plugin` | `kopexa-grc/mautic-postal-bundle` |
| `kopexa/mautic-theme-kopexa` | `mautic-theme` | `kopexa-grc/mautic-theme-kopexa` |

Development stays here. Each mirror repository is a read-only copy of its
directory, with history, the way Symfony publishes its components.

## How it works

- **Version:** each package has a `VERSION` file. `composer.json` has no
  `version` field, because Packagist takes versions from git tags.
- **Release:** to release, bump `VERSION`, add a `CHANGELOG.md` entry, and
  update the plugin version in `Config/config.php` (and the `VERSION`
  constant of the MCP bundle).
  [`hack/check-packages.sh`](../hack/check-packages.sh) checks all of this
  in CI (`packages` workflow), together with:
  - `composer validate --strict`
  - the license file
  - the constraints between our packages
- **Split:** the `packages` workflow (job `split`) runs on every push to
  `main`. It mirrors each directory with `git subtree split`, pushes it to
  the mirror's `main`, and tags `v<VERSION>` when that tag does not exist
  yet. Packagist picks up the tag.
- **Downloads:** `.gitattributes` keeps tests and QA tooling out of the
  zips.

## One-time setup

Everything below needs accounts or organisation rights, so it is done by
a person. Until then, the `split` job is skipped.

1. **Create the four mirror repositories** in `kopexa-grc`. Names are as in
   the table above. Make them public and empty (no README).
   - In each one's settings, set the description to point to mautic-stack.
   - Disable issues, wiki and projects there, so that everything goes to
     mautic-stack.
2. **Create a token for the split job.** Use a fine-grained personal
   access token or a GitHub App with **Contents: read and write** on these
   four repositories only. Store it in mautic-stack as the Actions secret
   `PACKAGES_SPLIT_TOKEN`.
3. **Enable the split:** set the Actions variable `PACKAGES_SPLIT` = `true`
   in mautic-stack. Then re-run the `packages` workflow, or push to `main`.
   The mirrors get their history and the first tags.
4. **Packagist.** Sign in at [packagist.org](https://packagist.org) with
   GitHub, then *Submit* each mirror's URL (`https://github.com/kopexa-grc/<name>`).
   With the GitHub account connected, Packagist updates automatically on
   new tags. The *Settings → GitHub sync* page shows the hooks.
5. **Mautic Marketplace** (optional, plugins and themes). The marketplace
   lists Packagist packages of type `mautic-plugin` / `mautic-theme`.
   While it is in beta, packages need to be added to its allowlist. Apply
   as described in Mautic's developer docs
   ([listing a plugin](https://devdocs.mautic.org/en/7.0/marketplace/listing.html),
   [allowlist note](https://devdocs.mautic.org/en/5.x/marketplace/listing.html)).

## Before publishing the theme

`kopexa/mautic-theme-kopexa` is Kopexa's own email design:

- The **code** is Apache-2.0.
- The **Kopexa name and logos are trademarks**. They are not licensed for
  other people's emails; see the theme's `NOTICE`.
- The **fonts** are SIL OFL 1.1.

Publishing it is fine as a reference or starting point. If it is meant to
be reused by others, consider a neutral variant without the logos.

## Visibility

A Packagist entry, the marketplace listing and the mirror READMEs all
link back to [kopexa.com](https://kopexa.com) and this repository. These
links are `nofollow` on Packagist. The value is the listing and the people
who find Kopexa through it, not search-engine link equity.
