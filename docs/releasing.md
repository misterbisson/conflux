# Releasing

The Mac and iPad apps reach testers through TestFlight. **GitHub checks, Xcode
Cloud ships:**

- **GitHub Actions** runs on every pull request. It builds and tests the
  package, and it does everything Xcode Cloud does to make a release short of
  signing it: generates the project with the same hook, archives Release with
  the same Xcode, and checks the app for what App Store Connect requires.
- **Xcode Cloud** runs when a `v*` tag is pushed. It archives the Mac app and
  the iPad app, signs them with the team's certificate, and uploads them to
  TestFlight for internal testers. It runs no tests; GitHub already has. Both
  are one app in App Store Connect, since they share a bundle ID, and 0.4.0 was
  the first release with both.

The repository is public, so most of what follows is about keeping secrets out
of it. Nothing that signs the app is in the repository or in GitHub, and nothing
needs to be: Xcode Cloud manages the certificates and profiles itself.

## What's in the repository

| File | What it does |
|---|---|
| [`project.yml`](../project.yml) | The app's two targets, for [XcodeGen](https://github.com/yonaskolb/XcodeGen): `conflux`, the Mac app, compiles `Sources/conflux`, and `conflux-ipad`, the same app for iPadOS with the same bundle ID, compiles `Sources/conflux-ipad`. Both use the package's `ConfluxCore` library. |
| [`App/`](../App) | The entitlements, the icon, the privacy manifest, and the signing settings, without a Team ID. |
| [`ci_scripts/ci_post_clone.sh`](../ci_scripts/ci_post_clone.sh) | Fetches the starter model and generates `conflux.xcodeproj`. Xcode Cloud runs it by name after cloning, once for each action, and it fails an action whose scheme doesn't fit its platform; GitHub's CI runs it too. |
| [`tools/ci/fetch-starter-model.sh`](../tools/ci/fetch-starter-model.sh) | Fetches the starter model both apps ship, SmolVLM-256M-Instruct, pinned by revision and checksum, into the ignored `App/StarterModel`. `check-app.sh` and `build-ipad.sh` check each app holds exactly those files. |
| [`.xcode-version`](../.xcode-version) | The Xcode that Xcode Cloud builds releases with, so GitHub can use the same one. |
| [`tools/ci/build-app.sh`](../tools/ci/build-app.sh) | Archives the app signed ad hoc, checks it, and runs it in the sandbox. |
| [`tools/ci/build-ipad.sh`](../tools/ci/build-ipad.sh) | Builds the iPad app for devices, unsigned, and checks its bundle ID, version and what it ships. The pinned llama.cpp framework has no iOS Simulator slice, so nothing runs. |
| [`tools/ci/retry.sh`](../tools/ci/retry.sh) | Runs a command again while it fails, for about eight minutes. The package's binaries come from GitHub's release downloads, which fail for minutes at a time, so the post-clone hook, the build scripts and CI fetch them through it before building. |
| [`tools/ci/check-app.sh`](../tools/ci/check-app.sh) | The checks: version, bundle ID, export compliance and its basis, category, a 512pt @2x icon, a privacy manifest that covers what the binaries import, the hardened runtime, the entitlements, and the embedded frameworks' versions. |
| [`tools/icon/make-icon.swift`](../tools/icon/make-icon.swift) | Draws the icon. It's a placeholder. |
| [`App/Credits.html`](../App/Credits.html) | The licences of the code and the starter model the app includes, shown in its About window. [`tools/notices/make-notices.py`](../tools/notices/make-notices.py) writes it; `check-app.sh` fails when it names other versions than `Package.swift` and `fetch-starter-model.sh` pin. |
| [`release-please-config.json`](../release-please-config.json) | How release-please versions conflux: tags `vX.Y.Z`, and `MARKETING_VERSION` in `project.yml` follows. `.release-please-manifest.json` holds the last version released. |
| [`tools/ci/check-commit-message.sh`](../tools/ci/check-commit-message.sh) | Checks a pull request's title and description, which become its commit message. |

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

