import Foundation
import Testing

@testable import MenubarCore

@Suite("AppIdentity")
struct AppIdentityTests {
    /// the SwiftPM product, which Package.swift names
    private static let packageProduct = "megamonitor"

    /// build.sh writes Info.plist by hand, so this keeps it in step with the names the app uses.
    @Test("build.sh stamps the bundle id, names, executable and URL scheme of AppIdentity")
    func buildScriptMatches() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = try String(contentsOf: root.appending(path: "build.sh"), encoding: .utf8)

        #expect(script.contains("<key>CFBundleIdentifier</key><string>\(AppIdentity.bundleID)</string>"))
        #expect(script.contains("<key>CFBundleExecutable</key><string>\(AppIdentity.displayName)</string>"))
        #expect(script.contains("<key>CFBundleName</key><string>\(AppIdentity.displayName)</string>"))
        #expect(script.contains("<key>CFBundleDisplayName</key><string>\(AppIdentity.displayName)</string>"))
        #expect(script.contains("build/app.noindex/\(AppIdentity.bundleFileName)"))
        let schemes = AppIdentity.urlSchemes.map { "<string>\($0)</string>" }.joined()
        #expect(script.contains("<key>CFBundleURLSchemes</key><array>\(schemes)</array>"))
        #expect(script.contains("--product \(Self.packageProduct)") && script.contains("$bin/\(Self.packageProduct)"))
        #expect(script.contains("<key>\(AppIdentity.sourceRootKey)</key>"))
        #expect(script.contains("<key>\(AppIdentity.sourceHashKey)</key>"))
    }

    /// install.sh and scripts/migrate-old-bundle.sh name the folders, the domains and the keychain services by hand.
    @Test("APP-10 install.sh and migrate-old-bundle.sh use the names of AppIdentity and its former identity")
    func scriptsMatch() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let install = try String(contentsOf: root.appending(path: "install.sh"), encoding: .utf8)
        let migrate = try String(contentsOf: root.appending(path: "scripts/migrate-old-bundle.sh"), encoding: .utf8)
        let package = try String(contentsOf: root.appending(path: "Package.swift"), encoding: .utf8)

        #expect(install.contains("new_id=\(AppIdentity.bundleID)\n"))
        #expect(install.contains("new_service=\(AppIdentity.keychainService)\n"))
        #expect(install.contains("former_id=\(AppIdentity.Former.bundleID)\n"))
        #expect(install.contains("former_service=\(AppIdentity.Former.keychainService)\n"))
        #expect(install.contains("Application Support/\(AppIdentity.name)/legacy-import.json"))
        #expect(install.contains("Library/Logs/\(AppIdentity.Former.name)\""))
        #expect(install.contains("identityMigration.filesDone") && IdentityMigration.filesDoneKey == "identityMigration.filesDone")
        #expect(migrate.contains("Application\\ Support/\(AppIdentity.name)\n"))
        #expect(migrate.contains(AppIdentity.Former.bundleID.replacingOccurrences(of: ".", with: "\\.")))
        #expect(package.contains(".executable(name: \"\(Self.packageProduct)\""))
    }
}
