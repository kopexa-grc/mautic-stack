# Kopexa Ops bundle (internal)

Operations commands of the kopexa Mautic image. Part of
[kopexa-grc/mautic-stack](https://github.com/kopexa-grc/mautic-stack), not
published.

| Command | Purpose |
|---|---|
| `kopexa:roles:sync [--json=…] [--dry-run]` | Create or update the roles in `MAUTIC_ROLES` (Helm: `mautic.roles`), matched by name, through Mautic's `RoleModel`. Run by `init` after the migrations. See [docs/sso.md](../../../docs/sso.md#roles). |
| `kopexa:cloud-storage:sync [--dry-run]` | Configure and publish Mautic's Amazon S3 plugin from `MAUTIC_S3_*` (Helm: `mautic.cloudStorage.amazonS3`), stored encrypted like the plugin dialog does. Run by `init` after the plugin reload. See [docs/plugins.md](../../../docs/plugins.md#amazon-s3-and-s3-compatible-storage). |
| `kopexa:privacy:strip-third-party-fonts [--dry-run]` | Removes the Google Fonts links Mautic wrote into stored pages, emails and dynamic content (`data-source="mautic"` only). Run by `init`. |

Behaviour of the role sync:

- existing roles with the same name are adopted (same ID, users stay);
- description, admin flag and permissions are set to the declared values,
  permissions replaced (Mautic computes the bitmasks);
- unchanged roles are not written; undeclared roles are never touched;
- unknown keys, bundles or permissions fail before anything is written.

Behaviour of the cloud storage sync:

- access key, secret, bucket, region and endpoint are set to the declared
  values and the plugin is published; unchanged settings are not written;
- the credentials come from the environment only and are never printed;
- without `MAUTIC_S3_*` the plugin is never touched.

Tests: `test/roles.sh`, `test/cloud-storage.sh` (smoke test) and the k3s
end-to-end test.
