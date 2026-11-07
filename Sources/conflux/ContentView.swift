import ConfluxCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            status
            modelSection
            gatewaySection
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
                LabeledContent("Throughput", value: "\(Int(snapshot.perHour.rounded())) per hour")
                if let typical = host.typicalSeconds {
                    LabeledContent("Typical request", value: String(format: "%.1f s", typical))
                }
                LabeledContent("Completed", value: "\(snapshot.completed)")
                LabeledContent("Failed · busy · unavailable",
                               value: "\(snapshot.failed) · \(snapshot.busy) · \(snapshot.unavailable)")
                if snapshot.idleWithWorkSeconds >= 1 {
                    LabeledContent("Idle while work waited",
                                   value: String(format: "%.0f s", snapshot.idleWithWorkSeconds))
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
                .disabled(model.settings.host?.model.isEmpty ?? true)
        }
    }

    var stateLabel: String {
        guard model.running else { return "Stopped" }
        return model.host?.state.label ?? "Gateway only"
    }

    var color: Color {
        guard model.running, let state = model.host?.state else { return .gray }
        switch state {
        case .ready: return .green
        case .busy: return .blue
        case .draining, .paused, .starting: return .orange
        case .failed, .offline: return .red
        }
    }

    // MARK: Model

    @ViewBuilder var modelSection: some View {
        Section("Model") {
            path("Model", model.settings.host?.model, projector: false)
            path("Projector", model.settings.host?.projector, projector: true)
            if model.settings.host?.projector != nil {
                Button("Remove projector (text only)") { model.settings.host?.projector = nil }
            }
            Stepper("Slots: \(host.slots)", value: binding(\.slots), in: 1...32)
            Stepper("Context per slot: \(host.contextPerSlot)", value: binding(\.contextPerSlot),
                    in: 1024...65536, step: 1024)
            Stepper("Largest image side: \(host.maxImageDimension) px", value: binding(\.maxImageDimension),
                    in: 256...4096, step: 128)
            Toggle("Check the model reads its input before serving", isOn: binding(\.selfCheck))
            if model.settings.host?.projector != nil {
                TextField("Fewest tokens per image", value: binding(\.imageMinTokens), format: .number.grouping(.never),
                          prompt: Text("the model's own setting"))
                Text("Some models read small images badly with fewer tokens. Qwen-VL models want 1024.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Slots come from measuring this Mac with its model. See docs/phase-0.md.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .disabled(model.running)
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
}
