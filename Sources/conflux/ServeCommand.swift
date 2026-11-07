import ConfluxCore
import Foundation

/// `conflux serve`: the gateway and this Mac's host, without a window.
enum ServeCommand {
    static let usage = """
    usage: conflux                  open the window
           conflux serve --model PATH [options] [-- llama-server arguments]
           conflux token [--rotate] print the gateway's bearer token

    serve: run the gateway on 127.0.0.1 and serve one model.

      --model PATH            GGUF model file
      --mmproj PATH           multimodal projector, for vision models
      --slots N               requests run at once (default 1)
      --ctx-per-slot N        context per slot (default 4096)
      --max-image-dimension N longest image side clients should send (default 1024)
      --image-min-tokens N    fewest tokens per image (Qwen-VL models want 1024)
      --port N                gateway port (default 8090)
      --no-token              let clients connect without the bearer token
      --skip-self-check       report Ready without checking the model reads input
      --runtime NAME          in-process (default), or llama-server to run
                              llama.cpp's server as a separate process
      --llama-server PATH     llama-server to run (default: Homebrew or PATH)

    Arguments after -- go to llama-server, with --runtime llama-server.
    """

    static func parse(_ args: [String]) throws -> NodeSettings {
        var values: [String: String] = [:]
        var flags: Set<String> = []
        var extra: [String] = []
        var index = 0
        let valued: Set<String> = ["--model", "--mmproj", "--slots", "--ctx-per-slot", "--max-image-dimension",
                                   "--port", "--llama-server", "--image-min-tokens", "--runtime"]
        while index < args.count {
            let arg = args[index]
            if arg == "--" {
                extra = Array(args[(index + 1)...])
                break
            } else if ["--no-token", "--skip-self-check"].contains(arg) {
                flags.insert(arg)
                index += 1
            } else if valued.contains(arg) {
                guard index + 1 < args.count else { throw UsageError("\(arg) needs a value") }
                values[arg] = args[index + 1]
                index += 2
            } else {
                throw UsageError("unknown option: \(arg)")
            }
        }
        guard let model = values["--model"] else { throw UsageError("--model is required") }
        func int(_ flag: String, _ fallback: Int, minimum: Int = 1) throws -> Int {
            guard let text = values[flag] else { return fallback }
            guard let value = Int(text), value >= minimum else { throw UsageError("\(flag) must be at least \(minimum)") }
            return value
        }
        let port = try int("--port", 8090, minimum: 0)
        guard port <= 65535 else { throw UsageError("--port must be at most 65535") }
        let runtime = try values["--runtime"].map { name in
            guard let runtime = ModelConfig.Runtime(rawValue: name) else {
                throw UsageError("--runtime is in-process or llama-server")
            }
            return runtime
        } ?? .inProcess
        if runtime == .inProcess && (!extra.isEmpty || values["--llama-server"] != nil) {
            throw UsageError("llama-server options need --runtime llama-server")
        }
        let host = ModelConfig(
            runtime: runtime, model: model, projector: values["--mmproj"],
            slots: try int("--slots", 1), contextPerSlot: try int("--ctx-per-slot", 4096, minimum: 256),
            maxImageDimension: try int("--max-image-dimension", 1024, minimum: 64),
            imageMinTokens: values["--image-min-tokens"] == nil ? nil : try int("--image-min-tokens", 0),
            selfCheck: !flags.contains("--skip-self-check"),
            executable: values["--llama-server"], extraArguments: extra)
        return NodeSettings(host: host, port: UInt16(port), requireToken: !flags.contains("--no-token"))
    }

    struct UsageError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    static func run(_ args: [String]) async -> Int32 {
        let settings: NodeSettings
        do {
            settings = try parse(args)
        } catch {
            say("conflux: \(error)\n\n\(usage)")
            return 64
        }
        let node = ConfluxNode()
        let port: UInt16
        do {
            port = try await node.start(settings)
        } catch {
            say("conflux: can't start the gateway: \(error.localizedDescription)")
            return 1
        }
        say("gateway on http://127.0.0.1:\(port)/v1")
        say(settings.requireToken ? "token: conflux token (stored at \(TokenStore.defaultURL.path))"
            : "no token required: any process on this Mac can use the gateway")
        if let log = node.logURL { say("llama.cpp log: \(log.path)") }

        let stop = { (signal: Int32) -> DispatchSourceSignal in
            Darwin.signal(signal, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signal, queue: .main)
            source.setEventHandler {
                Task {
                    await node.stop()
                    exit(0)
                }
            }
            source.resume()
            return source
        }
        // Held in a static: a local that's only read with `_ =` is released
        // early in optimized builds, and a released source never fires.
        signalSources = [stop(SIGINT), stop(SIGTERM)]

        // Report state changes until stopped.
        var last = ""
        while true {
            let snapshot = await node.scheduler.snapshot()
            let line = snapshot.hosts.map { host in
                "\(host.id): \(host.state.label)\(host.state.detail.map { " (\($0))" } ?? "") "
                    + "\(host.active)/\(host.capacity) busy"
            }.joined(separator: "; ") + "; \(snapshot.completed) completed, \(snapshot.failed) failed"
            let changed = snapshot.hosts.map { "\($0.state)/\($0.capacity)" }.joined()
            if changed != last {
                say(line)
                last = changed
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    nonisolated(unsafe) static var signalSources: [DispatchSourceSignal] = []

    static func say(_ text: String) {
        print(text)
        fflush(stdout)
    }
}
