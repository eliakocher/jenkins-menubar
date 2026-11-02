import SwiftUI

/// The strip over a side detail pane, as the Slots detail has it: the item's short name at the start, optional buttons,
/// and the ✕ that closes the pane (the user, 2026-11-02: "add an x button to close it"). 30 pt high; put a `Divider`
/// under it, or use ``DetailPane``.
struct DetailPaneStrip<Accessory: View>: View {
    /// what the strip names, like "#31" or "GitLab · 10:41:07"
    let title: String
    let close: () -> Void
    /// buttons before the ✕, such as "Open in a Tab"
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: title)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            accessory
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close the detail")
            .accessibilityLabel("Close Detail")
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
    }
}

/// A side detail pane with its ``DetailPaneStrip``, a divider and the content; Esc closes it.
struct DetailPane<Content: View, Accessory: View>: View {
    let title: String
    let close: () -> Void
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            DetailPaneStrip(title: title, close: close) { accessory }
            Divider()
            content
                .frame(minHeight: 0, maxHeight: .infinity)
        }
        .onExitCommand(perform: close)
    }
}

extension DetailPane where Accessory == EmptyView {
    init(title: String, close: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.init(title: title, close: close, accessory: { EmptyView() }, content: content)
    }
}
