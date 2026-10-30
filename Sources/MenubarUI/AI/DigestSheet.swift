import MenubarCore
import SwiftUI

/// The main window's Digest button (AI-04): a toolbar item that opens the digest sheet. Hidden while the Claude features
/// are off or `claude` isn't installed.
struct DigestToolbarItem: ToolbarContent {
    @Environment(AppModel.self) private var model: AppModel?
    @ViewState private var isShown = false

    var body: some ToolbarContent {
        if let model, model.ai.isOffered {
            ToolbarItem {
                Button {
                    isShown = true
                } label: {
                    Label("Digest", systemImage: "sparkles.rectangle.stack")
                }
                .help("Your daily digest, written by Claude from your merge requests, reviews, builds and work items")
                .sheet(isPresented: $isShown) {
                    DigestSheet()
                        .environment(model)
                }
            }
        }
    }
}

/// The digest sheet (AI-04): the last digest, or "Write Digest"; Claude writes it from my merge requests, the reviews
/// waiting for me, the red builds and the work items by slot, all from the app's own stores.
struct DigestSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let state = model.ai.state(of: .digest)
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Your Digest")
                    .font(.title2.weight(.semibold))
                Spacer()
                if case .answered(let answer) = state {
                    Text(verbatim: answer.answeredAt.formatted(date: .abbreviated, time: .shortened))
                        .foregroundStyle(.secondary)
                }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if state == .idle {
                            Text(
                                "Claude writes a few lines from your merge requests, the reviews waiting for you, the red "
                                    + "builds and your work items by slot.")
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        AIAnswerRows(
                            state: state, subject: .digest, send: { Task { await model.ai.send(.digest) } },
                            dismiss: { model.ai.dismiss(.digest) }
                        ) { answer in
                            if let text = answer.text {
                                CollapsibleMarkdown(document: MarkdownDocument(parsing: text, base: nil), startsExpanded: false)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                // A new question or answer scrolls into view.
                .onChange(of: model.ai.turns(of: .digest).map(\.status)) {
                    withAnimation(.snappy) { proxy.scrollTo(ConversationThread.endID, anchor: .bottom) }
                }
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                ClaudeActionButton(
                    title: state == .idle ? "Write Digest" : "Write Again", prominent: true,
                    help: "Write the digest from your merge requests, reviews, builds and work items.",
                    isDisabled: state.isBusy || isReviewing(state)
                ) { picked in
                    Task { await model.ai.writeDigest(model: picked) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 540)
    }

    private func isReviewing(_ state: AIAnswerState) -> Bool {
        if case .review = state {
            return true
        }
        return false
    }
}
