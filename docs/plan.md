# Plan

The order of work, and what has to be true before each phase is done. The
architecture is in [design.md](design.md). The client contract is in
[clients.md](clients.md).

Measure before building. Each phase ends with numbers, and the numbers decide
whether the next phase is worth doing.

## Phase 0: Measure, with no app

Find out how much one device can do, and how much more batching gets.

- **A load generator** in `tools/bench`: send a corpus of test images to an
  OpenAI-compatible endpoint at a chosen concurrency, and report completed
  requests per hour, latency percentiles, and prompt and completion tokens.
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

## Phase 1: One Mac, gateway and host

A macOS app that serves its own model to clients on loopback.

- Host: llama.cpp with one user-chosen model, slots set from Phase 0, resource
  policy, a self-check at load, and the states from the design.
- Gateway: the OpenAI-compatible API on loopback, the client contract (tokens,
  deadlines, `Retry-After`, request IDs, per-response `model` and
  `system_fingerprint`), and the status codes from [clients.md](clients.md).
- Settles the open question of linking llama.cpp in-process versus supervising
  `llama-server`.
- A simple window: the model served, state, active and completed requests,
  throughput.

**Done when:** an existing OpenAI-compatible client pointed at the gateway gets
the same answers as from `llama-server` directly, at the same or better
throughput, and never hits a client timeout while the mesh is busy.

## Phase 2: Several Macs over iroh

- apple-iroh: expose on hosts, forward from gateways (see
  [apple-iroh changes](#apple-iroh-changes)).
- Trust: per-device keys, published endpoint IDs in iCloud Keychain, the allow
  list.
- Scheduling: host pull, one request of prefetch on fast hosts, matching by
  model, preference list and capability, deadlines, retry on host loss, hedging
  at the tail.
- Monitoring: throughput per host and for the mesh, failures, idle time while
  compatible work waits.

**Done when:**

- the mesh's throughput comes close to the sum of each host's own throughput;
- idle-with-work time is near zero;
- closing a host's lid mid-run costs at most retries, with no lost or
  double-recorded results on a client that follows the contract.

## Phase 3: iPad hosts

- An iPadOS app sharing the host code: foreground serving with the screen kept
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

conflux needs three changes in
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
   over HTTP covers this in the meantime.

Every app links apple-iroh statically, pinned by version and checksum. So each
one adopts a release on its own schedule, and different apps' iroh versions
never have to match.

## CI

The repository is public, so GitHub's macOS runners are free. CI runs on every
pull request:

- build the macOS and iPadOS targets;
- unit tests: scheduling, admission, the contract's status codes and headers,
  identity and allow-list logic;
- later, the Phase 0 load generator against a small model on the runner, to
  catch regressions in the gateway, not to produce benchmarks.

Workflow rules, because the repository is public, are in
[CLAUDE.md](../CLAUDE.md#ci).

Code signing, notarization and TestFlight aren't in CI until they're needed.
When they are, the signing secrets go in a protected environment that pull
requests from forks can't reach.
