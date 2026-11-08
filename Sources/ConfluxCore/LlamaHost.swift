import Foundation
import llama

/// Runs one model with llama.cpp inside this process: what a sandboxed app
/// can do, and what an iPad must.
///
/// Each slot has its own llama.cpp context, so requests run side by side;
/// the model's weights and the vision projector are shared. A crash inside
/// llama.cpp takes the whole process with it, which the `llama-server`
/// runtime avoids.
public final class LlamaHost: ManagedHost, @unchecked Sendable {
    public let id: String
    public let config: ModelConfig
    public let logURL: URL
    public var slots: Int { config.slots }

    private let lock = NSLock()
    private var engine: LlamaEngine?
    private var identity: ModelInfo?
    private var state: HostAvailability = .starting("not started")
    /// Counts starts and stops, so a load that finishes after a stop is
    /// thrown away.
    private var generation = 0

    public init(id: String = "local", config: ModelConfig, logURL: URL = LlamaHost.defaultLogURL) {
        self.id = id
        self.config = config
        self.logURL = logURL
        // Provisional until the files are hashed, so requests arriving that
        // early hear "starting" rather than "no such model".
        identity = ModelInfo(id: config.modelID, capabilities: config.capabilities, fingerprint: "identifying",
                             maxImageDimension: config.projector == nil ? nil : config.maxImageDimension)
    }

    public static var defaultLogURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appending(path: "Logs/conflux/llama.log")
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

    // MARK: Lifecycle

    /// Identifies the model, loads it, and runs the self-check. Returns once
    /// the host is available or has failed.
    public func start() async {
        let generation = lock.withLock { () -> Int in
            self.generation += 1
            engine = nil
            state = .starting("identifying the model")
            return self.generation
        }
        for path in config.files where !FileManager.default.fileExists(atPath: path) {
            return set(.failed("no file at \(path)"), ifCurrent: generation)
        }
        let digest: String
        do {
            digest = try await Task.detached(priority: .utility) { [config] in
                try FileHash.combined(config.files)
            }.value
        } catch {
            return set(.failed("can't read the model file: \(error.localizedDescription)"), ifCurrent: generation)
        }
        lock.withLock {
            identity = ModelInfo(id: config.modelID, capabilities: config.capabilities,
                                 fingerprint: "llama.cpp-b\(LlamaRuntime.build)-sha256:\(digest.prefix(12))",
                                 maxImageDimension: config.projector == nil ? nil : config.maxImageDimension)
        }

        set(.starting("loading the model"), ifCurrent: generation)
        LlamaRuntime.initialize()
        LlamaLog.shared.open(logURL)
        LlamaLog.shared.note("--- \(Date()) loading \(config.modelID)\n")
        let mark = LlamaLog.shared.mark()
        let loaded: LlamaEngine
        do {
            loaded = try await Task.detached(priority: .userInitiated) { [config] in
                try LlamaEngine(config: config)
            }.value
        } catch {
            return set(.failed("\(error)"), ifCurrent: generation)
        }

        if config.selfCheck {
            set(.starting("checking that the model reads its input"), ifCurrent: generation)
            if let problem = await SelfCheck.run(vision: config.projector != nil, complete: { body in
                try await self.run(body, deadline: Date().addingTimeInterval(120), on: loaded)
            }) {
                let advice = SelfCheck.advice(in: LlamaLog.shared.warnings(since: mark))
                    .map { "; llama.cpp suggests: \($0)" } ?? ""
                return set(.failed("self-check failed: \(problem)\(advice)"), ifCurrent: generation)
            }
        }
        lock.withLock {
            guard self.generation == generation else { return }
            engine = loaded
            state = .available
        }
    }

    /// Stops taking work. The model is freed once requests still running
    /// finish.
    public func stop() {
        lock.withLock {
            generation += 1
            engine = nil
            state = .offline
        }
    }

    // MARK: Requests

    public func complete(_ body: Data, timeout: TimeInterval) async throws -> HostReply {
        guard let engine = lock.withLock({ state == .available ? engine : nil }) else {
            throw HostError.unavailable("the model isn't loaded")
        }
        return try await run(body, deadline: Date().addingTimeInterval(timeout), on: engine)
    }

