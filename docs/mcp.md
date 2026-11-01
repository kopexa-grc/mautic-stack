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
| `list_campaigns`, `get_campaign` | `mcp:read` | Campaigns with segments and their flow (in the `set_campaign_steps` format, with contacts per step) |
| `create_email_draft` | `mcp:write` | New **unpublished** email (HTML, subject, preheader, segments) |
| `update_email_draft` | `mcp:write` | Change an unpublished, never-sent email |
| `list_campaign_step_types` | `mcp:read` | Available actions, decisions and conditions (including those of installed plugins) |
| `describe_campaign_step_type` | `mcp:read` | Properties of a step type (names, required, choices), which steps it may follow |
| `create_campaign_draft` | `mcp:write` | New **unpublished** campaign with segment source |
| `update_campaign_draft` | `mcp:write` | Change name, description, segments of an unpublished campaign |
| `set_campaign_steps` | `mcp:write` | Set the complete flow: actions, decisions, conditions, waits, yes/no branches (applied as a diff) |
| `update_campaign_step` | `mcp:write` | Change one step (name, wait, properties), also in a running campaign |
| `add_campaign_step` | `mcp:write` | Add one step, also to a running campaign |
| `remove_campaign_step` | `mcp:write` | Remove one step; in a running campaign only after `dryRun` + `confirm`, optionally redirecting waiting contacts |

### Campaign flows

`set_campaign_steps` takes the flow as a list of steps. Each step has a
`key`, a `type` and optionally a `parent` (the step it follows), a `path`
(`yes`/`no` after a decision or condition), a `wait` and the type's
`properties`:

```json
[
  {"key": "welcome",  "type": "email.send", "properties": {"email": 12, "email_type": "marketing"}},
  {"key": "opened",   "type": "email.open", "parent": "welcome"},
  {"key": "engaged",  "type": "lead.changepoints", "parent": "opened", "path": "yes", "properties": {"points": 10}},
  {"key": "reminder", "type": "email.send", "parent": "opened", "path": "no",
   "wait": {"interval": 3, "unit": "d"}, "properties": {"email": 13, "email_type": "marketing"}}
]
```

The result opens in Mautic's campaign builder like a hand-built campaign:

![Campaign flow created via MCP, in the Mautic campaign builder](img/mcp-campaign-flow.png)

Steps are validated the way the builder validates them:

- **Properties** go through the step type's own form, as in the builder
  modal. Required fields, allowed choices and plugin step types are checked
  the same way.
- **Connection rules:**
  - no decision directly after a decision
  - type restrictions such as `email.open` only after `email.send`
  - the `no` path of a decision needs a `wait` (how long the contact has to act)
- **Emails:** campaigns can only send template emails, and the user must be
  allowed to see them.
- **All or nothing:** an invalid flow changes nothing. A valid one is
  saved in one transaction.

### Editing campaigns, including running ones

`get_campaign` returns the flow in exactly the format `set_campaign_steps`
accepts. The key of an existing step is its Mautic event ID, so the
assistant can read, change and send back without translating. Changes are
applied as a **diff**, the way Mautic's own API does:

| In the submitted flow | Effect |
|---|---|
| Key = existing step ID | Updated in place. The step keeps its ID, so contacts on their way and the statistics stay attached. Omitted `name`, `wait` and properties stay as they are. |
| New, non-numeric key | Step is added |
| Existing step left out | Step is removed |

For small edits there are single-step tools: `update_campaign_step`,
`add_campaign_step` and `remove_campaign_step`. Each reports what was
added, changed, removed and left unchanged. With `dryRun: true` it only
reports and saves nothing.

**Running (published) campaigns** can be edited too, with safeguards for
the contacts already in the flow:

| Change | Running campaign |
|---|---|
| Name, wait, properties of a step (e.g. 3 → 5 days, other email) | allowed. Contacts already scheduled on the step keep their time; the change applies to contacts reaching it from now on. |
| Add steps | allowed |
| Move steps (other parent or path) | refused. Contacts would suddenly be on a different branch. |
| Remove steps | only after a `dryRun`, which shows how many contacts are scheduled on the step, and with `confirm` / `allow_deletions`. `redirectTo` / `redirects` move waiting contacts to another step (Mautic's own redirect mechanism). Steps that have following steps cannot be removed one by one. |
| Change the type of a step | refused, also in drafts (remove it and add a new one) |

Publishing, unpublishing and sending stay with a person in Mautic. Every
change is written to the audit log with what was added, changed and
removed.

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
- a complete campaign flow (email → opened? → points / reminder after 3 days), the builder rules, and Mautic's campaign cron executing it
- editing the running campaign:
  - an unchanged round trip
  - wait 3 → 5 days with the step ID kept
  - adding a step
  - refused moves
  - removal only after dry run and confirmation, with the redirect stored in the database
  - the cron keeps running afterwards
- a restricted role that sees no contacts

`test/e2e-k3s.sh` checks discovery and the 401 challenge through the HTTPS
ingress.
