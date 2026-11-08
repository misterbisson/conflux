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

Phase 2, several Macs, is under way. The Mac app is built by Xcode Cloud and
distributed through TestFlight, which the iCloud Keychain trust model needs.
Serving over iroh comes next, and until then each Mac serves only itself.

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

## License

[MIT](LICENSE)

conflux links [llama.cpp](https://github.com/ggml-org/llama.cpp), which is
also MIT licensed, using the prebuilt framework from its releases, and
[apple-iroh](https://github.com/misterbisson/apple-iroh), MIT licensed, which
packages [iroh](https://github.com/n0-computer/iroh) (MIT or Apache 2.0) and
the crates it depends on. Models
aren't included: each has its own license, and conflux points at them.
