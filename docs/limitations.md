# Known limitations

## No IMAP (`ext-imap`)

PHP removed `ext-imap` from its core in 8.4; the extension depends on the
UW c-client library, which has not been maintained since 2007. We do not ship
it in a hardened image. Mautic features that need it are unavailable:

- **Monitored inbox** (bounce and unsubscribe processing via IMAP,
  `mautic:email:fetch`). Use your provider's webhooks instead (Amazon SES,
  SendGrid, Mailgun, Postmark, Brevo, … are supported through Symfony Mailer
  transports and Mautic plugins).

## Immutable code

Plugins and themes cannot be installed through the Marketplace or uploaded
at runtime. Extend the image instead (see configuration.md). This is
intentional: what runs is exactly what was built, scanned and signed.

## Settings UI vs. environment

Parameters provided through the environment (database, site URL, mailer,
trusted proxies, …) always win over values saved in the configuration UI.

## Middlewares ignore MAUTIC_CONFIG_PARAMETERS (upstream bug, worked around)

Mautic's HTTP middlewares (`TrustMiddleware` for `trusted_proxies` /
`trusted_hosts`, CORS, HSTS) read only `config/local.php` and
`config/parameters_local.php`, not the `MAUTIC_CONFIG_PARAMETERS`
environment variable. Behind a TLS-terminating ingress this makes Mautic
treat every request as plain HTTP (redirect loops, `http://` links).

The image works around it: at every start the entrypoint writes a managed
`config/parameters_local.php` that reads `MAUTIC_CONFIG_PARAMETERS`. Do not
edit that file — put overrides into the environment or `local.php` instead.
The k3s end-to-end test checks HTTPS redirects behind Traefik for this.
