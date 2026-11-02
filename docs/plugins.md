# Built-in extensions

The image ships with a curated set of extensions, listed in
[`image/plugins.txt`](../image/plugins.txt). They are installed at build
time with Composer, scanned and signed together with Mautic, and updated by
Renovate (patch releases automatically, anything larger by PR after the
end-to-end tests pass). Runtime installs from the Marketplace are disabled
on purpose: what runs is exactly what was built.

Criteria for inclusion: explicit Mautic 7 support, a release in the last
months, and a clear need for our use cases.

| Extension | What for | Configure in Mautic |
|---|---|---|
| [leuchtfeuer/mautic-doi-bundle](https://packagist.org/packages/leuchtfeuer/mautic-doi-bundle) | Double opt-in for forms and segments (GDPR, German UWG) | *Settings → Plugins → Double Opt-In* |
| [kopexa/mautic-postal-bundle](https://github.com/kopexa-grc/mautic-postal-bundle) (ours) | **Postal bounces:** signed `MessageBounced` / hard `MessageDeliveryFailed` webhooks mark the contact *Do Not Contact – bounced* | `mautic.postal.jwksUrl`; in Postal add a webhook to `https://<mautic>/mailer/callback` — see [docs/postal.md](postal.md) |
| [kopexa/mautic-mcp-bundle](https://github.com/kopexa-grc/mautic-mcp-bundle) (ours) | **MCP server** for Claude, ChatGPT and other AI assistants: read contacts, segments, emails, campaigns, statistics; create unpublished emails and campaigns, edit campaign flows (live for running campaigns), with the user's Mautic permissions; never publishes or sends directly | `mautic.oauth.enabled: true`, then add `https://<mautic>/mcp` as a connector — see [docs/mcp.md](mcp.md) |
| [kopexa/mautic-oauth-bundle](https://github.com/kopexa-grc/mautic-oauth-bundle) (ours) | **OAuth 2.1 authorization server** for MCP clients (Claude, ChatGPT): authorization code + PKCE S256, dynamic client registration, JWT access tokens, consent behind Mautic's login | `mautic.oauth.enabled: true` — see [docs/oauth.md](oauth.md) |
| [kopexa/mautic-theme-kopexa](../image/extensions/mautic-theme-kopexa) (ours) | **Kopexa email themes** (MJML, GrapesJS builder) from brand.kopexa.com tokens: *Kopexa* (standard mail), *Kopexa · Anmeldung bestätigen* (double opt-in), *Kopexa · Hero + Split* (hero, two cards, feature); automated quality gate (size, links, contrast, client compatibility, spam score, builder rules) | pick the theme when creating an email |
| `symfony/{amazon,postmark,brevo,mailgun,sendgrid,mailjet}-mailer` | Official Symfony Mailer bridges: send through provider HTTP APIs instead of SMTP | `mautic.mailer.dsn`, e.g. `ses+api://KEY:SECRET@default?region=eu-central-1`, `postmark+api://TOKEN@default` |

Mautic's own plugins from `mautic/recommended-project` are part of the
image as well, among them the **GrapesJS builder**, **Focus** (popups,
bars), **Tag Manager**, **Cloud Storage** (Amazon S3 and S3-compatible
storage such as OVH, for assets) and the CRM, Zapier, Gmail and Outlook
integrations. They appear under *Settings → Plugins*; nothing to install.

### Double opt-in

1. *Settings → Plugins → Double Opt-In*: enable it, set the link timeout.
2. Create an email with the theme *Kopexa · Anmeldung bestätigen* (type
   *template*). Its button links to `{doi_link}`, which the plugin fills in.
3. In the form, tab *Email Verification*: enable DOI, select that email,
   optionally a thank-you and an error page. Move the actions that should
   only run after the confirmation (add to segment, etc.) to the
   post-verification actions.

The chart runs the plugin's jobs (`cron.jobs.doi-*`: follow-up mails,
timeouts, cleanup); they do nothing as long as no form uses DOI.

Our default is **SMTP** (Mautic core) to our [Postal](https://docs.postalserver.io)
server; the bridges are there to switch to a provider API without
rebuilding the image:

```yaml
mautic:
  mailer:
    existingSecret: mautic-mailer   # key mailer-dsn: smtp://USER:PASSWORD@postal.example.com:25
    fromEmail: newsletter@example.com
```

Use an SMTP credential of the Postal mail server; Postal offers STARTTLS on
port 25 (and 587 if enabled).

List what is installed in a running image:

```bash
docker run --rm ghcr.io/kopexa-grc/mautic:7 plugins
```

Add a third-party extension: append `vendor/package:version` to
`image/plugins.txt` and open a PR. Our own bundles live in
`image/extensions/<name>/` and are installed automatically from a local
Composer path repository. CI fails if Composer cannot resolve it
against Mautic 7 or if the smoke test cannot find it in the image.

## MCP

There is no maintained MCP integration for Mautic yet: the existing
community servers were written in a few days in spring 2026 and have not
been updated since. See [#2](https://github.com/kopexa-grc/mautic-stack/issues/2) before
picking one; the planned approach is a Mautic plugin built on the official
PHP MCP SDK (`mcp/sdk`) and `symfony/mcp-bundle`.

Our own bundles (*ours* above) are developed in their own repositories and
published on Packagist and pinned in `image/plugins.txt`; see
[docs/extensions.md](extensions.md).
