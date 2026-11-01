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
