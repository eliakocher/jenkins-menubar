import CoreServices
import Foundation
import Testing

@testable import MenubarCore

/// The pure parts of the update's hand-over: is the installed bundle really new, did the start after it run the new
/// build, and which file changes start a check.
@Suite("Installed update")
struct InstalledUpdateTests {
    private static let running = BuildStamp(sourceRoot: URL(filePath: "/checkout", directoryHint: .isDirectory), sourceHash: "old")

    private static func build(hash: String?) -> BundleBuild {
        BundleBuild(
            version: "1.0.7", buildNumber: "8",
            stamp: hash.map { BuildStamp(sourceRoot: URL(filePath: "/checkout", directoryHint: .isDirectory), sourceHash: $0) })
    }

    @Test(
        "APP-05 the installed bundle is checked before the relaunch",
        arguments: [
            // installed hash (nil: no stamp; "-": no bundle), the checkout's hash now, the verdict
            ("new", "new", InstalledCheck.current),
            ("new", nil, InstalledCheck.current),
            ("new", "newer", InstalledCheck.behindCheckout),
            ("old", "new", InstalledCheck.unchanged),
            (nil, "new", InstalledCheck.missing),
            ("-", "new", InstalledCheck.missing),
        ] as [(String?, String?, InstalledCheck)])
    func verify(installedHash: String?, checkoutHash: String?, verdict: InstalledCheck) {
        let installed = installedHash == "-" ? nil : Self.build(hash: installedHash)
        let result = InstalledCheck.verify(installed: installed, running: Self.running, checkoutHash: checkoutHash)
        #expect(result == verdict)
        #expect(result.isNew == (verdict == .current || verdict == .behindCheckout))
    }

    @Test("APP-05 the start after an update tells whether it took")
    func handoverOutcome() throws {
        let defaults = TemporaryDefaults()
        let installedAt = Date(timeIntervalSince1970: 1_000_000)
        let handover = UpdateHandover(
            installedApp: "/Users/someone/Applications/MegaMonitor.app", expectedHash: "new", previousHash: "old",
            previousVersion: "1.0.6 (7)", installedAt: installedAt)
        let stamp = { (hash: String) in BuildStamp(sourceRoot: URL(filePath: "/checkout"), sourceHash: hash) }

        #expect(handover.outcome(running: stamp("new")) == .updated)
        #expect(handover.outcome(running: stamp("old")) == .stillOld)
        #expect(handover.outcome(running: stamp("other")) == .other)

        handover.save(to: defaults.defaults)
        #expect(UpdateHandover.take(from: defaults.defaults, now: installedAt.addingTimeInterval(5)) == handover)
        #expect(UpdateHandover.take(from: defaults.defaults, now: installedAt) == nil, "taken once")

        handover.save(to: defaults.defaults)
        let late = installedAt.addingTimeInterval(UpdateHandover.maxAge + 1)
        #expect(UpdateHandover.take(from: defaults.defaults, now: late) == nil, "too old to be the relaunch")
        #expect(defaults.defaults.data(forKey: UpdateHandover.defaultsKey) == nil)
    }

    @Test(
        "APP-05 the installed path has one form, without a final slash",
        arguments: [
            ("/Users/someone/Applications/MegaMonitor.app/", "/Users/someone/Applications/MegaMonitor.app"),
            ("/Users/someone/Applications/MegaMonitor.app", "/Users/someone/Applications/MegaMonitor.app"),
            ("/Users/a b/Apps+x/MegaMonitor.app/", "/Users/a b/Apps+x/MegaMonitor.app"),
            ("/", "/"),
        ])
    func plainPath(input: String, expected: String) {
        #expect(BundleBuild.plainPath(URL(filePath: input)) == expected)
        #expect(BundleBuild.plainPath(URL(filePath: input, directoryHint: .isDirectory)) == expected)
        // An app's path never ends in a slash, so its executable's path has no "//" (the root itself is no app).
        if expected != "/" {
            #expect(!(BundleBuild.plainPath(URL(filePath: input)) + "/Contents/MacOS/").contains("//"))
        }
    }

    @Test("APP-05 reads the build of a bundle on disk")
    func readsBundle() throws {
        let folder = try TemporaryFolder()
        let app = folder.file("MegaMonitor.app")
        #expect(BundleBuild.read(bundle: app) == nil)
        let info: [String: Any] = [
            "CFBundleExecutable": "MegaMonitor", "CFBundleShortVersionString": "1.0.7", "CFBundleVersion": "8",
            AppIdentity.sourceRootKey: "/checkout", AppIdentity.sourceHashKey: "abcdef0123456789",
        ]
        try folder.write(
            String(decoding: try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0), as: UTF8.self),
            to: "MegaMonitor.app/Contents/Info.plist")
        #expect(BundleBuild.read(bundle: app) == nil, "no executable")
        let executable = try folder.write("#!/bin/sh", to: "MegaMonitor.app/Contents/MacOS/MegaMonitor")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path(percentEncoded: false))

        let build = try #require(BundleBuild.read(bundle: app))
        #expect(build.versionLine == "1.0.7 (8)")
        #expect(build.shortHash == "abcdef012345")
        #expect(build.stamp?.sourceHash == "abcdef0123456789")
    }

    @Test(
        "APP-05 only changes of hashed files start a check",
        arguments: [
            ("/repo/Sources/MenubarCore/A.swift", 0, true),
            ("/repo/CHANGELOG.md", 0, true),
            ("/repo/build.sh", 0, true),
            ("/repo/Tests/MenubarCoreTests/ATests.swift", 0, false),
            ("/repo/README.md", 0, false),
            ("/repo/.git/HEAD", 0, false),
            ("/repo/.build/release/megamonitor", 0, false),
            ("/repo/build/app.noindex/MegaMonitor.app/Contents/Info.plist", 0, false),
            ("/repository/Sources/A.swift", 0, false),
            ("/repo/.git/index", kFSEventStreamEventFlagMustScanSubDirs, true),
            ("/repo/.git/index", kFSEventStreamEventFlagKernelDropped, true),
            ("/repo", kFSEventStreamEventFlagRootChanged, true),
        ])
    func relevantEvents(path: String, flags: Int, relevant: Bool) {
        #expect(CheckoutWatcher.isRelevant(path: path, flags: FSEventStreamEventFlags(flags), root: "/repo") == relevant)
    }
}
