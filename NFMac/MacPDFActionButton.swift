import AppKit
import SwiftUI

/// Editor buttons must not become first responder: opening a color/font menu
/// or pressing a text-format button must preserve NSTextView's selected range.
struct MacPDFActionButton: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    var title: String
    var symbol: String? = nil
    var identifier: String
    var accessibilityTitle: String? = nil
    var inline = false
    var checked: Bool? = nil
    var action: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(action: action) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.setButtonType(checked == nil ? .momentaryPushIn : .switch)
        button.isBordered = false
        button.refusesFirstResponder = true; button.target = context.coordinator; button.action = #selector(Coordinator.press)
        updateNSView(button, context: context); return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        button.isEnabled = isEnabled
        if let checked { button.state = checked ? .on : .off }
        button.identifier = NSUserInterfaceItemIdentifier(identifier); button.setAccessibilityIdentifier(identifier); button.setAccessibilityLabel(accessibilityTitle ?? title); button.toolTip = accessibilityTitle ?? title
        button.font = .systemFont(ofSize: inline || symbol == nil ? 13 : 10)
        button.alignment = inline || checked != nil ? .left : .center
        button.title = title
        if let symbol { button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibilityTitle ?? title)?.withSymbolConfiguration(.init(pointSize: 16, weight: .regular)); button.imagePosition = title.isEmpty ? .imageOnly : (inline ? .imageLeading : .imageAbove) }
        else if checked == nil { button.image = nil; button.imagePosition = .noImage }
        button.contentTintColor = .labelColor
    }
    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func press(_ sender: NSButton) { guard sender.isEnabled else { return }; action() }
    }
}
