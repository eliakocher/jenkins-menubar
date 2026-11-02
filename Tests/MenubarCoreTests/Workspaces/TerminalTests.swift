import Foundation
import Testing

@testable import MenubarCore

/// Terminals that are "installed" for a test, and the one Launch Services opens `.command` files with.
struct FakeTerminals: TerminalDirectory {
    var apps: [TerminalApp]
    var handler: String?

    static let terminal = TerminalApp(
        id: "com.apple.Terminal", name: "Terminal", url: URL(filePath: "/System/Applications/Utilities/Terminal.app"),
        runsScripts: true, opensFolders: true)
    static let cmux = TerminalApp(
        id: "com.cmuxterm.app", name: "cmux", url: URL(filePath: "/Applications/cmux.app"), runsScripts: true,
        opensFolders: true)
    /// opens folders but declares no script type
    static let foldersOnly = TerminalApp(
        id: "dev.example.folders", name: "Folders", url: URL(filePath: "/Applications/Folders.app"), runsScripts: false,
        opensFolders: true)

    func app(bundleID: String) -> TerminalApp? {
        apps.first { $0.id == bundleID }
    }

    func scriptHandler() -> TerminalApp? {
        handler.flatMap(app(bundleID:))
    }
}

@Suite("Terminal choice")
struct TerminalTests {
    @Test("WS-05 the terminal is the chosen one, else the app that opens .command files, else Terminal with the reason")
    func choosesTheTerminal() {
        let both = FakeTerminals(apps: [FakeTerminals.terminal, FakeTerminals.cmux, FakeTerminals.foldersOnly], handler: "com.cmuxterm.app")

        // Default is the app that opens .command files.
        let standard = TerminalChoice.choose(preferred: nil, for: .script, in: both)
        #expect(standard.app.id == "com.cmuxterm.app")
        #expect(standard.note == nil)
        // A chosen terminal wins over the default.
        #expect(TerminalChoice.choose(preferred: "com.apple.Terminal", for: .folder, in: both).app.id == "com.apple.Terminal")
        // A chosen terminal that is gone: Terminal, and the reason.
        let gone = TerminalChoice.choose(preferred: "com.googlecode.iterm2", for: .folder, in: both)
        #expect(gone.app.id == "com.apple.Terminal")
        #expect(gone.note != nil)
        // One that opens folders but declares no script type: a folder goes to it, a script to Terminal.
        #expect(TerminalChoice.choose(preferred: "dev.example.folders", for: .folder, in: both).app.id == "dev.example.folders")
        let script = TerminalChoice.choose(preferred: "dev.example.folders", for: .script, in: both)
        #expect(script.app.id == "com.apple.Terminal")
        #expect(script.note != nil)
        // No default handler, or an editor as the handler: Terminal, with a reason only for the editor.
        let none = FakeTerminals(apps: [FakeTerminals.terminal], handler: nil)
        #expect(TerminalChoice.choose(preferred: nil, for: .script, in: none) == TerminalChoice(app: FakeTerminals.terminal, note: nil))
        let editor = FakeTerminals(apps: [FakeTerminals.terminal, FakeTerminals.foldersOnly], handler: "dev.example.folders")
        #expect(TerminalChoice.choose(preferred: nil, for: .script, in: editor).note != nil)
        // Terminal missing from the directory still works.
        #expect(TerminalChoice.choose(preferred: "gone", for: .folder, in: FakeTerminals(apps: [], handler: nil)).app.name == "Terminal")
    }

    @Test("WS-05 the open request is open -a with the app's path and the target as two arguments, never a shell string")
    func buildsTheOpenRequest() {
        let choice = TerminalChoice(app: FakeTerminals.cmux, note: nil)
        #expect(choice.openArguments(for: "/Users/jdoe/my work/develop3; rm -rf ~") == [
            "-a", "/Applications/cmux.app", "/Users/jdoe/my work/develop3; rm -rf ~",
        ])
    }

    @Test("WS-05 an app's Info.plist says whether it runs scripts and opens folders")
    func readsWhatAnAppOpens() {
        // What cmux declares: the shell script type with the Shell role, and folders.
        let cmux: [String: Any] = ["CFBundleDocumentTypes": [
            ["CFBundleTypeRole": "Viewer", "LSItemContentTypes": ["public.folder"]],
            ["CFBundleTypeRole": "Shell", "LSItemContentTypes": ["com.apple.terminal.shell-script"]],
        ]]
        let found = TerminalApp.capabilities(of: cmux, isKnown: true)
        #expect(found.runsScripts && found.opensFolders)
        // An editor that lists the script type edits it, so it isn't a terminal.
        let editor: [String: Any] = ["CFBundleDocumentTypes": [
            ["CFBundleTypeRole": "Editor", "LSItemContentTypes": ["public.shell-script"]],
        ]]
        #expect(!TerminalApp.capabilities(of: editor, isKnown: true).runsScripts)
        #expect(!TerminalApp.capabilities(of: editor, isKnown: false).runsScripts)
        // An unknown app needs the Shell role; a known terminal may declare the extension with another role.
        let viewer: [String: Any] = ["CFBundleDocumentTypes": [
            ["CFBundleTypeRole": "Viewer", "CFBundleTypeExtensions": ["command"]],
        ]]
        #expect(TerminalApp.capabilities(of: viewer, isKnown: true).runsScripts)
        #expect(!TerminalApp.capabilities(of: viewer, isKnown: false).runsScripts)
        let none = TerminalApp.capabilities(of: [:], isKnown: true)
        #expect(!none.runsScripts && !none.opensFolders)
    }
}
