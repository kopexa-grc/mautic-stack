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
| [tawk-gmbh/mautic-friendlycaptcha-bundle](https://packagist.org/packages/tawk-gmbh/mautic-friendlycaptcha-bundle) | Friendly Captcha for forms (EU vendor, no cookies) | *Plugins → Friendly Captcha* |
| [firemultimedia/mautic-multi-captcha-bundle](https://packagist.org/packages/firemultimedia/mautic-multi-captcha-bundle) | hCaptcha, Cloudflare Turnstile, reCAPTCHA | *Plugins → Multi Captcha* |

Mail goes out via **SMTP** (Mautic core) to our [Postal](https://docs.postalserver.io)
server — no provider API bridges are needed:

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

Add your own extension: append `vendor/package:version` to
`image/plugins.txt` and open a PR. CI fails if Composer cannot resolve it
against Mautic 7 or if the smoke test cannot find it in the image.

## MCP

There is no maintained MCP integration for Mautic yet: the existing
community servers were written in a few days in spring 2026 and have not
been updated since. See [#2](https://github.com/kopexa-grc/mautic-stack/issues/2) before
picking one; the planned approach is a Mautic plugin built on the official
PHP MCP SDK (`mcp/sdk`) and `symfony/mcp-bundle`.
