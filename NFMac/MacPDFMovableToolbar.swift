import AppKit
import Combine
import SwiftUI

enum MacPDFToolbarLayout {
    static let topInset: CGFloat = 4
    static let sideInset: CGFloat = 8
    static let bottomInset: CGFloat = 14
    static let horizontalHeight: CGFloat = 52

    static func availableSize(in viewport: CGSize, scale: CGFloat) -> CGSize {
        CGSize(width: max(1, viewport.width - 2 * sideInset) / scale,
               height: max(1, viewport.height - topInset - bottomInset) / scale)
    }
    static func clamp(_ offset: CGSize, toolbar: CGSize, viewport: CGSize, scale: CGFloat) -> CGSize {
        let x = max(0, (viewport.width - toolbar.width * scale) / 2 - sideInset)
        let y = max(0, viewport.height - bottomInset - topInset - toolbar.height * scale)
        return CGSize(width: min(x, max(-x, offset.width)), height: min(0, max(-y, offset.height)))
    }

    static func optionsPanel(near toolbar: CGRect, in viewport: CGSize, vertical: Bool,
                             preferredHeight: CGFloat = 384) -> (frame: CGRect, alignment: Alignment) {
        let inset: CGFloat = 8, gap: CGFloat = 8
        let width = min(344, max(1, viewport.width - 2 * inset))
        let height = min(preferredHeight, max(1, viewport.height - 2 * inset))
        let left = toolbar.minX - gap - inset
        let right = viewport.width - inset - toolbar.maxX - gap
        if vertical && max(left, right) >= min(220, width) {
            let panelWidth = min(width, max(left, right))
            let x = left >= right ? toolbar.minX - gap - panelWidth : toolbar.maxX + gap
            let y = max(inset, min(toolbar.minY, viewport.height - inset - height))
            return (CGRect(x: x, y: y, width: panelWidth, height: height), .top)
        }

        let above = toolbar.minY - gap - inset
        let below = viewport.height - inset - toolbar.maxY - gap
        let x = max(inset, min(toolbar.midX - width / 2, viewport.width - inset - width))
        if max(above, below) < min(144, height) {
            // A tall toolbar can fill a very narrow split pane. In that case
            // place the settings at the edge with the most space.
            let y = above >= below ? inset : viewport.height - inset - height
            return (CGRect(x: x, y: max(inset, y), width: width, height: height), above >= below ? .top : .bottom)
        }
        let panelHeight = min(height, max(above, below))
        let y = above >= below ? toolbar.minY - gap - panelHeight : toolbar.maxY + gap
        return (CGRect(x: x, y: y, width: width, height: panelHeight), above >= below ? .bottom : .top)
    }
}

struct MacPDFToolbarBounds: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        if let next = nextValue() { value = next }
    }
}

struct MacPDFToolPalette<Content: View>: View {
    let vertical: Bool
    let availableSize: CGSize
    @ViewBuilder var content: () -> Content

    var body: some View {
        Group {
            if vertical {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 8, content: content)
                }
                .frame(width: 42, height: min(400, max(30, availableSize.height - 16)))
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8, content: content)
                }
                .frame(width: min(720, max(32, availableSize.width - 16)), height: MacPDFToolbarLayout.horizontalHeight - 16)
            }
        }
        .padding(8)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.12), lineWidth: 1).allowsHitTesting(false))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
    }
}

struct MacPDFToolPaletteButton: View {
    let toolID: String
    let title: String
    let symbol: String
    let isSelected: Bool
    var tooltip: String? = nil
    var onOffValue = false
    let action: () -> Void

    var body: some View {
        MacPDFActionButton(title: "", symbol: symbol, identifier: "pdf.tool." + toolID, accessibilityTitle: title, action: action)
            .frame(width: 32, height: 30)
            .background(isSelected ? Color.accentColor.opacity(0.24) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor.opacity(0.65))
                        .allowsHitTesting(false)
                }
            }
            .help(tooltip ?? title)
            .accessibilityLabel(title)
            .accessibilityValue(onOffValue ? (isSelected ? "켜짐" : "꺼짐") : (isSelected ? "선택됨" : ""))
    }
}

