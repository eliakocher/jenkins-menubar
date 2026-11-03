import MenubarCore
import SwiftUI

/// What the pane's footer shows of the fun layer: a line and the kind it is, as plain values.
struct FunFooterLine: Hashable, Sendable {
    var text: String
    var symbol: String
    /// the small title above a tip: "Butler's Tip"
    var title: String?

    init(_ line: FunModel.FooterLine) {
        text = line.text
        switch line.kind {
        case .tip:
            symbol = "lightbulb"
            title = "Butler's Tip"
        case .timer:
            symbol = "clock"
        case .surprise:
            // Sparkles mean Claude only in this app, whoever wrote the line: fun lines use the lightbulb of the tip.
            symbol = "lightbulb"
        }
    }

    init(text: String, symbol: String, title: String?) {
        self.text = text
        self.symbol = symbol
        self.title = title
    }
}

/// The pane's footer row of the fun layer, under Quit: the butler's tip of the day, or the line of the moment (lunch, the way
/// home, a fun fact). Quiet, secondary text in the footer's own symbol column, up to three lines. It isn't a command: a click
/// does nothing.
struct FunFooterRow: View {
    let line: FunFooterLine

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: line.symbol)
                .font(.system(size: 12))
                .foregroundStyle(.menuGrey)
                .frame(width: MenuMetrics.paneSymbol)
            VStack(alignment: .leading, spacing: 2) {
                if let title = line.title {
                    Text(verbatim: title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.menuGrey)
                }
                Text(verbatim: line.text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, MenuMetrics.padding + MenuMetrics.inset)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// The butler's tip under an empty state ("Nothing running", "Inbox Zero"), small and secondary, like a hint.
struct FunTipCaption: View {
    @Environment(AppModel.self) private var model: AppModel?

    var body: some View {
        if let tip = model?.fun.tip(at: .now) {
            Label {
                Text(verbatim: tip)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "lightbulb")
                    .foregroundStyle(.secondary)
            }
            .labelStyle(.titleAndIcon)
            .frame(maxWidth: 360)
            .padding(.top, 8)
            .accessibilityLabel("Butler's tip: \(tip)")
        }
    }
}
