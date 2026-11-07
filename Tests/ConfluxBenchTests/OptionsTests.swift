import Foundation
import Testing
@testable import ConfluxBench

@Suite struct OptionsTests {
    @Test func endpointForms() throws {
        let expected = "http://127.0.0.1:8080"
        for form in ["127.0.0.1:8080", "http://127.0.0.1:8080", "http://127.0.0.1:8080/",
                     "http://127.0.0.1:8080/v1", "http://127.0.0.1:8080/v1/chat/completions"] {
            #expect(try RunOptions.normalizeEndpoint(form).absoluteString == expected, "\(form)")
        }
        #expect(try RunOptions.normalizeEndpoint("https://example.test").absoluteString == "https://example.test")
        #expect(throws: BenchError.self) { try RunOptions.normalizeEndpoint("ftp://example.test") }
    }

    @Test func chatURL() throws {
        let options = try RunOptions.parse(["--endpoint", "127.0.0.1:8080", "--images", "/tmp/x"])
        #expect(options.chatURL.absoluteString == "http://127.0.0.1:8080/v1/chat/completions")
    }

    @Test func defaults() throws {
        let options = try RunOptions.parse(["--endpoint", "127.0.0.1:8080", "--images", "/tmp/x",
                                            "--concurrency", "4"])
        #expect(options.effectiveWarmup == 4)
        #expect(options.effectiveRequests == 4 + 40)
        #expect(options.token == nil)
        #expect(options.timeout == 120)
    }

    @Test func durationMeansNoRequestCount() throws {
        let options = try RunOptions.parse(["--endpoint", "127.0.0.1:8080", "--images", "/tmp/x",
                                            "--duration", "600"])
        #expect(options.effectiveRequests == nil)
        #expect(options.duration == 600)
    }

    @Test func tokenComesFromTheEnvironmentOnly() throws {
        let options = try RunOptions.parse(["--endpoint", "127.0.0.1:8080", "--images", "/tmp/x"],
                                           environment: ["CONFLUX_TOKEN": "t0ken"])
        #expect(options.token == "t0ken")
        #expect(throws: BenchError.self) {
            try RunOptions.parse(["--endpoint", "127.0.0.1:8080", "--images", "/tmp/x", "--token", "x"])
        }
    }

    @Test func refusals() {
        let base = ["--endpoint", "127.0.0.1:8080", "--images", "/tmp/x"]
        for bad in [[], ["--images", "/tmp/x"], base + ["--requests", "5", "--duration", "5"],
                    base + ["--concurrency", "0"], base + ["--duration", "-1"], base + ["--concurrency"],
                    base + ["--prompt", "a", "--prompt-file", "b"]] {
            #expect(throws: BenchError.self, "\(bad)") { try RunOptions.parse(bad) }
        }
    }
}
