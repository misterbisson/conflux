# Measurements

Results from [phase-0.md](phase-0.md)'s procedure, one device class at a
time. Each entry names the chip, memory, model and runtime. Raw reports stay
on the machine that made them. Each host reports its chip, GPU cores and
memory, and the window's Mesh and Monitoring rows show them
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

## Mesh: three Macs and two iPads

The first numbers from a real mesh, read from the app's window while a client
ran its own work through the gateway. They aren't a `conflux-bench` run, so
they come with less control than the results above.

- **Devices:** the gateway's Mac (48 GB), a second Mac, an M1 MacBook Pro
  (2020), an iPad Pro with M1 (`iPad13,4`) and an `iPad15,6`. Every one
  found the others through iCloud Keychain and connected directly, with
  round trips of 10 to 60 ms.
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

### Each host

From the gateway's Monitoring section, partway through the run, with 1,788
requests completed since the gateway started. The ceiling is what one slot
could do at the host's typical request time: 3,600 s divided by it.

| Host | Typical request | Ceiling | Per hour | Idle with work |
|---|---|---|---|---|
| Gateway's Mac, 48 GB | 6.0 s | 600 | 384 | 0.0 s |
| Second Mac | 8.7 s | 414 | 312 | 3.4 s |
| M1 MacBook Pro | 9.9 s | 364 | 228 | 0.7 s |
| `iPad15,6` | 14.5 s | 248 | 210 | 0.8 s |
| iPad Pro, M1 | 14.6 s | 247 | 168 | 0.5 s |
| **Mesh** | | **1,873** | **1,302** | |

A peer's typical time is measured at the gateway, so it includes the round
trip, which is too small to matter here.

### The mesh

| Point in the run | Completed | Per hour | Idle while work waited |
|---|---|---|---|
| Early | 1,639 | 408 | 3.3 s |
| Middle (the table above) | 1,788 | 1,302 | 5.6 s |
| Late | 1,893 | 1,932 | 7.0 s |

Across the run, 3 requests got a busy answer from a host, none came back
busy or unavailable to the client, 6 were hedged onto a second host, and no
hedge answered first. The window showed 1 to 2 failed requests.

### What this shows

- **The mesh reached the sum of its hosts.** Late in the run, the mesh
  completed 1,932 an hour, against about 1,870 for the hosts' ceilings
  added together. Phase 2 asks for the mesh's throughput to come close to
  the sum of each host's own. The ceilings are worked out from typical
  times, not measured alone, so this is close rather than exact. Earlier,
  at 70% of the ceilings, idle-with-work time stayed near zero, so the
  hosts weren't waiting on the scheduler. Most likely the client hadn't yet
  sent work fast enough to fill five slots.
- **Idle-with-work time stays near zero.** 7.0 s in total over about 250
  requests and five hosts. Fast hosts took requests ahead as designed: the
  second Mac took 18.
- **Image reading sets the pace, and GPU compute sets image reading.** With
  short answers, almost all of a request is reading the image. The 48 GB
  Mac is about 1.65 times as fast as the M1 MacBook Pro, closer to the
  difference in GPU compute than to the difference in memory bandwidth.
- **Fanless costs time.** The same M1 chip took about 1.5 times as long in
  an iPad as in a MacBook Pro with a fan. Some of that may be iPadOS's
  limits rather than heat.
- **The image's token count is the main lever.** Gemma's 256 tokens per
  image, against Qwen3-VL's 1,024, is a large part of why these requests
  are faster than the M2 results above. That only holds for work that
  Gemma's smaller view of each image reads correctly.
- **Hedging hasn't paid off yet.** All 6 hedges lost. That's little work
  wasted, but worth watching over longer runs.

Not covered: closing a lid mid-run, a mesh benchmark with a known workload,
and the chips of the second Mac and the `iPad15,6`.
