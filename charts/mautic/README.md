# mautic

![Version: 0.3.8](https://img.shields.io/badge/Version-0.3.8-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: 7.2.2](https://img.shields.io/badge/AppVersion-7.2.2-informational?style=flat-square)  [![chart](https://github.com/kopexa-grc/mautic-stack/actions/workflows/chart.yml/badge.svg)](https://github.com/kopexa-grc/mautic-stack/actions/workflows/chart.yml)

Hardened, always up-to-date Mautic for Kubernetes — web, queue workers, cron jobs, SAML SSO, MCP server for AI assistants (OAuth 2.1), Valkey for cache and sessions, optional MariaDB and restic backups.

Maintained by **[Kopexa](https://kopexa.com)**. Source, issues and full
documentation: [kopexa-grc/mautic-stack](https://github.com/kopexa-grc/mautic-stack).

## Highlights

- **Hardened image** [`ghcr.io/kopexa-grc/mautic`](https://github.com/kopexa-grc/mautic-stack/pkgs/container/mautic):
  - built on [kopexa-grc/images](https://github.com/kopexa-grc/images), with no shell and no package manager
  - non-root (uid 65532) with a read-only root filesystem
  - rebuilt daily, signed with cosign, with SBOM and SLSA provenance, for amd64 and arm64
- **Kubernetes best practices**:
  - Pod Security "restricted" and ingress/egress NetworkPolicies
  - PodDisruptionBudget, HPA and central resource defaults
  - `values.schema.json` validation, so typos fail at install time
- **Components**:
  - web and Messenger queue workers
  - Valkey (hardened image) for Mautic's cache and shared PHP sessions, so several web replicas work without sticky sessions
  - every Mautic cron job as a CronJob
  - optional MariaDB or an external database (credentials from operator Secrets)
- **Exposure**: Ingress *or* Gateway API `HTTPRoute`.
- **Backups**: restic to S3, B2, Azure, GCS, SFTP or REST, with database dump and media.
- **Single sign-on**: SAML with Keycloak, Google Workspace, Entra ID and others.
- **AI assistants via MCP**: Claude, ChatGPT and other clients connect to `/mcp` with standard OAuth 2.1 (PKCE, dynamic client registration). They can read data, create unpublished emails and campaigns, and edit campaign flows (changes to running campaigns are live), with the user's Mautic permissions. They never publish or send directly.
- **Built-in extensions**:
  - Postal bounce webhooks
  - Kopexa email theme
  - double opt-in
  - Symfony mailer bridges (SES, Postmark, Brevo, Mailgun, SendGrid, Mailjet)

## Install

```bash
helm install mautic oci://ghcr.io/kopexa-grc/charts/mautic \
  --namespace mautic --create-namespace \
  --set mautic.siteUrl=https://mautic.example.com
```

The first start installs Mautic automatically. The generated admin password:

```bash
kubectl -n mautic get secret mautic -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

Expose it with your ingress controller **or** Gateway API:

```yaml
ingress:
  enabled: true
  className: nginx
  hosts:
    - host: mautic.example.com
      paths: [{path: /, pathType: Prefix}]
  tls:
    - secretName: mautic-tls
      hosts: [mautic.example.com]
# or
httpRoute:
  enabled: true
  parentRefs: [{name: shared-gateway, namespace: gateway-system}]
  hostnames: [mautic.example.com]
```

Verify the chart signature (keyless cosign):

```bash
cosign verify ghcr.io/kopexa-grc/charts/mautic:0.3.8 \
  --certificate-identity-regexp 'https://github.com/kopexa-grc/mautic-stack/.*' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

## Documentation

| Topic | |
|---|---|
| [Configuration](https://github.com/kopexa-grc/mautic-stack/blob/main/docs/configuration.md) | image commands, environment variables, Mautic parameters |
| [Production](https://github.com/kopexa-grc/mautic-stack/blob/main/docs/production.md) | sizing, scaling, storage, upgrades |
| [Backup and restore](https://github.com/kopexa-grc/mautic-stack/blob/main/docs/backup.md) | restic targets, restore procedure |
| [SAML SSO](https://github.com/kopexa-grc/mautic-stack/blob/main/docs/sso.md) | Keycloak, Google Workspace, Entra ID |
| [MCP for AI assistants](https://github.com/kopexa-grc/mautic-stack/blob/main/docs/mcp.md) | connect Claude, ChatGPT; tools and permissions |
| [OAuth 2.1](https://github.com/kopexa-grc/mautic-stack/blob/main/docs/oauth.md) | authorization server, security model |
| [Postal](https://github.com/kopexa-grc/mautic-stack/blob/main/docs/postal.md) | sending via SMTP, bounce webhooks |
| [Extensions](https://github.com/kopexa-grc/mautic-stack/blob/main/docs/plugins.md) | what is built into the image |
| [Limitations](https://github.com/kopexa-grc/mautic-stack/blob/main/docs/limitations.md) | known gaps (e.g. no IMAP bounce processing) |

Mautic supports MySQL/MariaDB only.

## Requirements

Kubernetes: `>=1.29.0-0`

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| backup.affinity | object | `{}` | Affinity for the backup pods (overrides `global`). |
| backup.configMapEnv | object | `{}` | Same for ConfigMap keys, e.g. RESTIC_REPOSITORY built from a bucket ConfigMap. |
| backup.dumpImage | object | `{}` | Image used for the dump; defaults to the bundled MariaDB image. |
| backup.dumpSizeLimit | string | `"10Gi"` | Size limit of the scratch volume holding the dump. |
| backup.enabled | bool | `false` | Enable scheduled restic backups (database dump + media). |
| backup.existingSecret | string | `""` | Secret whose keys are used as env vars as-is (envFrom), e.g. RESTIC_PASSWORD, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY. |
| backup.extraEnv | list | `[]` | Extra env vars for restic (e.g. RESTIC_COMPRESSION). |
| backup.includeMedia | bool | `true` | Back up uploaded media as well. |
| backup.nodeSelector | object | `{}` | Node selector for the backup pods (overrides `global`). |
| backup.podAnnotations | object | `{}` | Annotations of the backup pods. |
| backup.podLabels | object | `{}` | Extra labels of the backup pods. |
| backup.priorityClassName | string | `""` | PriorityClass of the backup pods. |
| backup.repository | string | `""` | restic repository, e.g. s3:https://s3.eu-central-1.amazonaws.com/my-bucket/mautic |
| backup.resources | object | `{"limits":{"memory":"512Mi"},"requests":{"cpu":"50m","memory":"128Mi"}}` | Resources of the backup job. |
| backup.resticImage | object | `{"digest":"","pullPolicy":"IfNotPresent","repository":"ghcr.io/kopexa-grc/restic","tag":"0.19"}` | restic image. |
| backup.retention | object | `{"keepDaily":7,"keepMonthly":6,"keepWeekly":4}` | restic forget/prune policy. |
| backup.schedule | string | `"17 2 * * *"` | Cron schedule of the backup CronJob. |
| backup.secretEnv | object | `{}` | Map env var -> {name, key} of a Secret, for secrets with other key names (External Secrets, ObjectBucketClaims, cloud operators), e.g.   RESTIC_PASSWORD:       {name: mautic-backup, key: restic-password}   AWS_ACCESS_KEY_ID:     {name: mautic-bucket, key: AWS_ACCESS_KEY_ID}   AWS_SECRET_ACCESS_KEY: {name: mautic-bucket, key: AWS_SECRET_ACCESS_KEY} |
| backup.timeZone | string | `""` | Time zone of the schedule (empty = controller default, usually UTC). |
| backup.tolerations | list | `[]` | Tolerations for the backup pods (overrides `global`). |
| backup.topologySpreadConstraints | list | `[]` | Topology spread constraints for the backup pods. |
| commonAnnotations | object | `{}` | Annotations added to every rendered object. |
| commonLabels | object | `{}` | Labels/annotations added to every rendered object. |
| containerSecurityContext | object | `{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"readOnlyRootFilesystem":true,"runAsNonRoot":true}` | Container security context (read-only root, no capabilities). |
| cron.affinity | object | `{}` | Affinity for the cron pods (overrides `global`). |
| cron.defaults | object | `{"activeDeadlineSeconds":3600,"backoffLimit":0,"concurrencyPolicy":"Forbid","failedJobsHistoryLimit":3,"resources":{"limits":{"memory":"1Gi"},"requests":{"cpu":"50m","memory":"256Mi"}},"startingDeadlineSeconds":300,"successfulJobsHistoryLimit":1,"timeZone":""}` | Defaults applied to every job (override per job). |
| cron.enabled | bool | `true` | Create CronJobs for Mautic's scheduled commands. |
| cron.jobs | object | `{"broadcasts-send":{"args":["mautic:broadcasts:send"],"schedule":"*/5 * * * *"},"campaigns-trigger":{"args":["mautic:campaigns:trigger"],"schedule":"10,25,40,55 * * * *"},"campaigns-update":{"args":["mautic:campaigns:update"],"schedule":"5,20,35,50 * * * *"},"contacts-scheduled-export":{"args":["mautic:contacts:scheduled_export"],"enabled":false,"schedule":"*/3 * * * *"},"doi-cleanup-submissions":{"args":["leuchtfeuer:doi:cleanup-submissions"],"schedule":"37 3 * * *"},"doi-send-followup":{"args":["leuchtfeuer:doi:send-followup"],"schedule":"17 * * * *"},"doi-update-timeout":{"args":["leuchtfeuer:doi:update-timeout"],"schedule":"27 * * * *"},"import":{"args":["mautic:import"],"enabled":false,"schedule":"*/3 * * * *"},"iplookup-download":{"args":["mautic:iplookup:download"],"enabled":false,"schedule":"11 3 1 * *"},"maintenance-cleanup":{"args":["mautic:maintenance:cleanup","--days-old=365"],"enabled":false,"schedule":"21 2 * * *"},"reports-scheduler":{"args":["mautic:reports:scheduler"],"schedule":"3 * * * *"},"segments-update":{"args":["mautic:segments:update"],"schedule":"0,15,30,45 * * * *"},"webhooks-process":{"args":["mautic:webhooks:process"],"enabled":false,"schedule":"* * * * *"}}` | Map of jobs: name -> {enabled, schedule, args, ...defaults} |
| cron.nodeSelector | object | `{}` | Node selector for the cron pods (overrides `global`). |
| cron.podAnnotations | object | `{}` | Annotations of the cron pods. |
| cron.podLabels | object | `{}` | Extra labels of the cron pods. |
| cron.priorityClassName | string | `""` | PriorityClass of the cron pods. |
| cron.tolerations | list | `[]` | Tolerations for the cron pods (overrides `global`). |
| cron.topologySpreadConstraints | list | `[]` | Topology spread constraints for the cron pods. |
| ephemeral | object | `{"tmpSizeLimit":"512Mi","varSizeLimit":"1Gi"}` | Size limits for the emptyDir volumes (/tmp and /app/var) of every Mautic pod, so a runaway process cannot fill the node's disk. |
| externalDatabase.database | string | `"mautic"` | Database name. |
| externalDatabase.existingSecret | string | `""` | Secret with connection fields (e.g. created by a DB operator); see `secretKeys`. |
| externalDatabase.host | string | `""` | Host of an external MySQL 8 / MariaDB 10.11+ database. |
| externalDatabase.password | string | `""` | Plain password (only if not read from existingSecret; stored in a Secret created by the chart). |
| externalDatabase.port | int | `3306` | Port. |
| externalDatabase.secretKeys | object | `{"database":"","host":"","password":"password","port":"","username":""}` | Keys in `existingSecret` per field; empty = use the plain value above. |
| externalDatabase.tablePrefix | string | `""` | Mautic table prefix. |
| externalDatabase.username | string | `"mautic"` | User. |
| extraObjects | list | `[]` | Extra manifests rendered with the release (strings are templated). |
| fullnameOverride | string | `""` | Override the full resource name prefix. |
| global | object | `{"affinity":{},"imagePullSecrets":[],"nodeSelector":{},"podAnnotations":{},"podLabels":{},"priorityClassName":"","tolerations":[],"topologySpreadConstraints":[]}` | Defaults for every pod (web, worker, cron, MariaDB, backup). A value set on a component (e.g. worker.nodeSelector) replaces the global one. |
| httpRoute.annotations | object | `{}` | HTTPRoute annotations. |
| httpRoute.enabled | bool | `false` | Create a Gateway API HTTPRoute (alternative to Ingress). |
| httpRoute.filters | list | `[]` | Gateway API filters of the rule. |
| httpRoute.hostnames | list | `[]` | Hostnames of the route. |
| httpRoute.matches | list | `[{"path":{"type":"PathPrefix","value":"/"}}]` | Path matches; filters can add headers, redirects, … |
| httpRoute.parentRefs | list | `[]` | e.g. [{name: public-gateway, namespace: gateway-system, sectionName: https}] |
| image | object | `{"digest":"","pullPolicy":"IfNotPresent","repository":"ghcr.io/kopexa-grc/mautic","tag":""}` | Mautic image (hardened, signed). `tag` defaults to the chart appVersion; `digest` pins it. |
| image.digest | string | `""` | Pin by digest (takes precedence over tag), e.g. sha256:… |
| image.tag | string | `""` | Defaults to the chart's appVersion. |
| imagePullSecrets | list | `[]` | Pull secrets for all pods. |
| ingress.annotations | object | `{}` | Controller-specific annotations (nginx, traefik, …) go here. |
| ingress.className | string | `""` | IngressClass, e.g. nginx or traefik. |
| ingress.enabled | bool | `false` | Create an Ingress. |
| ingress.hosts | list | `[{"host":"mautic.example.com","paths":[{"path":"/","pathType":"Prefix"}]}]` | Hosts and paths. |
| ingress.tls | list | `[]` | TLS configuration (secretName + hosts). |
| init.resources | object | `{"limits":{"memory":"1Gi"},"requests":{"cpu":"100m","memory":"256Mi"}}` | Resources of the init container (install + migrations). |
| mariadb.affinity | object | `{}` | Affinity for the mariadb pods (overrides `global`). |
| mariadb.auth.database | string | `"mautic"` | Database name. |
| mariadb.auth.existingSecret | string | `""` | Secret with keys mariadb-password and mariadb-root-password. Generated (and kept across upgrades) if empty. |
| mariadb.auth.username | string | `"mautic"` | Database user. |
| mariadb.config | string | `"[mysqld]\ncharacter-set-server = utf8mb4\ncollation-server     = utf8mb4_unicode_ci\nskip-name-resolve\nmax_allowed_packet   = 64M\ninnodb_buffer_pool_size = 256M\ninnodb_log_file_size    = 128M\n"` | Appended to /etc/mysql/conf.d/mautic.cnf |
| mariadb.enabled | bool | `true` | Deploy a single MariaDB StatefulSet (official image). Disable to use `externalDatabase`. |
| mariadb.image | object | `{"digest":"","pullPolicy":"IfNotPresent","repository":"docker.io/library/mariadb","tag":"11.4"}` | MariaDB image. |
| mariadb.nodeSelector | object | `{}` | Node selector for the mariadb pods (overrides `global`). |
| mariadb.persistence | object | `{"accessModes":["ReadWriteOnce"],"enabled":true,"size":"8Gi","storageClass":""}` | MariaDB data volume. |
| mariadb.podAnnotations | object | `{}` | Annotations of the mariadb pods. |
| mariadb.podLabels | object | `{}` | Extra labels of the mariadb pods. |
| mariadb.priorityClassName | string | `""` | PriorityClass of the mariadb pods. |
| mariadb.resources | object | `{"limits":{"memory":"1Gi"},"requests":{"cpu":"100m","memory":"512Mi"}}` | Resources of MariaDB. |
| mariadb.tolerations | list | `[]` | Tolerations for the mariadb pods (overrides `global`). |
| mariadb.topologySpreadConstraints | list | `[]` | Topology spread constraints for the mariadb pods. |
| mautic.admin.email | string | `"admin@example.com"` | Admin email address. |
| mautic.admin.existingSecret | string | `""` | Secret with the admin password. If empty, a random password is generated once and kept in <release>-mautic (key: admin-password). |
| mautic.admin.firstname | string | `"Admin"` | Admin first name. |
| mautic.admin.lastname | string | `"Mautic"` | Admin last name. |
| mautic.admin.passwordKey | string | `"admin-password"` | Key of the password in `admin.existingSecret`. |
| mautic.admin.username | string | `"admin"` | Admin user created on first install. |
| mautic.configParameters | object | `{}` | Any other Mautic parameter (merged last, wins), e.g.   { "default_timezone": "Europe/Berlin", "locale": "de" } |
| mautic.cors.restrictDomains | bool | `true` | Only allow the origins in validDomains. |
| mautic.cors.validDomains | list | `[]` | Allowed origins, e.g. [https://www.kopexa.com, https://kopexa.com] |
| mautic.existingSecret | string | `""` | Secret with Mautic's secret_key (key: secret-key). Generated if empty. |
| mautic.extraEnv | list | `[]` | Extra environment for all Mautic containers (web, worker, cron, init). |
| mautic.extraEnvFrom | list | `[]` | Extra `envFrom` sources for all Mautic containers. |
| mautic.ipLookup.authFrom | object | `{}` | Credentials from a Secret (valueFrom source). For MaxMind GeoLite2: "<account id>:<license key>", e.g. {secretKeyRef: {name: maxmind, key: auth}}. |
| mautic.ipLookup.service | string | `""` | Lookup service; empty = Mautic's default (maxmind_download, MaxMind GeoLite2, free account). |
| mautic.mailer.dsn | string | `""` | Symfony Mailer DSN, e.g. smtp://user:pass@smtp.example.com:587 Prefer existingSecret, since a DSN usually contains credentials. |
| mautic.mailer.dsnKey | string | `"mailer-dsn"` | Key of the DSN in `mailer.existingSecret`. |
| mautic.mailer.existingSecret | string | `""` | Secret holding the mailer DSN (preferred over `dsn`). |
| mautic.mailer.fromEmail | string | `""` | Default sender address. |
| mautic.mailer.fromName | string | `""` | Default sender name. |
| mautic.mcp.liveCampaignEdits | bool | `true` | Allow assistants to change RUNNING (published) campaigns. Such changes are live and Mautic may send emails because of them. Even when true, each client needs the scope mcp:campaigns:live, which users must tick explicitly on the consent page. false: running campaigns are read-only for MCP (dry runs still work). |
| mautic.messenger.email | string | `"doctrine://default"` | Messenger transport for emails (`doctrine://default` = queued in the DB, `sync://` = inline). |
| mautic.messenger.failed | string | `""` | Messenger transport for failed messages. |
| mautic.messenger.hit | string | `"doctrine://default"` | Messenger transport for page/email hits. |
| mautic.oauth.enabled | bool | `false` | Enable the OAuth 2.1 authorization server and the MCP endpoint `/mcp` for AI assistants. |
| mautic.oauth.existingSecret | string | `""` | Secret with `oauth-private-key` (RSA private key, PEM; signs access tokens) and `oauth-encryption-key` (encrypts codes and refresh tokens). Empty: the chart generates both once and keeps them across upgrades. |
| mautic.oauth.redirectHosts | list | `["claude.ai","claude.com","chatgpt.com","chat.openai.com","localhost","127.0.0.1"]` | Hosts that dynamically registered clients may redirect to (https, subdomains included). "localhost"/"127.0.0.1" allow loopback redirects of desktop clients (RFC 8252). |
| mautic.oauth.resource | string | `""` | Audience of issued tokens (RFC 8707). Empty: <siteUrl>/mcp. |
| mautic.php.maxExecutionTime | string | `"300"` | PHP max_execution_time in seconds. |
| mautic.php.memoryLimit | string | `"512M"` | PHP memory_limit of the web pods. |
| mautic.php.postMaxSize | string | `"64M"` | PHP post_max_size. |
| mautic.php.timezone | string | `"UTC"` | PHP date.timezone. |
| mautic.php.uploadMaxFilesize | string | `"64M"` | PHP upload_max_filesize. |
| mautic.postal.jwksUrl | string | `""` | Postal's JWKS, e.g. https://postal.example.com/.well-known/jwks.json (allow egress to it when networkPolicy.egress is enabled). |
| mautic.postal.publicKeyFrom | object | `{}` | Alternatively the webhook public key (PEM) from a Secret/ConfigMap:   publicKeyFrom: {secretKeyRef: {name: postal-webhook, key: public.pem}} |
| mautic.saml.attributes | object | `{"email":"","firstname":"","lastname":"","username":""}` | IdP attribute names (empty = Mautic defaults). |
| mautic.saml.defaultRoleId | string | `""` | Mautic role ID given to users created on their first SSO login. Create a restricted role first; role 1 is Administrator. |
| mautic.saml.enabled | bool | `false` | Enable SAML single sign-on (see docs/sso.md). |
| mautic.saml.entityId | string | `""` | SP entity ID registered at the IdP. Default: scheme://host of siteUrl. |
| mautic.saml.idpMetadata | string | `""` | IdP metadata XML — inline, or (preferred) from a ConfigMap/Secret:   idpMetadataFrom: {configMapKeyRef: {name: keycloak-saml, key: metadata.xml}} |
| mautic.saml.idpMetadataFrom | object | `{}` | IdP metadata XML from a Secret/ConfigMap (`valueFrom` source), alternative to `idpMetadata`. |
| mautic.saml.spCertificateSecret | string | `""` | Optional SP signing certificate: a kubernetes.io/tls Secret (tls.crt / tls.key), e.g. issued by cert-manager. |
| mautic.siteUrl | string | `""` | Public URL of the instance (required), e.g. https://mautic.example.com |
| mautic.trustedHosts | list | `[]` | Allowed Host header patterns (regex). Empty = Mautic default. |
| mautic.trustedProxies | list | `["10.0.0.0/8","172.16.0.0/12","192.168.0.0/16","100.64.0.0/10"]` | Networks whose X-Forwarded-* headers are trusted (ingress / gateway). |
| nameOverride | string | `""` | Override the chart name used in resource names. |
| networkPolicy.egress.dnsSelector | object | `{"namespaceSelector":{},"podSelector":{"matchLabels":{"k8s-app":"kube-dns"}}}` | Where cluster DNS runs (for the always-allowed DNS rule). |
| networkPolicy.egress.enabled | bool | `false` | Also restrict egress of all Mautic pods: DNS and the bundled MariaDB are always allowed, everything else must be listed in `to`. Limits what an attacker can reach after a code-execution bug (e.g. PHP2Shell). |
| networkPolicy.egress.to | list | `[]` | Allowed destinations (NetworkPolicy egress rules), e.g. SMTP relay, external DB, S3 for backups, webhook targets:   - to: [{ipBlock: {cidr: 10.20.0.0/16}}]     ports: [{port: 3306}]   - to: [{ipBlock: {cidr: 0.0.0.0/0, except: [10.0.0.0/8]}}]     ports: [{port: 587}, {port: 443}] |
| networkPolicy.enabled | bool | `false` | Restrict ingress: web only on its HTTP port, MariaDB only from this release's pods. |
| networkPolicy.webIngressFrom | list | `[]` | Peers allowed to reach the web pods. Empty = from anywhere. |
| persistence.accessModes | list | `["ReadWriteOnce"]` | With ReadWriteOnce, worker/cron/backup pods are scheduled onto the node of the web pod. Use ReadWriteMany for multiple web replicas across nodes. |
| persistence.annotations | object | `{}` | Annotations of the PVC. |
| persistence.enabled | bool | `true` | Persist uploads (media/files, media/images). Without it they live in an emptyDir. |
| persistence.existingClaim | string | `""` | Use an existing PVC. |
| persistence.size | string | `"10Gi"` | Size of the PVC. |
| persistence.storageClass | string | `""` | StorageClass of the PVC (empty = cluster default). |
| podSecurityContext | object | `{"fsGroup":65532,"fsGroupChangePolicy":"OnRootMismatch","runAsGroup":65532,"runAsNonRoot":true,"runAsUser":65532,"seccompProfile":{"type":"RuntimeDefault"}}` | Pod security context (Pod Security "restricted" compliant). |
| service.annotations | object | `{}` | Service annotations. |
| service.port | int | `80` | Service port. |
| service.type | string | `"ClusterIP"` | Service type. |
| serviceAccount.annotations | object | `{}` | ServiceAccount annotations (e.g. IRSA / workload identity). |
| serviceAccount.automountServiceAccountToken | bool | `false` | Mount the API token (Mautic does not need it). |
| serviceAccount.create | bool | `true` | Create a ServiceAccount. |
| serviceAccount.name | string | `""` | Name of the ServiceAccount (generated if empty). |
| test | object | `{"resources":{"limits":{"memory":"64Mi"},"requests":{"cpu":"10m","memory":"32Mi"}}}` | Resources of the `helm test` pod. |
| valkey.affinity | object | `{}` | Affinity for the valkey pods (overrides `global`). |
| valkey.auth.existingSecret | string | `""` | Secret with key valkey-password. Generated (and kept) if empty. |
| valkey.enabled | bool | `true` | Deploy Valkey (Redis-compatible, hardened kopexa image) for Mautic's cache and the PHP sessions. Shared sessions are what makes more than one web replica work; the cache takes load off the database. Disable to keep both on the local filesystem of each pod. |
| valkey.extraArgs | list | `[]` | Extra valkey-server arguments. |
| valkey.image | object | `{"digest":"","pullPolicy":"IfNotPresent","repository":"ghcr.io/kopexa-grc/valkey","tag":"9.1"}` | Valkey image. |
| valkey.maxmemory | string | `"256mb"` | Memory limit for data; least recently used entries are evicted. |
| valkey.nodeSelector | object | `{}` | Node selector for the valkey pods (overrides `global`). |
| valkey.podAnnotations | object | `{}` | Annotations of the valkey pods. |
| valkey.podLabels | object | `{}` | Extra labels of the valkey pods. |
| valkey.priorityClassName | string | `""` | PriorityClass of the valkey pods. |
| valkey.resources | object | `{"limits":{"memory":"320Mi"},"requests":{"cpu":"20m","memory":"64Mi"}}` | Resources of Valkey. |
| valkey.sessions | bool | `true` | Store PHP sessions in Valkey (logins survive switching web pods). |
| valkey.tolerations | list | `[]` | Tolerations for the valkey pods (overrides `global`). |
| valkey.topologySpreadConstraints | list | `[]` | Topology spread constraints for the valkey pods. |
| web.affinity | object | `{}` | Affinity for the web pods (overrides `global`). |
| web.apache | object | `{"maxRequestWorkers":25}` | Apache worker settings; `maxRequestWorkers` caps concurrent requests per pod. |
| web.autoscaling | object | `{"enabled":false,"maxReplicas":5,"minReplicas":1,"targetCPUUtilizationPercentage":80}` | HorizontalPodAutoscaler on CPU. |
| web.extraInitContainers | list | `[]` | Extra init containers for the web pods. |
| web.extraVolumeMounts | list | `[]` | Extra volume mounts for the web container. |
| web.extraVolumes | list | `[]` | Extra volumes for the web pods. |
| web.lifecycle | object | `{}` | Container lifecycle hooks, e.g. {preStop: {sleep: {seconds: 5}}} (Kubernetes >= 1.30) to let the ingress drain connections first. |
| web.livenessProbe | object | `{"httpGet":{"path":"/healthz","port":"http"},"periodSeconds":20,"timeoutSeconds":5}` | Liveness probe. |
| web.nodeSelector | object | `{}` | Node selector for the web pods (overrides `global`). |
| web.pdb | object | `{"enabled":false,"minAvailable":1}` | PodDisruptionBudget for the web pods. |
| web.podAnnotations | object | `{}` | Annotations of the web pods. |
| web.podLabels | object | `{}` | Extra labels of the web pods. |
| web.priorityClassName | string | `""` | PriorityClass of the web pods. |
| web.readinessProbe | object | `{"httpGet":{"path":"/mtc.js","port":"http"},"periodSeconds":10,"timeoutSeconds":5}` | Readiness probe (sends Host and X-Forwarded-Proto of `siteUrl`). |
| web.replicaCount | int | `1` | Number of web pods (ignored when autoscaling is enabled). |
| web.resources | object | `{"limits":{"memory":"1Gi"},"requests":{"cpu":"100m","memory":"512Mi"}}` | Resources of the web container. |
| web.sidecars | list | `[]` | Extra sidecar containers for the web pods. |
| web.startupProbe | object | `{"failureThreshold":60,"httpGet":{"path":"/mtc.js","port":"http"},"periodSeconds":5}` | Probes (override fully to customise). Readiness exercises PHP + Mautic via the tracking script, liveness only Apache. |
| web.strategy | object | `{}` | Defaults to Recreate with a ReadWriteOnce volume, RollingUpdate otherwise. |
| web.terminationGracePeriodSeconds | int | `30` | Grace period for in-flight requests on shutdown. |
| web.tolerations | list | `[]` | Tolerations for the web pods (overrides `global`). |
| web.topologySpreadConstraints | list | `[]` | Topology spread constraints for the web pods. |
| worker.affinity | object | `{}` | Affinity for the worker pods (overrides `global`). |
| worker.enabled | bool | `true` | Run Messenger queue workers (needed with `doctrine://` transports). |
| worker.memoryLimit | string | `"256M"` | Worker restarts after using this much memory. |
| worker.nodeSelector | object | `{}` | Node selector for the worker pods (overrides `global`). |
| worker.podAnnotations | object | `{}` | Annotations of the worker pods. |
| worker.podLabels | object | `{}` | Extra labels of the worker pods. |
| worker.priorityClassName | string | `""` | PriorityClass of the worker pods. |
| worker.replicaCount | int | `1` | Number of worker pods. |
| worker.resources | object | `{"limits":{"memory":"512Mi"},"requests":{"cpu":"50m","memory":"256Mi"}}` | Resources of the worker container. |
| worker.timeLimit | int | `3600` | Workers exit after this many seconds and are restarted (avoids leaks). |
| worker.tolerations | list | `[]` | Tolerations for the worker pods (overrides `global`). |
| worker.topologySpreadConstraints | list | `[]` | Topology spread constraints for the worker pods. |
| worker.transports | list | `["email","hit"]` | Messenger transports consumed by the workers. |

---

Apache-2.0 · [Kopexa](https://kopexa.com) · This README is generated from
`README.md.gotmpl` and `values.yaml` with
[helm-docs](https://github.com/norwoodj/helm-docs).
