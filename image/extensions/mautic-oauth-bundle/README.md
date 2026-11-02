# kopexa/mautic-oauth-bundle

OAuth 2.1 authorization server for Mautic 7, so MCP clients (Claude,
ChatGPT, …) can connect with the standard MCP authorization flow.

## Installation

Mautic 7 (Composer-based installation):

```bash
composer require kopexa/mautic-oauth-bundle
php bin/console mautic:plugins:reload
```

Configure the signing and encryption keys (`kopexa_oauth_private_key`, `kopexa_oauth_encryption_key`) in Mautic's `config/local.php` or, in the kopexa image, via environment variables.

Already included in the hardened Mautic image
[`ghcr.io/kopexa-grc/mautic`](https://github.com/kopexa-grc/mautic-stack).

> Development happens in
> [kopexa-grc/mautic-stack](https://github.com/kopexa-grc/mautic-stack/tree/main/image/extensions/mautic-oauth-bundle);
> the package repository is a read-only mirror. Issues and pull requests
> go to mautic-stack.

It provides:

- authorization code grant with PKCE (S256 only) and rotating refresh tokens
- dynamic client registration (RFC 7591)
- authorization server metadata (RFC 8414)
- JWKS
- RFC 9068 JWT access tokens with an RFC 8707 audience
- revocation (RFC 7009)

Consent is shown under `/s/`, so Mautic's own login (password or SAML)
authenticates the user.

Built on [league/oauth2-server](https://oauth2.thephpleague.com).

Configuration, security model and endpoints:
[docs/oauth.md](../../../docs/oauth.md).

| Parameter | Env (kopexa image) | |
|---|---|---|
| `kopexa_oauth_private_key` | `MAUTIC_OAUTH_PRIVATE_KEY` | RSA private key (PEM) |
| `kopexa_oauth_encryption_key` | `MAUTIC_OAUTH_ENCRYPTION_KEY` | secret for codes / refresh tokens |
| `kopexa_oauth_redirect_hosts` | `MAUTIC_OAUTH_REDIRECT_HOSTS` | allowed redirect hosts |
| `kopexa_oauth_resource` | `MAUTIC_OAUTH_RESOURCE` | token audience (default `<site_url>/mcp`) |
| `kopexa_oauth_access_ttl` / `kopexa_oauth_refresh_ttl` | via `MAUTIC_CONFIG_PARAMETERS` | seconds (3600 / 2592000) |

Apache-2.0 · [Kopexa](https://kopexa.com)
