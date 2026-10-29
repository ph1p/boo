import Cocoa

/// The sheet behind Ghostty's clipboard confirmations: a paste that paste
/// protection flagged (newlines or control sequences outside bracketed paste),
/// or a program asking to read the clipboard over OSC 52.
@MainActor
enum ClipboardConfirmation {
    /// Longest preview shown in the sheet; the full text is still what gets pasted.
    static let previewLimit = 2000

    static func ask(
        isPaste: Bool, text: String, canRemember: Bool, in view: NSView,
        completion: @escaping @MainActor (_ allowed: Bool, _ remember: Bool) -> Void
    ) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        if isPaste {
            alert.messageText = "Paste this text?"
            alert.informativeText =
                "It contains line breaks or control characters that may run commands as soon as it is pasted."
            alert.addButton(withTitle: "Paste")
        } else {
            alert.messageText = "Allow the program to read the clipboard?"
            alert.informativeText =
                "A program running in this terminal, possibly on a remote host, asked for the clipboard contents."
            alert.addButton(withTitle: "Allow")
        }
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = preview(text)
        if canRemember {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Remember for this terminal"
        }

        let finish: (NSApplication.ModalResponse) -> Void = { response in
            completion(response == .alertFirstButtonReturn, alert.suppressionButton?.state == .on)
        }
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }

    private static func preview(_ text: String) -> NSView {
        let shown = text.count > previewLimit ? String(text.prefix(previewLimit)) + "\n…" : text
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 420, height: 160)
        scroll.borderType = .bezelBorder
        if let textView = scroll.documentView as? NSTextView {
            textView.isEditable = false
            textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            textView.string = shown
            textView.setAccessibilityLabel("Clipboard contents")
        }
        return scroll
    }
}
