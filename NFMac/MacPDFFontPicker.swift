import AppKit
import SwiftUI

struct MacPDFFontPicker: NSViewRepresentable {
    @Binding var selection: String

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.identifier = NSUserInterfaceItemIdentifier("pdf.text.font")
        button.setAccessibilityIdentifier("pdf.text.font")
        button.setAccessibilityLabel("글꼴")
        button.refusesFirstResponder = true
        button.autoenablesItems = false
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectFont)
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.prepareMenu),
                                               name: NSPopUpButton.willPopUpNotification, object: button)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.selection = $selection
        guard button.titleOfSelectedItem != selection else { return }
        if button.item(withTitle: selection) == nil { button.addItem(withTitle: selection) }
        button.selectItem(withTitle: selection)
    }

    final class Coordinator: NSObject {
        var selection: Binding<String>

        init(selection: Binding<String>) {
            self.selection = selection
        }

        @objc func prepareMenu(_ notification: Notification) {
            guard let button = notification.object as? NSPopUpButton else { return }
            let selected = selection.wrappedValue
            // Enumerate font faces only when AppKit is about to open the menu.
            var names = NSFontManager.shared.availableFonts
            if !names.contains(selected) { names.append(selected) }
            names.sort()
            guard button.itemTitles != names else { return }
            button.removeAllItems()
            button.addItems(withTitles: names)
            button.selectItem(withTitle: selected)
        }

        @objc func selectFont(_ sender: NSPopUpButton) {
            guard let selected = sender.titleOfSelectedItem, selected != selection.wrappedValue else { return }
            selection.wrappedValue = selected
        }
    }
}
