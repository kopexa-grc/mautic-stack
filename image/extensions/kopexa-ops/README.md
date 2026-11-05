# Kopexa Ops bundle (internal)

Operations commands of the kopexa Mautic image. Part of
[kopexa-grc/mautic-stack](https://github.com/kopexa-grc/mautic-stack), not
published.

| Command | Purpose |
|---|---|
| `kopexa:roles:sync [--json=…] [--dry-run]` | Create or update the roles in `MAUTIC_ROLES` (Helm: `mautic.roles`), matched by name, through Mautic's `RoleModel`. Run by `init` after the migrations. See [docs/sso.md](../../../docs/sso.md#roles). |
| `kopexa:preferences:sync [--json=…] [--dry-run]` | Email preference center from `MAUTIC_PREFERENCE_CENTER` (Helm: `mautic.preferenceCenter`): topics (global categories), the preference page (theme `kopexa-preferences`), Mautic's unsubscribe settings. Run by `init` after the roles. See [docs/preferences.md](../../../docs/preferences.md). |
| `kopexa:privacy:strip-third-party-fonts [--dry-run]` | Removes the Google Fonts links Mautic wrote into stored pages, emails and dynamic content (`data-source="mautic"` only). Run by `init`. |

Behaviour of the role sync:

- existing roles with the same name are adopted (same ID, users stay);
- description, admin flag and permissions are set to the declared values,
  permissions replaced (Mautic computes the bitmasks);
- unchanged roles are not written; undeclared roles are never touched;
- unknown keys, bundles or permissions fail before anything is written.

Tests: `test/roles.sh` (smoke test) and the k3s end-to-end test.
