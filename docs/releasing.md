# Releasing

The Mac app reaches testers through TestFlight. **GitHub checks, Xcode Cloud
ships:**

- **GitHub Actions** runs on every pull request. It builds and tests the
  package, and it does everything Xcode Cloud does to make a release short of
  signing it: generates the project with the same hook, archives Release with
  the same Xcode, and checks the app for what App Store Connect requires.
- **Xcode Cloud** runs when a `v*` tag is pushed. It archives the app, signs it
  with the team's certificate, and uploads it to TestFlight for internal
  testers. It runs no tests; GitHub already has.

The repository is public, so most of what follows is about keeping secrets out
of it. Nothing that signs the app is in the repository or in GitHub, and nothing
needs to be: Xcode Cloud manages the certificates and profiles itself.

## What's in the repository

| File | What it does |
|---|---|
| [`project.yml`](../project.yml) | The app target, for [XcodeGen](https://github.com/yonaskolb/XcodeGen). It compiles `Sources/conflux` against the package's `ConfluxCore` library. |
| [`App/`](../App) | The entitlements, the icon, and the signing settings, without a Team ID. |
| [`ci_scripts/ci_post_clone.sh`](../ci_scripts/ci_post_clone.sh) | Generates `conflux.xcodeproj`. Xcode Cloud runs it by name after cloning; GitHub's CI runs it too. |
| [`.xcode-version`](../.xcode-version) | The Xcode that Xcode Cloud builds releases with, so GitHub can use the same one. |
| [`tools/ci/build-app.sh`](../tools/ci/build-app.sh) | Archives the app signed ad hoc, checks it, and runs it in the sandbox. |
| [`tools/ci/check-app.sh`](../tools/ci/check-app.sh) | The checks: version, bundle ID, export compliance, category, a 512pt @2x icon, the hardened runtime, the entitlements, and the embedded frameworks' versions. |
| [`tools/icon/make-icon.swift`](../tools/icon/make-icon.swift) | Draws the icon. It's a placeholder. |

`conflux.xcodeproj` is generated and never committed. Xcode writes the signing
team into a project when you change signing in its editor, so a committed
project would sooner or later publish one.

## Building the app on a Mac

```bash
ci_scripts/ci_post_clone.sh
```

To sign it, add your Team ID to a file Git ignores:

```bash
cp App/Signing.local.xcconfig.example App/Signing.local.xcconfig
```

Then open `conflux.xcodeproj` and run the `conflux` scheme. Debug builds are
`com.caseybisson.conflux.dev`, so they keep their own container, settings and
privacy grants, apart from the TestFlight app. Without a Team ID it still
builds; to check an archive the way CI does, without one:

```bash
tools/ci/build-app.sh
```

Run `ci_scripts/ci_post_clone.sh` again after adding, renaming or removing a
file under `Sources/conflux`, or after changing `project.yml`.

## Making a release

Tag the commit on `main` and push the tag:

```bash
git tag v0.1.0
```

```bash
git push origin v0.1.0
```

The tag should match `MARKETING_VERSION` in `project.yml`. Xcode Cloud numbers
the builds, so `CURRENT_PROJECT_VERSION` stays 1. A build that uploads but never
appears in TestFlight was usually refused by App Store Connect after the upload:
**read the email from App Store Connect before the build log**, because the
log shows success.

## Setting up Xcode Cloud

This lives in App Store Connect, not in the repository, so it's written down
here. It's done once. No step needs a Team ID, key or token in the repository.

1. **The app record.** In App Store Connect, create a macOS app with the bundle
   ID `com.caseybisson.conflux`. Xcode registers the ID the first time it signs
   with automatic signing, if it isn't registered yet.
2. **A tester group first.** In TestFlight, create an internal group and add at
   least one tester. The workflow's TestFlight step can't be saved until a
   group with a tester exists.
3. **Connect the repository.** Run `ci_scripts/ci_post_clone.sh`, open
   `conflux.xcodeproj`, and choose **Product > Xcode Cloud > Create Workflow**.
   When GitHub asks which repositories Xcode Cloud may read, choose only
   `misterbisson/conflux`.
4. **The workflow:**
   - **Environment:** Xcode **Latest Release**, macOS **Latest Release**, and
     **Clean** on. Don't pin a version here; `.xcode-version` follows Xcode
     Cloud, not the other way round.
   - **Start conditions:** one, **Tag Changes**, for tags matching `v*`. Delete
     the default **Branch Changes** condition, and never add **Pull Request
     Changes** (see below).
   - **Actions:** one, **Archive - macOS**, scheme `conflux`, with
     **Distribution Preparation** set to **TestFlight (Internal Testing
     Only)**.
   - **Post-actions:** **TestFlight Internal Testing - macOS**, with that
     archive, to the group from step 2.
   - **Environment variables:** none. The Team ID comes from the build's own
     `CI_TEAM_ID`.
5. **Build numbers.** In Xcode Cloud's settings for the app, let Xcode Cloud
   manage the build number. Otherwise every build is number 1 and App Store
   Connect refuses the second.

### Why only tags

Anyone can open a pull request on a public repository. A pull request build in
Xcode Cloud runs the pull request's own `ci_scripts/`, on a machine where Xcode
Cloud has set up the team's signing. So conflux builds only tags there, and only
people who can push to the repository can push a tag. `ci_post_clone.sh` fails
a build that a pull request started, so a misconfigured workflow fails loudly,
but a hostile pull request can edit that script; the start condition is the
real protection.

## Keeping GitHub on Xcode Cloud's Xcode

Xcode Cloud always builds with the latest Xcode release. `.xcode-version`
records which one that is, and every macOS job in GitHub's CI selects it
([`select-xcode.sh`](../tools/ci/select-xcode.sh)) on the runner image that has
it ([`xcode-runner.sh`](../tools/ci/xcode-runner.sh)). That way a pull request
is built with the Xcode the release will be.

Two things notice when they drift apart:

- **Every Xcode Cloud build** prints its Xcode and `.xcode-version` near the
  top of the post-clone log, with a warning when they differ. The build goes
  on.
- **Once a week**, the [Xcode version](../.github/workflows/xcode-version.yml)
  workflow compares `.xcode-version` with Apple's
  [releases feed](https://developer.apple.com/news/releases/) and opens an issue
  when a newer Xcode is out. The issue lists which GitHub runner images have it.
  The workflow reads public pages and needs no token beyond the one GitHub gives
  every run.

To move to a new Xcode, change `.xcode-version` in a pull request, and fix
whatever the new Xcode finds there. If GitHub ships that Xcode on a differently
named runner image, change `xcode-runner.sh` too. GitHub's images get a new
Xcode some days after Apple releases it, and until then GitHub's CI is a version
behind Xcode Cloud.

## What only Xcode Cloud checks

GitHub's archive is signed ad hoc, so some things are first tested by the
TestFlight build:

- signing with the team's certificate and the profile Xcode Cloud makes;
- the hardened runtime's library validation, which needs the app and
  `llama.framework` to share a Team ID. Ad hoc signatures have none, so CI runs
  its sandbox check on a copy signed without the hardened runtime;
- App Store Connect's processing after the upload.

## Secrets and the public repository

- **No Team ID** in tracked files. It goes in `App/Signing.local.xcconfig`,
  which is ignored, or comes from Xcode Cloud's `CI_TEAM_ID`. Write examples as
  `<team ID>`, never a real-looking one.
- **No certificates, keys, profiles or export options** in the repository, and
  no App Store Connect API key anywhere. Xcode Cloud doesn't need any of them.
- **GitHub signs nothing.** No workflow uses the team's account or a signing
  secret.
- **The scripts print no environment.** `ci_scripts/` never traces commands or
  dumps variables, and never prints the Team ID.
- **Xcode Cloud builds tags only**, as above, and its GitHub access covers this
  repository only.

[`tools/ci/check-public.sh`](../tools/ci/check-public.sh) enforces what a
script can of this: it fails on a Team ID or provisioning profile setting in any
tracked file, on key, certificate, profile and export options files, on a
committed Xcode project, on a `ci_scripts/` file that isn't executable or that
prints the environment, and on a workflow that signs.

## Not done yet

- **Versions by hand.** Tags and `MARKETING_VERSION` are set by hand.
  release-please could do both from commit messages, as it does in similar
  repositories.
- **The icon** is a generated placeholder.
