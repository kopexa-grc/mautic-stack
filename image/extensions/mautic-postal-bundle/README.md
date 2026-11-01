# kopexa/mautic-postal-bundle

[Postal](https://docs.postalserver.io) integration for Mautic 7: bounces and
hard delivery failures reported by Postal mark the contact as
*Do Not Contact – bounced*, so Mautic stops mailing dead addresses.

## How it works

Postal sends webhooks to Mautic's transport callback endpoint
`POST https://<mautic>/mailer/callback`. The plugin:

1. verifies `X-Postal-Signature-256` (RSA-SHA256 over the body) against the
   Postal server's public key — from its JWKS
   (`https://<postal>/.well-known/jwks.json`) or a configured PEM;
2. handles `MessageBounced` and `MessageDeliveryFailed` (status `HardFail`)
   through Mautic's `TransportCallback` API (DNC reason *bounced*);
3. ignores all other events (sent, delayed, held, opens, clicks).

Unsigned or wrongly signed requests are rejected (403). Requests without a
Postal signature header are left to other transports.

## Configuration

| Parameter | Env (kopexa image) | |
|---|---|---|
| `postal_jwks_url` | `MAUTIC_POSTAL_JWKS_URL` | e.g. `https://postal.example.com/.well-known/jwks.json` (cached, default 1 h) |
| `postal_webhook_public_key` | `MAUTIC_POSTAL_WEBHOOK_PUBLIC_KEY` | PEM, takes precedence over the JWKS URL |

In Postal: *Server → Webhooks → Add webhook*, URL
`https://<mautic>/mailer/callback`, events **MessageBounced** and
**MessageDeliveryFailed**.

If egress is restricted (`networkPolicy.egress`), allow Mautic to reach the
Postal host on 443 for the JWKS, or configure the PEM instead.
