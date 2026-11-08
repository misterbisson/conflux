# Running conflux

conflux runs a gateway on loopback, serving this Mac's own model with
llama.cpp and, when it has [peers](#peers-other-macs-models), other Macs'
models over iroh. The [iPad app](#on-an-ipad) is so far a memory probe; iPads
join the mesh as hosts later in Phase 3 ([plan.md](plan.md)).

## What you need

- macOS 15 or later, on Apple Silicon.
- A GGUF model and, for a vision model, its multimodal projector (`mmproj`).
  [phase-0.md](phase-0.md) says how to choose one and how many slots it
  should get. To try conflux first, the app has one: see
  [the starter model](#the-starter-model).

## The app

```bash
swift run -c release conflux
```

Choose the model and projector, or keep the
[starter model](#the-starter-model), set the slots, and press **Start**. The
window shows the host's state, what's running and waiting, and throughput.
**Drain** finishes what's running and takes nothing new. **Pause** takes
nothing new straight away. **Stop** ends serving and unloads the model.

Settings are kept between launches.

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
`Ctrl-C` stops it. `conflux help` lists the options.

### Runtimes

llama.cpp is built into conflux, the same build Phase 0 measured, and
models run inside it. That's the only runtime the app uses, since a
sandboxed app can't start other programs.

`conflux serve --runtime llama-server` runs llama.cpp's own server as a
separate process instead, so a crash in the model can't take the gateway
down. It needs llama.cpp installed (`brew install llama.cpp`), and
everything after `--` is passed to `llama-server`. With the same llama.cpp
build, both runtimes give the same answers ([design.md](design.md#runtimes)).

## Pointing a client at it

- **Endpoint:** `http://127.0.0.1:8090/v1`. Change the port with `--port`.
- **Token:** `swift run conflux token` prints it. Clients send it as
  `Authorization: Bearer <token>`. To allow clients that can't send one, use
  `--no-token`, or turn off "Require the token" in the app. Any process on
  the Mac can then use the gateway.
- **Model:** `any`, `any-vision`, or the ID `/v1/models` lists, which is the
  GGUF file name without `.gguf`.

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

- **In the app:** **Mesh** shows this Mac's ID, with **Copy ID**. Paste
  another Mac's ID in **Peer** and click **Add**, then **Start**.
- **Without a window:**

  ```bash
  swift run -c release conflux id
  ```

  prints this Mac's ID, and `--peer` names another's, once per peer:

  ```bash
  swift run -c release conflux serve --model ... --peer 3f2a...
  ```

  A Mac that serves no model can still use its peers': `conflux serve --peer
  3f2a...` with no `--model`.

Both Macs have to add each other. Until then, each refuses the other, and the
window counts the refused connections. A Mac with no peers, from iCloud
Keychain or by hand, starts no iroh endpoint and contacts nothing.

The window shows each peer's state, its model, and whether the connection is
direct or relayed, with its round trip. **Monitoring** shows throughput,
failures and idle time for the mesh and for each host. `/health` with the
token gives the same numbers:

```bash
curl -s -H "Authorization: Bearer $(swift run -c release conflux token)" http://127.0.0.1:8090/health
```

"Idle while work waited" is time a host had a free slot while work it could
run waited at this gateway. It should stay near zero
([design.md](design.md#monitoring)). A peer that stops is shown as not
answering within seconds, and its requests go elsewhere or get a 503 with
`Retry-After`.

To try it on one Mac, run two nodes with different identities and ports:

```bash
swift run -c release conflux serve --identity a --port 8091 --model ... --peer "$(swift run -c release conflux id --identity b)"
```

```bash
swift run -c release conflux serve --identity b --port 8092 --peer "$(swift run -c release conflux id --identity a)"
```

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
halves its slots. At critical heat or memory pressure it pauses until things
recover.

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

The iPad app is the same app as the Mac's, built for iPadOS 18 or later. Its
first version isn't a host yet. It's a memory probe: it checks whether a
model fits on the iPad, and records the memory that took, to decide which
models iPads can serve ([plan.md](plan.md), Phase 3).

**Installing it.** From Xcode for now: it isn't on TestFlight yet
([releasing.md](releasing.md#not-done-yet)). With your Team ID in
`App/Signing.local.xcconfig` ([releasing.md](releasing.md#building-the-app-on-a-mac)),
generate the project, open it, choose the `conflux-ipad` scheme and your iPad,
and run. Xcode's automatic signing adds the app's two memory capabilities,
the increased memory limit and extended virtual addressing, to its app ID the
first time.

**The starter model** is listed first, so the probe can check something
before any model is copied in.

**Copying models in.** Connect the iPad to the Mac, select it in Finder, open
the **Files** tab, and drag the GGUF files onto conflux. The Files app shows
the same folder, under **On My iPad**. A vision model's projector goes
alongside it, with `mmproj` in its file name, as llama.cpp names them.

**Checking a model.** Choose the model, its projector, the slots and the
context, and press **Check this model**. conflux loads it, runs the
self-check, and times one request, keeping the screen awake meanwhile. Keep
it in the foreground. A model too big for the iPad makes iPadOS end the app,
and the next launch records it as *killed*.

The peak footprint it records is the highest since the app launched. So for
a clean number, check one model per launch: quit conflux from the app
switcher between checks.

**Sharing results.** **Share results** gives a Markdown table for
[measurements.md](measurements.md). It names the kind of iPad, such as
`iPad13,4`, its memory, and the model files: nothing that identifies the
iPad or its owner. The same results are in `probe-results.json`, in the
folder the models are in.

## Files

| What | Where |
|---|---|
| Gateway token | `~/Library/Application Support/conflux/token` |
| Device key, built from source | `~/Library/Application Support/conflux/identity/` (the app keeps it in the keychain) |
| Device directory, the TestFlight app | iCloud Keychain, as `conflux.device` items: each Mac's endpoint ID and name, nothing secret |
| llama.cpp log | `~/Library/Logs/conflux/llama.log` |
| `llama-server` log, with that runtime | `~/Library/Logs/conflux/llama-server.log` |
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
