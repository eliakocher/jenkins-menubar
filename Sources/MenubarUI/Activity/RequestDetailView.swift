import AppKit
import MenubarCore
import SwiftUI

/// The parts of a kept request in the Activity inspector (LOG-02): a segmented control for Request, Response and
/// Headers, then the chosen part's text. A segmented control, not a tab view: Apple keeps them for "a toolbar or
/// inspector pane" [segmented-controls › macOS], and the text takes only the height it is given, so the inspector never
/// makes the window taller (ACTIVITY-01).
struct RequestDetailView: View {
    let request: RequestDetails
    @Binding var tab: RequestDetailTab

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Part", selection: $tab) {
                Text("Request").tag(RequestDetailTab.request)
                Text("Response").tag(RequestDetailTab.response)
                Text("Headers").tag(RequestDetailTab.headers)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            ActivityTextBox(content: .request(request, tab))
        }
    }
}

/// The part the request detail shows; it stays across selections, Response first.
enum RequestDetailTab: String, CaseIterable, Hashable {
    case request
    case response
    case headers
}

/// What a text box shows. A kept request's part is built in the box when it changes, not in the view's body: the JSON
/// of a 128 KB response takes a moment to indent and color.
enum ActivityTextContent: Hashable {
    case plain(String)
    case request(RequestDetails, RequestDetailTab)

    /// the text with the kinds of its parts
    var styled: StyledText {
        switch self {
        case .plain(let text): StyledText(text: text)
        case .request(let request, .request): request.styledRequest
        case .request(let request, .response): request.styledResponse
        case .request(let request, .headers): request.styledHeaders
        }
    }
}

/// A long text in a framed box: monospaced, wrapping, selectable, scrolling within the height it is given (ACTIVITY-01).
/// An AppKit text view, as the old Logs had: it copes with a 131 KB response, and it wraps a long URL or JSON line at
/// any character without the hyphens a SwiftUI `Text` adds, which aren't in the data.
struct ActivityTextBox: View {
    let content: ActivityTextContent

    init(text: String) {
        content = .plain(text)
    }

    init(content: ActivityTextContent) {
        self.content = content
    }

    var body: some View {
        ActivityCodeText(content: content)
            .frame(minHeight: 0, maxHeight: .infinity)
            .clipShape(.rect(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.separator)
            }
    }
}

/// A read-only, selectable `NSTextView` in its scroll view, with the old Logs' small monospaced font and the syntax
/// colors of `SyntaxStyle`; it shows the top of each new text. The string stays the raw text, so Copy copies it.
private struct ActivityCodeText: NSViewRepresentable {
    let content: ActivityTextContent

    final class Coordinator {
        var shown: ActivityTextContent?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        if let textView = scrollView.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.isRichText = false
            textView.drawsBackground = false
            textView.textContainerInset = NSSize(width: 6, height: 8)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView, context.coordinator.shown != content else { return }
        context.coordinator.shown = content
        textView.textStorage?.setAttributedString(SyntaxStyle.attributedString(content.styled))
        textView.scroll(.zero)
    }
}
