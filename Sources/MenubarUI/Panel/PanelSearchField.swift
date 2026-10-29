import AppKit
import SwiftUI

/// The panel's search field: an `NSSearchField`, since `searchable` would need a toolbar the panel lacks.
///
/// - It takes the keyboard focus whenever ``focusRequest`` changes, as on every open of the panel.
/// - Esc clears a search that isn't empty, and with the field empty it calls ``onEscape``, which closes the panel
///   (APP-06, DQA-05). Handled here, so it doesn't depend on how the field editor passes Esc on.
/// - ↓ moves the focus on to the rows.
/// - The ⓧ button clears the search too, through the field's action.
///
/// Settings' label picker uses it with a placeholder of its own.
struct PanelSearchField: NSViewRepresentable {
    @Binding var text: String
    var focusRequest: Int
    var placeholder = PanelSearchField.placeholder
    var onEscape: () -> Void

    static let placeholder = "Search builds"

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.searchChanged(_:))
        field.sendsSearchStringImmediately = true
        field.focusRingType = .default
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text {
            field.stringValue = text
        }
        if context.coordinator.focusRequest != focusRequest {
            context.coordinator.focusRequest = focusRequest
            // After this update, once the field is in the panel's window.
            DispatchQueue.main.async {
                field.window?.makeFirstResponder(field)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: PanelSearchField
        var focusRequest: Int?

        init(parent: PanelSearchField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else {
                return
            }
            parent.text = field.stringValue
        }

        /// The field's action, which the ⓧ button sends after clearing the text, without a text change notification.
        @objc func searchChanged(_ field: NSSearchField) {
            if parent.text != field.stringValue {
                parent.text = field.stringValue
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.cancelOperation(_:)):
                if parent.text.isEmpty {
                    parent.onEscape()
                } else {
                    parent.text = ""
                    (control as? NSSearchField)?.stringValue = ""
                }
                return true
            case #selector(NSResponder.moveDown(_:)):
                control.window?.selectKeyView(following: control)
                return true
            default:
                return false
            }
        }
    }
}
