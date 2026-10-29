import MenubarCore
import SwiftUI

/// The mark of an answer written by Claude: a sparkle and "Claude", so an answer never reads as the app's own fact
/// (AI-06).
struct ClaudeMark: View {
    var body: some View {
        Label {
            Text("Claude")
        } icon: {
            Image(systemName: "sparkles")
        }
        .font(.callout.weight(.medium))
        .foregroundStyle(.purple)
        .accessibilityLabel("Written by Claude")
    }
}

/// What went, or goes, to Claude: the facts as sent, redacted, in a scrolling monospaced box that can be selected.
struct SentText: View {
    let prompt: ClaudePrompt

    var body: some View {
        ScrollView {
            Text(verbatim: prompt.text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .frame(maxHeight: 220)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// One AI answer's rows in a detail's section, whatever its state (AI-02 to AI-04): a spinner while the facts are
/// gathered and while Claude answers; the first time, what will be sent with Send to Claude and Cancel; the answer with
/// the Claude mark, its tokens and cost and what was sent; or the failure in plain words.
struct AIAnswerRows<Answer: View>: View {
    let state: AIAnswerState
    let send: () -> Void
    let dismiss: () -> Void
    @ViewBuilder let answer: (AIAnswer) -> Answer

    var body: some View {
        switch state {
        case .idle:
            EmptyView()
        case .preparing:
            progress("Gathering what to send…")
        case .review(let prompt):
            VStack(alignment: .leading, spacing: 8) {
                Text(
                    "This goes to Claude through your Claude Code login. Tokens, cookies and keys are removed. Once you "
                        + "send it, this kind of answer is sent without asking.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                SentText(prompt: prompt)
                HStack(spacing: 8) {
                    Button("Send to Claude", action: send)
                        .buttonStyle(.borderedProminent)
                    Button("Cancel", action: dismiss)
                        .buttonStyle(.bordered)
                    Spacer(minLength: 0)
                    Text(verbatim: "\(prompt.text.count.formatted()) characters")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
        case .running:
            progress("Claude is answering…")
        case .answered(let result):
            VStack(alignment: .leading, spacing: 10) {
                answer(result)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    ClaudeMark()
                    Text(verbatim: result.usageLine)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Spacer(minLength: 8)
                    Button("Clear", action: dismiss)
                        .buttonStyle(.link)
                }
                DisclosureGroup("What Was Sent") {
                    SentText(prompt: result.prompt)
                }
                .font(.callout)
            }
            .padding(.vertical, 2)
        case .failed(let message, _):
            StatusLine(.problem, message) {
                Button("Dismiss", action: dismiss)
                    .buttonStyle(.link)
            }
        }
    }

    private func progress(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(verbatim: text)
                .foregroundStyle(.secondary)
        }
    }
}

extension AIAnswerState {
    /// whether the button that asks should wait: the facts are being gathered, or Claude answers
    var isBusy: Bool {
        switch self {
        case .preparing, .running: true
        default: false
        }
    }

    /// whether the section has rows to show under its button
    var hasRows: Bool {
        self != .idle
    }
}
