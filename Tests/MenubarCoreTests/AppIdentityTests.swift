import Foundation
import Testing

@testable import MenubarCore

@Suite("AppIdentity")
struct AppIdentityTests {
    /// build.sh writes Info.plist by hand, so this keeps it in step with the names the app uses.
    @Test("build.sh stamps the bundle id, executable and URL scheme of AppIdentity")
    func buildScriptMatches() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = try String(contentsOf: root.appending(path: "build.sh"), encoding: .utf8)

        #expect(script.contains("<key>CFBundleIdentifier</key><string>\(AppIdentity.bundleID)</string>"))
        #expect(script.contains("<key>CFBundleExecutable</key><string>\(AppIdentity.name)</string>"))
        #expect(script.contains("<array><string>\(AppIdentity.urlScheme)</string></array>"))
        #expect(script.contains("<key>\(AppIdentity.sourceRootKey)</key>"))
        #expect(script.contains("<key>\(AppIdentity.sourceHashKey)</key>"))
    }
}
