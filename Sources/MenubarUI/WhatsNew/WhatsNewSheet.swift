import MenubarCore
import SwiftUI

/// The versions the "What's New" sheet shows: the changelog's sections after `from` up to `to`; nil for no end.
public struct WhatsNewRequest: Hashable, Sendable, Identifiable {
    /// a new one for every request, so the sheet shows again for the same versions
    public var id = UUID()
    public var from: String?
    public var to: String?

    public init(from: String?, to: String?) {
        self.from = from
        self.to = to
    }
}

/// "What's New": the changelog's sections one under the other, the newest first, each with its version and date and its
/// text drawn by the app's Markdown view. It opens from the Inbox's entry after an update, which starts after the last
/// version seen, and from Help › What's New…, which shows every version.
///
/// A changelog that isn't in the bundle (a debug binary, the tests) shows a short note instead of the sections.
struct WhatsNewSheet: View {
    let sections: [ChangelogSection]
    let close: @MainActor () -> Void

    static let width: CGFloat = 580

    /// the title's second line: the newest version, or "Everything since 1.0.2" when there are several
    var subtitle: String {
        guard let newest = sections.first else {
            return AppIdentity.displayName
        }
        return sections.count > 1
            ? "\(AppIdentity.displayName) \(newest.version), and \(sections.count - 1) earlier \(sections.count == 2 ? "release" : "releases")"
            : "\(AppIdentity.displayName) \(newest.version)"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if sections.isEmpty {
                Text("The list of changes isn't part of this build.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 26) {
                        ForEach(sections) { section in
                            WhatsNewSectionView(section: section, isNewest: section.id == sections.first?.id)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)
                }
            }
            Divider()
            HStack {
                Spacer()
                Button("Done", action: close)
                    .keyboardShortcut(.defaultAction)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: Self.width)
        .frame(minHeight: 360, idealHeight: 620, maxHeight: 700)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "sparkles")
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(.yellow)
                .frame(width: 40, height: 40)
                .background(Color.yellow.opacity(0.16), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("What's New")
                    .font(.title2.weight(.semibold))
                Text(verbatim: subtitle)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }
}

/// One version: its number and date, then its changes.
private struct WhatsNewSectionView: View {
    let section: ChangelogSection
    let isNewest: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: section.version)
                    .font(.title3.weight(.semibold))
                if let date = section.date {
                    Text(verbatim: date)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            if section.body.isEmpty {
                Text("No notes for this version.")
                    .foregroundStyle(.secondary)
            } else {
                MarkdownView(markdown: section.body, base: nil)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension WhatsNewRequest {
    /// the sections the request asks for, from the changelog the bundle carries
    @MainActor
    func sections(in changelog: [ChangelogSection] = Changelog.bundled()) -> [ChangelogSection] {
        Changelog.sections(changelog, from: from, to: to)
    }
}
