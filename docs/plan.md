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
lever. The Pro and iPad device classes are still to measure.

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

Left for later phases: streaming responses and hedging (it needs a second
host).

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
  at the tail. *So far:* matching, deadlines and retry on host loss work across
  peers, and hosts admit work, refusing what they have no slot for. Pull,
  prefetch and hedging are next.
- Monitoring: throughput per host and for the mesh, failures, idle time while
  compatible work waits.

**Done when:**

- the mesh's throughput comes close to the sum of each host's own throughput;
- idle-with-work time is near zero;
- closing a host's lid mid-run costs at most retries, with no lost or
  double-recorded results on a client that follows the contract.

## Phase 3: iPad hosts

- An iPadOS app sharing the host code, in-process runtime included: foreground serving with the screen kept
  awake, the increased-memory-limit entitlement, and withdrawing cleanly from
  the mesh when the app leaves the foreground.
- A host screen meant to be read from across a room.

**Done when:** a plugged-in iPad runs a full night in a mesh, and its
contribution is measured against the effort of keeping it there.

## Phase 4: More runtimes and capabilities

- Apple Foundation Models as a system-provided capability, identified by OS
  build.
- Capability requests and aliases beyond vision.
- MLX for artifacts that benefit from it.

## Phase 5: Hardening

- Tokens required by default.
- Fairness when several gateways share hosts, tested.
- Meshes across Apple Accounts, if wanted.
- A native client library over the same contract, if clients ask for one.

## apple-iroh changes

conflux needs four changes in
[apple-iroh](https://github.com/misterbisson/apple-iroh), needed by Phase 2.
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
  codes and headers, the in-process runtime against a tiny model, and later
  identity and allow-list logic;
- archive the Mac app as Xcode Cloud does, signed ad hoc, check it for what App
  Store Connect requires, and run it in the sandbox;
- build the iPadOS target, once there is one (Phase 3);
- later, the Phase 0 load generator against a small model on the runner, to
  catch regressions in the gateway, not to produce benchmarks.

Xcode Cloud signs releases and uploads them to TestFlight, from tags only. No
signing secret is in GitHub, protected or not: Xcode Cloud manages signing
itself. [releasing.md](releasing.md) has the details, and workflow rules,
because the repository is public, are in [CLAUDE.md](../CLAUDE.md#ci).
