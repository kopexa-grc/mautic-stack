# Contributing

Thanks for helping! A few ground rules keep this project trustworthy:

- **Security issues** go to [private advisories](https://github.com/kopexa-grc/mautic-stack/security/advisories/new), never to public issues.
- Open an issue before larger changes so we can agree on the approach.
- Pull requests need green CI: build, tests, vulnerability gate (grype) and
  CIS checks (dockle). Do not weaken a gate to make a change pass — explain
  the finding instead.
- GitHub Actions are pinned to commit SHAs; Renovate keeps them current.
- Commits are squash-merged; write the PR title as the commit subject
  (`feat: …`, `fix: …`, `ci: …`, `docs: …`).

By contributing you agree that your contribution is licensed under the
Apache License 2.0.
