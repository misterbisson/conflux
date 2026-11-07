import Foundation
import Testing
@testable import ConfluxCore

@Suite struct LlamaServerConfigTests {
    @Test func arguments() {
        let config = LlamaServerConfig(model: "/m/Some-Model-Q4_K_M.gguf", projector: "/m/mmproj.gguf", slots: 4,
                                       contextPerSlot: 4096, extraArguments: ["--threads", "4"])
        #expect(config.modelID == "Some-Model-Q4_K_M")
        #expect(config.arguments(port: 9000) == [
            "--host", "127.0.0.1", "--port", "9000", "-m", "/m/Some-Model-Q4_K_M.gguf", "--mmproj", "/m/mmproj.gguf",
            "--parallel", "4", "-c", "16384", "--threads", "4",
        ])
        #expect(LlamaServerConfig(model: "/m/plain").modelID == "plain")
    }

    @Test func buildNumbers() {
        #expect(LlamaServerHost.parseBuild("version: 0.9.0 (build 12110, commit cd959bae9)\nbuilt with clang") == "b12110")
        #expect(LlamaServerHost.parseBuild("nothing here") == nil)
    }

    @Test func advice() {
        let log = """
        0.00.808 W load_hparams: Qwen-VL models require at minimum 1024 image tokens to function correctly
        0.00.808 W load_hparams: if you encounter problems with accuracy, try adding --image-min-tokens 1024
        0.00.900 W load_hparams: if you encounter problems with accuracy, try adding --image-min-tokens 1024
        0.01.000 I srv load_model: try adding more memory
        """
        #expect(LlamaServerHost.advice(in: log) == "add --image-min-tokens 1024")
        #expect(LlamaServerHost.advice(in: "0.01 I srv model loaded") == nil)
    }

    @Test func helpers() throws {
        #expect(try LlamaServerHost.freePort() > 1024)
        #expect(LlamaServerHost.locate("/nonexistent/llama-server") == nil)
    }
}

/// Runs the real supervisor against a stand-in `llama-server`: a short
/// Python script that answers `/health` and `/v1/chat/completions`. It
/// tests launching, readiness, forwarding, restarts and stopping without a
/// model. Skipped where there's no python3.
@Suite(.serialized) struct LlamaServerSupervisionTests {
    static let script = #"""
    #!/usr/bin/python3
    import json, sys
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
    if "--version" in sys.argv:
        print("version: 0.0.0 (build 42, commit test)", file=sys.stderr)
        sys.exit(0)
    port = int(sys.argv[sys.argv.index("--port") + 1])
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        def log_message(self, *args): pass
        def reply(self, status, body):
            data = json.dumps(body).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        def do_GET(self):
            self.reply(200, {"status": "ok"}) if self.path == "/health" else self.reply(404, {})
        def do_POST(self):
            length = int(self.headers.get("Content-Length", 0))
            request = json.loads(self.rfile.read(length) or b"{}")
            if request.get("bad"):
                return self.reply(400, {"error": {"message": "bad request"}})
            text = json.dumps(request.get("messages", []))
            self.reply(200, {"choices": [{"message": {"content": "echo " + text}}], "model": "stand-in"})
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    print(f"stand-in listening on {port}", file=sys.stderr, flush=True)
    server.serve_forever()
    """#

    func fixture() throws -> (directory: URL, executable: String, model: String)? {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else { return nil }
        let directory = FileManager.default.temporaryDirectory.appending(path: "conflux-host-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appending(path: "llama-server").path
        try Self.script.write(toFile: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable)
        let model = directory.appending(path: "Tiny-Model.gguf").path
        try Data("not really a model".utf8).write(to: URL(fileURLWithPath: model))
        return (directory, executable, model)
    }

    func waitFor(_ host: LlamaServerHost, _ wanted: HostAvailability, seconds: Double = 20) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await host.availability == wanted { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    @Test func supervisesAProcess() async throws {
        guard let fixture = try fixture() else { return }
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let config = LlamaServerConfig(executable: fixture.executable, model: fixture.model, slots: 2, selfCheck: true)
        let host = LlamaServerHost(id: "test", config: config, logURL: fixture.directory.appending(path: "log.txt"))
        await host.start()
        let ready = await waitFor(host, .available)
        let state = await host.availability
        #expect(ready, "\(state)")

        let model = try #require(await host.model)
        #expect(model.id == "Tiny-Model")
        #expect(model.fingerprint.hasPrefix("llama.cpp-b42-sha256:"))
        #expect(model.capabilities == [.text])

        let reply = try await host.complete(Data(#"{"messages":[{"role":"user","content":"hi"}]}"#.utf8), timeout: 10)
        #expect(reply.status == 200)
        let refused = try await host.complete(Data(#"{"bad":true}"#.utf8), timeout: 10)
        #expect(refused.status == 400)

        // Kill it from outside: the host restarts it.
        let pids = Self.pids(of: fixture.executable)
        try #require(!pids.isEmpty)
        for pid in pids { kill(pid, SIGKILL) }
        let restarting = await waitFor(host, .starting("restarting: llama-server exited with status 9"), seconds: 5)
        let back = await waitFor(host, .available)
        let after = await host.availability
        #expect(restarting || back)
        if !back {
            let log = (try? String(contentsOf: fixture.directory.appending(path: "log.txt"), encoding: .utf8)) ?? ""
            Issue.record("""
                not back after a restart: \(after)
                log: \(log.suffix(2000))
                processes: \(Self.shell("/bin/ps", ["-axo", "pid,ppid,stat,command"]).split(separator: "\n")
                    .filter { $0.contains("conflux-host") }.joined(separator: "\n"))
                """)
        }

        host.stop()
        #expect(await host.availability == .offline)
        try? await Task.sleep(for: .milliseconds(300))
        #expect(Self.pids(of: fixture.executable).isEmpty)
    }

    @Test func reportsAMissingModelFile() async throws {
        guard let fixture = try fixture() else { return }
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let config = LlamaServerConfig(executable: fixture.executable, model: fixture.directory.appending(path: "gone.gguf").path)
        let host = LlamaServerHost(config: config, logURL: fixture.directory.appending(path: "log.txt"))
        #expect(await host.model?.fingerprint == "identifying")
        await host.start()
        guard case .failed(let why) = await host.availability else { Issue.record("should fail"); return }
        #expect(why.contains("gone.gguf"))
    }

    static func pids(of executable: String) -> [pid_t] {
        shell("/usr/bin/pgrep", ["-f", executable]).split(separator: "\n").compactMap { pid_t($0) }
    }

    static func shell(_ path: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: output, as: UTF8.self)
    }
}
