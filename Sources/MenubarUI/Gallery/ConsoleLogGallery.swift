#if DEBUG
import MenubarCore
import SwiftUI

/// The build detail's Console Log card (PIPE-12) on a detail page's ground, with a made-up log in memory.
struct ConsoleLogGalleryView: View {
    var stored: Data?
    var isRunning = false
    var startsOpen = true
    var size: CGSize

    var body: some View {
        let stored = stored ?? Data()
        let isRunning = isRunning
        let fake = ConsoleLogFake(stored: stored, isRunning: isRunning)
        VStack(alignment: .leading, spacing: 0) {
            ConsoleLogCard(
                build: BuildID(job: "MR-12", number: 7),
                consoleURL: URL(string: "https://jenkins.example.com/job/project/job/MR-12/7/console"), open: { _ in })
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(
            \.consoleLogFixture,
            ConsoleLogFixture(source: fake.source, startsOpen: startsOpen) { loader in
                loader.preload(stored: stored, isRunning: isRunning)
            })
    }
}

extension GalleryCatalog {
    static var consoleLogEntries: [GalleryEntry] {
        let size = CGSize(width: 980, height: 640)
        return [
            GalleryEntry(screen: "console-log", state: "collapsed", size: CGSize(width: 980, height: 160)) { _ in
                ConsoleLogGalleryView(stored: ConsoleLogFake.pipelineLog(lines: 400), startsOpen: false, size: CGSize(width: 980, height: 160))
            },
            GalleryEntry(screen: "console-log", state: "open", size: size) { _ in
                ConsoleLogGalleryView(stored: ConsoleLogFake.pipelineLog(lines: 20_000), size: size)
            },
            GalleryEntry(screen: "console-log", state: "running", size: size) { _ in
                ConsoleLogGalleryView(stored: ConsoleLogFake.pipelineLog(lines: 300), isRunning: true, size: size)
            },
            GalleryEntry(screen: "console-log", state: "narrow", size: CGSize(width: 560, height: 640)) { _ in
                ConsoleLogGalleryView(stored: ConsoleLogFake.pipelineLog(lines: 2_000), size: CGSize(width: 560, height: 640))
            },
        ]
    }
}
#endif
