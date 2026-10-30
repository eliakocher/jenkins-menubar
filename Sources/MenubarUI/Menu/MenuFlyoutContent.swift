import AppKit
import MenubarCore
import SwiftUI

/// What the flyout's rows do: the pointer on a row, a click on a row, and the context menus' actions. The gallery
/// passes ``none``.
struct MenuFlyoutActions {
    /// the pointer moved over a row, by its index in `MenuFlyout.items`
    var hover: @MainActor (Int?) -> Void = { _ in }
    /// the pointer entered or left the flyout
    var inside: @MainActor (Bool) -> Void = { _ in }
    /// a click on a row, or Return on it
    var activate: @MainActor (MenuFlyout.Item) -> Void = { _ in }
    /// the builds' context menu (`BuildRowMenu`) and the links: opening a page closes the pane
    var panel = PanelActions.none
    /// "Show in Window": the main window's section with the entry selected
    var showInWindow: @MainActor (MenuSelection) -> Void = { _ in }

    static var none: MenuFlyoutActions { MenuFlyoutActions() }
}

/// An area's flyout drawn from plain values (`docs/design/panel.md`): the window's sections under native section
/// headers, one rich row per entry, a note or placeholders instead when there are none, then the commands. The
/// highlight is an index into `MenuFlyout.items`, which the pointer and the keys move.
struct MenuFlyoutContent: View {
    let flyout: MenuFlyout
    var highlight: Int?
    var actions = MenuFlyoutActions.none

    var body: some View {
        let indices = Dictionary(uniqueKeysWithValues: flyout.items.enumerated().map { ($1, $0) })
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(flyout.sections.enumerated()), id: \.element.id) { offset, section in
                header(section, isFirst: offset == 0)
                ForEach(section.entries) { entry in
                    let index = indices[.entry(entry.id)]
                    MenuEntryRow(
                        entry: entry, isHighlighted: index != nil && index == highlight,
                        showsSymbolColumn: flyout.hasSymbolColumn)
                        .flyoutRow(index: index, item: .entry(entry.id), actions: actions)
                        .contextMenu { entryMenu(entry) }
                        .id(MenuFlyout.Item.entry(entry.id))
                }
            }
            if flyout.isPlaceholder {
                MenuPlaceholderRows()
            }
            if let note = flyout.note {
                noteRow(note)
            }
            if !flyout.commands.isEmpty {
                MenuSeparator()
                ForEach(flyout.commands) { command in
                    let index = indices[.command(command)]
                    commandRow(command, isHighlighted: index != nil && index == highlight)
                        .flyoutRow(index: index, item: .command(command), actions: actions)
                        .id(MenuFlyout.Item.command(command))
                }
            }
        }
        .padding(.vertical, MenuMetrics.edge)
        .frame(width: MenuMetrics.flyoutWidth)
        .fixedSize(horizontal: false, vertical: true)
        // The first row's top lines up with the open area's row, as a native submenu's first item with its item.
        .alignmentGuide(.menuFlyoutTop) { $0[.top] + MenuMetrics.edge }
        .background { MenuBackdropTint(shape: RoundedRectangle(cornerRadius: MenuMetrics.flyoutCorner, style: .continuous)) }
        .onHover { actions.inside($0) }
    }

    /// A native section header: the title in small bold grey, the count after it.
    private func header(_ section: MenuFlyout.Section, isFirst: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(verbatim: section.title)
                .fontWeight(.semibold)
                .foregroundStyle(.menuGrey)
            Text(verbatim: section.count)
                .monospacedDigit()
                .foregroundStyle(.menuHint)
            Spacer(minLength: 0)
        }
        .font(.subheadline)
        .padding(.horizontal, MenuMetrics.inset + MenuMetrics.padding)
        .padding(.top, isFirst ? 3 : 9)
        .padding(.bottom, 3)
        .accessibilityAddTraits(.isHeader)
    }

    private func noteRow(_ note: String) -> some View {
        Text(verbatim: note)
            .foregroundStyle(.menuGrey)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, MenuMetrics.inset + MenuMetrics.padding)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func commandRow(_ command: MenuFlyout.Command, isHighlighted: Bool) -> some View {
        HStack(spacing: 7) {
            Image(systemName: Self.symbol(of: command))
                .foregroundStyle(isHighlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.menuGrey))
                .frame(width: MenuMetrics.symbolColumn)
            Text(verbatim: command.title)
            Spacer(minLength: 0)
            if command == .watchBuild {
                MenuSecondaryText("⌘L", isHint: true)
            }
        }
        .menuRow(isHighlighted: isHighlighted, corner: MenuMetrics.flyoutCorner - MenuMetrics.inset)
    }

    private static func symbol(of command: MenuFlyout.Command) -> String {
        switch command {
        case .showInWindow: "macwindow"
        case .watchBuild: "eye"
        case .showHidden: "eye.slash"
        case .link: "arrow.up.forward.app"
        case .settings: "gearshape"
        }
    }

    /// The entry's context menu: a build's own menu (PIPE-03, PIPE-09, HIDE-01), or Open, Show in Window and Copy Link.
    @ViewBuilder private func entryMenu(_ entry: MenuEntry) -> some View {
        switch entry.kind {
        case .build(let row):
            BuildRowMenu(model: row, actions: actions.panel)
            Divider()
            Button("Show in Window") { actions.showInWindow(entry.selection) }
        case .mergeRequest, .workItem:
            Button("Show in Window") { actions.showInWindow(entry.selection) }
            if let url = entry.url {
                Button(entry.openTitle) { actions.panel.open(url) }
            }
            if let url = entry.url {
                Divider()
                Button("Copy Link") { actions.panel.copy(url) }
            }
        }
    }
}

