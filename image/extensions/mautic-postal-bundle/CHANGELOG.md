# Changelog

## 0.1.0 – 2026-11-01

- Postal webhooks on Mautic's `/mailer/callback` route.
- Signatures are verified with RSA-SHA256, using either a fixed public key or Postal's JWKS (cached).
- Contacts are marked *Do Not Contact – bounced* on `MessageBounced` and on hard `MessageDeliveryFailed`.
- Requests without a Postal signature are left to other transports.
