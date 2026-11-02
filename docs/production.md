# Running in production

## Database

Use a managed MySQL/MariaDB or an operator (e.g.
[mariadb-operator](https://github.com/mariadb-operator/mariadb-operator))
and set `mariadb.enabled=false` + `externalDatabase.*`. Recommended server
settings: `utf8mb4` / `utf8mb4_unicode_ci`, `max_allowed_packet >= 64M`,
an InnoDB buffer pool sized to the contact base.

## Storage and scaling

One volume holds, in sub-paths:

- `config/`
- `media/files` and `media/images` (uploads)
- `translations/` (language packs installed in Mautic)
- the GeoIP database

- **ReadWriteOnce** (default): web, worker, cron and backup pods are pinned
  to the node of the web pod; web uses the `Recreate` strategy. Fine for a
  single web replica.
- **ReadWriteMany** (NFS, CephFS, EFS, Azure Files, …): set
  `persistence.accessModes=[ReadWriteMany]` to run multiple web replicas
  across nodes, with `RollingUpdate`, PDB and HPA.

**Valkey** (on by default, `valkey.enabled`) holds Mautic's cache and the PHP
sessions:

- Logins stay valid when a request lands on another web pod. That is what
  makes several web replicas work without session affinity.
- The cache takes load off the database.
- Valkey keeps nothing that has to survive a restart: no volume and no
  persistence. After a restart users log in again and the cache is rebuilt.
- Only the Mautic pods may connect (NetworkPolicy), and access is
  password-protected.

With `valkey.enabled: false`, cache and sessions stay on the local disk of
each pod. With more than one web replica you then need session affinity at
the ingress or gateway (cookie-based).

**Object storage.** Mautic keeps uploads on the filesystem; S3 is not
supported for them. The exception is **assets** (downloads such as PDFs).
They can be stored in S3 or an S3-compatible store (custom endpoint) with
Mautic's *Amazon S3* plugin (*Settings → Plugins*). Email images, files from
the builder, configuration and language packs stay on the volume. For
several web replicas across nodes, use a ReadWriteMany volume, see above.

## Queues

Keep `mautic.messenger.email=doctrine://default` (default) so that sending
happens in the worker, not in web requests. Scale `worker.replicaCount` for
throughput. For high volume use a dedicated broker (e.g.
`amqp://user:pass@rabbitmq:5672/%2f/messages`).

## Upgrades

- Patch releases are rebuilt and published automatically; pin
  `image.tag` (e.g. `7.2.2`) or `image.digest` if you want to control rollouts.
- `helm upgrade` restarts the web pod; the init container runs database
  migrations before the new version serves traffic.
- **Take a backup before minor/major upgrades.**

## Behind a CDN (Cloudflare & co.)

Mautic evaluates the proxy headers (`X-Forwarded-Proto`, `-For`, `-Port`)
once, against `mautic.trustedProxies`. The private-network default is right
when the CDN talks to your ingress or gateway and that talks to Mautic: the
pod's direct peer is the ingress, so https is detected and there is no
redirect loop.

Visitor IPs, used for tracking and geolocation, are the rightmost address in
`X-Forwarded-For` that is not a trusted proxy. Behind a CDN that address is
the CDN edge. To record the real visitor, add the CDN's ranges, e.g.
[Cloudflare's](https://www.cloudflare.com/ips/):

```yaml
mautic:
  trustedProxies:
    - 10.0.0.0/8
    - 172.16.0.0/12
    - 192.168.0.0/16
    - 100.64.0.0/10
    # Cloudflare (https://www.cloudflare.com/ips-v4 and ips-v6)
    - 173.245.48.0/20
    - 103.21.244.0/22
    # …
```

Only do this when all traffic really comes through the CDN, i.e. the origin
is not reachable directly (firewall, Cloudflare Tunnel or authenticated
origin pulls). Otherwise clients can claim any IP.

## Resources and scheduling

Every component has its own `resources` with conservative defaults (web,
init, worker, cron via `cron.defaults`, MariaDB, backup, helm test). Node
selection, tolerations, affinity, topology spread, priority class, image
pull secrets and extra pod labels/annotations can be set once under
`global` and overridden per component. `/tmp` and `/app/var` are emptyDirs
with size limits (`ephemeral.*`).

## Security checklist

- Set `mautic.trustedHosts` to your hostname(s).
- Restrict `mautic.trustedProxies` to your ingress/gateway networks.
- Enable `networkPolicy.enabled=true`, and `networkPolicy.egress.enabled=true`
  with an allow-list (SMTP relay, external DB, S3, webhook targets). This
  limits what an attacker can reach after a code-execution bug.
- Use SAML SSO for your team (see [sso.md](sso.md)) and keep the local admin
  as break-glass access with a strong password from your secret manager.
- Provide `mautic.existingSecret` / `admin.existingSecret` from your secret
  manager (External Secrets, Sealed Secrets, …) instead of generated ones if
  you need to rotate them.
- Enforce Pod Security `restricted` on the namespace — the chart complies.

## What the hardening buys you against PHP code execution

Bugs like PHP2Shell (CVE-2026-109618/-109619, fixed in PHP 8.4.27) let an
unauthenticated attacker run PHP code as the web user. The image cannot
prevent the bug itself — **patching is the fix**, and the daily rebuild
ships a fixed PHP as soon as Wolfi has it. The hardening limits what such
an attacker can do afterwards:

| Attacker wants to | Result |
|---|---|
| Spawn a shell or tools (`system()`, `exec()`, reverse shell) | No shell or package manager in the image; process functions are disabled for mod_php |
| Become root / escape | Non-root, no capabilities, no setuid files, `no_new_privs`, seccomp `RuntimeDefault` |
| Modify Mautic's code | Code is root-owned on a read-only root filesystem |
| Talk to the Kubernetes API | No service account token mounted |
| Reach other systems | Only with `networkPolicy.egress` allow-list (recommended) |

What an attacker **can** still do with PHP code execution: read the
environment (database credentials, `secret_key`), query the database, and
write to the writable paths (`/tmp`, `/app/var`, `config/`, uploads). Note
`config/local.php`, which Mautic includes as PHP: rotate secrets and inspect
`config/` after an incident. Egress restrictions and fast patching matter
most.
