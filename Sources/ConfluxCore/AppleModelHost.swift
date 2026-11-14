import CoreGraphics
import Foundation
import FoundationModels
import ImageIO

/// Runs Apple's on-device model, the one Apple Intelligence uses, through
/// the Foundation Models framework.
///
/// The model runs in a system process, not in conflux's, so it takes none
/// of the app's memory: on an iPad it's outside the per-app limit. conflux
/// can't choose or pin it, and it changes with OS updates, so its
/// fingerprint is the OS build. It reads text and images.
///
/// Its guardrails decline some content, and its context is small: 4,096
/// tokens on macOS 27.0, images included. A request it declines or can't
/// fit goes to another host when there is one (`HostReply.retryElsewhere`).
///
/// Measured on an M2 MacBook Air: about 1 s to read a self-check image, and
/// about 1.2 requests a second with two at once, with little more from four
/// or eight. Hence two slots.
public final class AppleModelHost: LocalHost, @unchecked Sendable {
    /// What clients name it, and what responses report.
    public static let modelID = "apple-on-device"
    public static let defaultSlots = 2

    public let id: String
    public let slots: Int
    public let maxImageDimension: Int
    public let selfCheck: Bool

    private let lock = NSLock()
    private var state: HostAvailability = .starting("not started")
    private var identity: ModelInfo
    private var running = 0
    /// Counts starts and stops, so a check that finishes after a stop is
    /// thrown away.
    private var generation = 0
    /// How often to look again while Apple's model is downloading or Apple
    /// Intelligence is off. The framework sends no notice.
    private let recheck: Duration

    public init(id: String = "apple", slots: Int = AppleModelHost.defaultSlots, maxImageDimension: Int = 1024,
                selfCheck: Bool = true, recheck: Duration = .seconds(10)) {
        self.id = id
        self.slots = slots
        self.maxImageDimension = maxImageDimension
        self.selfCheck = selfCheck
        self.recheck = recheck
        identity = ModelInfo(id: Self.modelID, capabilities: [.text, .vision], fingerprint: Self.fingerprint,
                             maxImageDimension: maxImageDimension)
    }

