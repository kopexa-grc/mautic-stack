# Image configuration

## Commands

| Command | Purpose |
|---|---|
| `web` (default) | Apache httpd + mod_php on port 8080 |
| `init` | Wait for the database, install Mautic on first start (needs `MAUTIC_ADMIN_PASSWORD`), run migrations, reload plugins. Idempotent; concurrent runs are serialised with a database lock. |
| `worker [transport…]` | `messenger:consume` (default transports `email hit`); exits after `MAUTIC_WORKER_TIME_LIMIT` seconds so the orchestrator restarts it |
| `console <command> [args…]` | Run `bin/console`; exits 0 without doing anything while Mautic is not installed yet |
| `version` | Print the Mautic version |

## Environment

Every variable also accepts `<NAME>_FILE` pointing to a file (e.g. a mounted
secret).

| Variable | Mautic parameter | Notes |
|---|---|---|
| `MAUTIC_DB_HOST`, `MAUTIC_DB_PORT`, `MAUTIC_DB_NAME`, `MAUTIC_DB_USER`, `MAUTIC_DB_PASSWORD`, `MAUTIC_DB_TABLE_PREFIX` | `db_*` | MySQL 8 / MariaDB 10.11+ |
| `MAUTIC_SITE_URL` | `site_url` | required |
| `MAUTIC_SECRET_KEY` | `secret_key` | set it so all replicas share one key |
| `MAUTIC_TRUSTED_PROXIES` | `trusted_proxies` | comma/space separated CIDRs |
| `MAUTIC_TRUSTED_HOSTS` | `trusted_hosts` | comma/space separated regexes |
| `MAUTIC_MAILER_DSN`, `MAUTIC_MAILER_FROM_EMAIL`, `MAUTIC_MAILER_FROM_NAME` | `mailer_*` | Symfony Mailer DSN |
| `MAUTIC_MESSENGER_DSN_EMAIL`, `MAUTIC_MESSENGER_DSN_HIT`, `MAUTIC_MESSENGER_DSN_FAILED` | `messenger_dsn_*` | `doctrine://default` queues in the DB; `sync://` sends inline |
| `MAUTIC_POSTAL_JWKS_URL`, `MAUTIC_POSTAL_WEBHOOK_PUBLIC_KEY` | `postal_*` | Postal bounce webhooks, see [postal.md](postal.md) |
| `MAUTIC_OAUTH_PRIVATE_KEY`, `MAUTIC_OAUTH_ENCRYPTION_KEY`, `MAUTIC_OAUTH_REDIRECT_HOSTS`, `MAUTIC_OAUTH_RESOURCE` | `kopexa_oauth_*` | OAuth 2.1 for MCP clients, see [oauth.md](oauth.md) |
| `MAUTIC_MCP_LIVE_CAMPAIGN_EDITS` | `kopexa_mcp_live_campaign_edits` | `false` makes running campaigns read-only for MCP, see [mcp.md](mcp.md#what-mcp-changes-can-trigger) |
| `MAUTIC_CONFIG_PARAMETERS` | any | JSON object, merged last (wins) |
| `MAUTIC_ADMIN_USERNAME`, `MAUTIC_ADMIN_EMAIL`, `MAUTIC_ADMIN_PASSWORD`, `MAUTIC_ADMIN_FIRSTNAME`, `MAUTIC_ADMIN_LASTNAME` | — | used by `init` for the first installation only |
| `MAUTIC_DB_WAIT_TIMEOUT` | — | seconds `init`/`worker` wait for the DB (default 300) |
| `MAUTIC_WORKER_TIME_LIMIT`, `MAUTIC_WORKER_MEMORY_LIMIT` | — | worker restart limits (3600 s, 256M) |
| `PHP_MEMORY_LIMIT`, `PHP_MAX_EXECUTION_TIME`, `PHP_UPLOAD_MAX_FILESIZE`, `PHP_POST_MAX_SIZE`, `PHP_DATE_TIMEZONE` | — | php.ini |
| `APACHE_MAX_REQUEST_WORKERS`, `APACHE_TRUSTED_PROXIES`, … | — | see the [php-apache base image](https://github.com/kopexa-grc/images/blob/main/images/php-apache/apko.yaml) |

Values set through the environment override `config/local.php`. Settings
changed in Mautic's configuration UI are written to `config/local.php` and
take effect only for parameters that are **not** set through the environment.

## Writable paths

| Path | Content | Recommended mount |
|---|---|---|
| `/tmp` | PHP sessions, temp files | tmpfs / emptyDir |
| `/app/var` | cache, logs, spool | tmpfs / emptyDir |
| `/app/config` | `local.php` (installer, settings UI) | persistent |
| `/app/docroot/media/files` | uploaded assets | persistent |
| `/app/docroot/media/images` | uploaded images | persistent |

## SAML single sign-on

`MAUTIC_SAML_IDP_METADATA` (IdP metadata XML), `MAUTIC_SAML_IDP_ENTITY_ID`,
`MAUTIC_SAML_IDP_OWN_CERTIFICATE` / `_OWN_PRIVATE_KEY` (PEM, optional),
`MAUTIC_SAML_IDP_{EMAIL,USERNAME,FIRSTNAME,LASTNAME}_ATTRIBUTE` and
`MAUTIC_SAML_IDP_DEFAULT_ROLE`. All of them accept `*_FILE`. Plain XML/PEM
is base64-encoded automatically, as Mautic expects. See [sso.md](sso.md).

## Custom plugins and themes

The image is immutable (no Marketplace installs at runtime). Build your own
image on top of it:

```dockerfile
FROM ghcr.io/kopexa-grc/php-apache:8.4-dev AS build
COPY --from=ghcr.io/kopexa-grc/mautic:7 /app /app
WORKDIR /app
RUN composer require --no-interaction --ignore-platform-req=ext-imap vendor/my-mautic-plugin

FROM ghcr.io/kopexa-grc/mautic:7
COPY --from=build --chown=0:0 /app/vendor /app/vendor
COPY --from=build --chown=0:0 /app/docroot/plugins /app/docroot/plugins
```
