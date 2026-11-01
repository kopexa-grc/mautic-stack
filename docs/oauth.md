# OAuth 2.1 for MCP clients

Claude, ChatGPT and other MCP clients connect to remote MCP servers with
OAuth 2.1, as the [MCP authorization spec](https://modelcontextprotocol.io/specification/2025-06-18/basic/authorization)
requires. Mautic's built-in OAuth server (FOSOAuthServerBundle) predates
OAuth 2.1: no PKCE, no dynamic client registration, no metadata discovery.
[`kopexa/mautic-oauth-bundle`](../image/extensions/mautic-oauth-bundle) adds
a separate authorization server on [league/oauth2-server](https://oauth2.thephpleague.com)
that does. Mautic's own API OAuth (*Settings → API Credentials*) is not
affected.

```
MCP client ──▶ GET  /.well-known/oauth-authorization-server   (RFC 8414)
           ──▶ POST /oauth2/register                          (RFC 7591, public client)
browser    ──▶ GET  /s/oauth2/authorize?…&code_challenge=…&code_challenge_method=S256
               └─ Mautic login (password or SAML SSO) → consent page → redirect with ?code=
MCP client ──▶ POST /oauth2/token  (code + code_verifier)    → access token (JWT) + refresh token
           ──▶ MCP endpoint with  Authorization: Bearer <JWT>
```

## Enable it

```yaml
mautic:
  siteUrl: https://mautic.example.com   # becomes the issuer
  oauth:
    enabled: true
```

The chart generates an RSA signing key and an encryption key once, stores
them in the release Secret (`oauth-private-key`, `oauth-encryption-key`)
and keeps them across upgrades. To manage them yourself:

```bash
openssl genrsa -out oauth.pem 3072
kubectl -n mautic create secret generic mautic-oauth \
  --from-file=oauth-private-key=oauth.pem \
  --from-literal=oauth-encryption-key="$(openssl rand -hex 32)"
```

```yaml
mautic:
  oauth:
    enabled: true
    existingSecret: mautic-oauth
```

Docker: set `MAUTIC_OAUTH_PRIVATE_KEY` (PEM) and
`MAUTIC_OAUTH_ENCRYPTION_KEY` (or their `*_FILE` variants). Without them
the endpoints answer `503`.

| Value | Env | Default |
|---|---|---|
| `mautic.oauth.redirectHosts` | `MAUTIC_OAUTH_REDIRECT_HOSTS` | `claude.ai, claude.com, chatgpt.com, chat.openai.com, localhost, 127.0.0.1` |
| `mautic.oauth.resource` | `MAUTIC_OAUTH_RESOURCE` | `<siteUrl>/mcp` |

## Security model

| | |
|---|---|
| **Grants** | Authorization code and refresh token only. No implicit, password or client-credentials grant. |
| **PKCE** | Required for every request, `S256` only. `plain` or a missing method is rejected. |
| **Clients** | Public clients (`token_endpoint_auth_method: none`), created by dynamic registration. A client that asks for a secret gets `none`. Secrets would add nothing for apps that cannot keep them; PKCE protects the code instead. |
| **Redirect URIs** | `https` on an allow-listed host or its subdomains, or `http(s)` on loopback (RFC 8252) if `localhost`/`127.0.0.1` is allow-listed. Matched exactly at authorization time (loopback: any port). |
| **Who can authorize** | Any Mautic user, after Mautic's normal login (password or [SAML SSO](sso.md)). The consent page names the client, the scopes and the redirect host. The decision is written to Mautic's audit log. |
| **Permissions** | Tokens carry the Mautic user (`sub`). The MCP server acts with that user's Mautic role. Give AI access to a dedicated role with only the permissions it needs. |
| **Scopes** | `mcp:read` (default if none requested), `mcp:write` (draft emails and campaigns). |
| **Access tokens** | [RFC 9068](https://www.rfc-editor.org/rfc/rfc9068) JWTs (`typ: at+jwt`, RS256), 1 h, audience = `resource` ([RFC 8707](https://www.rfc-editor.org/rfc/rfc8707)). Verified offline against `/oauth2/jwks.json`, not stored. |
| **Refresh tokens** | 30 days, encrypted, rotated on every use (an old token is rejected). Revocable via `/oauth2/revoke` ([RFC 7009](https://www.rfc-editor.org/rfc/rfc7009)), which revokes all grants of that user for that client. |
| **Codes** | 10 minutes, single use, bound to client, redirect URI and PKCE challenge. |
| **Storage** | Tables `kopexa_oauth_clients` and `kopexa_oauth_grants`, created on first use. Grant IDs are stored as SHA-256 hashes. |
| **Consent page** | CSRF token, `X-Frame-Options: DENY`, strict CSP, `no-store`. |

Rotating the signing key invalidates all access tokens (clients refresh).
Rotating the encryption key invalidates all refresh tokens (users
reconnect).

## Endpoints

| Path | |
|---|---|
| `GET /.well-known/oauth-authorization-server` | Metadata (RFC 8414) |
| `GET /oauth2/jwks.json` | Public signing key |
| `POST /oauth2/register` | Dynamic client registration (RFC 7591) |
| `GET /s/oauth2/authorize` | Authorization + consent (behind Mautic login) |
| `POST /oauth2/token` | Token endpoint |
| `POST /oauth2/revoke` | Revocation (RFC 7009) |

The base image denies all paths starting with a dot. The image allows
exactly `/.well-known/oauth-authorization-server` and
`/.well-known/oauth-protected-resource` through to Mautic. The rest of
`/.well-known` stays denied.

## Tests

`test/smoke.sh` (section *OAuth 2.1 authorization server*) runs the whole
flow against the image on every build:

- metadata and JWKS
- rejected registrations (foreign host, plain http)
- login redirect and return to consent
- `plain` PKCE rejected
- code exchange with a wrong and then the right verifier
- single-use codes
- JWT claims and signature
- refresh rotation, revocation and denied consent

`test/e2e-k3s.sh` checks discovery through the HTTPS ingress.
`test/upgrade-k3s.sh` checks that the generated signing key survives
upgrades.
