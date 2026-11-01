# Running in production

## Database

Use a managed MySQL/MariaDB or an operator (e.g.
[mariadb-operator](https://github.com/mariadb-operator/mariadb-operator))
and set `mariadb.enabled=false` + `externalDatabase.*`. Recommended server
settings: `utf8mb4` / `utf8mb4_unicode_ci`, `max_allowed_packet >= 64M`,
an InnoDB buffer pool sized to the contact base.

## Storage and scaling

`config/` and `media/` live on one volume (sub-paths).

- **ReadWriteOnce** (default): web, worker, cron and backup pods are pinned
  to the node of the web pod; web uses the `Recreate` strategy. Fine for a
  single web replica.
- **ReadWriteMany** (NFS, CephFS, EFS, Azure Files, …): set
  `persistence.accessModes=[ReadWriteMany]` to run multiple web replicas
  across nodes, with `RollingUpdate`, PDB and HPA.

PHP sessions are stored in `/tmp` of each web pod. With several web replicas
enable session affinity at your ingress/gateway (cookie-based).

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
