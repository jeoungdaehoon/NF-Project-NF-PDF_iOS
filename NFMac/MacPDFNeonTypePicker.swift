import AppKit
import SwiftUI

/// A compact native selector which preserves the editor's keyboard focus.
struct MacPDFNeonTypePicker: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    @Binding var selection: MacPDFNeonType
    func makeCoordinator() -> Coordinator { Coordinator { selection = $0 } }
    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: MacPDFNeonType.allCases.map(\.title), trackingMode: .selectOne,
                                         target: context.coordinator, action: #selector(Coordinator.selectType(_:)))
        control.refusesFirstResponder = true
        control.font = .systemFont(ofSize: 12)
        control.setAccessibilityIdentifier("pdf.neon.type")
        control.setAccessibilityLabel("네온 타입")
        for (index, type) in MacPDFNeonType.allCases.enumerated() {
            control.setToolTip("네온 \(type.title) 그리기", forSegment: index)
        }
        updateNSView(control, context: context)
        return control
    }
    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.onSelect = { selection = $0 }
        control.isEnabled = isEnabled
        control.selectedSegment = MacPDFNeonType.allCases.firstIndex(of: selection) ?? 0
    }
    final class Coordinator: NSObject {
        var onSelect: (MacPDFNeonType) -> Void
        init(_ onSelect: @escaping (MacPDFNeonType) -> Void) { self.onSelect = onSelect }
        @objc func selectType(_ sender: NSSegmentedControl) {
            guard sender.isEnabled, MacPDFNeonType.allCases.indices.contains(sender.selectedSegment) else { return }
            onSelect(MacPDFNeonType.allCases[sender.selectedSegment])
        }
    }
}