    /// The runtime and the OS build, such as
    /// `apple-foundation-models-macOS-27.0.1-26A434`: the model changes only
    /// with the OS.
    public static var fingerprint: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        #if os(macOS)
        let platform = "macOS"
        #else
        let platform = "iPadOS"
        #endif
        return "apple-foundation-models-\(platform)-\(version.majorVersion).\(version.minorVersion)."
            + "\(version.patchVersion)-\(build)"
    }

    static var build: String {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &bytes, &size, nil, 0) == 0 else { return "unknown" }
        return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }

    public var model: ModelInfo? {
        get async { lock.withLock { identity } }
    }

    public var availability: HostAvailability {
        get async { lock.withLock { state } }
    }

    private func set(_ new: HostAvailability, ifCurrent generation: Int) {
        lock.withLock { if self.generation == generation { state = new } }
    }

    private func isCurrent(_ generation: Int) -> Bool { lock.withLock { self.generation == generation } }

    // MARK: Lifecycle

    enum Readiness: Equatable {
        case ready
        /// Expected to change: look again.
        case waiting(String)
        /// Won't change on this device.
        case never(String)
    }

    static func readiness(_ availability: SystemLanguageModel.Availability,
                          readsImages: Bool) -> Readiness {
        switch availability {
        case .available:
            return readsImages ? .ready : .never("Apple's model on this device doesn't read images")
        case .unavailable(.deviceNotEligible):
            return .never("this device can't run Apple's model")
        case .unavailable(.appleIntelligenceNotEnabled):
            return .waiting("Apple Intelligence is off; turn it on in System Settings")
        case .unavailable(.modelNotReady):
            return .waiting("Apple's model is still downloading")
        case .unavailable(let reason):
            return .waiting("Apple's model isn't available: \(reason)")
        }
    }

    /// Waits for Apple's model to be available, then runs the self-check.
    /// Returns once the host is available or has failed, or was stopped.
    public func start() async {
        let generation = lock.withLock { () -> Int in
            self.generation += 1
            state = .starting("checking Apple's model")
            return self.generation
        }
        while true {
            let model = SystemLanguageModel.default
            switch Self.readiness(model.availability, readsImages: model.capabilities.contains(.vision)) {
            case .ready:
                break
            case .waiting(let why):
                set(.starting(why), ifCurrent: generation)
                try? await Task.sleep(for: recheck)
                guard isCurrent(generation), !Task.isCancelled else { return }
                continue
            case .never(let why):
                return set(.failed(why), ifCurrent: generation)
            }
            break
        }
        if selfCheck {
            set(.starting("checking that the model reads its input"), ifCurrent: generation)
            if let problem = await SelfCheck.run(vision: true, complete: { body in
                try await self.run(body, deadline: Date().addingTimeInterval(120))
            }) {
                return set(.failed("self-check failed: \(problem)"), ifCurrent: generation)
            }
        }
        set(.available, ifCurrent: generation)
    }

    public func stop() {
        lock.withLock {
            generation += 1
            state = .offline
        }
    }

    /// Apple's model went away while serving, as when its assets are
    /// updated: wait for it again.
    private func lost() {
        let current = lock.withLock { () -> Bool in
            guard state == .available else { return false }
            state = .starting("Apple's model isn't available right now")
            return true
        }
        if current { Task { await self.start() } }
    }

    // MARK: Requests

    public func complete(_ body: Data, timeout: TimeInterval) async throws -> HostReply {
        guard lock.withLock({ state == .available }) else {
            throw HostError.unavailable("Apple's model isn't ready")
        }
        return try await run(body, deadline: Date().addingTimeInterval(timeout))
    }

    private func run(_ body: Data, deadline: Date) async throws -> HostReply {
        let request: AppleModelRequest
        do {
            request = try AppleModelRequest.parse(body)
        } catch .invalid(let message) {
            return HostReply(status: 400, body: ChatCompletionResult.error(message))
        } catch .unsuited(let message) {
            return Self.unsuited(message, code: "unsupported_by_model")
        }
        guard lock.withLock({ () -> Bool in
            guard running < slots else { return false }
            running += 1
            return true
        }) else { throw HostError.unavailable("every slot is busy") }
        defer { lock.withLock { running -= 1 } }

        do {
            let result = try await Self.within(deadline) { try await Self.generate(request) }
            return HostReply(status: 200, body: result.body(model: Self.modelID))
        } catch let error as Unreadable {
            return HostReply(status: 400, body: ChatCompletionResult.error(error.message))
        } catch let error as Unsuited {
            return Self.unsuited(error.message, code: "unsupported_by_model")
        } catch is DeadlinePassed {
            throw HostError.unavailable("the deadline passed while the model was running")
        } catch {
            switch Self.outcome(for: error) {
            case .success(let reply):
                return reply
            case .failure(let failure):
                if case .unavailable = failure { lost() }
                throw failure
            }
        }
    }

    struct Unreadable: Error { let message: String }
    /// Something another host might do.
    struct Unsuited: Error { let message: String }
    struct DeadlinePassed: Error {}

    /// Runs `work`, or throws `DeadlinePassed` when the deadline comes
    /// first. Cancelling the task cancels the work: a hedged copy that lost
    /// stops.
    static func within<T: Sendable>(_ deadline: Date, _ work: @escaping @Sendable () async throws -> T)
        async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
                throw DeadlinePassed()
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw DeadlinePassed() }
            return first
        }
    }

    static func generate(_ request: AppleModelRequest) async throws -> ChatCompletionResult {
        var entries: [Transcript.Entry] = []
        if let instructions = request.instructions {
            entries.append(.instructions(Transcript.Instructions(
                segments: [.text(Transcript.TextSegment(content: instructions))], toolDefinitions: [])))
        }
        for turn in request.history {
            let segments = try turn.parts.map(segment)
            switch turn.role {
            case .user: entries.append(.prompt(Transcript.Prompt(segments: segments)))
            case .assistant: entries.append(.response(Transcript.Response(assetIDs: [], segments: segments)))
            }
        }
        let pieces: [Prompt] = try request.prompt.map { part in
            switch part {
            case .text(let text):
                return Prompt(text)
            case .image(let data):
                let (image, orientation) = try decode(data)
                return Prompt(Attachment(image, orientation: orientation))
            }
        }
        guard !pieces.isEmpty else { throw Unreadable(message: "the last message is empty") }
        let session = LanguageModelSession(model: .default, tools: [], transcript: Transcript(entries: entries))
        let options = GenerationOptions(samplingMode: nil, temperature: request.temperature,
                                        maximumResponseTokens: request.maxTokens)
        let started = Date()
        var text: String
        if let schema = request.schema {
            let generation: GenerationSchema
            do {
                generation = try GenerationSchema(root: dynamic(schema), dependencies: [])
            } catch {
                throw Unsuited(message: "Apple's model can't take this schema: \(error.localizedDescription)")
            }
            let response = try await session.respond(schema: generation, options: options) {
                for piece in pieces { piece }
            }
            text = json(response.content)
        } else {
            text = try await session.respond(options: options) {
                for piece in pieces { piece }
            }.content
        }
        let elapsed = Date().timeIntervalSince(started) * 1000
        if let cut = ChatCompletionRequest.truncate(text, atFirstOf: request.stop) { text = cut }
        let usage = session.usage
        return ChatCompletionResult(text: text, finishReason: "stop", promptTokens: usage.input.totalTokenCount,
                                    completionTokens: usage.output.totalTokenCount, promptMs: 0,
                                    predictedMs: elapsed)
    }

    /// A response_format schema as guided generation takes it.
    static func dynamic(_ schema: AppleModelSchema) -> DynamicGenerationSchema {
        switch schema {
        case .object(let name, let properties):
            return DynamicGenerationSchema(name: name, properties: properties.map { property in
                DynamicGenerationSchema.Property(name: property.name, description: property.description,
                                                 schema: dynamic(property.schema), isOptional: property.optional)
            })
        case .choice(let name, let choices):
            return DynamicGenerationSchema(name: name, anyOf: choices.map(dynamic))
        case .strings(let name, let values):
            return DynamicGenerationSchema(name: name, anyOf: values)
        case .constant(let value):
            return DynamicGenerationSchema(type: String.self, guides: [.constant(value)])
        case .array(let items, let minimum, let maximum):
            return DynamicGenerationSchema(arrayOf: dynamic(items), minimumElements: minimum, maximumElements: maximum)
        case .string:
            return DynamicGenerationSchema(type: String.self)
        case .integer(let minimum, let maximum):
            var guides: [GenerationGuide<Int>] = []
            if let minimum { guides.append(.minimum(minimum)) }
            if let maximum { guides.append(.maximum(maximum)) }
            return DynamicGenerationSchema(type: Int.self, guides: guides)
        case .number:
            return DynamicGenerationSchema(type: Double.self)
        case .boolean:
            return DynamicGenerationSchema(type: Bool.self)
        case .null:
            return .null
        }
    }

    /// The answer as compact JSON, each object's properties in the order
    /// the model wrote them, which is the schema's. `jsonString` doesn't
    /// keep that order.
    static func json(_ content: GeneratedContent) -> String {
        switch content.kind {
        case .null:
            return "null"
        case .bool(let value):
            return value ? "true" : "false"
        case .number(let value):
            guard value.isFinite else { return "null" }
            if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
            return value.description
        case .string(let value):
            return OrderedJSON.quoted(value)
        case .array(let elements):
            return "[" + elements.map(json).joined(separator: ",") + "]"
        case .structure(let properties, let orderedKeys):
            let keys = orderedKeys.filter { properties[$0] != nil }
                + properties.keys.filter { !orderedKeys.contains($0) }.sorted()
            return "{" + keys.map { "\(OrderedJSON.quoted($0)):\(json(properties[$0]!))" }.joined(separator: ",") + "}"

        @unknown default:
            return content.jsonString
        }
    }

    static func segment(_ part: AppleModelRequest.Part) throws -> Transcript.Segment {
        switch part {
        case .text(let text):
            return .text(Transcript.TextSegment(content: text))
        case .image(let data):
            let (image, orientation) = try decode(data)
            return .attachment(Transcript.AttachmentSegment(
                content: .image(Transcript.ImageAttachment(image, orientation: orientation))))
        }
    }

    static func decode(_ data: Data) throws -> (CGImage, CGImagePropertyOrientation?) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw Unreadable(message: "an image doesn't decode") }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = (properties?[kCGImagePropertyOrientation] as? UInt32)
            .flatMap(CGImagePropertyOrientation.init(rawValue:))
        return (image, orientation)
    }

    static func unsuited(_ message: String, code: String) -> HostReply {
        HostReply(status: 400, body: ChatCompletionResult.error(message, code: code), retryElsewhere: true)
    }

    /// What a Foundation Models error means for the request: a refusal
    /// another host might not give, or a host error.
    static func outcome(for error: any Error) -> Result<HostReply, HostError> {
        let declined = unsuited("Apple's model declined the content", code: "content_filter")
        let tooLong = unsuited("the request is too long for Apple's model", code: "context_length_exceeded")
        if error is CancellationError { return .failure(.cancelled) }
        if let error = error as? LanguageModelError {
            switch error {
            case .contextSizeExceeded: return .success(tooLong)
            case .guardrailViolation, .refusal: return .success(declined)
            case .unsupportedCapability, .unsupportedTranscriptContent, .unsupportedGenerationGuide,
                 .unsupportedLanguageOrLocale:
                return .success(unsuited("Apple's model can't take this request: \(error.localizedDescription)",
                                         code: "unsupported_by_model"))
            case .rateLimited: return .failure(.busy("Apple's model is rate limited"))
            case .timeout: return .failure(.unavailable("Apple's model timed out"))
            @unknown default: return .failure(.failed(status: 500, message: error.localizedDescription))
            }
        }
        if let error = error as? SystemLanguageModel.Error {
            switch error {
            case .assetsUnavailable: return .failure(.unavailable("Apple's model isn't available right now"))
            @unknown default: return .failure(.failed(status: 500, message: error.localizedDescription))
            }
        }
        return .failure(.failed(status: 500, message: "\(error)"))
    }
}
