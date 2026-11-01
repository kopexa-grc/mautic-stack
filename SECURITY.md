# Security policy

## Reporting a vulnerability

Please report vulnerabilities **privately** via
[GitHub Security Advisories](https://github.com/kopexa-grc/mautic-stack/security/advisories/new).
Do not open a public issue.

We aim to acknowledge reports within 3 business days.

## What is in scope

- The image, entrypoint, Helm chart and CI pipeline in this repository.
- A published image containing a vulnerable package **for which a fixed
  package exists in the Wolfi repository** but was not picked up.

Vulnerabilities in upstream software itself (Mautic, PHP, Apache, ...) should be
reported to the respective upstream project; we pick up fixes automatically
through the daily rebuild.

## Supported tags

Only the latest Mautic 7.x image and the latest chart version are supported
(`mautic:7`, `mautic:latest`). Dated tags are kept for
reproducibility and rollback but do not receive fixes.
