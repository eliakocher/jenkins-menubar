import AppKit
import MenubarCore
import SwiftUI

/// The alert window's content (Task 4.5, `docs/design/alert.md`): the happy or sad butler, the headline with the
/// result's SF Symbol, the title, the facts, and the buttons, the default one on top (ALERT-02, ALERT-03).
///
/// `NativeEffects` hosts it in a non-activating panel that never takes the keyboard by itself; once a click makes the
/// panel key, Return presses the default button and Esc presses Dismiss. A live alert keeps Open Console and Hide Until
/// the Next Build in a More menu above Dismiss. 320 pt wide; the height fits the content.
public struct BuildAlertView: View {
    let alert: BuildAlert
    let notificationsOff: Bool
    let perform: (AlertContent.Action) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    /// the alert's fixed width
    public static let width: CGFloat = 320

    /// - Parameters:
    ///   - alert: the alert
    ///   - notificationsOff: whether it shows as a window because its banner couldn't (ALERT-03)
    ///   - perform: runs a button's action; the panel opens its link and closes
    public init(alert: BuildAlert, notificationsOff: Bool, perform: @escaping (AlertContent.Action) -> Void) {
        self.alert = alert
        self.notificationsOff = notificationsOff
        self.perform = perform
    }

    public var body: some View {
        let content = alert.content
        VStack(spacing: 0) {
            Image(nsImage: AppImages.alert(content.icon, hat: content.hat))
                .resizable()
                .frame(width: 96, height: 96)
            if let project = content.project {
                // With several projects, which one the build is of (plan Phase 13).
                Text(verbatim: project)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 12)
            }
            headline(content)
                .font(.title3)
                .bold()
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, content.project == nil ? 12 : 2)
            if let title = content.title {
                Text(verbatim: title)
                    .lineLimit(lineLimit)
                    .help(title)
                    .padding(.top, 4)
            }
            VStack(spacing: 0) {
                ForEach(content.facts, id: \.self) { fact in
                    Text(verbatim: fact)
                        .lineLimit(fact.hasPrefix(Self.failedStagesPrefix) ? lineLimit : 1)
                        .help(fact.hasPrefix(Self.failedStagesPrefix) ? String(fact.dropFirst(Self.failedStagesPrefix.count)) : "")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
            if notificationsOff {
                Text("Notifications are off, so this alert shows as a window.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
            if let eggLine = content.eggLine {
                // An easter egg adds a line under the facts, never in place of one (EGG-11).
                Text(verbatim: eggLine)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
            VStack(spacing: 8) {
                ForEach(content.buttons, id: \.self) { action in
                    // The secondary actions sit in a menu above Dismiss, so the buttons stay calm (ALERT-03).
                    if action == .dismiss, !content.moreActions.isEmpty {
                        moreMenu(content.moreActions)
                    }
                    Button(action.title) {
                        perform(action)
                    }
                    .controlSize(.large)
                    .buttonSizing(.flexible)
                    .frame(maxWidth: .infinity)
                    .keyboardShortcut(shortcut(for: action))
                }
            }
            .padding(.top, 20)
        }
        .multilineTextAlignment(.center)
        .padding([.horizontal, .bottom], 20)
        .padding(.top, 20)
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Open Console and Hide Until the Next Build, in a menu of their own.
    private func moreMenu(_ actions: [AlertContent.Action]) -> some View {
        Menu {
            ForEach(actions, id: \.self) { action in
                Button(action.title) {
                    perform(action)
                }
            }
        } label: {
            Label("More", systemImage: "ellipsis")
        }
        .controlSize(.large)
        .buttonSizing(.flexible)
        .frame(maxWidth: .infinity)
    }

    private static let failedStagesPrefix = "Failed stages: "

    /// Three lines, six at accessibility sizes (`docs/design/alert.md`, Layout).
    private var lineLimit: Int {
        typeSize.isAccessibilitySize ? 6 : 3
    }

    /// The result's SF Symbol in its color, then "!1 #7 SUCCESS"; the emoji is for banners only (ALERT-02).
    private func headline(_ content: AlertContent) -> Text {
        let state = Self.state(of: content.result)
        let symbol = Text(Image(systemName: state.symbol))
        let tinted = state.color.map { symbol.foregroundStyle($0) } ?? symbol
        let text = content.headlineParts?.text ?? content.headline
        return Text("\(tinted) \(Text(verbatim: text))")
    }

    private static func state(of result: AlertContent.ResultKind) -> BuildState {
        switch result {
        case .success: .successful
        case .unstable: .unstable
        case .failure: .failed
        case .aborted: .aborted
        case .other: .other("")
        }
    }

    private func shortcut(for action: AlertContent.Action) -> KeyboardShortcut? {
        if action == alert.content.defaultAction {
            return .defaultAction
        }
        return action == .dismiss ? .cancelAction : nil
    }
}
