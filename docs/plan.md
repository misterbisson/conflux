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
part of Phase 2's mesh measurements, and the iPads' memory ceilings, which
the iPad build's memory probe measures (Phase 3, step 1). On the M1 iPad Pro
(8 GB) it has run only the starter model so far, which left 7.7 GB of the
8 GB iPadOS allowed. The 4B models clients use, and the M4 iPad Air (likely
12 GB), are next.

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
- Structured output, which clients that parse answers depend on. *Built*:
  `llama-server` follows `response_format` itself, and the in-process runtime
  turns it into the same grammar ([design.md](design.md#runtimes)). Both
  constrain the model alike, though `llama-server` wraps the answer
  differently, so they can return different valid JSON.

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
  compatible work waits. *Built*: in the window, beside each host and under
  Gateway, and in `/health` for clients with the token. Peers count their own
  free time, so a gateway sees the round trips its peers sit idle for
  ([design.md](design.md#monitoring)). Each host reports its hardware class,
  chip, cores and memory, so results can name each device's chip.

**Done when:**

- the mesh's throughput comes close to the sum of each host's own throughput;
- idle-with-work time is near zero;
- closing a host's lid mid-run costs at most retries, with no lost or
  double-recorded results on a client that follows the contract.

*Left*, in order. Everything so far is measured on one Mac, with peers as
separate processes.

1. A mesh benchmark in `tools/bench/`: the mesh's throughput against the sum
   of each host's own, idle-with-work time, and a run that loses a host
   partway, checking every request got exactly one result. Its requests
   should look like clients' ([below](#what-use-has-shown)): images with a
   schema to answer in, under a deadline.
2. Running it on three Macs of different classes: M1 (16 GB), M2 (24 GB) and
   M4 Pro (48 GB), then closing a lid mid-run.
3. Trust syncing through iCloud Keychain, in a TestFlight build: two Macs on
   one Apple Account finding each other with no peer added by hand. Not
   confirmed yet.

None of the [apple-iroh changes](#apple-iroh-changes) blocks these.

## Phase 3: iPad hosts

One app, built for the Mac and for iPadOS: one bundle ID, one keychain access
group, one TestFlight record. An iPad is a host only. It serves its model to
the Macs' gateways, and runs no gateway and no clients, so it needs no token.

What Phase 2 showed about the iPad:

- The shared code builds for iPadOS, with two Mac-only
  parts set aside: the `llama-server` runtime, because iPadOS can't start
  processes, and the check that a loopback connection came from this
  process, because iPadOS has no libproc.
- Without that check, another app on the iPad could reach the host service
  and get around the gateway's token. So on iPadOS the host service listens
  on a Unix socket in the app's container instead, which other apps can't
  reach, and [apple-iroh change 4](#apple-iroh-changes) carries peers'
  streams there.
- The pinned llama.cpp framework has no iOS Simulator slice. CI builds the
  iPad app for devices, and models are tested on a real iPad.

In order:

1. **A memory probe**, the iPad app's first version. It loads a model chosen
   on the iPad, runs the self-check, and records the memory the model took
   and what's left. A model too big for the per-app limit shows up as a probe
   killed while loading. Run with the increased-memory-limit entitlement on
   the M1 iPad Pro (8 GB) and the M4 iPad Air (likely 12 GB), it answers
   Phase 0's last question, and whether the rest of this phase is worth
   doing. *Built*, and from 0.4.0 delivered through TestFlight with the Mac
   app. On the M1 iPad Pro the starter model loaded in 12 s, took 0.3 GB and
   passed. The iPad Air (iPad15,6) also has 8 GB, not 12. Still to run: a 4B
   vision model, such as Qwen3-VL-4B or Gemma 3 4B, on each.
2. **apple-iroh change 4**, the host side: *built* in apple-iroh 0.10.0 as
   `apple_iroh_expose_unix`, released ahead of the other changes because it
   was the one blocking iPads. The forwarding side, below, is still open.
3. **The iPad host**: serving in the foreground with the screen kept awake,
   by default only while charging. When the app leaves the foreground it
   stops taking work and finishes what's running, and gateways send work
   elsewhere. It also needs the device directory on iPadOS, and models copied
   in from a Mac with Finder or the Files app. *Built*: a node with no
   gateway, which trusts the Macs in the directory and serves them over the
   socket ([running.md](running.md#on-an-ipad)). The first run on an iPad
   found its socket's path too long for apple-iroh, so its mesh never
   started; the name is now short enough. Not yet run on an iPad with a Mac
   using it.
4. **A host screen** meant to be read from across a room: state, model,
   throughput, temperature and charging. *Built*, at the top of the iPad
   app.
5. **An overnight run** in a mesh with the Macs.

**Done when:** a plugged-in iPad runs a full night in a mesh, and its
contribution is measured against the effort of keeping it there.

## Phase 4: More runtimes and capabilities

- **Apple Foundation Models**, as a host runtime alongside llama.cpp, with
  Apple Intelligence turned on. It reads images from macOS 27 and iPadOS 27,
  so those are conflux's floors. Apple's Private Cloud Compute model is left
  out: it runs off the device. *Built*: a device serves it alongside its
  model file, as a second host, `apple-on-device`, from the window or
  `conflux serve --apple-model` ([running.md](running.md#apples-on-device-model)).
  It answers `any-vision` as well as `any`, passes the self-check, and its
  fingerprint is the OS build ([design.md](design.md#runtimes)). Requests it
  declines, or can't fit in its 4,096 tokens, go to another host serving an
  accepted model, across the mesh too. On an M2 MacBook Air it read 57 of 60
  self-check images, in about 1 s each, and its misses each added a letter,
  so the self-check now allows one letter added or dropped as well as
  changed. It managed about 1.2 requests a second with two at once, little
  more with four or eight, so it gets two slots. A device serving both a
  model file and Apple's model is two hosts to every gateway in the mesh:
  the host protocol lists each host a device serves, and a gateway names
  the one it means in `Conflux-Host`, without a new protocol version
  ([design.md](design.md#the-host-protocol)). It follows `response_format`
  with its guided generation, and sends a schema asking for what that can't
  enforce, such as a `pattern`, to another host. An iPad serves it too,
  beside its model file or alone ([running.md](running.md#on-an-ipad)).
  It runs outside the app's memory limit, which may make the 8 GB iPad Pro
  a useful host.

  *Left*: measurements: how many tokens an image costs, throughput against
  Qwen3-VL-4B on the same images, both models at once on one Mac, how an
  iPad compares, whether it slows in the background, and how often the
  default guardrails decline ordinary images.
- **A starter model in the app**, so a first request works before anyone
  has found a model. *Built*: SmolVLM-256M-Instruct (Apache 2.0), Q8_0 with
  its Q8_0 projector, about 280 MB together, served until the person chooses
  a model, and listed first in the iPad probe
  ([running.md](running.md#the-starter-model)). It reads text and images. On
  an M2 MacBook Air it read 88 of 90 self-check probes, in 0.45 s each, while
  SmolVLM-500M did worse, 55 of 60. Nearly every miss read a doubled letter
  once, so the self-check's text no longer repeats a character back to back.
  On an iPad it swapped two neighbouring letters and failed the check, so a
  swap now counts as one mistake, like a misread letter.
  Its text answers are weak: it proves the plumbing, not the work. The build
  fetches it pinned by revision and checksum, so the weights still aren't
  committed, and it ships inside the app: the app fetches nothing from the
  internet, which would risk App Store review. An iPad copying the model a
  Mac in its mesh serves fetches nothing from the internet either.
- **Capability requests beyond vision**, so a client asks for the work a
  request needs rather than a model, and a large, slow model's slots go to
  the requests that need it ([design.md](design.md#capabilities-and-tags),
  [clients.md](clients.md#ask-for-what-the-work-needs)). Small models
  describe images well and quickly, but fall short at choosing and ordering
  among hundreds of items, work that a 31B model does well at many times the
  cost. In two steps:
  1. **Tags and holding back.** *Built.* The documented vocabulary and the
     owner's own tags, set on each model in the app beside its other
     settings, kept by model ID, with `conflux serve --tags`, and sent in
     the host protocol. A model that answers only when asked for
     (`--only-when-asked`). `context-<N>k` as a fact. Requests joined with
     `+`, the four aliases kept as other spellings, and `/v1/models`
     listing each model's tags and context. Apple's model tagged
     `image-description` by conflux, which the owner can change
     (`--apple-tags`). An iPad's models keep their defaults for now: its
     app has no place to set tags yet.

     *Built since:* suggestions for the models the README lists, in
     `ModelCatalog`, matched by header: a context per slot, slots and
     tokens per image where measurements say, and tags, with Gemma 4 31B
     held back for `editorial`, `image-critique`, `reasoning` and
     `writing`. Applied when a model is
     chosen, and by `conflux serve` for options not given. An iPad takes
     the tags, not yet the settings.
  2. **A request's expected time from its size**, timed per thousand prompt
     and written tokens on each host, for deadlines and for the choice
     between hosts ([design.md](design.md#deadlines)).

  **Done when:** a mesh serving Apple's model and a small model file beside
  a large one held back sends image descriptions only to the small ones,
  and requests for `editorial` only to the large one, without the client
  naming a model.
- MLX for artifacts that benefit from it.

## Apps on the same Mac

A sandboxed app can't read conflux's token, which sits in conflux's
container, so today it works only with "Require the token" off, and then any
process on the Mac can use the models. Nor can it start conflux's gateway, or
learn when the mesh changes, except by asking again and again. This work
lets such an app turn conflux on with a switch: it launches conflux, pairs
once with the person's approval, gets a token of its own, and follows the
mesh as it changes. No URL to type, no token to paste, and no concurrency to
tune.

Encryption isn't part of it. Other processes can't read loopback traffic, and
the token closes the hole that matters, any process using the models. What a
certificate would add is proof that the server on the port is conflux, which
the pairing reply could carry later as a fingerprint.

In order. Steps 1 and 4 stand alone. Step 3 needs step 2.

1. **Serving resumes at launch, and a launch by another app stays in the
   background.** The gateway used to start only when someone pressed Start,
   so an app that launched conflux found nothing listening. conflux records
   whether it was serving when it quit, and starts again if it was. A Mac its
   owner stopped stays stopped: an app launching conflux doesn't decide that
   a multi-gigabyte model loads. And conflux brings itself to the front only
   when run from the command line, the case that call is there for. Launched
   by another app with activation off, it stays behind.

   *Done when:* conflux, last quit while serving, launched with `NSWorkspace`
   and activation off, has its gateway up on its port, without taking focus.
   *Built*: it records serving at every start, stop and change of intent, so
   a crash keeps the owner's last choice, and paused or draining counts as
   not serving ([running.md](running.md#the-app)). Not yet checked by
   launching it from another app.

2. **A token for each paired app.** The gateway accepts the owner's token,
   as now, for the command line and `conflux-bench`, and one token for each
   paired app, kept the same way, in a file only this user can read. Each is
   tied to the app's bundle ID and Team ID, not to a name it gives. The window
   lists the paired apps, with their icons, when each was paired and last
   used, and **Revoke**: that app's next request gets `401`, and no other
   app's does. Turning "Require the token" off still lets any process in, as
   it says.

   *Done when:* tests show the gateway taking each token, refusing a revoked
   one, and comparing in constant time.
   *Built*, in the window's **Gateway** tab, under **Apps**, which shows
   once an app has paired: until step 3, none can. A revoke goes in the
   [mesh log](running.md#the-mesh-log). `conflux serve` takes only the
   owner's token.

3. **Pairing, through a `conflux://` URL.** The Mac app registers the
   scheme, and handles it in its app delegate, because a SwiftUI
   `onOpenURL` can open a second window. An app opens
   `conflux://pair?reply=<its own URL>`, and:

   - conflux identifies the app from its code signature, not from anything
     in the URL: bundle ID, Team ID, name and icon. The get-URL Apple Event
     carries the sender's audit token. *First, confirm* that it names the
     app that opened the URL, not LaunchServices. Either way, the reply URL
     must open in that same app, found with
     `NSWorkspace.urlForApplication(toOpen:)`, and if the two differ the
     request is refused. Then another app registering the reply scheme
     can't receive the token, and one claiming a name it isn't shows as
     itself.
   - conflux comes to the front and asks: "Let *App* use your models?",
     with its icon and developer. A build without a Team ID says it's from
     an unidentified developer.
   - On yes, it starts the gateway if it's stopped and can start, and opens
     the reply URL in that app, with `NSWorkspace.open(_:withApplicationAt:)`,
     carrying the app's token and the gateway's address,
     `http://127.0.0.1:<port>/v1`. On no, the reply says it was declined.
     The [mesh log](running.md#the-mesh-log) records which app was paired,
     declined or refused, never the reply, which carries the token.
   - An app already paired, with the same bundle ID and Team ID, is answered
     at once, without asking and without coming to the front, with the same
     token and the current address. So an app that loses its token, or finds
     nothing on the port it knew, pairs again and carries on.

   *Done when:* a sandboxed test app pairs with one approval and gets answers
   with its token; a second app that registered the same reply scheme gets
   nothing; and pairing again after the port changes gets the new address
   with no prompt.
   *Built*, with the pairing contract in
   [clients.md](clients.md#pair-for-an-app-on-the-same-mac). Confirmed with
   stand-in sandboxed apps and a sandboxed build: the Apple Event's audit
   token names the app that opened the URL, whether conflux was running or
   the URL launched it, and an app asking for a reply to another app is
   refused. The sandbox reads other apps' signatures only in `/Applications`
   and the system's folders, so an app has to be there to pair. Not yet run:
   an approval, a reply carrying a token, a request answered with it, and
   pairing again after the port changes.

4. **A notice when the gateway changes.** conflux posts a distributed
   notification, `com.caseybisson.conflux.gateway.changed`, when its gateway
   starts or stops, conflux quits, its owner drains, pauses or resumes it, the
   models served change, or the mesh's slots do. Slots move under memory
   pressure and heat, so notices are coalesced to at most one a second. A
   sandboxed app can't attach anything to a distributed notification, and
   nothing is needed: an app re-reads `/health` and `/v1/models` with its
   token. Anyone can post or watch the notice, and it says only that
   something changed.

   *Done when:* tests show which changes post a notice, and that a burst of
   slot changes posts one.
   *Built*, with the contract in
   [clients.md](clients.md#follow-the-gateway-for-an-app-on-the-same-mac).
   A host's slots are the ones the gateway can fill now, `capacity` in
   `/health`, which is none while a host starts, fails, is paused or drains,
   so those changes post too; how busy a host is doesn't. The app checks once
   a second, as it reads the window's numbers, and conflux launching and
   serving again posts one, which an app that launched it can wait for. It
   posts one last notice as it quits, once the gateway has stopped, even
   within a second of the one before. `conflux serve` posts none. Pairing
   or revoking an app posts one too, so a revoked app finds out from
   `/v1/models` without waiting for its next request, and so does turning
   "Require the token" on or off.

5. **The contract written down.** In [clients.md](clients.md): pairing, the
   reply, keeping the token in the app's keychain, pairing again when the
   gateway can't be reached, the notification, and sizing concurrency from
   the slots in `/health`. In [running.md](running.md), the paired apps and
   Revoke. In [design.md](design.md#client-authorization), tokens for each
   app.
   *Built*: most of it with steps 2 to 4, and last
   [sizing concurrency](clients.md#size-concurrency-from-the-slots), which
   replaces the advice to set a fixed concurrency at the mesh's peak. A
   client adds up `capacity` in `/health` over the hosts serving what it asks
   for, plus one for each host on another device, and reads it again on each
   notice. A fixed concurrency stays the advice for a client that can't
   follow the count.

**Done when:** a sandboxed client app with nothing typed into it launches
conflux in the background, pairs with one approval, gets answers with its
own token, widens and narrows its concurrency as Macs join and leave, and
loses access when revoked, while every other process still gets `401`.
*Every step is built.* What's left is running that check end to end with a
real client app. Each step was checked on its own, in tests and with
stand-in apps, as it says.

*Left for later:* a certificate fingerprint in the pairing reply; which app
sent each request, in the window's activity and in `/health`; and limits for
each app, if one app can crowd out another.

## Phase 5: Hardening

- Tokens required by default.
- Fairness when several gateways share hosts, tested.
- Meshes across Apple Accounts, if wanted.
- A native client library over the same contract, if clients ask for one.

## What use has shown

A client running real work through the app found more in a few days than
the benchmarks had. The measurements so far send one prompt
with no schema and an easy deadline, so the next ones should send work
shaped like clients'.

- **Clients depend on structured output.** The in-process runtime ignored
  `response_format` until 0.4.1, so a small model answered in a shape of its
  own, or in a code fence, and no answer parsed.
- **A schema has to require what the client needs.** A property that isn't
  required is optional, and a small model may leave out every one: with
  nothing required, Gemma 3 4B answers `{}`, under `llama-server` too.
  [clients.md](clients.md#ask-for-a-schema) says so.
- **Some bugs appear only in optimized builds.** The app aborted as soon as
  a request waited for a slot, until 0.4.3, from a Swift concurrency check
  that only Release builds trip. CI now runs the tests optimized as well as
  in debug.
- **Each model family needs its own settings**, and the self-check finds
  most of them before serving. Qwen-VL models read badly with fewer than
  1,024 image tokens. Apple's model declines some content and takes 4,096
  tokens. The starter model proves the plumbing, not the answers.
- **A request that names a model no host serves fails**, by design.
  Clients that accept `any`, or a preference list, keep working as hosts
  come and go.

## apple-iroh changes

conflux needs four changes in
[apple-iroh](https://github.com/misterbisson/apple-iroh). Change 4's
exposing side blocked Phase 3's iPad hosts, and is done. The rest make the
mesh better, and nothing waits on them.
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
   would close that. The exposing side is done: apple-iroh 0.10.0 can expose
   a Unix socket rather than a loopback port, which iPads use. The
   forwarding side, on the Macs' gateways, is still open.

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

- build and test the package, in debug and optimized: scheduling, admission,
  the contract's status codes and headers, the in-process runtime against a
  tiny model, structured output, device identity, the allow list and the
  device directory, and the host protocol between processes;
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
