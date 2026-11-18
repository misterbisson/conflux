import Foundation
import Testing
@testable import ConfluxCore

/// Tags, holding back and `context-<N>k`: asking for the work a request
/// needs rather than a model (docs/design.md, Capabilities and tags).
@Suite struct ModelTagsTests {
    func needs(_ name: String) -> ModelChoice.Needs? { ModelChoice.Needs(name) }

    func model(_ id: String = "m", vision: Bool = true, filter: Bool = false, context: Int? = 4096,
               tags: [String] = [], held: Bool = false) -> ModelInfo {
        ModelInfo(id: id, capabilities: vision ? [.text, .vision] : [.text], fingerprint: "f", contentFilter: filter,
                  contextTokens: context).labelled(ModelLabels(tags: tags, onlyWhenAsked: held))
    }

    // MARK: Reading requests

    @Test func readsTermsJoinedToAny() {
        #expect(needs("any") == ModelChoice.Needs())
        #expect(needs("any+editorial+context-32k") == ModelChoice.Needs(contextTokens: 32768, tags: ["editorial"]))
        #expect(needs("any+vision+unfiltered") == ModelChoice.Needs(vision: true, unfiltered: true))
        #expect(needs("any+text") == ModelChoice.Needs())
        #expect(needs("any+my-own-tag") == ModelChoice.Needs(tags: ["my-own-tag"]))
    }

    @Test func aliasesAreOtherSpellings() {
        #expect(needs("any-vision") == needs("any+vision"))
        #expect(needs("any-unfiltered") == needs("any+unfiltered"))
        #expect(needs("any-vision-unfiltered") == needs("any+vision+unfiltered"))
        #expect(needs("any-vision+editorial") == needs("any+editorial+vision"))
    }

    @Test func anImageTagImpliesVision() {
        #expect(needs("any+image-description")?.vision == true)
        #expect(needs("any+editorial")?.vision == false)
    }

    @Test func anythingElseNamesAModel() {
        for name in ["gemma-3-4b-it-Q4_K_M", "any+Editorial", "any+", "any+context-32", "any+context-0k",
                     "anything", "any-text"] {
            #expect(needs(name) == nil, "\(name)")
        }
        let choice = ModelChoice(model: "any+Editorial", preference: nil)
        #expect(choice.options == [.exact("any+Editorial")])
    }

