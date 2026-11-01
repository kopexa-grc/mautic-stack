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

## Security checklist

- Set `mautic.trustedHosts` to your hostname(s).
- Restrict `mautic.trustedProxies` to your ingress/gateway networks.
- Enable `networkPolicy.enabled=true`.
- Provide `mautic.existingSecret` / `admin.existingSecret` from your secret
  manager (External Secrets, Sealed Secrets, …) instead of generated ones if
  you need to rotate them.
- Enforce Pod Security `restricted` on the namespace — the chart complies.
