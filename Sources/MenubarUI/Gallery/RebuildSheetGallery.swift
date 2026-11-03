#if DEBUG
import MenubarCore
import SwiftUI

extension GalleryCatalog {
    /// The "Rebuild with Changes…" sheet (PIPE-09): its parameters by type, loading, and a failure.
    static var rebuildSheetEntries: [GalleryEntry] {
        let size = CGSize(width: RebuildSheet.width, height: 560)
        let definitions = [
            ParameterDefinition(name: "TARGET_BRANCH", kind: .string, defaultValue: "main", details: "The branch to build"),
            ParameterDefinition(name: "SKIP_UI_TESTS", kind: .boolean, defaultValue: "false"),
            ParameterDefinition(name: "ENVIRONMENT", kind: .choice, choices: ["staging", "qa", "production"], defaultValue: "staging"),
            ParameterDefinition(name: "NOTES", kind: .text, details: "Shown in the build's description"),
            ParameterDefinition(name: "DEPLOY_PASSWORD", kind: .password),
            ParameterDefinition(name: "UPSTREAM", kind: .unsupported),
        ]
        let original = [
            BuildParameter(name: "TARGET_BRANCH", value: "release/8.x"), BuildParameter(name: "SKIP_UI_TESTS", value: "true"),
            BuildParameter(name: "ENVIRONMENT", value: "qa"), BuildParameter(name: "NOTES", value: "Retry after the flaky run"),
        ]
        return [
            GalleryEntry(screen: "rebuild-sheet", state: "ready", size: size) { _ in
                RebuildSheet(
                    build: "!1 #7", form: RebuildForm(definitions: definitions, original: original),
                    load: { .failure(.jobGone) }, rebuild: { _ in }, close: {})
            },
            GalleryEntry(screen: "rebuild-sheet", state: "loading", size: CGSize(width: RebuildSheet.width, height: 300)) { _ in
                RebuildSheet(
                    build: "!1 #7",
                    load: {
                        try? await Task.sleep(for: .seconds(3600))
                        return .failure(.jobGone)
                    }, rebuild: { _ in }, close: {})
            },
            GalleryEntry(screen: "rebuild-sheet", state: "failed", size: CGSize(width: RebuildSheet.width, height: 220)) { _ in
                RebuildSheet(
                    build: "!1 #7", load: { .failure(.noBuildPermission) }, rebuild: { _ in }, close: {})
            },
        ]
    }
}
#endif