    @Test func preferenceListsMixModelsAndNeeds() {
        let choice = ModelChoice(model: nil, preference: "any-vision, any+image-critique, some-model")
        #expect(choice.options == [.capability(.vision), .needs(ModelChoice.Needs(vision: true, tags: ["image-critique"])),
                                   .exact("some-model")])
    }

    @Test func namesAreTheShortestSpelling() {
        #expect(ModelChoice.Option.any.name == "any")
        #expect(ModelChoice.Option.unfiltered(.vision).name == "any-vision-unfiltered")
        #expect(needs("any+editorial+context-32k")?.name == "any+context-32k+editorial")
        #expect(needs("any+vision+image-description")?.name == "any+image-description")
        #expect(needs("any+unfiltered+writing")?.name == "any+unfiltered+writing")
    }

    // MARK: Matching

    @Test func tagsMustAllBeThere() {
        let both = model(tags: ["editorial", "writing"])
        #expect(needs("any+editorial")!.accepts(both))
        #expect(needs("any+editorial+writing")!.accepts(both))
        #expect(!needs("any+editorial+code")!.accepts(both))
        #expect(!needs("any+editorial")!.accepts(model()))
    }

    @Test func contextIsAFloor() {
        #expect(needs("any+context-4k")!.accepts(model(context: 4096)))
        #expect(!needs("any+context-8k")!.accepts(model(context: 4096)))
        // A peer from before context was reported says nothing, so meets no floor.
        #expect(!needs("any+context-1k")!.accepts(model(context: nil)))
        #expect(needs("any")!.accepts(model(context: nil)))
    }

    @Test func aModelHeldBackAnswersOnlyItsNameAndTags() {
        let held = model("large", tags: ["editorial", "reasoning"], held: true)
        for name in ["any", "any-vision", "any-unfiltered", "any+vision", "any+context-4k"] {
            #expect(!ModelChoice(model: name, preference: nil).options[0].accepts(held), "\(name)")
        }
        #expect(ModelChoice(model: "large", preference: nil).options[0].accepts(held))
        #expect(needs("any+editorial")!.accepts(held))
        #expect(needs("any+reasoning+context-4k")!.accepts(held))
        #expect(!needs("any+editorial+code")!.accepts(held))
    }

    @Test func factsStillHold() {
        #expect(!needs("any+image-description")!.accepts(model(vision: false, tags: ["image-description"])))
        #expect(!needs("any+unfiltered+editorial")!.accepts(model(filter: true, tags: ["editorial"])))
    }

    // MARK: Labels

    @Test func imageTagsOnlyOnAModelThatReadsImages() {
        #expect(model(vision: false, tags: ["image-description", "writing"]).tags == ["writing"])
        #expect(model(vision: true, tags: ["image-description", "writing"]).tags == ["image-description", "writing"])
    }

    @Test func labelsAreTidied() {
        let labels = ModelLabels(tags: [" Writing", "writing", "code", "Not A Tag", "any", "context-8k"])
        #expect(labels.tags == ["code", "writing"])
        #expect(labels.with("editorial", true).tags == ["code", "editorial", "writing"])
        #expect(labels.with("code", false).tags == ["writing"])
        #expect(labels.held(true).onlyWhenAsked)
    }

    @Test func customTagsFollowTheRules() {
        #expect(ModelTag.problem(withCustom: "art-direction") == nil)
        #expect(ModelTag.problem(withCustom: "v2-tests") == nil)
        for bad in ["", "Art", "2d", "-x", "a b", "a_b", "any", "vision", "unfiltered", "text", "context-8k",
                    "editorial", String(repeating: "a", count: 33)] {
            #expect(ModelTag.problem(withCustom: bad) != nil, "\(bad)")
        }
    }

    @Test func appleModelStartsTaggedForDescribingImages() {
        #expect(ModelLabels.defaults(for: AppleModelHost.alias).tags == ["image-description"])
        #expect(ModelLabels.defaults(for: "some-model").tags.isEmpty)
        #expect(NodeSettings().labels(for: AppleModelHost.alias).tags == ["image-description"])
        var settings = NodeSettings()
        settings.labels[AppleModelHost.alias] = ModelLabels()
        #expect(settings.labels(for: AppleModelHost.alias).tags.isEmpty)
    }

    @Test func settingsFromBeforeLabelsStillLoad() throws {
        let old = Data(#"{"port":8090,"requireToken":true,"peers":[],"iCloudKeychain":true}"#.utf8)
        let settings = try JSONDecoder().decode(NodeSettings.self, from: old)
        #expect(settings.labels.isEmpty)
        #expect(settings.labels(for: AppleModelHost.alias) == AppleModelHost.defaultLabels)

        var saved = settings
        saved.labels["large"] = ModelLabels(tags: ["editorial"], onlyWhenAsked: true)
        let again = try JSONDecoder().decode(NodeSettings.self, from: JSONEncoder().encode(saved))
        #expect(again.labels(for: "large") == ModelLabels(tags: ["editorial"], onlyWhenAsked: true))
    }

    // MARK: The host protocol

    @Test func aModelWithoutLabelsEncodesAsBefore() throws {
        let plain = ModelInfo(id: "m", capabilities: [.text], fingerprint: "f")
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(plain)) as? [String: Any]
        #expect(object?["tags"] == nil)
        #expect(object?["onlyWhenAsked"] == nil)
        #expect(object?["contextTokens"] == nil)
    }

    @Test func labelsCrossTheProtocol() throws {
        let labelled = model("large", context: 32768, tags: ["editorial"], held: true)
        let again = try JSONDecoder().decode(ModelInfo.self, from: JSONEncoder().encode(labelled))
        #expect(again == labelled)
    }

    @Test func aPeerFromBeforeLabelsHasNone() throws {
        let old = Data(#"{"id":"m","capabilities":["text"],"fingerprint":"f","contentFilter":false}"#.utf8)
        let model = try JSONDecoder().decode(ModelInfo.self, from: old)
        #expect(model.tags.isEmpty)
        #expect(!model.onlyWhenAsked)
        #expect(model.contextTokens == nil)
    }

    // MARK: Scheduling

    @Test func anyNeverReachesAModelHeldBack() async {
        let small = FakeHost(id: "small", model: "small")
        let large = FakeHost(id: "large", model: "large")
        large.label(tags: ["editorial"], onlyWhenAsked: true)
        let scheduler = await Scheduler.with([large, small])
        for name in ["any", "any-vision"] {
            let outcome = await scheduler.submit(Data(), choice: ModelChoice(model: name, preference: nil),
                                                 deadline: Date().addingTimeInterval(5), key: nil)
            guard case .completed(_, let model) = outcome else { Issue.record("\(outcome)"); return }
            #expect(model.id == "small")
        }
        let outcome = await scheduler.submit(Data(), choice: ModelChoice(model: "any+editorial", preference: nil),
                                             deadline: Date().addingTimeInterval(5), key: nil)
        guard case .completed(_, let model) = outcome else { Issue.record("\(outcome)"); return }
        #expect(model.id == "large")
        #expect(large.callCount == 1)
    }

    @Test func aBusyQuickModelDoesntSpillOntoOneHeldBack() async {
        let gate = Gate()
        let small = FakeHost(id: "small", model: "small", behavior: gate.reply())
        let large = FakeHost(id: "large", model: "large")
        large.label(tags: ["editorial"], onlyWhenAsked: true)
        let scheduler = await Scheduler.with([large, small])
        let deadline = Date().addingTimeInterval(5)
        let first = Task { await scheduler.submit(Data(), choice: ModelChoice(model: "any", preference: nil),
                                                  deadline: deadline, key: nil) }
        #expect(await eventually { small.callCount == 1 })
        let second = Task { await scheduler.submit(Data(), choice: ModelChoice(model: "any", preference: nil),
                                                   deadline: deadline, key: nil) }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(large.callCount == 0)
        await gate.release()
        for task in [first, second] {
            guard case .completed(_, let model) = await task.value else { Issue.record("not completed"); return }
            #expect(model.id == "small")
        }
        #expect(large.callCount == 0)
    }

    @Test func noModelWithTheTagIsUnknown() async {
        let small = FakeHost(id: "small", model: "small")
        let scheduler = await Scheduler.with([small])
        let outcome = await scheduler.submit(Data(), choice: ModelChoice(model: "any+editorial", preference: nil),
                                             deadline: Date().addingTimeInterval(1), key: nil)
        guard case .unknownModel(let message) = outcome else { Issue.record("\(outcome)"); return }
        #expect(message.contains("any+editorial"))
    }

    @Test func relabellingTellsPeersGateways() async {
        let host = FakeHost(id: "h")
        let scheduler = await Scheduler.with([host])
        let before = await scheduler.status(of: "h", after: nil, wait: 0).generation
        host.label(tags: ["writing"])
        await scheduler.refresh()
        let (snapshot, after) = await scheduler.status(of: "h", after: nil, wait: 0)
        #expect(after > before)
        #expect(snapshot?.model?.tags == ["writing"])
    }

    // MARK: /v1/models

    func models(_ hosts: [FakeHost]) async -> [[String: Any]] {
        let gateway = Gateway(scheduler: await Scheduler.with(hosts), token: "t")
        let response = await gateway.handle(HTTPRequest(method: "GET", path: "/v1/models",
                                                        headers: [("Authorization", "Bearer t")], body: Data()))
        let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        return object?["data"] as? [[String: Any]] ?? []
    }

    @Test func modelsListsATagAliasForEachTagServed() async {
        let small = FakeHost(id: "small", model: "small")
        small.label(tags: ["image-description"], contextTokens: 4096)
        let large = FakeHost(id: "large", model: "large", capabilities: [.text])
        large.label(tags: ["writing", "editorial", "house-style"], onlyWhenAsked: true, contextTokens: 32768)
        let data = await models([small, large])
        #expect(data.map { $0["id"] as? String } == [
            "any", "any-unfiltered", "any-vision", "any-vision-unfiltered",
            "any+image-description", "any+editorial", "any+writing", "any+house-style", "large", "small",
        ])
        let entry = data.first { $0["id"] as? String == "large" }?["conflux"] as? [String: Any]
        #expect(entry?["tags"] as? [String] == ["editorial", "house-style", "writing"])
        #expect(entry?["only_when_asked"] as? Bool == true)
        #expect(entry?["context_tokens"] as? Int == 32768)
        let alias = data.first { $0["id"] as? String == "any+editorial" }?["conflux"] as? [String: Any]
        #expect(alias?["description"] as? String == "any model trusted to choose, order and cut among many items toward a goal, and say why")
    }

    @Test func modelsListsTheAppleAliasBesideTheModelItReaches() async {
        let apple = FakeHost(id: "apple", model: "afm-3-core", contentFilter: true,
                             fingerprint: "apple-foundation-models-iPadOS-27.2.0-27C55")
        let ids = await models([apple]).map { $0["id"] as? String }
        #expect(ids == ["any", "any-vision", "apple-on-device", "afm-3-core"])
        // A peer from before the variants were named serves it as a model.
        let before = FakeHost(id: "before", model: "apple-on-device", contentFilter: true)
        #expect(await models([before]).map { $0["id"] as? String } == ["any", "any-vision", "apple-on-device"])
    }

    @Test func noAnyAliasWhenEveryModelIsHeldBack() async {
        let large = FakeHost(id: "large", model: "large")
        large.label(tags: ["editorial"], onlyWhenAsked: true)
        let data = await models([large])
        #expect(data.map { $0["id"] as? String } == ["any+editorial", "large"])
    }

    // MARK: Apple's model

    @Test func appleModelCanBeRelabelledWhileItServes() async {
        let host = AppleModelHost(id: "apple", slots: 1, maxImageDimension: 1024, selfCheck: false,
                                  recheck: .seconds(10), generator: { _ in throw CancellationError() })
        #expect(await host.model?.tags == ["image-description"])
        #expect(await host.model?.contextTokens == AppleModelHost.contextTokens)
        let told = Counter()
        host.observe { told.add() }
        host.label(ModelLabels(tags: ["writing"], onlyWhenAsked: true))
        #expect(await host.model?.tags == ["writing"])
        #expect(await host.model?.onlyWhenAsked == true)
        #expect(told.value == 1)
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func add() { lock.withLock { count += 1 } }
    }
}
