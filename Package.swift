// swift-tools-version: 6.2
// Builds with only the Command Line Tools: build.sh bundles the app, test.sh runs the tests. Developers with Xcode can
// open this file instead of a project.
import PackageDescription

let package = Package(
    name: "menubar-monitor",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "menubar-monitor", targets: ["MenubarMonitor"]),
    ],
    dependencies: [
        // The Markdown parser of the descriptions (WIN-02): cmark-gfm's tree, which MenubarUI draws with its own views.
        // Apache 2.0; no macros or build plugins, so it builds with only the Command Line Tools (docs/decisions.md).
        .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.9.0"),
    ],
    targets: [
        // Models, networking, storage, scheduling and the stores. Foundation, Network and Observation only: build.sh
        // refuses AppKit and SwiftUI here.
        .target(name: "MenubarCore"),
        // Every view, and the gallery catalog with its fixtures.
        .target(name: "MenubarUI", dependencies: ["MenubarCore", .product(name: "Markdown", package: "swift-markdown")]),
        // The app: scenes, AppDelegate, the AppKit side of effects and system events, and --gallery in debug builds.
        .executableTarget(name: "MenubarMonitor", dependencies: ["MenubarCore", "MenubarUI"]),
        .testTarget(name: "MenubarCoreTests", dependencies: ["MenubarCore"]),
        .testTarget(name: "MenubarUITests", dependencies: ["MenubarUI"]),
    ],
    swiftLanguageModes: [.v6]
)
