# MCP: Mautic for Claude, ChatGPT and other AI assistants

[`kopexa/mautic-mcp-bundle`](../image/extensions/mautic-mcp-bundle) runs a
[Model Context Protocol](https://modelcontextprotocol.io) server inside
Mautic at `https://<mautic>/mcp`. It is built on the official
[MCP PHP SDK](https://github.com/modelcontextprotocol/php-sdk) and uses
Streamable HTTP. Clients sign in with OAuth 2.1 against Mautic itself
([docs/oauth.md](oauth.md)): a person logs in to Mautic, approves the
client and from then on the assistant works **with that person's Mautic
permissions**.

## Enable

```yaml
mautic:
  siteUrl: https://mautic.example.com
  oauth:
    enabled: true     # authorization server; the MCP endpoint needs it
```

The endpoint must be reachable from the internet over HTTPS (ingress or
Gateway API). Claude and ChatGPT connect from their own servers, not from
your browser.

## Connect

| Client | How |
|---|---|
| **Claude** (claude.ai, Desktop, mobile) | *Settings → Connectors → Add custom connector*, URL `https://mautic.example.com/mcp`. Claude registers itself, opens the Mautic login and the consent page. |
| **ChatGPT** | *Settings → Apps & Connectors → Create* (developer mode), MCP server URL `https://mautic.example.com/mcp`, authentication *OAuth*. |
| **Claude Code** | `claude mcp add --transport http mautic https://mautic.example.com/mcp`, then `/mcp` to sign in. |
| **MCP Inspector** | `npx @modelcontextprotocol/inspector`, transport *Streamable HTTP*, URL as above. |

Discovery is automatic. The first request without a token gets `401` with
`WWW-Authenticate: Bearer resource_metadata=".../.well-known/oauth-protected-resource/mcp"` ([RFC 9728](https://www.rfc-editor.org/rfc/rfc9728)).
That document points to the authorization server metadata, and the client
registers dynamically. Nothing has to be configured in Mautic per client.

## Tools

| Tool | Scope | What it does |
|---|---|---|
| `search_contacts` | `mcp:read` | Search by name, email, company or Mautic search syntax (`tag:…`, `segment:…`) |
| `get_contact` | `mcp:read` | Profile fields, tags, segments, points, stage, Do-Not-Contact status |
| `list_segments` | `mcp:read` | Segments with contact counts |
| `list_emails`, `get_email` | `mcp:read` | Emails with type, status, statistics, HTML |
| `get_email_stats` | `mcp:read` | Sent, read, read rate, clicks per link, pending recipients |
| `list_campaigns`, `get_campaign` | `mcp:read` | Campaigns with segments and their event tree |
| `create_email_draft` | `mcp:write` | New **unpublished** email (HTML, subject, preheader, segments) |
| `update_email_draft` | `mcp:write` | Change an unpublished, never-sent email |
| `create_campaign_draft` | `mcp:write` | New **unpublished** campaign with segment source; steps are added in the campaign builder |
| `update_campaign_draft` | `mcp:write` | Change name, description, segments of an unpublished campaign |

**Nothing is sent or published through MCP.** Write tools only create and
change drafts. Published or already sent items are refused. A person
reviews the draft in Mautic (each result contains its `url`) and publishes
it there.

## Permissions

Three layers, all of which must allow an action:

1. **Scope** of the token: `mcp:read` or `mcp:write`, chosen at consent. A
   write call with a read-only token is answered with `403 insufficient_scope`.
2. **Mautic role** of the user who approved the client. The same
   own/other checks as the Mautic UI and API apply (`lead:leads:viewother`,
   `email:emails:create`, `email:emails:editown`, …). Users who may only see
   their own items only get those in lists.
3. **Draft rule**: no publishing, no sending, no deleting.

We recommend a dedicated role, for example *AI Editor*:

- Emails: view, create, edit (own)
- Campaigns: view, create, edit (own)
- Segments: view
- Contacts: view only if the assistant really needs contact data

Contact data is personal data. Before giving an assistant contact read
access, check your data processing agreement with the AI provider.

Each write is recorded in Mautic's audit log with the OAuth client id. A
disabled Mautic user loses access immediately, even with a valid token.

## Operations

- **Sessions** are kept in the Mautic database (table
  `kopexa_mcp_sessions`, created on first use). This works with several
  web replicas behind a load balancer and needs no sticky sessions.
- **Tokens** are verified offline against the instance's own signing key.
  No outbound connection is needed, so it works with
  `networkPolicy.egress.enabled`.
- **Host check:** requests must use the host of `siteUrl` (DNS rebinding
  protection). CORS is open, because browsers never send bearer tokens on
  their own.

## Tests

`test/smoke.sh` (section *MCP server*) runs on every image build:

- protected resource metadata
- 401 with `WWW-Authenticate`; forged tokens rejected
- initialize with a database session, `tools/list`
- search and contact details
- create and update a draft; a published email is refused
- `insufficient_scope` for a read-only token
- segments, campaign drafts and statistics
- a restricted role that sees no contacts

`test/e2e-k3s.sh` checks discovery and the 401 challenge through the HTTPS
ingress.
