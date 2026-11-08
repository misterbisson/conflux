# Design

conflux turns the Apple Silicon devices one person already owns into a
**personal inference mesh**. Each Mac or iPad runs one local model and serves it
over [iroh](https://github.com/n0-computer/iroh). Clients spread independent
requests across every device that is currently willing to take them.

This document records the architecture and the decisions behind it. What a
client has to do is in [clients.md](clients.md). The order of work is in
[plan.md](plan.md).

## What it is for

Workloads made of many independent, small inference requests, where the job is
large because of the **number** of requests, not the size of any one. The
motivating case is bulk image analysis with small vision-language models:
hundreds of thousands of images, each a few seconds to a minute of inference.
On one machine, a job like that can run for months.

**The goal is gross throughput**: completed requests per hour across the whole
mesh. The latency of any single request matters only in that it must finish
inside the client's deadline.

## What it is not

- **Not distributed execution of one model.** No device ever holds part of
  another device's model. Every request runs entirely on one device.
- **Not a durable job queue.** Clients own their work: what still needs doing,
  what has been done, what to retry. conflux executes requests and returns
  results. A request lost with a host is retried, and nothing more is promised.
- **Not a cloud service.** There is no central server and no coordinator. A
  mesh is the devices that are running conflux at the moment.
- **Not tied to any one client.** Any application that can speak the client
  contract can use a mesh.

## Shape

```
client ──HTTP, loopback──▶ gateway (Mac) ──iroh──▶ host ──▶ runtime ──▶ model
                             │                     host ──▶ runtime ──▶ model
                             └── local host         host ──▶ runtime ──▶ model
```

There are three roles:

| Role | Runs on | Responsibility |
|---|---|---|
| **Host** | Mac, iPad | Runs one user-chosen model, admits or refuses work, executes it, reports its state |
| **Gateway** | Mac | Presents the client API on loopback, finds hosts, schedules requests across them, retries and hedges |
| **Client** | Anywhere the gateway is reachable | Owns the durable work, submits requests, records results |

The Mac app is both a gateway and a host. Its own model is just one more host,
reached without iroh. The iPad app is a host only.

The gateway is the "client-side scheduler" of a decentralized design. It runs
next to the client, not in the middle of the network. Two Macs can each run a
gateway for their own clients against the same hosts. They don't coordinate
with each other, because hosts decide admission (see
[Scheduling](#scheduling)).

### Why a loopback gateway, not a client library

Clients talk to the gateway over an **OpenAI-compatible HTTP API** on
`127.0.0.1`. That means:

- **Existing clients work.** Anything that can point at an OpenAI-compatible
  endpoint can use a mesh without linking anything.
- **iroh stays in one process.** The gateway owns the iroh endpoint, the
  keychain items, and the allow list. Clients need none of them.
- **The protocol inside the mesh can change** without changing clients.

A native client library may come later. It would be a convenience over the
same contract, not a separate protocol.

## Hosts

### One model at a time

A host serves exactly one model, chosen by the person running it. Changing
models is an explicit action on that device. The scheduler never loads,
unloads, or swaps models.

That choice removes model placement, load-cost estimation and cross-device
memory planning from the problem. A host's memory use is predictable. What it
offers stays stable until someone changes it.

**Different devices will serve different models.** Device memory limits what
each can run: an 8 GB iPad can't hold the same model as a 48 GB Mac. So a mixed
set of models is the normal case, not an exception, and every part of the
design assumes it.

### Slots

A host offers a number of **slots**: requests it will run at once. A slot may
be a serial execution or one sequence in a continuously batched set. The
scheduler doesn't need to know which, only how many slots are free.

Each host's slot count comes from measuring that device with its model
([plan.md](plan.md), Phase 0). Batching several sequences is often the biggest
single throughput gain on one device. Generating tokens is limited by memory
bandwidth, so one sequence leaves most of the GPU's compute unused.

### States

| State | Meaning |
|---|---|
| **Ready** | Model loaded, has free slots |
| **Busy** | Model loaded, every slot in use |
| **Draining** | Finishing what it has, accepting nothing new |
| **Paused** | Accepting nothing, by choice or by resource policy |
| **Starting** | Loading its model, or checking that the model reads its input |
| **Failed** | Can't serve until a person changes something, and says why |

**Offline** is not a state a host reports. The gateway infers it when a host
stops answering. Every host is treated as opportunistic: a MacBook's lid
closes, an iPad's app leaves the foreground, a desktop's owner starts something
heavy. The design assumes any host can disappear at any moment, mid-request.

### Resource policy

A host refuses work before it hurts the device. It watches:

- **Memory pressure**, not just free memory. Unified memory is shared by the
  CPU, the GPU and the rest of the system. Sources: `DispatchSource` memory
  pressure events, `os_proc_available_memory()` on iPadOS, Metal's
  `recommendedMaxWorkingSetSize`.
- **Thermal state** (`ProcessInfo.thermalState`). Fanless devices, meaning
  every iPad and MacBook Air, throttle under sustained load. A host lowers its
  slot count as it heats up, and pauses at `.critical`.
- **Power**: on battery or not, battery level, Low Power Mode.
- **Its owner**: a person can pause or drain a host at any time.

### Self-check

A vision model whose image encoder or projector fails doesn't report the
failure. It describes an image it never saw, fluently. So before a host reports
Ready, it renders five random characters in an image, asks the model to read
them, and checks the answer. It does this three times with fresh text, and
all three must pass, allowing one misread character in each. A working model
reads them every time. A model that can't see the image, or that reads it
badly because it's misconfigured, gets some right by luck, and one probe
wouldn't tell the difference. A host that fails the check reports Failed and
says why.

### iPad hosts

An iPad takes part while the app is in the foreground. The intended setup is an
iPad plugged in, on a stand, running overnight. The app:

- keeps the screen awake (`isIdleTimerDisabled`) while serving;
- requests the `com.apple.developer.kernel.increased-memory-limit` entitlement;
- withdraws from the mesh when it leaves the foreground, and finishes or gives
  up its in-flight work.

## Model identity

A model name like "a 4B vision model" isn't specific enough for clients that
keep results. Two hosts serving "the same model" can differ in:

- **the artifact**: weights, version, quantization, identified by a content
  hash;
- **the runtime**: engine and version;
- **preprocessing**: image resizing, token budgets, chat template.

Hosts advertise all three. Every response says which model produced it, in the
OpenAI `model` field, with runtime and artifact hash in `system_fingerprint`.
Clients record that per result ([clients.md](clients.md)).

**Results are not bit-for-bit reproducible**, even at temperature 0. Batch size
and hardware change the floating-point arithmetic. What is reproducible is
knowing exactly which configuration produced a result.

To keep results comparable, a given artifact runs on the **same runtime on
every host**. conflux won't serve one artifact through llama.cpp on one device
and through MLX on another under the same name.

## Scheduling

### Matching

A request names what it can accept:

- **An exact model**: only hosts serving that artifact.
- **A preference list**: the first available of several acceptable models, in
  the client's order.
- **Any model with a capability**, for example vision input: any host that
  qualifies.

conflux never decides that one model is "better" than another. Substitution
happens only as far as the client allows, and the response always names what
actually ran.

### Hosts pull, the gateway holds a short queue

A host with a free slot **asks** a gateway for work. Gateways don't push and
hope. A gateway keeps a control stream open to each host and tells it how much
compatible work it holds. When a slot frees, the host asks one of its gateways
for the next request, taking gateways in turn.

This gives the properties the design needs, without coordination between
gateways:

- **Work-conserving.** No slot sits idle while compatible work is waiting.
- **Proportional to speed, automatically.** A faster host frees slots more
  often, so it asks more often and takes more work. There are no performance
  weights to tune.
- **Admission belongs to the host.** It asks only when it can run the work.
  Gateways never race each other for a slot.
- **Fair between gateways.** The host takes them in turn.

A host asks for **one request more than it has free slots**. The next input is
then already transferred when a slot frees, so a network round trip never idles
the GPU. A slow host gets no extra request: a request waiting behind a long one
on a slow device can blow a client's deadline.

**How it's built today.** The gateway dials each host and the host never
dials back, so the host can't ask for work on a connection of its own.
Instead the gateway keeps a status request open to each host, and the host
answers it the moment its slots change ([The host protocol](#the-host-protocol)).
A freed slot reaches the gateway in half a round trip, and its next request
follows at once. Two things close the remaining gap:

- **One request ahead, on fast hosts.** When no host has a free slot, the
  gateway sends a request ahead to a fast host, where it waits for that
  host's next slot, ahead of anything else. A host holds one such request at
  most, whichever gateway sent it, and only if it would still finish inside
  its deadline after waiting behind a whole request. Fast means a typical
  time within 1.5 times the quickest host the request could use, and at most
  20 seconds. A slow host is never sent work to wait, and neither is this
  Mac's own host, which has no round trip to hide.
- **A lost slot isn't a lost request.** When two gateways send to the same
  free slot, the host takes one. A request to a fast host may wait there,
  if nothing else is waiting, so the other usually waits on the host
  instead. Otherwise the host says busy, and the gateway puts the request
  back in its queue for the next slot, on that host or another, rather than
  answering 429. Gateways still race for a freed slot. Taking them in turn
  is for later ([plan.md](plan.md), Phase 5).

### Deadlines

The gateway queues requests only briefly, and it **always answers inside the
client's deadline**: with a result, with 429 and `Retry-After` when no slot will
free up in time, or with 503 when hosts failed and time ran out. It doesn't send
a request to a host whose expected finish would pass the deadline. With this
guarantee, a client timeout means one thing: the gateway is stuck. A busy mesh
never looks like a dead one. See [clients.md](clients.md).

### Failures and stragglers

- **A host disappears mid-request**: the gateway sends the request to another
  host if the deadline allows, and otherwise answers 503.
- **The tail of a batch**: when the gateway's queue is empty and fast hosts are
  idle, it sends copies of requests still running on slow hosts to the idle
  ones, takes the first answer and cancels the rest. The client sees one
  answer. Request IDs make this safe ([clients.md](clients.md)).

  In detail: a request **straggles** once it has run twice its host's typical
  time, or three times for a request sent ahead, which may first wait behind
  a whole request. If nothing at all waits at the gateway, the gateway sends
  one copy of a straggler to the quickest host that has a free slot, serves
  a model the request accepts, and would finish inside its deadline. The
  first answer goes to the client and the other copy is cancelled: a host
  this gateway runs stops its task, and a peer's host is told by request ID
  ([The host protocol](#the-host-protocol)). A cancelled copy isn't a
  failure. A copy that fails while the other runs waits for the other. Both
  copies run inside the client's deadline, so the answer still comes in
  time, and a request with an `Idempotency-Key` still has one result. As
  soon as any request has to wait, copies still running are cancelled and
  their slots go to it: a copy never holds up new work. With a preference
  list, the copy can go to a host serving a less preferred model, as any
  request can, and the answer names the model that ran.
- **Idle-with-work is a bug.** The gateway counts time a compatible host spends
  idle while compatible work is waiting. That number should be close to zero,
  and it is the first one to look at when throughput disappoints.

### Monitoring

Each gateway keeps, for the mesh and for each host it schedules to:
completions and completions per hour, failures by kind (not answering,
server error, busy, out of the client's time), and idle-with-work seconds.
The window shows them, and so does `GET /health` for a client with the token
([clients.md](clients.md#the-api)).

Idle-with-work is measured where it happens. For this Mac's own host, the
gateway holds the slots, and the count is exact: seconds the host had a free
slot while a request it could run waited. A host on another device may have
a free slot the gateway doesn't know about yet, or be full with other
gateways' work, so it counts its own free seconds and reports them in its
status. The gateway counts the part of that free time spent while work for
that host waited here. Between two reports, it takes the share of the time
that work waited, which is exact while a mesh is saturated, the case the
number exists for. The mesh's figure is the hosts' added up.

## Transport and trust

### iroh, through apple-iroh

Hosts and gateways connect over iroh: QUIC with TLS 1.3, where each device's
identity is an Ed25519 public key. iroh hole-punches a direct path when it can
and falls back to a relay when it can't. That works whatever network each
device is on.

conflux uses [apple-iroh](https://github.com/misterbisson/apple-iroh), which
packages iroh as a static XCFramework behind a small C ABI. Its model fits
conflux as-is:

- A host runs an HTTP server on loopback and **exposes** that port over iroh.
- A gateway **forwards** a local port to each host's endpoint ID.
- Everything between them, including control streams, requests, results and
  cancellation, is HTTP over that forwarded connection.

Bandwidth is not a concern. An image sized for a vision model is a few hundred
KB, so even a fast mesh moves well under 1 MB/s, and a relayed path is fine.
Connection setup takes seconds, but it happens once per host per session.

The apple-iroh changes conflux needs are listed in [plan.md](plan.md). All of
them are additive, keep today's defaults, and stay compatible with apple-iroh's
other users.

### The host protocol

What a gateway and a host on another device say to each other, over the
forwarded connection. It's versioned in its paths, `/conflux/0/…`, until
apple-iroh lets conflux name its own ALPN.

- `GET /conflux/0/host`: the host's model, availability, the slots it takes
  work in now, how many are busy, how many requests are held waiting for a
  slot (`held`), its typical request time, how many seconds it has had a free
  slot since it started (`free_seconds`), and `generation`, which counts its
  status changes. With `Conflux-After: <generation>` and `Conflux-Wait:
  <seconds>` (5 at most), the host holds the request until its status has
  changed since that generation, or the wait is over. The gateway always
  has one of these open, waiting a second, so it hears of a freed slot at
  once. That's also the heartbeat: a connection iroh reports closed counts as
  lost at once, and three unanswered asks in a row count as lost too.
- `POST /conflux/0/complete`: one chat completion, with the time left in
  `Conflux-Timeout` and the copy's ID in `Conflux-Request-ID`.
  `Conflux-Prefetch: 1` says the request may wait on the host for a slot.
  `Conflux-Outcome` says what became of it: `completed`, `rejected` (the
  runtime refused it, a 4xx the gateway passes on), `unsuitable` (refused
  here, though another host might take it: content the model declined, or a
  request too long for it), `busy`, `unavailable`, or `cancelled`. A completion names the model that ran, as the host saw it.
  `Conflux-Slots: <generation> <capacity> <active> <held>` says how the
  host's slots stand once the request has left its slot, so the gateway can
  send the next request without waiting for the status that says the same.
- `POST /conflux/0/cancel`, with `Conflux-Request-ID`: stops that completion,
  running or waiting for a slot, and its answer says `cancelled` once it has
  left its slot. In-process, generation stops at the next token. A cancel
  that arrives before its request is remembered for a minute, and the
  request is answered `cancelled` without running.

**Admission belongs to the host.** A request from a peer's gateway runs only
if one of the host's slots is free now, whichever gateway sent it. It
queues there only if it was sent with `Conflux-Prefetch`, no other request is
held, and it would still finish in time after waiting behind a whole
request. Otherwise a host with no free slot says `busy`, and the gateway,
which holds the queue, waits for the next slot. No slot is promised twice.

A host from before host pull sends no `generation`, answers a status request
at once, and ignores `Conflux-Prefetch`. A gateway asks it every second and
sends it nothing ahead, as before.

A host that serves no model still answers, so its peers see "serves no model"
rather than silence.

**The host service accepts connections only from its own process.** It
listens on loopback, where apple-iroh delivers peers' streams, and it has no
token. So it checks that the other end of each connection is a socket this
process holds, which is true of apple-iroh's and of no other program's. The
gateway side has a gap: the loopback port apple-iroh opens for each peer
takes connections from any local process, which can then reach that peer's
host without the gateway's token. Closing it needs a change in apple-iroh
([plan.md](plan.md#apple-iroh-changes)).

### Trust

- **Each device keeps its own secret key.** It is stored in the keychain as
  `ThisDeviceOnly`, never synced, so a device's endpoint ID is stable across
  launches and no two devices can answer as one.
- **Each device publishes its public endpoint ID** to iCloud Keychain as a
  synced item, one item per device, keyed by the ID. The set of those items is
  the **device directory**, and the devices in it are trusted. It contains
  only devices signed in to the same Apple Account and running conflux.
- **Both sides accept only trusted IDs**, and an empty list accepts nobody. A
  device that can't read the directory trusts nobody from it, rather than
  everyone.
- **Devices refresh their published item regularly.** Items that stop being
  refreshed are eventually treated as gone.

**The item.** A generic password, synchronizable, in the data protection
keychain:

| Attribute | Value |
|---|---|
| service | `conflux.device` |
| account | the endpoint ID, 64 lowercase hex characters |
| access group | `<team ID>.com.caseybisson.conflux.devices` |
| accessible | after first unlock (a synced item can't be `ThisDeviceOnly`) |
| data | JSON: `{"name": "Studio", "published": "2026-11-07T12:00:00Z"}` |

`name` is the Mac's computer name, from Sharing settings, for the window.
`published` is when the device last wrote the item. Only the public key is in
it; the secret key is a separate item, in the app's own group, not synced.
An item that doesn't parse, or whose account isn't an endpoint ID, is
skipped, not trusted.

**The access group.** conflux uses its own service names and access groups,
and shares no keychain items with any other app. The app's entitlements give
two groups, both with the team's prefix as `$(AppIdentifierPrefix)`, so no
team ID is written in the repository: first the app's own,
`$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)`, which stays the default
and so keeps the device key where it was; then the directory's,
`$(AppIdentifierPrefix)com.caseybisson.conflux.devices`, which every build of
the app shares. A Debug build from Xcode has its own bundle ID, and so its own
key and its own entry in the directory: it's another device. The app finds the
directory's group in its own entitlements at launch. Built from source or
signed ad hoc, there's no group with a team prefix, so there's no directory,
and peers are added by hand.

**Joining, refreshing and leaving.** A device lists itself when the app opens
with **Find my Macs through iCloud Keychain** on, which is the default, and
rewrites the item when it's more than a day old or the Mac's name changed.
Items more than 30 days old are trusted by nobody and shown nowhere, so a Mac
that's been sold or wiped drops out on its own. Turning the setting off
removes this device's item, and stops it trusting the directory.

**Forgetting a device** removes its item, which iCloud Keychain then removes
from every device, so none of them trusts it. The forgotten device would put
the item back the next time it refreshed, so it remembers which ID it last
listed: finding that item gone, it knows it was forgotten, turns the setting
off and says so in its window. Its owner turns it on again to rejoin. A device
that's forgotten while conflux is closed there notices at its next launch, as
long as the deletion has synced by then.

**Hand-added peers stay.** They're trusted alongside the directory, and
they're the only source where there's no directory: `conflux serve`, `swift
run`, `swift test` and ad hoc builds. A device in both is trusted while
either says so. Each device shows its endpoint ID, and each hand-added peer
list names the others. The rules are the same: only listed IDs may connect,
trust is both ways, so a peer may use this device's host and this device's
gateway uses the peer's, and with no peers, conflux starts no iroh endpoint
and contacts nothing. The device key is in the keychain for a signed build;
built from source, it's in a file only the user can read, like the gateway's
token.

**Changes while running.** The keychain sends no notice when a synced item
changes, so a running node reads the directory every 10 seconds, and at once
after this device forgets one. iCloud Keychain takes its own time to sync,
often seconds and sometimes minutes, so that's the delay that counts.
apple-iroh checks its allow list as each connection arrives, and
`apple_iroh_allow` adds to it while the endpoint runs, so a new device joins
the running mesh. It has no call to take one ID off the list or close one
peer's connection, though, and `apple_iroh_allow_none` leaves held
connections open. So a device that leaves means a new endpoint, under the
same key, with the remaining peers: their connections drop and are dialled
again, and requests in flight to them fail over like any lost host. A
directory that can't be read keeps the peers it last gave, and the window
says why it couldn't be read.

The directory is behind a `DeviceDirectory` protocol, with the keychain one
for the app and one in memory for tests, so tests need no entitlements.

### Client authorization

The gateway listens only on loopback, but any process on the Mac can reach
loopback. So the gateway issues **API tokens**, which clients send as
`Authorization: Bearer`. Early versions may allow tokenless loopback access as
an opt-in setting, so that clients that can't send a token yet still work. The
setting is labelled for what it is.

Being a trusted peer (a device on the allow list) and being an authorized
client are separate questions, and the design keeps them separate. A mesh shared
between people later would need both.

## Runtimes

**llama.cpp first.** It has broad model support, GGUF quantization, Metal
acceleration, multimodal input for vision-language models, and continuous
batching across parallel sequences. It is also embeddable on iPadOS. One runtime
on every device also keeps results comparable ([Model identity](#model-identity)).

**Hosts link llama.cpp in-process**, on macOS and iPadOS alike. The trust
model keeps device IDs in iCloud Keychain, which an app gets only when it's
distributed through Apple: TestFlight or the App Store. Those apps run in the
App Sandbox, which can't start a Homebrew `llama-server`. So conflux links
the xcframework llama.cpp publishes with each release, pinned by version and
checksum, and runs models inside the app.

- Each slot gets its own llama.cpp context. The model's weights and the
  vision projector are shared, and the projector runs one image at a time.
- Requests become prompts the way llama-server builds them: the model's chat
  template, and images placed where llama.cpp would place them. Responses
  carry llama-server's `usage` and `timings`. With the same build, model and
  request at temperature 0, both runtimes give identical answers.
- What it costs: a crash inside llama.cpp takes the app down with it, and a
  context per slot doesn't batch across slots the way llama-server's
  continuous batching does. Phase 0 found extra slots add little on a base M
  chip; if Pro and Max chips show otherwise, the in-process host should batch
  too.

**`llama-server` stays as a second runtime** for the command line:
`conflux serve --runtime llama-server`. The host starts the process on a
loopback port, waits for it to load, runs the self-check, forwards requests,
and restarts it if it exits, giving up after four exits in five minutes. It's
useful for comparing the two and where crash isolation matters more than
distribution.

**Apple's on-device model** is the third runtime, through the Foundation
Models framework: the model Apple Intelligence uses, which reads text and
images from macOS 27 and iPadOS 27, conflux's floors. A device serves it
alongside its model file, as a second host, `apple-on-device`. It runs in a
system process, so it takes none of conflux's memory. conflux can't choose
or pin it, and it changes with OS updates, so its fingerprint is the OS
build. Its guardrails decline some content, and its context is small,
4,096 tokens on macOS 27.0, images included. A request it declines or can't
fit isn't the client's fault, so the host marks it for another host, and the
gateway tries one that serves an accepted model. The client sees the
refusal, a `400` with code `content_filter` or `context_length_exceeded`,
only when there's none.

Later candidates, each behind the same host interface:

- **MLX**: a strong option on Apple Silicon, for artifacts that run only there.

The runtime interface reports what each engine actually supports. It doesn't
pretend every engine accepts the same requests.

## Expectations

These are rough estimates, to be replaced by measurements:

- **Batching on one device** can multiply that device's throughput, because
  generating tokens is limited by memory bandwidth. Reading the image is limited
  by compute and benefits less. There, the image's token count is the main
  lever.
- **More devices** add roughly in proportion to their memory bandwidth for
  generation, and their GPU compute for image reading. Throttling on fanless
  devices reduces that.
- The two multiply: each host batches, and there are more hosts.

## Open questions

- **Slot counts** for each device class and model, and how quickly slots should
  drop as devices heat up. Phase 0 measures this.
- **Header names** for the deadline and the preference list. The ones in
  [clients.md](clients.md) are provisional.
- **Discovery without internet.** Whether apple-iroh's local-network discovery
  is enough for a LAN-only mesh when the internet is down.
- **Meshes shared between people**: trust beyond one Apple Account.