/// An entry's row: the colored status symbol, the title cut by width (its tooltip the whole title), the grey line with
/// a work item's slot pill before it or a failed rebuild after the red marker, and a running build's thin progress bar.
struct MenuEntryRow: View {
    let entry: MenuEntry
    let isHighlighted: Bool
    /// whether the flyout keeps a symbol column: when any of its entries has a symbol; without, the text starts at the
    /// row's edge, under the section headers (the user, 2026-10-29)
    var showsSymbolColumn = true

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            if showsSymbolColumn {
                Group {
                    if let symbol = entry.symbol {
                        MenuSymbol(name: symbol, tint: entry.tint)
                    } else {
                        // The empty column keeps the titles lined up with the marked rows, as a native menu's.
                        Text(verbatim: " ")
                    }
                }
                .frame(width: MenuMetrics.symbolColumn)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: entry.title)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    // The checkout the build or branch lives in (WS-07); the row itself is the click target.
                    switch entry.kind {
                    case .build(let row): WorkspaceTag(subject: .build(row.build))
                    case .mergeRequest(let row): WorkspaceTag(subject: .mergeRequest(row.mergeRequest))
                    case .workItem: EmptyView()
                    }
                }
                HStack(spacing: 5) {
                    if let pill = entry.pill {
                        LabelPill(label: pill, style: .compact)
                            .fixedSize()
                    }
                    MenuSecondaryText(entry.subtitle)
                        .lineLimit(1)
                }
                .font(.subheadline)
                if let problem = entry.problem {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        ProblemSymbol()
                        Text(verbatim: problem)
                            .lineLimit(2)
                    }
                    .font(.subheadline)
                }
                if let progress = entry.progress {
                    MenuProgressBar(progress: progress)
                        .padding(.top, 3)
                        .padding(.bottom, 1)
                }
            }
        }
        .padding(.vertical, 2)
        .menuRow(isHighlighted: isHighlighted, corner: MenuMetrics.flyoutCorner - MenuMetrics.inset)
        .help(entry.url == nil ? entry.title : "\(entry.title)\n⌥-click to open in the browser")
        .accessibilityElement(children: .combine)
    }
}

/// Rows of bars standing in for a list that never loaded (OD-01), in the flyout rows' size.
struct MenuPlaceholderRows: View {
    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<4, id: \.self) { index in
                SkeletonRow(index: index, leading: .symbol(column: MenuMetrics.symbolColumn), spacing: 7)
                    .padding(.vertical, 2)
                    .menuRow(isHighlighted: false)
            }
        }
    }
}

extension View {
    /// Makes a view a flyout row: a button for clicks and VoiceOver, which reports the pointer on it.
    fileprivate func flyoutRow(index: Int?, item: MenuFlyout.Item, actions: MenuFlyoutActions) -> some View {
        Button {
            actions.activate(item)
        } label: {
            self
        }
        .buttonStyle(MenuRowButtonStyle())
        .onContinuousHover { phase in
            if case .active = phase {
                actions.hover(index)
            }
        }
    }
}
