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
| [etailors/mautic-amazon-ses](https://packagist.org/packages/etailors/mautic-amazon-ses) | Amazon SES sending via API **plus bounce/complaint handling** via SNS — the replacement for IMAP bounce processing | DSN `mautic+ses+api://KEY:SECRET@default?region=eu-central-1`, see the plugin README |
| [tawk-gmbh/mautic-friendlycaptcha-bundle](https://packagist.org/packages/tawk-gmbh/mautic-friendlycaptcha-bundle) | Friendly Captcha for forms (EU vendor, no cookies) | *Plugins → Friendly Captcha* |
| [firemultimedia/mautic-multi-captcha-bundle](https://packagist.org/packages/firemultimedia/mautic-multi-captcha-bundle) | hCaptcha, Cloudflare Turnstile, reCAPTCHA | *Plugins → Multi Captcha* |
| `symfony/{amazon,brevo,postmark,mailgun,sendgrid,mailjet}-mailer` | Official Symfony Mailer bridges: send through provider APIs instead of SMTP | `mautic.mailer.dsn`, e.g. `brevo+api://KEY@default`, `postmark+api://KEY@default` |

List what is installed in a running image:

```bash
docker run --rm ghcr.io/kopexa-grc/mautic:7 plugins
```

Add your own extension: append `vendor/package:version` to
`image/plugins.txt` and open a PR. CI fails if Composer cannot resolve it
against Mautic 7 or if the smoke test cannot find it in the image.

## MCP

There is no maintained MCP integration for Mautic yet: the existing
community servers were written in a few days in spring 2026 and have not
been updated since. See the discussion in the repository issues before
picking one; the planned approach is a Mautic plugin built on the official
PHP MCP SDK (`mcp/sdk`) and `symfony/mcp-bundle`.
