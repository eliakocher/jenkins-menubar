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
    targets: [
        // Models, networking, storage, scheduling and the stores. Foundation, Network and Observation only: build.sh
        // refuses AppKit and SwiftUI here.
        .target(name: "MenubarCore"),
        // Every view, and the gallery catalog with its fixtures.
        .target(name: "MenubarUI", dependencies: ["MenubarCore"]),
        // The app: scenes, AppDelegate, the AppKit side of effects and system events, and --gallery in debug builds.
        .executableTarget(name: "MenubarMonitor", dependencies: ["MenubarCore", "MenubarUI"]),
        // In SwiftTests/, not Tests/: the file system ignores case, and tests/ still holds the old tool's bash tests,
        // which Phase 7 deletes. Then these can move to Tests/ and drop the path.
        .testTarget(name: "MenubarCoreTests", dependencies: ["MenubarCore"], path: "SwiftTests/MenubarCoreTests"),
        .testTarget(name: "MenubarUITests", dependencies: ["MenubarUI"], path: "SwiftTests/MenubarUITests"),
    ],
    swiftLanguageModes: [.v6]
)
