import SwiftUI

/// The action row under a detail's header: every frequent action as a bordered button, wrapping when narrow (the user,
/// 2026-10-30: "represent them directly in the view, so they're not hidden behind a menu"). The build, merge request and
/// work item details fill it with ``DetailActionButton`` and ``CopyLinkButton``; the header's ⋯ menu keeps only the rare
/// actions, or goes away when nothing is left.
struct DetailActionRow<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        PillFlowLayout(spacing: 8, lineSpacing: 8) {
            content
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One button of a ``DetailActionRow``: a symbol and a title, with a tooltip.
struct DetailActionButton: View {
    let title: String
    let symbol: String
    let help: String
    let action: () -> Void

    /// - Parameters:
    ///   - title: the button's words
    ///   - symbol: the SF Symbol before them
    ///   - help: the tooltip
    ///   - action: what it does
    init(_ title: String, _ symbol: String, help: String, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.help = help
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
        }
        .help(help)
    }
}

/// "Copy Link" as a button of a ``DetailActionRow``: it says "Copied" with a check for a moment after the click.
struct CopyLinkButton: View {
    let help: String
    let copy: () -> Void

    @ViewState private var copied = false

    /// - Parameters:
    ///   - help: the tooltip, naming what the link leads to
    ///   - copy: puts the link on the clipboard
    init(help: String, copy: @escaping () -> Void) {
        self.help = help
        self.copy = copy
    }

    var body: some View {
        DetailActionButton(copied ? "Copied" : "Copy Link", copied ? "checkmark" : "link", help: help) {
            copy()
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        }
    }
}
