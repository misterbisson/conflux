# Running conflux

Phase 1 runs on one Mac: a gateway on loopback, serving this Mac's own model
through `llama-server`. Other Macs and iPads join in later phases
([plan.md](plan.md)).

## What you need

- macOS 14 or later, on Apple Silicon.
- llama.cpp: `brew install llama.cpp`.
- A GGUF model and, for a vision model, its multimodal projector (`mmproj`).
  [phase-0.md](phase-0.md) says how to choose one and how many slots it
  should get.

## The app

```bash
swift run -c release conflux
```

Choose the model and projector, set the slots, and press **Start**. The
window shows the host's state, what's running and waiting, and throughput.
**Drain** finishes what's running and takes nothing new. **Pause** takes
nothing new straight away. **Stop** ends serving and quits `llama-server`.

Settings are kept between launches. The app is built and run from source for
now. A signed app comes later.

## Without a window

```bash
swift run -c release conflux serve --model ~/models/model.gguf --mmproj ~/models/mmproj.gguf --slots 1
```

It prints the endpoint, then a line each time the host's state changes.
`Ctrl-C` stops it and its `llama-server`. Everything after `--` is passed to
`llama-server`. `conflux help` lists the options.

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
that fails says what the model answered, and passes on any advice
llama-server logged about it.

The usual cause is a model that needs an option to read images well. Qwen-VL
models, for one, read small images badly unless llama-server gives each
image at least 1,024 tokens. That model family needs:

```bash
swift run -c release conflux serve --model ... --mmproj ... -- --image-min-tokens 1024
```

In the app, put `--image-min-tokens 1024` in **More llama-server options**.
Check the model's documentation for others. Turning the self-check off makes
the host serve anyway, and clients get the bad answers instead.

## Files

| What | Where |
|---|---|
| Gateway token | `~/Library/Application Support/conflux/token` |
| `llama-server` log | `~/Library/Logs/conflux/llama-server.log` |
| Model file hashes, cached | `~/Library/Caches/conflux/hashes.json` |
