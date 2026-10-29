import AppKit
import MenubarCore
import SwiftUI

/// A GitLab label as the GitLab pane's filter lists show it (WI-06, `docs/design/settings-gitlab.md`, Pills): GitLab's
/// color, a scoped label with its scope filled in and its value on the row's background, a hairline in the separator
/// color, one line truncated in the middle with the value giving way last. A gone label gets the red problem symbol
/// before it. The title is always plain text (WI-04). Its one tooltip is the full title while the pill is cut, and
/// `help` otherwise (review SETTINGS-03: nested tooltips hide the outer one).
struct FilterLabelPill: View {
    let title: String
    /// GitLab's color, like `#428BCA`; nil when unknown
    let color: String?
    var isGone = false
    /// the tooltip while the title shows whole, like "Remove from the filter"
    var help = ""
    @ViewState private var isCut = false

    var body: some View {
        HStack(spacing: 3) {
            if isGone {
                Image(systemName: StatusKind.problem.symbol)
                    .foregroundStyle(StatusKind.problem.color)
            }
            LabelCapsule(title: title, color: color)
                .readsTruncation($isCut)
        }
        .font(.subheadline)
        .help(isCut ? title : help)
    }
}

/// The capsule of a label: filled with its color, or for a scoped label only its scope.
private struct LabelCapsule: View {
    let title: String
    let color: String?

    var body: some View {
        if let parts = MenubarCore.Label.scopeAndValue(of: title) {
            HStack(spacing: 0) {
                Text(verbatim: parts.scope)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.leading, 7)
                    .padding(.trailing, 5)
                    .foregroundStyle(LabelColors.text(on: color))
                    .background(LabelColors.fill(color))
                Text(verbatim: parts.value)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.leading, 5)
                    .padding(.trailing, 7)
                    .layoutPriority(1)
            }
            .padding(.vertical, 1)
            .clipShape(Capsule())
            .overlay {
                Capsule().strokeBorder(LabelColors.fill(color), lineWidth: 1)
            }
            .overlay {
                Capsule().strokeBorder(.separator, lineWidth: 0.5)
            }
        } else {
            Text(verbatim: title)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 7)
                .padding(.vertical, 1)
                .foregroundStyle(LabelColors.text(on: color))
                .background(Capsule().fill(LabelColors.fill(color)))
                .overlay {
                    Capsule().strokeBorder(.separator, lineWidth: 0.5)
                }
        }
    }
}

/// Where a label stands in the picker of one list.
enum LabelChipState: Hashable {
    /// in neither list
    case unused
    /// in the picker's own list: filled, with the list's symbol
    case inThisList(WorkItemFilters.LabelList)
    /// in the other list: outlined, with that list's symbol; a click moves it over
    case inOtherList(WorkItemFilters.LabelList)

    /// Returns where a label stands for the picker of a list.
    static func of(_ label: String, list: WorkItemFilters.LabelList, filters: WorkItemFilters) -> LabelChipState {
        let lists: [WorkItemFilters.LabelList: [String]] = [.with: filters.withLabels, .without: filters.withoutLabels]
        if lists[list]?.contains(label) == true {
            return .inThisList(list)
        }
        let other: WorkItemFilters.LabelList = list == .with ? .without : .with
        return lists[other]?.contains(label) == true ? .inOtherList(other) : .unused
    }
}

extension WorkItemFilters.LabelList {
    /// `checkmark` for Must Have, `nosign` for Must Have None of These (WI-06)
    var symbol: String {
        self == .with ? "checkmark" : "nosign"
    }
}

/// A label in the picker: a button in the label's color. Inside a scope group it shows the value only.
struct LabelChip: View {
    let title: String
    /// what the chip shows: the value inside a scope group, the whole title otherwise
    let text: String
    let color: String?
    let state: LabelChipState
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if let symbol {
                    Image(systemName: symbol)
                        .imageScale(.small)
                }
                Text(verbatim: text)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.subheadline)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .foregroundStyle(isFilled ? LabelColors.text(on: color) : AnyShapeStyle(.primary))
            .background {
                if isFilled {
                    Capsule().fill(LabelColors.fill(color))
                }
            }
            .overlay {
                if !isFilled {
                    Capsule().strokeBorder(LabelColors.fill(color), lineWidth: 1)
                }
            }
            .overlay {
                // As the pills have it: a white or a black label keeps an edge on any background (SETTINGS-GITLAB-01).
                Capsule().strokeBorder(.separator, lineWidth: 0.5)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var isFilled: Bool {
        if case .inThisList = state { true } else { false }
    }

    private var symbol: String? {
        switch state {
        case .unused: nil
        case .inThisList(let list), .inOtherList(let list): list.symbol
        }
    }

    private var help: String {
        switch state {
        case .unused: "Click to add it"
        case .inThisList: "Click to remove it"
        case .inOtherList(let list): "In \(SettingsOptionTitles.labelList(list)): click to move it here"
        }
    }
}

/// GitLab's label colors in SwiftUI (WI-06).
enum LabelColors {
    /// the label's color; the system's secondary fill when GitLab gave none
    static func fill(_ hex: String?) -> AnyShapeStyle {
        guard let hex, MenubarCore.Label.textColor(onBackground: hex) != nil else {
            return AnyShapeStyle(.fill.secondary)
        }
        return AnyShapeStyle(Color(nsColor: NSColor(hex: hex)))
    }

    /// black or white on the label's color by WI-06's rule; the label color without a known color
    static func text(on hex: String?) -> AnyShapeStyle {
        guard let hex, let text = MenubarCore.Label.textColor(onBackground: hex) else {
            return AnyShapeStyle(.primary)
        }
        return AnyShapeStyle(Color(nsColor: NSColor(hex: text)))
    }
}