    private func run(_ body: Data, deadline: Date, on engine: LlamaEngine) async throws -> HostReply {
        let request: ChatCompletionRequest
        do {
            request = try ChatCompletionRequest.parse(body, marker: engine.marker)
        } catch {
            return HostReply(status: 400, body: ChatCompletionResult.error(error.message))
        }
        if !request.images.isEmpty && !engine.acceptsImages {
            return HostReply(status: 400, body: ChatCompletionResult.error("this model doesn't accept images"))
        }
        guard let slot = engine.acquire() else { throw HostError.unavailable("every slot is busy") }
        defer { engine.release(slot) }
        // Cancelling the task stops generation at the next token: a hedged
        // copy that lost frees its slot at once.
        let stop = StopFlag()
        do {
            let result = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    slot.queue.async {
                        continuation.resume(with: Result {
                            try engine.generate(request, in: slot, deadline: deadline, stop: stop)
                        })
                    }
                }
            } onCancel: {
                stop.set()
            }
            return HostReply(status: 200, body: result.body(model: config.modelID))
        } catch let failure as LlamaEngine.Failure {
            switch failure {
            case .invalid(let message):
                return HostReply(status: 400, body: ChatCompletionResult.error(message))
            case .outOfTime:
                throw HostError.unavailable("the deadline passed while the model was running")
            case .cancelled:
                throw HostError.cancelled
            case .failed(let message):
                throw HostError.failed(status: 500, message: message)
            }
        }
    }
}

/// A host on this device, which its node starts and stops.
public protocol LocalHost: InferenceHost {
    func start() async
    func stop()
}

/// A local host running a model file the person chose, with llama.cpp.
public protocol ManagedHost: LocalHost {
    var config: ModelConfig { get }
    var logURL: URL { get }
}

/// A loaded model and its slots. llama.cpp's objects are freed when the last
/// owner lets go: the host, or a request still running after it stopped.
final class LlamaEngine: @unchecked Sendable {
    enum Failure: Error, CustomStringConvertible {
        /// The request can't run: 400.
        case invalid(String)
        case outOfTime
        case cancelled
        case failed(String)

        var description: String {
            switch self {
            case .invalid(let message), .failed(let message): message
            case .outOfTime: "out of time"
            case .cancelled: "cancelled"
            }
        }
    }

    final class Slot: @unchecked Sendable {
        let index: Int
        let context: OpaquePointer
        let queue: DispatchQueue
        var batch: llama_batch
        let batchSize: Int32

        init(index: Int, context: OpaquePointer, batchSize: Int32) {
            self.index = index
            self.context = context
            self.batchSize = batchSize
            batch = llama_batch_init(batchSize, 0, 1)
            queue = DispatchQueue(label: "conflux.llama.slot.\(index)", qos: .userInitiated)
        }

        /// Frees the context. The engine calls it, before it frees the
        /// model the context came from.
        fileprivate func close() {
            llama_batch_free(batch)
            llama_free(context)
        }
    }

    let model: OpaquePointer
    let vocab: OpaquePointer
    /// The multimodal context, for a model with a projector.
    let vision: OpaquePointer?
    let template: UnsafePointer<CChar>?
    let marker: String
    let contextSize: Int
    private let slots: [Slot]
    private let lock = NSLock()
    private var idle: [Int]
    /// The projector's context isn't safe to use from two slots at once.
    private let visionLock = NSLock()

    var acceptsImages: Bool { vision != nil }

    init(config: ModelConfig) throws(Failure) {
        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = -1 // all of them
        guard let model = llama_model_load_from_file(config.model, modelParams) else {
            throw .failed("llama.cpp couldn't load \(URL(fileURLWithPath: config.model).lastPathComponent); see the log")
        }
        self.model = model
        vocab = llama_model_get_vocab(model)
        template = llama_model_chat_template(model, nil)
        contextSize = config.contextPerSlot
        let threads = LlamaRuntime.threads

        if let projector = config.projector {
            var params = mtmd_context_params_default()
            params.use_gpu = true
            params.n_threads = threads
            params.print_timings = false
            if let minimum = config.imageMinTokens { params.image_min_tokens = Int32(minimum) }
            guard let vision = mtmd_init_from_file(projector, model, params) else {
                llama_model_free(model)
                throw .failed("llama.cpp couldn't load the projector \(URL(fileURLWithPath: projector).lastPathComponent); see the log")
            }
            guard mtmd_support_vision(vision) else {
                mtmd_free(vision)
                llama_model_free(model)
                throw .failed("the projector doesn't support images")
            }
            self.vision = vision
            marker = String(cString: mtmd_default_marker())
        } else {
            vision = nil
            marker = "<__media__>"
        }

        var made: [Slot] = []
        for index in 0..<max(1, config.slots) {
            var params = llama_context_default_params()
            params.n_ctx = UInt32(config.contextPerSlot)
            params.n_batch = UInt32(min(2048, config.contextPerSlot))
            params.n_ubatch = UInt32(min(512, config.contextPerSlot))
            params.n_seq_max = 1
            params.n_threads = threads
            params.n_threads_batch = threads
            guard let context = llama_init_from_model(model, params) else {
                made.forEach { $0.close() }
                if let vision { mtmd_free(vision) }
                llama_model_free(model)
                throw .failed("llama.cpp couldn't make a context of \(config.contextPerSlot) tokens for slot \(index + 1); try fewer slots or less context")
            }
            made.append(Slot(index: index, context: context, batchSize: Int32(params.n_batch)))
        }
        slots = made
        idle = made.map(\.index)
    }

