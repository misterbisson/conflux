# Measurements

Results from [phase-0.md](phase-0.md)'s procedure, one device class at a
time. Each entry names the chip, memory, model and runtime. Raw reports stay
on the machine that made them.

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
