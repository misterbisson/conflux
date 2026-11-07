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

Phase 0: measuring. The benchmark tool is built, and the conflux app isn't
started yet.

- [Design](docs/design.md): architecture and decisions
- [Client requirements](docs/clients.md): what a client does, and what it gets back
- [Plan](docs/plan.md): phases, and what finishes each one
- [Measuring](docs/phase-0.md): how to benchmark a device with `conflux-bench`

```bash
swift build
```

```bash
swift test
```

## License

[MIT](LICENSE)
