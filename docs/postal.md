# Postal: sending and bounce handling

Mautic sends through our [Postal](https://docs.postalserver.io) server, via
Postal's HTTP API (recommended) or SMTP. Postal reports bounces and delivery failures back to Mautic via
webhooks, handled by
[`kopexa/mautic-postal-bundle`](https://github.com/kopexa-grc/mautic-postal-bundle).
Without that, Mautic keeps mailing dead addresses and the sender reputation
suffers.

```
Mautic ──HTTPS API / SMTP──▶ Postal ──▶ recipient MX
  ▲                 │
  │  POST /mailer/callback  (signed webhook: MessageBounced,
  └─────────────────┘                     MessageDeliveryFailed)
```

## 1. Sending

### Via Postal's HTTP API (recommended)

The bundle brings a mailer transport for Postal's API
(`/api/v1/send/raw`). Mautic hands over the finished message, so every
header (List-Unsubscribe, tracking) arrives unchanged, and bounces come back
through the webhook below as with SMTP. Compared to SMTP:

- HTTPS on 443 only: no SMTP port in the egress rules, no STARTTLS quirks;
- an API credential per Postal server, rejected requests are reported with
  Postal's error code (`InvalidServerAPIKey`, `UnauthenticatedFromAddress`);
- Postal's message ID is stored with the sent message.

Create an API credential in Postal (*Server → Credentials → API*) and store
the DSN as a Secret:

```bash
kubectl -n mautic create secret generic mautic-mailer \
  --from-literal=mailer-dsn='postal+api://API_KEY@postal.example.com'
```

```yaml
mautic:
  mailer:
    existingSecret: mautic-mailer
    fromEmail: newsletter@kopexa.com
    fromName: Kopexa
```

| DSN | |
|---|---|
| `postal+api://KEY@postal.example.com` | HTTPS on 443 |
| `postal+api://KEY@postal.example.com:8443` | HTTPS on another port |
| `postal+api://KEY@postal-web.postal:5000?tls=false` | plain HTTP, e.g. to Postal's web service inside the cluster |

The sender address (`fromEmail`) must belong to a domain that is verified on
that Postal server, otherwise Postal answers `UnauthenticatedFromAddress`.
With `networkPolicy.egress`, allow Mautic to reach the Postal host on 443
(the same rule the webhook key from the JWKS needs).

### Via SMTP

Create an SMTP credential for the mail server in Postal (*Server →
Credentials → SMTP*) and store the DSN as a Secret:

```bash
kubectl -n mautic create secret generic mautic-mailer \
  --from-literal=mailer-dsn='smtp://USER:PASSWORD@postal.example.com:25'
```

```yaml
mautic:
  mailer:
    existingSecret: mautic-mailer
    fromEmail: newsletter@kopexa.com
    fromName: Kopexa
```

Postal offers STARTTLS on port 25 (and 587 if enabled on the Postal side).

## 2. Bounces: the `/mailer/callback` endpoint

`POST https://<mautic-host>/mailer/callback` is **Mautic's built-in
transport callback route**. Mautic dispatches every request to it as an
`EmailEvents::ON_TRANSPORT_WEBHOOK` event; each installed transport
integration decides whether the request is meant for it. If nobody handles
it, Mautic answers `404`.

The Postal bundle handles a request only if it carries Postal's signature
header (`X-Postal-Signature-256`), so other transports keep working on the
same endpoint:

| Request | Response |
|---|---|
| No `X-Postal-Signature-256` header | not handled by this bundle (another transport or `404`) |
| Signature present, verification not configured | `503` |
| Signature does not match the Postal key | `403` |
| Valid, `MessageBounced` or `MessageDeliveryFailed` with status `HardFail` | contact → *Do Not Contact (bounced)*, `200` `{"handled": true}` |
| Valid, any other event (sent, delayed/soft fail, held, opened, clicked) | ignored, `200` `{"handled": false}` |

Bounces are recorded through Mautic's own `TransportCallback` API (the one
Mautic's transport integrations use), so they show up like any other
bounce: on the contact's timeline, in segment filters (*Do Not Contact →
bounced*) and in email statistics.

### Signature verification

Postal signs every webhook with its server key (RSA-SHA256 over the raw
body, base64 in `X-Postal-Signature-256`, key id in
`X-Postal-Signature-KID`) and publishes the public key as a JWKS at
`https://<postal-host>/.well-known/jwks.json`.

Configure one of:

```yaml
mautic:
  postal:
    # preferred: picks up key rotation automatically (cached for 1 h)
    jwksUrl: https://postal.example.com/.well-known/jwks.json
    # or a fixed public key (PEM) from a Secret/ConfigMap
    # publicKeyFrom: {secretKeyRef: {name: postal-webhook, key: public.pem}}
```

With `networkPolicy.egress.enabled`, allow Mautic to reach the Postal host
on port 443 for the JWKS — or use `publicKeyFrom`.

### Set up the webhook in Postal

*Server → Webhooks → Add webhook*:

- **URL:** `https://<mautic-host>/mailer/callback`
- **Events:** `MessageBounced`, `MessageDeliveryFailed` (others are accepted
  and ignored)
- **Enabled:** yes

The endpoint must be reachable from Postal over HTTPS through your ingress
or gateway. It is public by design; requests are trusted only after the
signature check.

## 3. Check that it works

From any machine with `openssl` and `curl`, simulate Postal with a test key.
This only passes if Mautic is configured with that test key
(`publicKeyFrom`), so do it on a staging instance:

```bash
openssl genrsa -out postal-test.pem 2048
openssl rsa -in postal-test.pem -pubout > postal-test.pub   # put into the Secret
body='{"event":"MessageBounced","payload":{"original_message":{"direction":"outgoing","to":"someone@example.com"}}}'
sig="$(printf '%s' "$body" | openssl dgst -sha256 -sign postal-test.pem | base64 -w0)"
curl -i -X POST https://<mautic-host>/mailer/callback \
  -H 'Content-Type: application/json' -H "X-Postal-Signature-256: $sig" --data-binary "$body"
```

In production, Postal's *Webhooks → Requests* log shows every delivery and
Mautic's response.

## Troubleshooting

| Symptom | Cause |
|---|---|
| Postal logs `404` | the request has no Postal signature header (proxy strips headers?) or the image predates the bundle — `docker run --rm <image> plugins` must list `kopexa/mautic-postal-bundle` |
| `503` | neither `mautic.postal.jwksUrl` nor `publicKeyFrom` is set |
| `403` | wrong key: JWKS URL of a different Postal instance, or an outdated PEM after a key rotation |
| `200` but contact not marked | the recipient address does not exist as a contact in Mautic |

The bundle's functional test
([kopexa-grc/mautic-postal-bundle](https://github.com/kopexa-grc/mautic-postal-bundle),
`tests/functional/`) exercises all of these paths; the image smoke test
(`test/smoke.sh`, section *Postal bounce webhook*) checks that the key from
`MAUTIC_POSTAL_WEBHOOK_PUBLIC_KEY` is used.
