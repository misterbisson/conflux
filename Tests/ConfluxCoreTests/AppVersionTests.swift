import ConfluxCore
import Testing

@Suite struct AppVersionTests {
    @Test func versionAndBuild() {
        #expect(AppVersion.label(["CFBundleShortVersionString": "0.4.3", "CFBundleVersion": "12"]) == "0.4.3 (12)")
    }

    @Test func noBuild() {
        #expect(AppVersion.label(["CFBundleShortVersionString": "0.4.3"]) == "0.4.3")
    }

    @Test func builtFromSource() {
        #expect(AppVersion.label([:]) == "Built from source")
    }
}
