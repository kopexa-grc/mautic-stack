# mautic-stack

[![image](https://github.com/kopexa-grc/mautic-stack/actions/workflows/image.yml/badge.svg)](https://github.com/kopexa-grc/mautic-stack/actions/workflows/image.yml) [![chart](https://github.com/kopexa-grc/mautic-stack/actions/workflows/chart.yml/badge.svg)](https://github.com/kopexa-grc/mautic-stack/actions/workflows/chart.yml) [![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/kopexa-grc/mautic-stack/badge)](https://scorecard.dev/viewer/?uri=github.com/kopexa-grc/mautic-stack) [![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)

Always up-to-date, hardened [Mautic](https://www.mautic.org) for Docker and
Kubernetes.

- **Image** `ghcr.io/kopexa-grc/mautic` — Mautic 7 on the hardened
  [`php-apache`](https://github.com/kopexa-grc/images) base: no shell, no
  package manager, non-root (uid 65532), read-only root filesystem, rebuilt
  daily, signed (cosign), SBOM + SLSA provenance, multi-arch (amd64/arm64).
- **Helm chart** `oci://ghcr.io/kopexa-grc/charts/mautic` — web, queue
  workers, cron jobs, optional MariaDB, Ingress *or* Gateway API, restic
  backups, NetworkPolicies, Pod Security "restricted" by default.
- **Automatic updates** — Renovate opens a PR for every Mautic release on
  Packagist; patch releases are merged automatically once the end-to-end
  tests pass.

## Quick start (Kubernetes)

```bash
helm install mautic oci://ghcr.io/kopexa-grc/charts/mautic \
  --namespace mautic --create-namespace \
  --set mautic.siteUrl=https://mautic.example.com
```

The first start installs Mautic automatically (init container). Get the
generated admin password:

```bash
kubectl -n mautic get secret mautic -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

Expose it with your ingress controller **or** Gateway API:

```yaml
# values.yaml
ingress:
  enabled: true
  className: nginx            # or traefik, haproxy, …
  hosts:
    - host: mautic.example.com
      paths: [{path: /, pathType: Prefix}]
  tls:
    - secretName: mautic-tls
      hosts: [mautic.example.com]
```

```yaml
# … or Gateway API (Envoy Gateway, Cilium, Istio, NGINX Gateway Fabric, …)
httpRoute:
  enabled: true
  parentRefs: [{name: public, namespace: gateway-system, sectionName: https}]
  hostnames: [mautic.example.com]
```

Configure a mailer (Symfony Mailer DSN), ideally from a Secret:

```bash
kubectl -n mautic create secret generic mautic-mailer \
  --from-literal=mailer-dsn='smtp://user:password@smtp.example.com:587'
```

```yaml
mautic:
  mailer:
    existingSecret: mautic-mailer
    fromEmail: marketing@example.com
    fromName: Example
```

## Production

The bundled MariaDB is meant for evaluation and small installations:
a single instance, **no replication, no automatic failover**. For production:

```yaml
mariadb:
  enabled: false
externalDatabase:
  host: mautic-db.databases.svc   # managed DB or e.g. mariadb-operator
  database: mautic
  username: mautic
  existingSecret: mautic-db       # key: password
backup:
  enabled: true
  repository: s3:https://s3.eu-central-1.amazonaws.com/my-backups/mautic
  existingSecret: mautic-backup   # RESTIC_PASSWORD, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY
```

See [docs/production.md](docs/production.md) (sizing, scaling, storage,
upgrades) and [docs/backup.md](docs/backup.md) (backup and restore).

## How the chart is laid out

| Component | Kind | Command |
|---|---|---|
| web | Deployment | Apache + mod_php; init container installs/migrates |
| worker | Deployment | `messenger:consume email hit` (restarts hourly) |
| cron | one CronJob per job | `mautic:segments:update`, `campaigns:update`, `campaigns:trigger`, `broadcasts:send`, `reports:scheduler`, … |
| mariadb | StatefulSet (optional) | official `mariadb:11.4` |
| backup | CronJob (optional) | `mariadb-dump` → restic (+ uploads) |

Everything is configurable in [`values.yaml`](charts/mautic/values.yaml):
resources, probes, affinity, tolerations, topology spread, extra
env/volumes/sidecars/init containers, per-job schedules, PDB, HPA and
`extraObjects` for anything else. The chart renders plain manifests, so it
also works with `helm template | kustomize`.

## Docker / Compose

```bash
docker run -d --name mautic -p 8080:8080 --read-only --tmpfs /tmp --tmpfs /app/var \
  -v mautic-config:/app/config -v mautic-media:/app/docroot/media/images \
  -e MAUTIC_DB_HOST=db -e MAUTIC_DB_NAME=mautic -e MAUTIC_DB_USER=mautic \
  -e MAUTIC_DB_PASSWORD_FILE=/run/secrets/db-password \
  -e MAUTIC_SITE_URL=https://mautic.example.com \
  -e MAUTIC_ADMIN_PASSWORD_FILE=/run/secrets/admin-password \
  ghcr.io/kopexa-grc/mautic:7
```

Run `init` once before `web` (or as a separate service), plus `worker` and
`console <command>` for queues and cron. The image commands and all
environment variables are documented in
[docs/configuration.md](docs/configuration.md).

## Verify

```bash
cosign verify ghcr.io/kopexa-grc/mautic:7 \
  --certificate-identity-regexp '^https://github.com/kopexa-grc/mautic-stack/\.github/workflows/image\.yml@refs/heads/main$' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

## Differences from the official Mautic image

- Mautic **7** (the official image currently publishes 5.x and 6.x only).
- Hardened base: no shell/package manager, non-root, read-only rootfs,
  setuid-free, CIS-aligned Apache config, uploads cannot execute PHP.
- Configuration via environment and `*_FILE` secrets; automatic install.
- No `ext-imap`: removed from PHP 8.4 core and built on an unmaintained
  library. IMAP bounce processing is therefore unavailable — use your mail
  provider's webhooks. See [docs/limitations.md](docs/limitations.md).

## License

Packaging (Dockerfile, chart, scripts): [Apache-2.0](LICENSE).
Mautic itself is [GPL-3.0](https://github.com/mautic/mautic/blob/7.x/LICENSE.txt);
the image contains Mautic and the packages of its base image under their own
licenses (see the SBOM attached to each image). This project is not
affiliated with or endorsed by Mautic or Acquia.
