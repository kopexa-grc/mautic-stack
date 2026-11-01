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
- A user who logs in for the first time is created with
  `mautic.saml.defaultRoleId`. Create a restricted role in Mautic first —
  role `1` is Administrator.

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
       defaultRoleId: 2
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
