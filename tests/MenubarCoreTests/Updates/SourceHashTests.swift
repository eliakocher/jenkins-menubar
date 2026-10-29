import Foundation
import Testing

@testable import MenubarCore

/// The source hash against `build.sh`'s own pipeline, on a made-up checkout in a temporary folder. The real checkout
/// isn't hashed here: other work changes its files while the tests run.
@Suite("SourceHash")
struct SourceHashTests {
    private static var repositoryRoot: URL {
        URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @Test("APP-05 source hash is stable")
    func stable() throws {
        let folder = try TemporaryFolder()
        try writeCheckout(in: folder)

        let first = try SourceHash.compute(root: folder.url)
        let second = try SourceHash.compute(root: folder.url)

        #expect(first == second)
        #expect(first.count == 64)
        #expect(first.allSatisfy { "0123456789abcdef".contains($0) })
    }

    /// The contract with `build.sh`: hidden files, symbolic links, files outside the four paths, byte order (capitals
    /// first), a name that isn't ASCII, and the names `shasum` escapes.
    @Test("APP-05 source hash equals the MMSourceHash of build.sh")
    func equalsBuildScript() async throws {
        let folder = try TemporaryFolder()
        try writeCheckout(in: folder)
        try folder.write("ignored", to: "Sources/.DS_Store")
        try folder.write("ignored", to: "Sources/.hidden/Inside.swift")
        try folder.write("ignored", to: "README.md")
        try folder.write("lower", to: "Sources/b.swift")
        try folder.write("upper", to: "Sources/B.swift")
        try folder.write("umlaut", to: "Sources/Größe.swift")
        try folder.write("backslash", to: #"Sources/back\slash.swift"#)
        try folder.write("line break", to: "Sources/line\nbreak.swift")
        try FileManager.default.createSymbolicLink(at: folder.file("Sources/Link.swift"), withDestinationURL: folder.file("Sources/b.swift"))
        try FileManager.default.createSymbolicLink(at: folder.file("icons/linked"), withDestinationURL: folder.file("Sources"))

        let expected = try await buildScriptHash(of: folder.url)

        #expect(try SourceHash.compute(root: folder.url) == expected)
    }

    @Test("APP-05 source hash changes with a source file")
    func changesWithASource() throws {
        let folder = try TemporaryFolder()
        try writeCheckout(in: folder)
        let before = try SourceHash.compute(root: folder.url)

        try folder.write("// changed", to: "Sources/MenubarCore/A.swift")
        let changed = try SourceHash.compute(root: folder.url)
        try folder.write("ignored", to: "Sources/.DS_Store")

        #expect(changed != before)
        #expect(try SourceHash.compute(root: folder.url) == changed)
    }

    @Test("APP-05 the build stamp tells when the checkout changed")
    func stampTellsAChange() throws {
        let folder = try TemporaryFolder()
        try writeCheckout(in: folder)
        let hash = try SourceHash.compute(root: folder.url)
        let info: [String: Any] = [AppIdentity.sourceRootKey: folder.url.path(percentEncoded: false), AppIdentity.sourceHashKey: hash]
        let stamp = try #require(BuildStamp(infoDictionary: info))

        #expect(stamp.sourceHash == hash)
        #expect(!stamp.checkoutChanged())
        try folder.write("// changed", to: "Sources/MenubarCore/A.swift")
        #expect(stamp.checkoutChanged())

        #expect(BuildStamp(infoDictionary: [AppIdentity.sourceHashKey: hash]) == nil)
        #expect(BuildStamp(infoDictionary: nil) == nil)
        let gone = BuildStamp(sourceRoot: folder.file("gone"), sourceHash: hash)
        #expect(!gone.checkoutChanged())
    }

    private func writeCheckout(in folder: TemporaryFolder) throws {
        try folder.write("// swift-tools-version: 6.2", to: "Package.swift")
        try folder.write("#!/bin/bash", to: "build.sh")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.file("build.sh").path)
        try folder.write("// a", to: "Sources/MenubarCore/A.swift")
        try folder.write("// app", to: "Sources/MenubarMonitor/App.swift")
        try folder.write("png", to: "icons/menubar.png")
        try folder.write("{}", to: "icons/AppIcon.icon/icon.json")
    }

    /// Runs the `source_hash=$(…)` pipeline of `build.sh`, read from the script itself, in the checkout.
    private func buildScriptHash(of checkout: URL) async throws -> String {
        let script = try String(contentsOf: Self.repositoryRoot.appending(path: "build.sh"), encoding: .utf8)
        let match = try #require(script.firstMatch(of: /source_hash=\$\(([^)]*)\)/), "build.sh has no source_hash=$(…)")
        let pipeline = String(match.1)
        let output = try await SystemProcessRunner().run(
            URL(filePath: "/bin/bash"), arguments: ["-c", "cd \"$1\" && \(pipeline)", "bash", checkout.path(percentEncoded: false)], input: nil)
        try #require(output.status == 0, "\(String(decoding: output.standardError, as: UTF8.self))")
        return String(decoding: output.standardOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