    deinit {
        // Stored properties are released after this body runs, so the
        // contexts are freed here, explicitly, before the model they came
        // from. No request is running: each holds the engine until it ends.
        slots.forEach { $0.close() }
        if let vision { mtmd_free(vision) }
        llama_model_free(model)
    }

    func acquire() -> Slot? {
        lock.withLock { idle.isEmpty ? nil : slots[idle.removeFirst()] }
    }

    func release(_ slot: Slot) {
        lock.withLock { idle.append(slot.index) }
    }

    // MARK: Generating

    /// Runs one request to completion on `slot`. Blocks: call it on the
    /// slot's queue.
    func generate(_ request: ChatCompletionRequest, in slot: Slot, deadline: Date,
                  stop: StopFlag = StopFlag()) throws(Failure) -> ChatCompletionResult {
        let context = slot.context
        llama_memory_clear(llama_get_memory(context), true)
        let prompt = try format(request.messages)

        let promptStart = Date()
        var position: llama_pos
        let promptTokens: Int
        if let vision {
            (position, promptTokens) = try evaluate(prompt, images: request.images, vision: vision, in: slot)
        } else {
            let tokens = try tokenize(prompt)
            promptTokens = tokens.count
            guard promptTokens < contextSize else { throw .invalid(tooLong(promptTokens)) }
            position = 0
            var start = 0
            while start < tokens.count {
                let end = min(tokens.count, start + Int(slot.batchSize))
                try decode(tokens[start..<end], at: position, in: slot, logitsForLast: end == tokens.count)
                position += llama_pos(end - start)
                start = end
            }
        }
        let promptMs = Date().timeIntervalSince(promptStart) * 1000

        let sampler = makeSampler(request)
        defer { llama_sampler_free(sampler) }
        let generateStart = Date()
        var output: [UInt8] = []
        var generated = 0
        var finish = "length"
        var text: String?
        let limit = min(request.maxTokens ?? Int.max, contextSize - Int(position))
        while generated < limit {
            guard Date() < deadline else { throw .outOfTime }
            guard !stop.isSet else { throw .cancelled }
            let token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) {
                finish = "stop"
                break
            }
            generated += 1
            output += piece(token)
            if !request.stop.isEmpty,
               let cut = ChatCompletionRequest.truncate(String(decoding: output, as: UTF8.self), atFirstOf: request.stop) {
                text = cut
                finish = "stop"
                break
            }
            guard generated < limit else { break }
            try decode([token], at: position, in: slot, logitsForLast: true)
            position += 1
        }
        return ChatCompletionResult(
            text: text ?? String(decoding: output, as: UTF8.self), finishReason: finish,
            promptTokens: promptTokens, completionTokens: generated,
            promptMs: promptMs, predictedMs: Date().timeIntervalSince(generateStart) * 1000)
    }

    private func tooLong(_ tokens: Int) -> String {
        "the prompt is \(tokens) tokens, and this host's context is \(contextSize)"
    }

    /// The messages in the model's chat template, ready for the assistant's
    /// turn.
    func format(_ messages: [ChatCompletionRequest.Message]) throws(Failure) -> String {
        let strings = messages.map { (strdup($0.role), strdup($0.text)) }
        defer { strings.forEach { free($0.0); free($0.1) } }
        let chat = strings.map { llama_chat_message(role: $0.0, content: $0.1) }
        let needed = llama_chat_apply_template(template, chat, chat.count, true, nil, 0)
        guard needed >= 0 else { throw .failed("llama.cpp doesn't support this model's chat template") }
        var buffer = [CChar](repeating: 0, count: Int(needed) + 1)
        _ = llama_chat_apply_template(template, chat, chat.count, true, &buffer, Int32(buffer.count))
        return String(decoding: buffer.prefix(Int(needed)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Tokenizes the prompt with its images, checks it fits, and runs it
    /// through the model. Returns the next position and the prompt's tokens.
    private func evaluate(_ prompt: String, images: [Data], vision: OpaquePointer,
                          in slot: Slot) throws(Failure) -> (llama_pos, Int) {
        var bitmaps: [OpaquePointer] = []
        defer { bitmaps.forEach { mtmd_bitmap_free($0) } }
        for image in images {
            let wrapper = image.withUnsafeBytes { bytes in
                mtmd_helper_bitmap_init_from_buf(vision, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count,
                                                 false, mtmd_helper_init_opt_default())
            }
            if let video = wrapper.video_ctx { mtmd_helper_video_free(video) }
            guard let bitmap = wrapper.bitmap else { throw .invalid("an image couldn't be decoded") }
            bitmaps.append(bitmap)
        }

        guard let chunks = mtmd_input_chunks_init() else { throw .failed("out of memory") }
        defer { mtmd_input_chunks_free(chunks) }
        let status = prompt.withCString { text in
            var input = mtmd_input_text(text: text, text_len: strlen(text), add_special: true, parse_special: true)
            let pointers: [OpaquePointer?] = bitmaps
            return pointers.withUnsafeBufferPointer { mtmd_tokenize(vision, chunks, &input, $0.baseAddress, $0.count) }
        }
        switch status {
        case 0: break
        case 1: throw .invalid("the number of images doesn't match the places for them")
        default: throw .invalid("an image couldn't be prepared for the model")
        }
        let tokens = mtmd_helper_get_n_tokens(chunks)
        guard tokens < contextSize else { throw .invalid(tooLong(tokens)) }

        var next: llama_pos = 0
        let result = visionLock.withLock {
            mtmd_helper_eval_chunks(vision, slot.context, chunks, 0, 0, slot.batchSize, true, &next)
        }
        guard result == 0 else { throw .failed("llama.cpp couldn't read the prompt (\(result))") }
        return (next, tokens)
    }

    private func tokenize(_ text: String) throws(Failure) -> [llama_token] {
        let length = Int32(text.utf8.count)
        let needed = -llama_tokenize(vocab, text, length, nil, 0, true, true)
        guard needed > 0 else { throw .invalid("the prompt is empty") }
        var tokens = [llama_token](repeating: 0, count: Int(needed))
        let count = llama_tokenize(vocab, text, length, &tokens, needed, true, true)
        guard count >= 0 else { throw .failed("llama.cpp couldn't tokenize the prompt") }
        return Array(tokens.prefix(Int(count)))
    }

    private func decode(_ tokens: ArraySlice<llama_token>, at start: llama_pos, in slot: Slot,
                        logitsForLast: Bool) throws(Failure) {
        let batch = slot.batch
        for (offset, token) in tokens.enumerated() {
            batch.token[offset] = token
            batch.pos[offset] = start + llama_pos(offset)
            batch.n_seq_id[offset] = 1
            batch.seq_id[offset]![0] = 0
            batch.logits[offset] = logitsForLast && offset == tokens.count - 1 ? 1 : 0
        }
        slot.batch.n_tokens = Int32(tokens.count)
        let result = llama_decode(slot.context, slot.batch)
        guard result == 0 else { throw .failed("llama.cpp couldn't decode (\(result))") }
    }

    private func piece(_ token: llama_token) -> [UInt8] {
        var buffer = [CChar](repeating: 0, count: 64)
        var count = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        if count < 0 {
            buffer = [CChar](repeating: 0, count: Int(-count))
            count = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        }
        return buffer.prefix(Int(max(0, count))).map { UInt8(bitPattern: $0) }
    }

    /// llama-server's order: top-k, top-p, min-p, temperature, then a draw.
    private func makeSampler(_ request: ChatCompletionRequest) -> UnsafeMutablePointer<llama_sampler> {
        let chain = llama_sampler_chain_init(llama_sampler_chain_default_params())!
        if request.temperature <= 0 {
            llama_sampler_chain_add(chain, llama_sampler_init_greedy())
        } else {
            if request.topK > 0 { llama_sampler_chain_add(chain, llama_sampler_init_top_k(Int32(request.topK))) }
            llama_sampler_chain_add(chain, llama_sampler_init_top_p(Float(request.topP), 1))
            llama_sampler_chain_add(chain, llama_sampler_init_min_p(Float(request.minP), 1))
            llama_sampler_chain_add(chain, llama_sampler_init_temp(Float(request.temperature)))
            llama_sampler_chain_add(chain, llama_sampler_init_dist(request.seed ?? UInt32.random(in: 0..<UInt32.max)))
        }
        return chain
    }
}

/// Set from any thread to stop a generation at its next token.
final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    func set() { lock.withLock { stopped = true } }
    var isSet: Bool { lock.withLock { stopped } }
}
