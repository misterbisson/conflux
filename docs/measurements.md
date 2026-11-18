# Measurements

Results from [phase-0.md](phase-0.md)'s procedure, one device class at a
time. Each entry names the chip, memory, model and runtime. Raw reports stay
on the machine that made them. Each host reports its chip, GPU cores and
memory, and the window shows them beside each host
([design.md](design.md#monitoring)), as does `conflux-bench`'s report and the
iPad's Share results.

## M2, 24 GB (fanless)

- **Model:** Qwen3-VL-4B-Instruct, Q4_K_M, with its Q8_0 projector (Apache-2.0)
- **Runtime:** llama.cpp build 12110, through `llama-server`
- **Workload:** generated 1024 px test images, "Describe this image in one
  paragraph", about 1,040 prompt tokens and 140 generated tokens per request
- **Date:** 2026-11-06

### Slots

`sweep.sh`, with twice as many requests in flight as slots, and 4,096 tokens
of context per slot.

| Slots | Per hour | p50 latency | Generated tok/s | Swap growth |
|---|---|---|---|---|
| 1 | 241 | 26 s | 9.5 | none |
| 2 | 225 | 66 s | 8.7 | none |
| 4 | 302 | 100 s | 11.4 | +1.5 GB |
| 8 | 335 | 183 s | 12.6 | +4.6 GB |

**Extra slots add little on this device.** One request reads its prompt in
about 8 s (130 tokens/s) and generates for about 7 s (20 tokens/s). With more
slots, reading new images competes with generating for the GPU, so each
request slows nearly as much as the slot count rises. Reading the image is
limited by compute, and batching doesn't add compute. The 4 and 8-slot runs
also pushed the machine into swap, so their gains are uncertain and their
latency is far too high for most clients' deadlines.

**Recommendation for this device: 1 slot**, or 2 only if latency doesn't
matter at all.

An earlier run of the same sweep, with other applications holding most of the
memory, showed 2 slots at 170 per hour and 4 and 8 slots timing out. That's
why reports now record swap growth: a run that swaps measures the disk.

### Image resolution

One slot, two requests in flight, the same images downscaled by the
benchmark, with llama-server's default settings.

| Longest side | Prompt tokens | Per hour | Reading the prompt | Generating |
|---|---|---|---|---|
| 512 px | 273 | 568 | 1.5 s | 4.8 s |
| 768 px | 593 | 286 | 5.5 s | 7.1 s |
| 1024 px | 1,041 | 241 | 7.9 s | 7.0 s |

**Fewer image tokens are faster, but this model reads them badly.** Halving
the longest side more than doubles throughput. But llama.cpp warns that
Qwen-VL models need at least 1,024 image tokens to work correctly, and
conflux's self-check confirmed it. Asked to read five large characters from a
768 × 256 image (about 200 image tokens), the model got 3 of 12 right. With
`--image-min-tokens 1024` it got all 12, and also all of 20 tests with digits
and words. At 512 px, the default settings also produced answers that
misread text in the benchmark images.

With `--image-min-tokens 1024`, llama-server enlarges small images to that
many tokens, so for this model family a smaller image no longer saves time:
every image costs about what a 1024 px one does. Sending images above
1024 px is still wasted. Other model families may differ, which is what the
resolution sweep in [phase-0.md](phase-0.md) is for, as long as answers are
checked as well as speed.

### Through the conflux gateway

`conflux serve` with one slot and `--image-min-tokens 1024`, the same
images at 1024 px, measured with `conflux-bench` against the gateway on
2026-11-07.

| Run | Requests | Per hour | p50 latency | Result |
|---|---|---|---|---|
| One at a time | 6 | 318 | 11.8 s | all answered by the expected model |
| Two in flight | 10 | 307 | 18.9 s | no failures, no busy responses |
| Ten in flight, 60 s deadline | 16 | 310 | 27.8 s | 4 answered, 12 refused with `429` in time, none late |

- The self-check passed before the host reported Ready. Without
  `--image-min-tokens 1024` it failed, and passed on llama-server's advice.
- The gateway adds no cost that shows in these numbers. They're a little
  faster than the earlier direct runs, which were made with less free memory.
- Under overload every request ended within its deadline. The slowest took
  46.5 s against 60 s. Those that couldn't be served in time got `429` with a
  `Retry-After` estimate, and the client gave up instead of waiting past its
  deadline.
- `Ctrl-C` stopped the gateway and its `llama-server`.

### In-process against llama-server

The same llama.cpp build (12110), model and images, one slot, run back to
back on 2026-11-07, while the Mac was short of memory, so both are slower
than the runs above.

| Runtime | Per hour | p50 latency | Reading the prompt | Generating |
|---|---|---|---|---|
| In-process | 176 | 20.6 s | 11.6 s | 14.6 tok/s |
| `llama-server` | 163 | 21.3 s | 12.2 s | 13.4 tok/s |

The two run at the same speed. At temperature 0 they gave identical answers,
word for word, for text and for images, once the in-process runtime joined
a message's text and image parts the way llama.cpp does.

### What this means for the plan

- On a base M chip, image workloads are **limited by compute while reading the
  image**. Fewer image tokens would be the cheapest gain, but only with a
  model that still reads them correctly. For Qwen-VL models, about 1,024
  tokens per image is the floor.
- More slots are worth measuring on chips with more GPU compute (Pro and Max)
  before assuming they help. The Phase 0 numbers for those devices decide each
  host's slot count.
- The mesh's gain comes from adding devices, not from batching on small ones.
  That's the case Phase 2 is for.

## M4 Pro, 48 GB: Gemma 4

Gemma 4's two largest models against Gemma 3 4B, one Mac, one model at a
time.

- **Device:** a 14-inch MacBook Pro, M4 Pro (16-core GPU), 48 GB, with other
  applications open and 18 GB already in swap
- **Models:** Gemma 4 26B-A4B-it and 31B-it, Q4_0, each with its Q8_0
  projector (Apache 2.0); Gemma 3 4B-it, Q4_K_M, with its F16 projector
  ([Gemma Terms of Use](https://ai.google.dev/gemma/terms))
- **Runtime:** `conflux serve --runtime llama-server -- --reasoning off`,
  conflux 0.14.0, Homebrew's llama.cpp build 11669. The in-process runtime
  can't serve Gemma 4 yet (below).
- **Workload:** `conflux-bench run` against the gateway, twice as many
  requests in flight as slots, 10 measured requests a slot after warmup, 64
  images from `conflux-bench images`, at most 1,024 px, so no image was sent
  twice. Its default prompt, "Describe this image in one paragraph.", with
  up to 256 tokens of answer. Gemma 4 read each request as 463 prompt
  tokens, Gemma 3 as 274, and each answered in 95 to 110 tokens.
- **Date:** 2026-11-17

| Model | Slots | Per hour | p50 latency | Reading the prompt | Generating | Peak memory |
|---|---|---|---|---|---|---|
| Gemma 3 4B | 1 | 1,036 | 6.8 s | 2.1 s | 1.4 s | 4.8 GB |
| Gemma 3 4B | 2 | 1,057 | 14.1 s | 2.4 s | 4.3 s | 6.1 GB |
| Gemma 4 26B-A4B | 1 | 738 | 9.4 s | 3.2 s | 1.6 s | 17.7 GB |
| Gemma 4 26B-A4B | 2 | 805 | 18.4 s | 3.4 s | 5.5 s | 18.7 GB |
| Gemma 4 31B | 1 | 178 | 40.7 s | 10.3 s | 9.5 s | 21.6 GB |
| Gemma 4 31B | 2 | 169 | 85.5 s | 10.8 s | 17.4 s | 23.3 GB |

Reading and generating are the server's times for one request, averaged.
Peak memory is conflux and `llama-server` together, the model's weights
included. The Mac's thermal state was fair, not nominal, throughout.

- **26B-A4B is nearly as fast as a 4B model.** It's a mixture of experts:
  each token uses 8 of its 128 experts, about 4B parameters. It generated
  about 70 tokens/s, the same as Gemma 3 4B, and took 4.8 s of the server's
  time a request against 3.5 s. Most of the difference is reading the
  image: Gemma 4 reads it as more tokens.
- **31B is about four times slower than 26B-A4B.** It's dense: every token
  reads all 18 GB of its weights, so the M4 Pro's 273 GB/s holds it to about
  10 tokens/s generating, and 45 tokens/s reading the prompt. A request
  takes about 20 s of the server's time.
- **Both described the benchmark images correctly**, text in them included,
  in one paragraph each. This run doesn't say how much better 31B's answers
  are; a client's own images, with answers checked, would.
- **A second slot adds little to either.** 26B-A4B did 9% more with two,
  and 31B none, while latency doubled. One slot each on this Mac.
- **The 31B's first run went into swap.** Swap grew 5.1 GB as its 18 GB of
  weights loaded into a Mac already short of memory. The run after it grew
  0.3 GB and read prompts at the same speed, so swap didn't set the pace.
  A 32 GB Mac is untested: 26B-A4B should fit with room, but 31B, at about
  22 GB with one slot, would be close to what macOS lets the GPU use.
- **Benchmark with more images than requests.** A first run of 26B-A4B
  with only 8 images, each sent more than once, showed 1,100 an hour, half
  again what it does. `llama-server` keeps recent prompts, and a repeated
  image costs it almost nothing to read.

The in-process runtime, the only one the app and the iPad use, fails
Gemma 4's self-check with "llama.cpp doesn't support this model's chat
template". It formats prompts with `llama_chat_apply_template`, which knows
a fixed list of templates, and llama.cpp build 12110's list has no Gemma 4.
`llama-server` reads the model's own template.

## Mesh: three Macs and two iPads

The first numbers from a real mesh, read from the app's window while a client
ran its own work through the gateway. They aren't a `conflux-bench` run, so
they come with less control than the results above.

- **Devices:**
  - the gateway: a 14-inch MacBook Pro, M4 Pro (12-core CPU, 16-core GPU),
    48 GB
  - an M2 with 24 GB
  - a 13-inch MacBook Pro, M1 (2020)
  - an iPad Pro, M1 (`iPad13,4`)
  - a 13-inch iPad Air, M3 (`iPad15,6`)

  Each found the others through iCloud Keychain and connected directly, with
  round trips of 10 to 60 ms. They joined over the run: one host at first,
  then two, then three, and all five only near the end.
- **Model:** Gemma 3 4B-it, Q4_K_M, with its F16 projector
  ([Gemma Terms of Use](https://ai.google.dev/gemma/terms)), on every host
- **Runtime:** llama.cpp build 12110, in-process, conflux 0.8.0
- **Settings:** 1 slot on every host, 4,096 tokens of context, largest image
  side 1,024 px, self-check on
- **Workload:** a client's own images, about 1,600 px on the longest side,
  which hosts scale to 1,024 px. Gemma reads each as 256 tokens, so a request
  is about 350 to 430 prompt tokens, and the answers are short, 15 to 25
  generated tokens. The client kept up to 8 requests in flight.
- **Date:** 2026-11-13

### How the window counts

- **Per hour** is the requests completed in the last 10 minutes, times 6. A
  host that joined less than 10 minutes ago shows less than its rate, and so
  does a mesh that gained hosts in that time.
- **Typical request** is measured at the gateway, from sending a request to
  its answer, and weighted towards the last few. For a request a host took
  ahead, it includes waiting there for the slot, so it overstates how long
  that host takes to run one.

### Each host

From the gateway's Monitoring section, once all five were serving. The
ceiling is what one slot could do at the host's typical time: 3,600 s
divided by it.

| Host | Typical request | Ceiling per hour | Taken ahead | Idle with work |
|---|---|---|---|---|
| MacBook Pro, M4 Pro | 6.0 s | 600 | none | 0.0 s |
| M2, 24 GB | 8.7 s | 414 | 18 | 3.4 s |
| MacBook Pro, M1 | 9.9 s | 364 | 1 | 0.7 s |
| iPad Air, M3 | 14.5 s | 248 | 3 | 0.8 s |
| iPad Pro, M1 | 14.6 s | 247 | 2 | 0.5 s |
| **All five** | | **1,873** | | |

The M2's typical time is the least reliable. It took far more requests ahead
than any other host, so more of its time is waiting for its own slot.

### The mesh

A few minutes later, near the end of the run:

- **1,932 per hour**, 322 requests in the last 10 minutes. Those 10 minutes
  include time before all five hosts had joined. The gateway's own Mac did
  552 an hour of that, 92% of its ceiling.
- **7.0 s idle while work waited**, in total since the gateway started.
- 3 busy answers from hosts, none busy or unavailable to the client, 6
  requests hedged onto a second host with no hedge answering first, and 1 to
  2 failed requests.

### What this shows

- **The mesh reached roughly the sum of its hosts.** It completed 1,932 an
  hour against 1,873 for the ceilings added together, though the count
  includes time with fewer hosts. Both numbers are rough: the count is below
  the five-host rate, and the ceilings are below what the hosts can do,
  since typical times include waits for requests taken ahead. That is
  consistent with Phase 2's first target, not proof of it. Proof needs each
  host measured alone and then together, over runs long enough to fill the
  count: the mesh benchmark [plan.md](plan.md) still lists.
- **Idle-with-work time stays near zero.** 7.0 s in total, over a run that
  ended with five hosts. Fast hosts took requests ahead as designed: the M2
  took 18.
- **The GPU sets the pace.** With short answers, almost all of a request is
  reading the image, and the M4 Pro's GPU stayed fully busy while its CPU
  cores didn't. The M4 Pro was about 1.65 times as fast as the M1 MacBook
  Pro. It has twice the M1's GPU cores and four times its memory bandwidth
  (273 GB/s against 68), so the gain follows compute rather than bandwidth,
  and falls short even of the core count. Work outside the GPU in each
  request, such as decoding and scaling the image, may be some of the
  difference.
- **Fanless costs time.** The same M1 chip took about 1.5 times as long in
  an iPad as in a MacBook Pro with a fan. Some of that may be iPadOS's
  limits rather than heat. The M3 iPad Air, two chip generations newer, was
  no faster than the M1 iPad Pro: 14.5 s against 14.6 s.
- **This run can't say what the image's token count is worth.** On an M2
  with 24 GB, Qwen3-VL at 1,024 tokens per image took 11.8 s a request
  through the gateway (above). Gemma, at 256, took 8.7 s here, but with much
  shorter answers and with waits for requests taken ahead, so the two don't
  compare. Both models on one device, one request at a time, would.
- **Hedging hasn't paid off yet.** All 6 hedges lost. That's little work
  wasted, but worth watching over longer runs.

Not covered: closing a lid mid-run, each host measured alone, and a
benchmark with a known workload.

## Mesh, saturated

The first `conflux-bench` run against a mesh, with more requests in flight
than the mesh had slots, so work always waited at the gateway.

- **Devices:** seven hosts on five devices:
  - the gateway: a 14-inch MacBook Pro, M4 Pro (16-core GPU), 48 GB: the
    model file, 1 slot
  - a 15-inch MacBook Air, M2 (10-core GPU), 24 GB, fanless: the model file,
    2 slots, and Apple's model, 8 slots
  - a 13-inch MacBook Pro, M1 (8-core GPU), 16 GB: the model file, 2 slots,
    and Apple's model, 8 slots and then 4
  - an iPad Pro, M1 (`iPad13,4`), 8 GB: Apple's model, 2 slots
  - a 13-inch iPad Air, M3 (`iPad15,6`), 8 GB: Apple's model, 2 slots
- **Models:** Gemma 3 4B-it, Q4_K_M, with its F16 projector
  ([Gemma Terms of Use](https://ai.google.dev/gemma/terms)), in-process with
  llama.cpp build 12110; and Apple's on-device model, on macOS 27 and
  iPadOS 27
- **conflux:** 0.11.0 on the gateway
- **Workload:** `conflux-bench run --concurrency 30 --requests 3000`, with 8
  images from `conflux-bench images`, at most 1,024 px and 50 KB on average,
  and its default prompt, "Describe this image in one paragraph.", with up
  to 256 tokens of answer. The requests name no model, so any host could
  take each one, and each has a 115 s deadline. A request was 225 prompt
  tokens and 87 generated tokens on average, across both models.
- **Date:** 2026-11-14

### What the client saw

- **2,997 answered and 3 refused**, each refusal a `429` once no slot would
  free up in time.
- **4,373 an hour**: 2,967 requests, after the first 30, in 2,442 s.
- **Latency:** 20.4 s at the median, 39.7 s at p90, 63.9 s at p99 and 113.1 s
  at most. Every request ended inside its 115 s deadline.
- **Models:** Apple's answered 2,249 and Gemma 748.

### Each host

From the gateway's `/health` about 18 minutes into the run, so for the
10 minutes before that.

| Host | Model | Slots | Typical request | p95 | Per hour |
|---|---|---|---|---|---|
| MacBook Pro, M4 Pro | Gemma | 1 | 5.2 s | 6.0 s | 684 |
| MacBook Air, M2 | Gemma | 2 | 30.6 s | 34.3 s | 228 |
| MacBook Air, M2 | Apple's | 8 | 26.6 s | 32.2 s | 1,074 |
| MacBook Pro, M1 | Gemma | 2 | 28.3 s | 30.8 s | 252 |
| MacBook Pro, M1 | Apple's | 4 | 11.3 s | 15.2 s | 1,284 |
| iPad Pro, M1 | Apple's | 2 | 9.3 s | 12.6 s | 402 |
| iPad Air, M3 | Apple's | 2 | 8.1 s | 12.7 s | 438 |
| **All seven** | | | | | **4,362** |

Every host's utilization was 99.6% or more, and the mesh's 99.8%. Requests
waited at the gateway 8.5 s at the median and 14.3 s at p95, with 8 to 13
waiting at a time.

### What this shows

- **The gateway kept every slot busy.** Idle while work waited was 27 s in
  total at that point, since the gateway started, earlier runs included.
- **Apple's model did three-quarters of the work.** Its four hosts did 3,198
  an hour, and Gemma's three 1,164. On the base M1 and M2, Gemma's requests
  took about 30 s with 2 slots, against 8.7 s and 9.9 s with 1 slot in the
  first mesh run (above). Answers here were several times longer, and each
  of those Macs ran Apple's model on the same GPU, so this run can't say
  which cost more.
- **More slots for Apple's model stopped paying.** The M1 MacBook Pro began
  with 8, and did more once it was cut to 4 early in the run. With 4, it did
  1,284 an hour at 11.3 s a request. The M2, a faster chip, with 8 did 1,074
  at 26.6 s. One device of each, sharing its GPU with Gemma, isn't a
  measurement of where more slots stop helping on each chip, but it says to
  find it rather than take the most ([running.md](running.md#apples-on-device-model)).
- **The iPads spent about half the time paused.** Both showed 99.6%
  utilization or more, but this gateway completed 67 and 73 requests on them
  in those 10 minutes, where two slots at their typical times would fit
  about 129 and 148. Utilization counts only time a host offers slots, and a
  paused host offers none. Both were paused near the end of the run, the
  iPad Air for heat. The fanless MacBook Air kept its slots: its two hosts' requests
  fill its slots for the whole window.
- **Stopping a host cost the client nothing.** Cutting the M1's slots meant
  stopping conflux on it, as Apple's model's slots then needed. The requests
  running there failed, and so did requests that tried it before the
  gateway knew it had stopped, and the gateway sent each to another host.
  None reached the client. Apple's model's slots now change while conflux
  runs.
- **The peers dropped out together once, unexplained.** Between 18 minutes
  in and the end, idle while work waited rose from 27 s to 388 s, spread
  over every peer's hosts, 35 to 92 s each, and none on the gateway's own.
  Every peer's hosts also counted requests that found them unreachable. The
  gateway lost all its peers at once, perhaps for under a minute, and the
  slowest answers and the three `429`s may have come from it. The window's
  chart would show when; this summary can't.

Not covered: each host measured alone, the M1's Apple model at one slot
count for the whole run, the same run without Apple's model beside Gemma,
and what took every peer away at once.
