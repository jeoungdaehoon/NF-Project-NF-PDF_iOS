import AppKit
import Combine
import QuartzCore
import SwiftUI

/// Shared only by the two panes. Pointer motion moves a native preview window
/// directly, avoiding a SwiftUI/titlebar rebuild on every mouse event.
@MainActor
final class MacPortalTabTransfer: ObservableObject {
    @Published private(set) var pageID: String?
    @Published private(set) var sourcePane: String?
    @Published private(set) var targetPane: String?
    @Published private(set) var completedPane: String?
    @Published private(set) var isFinishing = false
    private weak var primary: MacPortalBrowserModel?
    private weak var secondary: MacPortalBrowserModel?
    private var regions: [String: CGRect] = [:]
    private var strips: [String: CGRect] = [:]
    private var preview: PreviewPanel?
    private var origin = CGRect.zero
    private var pointerOffset = CGSize.zero
    private var finishTimer: Timer?
    var previewFrame: CGRect? { preview?.frame }

    func configure(primary: MacPortalBrowserModel, secondary: MacPortalBrowserModel) {
        self.primary = primary; self.secondary = secondary
    }
    func register(pane: String, frame: CGRect, strip: Bool, window: NSWindow) {
        if strip { strips[pane] = frame } else { regions[pane] = frame }
    }
    func unregister(pane: String, strip: Bool) {
        if strip { strips.removeValue(forKey: pane) } else { regions.removeValue(forKey: pane) }
    }
    private func model(_ pane: String) -> MacPortalBrowserModel? {
        if pane == primary?.identifier { return primary }
        if pane == secondary?.identifier { return secondary }
        return nil
    }
    func begin(page: MacPortalPage, pane: String, frame: CGRect, pointer: CGPoint, window: NSWindow) -> Bool {
        guard preview == nil, model(pane)?.pages.contains(where: { $0.id == page.id }) == true,
              regions.count == 2 else { return false }
        origin = frame
        let liftedFrame = frame.insetBy(dx: -3, dy: -2)
        pointerOffset = CGSize(width: pointer.x - liftedFrame.minX, height: pointer.y - liftedFrame.minY)
        let panel = PreviewPanel(contentRect: liftedFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hasShadow = true; panel.ignoresMouseEvents = true; panel.level = .popUpMenu
        panel.alphaValue = 0.85
        panel.collectionBehavior = [.fullScreenAuxiliary, .transient]
        panel.contentView = NSHostingView(rootView: Text(page.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            .padding(.horizontal, 10).frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(MacPortalTitlebarPalette.foreground).background(MacPortalTitlebarPalette.background, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(MacPortalTitlebarPalette.separator, lineWidth: 1)))
        preview = panel
        withAnimation(.easeOut(duration: 0.14)) { pageID = page.id; sourcePane = pane; isFinishing = false }
        completedPane = nil
        panel.orderFront(nil)
        panel.contentView?.wantsLayer = true
        let lift = CABasicAnimation(keyPath: "transform.scale"); lift.fromValue = 0.94; lift.toValue = 1; lift.duration = 0.14
        panel.contentView?.layer?.add(lift, forKey: "tabLift")
        update(pointer: pointer)
        return true
    }
    func update(pointer: CGPoint) {
        guard let preview, !isFinishing, let sourcePane, let pageID,
              let page = model(sourcePane)?.pages.first(where: { $0.id == pageID }) else { return }
        preview.setFrameOrigin(CGPoint(x: pointer.x - pointerOffset.width, y: pointer.y - pointerOffset.height))
        let destination = regions.first { $0.key != sourcePane && $0.value.contains(pointer) && model($0.key)?.canReceiveTransferredPage(page) == true }?.key
        if destination != targetPane { withAnimation(.easeInOut(duration: 0.16)) { targetPane = destination } }
    }
    func finish(pointer: CGPoint) {
        guard !isFinishing else { return }
        update(pointer: pointer)
        guard let sourcePane, let pageID, let targetPane,
              let source = model(sourcePane), let target = model(targetPane) else { cancel(); return }
        let dock = strips[targetPane] ?? regions[targetPane] ?? origin
        let destination = CGRect(x: dock.minX + 4, y: dock.maxY - origin.height, width: origin.width, height: origin.height)
        let moved = withAnimation(.easeInOut(duration: 0.22)) { source.transferPage(id: pageID, to: target) }
        guard moved else { cancel(); return }
        completedPane = targetPane
        settle(to: destination)
    }
    func cancel(animated: Bool = true) {
        guard preview != nil else { return }
        if animated { settle(to: origin) } else { clear() }
    }
    private func settle(to frame: CGRect) {
        isFinishing = true
        preview?.setFrame(frame, display: true, animate: true)
        finishTimer?.invalidate()
        let timer = Timer(timeInterval: 0.24, repeats: false) { [weak self] _ in MainActor.assumeIsolated { self?.clear() } }
        finishTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private func clear() {
        finishTimer?.invalidate(); finishTimer = nil
        preview?.close(); preview = nil
        withAnimation(.easeOut(duration: 0.14)) { pageID = nil; sourcePane = nil; targetPane = nil; isFinishing = false }
    }
    private final class PreviewPanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override func animationResizeTime(_ newFrame: NSRect) -> TimeInterval { 0.22 }
    }
}

/// Geometry is in SCREEN coordinates so native titlebar and content hosts agree.
struct MacPortalTabDropRegion: NSViewRepresentable {
    let transfer: MacPortalTabTransfer
    let pane: String
    var strip = false
    final class RegionView: NSView {
        var transfer: MacPortalTabTransfer?
        var pane = ""
        var strip = false
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); report() }
        override func layout() { super.layout(); report() }
        override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); report() }
        override func setFrameOrigin(_ newOrigin: NSPoint) { super.setFrameOrigin(newOrigin); report() }
        func report() {
            guard let window, bounds.width > 0, bounds.height > 0 else { return }
            var rect = window.convertToScreen(convert(bounds, to: nil))
            if !strip { rect.size.height = window.frame.maxY - rect.minY }
            transfer?.register(pane: pane, frame: rect, strip: strip, window: window)
        }
    }
    func makeNSView(context: Context) -> RegionView {
        let view = RegionView(); view.transfer = transfer; view.pane = pane; view.strip = strip; return view
    }
    func updateNSView(_ view: RegionView, context: Context) { view.report() }
    static func dismantleNSView(_ view: RegionView, coordinator: ()) { view.transfer?.unregister(pane: view.pane, strip: view.strip) }
}