The `conflux-ipad` scheme runs the iPad app on an iPad, signed the same way
([running.md](running.md#on-an-ipad)). To check it compiles the way CI does:

```bash
tools/ci/build-ipad.sh
```

Run `ci_scripts/ci_post_clone.sh` again after adding, renaming or removing a
file under `Sources/conflux` or `Sources/conflux-ipad`, or after changing
`project.yml`.

## Making a release

Releases come from [release-please](https://github.com/googleapis/release-please),
from the commit messages on `main`:

1. Each pull request's title is a [Conventional
   Commit](https://www.conventionalcommits.org/), because pull requests are
   squash merged and the title becomes the commit's subject. `feat:` makes the
   next release a minor version while conflux is below 1.0, `fix:` and `perf:`
   a patch version, and `docs:`, `test:`, `ci:` and the rest don't release by
   themselves. The [commit message](../.github/workflows/commit-message.yml)
   check holds a pull request until its title and description read the way
   they're meant to.
2. After each merge, the
   [release-please](../.github/workflows/release-please.yml) workflow opens or
   updates one release pull request. It sets `MARKETING_VERSION` in
   `project.yml`, adds the changes to `CHANGELOG.md`, and is titled
   `chore(main): release x.y.z`.
3. The release pull request gets the same CI as any other: the tests, the
   Release archive, the App Store Connect checks and the sandbox smoke test, on
   macOS. A pull request opened by a workflow can't start other workflows, so
   the release workflow starts them itself. With many merges in a day, each
   update replaces the build in progress, and only the latest one counts.
4. Merging the release pull request, whenever you choose, tags `vX.Y.Z` on
   `main` and makes a GitHub release. Xcode Cloud builds the tag and uploads it
   to TestFlight. So TestFlight gets one build per release, and only builds
   whose code passed CI.

`ci_post_clone.sh` fails an Xcode Cloud build whose tag isn't
`v` + `MARKETING_VERSION`, so a tag made by hand can't ship a mismatched build.
Xcode Cloud numbers the builds, so `CURRENT_PROJECT_VERSION` stays 1.

A build that uploads but never appears in TestFlight was usually refused by App
Store Connect after the upload: **read the email from App Store Connect before
the build log**, because the log shows success.

To release a version release-please wouldn't choose, end a pull request's
description with a line of its own, `Release-As: x.y.z`.

To change what a release says, edit the release pull request by hand: its
`CHANGELOG.md`, and the same section of its description, which becomes the
GitHub release's notes. release-please rewrites both after every merge to
`main`, so merge the release pull request before anything else, or make the
edit again.

release-please opens its pull request with the workflow's own token, which
needs one repository setting: **Settings > Actions > General > Workflow
permissions**, with **Read repository contents and packages permissions**
selected and **Allow GitHub Actions to create and approve pull requests**
on. Without it, the workflow pushes the release branch and then fails with
"GitHub Actions is not permitted to create or approve pull requests". Every
workflow still starts with `contents: read` and grants more per job.

The release pull request also shows a CI run and a commit message run waiting
for approval. Those are the `pull_request` runs, held by the setting that
asks before running a first-time contributor's workflows, which counts the
Actions bot. The runs the release workflow started cover the same checks on
the same commit, so the held ones can be left alone.

## Setting up Xcode Cloud

This lives in App Store Connect, not in the repository, so it's written down
here. It's done once. No step needs a Team ID, key or token in the repository.

1. **The bundle ID.** On developer.apple.com, under **Certificates,
   Identifiers & Profiles > Identifiers**, register an explicit App ID for
   `com.caseybisson.conflux`, with two capabilities, for the iPad app:
   **Increased Memory Limit** and **Extended Virtual Addressing**, which match
   its entitlements in `project.yml`. Xcode Cloud's automatic signing can't
   turn them on for an App ID registered by hand. Without them, the iOS
   archive builds and then its export fails with "Automatic signing cannot
   update bundle identifier" and "No profiles for 'com.caseybisson.conflux'
   were found". The Mac app doesn't claim them, so its profile is unaffected.
   The keychain access groups in the entitlements, for the
   [device directory](design.md#trust), aren't a capability there: the team's
   provisioning profiles allow any group with the team's prefix. They do need
   a profile, so a build signed by the team gets one (Xcode Cloud's, or
   Xcode's automatic signing on a desk), and an ad hoc build leaves them out
   (`tools/ci/build-app.sh`).
2. **The app record.** In App Store Connect, create a macOS app with that
   bundle ID. Its name there is "Conflux Inference Mesh"; plain "Conflux" is
   taken. The name under the icon stays "conflux", from `project.yml`.
3. **A tester group first.** In TestFlight, create an internal group and add at
   least one tester. The workflow's TestFlight step can't be saved until a
   group with a tester exists.
4. **Connect the repository, from a plain clone.** Clone the repository into a
   folder of its own, run `ci_scripts/ci_post_clone.sh`, and open
   `conflux.xcodeproj`. Open the Report navigator (⌘9), click **Cloud**, then
   **Get Started**, and choose the `conflux` product. When GitHub asks which
   repositories Xcode Cloud may read, choose only `misterbisson/conflux`.

   Don't start from a Git worktree nested inside another checkout of this
   repository. Xcode sees two copies of one repository there, and recreating a
   deleted workflow from one failed with nothing more than "An unexpected error
   occurred"; the same steps from a plain clone worked.

   Only the first workflow needs Xcode. After that, App Store Connect's Xcode
   Cloud page edits workflows and starts builds.
5. **The workflow:**
   - **Environment:** Xcode **Latest Release**, macOS **Latest Release**, and
     **Clean** on. Don't pin a version here; `.xcode-version` follows Xcode
     Cloud, not the other way round.
   - **Start conditions:** one, **Tag Changes**, for tags matching `v*`. Delete
     the default **Branch Changes** condition, and never add **Pull Request
     Changes** (see below).
   - **Actions:** one for each platform, each with **Distribution
     Preparation** set to **TestFlight (Internal Testing Only)**:
     - **Archive - macOS**: platform macOS, scheme `conflux`, Build For
       **Any Mac**.
     - **Archive - iOS**: platform iOS, scheme **`conflux-ipad`**. Not
       `conflux`: that scheme builds only the Mac app, and an iOS archive of
       it fails with "Unable to find a destination matching the provided
       destination specifier: { generic:1, platform:iOS }", followed by every
       simulator Xcode Cloud has. The post-clone hook stops such an
       action first, with a message naming the scheme to use.
   - **Post-actions:** one for each archive, to the group from step 3:
     **TestFlight Internal Testing - macOS** with Archive - macOS, and
     **TestFlight Internal Testing - iOS** with Archive - iOS.
   - **Environment variables:** none. The team comes from Xcode Cloud: the
     post-clone hook writes `CI_TEAM_ID` into `App/Signing.local.xcconfig`
     when it holds a Team ID, and otherwise leaves signing to Xcode Cloud's
     settings, logging the value's shape but not the value. The first build's
     `CI_TEAM_ID` wasn't the ten-character Team ID Apple's documentation
     describes.
   - **Restrict Editing:** on, if anyone else on the team should see the
     workflow without changing it.
6. **Build numbers.** In the app's Xcode Cloud **Settings**, let Xcode Cloud
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

## Export compliance and privacy

App Store Connect asks two questions of every upload that a build log never
shows, and refuses or holds the build by email when they go unanswered.

- **Export compliance.** `ITSAppUsesNonExemptEncryption` is `NO`: the app
  uses encryption, and none of it is non-exempt. The note beside it in
  [`project.yml`](../project.yml) lists every use of cryptography in the app,
  file by file, and [the reasoning](#export-compliance-the-reasoning) is
  below. `check-app.sh` fails when a source file not on that list uses Apple's
  cryptography or TLS, when the archive holds a bundled cryptography library
  other than apple-iroh's, and when `Package.swift` pins an apple-iroh version
  the note doesn't name. Any of those means answering again.
- **The privacy manifest.** [`App/PrivacyInfo.xcprivacy`](../App/PrivacyInfo.xcprivacy)
  says conflux collects nothing and tracks nothing, and gives the reason for
  each required-reason API it uses: file timestamps, for the model files the
  user picked, and `UserDefaults`, for its own settings. Apple enforces this
  for iOS and the other device platforms, not yet for macOS, but it costs
  nothing and stays true. `check-app.sh` scans the archived binaries,
  `llama.framework` included, and fails on a category that no manifest
  declares.

### Export compliance: the reasoning

The maintainer's determination, made on 2026-11-07 when conflux first linked
apple-iroh, and the reasoning behind it.

**What the app contains.** iroh compiles its cryptography into the app: rustls
with ring, not the operating system's libraries. It uses standard, publicly
accepted cryptographic protocols, IETF standards, rather than proprietary
cryptography:

- QUIC for transport;
- TLS 1.3 for the handshake and encryption;
- Ed25519 elliptic-curve keys for each device's identity and authentication.

It uses them to authenticate the user's own devices to each other and to
protect the requests and answers between them.

**Under the U.S. Export Administration Regulations (EAR):**

- *Publicly available, open-source software* is generally exempt from strict
  export controls, provided specific notification requirements are met. For
  open-source code containing strong encryption, like iroh's TLS 1.3 and
  Ed25519, to be exempt under License Exception TSU, the authors or exporters
  usually must send a one-time email notification with the source code's URL
  to BIS and the NSA, before or when it's made public.
- *Standard industry protocols.* Because QUIC, TLS 1.3 and Ed25519 are
  standard, mass-market-adjacent dual-use cryptographic mechanisms, commercial
  products incorporating them often fall under ECCN 5D002. These products can
  typically be exported globally under License Exception ENC (§ 740.17),
  provided the company files an annual Self-Classification Report with BIS.

**App Store Connect's questions:**

1. *Does your app use, access, contain, implement, or incorporate encryption?*
   Yes.
2. *Does your app qualify for an exemption?* Yes. Under the EAR, Category 5
   Part 2, the app qualifies for an exemption if it's considered a "mass
   market" product or uses cryptography only for standard authentication and
   data protection.

So `ITSAppUsesNonExemptEncryption` is `NO`. This is the maintainer's
compliance call, recorded here so a change to what the app contains is checked
against it. It isn't legal advice for anyone else's use of conflux.

## Not done yet

- **The icon** is a generated placeholder.
