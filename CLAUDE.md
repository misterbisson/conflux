# Working on conflux

conflux is a personal inference mesh for Apple devices. Start with
[README.md](README.md), then [docs/design.md](docs/design.md),
[docs/clients.md](docs/clients.md) and [docs/plan.md](docs/plan.md).

## Building

A Swift package, macOS 14 or later, with no dependencies beyond the SDK:

```bash
swift build
```

```bash
swift test
```

Tests use Swift Testing. CI runs both on every pull request, plus the
public-repository checks in `tools/ci/`.

## This repository is public

Everything here is public: files, commit messages, branch names, pull requests,
issues, review comments, CI logs and release notes. Write everything for that
audience.

### Clients are generic

conflux is a standalone tool. **Don't name or describe any specific application
that uses it**, and don't refer to private repositories, their issues or their
code. Write about "clients" and "client requirements." When a client's needs
shape a decision, state the need in general terms: "clients often treat
repeated timeouts as a dead server," not what a particular app does. This
applies even when the information is accurate and harmless.

Don't copy code from private repositories. Reimplement the pattern.

### No secrets

- No keys, tokens, passwords, certificates or provisioning profiles.
- No Apple Developer Team ID in tracked files. Signing settings go in a
  `*.local.xcconfig`, which is ignored.
- No iroh secret keys, and no endpoint IDs of real devices, in code, tests,
  logs or docs. Tests generate their own.

### No personal data

- **Test images are generated, or openly licensed** (CC0 or similar), with
  EXIF and other metadata, GPS especially, stripped before committing. Never
  personal photographs.
- Benchmark results are committed only as scrubbed summaries: device class and
  chip, not hostnames, serial numbers, IP addresses, Apple Account details or
  endpoint IDs. Raw output goes in `tools/bench/results/`, which is ignored.
- Logs and screenshots in issues and pull requests get the same scrubbing.

### No model weights

Weights are fetched, never committed. Document where a model comes from and
under what license. Some model licenses restrict redistribution or use, so
conflux points at models and doesn't ship them.

### Dependencies

Pin binary dependencies by version **and** checksum, the way
[apple-iroh](https://github.com/misterbisson/apple-iroh) releases are consumed.
A tag can be moved, a checksum can't.

apple-iroh is maintained alongside conflux, and other apps depend on it.
Changes to it must be additive, keep existing defaults, and be useful beyond
conflux.

## CI

The repository is public so GitHub's macOS runners are free. That also means
anyone can open a pull request that runs workflows. So:

- **Pin third-party actions by full commit SHA**, with the version in a
  comment, never by tag.
- Set **`permissions: contents: read`** at the top of every workflow, and grant
  more per job only where needed.
- **Never use `pull_request_target`** to build or run code from a pull
  request.
- **No secrets in workflows that pull requests can trigger.** Signing secrets,
  when they exist, live in a protected environment that runs only on `main` or
  tags.
- **No self-hosted runners.** On a public repository they run strangers' code
  on our machines.
- Keep the repository setting that requires approval before workflows run for
  first-time contributors.
- `tools/ci/check-public.sh` enforces what it can of this file: no weights or
  large files, no image metadata, pinned actions, no `pull_request_target`, no
  self-hosted runners and no secrets in workflows. Run it before pushing. When
  a rule here changes, change the check with it.
