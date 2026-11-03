# Single sign-on (SAML)

Mautic has built-in **SAML 2.0** single sign-on. It does not support OIDC
natively, but every common identity provider speaks SAML: Keycloak, Google
Workspace, Microsoft Entra ID, Okta and authentik. The chart configures it
completely from values — no clicking through Mautic's settings.

Password login stays available for the local admin, so you keep break-glass
access if the IdP is down.

## How it works

- **Service provider (SP)** = Mautic, entity ID `https://<your-host>` by default
- **Assertion Consumer Service URL:** `https://<your-host>/s/saml/login_check`
- **Login URL (SP-initiated):** `https://<your-host>/s/saml/login`
- A user who logs in for the first time is created with the role
  `mautic.saml.defaultRole` (by name). Declare that role in the values (see
  [Roles](#roles)); nothing has to be clicked in Mautic.

## Keycloak

1. In Keycloak, create a client of type **SAML**:
   - Client ID: `https://mautic.example.com`
   - Valid redirect URI: `https://mautic.example.com/s/saml/login_check`
   - Name ID format: `email`
   - Mappers: *User Property* `email` → `email`, `firstName` → `firstName`,
     `lastName` → `lastName`
2. Download the IdP metadata from
   `https://keycloak.example.com/realms/<realm>/protocol/saml/descriptor`
   and store it:
   ```bash
   kubectl -n mautic create configmap keycloak-saml --from-file=metadata.xml=descriptor.xml
   ```
3. Configure the chart:
   ```yaml
   mautic:
     saml:
       enabled: true
       idpMetadataFrom:
         configMapKeyRef: {name: keycloak-saml, key: metadata.xml}
       attributes: {email: email, firstname: firstName, lastname: lastName}
       defaultRole: Marketing     # declared under mautic.roles, see below
   ```

## Google Workspace

1. Admin console → **Apps → Web and mobile apps → Add custom SAML app**.
2. Download the **IdP metadata** and store it as a ConfigMap (as above).
3. Service provider details:
   - ACS URL: `https://mautic.example.com/s/saml/login_check`
   - Entity ID: `https://mautic.example.com`
   - Name ID: *Basic information → Primary email*
4. Attribute mapping: *Primary email* → `email`, *First name* → `firstname`,
   *Last name* → `lastname`. Use the same names in `mautic.saml.attributes`.
5. Turn the app on for the organisational units that should have access.

## Roles

Roles are declared in the values and created or updated by the init
container (`kopexa:roles:sync`, through Mautic's own role model):

```yaml
mautic:
  roles:
    - name: Marketing
      description: Kampagnen, E-Mails, Kontakte
      permissions:
        lead:leads: [full]
        lead:lists: [full]
        email:emails: [full]
        campaign:campaigns: [full]
        form:forms: [full]
        page:pages: [full]
        asset:assets: [full]
    - name: Vertrieb
      permissions:
        lead:leads: [viewother, editother]
        report:reports: [viewother]
  saml:
    enabled: true
    defaultRole: Marketing
```

- **Matched by name.** A role that already exists with that name, created in
  the UI or by an earlier deploy, is adopted. It keeps its ID, so its users
  stay assigned, and is set to the declared description, admin flag and
  permissions. Permissions are replaced, not merged.
- **Declared roles belong to the values.** Changes made to them in the
  Mautic UI are overwritten at the next start (every rollout runs the init).
  Roles that are not declared are never touched.
- **Removing a role from the list does not delete it.** Delete it in Mautic
  once no user has it any more. Renaming a role in the values creates a new
  role; the old one stays with its users.
- **Idempotent.** A start without changes writes nothing (`unchanged` in
  the init log).
- **Validated.** Unknown keys, bundles or permissions fail the init with a
  message, before anything is written. The chart schema catches typos in the
  keys already at `helm template`.
- `isAdmin: true` makes a role administrator (all permissions; leave out
  `permissions`).
- `saml.defaultRole` must be declared in `roles` or already exist in Mautic.
  Otherwise the init fails, and running pods log a warning and start SSO
  without a default role. Set either `defaultRole` or the older
  `defaultRoleId`, not both.

### Common permissions

Each entry is `bundle:level: [permissions]`. `full` grants everything on
that level.

| Key | Area | Permissions |
|---|---|---|
| `lead:leads` | contacts | `viewown`, `viewother`, `editown`, `editother`, `create`, `deleteown`, `deleteother`, `full` |
| `lead:lists` | segments | `viewown`, `viewother`, `editown`, `editother`, `create`, `deleteown`, `deleteother`, `publishown`, `publishother`, `full` |
| `lead:fields` | custom fields | `view`, `full` |
| `lead:imports` | contact imports | `view`, `edit`, `create`, `delete`, `publish`, `full` |
| `email:emails` | emails | `viewown`, `viewother`, `editown`, `editother`, `create`, `deleteown`, `deleteother`, `publishown`, `publishother`, `full` |
| `campaign:campaigns` | campaigns | `viewown`, `viewother`, `editown`, `editother`, `create`, `deleteown`, `deleteother`, `publishown`, `publishother`, `full` |
| `form:forms` | forms | `viewown`, `viewother`, `editown`, `editother`, `create`, `deleteown`, `deleteother`, `publishown`, `publishother`, `full` |
| `page:pages` | landing pages | `viewown`, `viewother`, `editown`, `editother`, `create`, `deleteown`, `deleteother`, `publishown`, `publishother`, `full` |
| `asset:assets` | assets | `viewown`, `viewother`, `editown`, `editother`, `create`, `deleteown`, `deleteother`, `publishown`, `publishother`, `full` |
| `report:reports` | reports | `viewown`, `viewother`, `editown`, `editother`, `create`, `deleteown`, `deleteother`, `publishown`, `publishother`, `full` |
| `point:points` | points actions | `view`, `edit`, `create`, `delete`, `publish`, `full` |
| `stage:stages` | stages | `view`, `edit`, `create`, `delete`, `publish`, `full` |
| `focus:items` | focus items (popups) | `viewown`, `viewother`, `editown`, `editother`, `create`, `deleteown`, `deleteother`, `publishown`, `publishother`, `full` |
| `user:users`, `user:roles` | users, roles | `view`, `edit`, `create`, `delete`, `full` |

The full list for your instance is the role form in Mautic (*Settings →
Roles*); `kopexa:roles:sync` rejects anything Mautic does not know.

## Signed requests (optional)

If your IdP requires signed authentication requests, provide an SP
certificate as a `kubernetes.io/tls` Secret, e.g. issued by cert-manager:

```yaml
mautic:
  saml:
    spCertificateSecret: mautic-saml-sp   # keys tls.crt / tls.key
```

## OIDC-only identity providers

If an IdP offers only OIDC, put Keycloak (or authentik) in between as an
identity broker: Keycloak logs in against the OIDC provider and presents
SAML to Mautic.

Do **not** put the whole Mautic host behind an authenticating proxy such as
oauth2-proxy. Tracking pixels, forms, landing pages, unsubscribe links and
the API have to stay publicly reachable. If you want an extra gate, restrict
only the `/s/` path (the admin UI) at your ingress or gateway.
