import SwiftUI
import AppKit

struct PlainCodeEditor: NSViewRepresentable {
    @Binding var text: String
    @Environment(\.isEnabled) private var enabled

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let editor = scroll.documentView as! NSTextView
        editor.delegate = context.coordinator
        editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false
        editor.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        editor.textContainerInset = NSSize(width: 8, height: 10)
        editor.isEditable = enabled
        editor.string = text
        editor.setAccessibilityLabel(String(localized: "Docker-Befehl oder Compose-Inhalt"))
        return scroll
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 300,
               height: proposal.height.flatMap { $0.isFinite ? $0 : nil } ?? 200)
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? NSTextView else { return }
        editor.isEditable = enabled
        if editor.string != text {
            let cursor = min(editor.selectedRange().location, (text as NSString).length)
            editor.string = text
            editor.setSelectedRange(NSRange(location: cursor, length: 0))
        }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PlainCodeEditor
        init(_ parent: PlainCodeEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            if let editor = notification.object as? NSTextView { parent.text = editor.string }
        }
    }
}
