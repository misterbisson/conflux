import AppKit
import ConfluxCore
import SwiftUI
import UniformTypeIdentifiers

struct ConfluxApp: App {
    @StateObject private var model = AppModel()

    init() {
        // Run from the command line, the process starts as a background tool.
        // This makes it an ordinary app with a Dock icon and a window in front.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate()
    }

    var body: some Scene {
        WindowGroup("conflux") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 520, minHeight: 640)
        }
        .windowResizability(.contentSize)
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var settings: NodeSettings {
        didSet { save() }
    }
    @Published private(set) var snapshot: SchedulerSnapshot?
    @Published private(set) var running = false
    @Published private(set) var port: UInt16?
    @Published private(set) var intent: OwnerIntent = .serving
    @Published var problem: String?

    let node = ConfluxNode()
    private let access = ModelAccess()
    private var polling: Task<Void, Never>?
    private static let key = "settings"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode(NodeSettings.self, from: data) {
            settings = saved
        } else {
            settings = NodeSettings()
        }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                if let self { self.snapshot = await self.node.scheduler.snapshot() }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                               queue: .main) { [node] _ in
            // Don't leave llama-server running after the app quits.
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                await node.stop()
                done.signal()
            }
            _ = done.wait(timeout: .now() + 3)
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    var host: HostSnapshot? { snapshot?.hosts.first }

    func start() {
        problem = nil
        var settings = settings
        if var host = settings.host {
            // In the sandbox, the model files open only through the bookmarks
            // made when they were chosen.
            do {
                let paths = try access.open([host.model] + (host.projector.map { [$0] } ?? []))
                host.model = paths[0]
                if host.projector != nil { host.projector = paths[1] }
            } catch {
                problem = error.localizedDescription
                return
            }
            // Keep a moved file's new path.
            if host.model != settings.host?.model || host.projector != settings.host?.projector {
                self.settings.host?.model = host.model
                self.settings.host?.projector = host.projector
            }
            // The app runs models in-process: a sandboxed app can't run
            // llama-server. `conflux serve --runtime llama-server` can.
            host.runtime = .inProcess
            settings.host = host
        }
        Task {
            do {
                port = try await node.start(settings)
                running = true
                intent = .serving
            } catch {
                problem = "Couldn't start the gateway on port \(settings.port): \(error.localizedDescription)"
            }
        }
    }

    func stop() {
        Task {
            await node.stop()
            access.close()
            running = false
            port = nil
        }
    }

    func setIntent(_ intent: OwnerIntent) {
        self.intent = intent
        Task { await node.setIntent(intent) }
    }

    var token: String? { try? TokenStore.token() }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func rotateToken() {
        _ = try? TokenStore.rotate()
        objectWillChange.send()
        if running { start() }
    }

    func choose(projector: Bool) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "gguf") ?? .data]
        panel.message = projector ? "Choose the model's multimodal projector (mmproj)" : "Choose a GGUF model"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        problem = nil
        do {
            try access.remember(url)
        } catch where ModelAccess.sandboxed {
            // It still opens until the app quits, but not after.
            problem = "conflux can open \(url.lastPathComponent) until it quits, but not after: \(error.localizedDescription)"
        } catch {}
        var host = settings.host ?? ModelConfig(model: "")
        if projector { host.projector = url.path } else { host.model = url.path }
        settings.host = host
        access.keep(only: [host.model] + (host.projector.map { [$0] } ?? []))
    }
}
