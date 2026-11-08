# Plan

The order of work, and what has to be true before each phase is done. The
architecture is in [design.md](design.md). The client contract is in
[clients.md](clients.md).

Measure before building. Each phase ends with numbers, and the numbers decide
whether the next phase is worth doing.

## Phase 0: Measure, with no app

Find out how much one device can do, and how much more batching gets.

- **A load generator**, `conflux-bench`, with `tools/bench/sweep.sh` to run it
  across slot counts: send a corpus of test images to an OpenAI-compatible
  endpoint at a chosen concurrency, and report completed requests per hour,
  latency percentiles, and prompt and completion tokens. *Built.* How to use
  it is in [phase-0.md](phase-0.md).
- **Batching on the largest Mac**: run `llama-server` with `--parallel` set to
  1, 2, 4 and 8, and measure throughput at each. Total context (`-c`) is split
  across slots, so it has to grow with `--parallel`, or long image prompts won't
  fit in a slot.
- **Image resolution**: throughput and answer quality against image token
  budget, at the size a task actually needs.
- **Sustained throughput on fanless devices**: an hour or more on a MacBook Air,
  watching thermal state. Burst numbers overstate what an overnight run gets.
- **Memory ceilings on iPads**: the largest model that loads and runs under
  iPadOS's per-app limit, with the increased-memory-limit entitlement, on 8 GB
  and 12 GB devices.

Test images must be generated, or openly licensed with metadata stripped (see
[CLAUDE.md](../CLAUDE.md)).

**Done when:** we have a throughput-against-slots curve for each device class we
care about, and a go or no-go on the expected gain.

*Progress:* M2 with 24 GB is measured ([measurements.md](measurements.md)).
On that device, extra slots barely help. Smaller images are much faster, but
the model measured reads them badly, so for it resolution isn't a free
lever. Still to measure: the M1 and M4 Pro MacBook Pros (16 and 48 GB), as
part of Phase 2's mesh measurements, and the M1 iPad Pro (8 GB) and M4 iPad
Air (likely 12 GB), whose memory ceilings the iPad build's memory probe
measures (Phase 3, step 1).

## Phase 1: One Mac, gateway and host

A macOS app that serves its own model to clients on loopback. *Built.* How to
run it is in [running.md](running.md).

- Host: llama.cpp with one user-chosen model, slots set from Phase 0, resource
  policy, a self-check at load, and the states from the design.
- Gateway: the OpenAI-compatible API on loopback, the client contract (tokens,
  deadlines, `Retry-After`, request IDs, per-response `model` and
  `system_fingerprint`), and the status codes from [clients.md](clients.md).
