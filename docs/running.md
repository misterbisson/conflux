# Running conflux

conflux runs a gateway on loopback, serving this Mac's own model with
llama.cpp and, when it has [peers](#peers-other-macs-models), other Macs'
models over iroh. The [iPad app](#on-an-ipad) is so far a memory probe; iPads
join the mesh as hosts later in Phase 3 ([plan.md](plan.md)).

## What you need

- macOS 27 or later, on Apple Silicon.
- A GGUF model and, for a vision model, its multimodal projector (`mmproj`).
  The [README](../README.md#models) suggests some and says where to get
  them. [phase-0.md](phase-0.md) says how to choose one and how many slots it
  should get. To try conflux first, the app has one: see
  [the starter model](#the-starter-model).

## The app

```bash
swift run -c release conflux
```

The window has three tabs: **Models**, for this Mac's models; **Mesh**, for
the devices it shares them with; and **Gateway**, for the endpoint its
clients use. In **Models**, under **Custom Model**, choose the model and
projector, or keep the [starter model](#the-starter-model), set the slots,
and press **Start**. Above the tabs, the window shows the host's state,
what's running, and the mesh's requests an hour and utilization, whichever
tab is open. At the top of each tab, a chart shows requests completed, or
tokens written, for each minute of the last hour or each ten minutes of the
last day, stacked by host, with a red mark where a host failed. Under the
chart are the requests waiting, conflux's memory (nearly all of it the
model's) against the Mac's, and the thermal state, over the same span. The
history is kept in memory, from when conflux opened.

Each host's own numbers are beside it: this Mac's models' under **Models**,
each peer's hosts in its row under **Mesh**. What became of the requests
clients sent the gateway, on any host, is under **Gateway**, in
**Requests**.

**Drain** finishes what's running and waiting and takes nothing new: on
this Mac's models, and at its gateway, which finishes the requests its clients
sent, wherever they run, and answers new ones `503` with `error.code`
`draining`. The window shows Draining until both are done. **Pause** takes
nothing new on this Mac's models straight away, while the gateway goes on
sending clients' work to peers. **Stop** ends serving and unloads the model.

The slots change while conflux runs; the other model settings need a stop.
More slots are made without reloading the model. Fewer free idle slots at
once. When requests are running in slots that go, conflux asks whether to let
them finish first or stop them now. A stopped request goes to another host
with a free slot, and with none, its client gets `429` and tries again.

**Serve a custom model** turns the model file on and off. Off, the section
folds to that switch, keeps the files and settings for later, and the Mac
serves only [Apple's model](#apples-on-device-model), when that's on. Each
model's switch works while conflux runs, as the slots do: on, the model
starts at once; off, it takes nothing new, and when requests are running on
it, conflux asks whether to let them finish first or stop them now, each
going to another host. Peers' gateways see the change at their next look.

### Which requests reach a model

Under each model, **Answers** and **Trusted with** say which requests reach
it, without clients naming it ([clients.md](clients.md#ask-for-what-the-work-needs)):

- **Reads** shows what conflux reads from the model's files and settings:
  text or images, and its context per slot. Clients can ask for those as
  `vision` and `context-<N>k`.
- **Answers**: *Requests for any model*, or *Only requests that ask for it*.
  Held back, the model answers its ID and its tags, but never `any` or
  `any-vision`, so a slow, capable model's slots stay free for the requests
  that need it.
- **Trusted with** is your judgement of the work the model does well: the
  documented tags, each with what it promises, and **Other tags** of your
  own. `image-description` and `image-critique` show only for a model that
  reads images.
- **Clients reach it with** lists what a client can send in `model` to reach
  it.

These change at once, while conflux serves, and peers' gateways see the
change at their next look. They're kept for each model, by its ID, so a
model chosen again gets its tags back. A model file starts with none, and
answers any request. [Apple's model](#apples-on-device-model) starts tagged
`image-description`, which you can untick.

With `conflux serve`, `--tags` sets the model file's tags, comma separated,
`--only-when-asked` holds it back, and `--apple-tags` sets Apple's model's,
`""` for none:

```bash
swift run -c release conflux serve --model ~/models/large.gguf --tags editorial,writing,reasoning --only-when-asked
```

**No slots** makes the Mac gateway only: it runs no requests itself, frees the
model's memory once its last request ends, and sends every request to its
peers. The model stays chosen, and peers can still copy it. Raising the slots
loads it again.

While it serves, conflux keeps the Mac from idle sleep, and the display
still sleeps. Drained or paused, it lets the Mac sleep once nothing it was
running or relaying is left; stopped, at once. A Mac left to idle sleep would
still be woken by peers' requests, start running them, and sleep again in the
middle, every few seconds. Closing the lid or choosing **Sleep** still sleeps
the Mac, and its peers send their work elsewhere.

Settings are kept between launches, and so is serving: conflux quit while
serving starts again when it next opens. Stopped, paused or draining, it
opens stopped. Opened by another app, such as a client launching it in the
background, it stays behind that app and doesn't take focus.

The app also comes from TestFlight ([releasing.md](releasing.md)). That build
runs in the App Sandbox, so it can open only the model files chosen in it, and
it keeps that access between launches. A file that's moved or renamed is
followed. One that's replaced, or on a disk that isn't connected, has to be
chosen again, and the app says so when you press **Start**.

### The starter model

The app includes one small model, so a client can get an answer before
you've chosen one: SmolVLM-256M-Instruct, by Hugging Face (Apache 2.0), with
its vision projector, about 280 MB. Until you choose a model, the app serves
it, as `SmolVLM-256M-Instruct-Q8_0`. It reads text and images, and passes the
self-check, but its answers are poor: it shows a client working through
conflux, not what a real model can do. **Use the starter model** goes back to
it.

`ci_scripts/ci_post_clone.sh` fetches it, pinned by revision and checksum,
with [`tools/ci/fetch-starter-model.sh`](../tools/ci/fetch-starter-model.sh).
Run from source with `swift run`, there's no app bundle and no starter
model.

## Without a window

```bash
swift run -c release conflux serve --model ~/models/model.gguf --mmproj ~/models/mmproj.gguf --slots 1
```

It prints the endpoint, then a line each time the host's state changes.
It keeps the Mac from idle sleep until it stops, as the app does while it
serves. `Ctrl-C` stops it. `conflux help` lists the options.

### Runtimes

llama.cpp is built into conflux, the same build Phase 0 measured, and
models run inside it. That's the only runtime the app uses, since a
sandboxed app can't start other programs.

`conflux serve --runtime llama-server` runs llama.cpp's own server as a
separate process instead, so a crash in the model can't take the gateway
down. It needs llama.cpp installed (`brew install llama.cpp`), and
everything after `--` is passed to `llama-server`. With the same llama.cpp
build, both runtimes give the same answers ([design.md](design.md#runtimes)).

### Apple's on-device model

The model Apple Intelligence uses can be served alongside the model file, as
`apple-on-device`. Turn on **Serve Apple's on-device model** in the
window, or add `--apple-model` to `conflux serve`. It needs Apple
Intelligence turned on in System Settings; until it is, or while Apple's
model downloads, the host says so and waits.

It reads text and images and passes the self-check, in about a second per
image on an M2 MacBook Air. It runs two requests at once by default
(`--apple-slots`), and its slots change while conflux runs, the way the model
file's do. Past a few, more slots add waiting, not throughput: in a saturated
mesh, an M1 MacBook Pro with 4 did 1,284 requests an hour at 11.3 s each,
and an M2 with 8 did 1,074 at 26.6 s ([measurements.md](measurements.md#mesh-saturated)).
A longer request leaves less of a client's deadline, and a gateway sends
nothing to a host it expects to finish too late. So raise them one at a time
while conflux runs, and stop when the host's requests an hour, under
**Apple's model** in **Models**, stop rising. Its guardrails decline
some content, and it takes only short requests. Those go to the model file's
host, or a peer's, when the client accepts that model: with
`Conflux-Models: apple-on-device, <model ID>`, for example. A request that
only Apple's model may run gets the refusal, a `400` with code
`content_filter` or `context_length_exceeded`. `/v1/models` marks it
`content_filter: true`, and `any-unfiltered` and `any-vision-unfiltered` leave
it out. conflux tags it `image-description`, since it describes images well
and quickly, and it's the same model on every Mac at an OS version: untick it
under **Trusted with**, or pass `--apple-tags ""`. Its tags are worth a look
after an OS update, which changes the model. It follows a
`response_format` schema with its guided generation, but a schema that asks
for what it can't enforce, such as a `pattern`, goes elsewhere the same way
([clients.md](clients.md#ask-for-a-schema)), and so do requests with tools.

Peers' gateways see both hosts, and send each request to the one serving a
model it accepts: a Mac that serves a model file and Apple's model is two
hosts in every gateway in the mesh. A peer still running a conflux from
before 0.10 shows its first host only, the model file's, or Apple's model
when it has no model file.

## Pointing a client at it

- **Endpoint:** `http://127.0.0.1:8090/v1`. Change the port with `--port`.
- **Token:** `swift run conflux token` prints it. Clients send it as
  `Authorization: Bearer <token>`. To allow clients that can't send one, use
  `--no-token`, or turn off "Require the token" in the app. Any process on
  the Mac can then use the gateway.
- **Apps:** an app on the Mac asks to use your models by opening
  `conflux://pair` ([clients.md](clients.md#pair-for-an-app-on-the-same-mac)),
  and conflux asks you, naming the app by its signature. One you allow gets
  a token of its own, which the app's gateway takes as well as yours. They're listed under
  **Gateway**, in **Apps**, with when each was paired and last used.
  **Revoke** takes one away: that app's next request gets `401`, and it has
  to ask again. `conflux serve` takes only the owner's token. The app tells
  apps on the Mac when the gateway changes, with a notice they watch
  ([clients.md](clients.md#follow-the-gateway-for-an-app-on-the-same-mac)),
  so they follow it without asking it again and again.
- **Model:** `any`, `any-vision`, `any-unfiltered` or `any-vision-unfiltered`
  (any model, or any vision model, other than Apple's, whose guardrails
  decline some content), what the work needs, such as
  `any+editorial+context-32k`
  ([clients.md](clients.md#ask-for-what-the-work-needs)), or the ID
  `/v1/models` lists, which is the GGUF file name without `.gguf`.

[clients.md](clients.md) has the full contract: deadlines, `Retry-After`,
request IDs, and recording which model answered.

## Peers: other Macs' models

Macs that name each other as peers use each other's models over
[iroh](design.md#transport-and-trust). A client of any of them sees every
peer's model in `/v1/models`, and its requests go to whichever host is free
and serves a model it accepts. Each response says which model ran.

**The TestFlight app finds the others itself.** On each Mac, sign in to the
same Apple Account with iCloud Keychain on (in System Settings, under the
Apple Account's iCloud settings), open conflux, and leave **Find my
Macs through iCloud Keychain** on in **Mesh**. Each Mac lists its endpoint ID
in iCloud Keychain and trusts the others listed there. They appear under
**Mesh**, by name, marked **From iCloud Keychain**, once iCloud Keychain has
synced, which can take a minute. A running Mac picks up new ones within
seconds of the sync, without a restart.

**Forget…** beside one removes it from every Mac, and no Mac trusts it. If
conflux is running there, it notices, turns the setting off and says so, and
stays out until it's turned on there again. Turning the setting off on a Mac
takes that Mac out the same way. A Mac that hasn't opened conflux for 30 days
is left out until it does.

**Peers can also be added by hand**, and built from source that's the only
way: iCloud Keychain needs the app signed by its team. Each Mac has an
endpoint ID, the public half of a key that never leaves it. Give each Mac the
others' IDs:

- **In the app:** **Pair by hand** shows this Mac's ID, with **Copy ID**.
  Paste the other Mac's ID beside **The other device's ID** and click
  **Add**, then **Start**. The Mac appears under **Mesh**, marked **Added by
  hand**.
- **Without a window:**

  ```bash
  swift run -c release conflux id
  ```

  prints this Mac's ID, and `--peer` names another's, once per peer:

  ```bash
  swift run -c release conflux serve --model ... --peer 3f2a...
  ```

  A Mac that serves no model can still use its peers': `conflux serve --peer
  3f2a...` with no `--model`, or, in the app, no slots.

Both Macs have to add each other. Until then, each refuses the other, and the
window counts the refused connections. A Mac with no peers, from iCloud
Keychain or by hand, starts no iroh endpoint and contacts nothing.

Under **Mesh**, the window shows each peer's state, its model, and whether
the connection is direct or relayed, with its round trip, and under each
peer, its hosts' throughput, failures and idle time. A host that has
failed says why the last failure happened and how long ago, so a peer that
keeps failing can be understood from this Mac, without going to it. The
mesh's are under **Gateway**, in **Requests**. `/health` with the token
gives the same numbers:

```bash
curl -s -H "Authorization: Bearer $(swift run -c release conflux token)" http://127.0.0.1:8090/health
```

"Idle while work waited" is time a host had a free slot while work it could
run waited at this gateway. It should stay near zero
([design.md](design.md#monitoring)). A peer that stops is shown as not
answering within seconds, and its requests go elsewhere or get a 503 with
`Retry-After`.

Two numbers need reading beside others:

- **Utilization counts only time a host is taking work.** A host paused for
  heat or memory offers no slots while it's paused, so an iPad that rests
  half the time can show 99% busy while doing half the work. Read its
  requests an hour beside it.
- **A host's failures aren't its clients'.** The chart's red marks and the
  failures beside each host count requests that failed on that host, and
  the gateway sends each to another host while the client's deadline allows.
  What clients got is the mesh's `answered` in `/health`: the busy (`429`),
  rejected and unavailable (`503`) answers the gateway gave.

To take a host out of a busy mesh without those failures, **Drain** it first
and **Stop** it once it's idle: once its own models and its gateway have
finished what they had. Stopped at once, every request running on it
fails there and goes elsewhere, and so does each request waiting at a
gateway that tries it before that gateway hears it has stopped.

To try it on one Mac, run two nodes with different identities and ports:

```bash
swift run -c release conflux serve --identity a --port 8091 --model ... --peer "$(swift run -c release conflux id --identity b)"
```

```bash
swift run -c release conflux serve --identity b --port 8092 --peer "$(swift run -c release conflux id --identity a)"
```

## The mesh log

The window and `/health` say how things stand now, and they're gone once
conflux quits. For a long run that went wrong, each device also keeps a log
of what happened, `mesh.log` ([Files](#files)). It says:

- **Each host's state as it changes**: serving, with its model and slots,
  and why it has fewer than it could; starting, paused or failed, and why;
  and how long the state before lasted. A state is written once it has held
  for five seconds, so a moment's blip isn't a line of its own, and a host
  that keeps changing gets at most a line a minute, saying how many changes
  it skipped. Each line has the time its state began. The first time a
  host serves, its line says what kind of device it's on.
- **Every five minutes, what each host did**: requests completed, declined
  and failed, by kind, and why the last failure failed. A host that did
  nothing gets no line. `gateway` says what clients were answered, the busy
  (`429`) and unavailable (`503`) answers included.
- **This device**: conflux starting, with its version, and stopping; the
  peers it trusts; the mesh or the device directory failing; and a Mac
  going to sleep and waking, or an iPad going to the background and back. A
  start with no stop before it means conflux quit without stopping, as a
  crash does.
- **Apps**, under `gateway`: an app paired, declined, answered again, or
  refused and why, and an app's token revoked.

```text
2026-11-15T00:11:35.204-08:00  node  started: conflux 0.9.0 (22), gateway on 127.0.0.1:8090, 0 peers added by hand, iCloud Keychain on
2026-11-15T00:11:36.010-08:00  node  trusts 2 peers: peer-3f2a9c41d0, peer-8b07e5d2c4
2026-11-15T00:11:41.388-08:00  peer-3f2a9c41d0  serving gemma-3-4b-it-Q4_K_M, 2 slots, on Mac14,15, Apple M2, 24 GB
2026-11-15T05:30:02.921-08:00  peer-8b07e5d2c4  last 5m: 3 completed, 176 unavailable; last failure: this device isn't taking work
2026-11-15T06:36:50.117-08:00  peer-3f2a9c41d0  starting: the peer isn't answering (serving for 6h 25m)
```

Hosts are named as `/health` names them: `local` and `apple` for this
device's, and `peer-` with the start of a peer's endpoint ID for a peer's.
A line can be written a few seconds after its time, so lines about different
hosts can be slightly out of order. The log moves aside to `mesh.log.1` at
4 MB, replacing the one before.

`conflux log` prints it, the older file first. Run from inside the app's
bundle, it reads the app's log, in the app's container:

```bash
/Applications/conflux.app/Contents/MacOS/conflux log
```

It names no device or person, only kinds of device, but a peer's ID belongs
to one device: replace them before posting a log in an issue. An iPad
writes its log in its app's container too, where nothing reads it yet.

## What the states mean

| State | Meaning |
|---|---|
| Starting | Identifying the model, loading it, or checking that it reads its input |
| Ready | Has a free slot |
| Busy | Every slot is in use. New requests wait briefly, then get `429` |
| Draining | Finishing what's running, taking nothing new |
| Paused | Taking nothing: by its owner, or because the Mac is too hot or short of memory |
| Failed | Can't serve until something changes: see the reason shown, and the log |

When the Mac gets hot or short of memory, or Low Power Mode is on, the host
halves its slots, keeping at least one. At critical heat or memory pressure it
pauses until things recover.

Pausing frees no memory. When memory pressure stays critical for a few
seconds, a model run in conflux's own process, the default runtime, is
unloaded, and requests running in it go to other hosts. The host says
*memory ran short*, and loads the model again by itself once pressure has
been normal for a minute, or longer if loading it brought the pressure
back. The **Memory pressure** tile shows the whole Mac's pressure, normal,
warning or critical, over the chart's span, and what conflux is doing about
it: *halved*, *paused* or *unloaded*. With `llama-server`, the host only
pauses.

**Cool down**, the box in the Heat tile, rests the host at serious heat too,
until it's back to fair, rather than letting it stay hot. It's off until you
check it, and it takes effect at once. A device that serves for hours while
charging stays hot, and heat ages a battery. The tile says what's happening
after the heat: "resting" while Cool down holds the host back, "halved" while
conflux has taken slots itself, and "paused" while conflux has paused it,
when the box is checked and can't be changed, since unchecking it couldn't
resume anything. iPadOS and macOS don't tell apps when they slow the chip
down, so the tile shows only what conflux does.

## If the self-check fails

Before serving, the host shows its model five random characters in an image
and asks it to read them back ([design.md](design.md), *Self-check*). A host
that fails says what the model answered, and passes on any advice llama.cpp
logged about it.

The usual cause is a model that needs an option to read images well. Qwen-VL
models, for one, read small images badly unless llama.cpp gives each image
at least 1,024 tokens. That model family needs:

```bash
swift run -c release conflux serve --model ... --mmproj ... --image-min-tokens 1024
```

In the app, set **Fewest tokens per image** to 1024.
Check the model's documentation for others. Turning the self-check off makes
the host serve anyway, and clients get the bad answers instead.

## On an iPad

The iPad app is the same app as the Mac's, built for iPadOS 27 or later. An
iPad is a host only: it serves its model to your Macs' gateways over iroh,
and runs no gateway, so clients never talk to it directly. It also has a
memory probe, which checks whether a model fits and records the memory that
took ([plan.md](plan.md), Phase 3).

**Installing it.** From TestFlight, like the Mac app
([releasing.md](releasing.md)): testers in the TestFlight group get both. Or
build it: with your Team ID in `App/Signing.local.xcconfig`
([releasing.md](releasing.md#building-the-app-on-a-mac)), generate the
project, open it, choose the `conflux-ipad` scheme and your iPad, and run.
Xcode's automatic signing adds the app's two memory capabilities, the
increased memory limit and extended virtual addressing, to its app ID the
first time.

**The starter model** is listed first, so there's something to serve or
check before you add a model.

**Adding models.** Models are listed under **Model files**, and a vision
model's projector is listed with them, with `mmproj` in its file name, as
llama.cpp names them. A model gets there in one of four ways:

- **Choose from Files…** opens the document picker, for the model and its
  projector together. A file on the iPad, in **On My iPad**, or on a USB
  drive, is used where it is, with no copy: conflux keeps its
  access to the file between launches, as the Mac app does. A file in iCloud
  Drive is copied in instead, because iCloud can remove the iPad's copy of a
  file it thinks isn't needed, and that isn't safe under a loaded model.
- **Sharing a file to conflux.** A GGUF file downloaded in Safari, or found
  in the Files app, can be opened in conflux from the share button. conflux
  copies it into its own folder, the one the Files app shows under **On My
  iPad › conflux**.
- **From a Mac, with a cable.** Connect the iPad, select it in Finder, open
  the **Files** tab, and drag the GGUF files onto conflux.
- **From a Mac in the mesh**, with no cable: see below.

A copy of a big model takes a while, and the screen shows how far it's got.
Keep conflux open until it's done. **Remove** beside a file used in place
forgets it, and the file stays where it is. **Delete** beside a copy deletes
it. When conflux can't reach a file used in place, it leaves the model
choices and stays under **Model files**, until you remove it, as one of two:

- *not connected*, when its drive isn't, or when conflux can't tell why.
- *missing*, when its drive, or the iPad's own storage, is there and the
  file isn't: deleted, or moved somewhere conflux can't follow it. A file
  moved on the same drive is followed.

conflux looks for both again each time it comes to the foreground and before
you choose from Files, so a drive connected again, or a file put back, shows
its models without reopening conflux. conflux never removes either by
itself: **Remove** forgets one.

**Getting a model from your Macs.** A Mac running conflux offers the model
it serves, and its projector, to the devices it trusts, and **Get a model
from your Macs** lists each Mac in the mesh with what it offers: both files
and their sizes, whether the pair will likely fit this iPad's memory with one
slot and a typical context (the same estimate as for a chosen model, below,
without the model's header, which is on the Mac), the storage it takes and
what's free, and how the Mac is connected. **Get this model** copies the
pair here over the mesh: the files come from your own Mac, and nothing from
the internet. To reach its Macs while it isn't serving, the iPad runs its
mesh with no model while conflux is open, so a Mac sees it as serving none.

- **Direct or relayed.** Connected directly, on the same network, it says
  about how long the copy will take at 25 MB/s, what one iroh connection
  managed between two processes on one Mac
  ([design.md](design.md#iroh-through-apple-iroh)). An iPad over Wi-Fi may
  be slower. Connected through a relay, it warns that the copy is slow, and
  estimates it at 5 MB/s at best, which can mean tens of minutes for a large
  model. Allowing Local Network, on the same network as the Mac, lets iroh
  connect directly.
- **While it copies**, it shows how much has arrived, the rate, and about how
  long is left, and keeps the screen awake. Keep conflux open: in the
  background iPadOS suspends it, and the copy stops. **Stop** stops it too.
  **Resume** carries on where it stopped, even after conflux was closed, and
  **Discard** throws away what has arrived. Starting to serve waits until
  it's done or stopped, since serving restarts the connection to the Macs.
- **Each file is checked.** It's written to a partial file in conflux's
  Application Support folder, and kept only once its SHA-256 matches the
  Mac's. A resumed copy asks for the rest of the same version of the file:
  if the Mac's file changed meanwhile, conflux throws away what it had and
  says to get the model again.
- **Where it goes.** Once both files are checked, they move together into a
  folder named for the model, in conflux's folder in Files, and the model
  list reads them there, one folder down, with the projector matched to the
  model as for any other. They keep the Mac's file names, which name the
  model, so the iPad serves it under the same model ID, and with the same
  llama.cpp, the same fingerprint, and a gateway treats the two as hosts of
  one model. **Delete** deletes each, and the folder with the last of them.
  A pair that's already here, the starter model's included, is marked so.

**Serving.** The iPad's window has the Mac's tabs, but no **Gateway**, since
it runs none: **Models**, for its models, the files it has and getting one
from a Mac, and **Mesh**, for its Macs. In **Models**, under **Custom
Model**, choose the model, its projector, the slots and the context, and
press **Start**, at the top. The iPad keeps that choice, and chooses it again
at its next launch: a model that's gone, as on a drive that isn't connected,
gives way to the first one listed.

Above the tabs, the iPad says what it's doing, in type big enough to read
across a room: its state, the slots in use, how many Macs are connected, and
its requests an hour and utilization. Beside its state are the Mac's
controls: **Start**, then **Drain**, **Pause** or **Resume**, and **Stop**,
which asks first when requests are running and offers **Drain** instead. At
the top of each tab, the same chart as the Mac's shows its own requests or
tokens over the last hour or day, and under it the memory left before iPadOS
would end conflux, the whole iPad's memory pressure, the thermal state, and
whether it's charging, over the same span, while it serves. Each model's own
numbers are under it, in **Models**.

**Apple's model.** Turn on **Serve Apple's on-device model**, and the iPad
serves Apple's on-device model to its Macs as `apple-on-device`, as a Mac
does ([Apple's on-device model](#apples-on-device-model)): beside the model
file, or alone, with **Serve a custom model** off under **Custom Model**,
which folds that section to its switch. Both switches work while it
serves, as a Mac's do: off with requests running asks whether to let them
finish first or stop them now. Apple's model runs in a system process, so it takes none of the memory
iPadOS lets conflux use, and an iPad too small for a useful model file can
still serve it. It needs an iPad that runs Apple Intelligence, with Apple
Intelligence turned on in Settings; until then the switch says why, and
while it serves, its own row shows its state. It takes two requests at once,
with no setting for it: at serious heat that halves to one, or with **Cool
down** checked it rests. Under sustained work an iPad can spend much of its
time paused for heat, so heat, not slots, sets what it does
([measurements.md](measurements.md#mesh-saturated)). The same rules hold for it as
for the model file: only in the foreground, and only while charging unless
**Serve on battery** is on.

- **Which Macs.** With **Find my Macs through iCloud Keychain** on, the iPad
  lists itself in iCloud Keychain's device list, and trusts the Macs listed
  there, as Macs trust each other ([Peers](#peers-other-macs-models)). The
  Macs find it and send it work, as they do another Mac. A build not signed
  for the team has no device list: under **Pair by hand**, copy the iPad's ID
  into each Mac's conflux, and each Mac's ID into the iPad's. The iPad lists
  its Macs under **Mesh**, in **Your Macs**, with whether each is connected.
- **Only in the foreground.** iPadOS suspends an app in the background, so
  when conflux leaves the foreground it finishes what's running and takes
  nothing new, and the Macs send their work elsewhere. It keeps the screen
  awake while it serves.
- **Only while charging**, by default. Unplugged, it pauses, until it's
  plugged in again or **Serve on battery** is on, under **This iPad** in
  **Models**. A **Drain** or **Pause** of its owner's holds as well: it takes
  work only when none of them holds it back.
- **Resting when hot**, with **Cool down** checked in the Heat tile: at
  serious heat it pauses until it's back to fair ([What the states
  mean](#what-the-states-mean)). An iPad serves one request at a time, and
  halving one slot leaves one, so without it an iPad serves on at serious
  heat.
- **When the iPad runs short of memory.** Memory left is what iPadOS lets
  conflux alone use. The iPad as a whole can run short sooner, since the
  model's memory is wired for the GPU and other apps need theirs, and then
  iPadOS ends apps, conflux among them. **Memory pressure** shows the whole
  iPad's: normal, warning or critical. At a warning, more than one slot is
  halved. When it stays critical for a few seconds, conflux unloads the model,
  which gives its memory back, and says so; the Macs send its work
  elsewhere. Once pressure has been normal for a minute it loads the model
  again by itself, with no need to stop and serve again.
- **The first time**, iPadOS asks whether conflux may find devices on the
  local network. Allowing it lets iroh connect to the Macs directly rather
  than through a relay.

**Leaving it where others can reach it.** iPadOS's Guided Access keeps the
iPad in conflux and, with touch turned off, keeps anyone from changing what it
serves. Turn it on in Settings, under Accessibility, then, with conflux open,
triple-click the top button, or the Home button. Under **Options**, turn off
**Touch**, and start it. The status and charts go on updating; leaving the
app, or touching anything in it, takes the passcode, Face ID or Touch ID, set
under Guided Access's own settings.

How other apps are kept out: on a Mac, the host service listens on a
loopback port and takes connections only from conflux itself. iPadOS can't
say which app connected, so on an iPad it listens on a Unix socket in
conflux's own container, which other apps can't reach, and apple-iroh
carries the Macs' requests there.

**Which models will likely fit.** Above the model choices, conflux says
how much memory iPadOS lets it use of this iPad's memory, and how large a
model, with its projector, will likely load. Below them, it estimates the memory
the chosen model, projector, slots and context will take: the two files,
whole, plus each slot's context, worked out from the model's header (its
layers, key/value heads and their width, at llama.cpp's default f16 cache),
plus room for llama.cpp and conflux to work in. It marks the choice *likely
too big* when the estimate is more than three quarters of what iPadOS
allows, or of the iPad's memory if that's less, or more than the iPad's
memory less 3.5 GB: 4.5 GB on an 8 GB iPad. What's kept back is for
iPadOS, which can report a limit as large as all of the iPad's memory but
needs some of it itself, for the other apps it keeps, and for what the
estimate can't see. The estimate errs towards saying a
model may not fit, and it's a hint, never a block: serving and checking
stay open either way. It also says when the context per slot is more than
the model was trained to read, which takes memory and may not help. Once a
check has run for the same files, slots and context, conflux shows what it
measured instead: what it took once the model loaded and what was left, or
that iPadOS ended it. **Models measured on iPads** links to
[measurements.md](measurements.md) on GitHub.

**Checking a model.** Choose the model, its projector, the slots and the
context, and press **Check whether it fits**. conflux loads it, runs the
self-check, and times one request, keeping the screen awake meanwhile. Keep
it in the foreground. A model too big for the iPad makes iPadOS end the app,
and the next launch records it as *killed*.

The peak footprint it records is the highest since the app launched. So for
a clean number, check one model per launch: quit conflux from the app
switcher between checks.

**Sharing results.** **Share results** gives a Markdown table for
[measurements.md](measurements.md). It names the kind of iPad, such as
`iPad13,4`, its memory, and the model files: nothing that identifies the
iPad or its owner. The same results are in `probe-results.json`, in
conflux's own folder, where copied models go.

## Files

| What | Where |
|---|---|
| Gateway token | `~/Library/Application Support/conflux/token` |
| Paired apps and their tokens | `~/Library/Application Support/conflux/paired-apps.json` |
| Device key, built from source | `~/Library/Application Support/conflux/identity/` (the app keeps it in the keychain) |
| Device directory, the TestFlight app | iCloud Keychain, as `conflux.device` items: each Mac's endpoint ID and name, nothing secret |
| llama.cpp log | `~/Library/Logs/conflux/llama.log` |
| `llama-server` log, with that runtime | `~/Library/Logs/conflux/llama-server.log` |
| [Mesh log](#the-mesh-log), and the one before it | `~/Library/Logs/conflux/mesh.log`, `mesh.log.1`; `mesh-<identity>.log` for another `--identity` |
| Model file hashes, cached | `~/Library/Caches/conflux/hashes.json` |

Those are for conflux built from source. The TestFlight app keeps the same
files inside its container, under
`~/Library/Containers/com.caseybisson.conflux/Data/Library/`, so it has a
token of its own. A Debug build from Xcode uses
`com.caseybisson.conflux.dev` instead. The window shows it. `conflux token` run from inside the
app's bundle prints the app's token too, since it runs in the same sandbox:

```bash
/Applications/conflux.app/Contents/MacOS/conflux token
```
