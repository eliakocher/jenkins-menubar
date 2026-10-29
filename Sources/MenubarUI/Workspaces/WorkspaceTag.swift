import MenubarCore
import SwiftUI

/// What a ``WorkspaceTag`` belongs to.
enum WorkspaceTagSubject: Hashable, Sendable {
    case mergeRequest(MergeRequest)
    case build(Build)
}

private struct WorkspaceTagsClickableKey: EnvironmentKey {
    static let defaultValue = false
}

private struct WorkspaceLinksOverrideKey: EnvironmentKey {
    static let defaultValue: WorkspaceLinks? = nil
}

extension EnvironmentValues {
    /// whether a tag opens its workspace on a click: the main window's lists and details; the panel's and the flyout's
    /// rows are buttons themselves, so their tags only say where the work lives
    var workspaceTagsClickable: Bool {
        get { self[WorkspaceTagsClickableKey.self] }
        set { self[WorkspaceTagsClickableKey.self] = newValue }
    }

    /// links to use instead of the app's own checkouts, for the gallery
    var workspaceLinksOverride: WorkspaceLinks? {
        get { self[WorkspaceLinksOverrideKey.self] }
        set { self[WorkspaceLinksOverrideKey.self] = newValue }
    }
}

extension View {
    /// Makes the tags below open their workspace on a click, in the main window.
    func workspaceTagsClickable() -> some View {
        environment(\.workspaceTagsClickable, true)
    }
}

/// The small quiet tag on a merge request's or build's row and detail that names the checkout the work lives in
/// ("develop3"), matched by the merge request's source branch (WS-07, ``WorkspaceLinks``). A click shows that checkout
/// in the Workspaces section. Nothing shows when no checkout is on the branch, or without checkouts at all.
struct WorkspaceTag: View {
    let subject: WorkspaceTagSubject
    @Environment(AppModel.self) private var model: AppModel?
    @Environment(WindowRouter.self) private var router: WindowRouter?
    @Environment(\.workspaceLinksOverride) private var override
    @Environment(\.workspaceTagsClickable) private var clickable

    var body: some View {
        if let entry {
            if clickable, let router {
                Button {
                    router.showInWorkspaces(entry.id)
                } label: {
                    tag(entry)
                }
                .buttonStyle(.plain)
                .help("\(entry.name) has \(entry.branch) checked out: show it in Workspaces")
                .accessibilityLabel("Workspace \(entry.name)")
                .accessibilityHint("Shows it in Workspaces")
            } else {
                tag(entry)
                    .help("\(entry.name) has \(entry.branch) checked out")
                    .accessibilityLabel("Workspace \(entry.name)")
            }
        }
    }

    private var entry: WorkspaceLinks.Entry? {
        let links: WorkspaceLinks
        if let override {
            links = override
        } else if let model {
            let store = model.workspaces
            guard !store.readings.isEmpty else {
                return nil
            }
            // Only a build can need the merge requests, to find its branch.
            let requests: [MergeRequest]
            if case .build = subject {
                requests = model.mergeRequests.list?.mergeRequests ?? []
            } else {
                requests = []
            }
            links = WorkspaceLinks(checkouts: store.checkouts, readings: store.readings, mergeRequests: requests)
        } else {
            return nil
        }
        return switch subject {
        case .mergeRequest(let mergeRequest): links.checkout(for: mergeRequest)
        case .build(let build): links.checkout(for: build)
        }
    }

    private func tag(_ entry: WorkspaceLinks.Entry) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.triangle.branch")
                .imageScale(.small)
            Text(verbatim: entry.name)
                .lineLimit(1)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(Color.primary.opacity(0.07), in: Capsule())
        .fixedSize()
        .contentShape(Capsule())
    }
}
