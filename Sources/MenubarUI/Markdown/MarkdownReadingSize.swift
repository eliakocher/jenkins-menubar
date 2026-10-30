import SwiftUI

/// The app-wide reading size of rendered Markdown (WIN-02): a few steps from 0.85× to 2× of the base size, remembered
/// across launches under ``key`` in the preferences. The View menu and the description's A−/A+ buttons move it.
enum MarkdownReadingSize {
    /// the preferences key of the step's index
    static let key = "markdown.readingSizeStep"

    /// the sizes the steps stand for; the default is the entry at ``defaultStep``
    static let scales: [CGFloat] = [0.85, 1, 1.15, 1.3, 1.5, 1.75, 2]
    static let defaultStep = 1

    /// the step moved by `change` (−1 smaller, +1 bigger, 0 back to the default), kept inside the steps; a stored value
    /// outside them counts as the nearest step first
    static func step(_ step: Int, changedBy change: Int) -> Int {
        change == 0 ? defaultStep : clamped(clamped(step) + change)
    }

    static func clamped(_ step: Int) -> Int {
        min(max(step, 0), scales.count - 1)
    }

    static func scale(forStep step: Int) -> CGFloat {
        scales[clamped(step)]
    }

    static func canGrow(from step: Int) -> Bool { clamped(step) < scales.count - 1 }
    static func canShrink(from step: Int) -> Bool { clamped(step) > 0 }
    static func isDefault(_ step: Int) -> Bool { clamped(step) == defaultStep }
}

private struct MarkdownScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    /// the factor the Markdown drawn below uses on its type, spacing and fixed sizes
    var markdownScale: CGFloat {
        get { self[MarkdownScaleKey.self] }
        set { self[MarkdownScaleKey.self] = newValue }
    }
}

/// One clear control for the reading size in the header of a description: a `textformat.size` button whose menu makes
/// the text bigger or smaller or back to the actual size, with the same steps as View › Make Text Bigger and Smaller;
/// ⌘0 in the View menu resets too.
struct MarkdownSizeButtons: View {
    @AppStorage(MarkdownReadingSize.key) private var step = MarkdownReadingSize.defaultStep

    var body: some View {
        Menu {
            Button("Make Text Bigger", systemImage: "textformat.size.larger") {
                step = MarkdownReadingSize.step(step, changedBy: 1)
            }
            .disabled(!MarkdownReadingSize.canGrow(from: step))
            Button("Make Text Smaller", systemImage: "textformat.size.smaller") {
                step = MarkdownReadingSize.step(step, changedBy: -1)
            }
            .disabled(!MarkdownReadingSize.canShrink(from: step))
            Divider()
            Button("Actual Size") {
                step = MarkdownReadingSize.step(step, changedBy: 0)
            }
            .disabled(MarkdownReadingSize.isDefault(step))
        } label: {
            Image(systemName: "textformat.size")
                .imageScale(.medium)
                .frame(width: 24, height: 20)
                .contentShape(.rect)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(.secondary)
        .help("Text Size")
        .accessibilityLabel("Text Size")
    }
}
