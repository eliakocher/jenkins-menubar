import Foundation
import Testing

@testable import MenubarCore

@Suite("PersonalSettingsBackup")
struct PersonalSettingsBackupTests {
    /// a value of the type the entry expects, different per key
    private func sample(_ entry: PersonalSettingsBackup.Entry) -> Any {
        switch entry.type {
        case .bool: true
        case .int: 42
        case .double: 1234.5
        case .string: "value of \(entry.key)"
        case .strings: ["one", "two \(entry.key)"]
        case .data: Data("data of \(entry.key)".utf8)
        }
    }

    private func file(kind: String, version: Int) throws -> Data {
        let file: [String: Any] = [
            "formatVersion": version, "kind": kind, "exportedAt": "2026-11-02T10:00:00Z",
            "values": ["showInMenuBar": false],
        ]
        return try JSONSerialization.data(withJSONObject: file)
    }

    @Test("SET-01: a backup round-trips every allowlisted key and nothing else, and refuses a wrong or newer file")
    func roundTrip() throws {
        let source = TemporaryDefaults()
        for entry in PersonalSettingsBackup.allowlist {
            source.defaults.set(sample(entry), forKey: entry.key)
        }
        source.defaults.set("glpat-secret", forKey: "gitlabToken")
        source.defaults.set(Data("opened".utf8), forKey: "openedItems")
        let data = try PersonalSettingsBackup.export(from: source.defaults)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("glpat-secret"))
        #expect(!text.contains("gitlabToken"))
        #expect(!text.contains("openedItems"))

        // A planted key in the file is ignored, and so is a value of the wrong type.
        var file = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var values = try #require(file["values"] as? [String: Any])
        values["gitlabToken"] = "planted"
        values["openedItems"] = ["planted"]
        values["showInMenuBar"] = "not a bool"
        file["values"] = values
        let planted = try JSONSerialization.data(withJSONObject: file)

        let target = TemporaryDefaults()
        let result = try PersonalSettingsBackup.importValues(from: planted, into: target.defaults)
        #expect(target.defaults.object(forKey: "gitlabToken") == nil)
        #expect(target.defaults.object(forKey: "openedItems") == nil)
        #expect(target.defaults.object(forKey: "showInMenuBar") == nil)
        #expect(result.count == PersonalSettingsBackup.allowlist.count - 1)
        for entry in PersonalSettingsBackup.allowlist where entry.key != "showInMenuBar" {
            switch entry.type {
            case .bool: #expect(target.defaults.object(forKey: entry.key) as? Bool == true, "\(entry.key)")
            case .int: #expect(target.defaults.object(forKey: entry.key) as? Int == 42, "\(entry.key)")
            case .double: #expect(target.defaults.object(forKey: entry.key) as? Double == 1234.5, "\(entry.key)")
            case .string:
                #expect(target.defaults.string(forKey: entry.key) == "value of \(entry.key)", "\(entry.key)")
            case .strings:
                #expect(target.defaults.stringArray(forKey: entry.key) == ["one", "two \(entry.key)"], "\(entry.key)")
            case .data:
                #expect(target.defaults.data(forKey: entry.key) == Data("data of \(entry.key)".utf8), "\(entry.key)")
            }
        }

        let refused = TemporaryDefaults()
        #expect(throws: PersonalSettingsBackupError.notABackup) {
            try PersonalSettingsBackup.importValues(
                from: try self.file(kind: "megamonitor-team", version: 1), into: refused.defaults)
        }
        #expect(throws: PersonalSettingsBackupError.newerFormat(2)) {
            try PersonalSettingsBackup.importValues(
                from: try self.file(kind: PersonalSettingsBackup.kind, version: 2), into: refused.defaults)
        }
        #expect(refused.defaults.object(forKey: "showInMenuBar") == nil)
    }
}
