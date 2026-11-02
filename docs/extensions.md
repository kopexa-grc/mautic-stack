# Our extensions: repositories and releases

| Package | Repository | What for |
|---|---|---|
| `kopexa/mautic-oauth-bundle` | [kopexa-grc/mautic-oauth-bundle](https://github.com/kopexa-grc/mautic-oauth-bundle) | OAuth 2.1 authorization server ([docs/oauth.md](oauth.md)) |
| `kopexa/mautic-mcp-bundle` | [kopexa-grc/mautic-mcp-bundle](https://github.com/kopexa-grc/mautic-mcp-bundle) | MCP server for AI assistants ([docs/mcp.md](mcp.md)) |
| `kopexa/mautic-postal-bundle` | [kopexa-grc/mautic-postal-bundle](https://github.com/kopexa-grc/mautic-postal-bundle) | Postal bounce webhooks ([docs/postal.md](postal.md)) |
| `kopexa/mautic-theme-kopexa` | this repository, [`image/extensions/mautic-theme-kopexa`](../image/extensions/mautic-theme-kopexa) | Kopexa email theme; internal, not published |

The three bundles live in their own repositories, with their history from
this one. Each one has:

- a CI that lints, runs `composer validate` and checks version consistency;
- a release workflow: bumping `VERSION` on `main` tags `v<VERSION>` and
  creates the GitHub release from `CHANGELOG.md`.

## How the image gets them

[`image/plugins.txt`](../image/plugins.txt) pins the released versions
(`kopexa/mautic-mcp-bundle:0.4.0`, …). The Dockerfile installs them with
Composer from the GitHub repositories (VCS repositories, `no-api`) until
they are on Packagist. Renovate opens a grouped PR for new releases
(`github-tags`). Our smoke test then exercises them end to end:

- OAuth flow
- MCP tools and campaign scenarios
- Postal webhooks

The PR is merged automatically when that is green.

So a change to a bundle goes like this:

1. PR in the bundle's repository, merge.
2. Bump `VERSION` + `CHANGELOG.md` there; the release workflow tags it.
3. Renovate updates `image/plugins.txt` here; the smoke test decides.

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

## Packagist (one-time, needs an account)

1. Sign in at [packagist.org](https://packagist.org) with GitHub.
2. *Submit* each repository URL, e.g.
   `https://github.com/kopexa-grc/mautic-oauth-bundle`. With the GitHub
   account connected, Packagist updates on new tags by itself.
3. Afterwards the VCS repositories in `image/Dockerfile` and the
   `github-tags` Renovate manager can be dropped in favour of Packagist.
4. **Mautic Marketplace** (optional): it lists Packagist packages of type
   `mautic-plugin`. While it is in beta, packages need to be allowlisted.
   See Mautic's developer docs
   ([listing a plugin](https://devdocs.mautic.org/en/7.0/marketplace/listing.html)).

Packagist links are `nofollow`. The value is the listing and the people
who find Kopexa through it, not search-engine link equity.
