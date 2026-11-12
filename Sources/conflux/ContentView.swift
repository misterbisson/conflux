import ConfluxCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            status
            modelSection
            appleSection
            meshSection
            monitoringSection
            gatewaySection
            aboutSection
        }
        .formStyle(.grouped)
        .padding(.bottom, 8)
    }

    // MARK: Status

    @ViewBuilder var status: some View {
        Section {
            HStack(alignment: .firstTextBaseline) {
                Circle().fill(color).frame(width: 10, height: 10)
                Text(stateLabel).font(.title2.weight(.semibold))
                Spacer()
                controls
            }
            if let detail = model.host?.state.detail {
                Text(detail).foregroundStyle(.secondary)
            }
            if let problem = model.problem {
                Text(problem).foregroundStyle(.red)
            }
            if let host = model.host, let snapshot = model.snapshot {
                if let served = host.model {
                    LabeledContent("Serving", value: served.id)
                    LabeledContent("Fingerprint") {
                        Text(served.fingerprint).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
                LabeledContent("Slots", value: "\(host.active) busy of \(host.capacity)"
                    + (host.capacity < host.slots ? " (limited from \(host.slots))" : ""))
                LabeledContent("Waiting", value: "\(snapshot.queued)")
                if let typical = host.typicalSeconds {
                    LabeledContent("Typical request", value: String(format: "%.1f s", typical))
                }
            }
        }
    }

    @ViewBuilder var controls: some View {
        if model.running {
            if model.intent == .serving {
                Button("Drain") { model.setIntent(.draining) }
                    .help("Finish what's running and take nothing new")
                Button("Pause") { model.setIntent(.paused) }
            } else {
                Button("Resume") { model.setIntent(.serving) }
            }
            Button("Stop") { model.stop() }
        } else {
            Button("Start") { model.start() }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canStart)
        }
    }

    var stateLabel: String {
        guard model.running else { return "Stopped" }
        return (model.host ?? model.appleHost)?.state.label ?? "Gateway only"
    }

    var color: Color {
        guard model.running, let state = (model.host ?? model.appleHost)?.state else { return .gray }
        return color(for: state)
    }

    // MARK: Model

    @ViewBuilder var modelSection: some View {
        Section("Model") {
            if model.servesStarter {
                LabeledContent("Model") {
                    HStack {
                        Text("Starter model, included").lineLimit(1)
                        Button("Choose…") { model.choose(projector: false) }
                    }
                }
                Text("""
                    \(StarterModel.modelFile), with its projector: small, reads text and images, and answers \
                    poorly. Enough to see a client work through conflux. Choose a model to serve a real one.
                    """)
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                path("Model", model.settings.host?.model, projector: false)
                path("Projector", model.settings.host?.projector, projector: true)
                if model.settings.host?.projector != nil {
                    Button("Remove projector (text only)") { model.settings.host?.projector = nil }
                }
                if model.starter != nil {
                    Button("Use the starter model") { model.useStarter() }
                }
            }
            Stepper("Slots: \(host.slots)", value: binding(\.slots), in: 1...32)
            Picker("Context per slot", selection: binding(\.contextPerSlot)) {
                ForEach(ModelConfig.choices(ModelConfig.contextSizes, including: host.contextPerSlot), id: \.self) {
                    Text("\($0.formatted()) tokens").tag($0)
                }
            }
            Picker("Largest image side", selection: binding(\.maxImageDimension)) {
                ForEach(ModelConfig.choices(ModelConfig.imageSides, including: host.maxImageDimension), id: \.self) {
                    Text("\($0.formatted()) px").tag($0)
                }
            }
            Toggle("Check the model reads its input before serving", isOn: binding(\.selfCheck))
            if model.settings.host?.projector != nil {
                TextField("Fewest tokens per image", value: binding(\.imageMinTokens), format: .number.grouping(.never),
                          prompt: Text("the model's own setting"))
                Text("Some models read small images badly with fewer tokens. Qwen-VL models want 1024.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("""
                Slots are how many requests this Mac runs at once, and each one takes memory for its context. \
                More slots don't always mean more speed. If the Mac runs short of memory and swaps to disk, use \
                fewer slots or less context.
                """)
                .font(.caption).foregroundStyle(.secondary)
        }
        .disabled(model.running)
    }

    // MARK: Apple's model

    @ViewBuilder var appleSection: some View {
        Section("Apple's model") {
            Toggle("Serve Apple's on-device model too", isOn: $model.settings.appleModel.enabled)
                .disabled(model.running)
            if model.settings.appleModel.enabled {
                if let apple = model.appleHost, model.running {
                    LabeledContent("State") {
                        HStack {
                            Circle().fill(color(for: apple.state)).frame(width: 8, height: 8)
                            Text(apple.state.label)
                        }
                    }
                    if let detail = apple.state.detail {
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                    LabeledContent("Slots", value: "\(apple.active) busy of \(apple.capacity)")
                    if let typical = apple.typicalSeconds {
                        LabeledContent("Typical request", value: String(format: "%.1f s", typical))
                    }
                }
                Stepper("Slots: \(model.settings.appleModel.slots)", value: $model.settings.appleModel.slots, in: 1...8)
                    .disabled(model.running)
            }
            Text("""
                The model Apple Intelligence uses, served as \(AppleModelHost.modelID): text and images, in a system \
                process, so it takes none of conflux's memory. It needs Apple Intelligence turned on. It declines \
                some content and takes only short requests; those go to another host when there is one.
                """)
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    var host: ModelConfig { model.settings.host ?? ModelConfig(model: "") }

    func binding<T>(_ path: WritableKeyPath<ModelConfig, T>) -> Binding<T> {
        Binding(get: { host[keyPath: path] },
                set: { value in
                    var updated = host
                    updated[keyPath: path] = value
                    model.settings.host = updated
                })
    }

    func path(_ label: String, _ value: String?, projector: Bool) -> some View {
        LabeledContent(label) {
            HStack {
                Text(value.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "None")
                    .foregroundStyle(value == nil ? .secondary : .primary)
                    .lineLimit(1).truncationMode(.middle)
                Button("Choose…") { model.choose(projector: projector) }
            }
        }
    }

    // MARK: Mesh

    @State private var newPeer = ""
    @State private var peerProblem: String?
    @State private var forgetting: TrustedPeer?

    @ViewBuilder var meshSection: some View {
        Section("Mesh") {
            if let id = model.endpointID {
                LabeledContent("This Mac") {
                    HStack {
                        Text(DeviceIdentity.short(id) + "…").font(.body.monospaced())
                            .help(id)
                        Button("Copy ID") { model.copy(id) }
                    }
                }
            }
            if model.directory != nil {
                Toggle("Find my Macs through iCloud Keychain",
                       isOn: Binding(get: { model.settings.iCloudKeychain }, set: { model.setICloudKeychain($0) }))
                    .disabled(model.running)
                if let notice = model.directoryNotice {
                    Text(notice).font(.caption).foregroundStyle(.orange)
                }
                if let problem = model.directoryProblem {
                    Text(problem).font(.caption).foregroundStyle(.red)
                }
            }
            if let problem = model.meshProblem {
                Text(problem).foregroundStyle(.red)
            }
            ForEach(model.trusted) { peer in
                peerRow(peer)
            }
            if !model.running {
                HStack {
                    TextField("Peer", text: $newPeer, prompt: Text("another Mac's ID"))
                        .font(.body.monospaced())
                        .onSubmit(addPeer)
                    Button("Add", action: addPeer).disabled(newPeer.isEmpty)
                }
                if let peerProblem {
                    Text(peerProblem).font(.caption).foregroundStyle(.red)
                }
            }
            if model.refused > 0 {
                LabeledContent("Refused", value: "\(model.refused) connections from devices that aren't peers")
            }
            Text(meshCaption).font(.caption).foregroundStyle(.secondary)
        }
        .confirmationDialog("Forget \(forgetting?.name ?? "this Mac")?",
                            isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }),
                            presenting: forgetting) { peer in
            Button("Forget", role: .destructive) { model.forget(peer.endpointID) }
        } message: { _ in
            Text("It's removed from iCloud Keychain on every Mac, and none of them trusts it. If conflux is running there, it stays out until it's turned on there again.")
        }
    }

    var meshCaption: String {
        let found = "Macs signed in to this Apple Account, with iCloud Keychain on here and there, find each other."
        let byHand = "Peers added by hand have to add each other."
        let none = "With no peers, conflux connects to nothing."
        return switch (model.directory != nil, model.settings.iCloudKeychain) {
        case (true, true): "Peers use each other's models. \(found) \(byHand)"
        case (true, false): "Peers use each other's models. \(byHand) \(none)"
        case (false, _): "Peers use each other's models. \(byHand) Built from source, conflux can't use iCloud Keychain. \(none)"
        }
    }

    func addPeer() {
        peerProblem = model.addPeer(newPeer)
        if peerProblem == nil { newPeer = "" }
    }

    @ViewBuilder func peerRow(_ peer: TrustedPeer) -> some View {
        let id = peer.endpointID
        let status = model.peers.first { $0.endpointID == id }
        let host = status.flatMap(model.peerHost)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Circle().fill(host.map { color(for: $0.state) } ?? .gray).frame(width: 8, height: 8)
                if let name = peer.name {
                    Text(name).lineLimit(1).truncationMode(.middle)
                }
                Text(DeviceIdentity.short(id) + "…").font(.body.monospaced())
                    .foregroundStyle(peer.name == nil ? .primary : .secondary).help(id)
                Text(host?.state.label ?? (model.running ? "Not started" : "Peer"))
                Spacer()
                if peer.addedByHand && !model.running {
                    Button("Remove") { model.removePeer(id) }
                }
                if peer.listed {
                    Button("Forget…") { forgetting = peer }
                }
            }
            Text(source(of: peer)).font(.caption).foregroundStyle(.secondary)
            if let host, model.running {
                let parts = [host.model?.id, status.map(\.path.label),
                             host.capacity > 0 ? "\(host.active) busy of \(host.capacity)" : nil,
                             host.completed > 0 ? "\(host.completed) completed" : nil].compactMap { $0 }
                Text(parts.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                if let detail = host.state.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    func source(of peer: TrustedPeer) -> String {
        switch (peer.listed, peer.addedByHand) {
        case (true, true): "From iCloud Keychain, and added by hand"
        case (true, false): "From iCloud Keychain"
        default: "Added by hand"
        }
    }

    func color(for state: HostState) -> Color {
        switch state {
        case .ready: .green
        case .busy: .blue
        case .draining, .paused, .starting: .orange
        case .failed, .offline: .red
        }
    }

    // MARK: Monitoring

    /// Throughput, failures and idle-with-work, for the mesh and each host,
    /// as this Mac's gateway sees them.
    @ViewBuilder var monitoringSection: some View {
        if model.running, let snapshot = model.snapshot {
            Section("Monitoring") {
                LabeledContent("Throughput", value: "\(Int(snapshot.perHour.rounded())) per hour")
                LabeledContent("Completed", value: "\(snapshot.completed)")
                LabeledContent("Idle while work waited", value: Self.seconds(snapshot.idleWithWorkSeconds))
                LabeledContent("Host failures", value: Self.describe(snapshot.failures))
                LabeledContent("Answered busy · unavailable", value: "\(snapshot.busy) · \(snapshot.unavailable)")
                    .help("Answers of 429, no slot in time, and 503, hosts failed or none up")
                if snapshot.hedged > 0 {
                    LabeledContent("Hedged", value: "\(snapshot.hedged), \(snapshot.hedgeWins) answered first")
                        .help("Copies of straggling requests sent to an idle host at the end of a batch")
                }
                ForEach(snapshot.hosts) { host in
                    monitoringRow(host)
                }
                Text("Idle while work waited is time a host had a free slot while work it could run waited here. It should stay near zero.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    func monitoringRow(_ host: HostSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(host.id.hasPrefix("peer-") ? host.id.dropFirst("peer-".count) + "…" : "This Mac")
                    .font(host.id.hasPrefix("peer-") ? .body.monospaced() : .body)
                Spacer()
                Text("\(Int(host.perHour.rounded())) per hour").monospacedDigit()
            }
            let parts = ["\(host.completed) completed",
                         host.typicalSeconds.map { String(format: "typical %.1f s", $0) },
                         "idle with work \(Self.seconds(host.idleWithWorkSeconds))",
                         host.prefetched > 0 ? "\(host.prefetched) sent ahead" : nil,
                         host.failures.total > 0 ? Self.describe(host.failures) : nil].compactMap { $0 }
            Text(parts.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
        }
    }

    static func seconds(_ value: Double) -> String {
        value < 10 ? String(format: "%.1f s", value) : String(format: "%.0f s", value)
    }

    static func describe(_ failures: FailureCounts) -> String {
        guard failures.total > 0 else { return "none" }
        return [(failures.unavailable, "not answering"), (failures.failed, "server error"),
                (failures.busy, "busy"), (failures.deadline, "out of time")]
            .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }.joined(separator: " · ")
    }

    // MARK: Gateway

    @ViewBuilder var gatewaySection: some View {
        Section("Gateway") {
            LabeledContent("Port") {
                TextField("Port", value: $model.settings.port, format: .number.grouping(.never))
                    .frame(width: 80).multilineTextAlignment(.trailing)
            }
            .disabled(model.running)
            if let port = model.port {
                let url = "http://127.0.0.1:\(port)/v1"
                LabeledContent("Endpoint") {
                    HStack {
                        Text(url).font(.body.monospaced()).textSelection(.enabled)
                        Button("Copy") { model.copy(url) }
                    }
                }
            }
            Toggle("Require the token", isOn: $model.settings.requireToken)
                .disabled(model.running)
            if model.settings.requireToken {
                LabeledContent("Token") {
                    HStack {
                        Button("Copy") { if let token = model.token { model.copy(token) } }
                        Button("New token") { model.rotateToken() }
                    }
                }
            } else {
                Text("Any process on this Mac can use the gateway without a token.")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    // MARK: About

    @ViewBuilder var aboutSection: some View {
        Section("About") {
            LabeledContent("Version") {
                Text(AppVersion.current).textSelection(.enabled)
            }
            LabeledContent("Acknowledgements") {
                Button("Show…") { NSApplication.shared.orderFrontStandardAboutPanel(nil) }
            }
        }
    }
}
