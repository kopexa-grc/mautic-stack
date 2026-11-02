# Changelog

## 0.2.0 – 2026-11-02

- The consent page lists the requested scopes as checkboxes. Users can grant fewer scopes than requested.
- Opt-in scopes (`kopexa_oauth_optin_scopes`) are highlighted and unticked by default.
- New scope `mcp:campaigns:live` (opt-in), used by `kopexa/mautic-mcp-bundle` for changes to running campaigns.
- `Settings::publicKeyPem()` exposes the public signing key to resource servers in the same instance.

## 0.1.0 – 2026-11-01

- OAuth 2.1 authorization server:
  - authorization code with PKCE (S256 only)
  - rotating refresh tokens
  - dynamic client registration (RFC 7591)
  - metadata (RFC 8414) and JWKS
  - RFC 9068 JWT access tokens with an RFC 8707 audience
  - revocation (RFC 7009)
- Consent page behind Mautic's login (password or SAML). Decisions go to the audit log.
