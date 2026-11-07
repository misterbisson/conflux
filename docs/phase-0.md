# Phase 0: measuring

How to take the measurements Phase 0 asks for ([plan.md](plan.md)), with
`conflux-bench` and `tools/bench/sweep.sh`. No conflux app is involved yet.
These tools measure a plain OpenAI-compatible server, usually `llama-server`
from llama.cpp.

The questions:

1. How many requests per hour does one device sustain with its model?
2. How much do parallel slots (continuous batching) add, and where does that
   gain level off?
3. How much does image resolution cost?
4. How far do fanless devices fall from their burst numbers over an hour?

## Setup

```bash
brew install llama.cpp
```

```bash
swift build -c release
```

The benchmark is `.build/release/conflux-bench`. It has no dependencies beyond
the macOS SDK.

### Images

For throughput, generated images are enough:

```bash
.build/release/conflux-bench images --out ~/conflux-images --count 64
```

Generated images contain nothing personal, so they're safe to share. A model
may describe them differently from real images, though, and output length
drives generation time. So for numbers that match a real workload, use a
folder of images like the ones that workload sends.

**Your own images stay on your machine.** The benchmark downscales and
re-encodes each one before sending it to the server, which also removes GPS
and other metadata. Its reports record images by position, not by file name.
Never commit personal images to this repository (see
[CLAUDE.md](../CLAUDE.md)).

### A model

Pick a vision-language model in GGUF format, with its multimodal projector,
that fits the device. Pass it to `llama-server` either by Hugging Face
repository (`-hf <repo>:<quant>`, downloaded and cached on first use) or by
file (`-m model.gguf --mmproj projector.gguf`). Use the same model file on
every device you mean to compare.

## Question 2: slots

`sweep.sh` starts `llama-server` once for each slot count, keeps twice as many
requests in flight as there are slots, and prints a comparison:

```bash
tools/bench/sweep.sh --images ~/conflux-images --slots "1 2 4 8" -- -hf <repo>:<quant>
```

```
run         in flight  per hour  p50 s  p90 s  gen tok/s  failed  hot
parallel 1          2       …
parallel 2          4       …
parallel 4          8       …
parallel 8         16       …
```

- **per hour** is steady-state throughput, with the first round of requests
  left out as warmup.
- **gen tok/s** is generated tokens per second across all requests. If it
  keeps climbing with slots while per-request latency barely moves,
  generation is limited by memory bandwidth and batching is paying off.
- **hot** is the share of samples where this machine's thermal state was
  serious or critical.

The best slot count is where **per hour** stops improving, or where latency
gets too close to a client's deadline. Total context is split across slots,
so the script sets `-c` to `--ctx-per-slot` × slots. If image prompts are
long, raise `--ctx-per-slot`.

The server log for each run is kept next to the results. llama.cpp prints its
own prompt and generation timings there, and the benchmark also records them
per request (`promptMs`, `predictedMs` in the JSON).

## Question 1 and 3: one setting at a time

Run `conflux-bench` directly against a server that's already running:

```bash
llama-server --host 127.0.0.1 --port 8080 --parallel 4 -c 32768 -hf <repo>:<quant>
```

```bash
.build/release/conflux-bench run --endpoint 127.0.0.1:8080 --images ~/conflux-images \
  --concurrency 8 --max-dimension 768 --label "4 slots, 768 px" --json tools/bench/results/768.json
```

Repeat with `--max-dimension` at 512, 768, 1024 and 1536, and compare:

```bash
.build/release/conflux-bench compare tools/bench/results/*.json
```

Resolution trades time against accuracy, so check the answers as well as the
speed. A faster run that misreads images is not a gain.

## Question 4: sustained throughput

On fanless Macs, run for an hour or more with `--duration` in place of a
request count:

```bash
.build/release/conflux-bench run --endpoint 127.0.0.1:8080 --images ~/conflux-images \
  --concurrency 8 --duration 3600 --label "1 hour" --json tools/bench/results/hour.json
```

The benchmark samples this machine's thermal state every five seconds, which
is meaningful when the server runs on the same machine. Compare the hour's
throughput with a ten-minute run at the same settings.

## Sharing results

Raw results stay in `tools/bench/results/`, which git ignores. To share a
result in an issue or pull request, paste the `compare` table and say which
device class, memory and model it came from: for example "M2, 24 GB, a 4-bit
4B vision model". Leave out hostnames, IP addresses and anything else that
identifies a person or a machine.

The JSON reports are written to be safe by default. They record chip, memory
and OS, but not the hostname. Image paths and file names are left out, and so
is the prompt text, which is kept only as a length and a hash. A server that
isn't on loopback appears as "remote" and its port. Check before sharing all
the same.

## Bearer tokens

If the endpoint needs a token, put it in `CONFLUX_TOKEN`. There's no
command-line option for it, so it stays out of shell history and process
lists.