/// Only the tab title handles long press. The separate × button is untouched.
struct MacPortalTabPressLabel: NSViewRepresentable {
    let page: MacPortalPage
    let pane: String
    let transfer: MacPortalTabTransfer
    let enabled: Bool
    let foreground: NSColor
    let onSelect: () -> Void
    final class PressView: NSView {
        var page: MacPortalPage?
        var pane = ""
        var transfer: MacPortalTabTransfer?
        var enabled = false
        var foreground = NSColor.labelColor
        var onSelect: (() -> Void)?
        private var holdTimer: Timer?
        private var escapeMonitor: Any?
        private var downPoint: CGPoint?
        private var cancelled = false
        private var dragging = false
        private var cursorPushed = false
        private weak var previousResponder: NSResponder?
        override var mouseDownCanMoveWindow: Bool { false }
        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var intrinsicContentSize: NSSize {
            let width = ((page?.title ?? "") as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)]).width
            return NSSize(width: min(270, max(50, ceil(width) + 20)), height: 28)
        }
        override func draw(_ dirtyRect: NSRect) {
            let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center; paragraph.lineBreakMode = .byTruncatingTail
            let font = NSFont.systemFont(ofSize: 12, weight: .medium)
            (page?.title ?? "" as String).draw(in: CGRect(x: 10, y: (bounds.height - 16) / 2, width: max(0, bounds.width - 20), height: 16),
                withAttributes: [.font: font, .foregroundColor: foreground, .paragraphStyle: paragraph])
        }
        override func accessibilityPerformPress() -> Bool { onSelect?(); return true }
        override func mouseDown(with event: NSEvent) {
            clean()
            downPoint = event.locationInWindow; cancelled = false
            guard enabled else { return }
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseUp]) { [weak self] event in
                guard let self else { return event }
                if event.type == .keyDown && event.keyCode == 53 { self.cancelPress(); return nil }
                return event
            }
            let timer = Timer(timeInterval: 0.4, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.cancelled, let point = self.downPoint,
                          let window = self.window, let page = self.page else { return }
                    let frame = window.convertToScreen(self.convert(self.bounds, to: nil))
                    self.dragging = self.transfer?.begin(page: page, pane: self.pane, frame: frame,
                        pointer: window.convertPoint(toScreen: point), window: window) == true
                    if self.dragging {
                        self.previousResponder = window.firstResponder
                        window.makeFirstResponder(self)
                        NSCursor.closedHand.push(); self.cursorPushed = true
                    }
                }
            }
            holdTimer = timer; RunLoop.main.add(timer, forMode: .common)
        }
        override func mouseDragged(with event: NSEvent) {
            guard let window else { return }
            if dragging { transfer?.update(pointer: window.convertPoint(toScreen: event.locationInWindow)) }
            else if let point = downPoint, hypot(point.x - event.locationInWindow.x, point.y - event.locationInWindow.y) > 6 {
                cancelled = true; holdTimer?.invalidate()
            }
        }
        override func mouseUp(with event: NSEvent) {
            let wasDragging = dragging, wasCancelled = cancelled
            let callback = onSelect, transfer = transfer
            let point = window?.convertPoint(toScreen: event.locationInWindow)
            let releasedInside = bounds.contains(convert(event.locationInWindow, from: nil))
            clean()
            if wasDragging, let point { transfer?.finish(pointer: point) }
            else if !wasCancelled && releasedInside { callback?() }
        }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { cancelPress() } else { super.keyDown(with: event) }
        }
        override func cancelOperation(_ sender: Any?) { cancelPress() }
        func cancelPress() { cancelled = true; let active = dragging; clean(); cancelled = true; if active { transfer?.cancel() } }
        func clean() {
            holdTimer?.invalidate(); holdTimer = nil
            if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }; escapeMonitor = nil
            if cursorPushed { NSCursor.pop() }; cursorPushed = false
            if window?.firstResponder === self { window?.makeFirstResponder(previousResponder) }
            previousResponder = nil
            dragging = false; downPoint = nil
        }
    }
    func makeNSView(context: Context) -> PressView {
        let view = PressView(); view.setAccessibilityElement(true); view.setAccessibilityRole(.button); return view
    }
    func updateNSView(_ view: PressView, context: Context) {
        if !enabled && view.enabled { view.cancelPress() }
        view.page = page; view.pane = pane; view.transfer = transfer; view.enabled = enabled
        view.foreground = foreground; view.onSelect = onSelect
        view.toolTip = enabled ? "클릭: 페이지 선택 · 0.4초 누른 채 반대쪽으로 드래그: 탭 이동" : page.url.absoluteString
        view.setAccessibilityLabel(page.title); view.setAccessibilityIdentifier("portal.tab.press.\(pane).\(page.id)")
        view.invalidateIntrinsicContentSize(); view.needsDisplay = true
    }
    static func dismantleNSView(_ view: PressView, coordinator: ()) { view.cancelPress() }
}