- Settles the open question of linking llama.cpp in-process versus supervising
  `llama-server`. *Settled first for `llama-server`, then for in-process,*
  because the sandboxed app Phase 2 needs can't run `llama-server`
  ([design.md](design.md#runtimes)). Both runtimes remain.
- A simple window: the model served, state, active and completed requests,
  throughput. Also `conflux serve`, the same thing without a window.

Left for later phases: streaming responses, and hedging, which needs a
second host and came in Phase 2.

**Done when:** an existing OpenAI-compatible client pointed at the gateway gets
the same answers as from `llama-server` directly, at the same or better
throughput, and never hits a client timeout while the mesh is busy.

## Phase 2: Several Macs over iroh

- Distribution: a sandboxed app built by Xcode Cloud and distributed with
  TestFlight, which iCloud Keychain needs. Models run in-process, which a
  sandboxed app can do. *Done:* release-please tags each release, Xcode Cloud
  builds the tag, and TestFlight delivers it ([releasing.md](releasing.md)).
- apple-iroh: expose on hosts, forward from gateways (see
  [apple-iroh changes](#apple-iroh-changes)). *Built*, on apple-iroh 0.9.0:
  each host serves the [host protocol](design.md#the-host-protocol) to its
  peers, and each gateway schedules to them.
- Trust: per-device keys, published endpoint IDs in iCloud Keychain, the allow
  list. *Built.* Each device lists its endpoint ID in iCloud Keychain and
  trusts the others listed there, kept up to date while running; hand-added
  peers stay, and are the only kind built from source. Syncing between
  devices is tested only in a signed build ([design.md](design.md#trust)).
- Scheduling: host pull, one request of prefetch on fast hosts, matching by
  model, preference list and capability, deadlines, retry on host loss, hedging
  at the tail. *Built.* Matching, deadlines and retry on host loss work across
  peers, and hosts admit work. Host pull and prefetch are built within the
  fixed connection direction: hosts answer a held status request when a
  slot frees, fast hosts take one request ahead, and a request that loses a
  slot to another gateway waits for the next one
  ([design.md](design.md#hosts-pull-the-gateway-holds-a-short-queue)). With
  fake hosts behind 40 ms of latency, a fast host's idle-with-work fell from
  about 2 s to 0.1 s over 30 requests. Hedging at the tail is built too: a
  request that runs past twice its host's typical time, while another host
  is idle and nothing waits, gets a copy there, and the loser is cancelled by
  request ID ([design.md](design.md#failures-and-stragglers)).
- Monitoring: throughput per host and for the mesh, failures, idle time while
  compatible work waits. *Built*: in the window's Monitoring section and in
  `/health` for clients with the token. Peers count their own free time, so
  a gateway sees the round trips its peers sit idle for
  ([design.md](design.md#monitoring)).

**Done when:**

- the mesh's throughput comes close to the sum of each host's own throughput;
- idle-with-work time is near zero;
- closing a host's lid mid-run costs at most retries, with no lost or
  double-recorded results on a client that follows the contract.

*Left*, in order. Everything so far is measured on one Mac, with peers as
separate processes.

1. A mesh benchmark in `tools/bench/`: the mesh's throughput against the sum
   of each host's own, idle-with-work time, and a run that loses a host
   partway, checking every request got exactly one result.
2. Running it on three Macs of different classes: M1 (16 GB), M2 (24 GB) and
   M4 Pro (48 GB), then closing a lid mid-run.
3. Trust syncing through iCloud Keychain, in the TestFlight build of 0.2.0.

None of the [apple-iroh changes](#apple-iroh-changes) blocks these.

## Phase 3: iPad hosts

One app, built for the Mac and for iPadOS: one bundle ID, one keychain access
group, one TestFlight record. An iPad is a host only. It serves its model to
the Macs' gateways, and runs no gateway and no clients, so it needs no token.

What Phase 2 showed about the iPad:

- The shared code builds for iPadOS 18, apple-iroh's floor, with two Mac-only
  parts set aside: the `llama-server` runtime, because iPadOS can't start
  processes, and the check that a loopback connection came from this
  process, because iPadOS has no libproc.
- Without that check, another app on the iPad could reach the host service
  and get around the gateway's token. So on iPadOS the host service refuses
  every connection until [apple-iroh change 4](#apple-iroh-changes) lands,
  and that change blocks iPad hosts.
- The pinned llama.cpp framework has no iOS Simulator slice. CI builds the
  iPad app for devices, and models are tested on a real iPad.

In order:

1. **A memory probe**, the iPad app's first version. It loads a model chosen
   on the iPad, runs the self-check, and records the memory the model took
   and what's left. A model too big for the per-app limit shows up as a probe
   killed while loading. Run with the increased-memory-limit entitlement on
   the M1 iPad Pro (8 GB) and the M4 iPad Air (likely 12 GB), it answers
   Phase 0's last question, and whether the rest of this phase is worth
   doing.
2. **apple-iroh change 4**, released with changes 1–3 and 5, and adopted by
   conflux on both platforms.
3. **The iPad host**: serving in the foreground with the screen kept awake,
   by default only while charging. When the app leaves the foreground it
   stops taking work and finishes what's running, and gateways send work
   elsewhere. It also needs the device directory on iPadOS, and models copied
   in from a Mac with Finder or the Files app.
4. **A host screen** meant to be read from across a room: state, model,
   throughput, temperature and charging.
5. **An overnight run** in a mesh with the Macs.

**Done when:** a plugged-in iPad runs a full night in a mesh, and its
contribution is measured against the effort of keeping it there.

## Phase 4: More runtimes and capabilities

- **Apple Foundation Models**, as a host runtime alongside llama.cpp, on
  macOS 26 and iPadOS 26 with Apple Intelligence turned on. It takes text and
  images, so it answers `any-vision` as well as `any`, and passes the same
  self-check before reporting Ready. The app's floors stay macOS 15 and
  iPadOS 18, so the runtime is offered only where the OS has it. The model
  is the system's, advertised as a capability rather than an artifact:
  conflux can't choose or pin its weights, which change with OS updates, so
  its identity is the OS build ([design.md](design.md#runtimes)). On devices
  that have it, it's a model that works with nothing to copy in.
- **A starter model in the app**, so a first request works before anyone
  has found a model: SmolVLM-256M-Instruct (Apache 2.0), Q8_0 with its Q8_0
  projector, about 280 MB together. It reads text and images. On an M2
  MacBook Air it read 88 of 90 self-check probes, in 0.45 s each, while
  SmolVLM-500M did worse, 55 of 60. Nearly every miss read a doubled letter
  once, so the self-check's text shouldn't repeat a character back to back.
  Its text answers are weak: it proves the plumbing, not the work.
  - The weights still aren't committed. The build fetches the file pinned
    by URL and SHA-256, as `tools/ci/fetch-test-model.sh` does for tests,
    and its licence goes in `App/Credits.html`.
  - Shipping it changes the rule in [CLAUDE.md](../CLAUDE.md) that conflux
    points at models and doesn't ship them. `tools/ci/check-public.sh` still
    keeps weights out of the repository.
  - It ships inside the app, not as a download the app makes, which risks
    App Store review.
- Capability requests and aliases beyond vision.
- MLX for artifacts that benefit from it.

## Phase 5: Hardening

- Tokens required by default.
- Fairness when several gateways share hosts, tested.
- Meshes across Apple Accounts, if wanted.
- A native client library over the same contract, if clients ask for one.

## apple-iroh changes

conflux needs four changes in
[apple-iroh](https://github.com/misterbisson/apple-iroh). Change 4 blocks
Phase 3's iPad hosts. The others make the mesh better, and nothing waits on
them, so they can go in the same release.
apple-iroh has other users, so each change is additive, keeps today's behavior
as the default, and has to be useful beyond conflux.

1. **Caller-chosen ALPN.** The protocol name is fixed today. Letting the caller
   choose it (`conflux/0`) makes a version mismatch fail at the handshake
   instead of as confusing HTTP errors. An endpoint can accept several ALPNs,
   so a user that later changes its own name keeps old and new builds talking
   during the switch.
2. **Opt-in local-network discovery (mDNS).** The default preset finds
   addresses through DNS and relays, so a LAN-only mesh can't form when the
   internet is down.
3. **A connection-closed signal.** For example a counter alongside the existing
   carried-bytes counters, so a gateway notices a lost host quickly. A heartbeat
   over HTTP covers this in the meantime. Measured on one Mac: a host that
   stops cleanly is noticed in about 2 seconds, because `apple_iroh_path`
   reports the closed connection, and a host killed outright in about 13, by
   three missed heartbeats.
4. **Forwarded ports that take only their own process's connections.** The
   loopback port `apple_iroh_forward` opens accepts any local process, which can
   then reach the peer's host without the gateway's token. An option to accept
   only connections from this process, or to forward a Unix socket instead,
   would close that. conflux's host side already checks.

One more would help, though nothing waits on it:

5. **Taking one ID off the allow list**, and closing its connection. Today
   the list only grows, or empties without closing anything, so conflux
   restarts its endpoint when a device leaves the mesh, dropping every peer's
   connection for a moment.

Every app links apple-iroh statically, pinned by version and checksum. So each
one adopts a release on its own schedule, and different apps' iroh versions
never have to match.

## CI

The repository is public, so GitHub's macOS runners are free. CI runs on every
pull request, with the Xcode that Xcode Cloud releases with:

- build and test the package: scheduling, admission, the contract's status
  codes and headers, the in-process runtime against a tiny model, device
  identity, the allow list and the device directory, and the host protocol
  between processes;
- archive the Mac app as Xcode Cloud does, signed ad hoc, check it for what App
  Store Connect requires, and run it in the sandbox;
- build the iPad app for devices (Phase 3), since the pinned llama.cpp
  framework has no iOS Simulator slice;
- later, the Phase 0 load generator against a small model on the runner, to
  catch regressions in the gateway, not to produce benchmarks.

Xcode Cloud signs releases and uploads them to TestFlight, from tags only. No
signing secret is in GitHub, protected or not: Xcode Cloud manages signing
itself. [releasing.md](releasing.md) has the details, and workflow rules,
because the repository is public, are in [CLAUDE.md](../CLAUDE.md#ci).
