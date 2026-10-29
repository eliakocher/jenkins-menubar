import Foundation
import Testing

@testable import MenubarCore

@Suite("ProcessRunner")
struct ProcessRunnerTests {
    @Test("ACC-01 a tool that ends before reading the token doesn't end the app")
    func toolIgnoringItsInput() async throws {
        // More than a pipe holds, so the write hits the closed pipe.
        let output = try await SystemProcessRunner().run(URL(filePath: "/usr/bin/true"), arguments: [], input: Data(count: 1_000_000))
        #expect(output.status == 0)
    }

    @Test("ACC-01 passes the input on stdin and returns stdout, stderr and the exit status")
    func passesInputAndOutput() async throws {
        let output = try await SystemProcessRunner().run(
            URL(filePath: "/bin/sh"),
            arguments: ["-c", "cat; echo oops >&2; exit 3"],
            input: Data("secret on stdin".utf8)
        )
        #expect(output.status == 3)
        #expect(String(decoding: output.standardOutput, as: UTF8.self) == "secret on stdin")
        #expect(String(decoding: output.standardError, as: UTF8.self) == "oops\n")
    }
}
