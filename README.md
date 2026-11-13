# conflux

**A personal inference mesh for Apple devices.**

Each Mac or iPad runs one local model and serves it over
[iroh](https://github.com/n0-computer/iroh). Clients send independent requests
to a gateway on their Mac, and the gateway spreads them across every device
that's willing to take them right now. The goal is aggregate throughput: more
completed requests per hour than any one device manages alone.

It is meant for workloads made of many small, independent requests, such as bulk
image analysis with small vision-language models. It isn't for running one
model that's too large for any single device.

- Devices serve different models. Each runs what fits it, and every response
  says exactly which model produced it.
- Any device can leave at any time: a lid closes, an app goes to the
  background. Clients don't notice, beyond retries.
- No central server. Each host decides what work it admits, and each gateway
  schedules its own clients' requests.
- Clients use an OpenAI-compatible API on loopback, so existing tools work.

## Status

Phase 2, several Macs, is under way, and Phase 3's iPad host is built: an
iPad serves its model to the Macs' gateways. The Mac and iPad apps are
built by Xcode Cloud and distributed through TestFlight, which the iCloud
Keychain trust model needs.
Macs signed in to the same Apple Account find each other through iCloud
Keychain and use each other's models over iroh; peers can also be added by
hand. Hosts pull work as slots free, fast hosts take one request ahead, and
stragglers are hedged onto idle hosts. The window and `/health` show
throughput, failures and idle time per host. What's left is measuring it on
several real Macs against Phase 2's targets.

Phase 1 is done: the gateway, scheduler and a host running llama.cpp
in-process on a single Mac, with a window or headless.

- [Design](docs/design.md): architecture and decisions
- [Client requirements](docs/clients.md): what a client does, and what it gets back
- [Plan](docs/plan.md): phases, and what finishes each one
- [Running](docs/running.md): serving a model and pointing a client at it
- [Releasing](docs/releasing.md): the Mac app, Xcode Cloud and TestFlight
- [Measuring](docs/phase-0.md): how to benchmark a device with `conflux-bench`
- [Measurements](docs/measurements.md): results so far

```bash
swift run -c release conflux
```

```bash
swift test
```

## Models

conflux serves a vision-language model in GGUF format, with its multimodal
projector (`mmproj`): the files llama.cpp runs. It never fetches models from
the internet. Fetch them yourself, then choose them in the app or pass them to
`conflux serve`. An iPad can copy the model a Mac in its mesh serves, from
your own Mac. Until you do, the app serves its small
[starter model](docs/running.md#the-starter-model).

These four are good places to start. Sizes are the model and its projector
together.

| Model | Size | License | Notes |
|---|---|---|---|
| [Qwen3-VL-8B-Instruct](https://huggingface.co/Qwen/Qwen3-VL-8B-Instruct-GGUF), Q4_K_M | 5.8 GB | Apache 2.0 | The best of these at reading text in images. For Macs with 16 GB or more. |
| [Qwen3-VL-4B-Instruct](https://huggingface.co/Qwen/Qwen3-VL-4B-Instruct-GGUF), Q4_K_M | 3.0 GB | Apache 2.0 | Faster, and fits smaller devices. The model in [measurements.md](docs/measurements.md). |
| [Gemma 3 4B-it](https://huggingface.co/ggml-org/gemma-3-4b-it-GGUF), Q4_K_M | 3.3 GB | [Gemma Terms of Use](https://ai.google.dev/gemma/terms), with use restrictions | Shrinks every image to 896 px square, 256 tokens, so it reads images faster than Qwen but can miss small text. |
| [Gemma 4 E4B-it](https://huggingface.co/ggml-org/gemma-4-E4B-it-GGUF), Q4_0 | 5.2 GB | Apache 2.0 | The newest. Its per-layer embeddings make the file as big as an 8B model's. Not yet measured with conflux. |

**Qwen-VL models need at least 1,024 tokens per image** to read images
correctly. Set **Fewest tokens per image** to 1024 in the app, or pass
`--image-min-tokens 1024` to `conflux serve`
([running.md](docs/running.md#if-the-self-check-fails)).

### Getting them

Each Hugging Face page above lists its files, with their SHA-256 checksums.
Download one model file and the projector that goes with it. A projector made
for another model doesn't load. Any folder works; these commands use
`~/models`:

```bash
mkdir -p ~/models && cd ~/models
```

```bash
curl -L -O https://huggingface.co/Qwen/Qwen3-VL-8B-Instruct-GGUF/resolve/main/Qwen3VL-8B-Instruct-Q4_K_M.gguf \
        -O https://huggingface.co/Qwen/Qwen3-VL-8B-Instruct-GGUF/resolve/main/mmproj-Qwen3VL-8B-Instruct-Q8_0.gguf
```

```bash
curl -L -O https://huggingface.co/Qwen/Qwen3-VL-4B-Instruct-GGUF/resolve/main/Qwen3VL-4B-Instruct-Q4_K_M.gguf \
        -O https://huggingface.co/Qwen/Qwen3-VL-4B-Instruct-GGUF/resolve/main/mmproj-Qwen3VL-4B-Instruct-Q8_0.gguf
```

```bash
curl -L -O https://huggingface.co/ggml-org/gemma-3-4b-it-GGUF/resolve/main/gemma-3-4b-it-Q4_K_M.gguf \
        -o mmproj-gemma-3-4b-it-f16.gguf https://huggingface.co/ggml-org/gemma-3-4b-it-GGUF/resolve/main/mmproj-model-f16.gguf
```

```bash
curl -L -O https://huggingface.co/ggml-org/gemma-4-E4B-it-GGUF/resolve/main/gemma-4-E4B-it-Q4_0.gguf \
        -O https://huggingface.co/ggml-org/gemma-4-E4B-it-GGUF/resolve/main/mmproj-gemma-4-E4B-it-Q8_0.gguf
```

Gemma 3's projector is published as `mmproj-model-f16.gguf`, so that command
saves it under a name that says which model it's for. Keep `mmproj` in a
projector's name: the iPad app finds projectors by it.

If you've run one of these with `llama-server -hf`, recent llama.cpp builds
keep the download in the Hugging Face cache, under
`~/.cache/huggingface/hub/`. Copy the files from there rather than fetching
them again.

### Where to put them

**On a Mac**, anywhere, such as `~/models`. Keep a model and its projector
together. The TestFlight app opens only the files you choose in it, and keeps
that access between launches; a file that's replaced has to be chosen again.
The model's ID, in `/v1/models` and in every response, is its file name
without `.gguf`.

**On an iPad**, drag both files onto conflux in Finder's **Files** tab for
the iPad ([running.md](docs/running.md#on-an-ipad)).

### Serving them

In the app, choose the model and its projector, then press **Start**.
Without a window:

```bash
swift run -c release conflux serve --model ~/models/Qwen3VL-8B-Instruct-Q4_K_M.gguf --mmproj ~/models/mmproj-Qwen3VL-8B-Instruct-Q8_0.gguf --image-min-tokens 1024
```

```bash
swift run -c release conflux serve --model ~/models/gemma-3-4b-it-Q4_K_M.gguf --mmproj ~/models/mmproj-gemma-3-4b-it-f16.gguf
```

Before serving, the host checks that the model can read an image. If it
can't, [running.md](docs/running.md#if-the-self-check-fails) says why that
usually happens. [phase-0.md](docs/phase-0.md) covers measuring a model on
your devices and choosing its slots.

## License

[MIT](LICENSE)

conflux links [llama.cpp](https://github.com/ggml-org/llama.cpp), which is
also MIT licensed, using the prebuilt framework from its releases, and
[apple-iroh](https://github.com/misterbisson/apple-iroh), MIT licensed, which
packages [iroh](https://github.com/n0-computer/iroh) (MIT or Apache 2.0) and
the crates it depends on. The app includes one small model, so a first
request works before you've chosen one:
[SmolVLM-256M-Instruct](https://huggingface.co/HuggingFaceTB/SmolVLM-256M-Instruct),
by Hugging Face, Apache 2.0. Other models aren't included: each has its own
license, and conflux points at them.