private struct ToolbarSizePreference: PreferenceKey {
    static let defaultValue = CGSize.zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

/// Own live movement here, not in the editor: dragging must not rebuild the
/// PDF canvas. Only the final, bounded position is published/persisted.
struct MacPDFMovableToolbar<Content: View>: View {
    @ObservedObject var state: MacPDFEditorState
    let viewport: CGSize
    @ViewBuilder var content: (MacPDFToolbarDragHandle, CGSize) -> Content
    @State private var measuredSize = CGSize.zero
    @State private var measuredVertical: Bool?
    @State private var drag: DragSession?
    private struct DragSession { let origin: CGSize; var offset: CGSize }
    private var scale: CGFloat { CGFloat(state.toolbarScale) }
    private var availableSize: CGSize { MacPDFToolbarLayout.availableSize(in: viewport, scale: scale) }
    private var toolbarSize: CGSize {
        if measuredVertical == state.verticalToolbar, measuredSize.width > 0, measuredSize.height > 0 { return measuredSize }
        return state.verticalToolbar
            ? CGSize(width: 58, height: min(416, availableSize.height))
            : CGSize(width: min(736, availableSize.width), height: MacPDFToolbarLayout.horizontalHeight)
    }
    private func bounded(_ offset: CGSize) -> CGSize {
        MacPDFToolbarLayout.clamp(offset, toolbar: toolbarSize, viewport: viewport, scale: scale)
    }
    var body: some View {
        content(MacPDFToolbarDragHandle(isLocked: state.paletteLocked, onBegan: beginDrag, onChanged: updateDrag, onEnded: endDrag), availableSize)
            .background(GeometryReader { geometry in Color.clear.preference(key: ToolbarSizePreference.self, value: geometry.size) })
            .onPreferenceChange(ToolbarSizePreference.self) { size in
                if size.width > 0, size.height > 0, size != measuredSize || measuredVertical != state.verticalToolbar {
                    measuredSize = size; measuredVertical = state.verticalToolbar
                }
            }
            .anchorPreference(key: MacPDFToolbarBounds.self, value: .bounds) { $0 }
            .scaleEffect(scale, anchor: .bottom)
            .offset(bounded(drag?.offset ?? state.toolbarOffset))
            .padding(.bottom, MacPDFToolbarLayout.bottomInset)
            .transaction { $0.animation = nil; $0.disablesAnimations = true }
            .onChange(of: state.paletteLocked) { _, locked in if locked { drag = nil } }
            .onChange(of: state.verticalToolbar) { _, _ in drag = nil }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { notification in
                if notification.object as? NSWindow === state.canvas?.window { drag = nil }
            }
            .onDisappear { drag = nil }
    }
    private func beginDrag() {
        guard !state.paletteLocked else { return }
        let origin = bounded(state.toolbarOffset)
        drag = DragSession(origin: origin, offset: origin)
    }
    private func updateDrag(_ translation: CGSize) {
        guard !state.paletteLocked, var session = drag else { return }
        session.offset = bounded(CGSize(width: session.origin.width + translation.width, height: session.origin.height + translation.height))
        drag = session
    }
    private func endDrag(_ translation: CGSize) {
        guard !state.paletteLocked, let session = drag else { drag = nil; return }
        let offset = bounded(CGSize(width: session.origin.width + translation.width, height: session.origin.height + translation.height))
        // Clear preview and commit together; never show saved + live movement.
        var transaction = Transaction(animation: nil); transaction.disablesAnimations = true
        withTransaction(transaction) { state.toolbarOffset = offset; drag = nil }
        state.rememberSettings()
    }
}

/// Window-space pointer deltas stay stable while the scaled toolbar moves.
/// This handle never takes keyboard focus away from the PDF/text editor.
struct MacPDFToolbarDragHandle: NSViewRepresentable {
    let isLocked: Bool
    let onBegan: () -> Void
    let onChanged: (CGSize) -> Void
    let onEnded: (CGSize) -> Void
    func makeNSView(context: Context) -> HandleView {
        let view = HandleView()
        view.imageScaling = .scaleProportionallyDown
        view.identifier = NSUserInterfaceItemIdentifier("pdf.toolbar.move")
        view.setAccessibilityElement(true); view.setAccessibilityRole(.image)
        view.setAccessibilityIdentifier("pdf.toolbar.move"); view.setAccessibilityLabel("도구창 이동")
        updateNSView(view, context: context); return view
    }
    func updateNSView(_ view: HandleView, context: Context) {
        view.isLocked = isLocked; view.onBegan = onBegan; view.onChanged = onChanged; view.onEnded = onEnded
        view.image = NSImage(systemSymbolName: isLocked ? "lock" : "arrow.up.and.down.and.arrow.left.and.right", accessibilityDescription: "도구창 이동")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        view.contentTintColor = .labelColor
        view.toolTip = isLocked ? "도구창 위치 잠금됨" : "드래그하여 도구창 이동"
    }
    final class HandleView: NSImageView {
        var isLocked = false
        var onBegan: (() -> Void)?, onChanged: ((CGSize) -> Void)?, onEnded: ((CGSize) -> Void)?
        private var origin: CGPoint?
        override var acceptsFirstResponder: Bool { false }
        override var mouseDownCanMoveWindow: Bool { false }
        override var intrinsicContentSize: NSSize { NSSize(width: 32, height: 30) }
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard !isHidden, bounds.contains(convert(point, from: superview)) else { return nil }
            return self
        }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            guard !isLocked else { return }
            origin = event.locationInWindow; onBegan?()
        }
        override func mouseDragged(with event: NSEvent) {
            guard !isLocked, let origin else { return }
            onChanged?(CGSize(width: event.locationInWindow.x - origin.x, height: origin.y - event.locationInWindow.y))
        }
        override func mouseUp(with event: NSEvent) {
            guard let origin else { return }
            self.origin = nil
            guard !isLocked else { return }
            onEnded?(CGSize(width: event.locationInWindow.x - origin.x, height: origin.y - event.locationInWindow.y))
        }
    }
}
