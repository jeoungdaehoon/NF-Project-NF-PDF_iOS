import AppKit
import PDFKit
import SwiftUI

struct MacPDFCanvas: NSViewRepresentable {
    @ObservedObject var state: MacPDFEditorState
    var isContainerResizing = false
    var onExitPaneExpansion: (() -> Void)?
    func makeNSView(context: Context) -> MacPDFEditingView {
        let view = MacPDFEditingView(); view.editor = state; state.canvas = view
        view.onExitPaneExpansion = onExitPaneExpansion
        view.document = state.document; view.minScaleFactor = 0.1; view.maxScaleFactor = 10
        view.displayMode = .singlePageContinuous; view.displaysPageBreaks = true; view.autoScales = true
        view.installObservers(); view.refreshAnnotations(); return view
    }
    func updateNSView(_ view: MacPDFEditingView, context: Context) {
        view.onExitPaneExpansion = onExitPaneExpansion
        if view.document !== state.document { view.finishTextEditing(); view.document = state.document; view.refreshAnnotations() }
        if isContainerResizing { view.autoScales = false }
        state.configureView(); view.updateInteractionOverlay()
    }
    static func dismantleNSView(_ view: MacPDFEditingView, coordinator: ()) { view.onExitPaneExpansion = nil; view.finishTextEditing(); view.removeObservers() }
}

/// Route the PDF surface through one editor. Native text inputs and SwiftUI
/// overlays retain their own hit testing; PDFKit's private views do not consume
/// editing gestures before our tool handlers see them.
final class MacPDFEditingView: PDFView, NSTextViewDelegate {
    weak var editor: MacPDFEditorState?
    var onExitPaneExpansion: (() -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var historyKeyMonitor: Any?
    private var start: CGPoint?, dragPage: PDFPage?
    private var beforeDrag: [MacPDFObject] = [], samples: [MacPDFPoint] = []
    private var draft: MacPDFObject?, resizeHandle: Int?
    struct ConnectionHandle { let anchor: MacPDFPoint; let center: CGPoint; let direction: CGVector }
    private struct ConnectionDrag {
        let source: UUID, page: Int, anchor: MacPDFPoint, style: MacPDFStyle
        var end: CGPoint
        var target: UUID?
        var targetAnchor = MacPDFPoint(CGPoint(x: 0, y: 0.5))
    }
    private var connectionDrag: ConnectionDrag?
    private struct RouteDrag {
        let id: UUID, page: Int, mouseOrigin: CGPoint, controlOrigin: CGPoint
        let before: [MacPDFObject]
    }
    private var routeDrag: RouteDrag?
    private var connectionPortsPath: CGPath?, connectionGlyphsPath: CGPath?
    private var connectionPreviewPath: CGPath?, connectionTargetPath: CGPath?
    var connectionTargetID: UUID? { connectionDrag?.target }
    var hasConnectionPreview: Bool { connectionDrag != nil }
    var connectorRouteHandle: CGPoint? {
        guard let editor, !editor.isTextEditing, editor.selection.count == 1,
              let object = editor.selected, object.kind == .connector,
              let p = MacPDFObjectRenderer.connectorControlPoint(object, objects: editor.objects), let page = document?.page(at: object.page) else { return nil }
        return convert(p, from: page)
    }
    private var rotating = false, moving = false, activeTool = MacPDFTool.view
    private var activeNeonType = MacPDFNeonType.line
    private var panStart: CGPoint?, panOrigin: CGPoint?, commandStart: (CGFloat, CGFloat)?
    private var commandHeld = false
    private var textView: NSTextView?, editingTextID: UUID?
    private var textBeforeEditing: [MacPDFObject] = [], editingTextScale: CGFloat = 1
    private var initialFitPending = true, mouseTracking: NSTrackingArea?
    private let interactionLayer = CAShapeLayer()
    private let drawingOverlay = MacPDFDrawingOverlay()
    private var lastMousePoint: CGPoint?
    var activeTextView: NSTextView? { textView }
    var editingObjectID: UUID? { editingTextID }
    var drawingDraft: MacPDFObject? { draft }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, bounds.contains(convert(point, from: superview)) else { return nil }
        if !commandHeld, let textView {
            let local = textView.convert(point, from: superview)
            if textView.bounds.contains(local) { return textView }
        }
        return self
    }
    override func updateTrackingAreas() {
        if let mouseTracking { removeTrackingArea(mouseTracking) }
        mouseTracking = NSTrackingArea(rect: .zero, options: [.mouseMoved, .cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(mouseTracking!); super.updateTrackingAreas()
    }
    var editingCursor: NSCursor {
        if commandHeld { return commandStart == nil ? .openHand : .closedHand }
        if panStart != nil { return .closedHand }
        return editor?.tool == .view ? .openHand : .crosshair
    }
    private func updateCommandModifier(_ flags: NSEvent.ModifierFlags) {
        let pressed = flags.contains(.command)
        guard commandHeld != pressed else { return }
        commandHeld = pressed
        window?.invalidateCursorRects(for: self)
        updateInteractionOverlay()
    }
    private func updateHoveredCursor(at location: CGPoint? = nil) {
        guard let window, window.isKeyWindow, let content = window.contentView else { return }
        let point = location ?? window.mouseLocationOutsideOfEventStream
        guard content.hitTest(content.convert(point, from: nil)) === self else { return }
        editingCursor.set()
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: editingCursor) }
    override func cursorUpdate(with event: NSEvent) {
        // Cursor-update events can carry stale modifier flags. Modifier/key
        // and pointer events own the temporary mode; cursor refreshes only draw it.
        editingCursor.set()
    }
    override func flagsChanged(with event: NSEvent) {
        updateCommandModifier(event.modifierFlags); updateHoveredCursor()
        super.flagsChanged(with: event)
    }
    override func layout() {
        super.layout(); updateInteractionOverlay()
        guard initialFitPending, bounds.width > 20, bounds.height > 20, document != nil else { return }
        initialFitPending = false
        DispatchQueue.main.async { [weak self] in
            guard let self, self.autoScales else { return }
            let fit = self.scaleFactorForSizeToFit
            if fit.isFinite && fit > 0 { self.scaleFactor = min(10, max(0.1, fit)) }
        }
    }
    static func corners(_ r: CGRect) -> [CGPoint] { [.init(x: r.minX, y: r.minY), .init(x: r.maxX, y: r.minY), .init(x: r.maxX, y: r.maxY), .init(x: r.minX, y: r.maxY)] }
    static func handles(_ r: CGRect) -> [CGPoint] {
        [.init(x: r.minX, y: r.minY), .init(x: r.midX, y: r.minY), .init(x: r.maxX, y: r.minY), .init(x: r.maxX, y: r.midY), .init(x: r.maxX, y: r.maxY), .init(x: r.midX, y: r.maxY), .init(x: r.minX, y: r.maxY), .init(x: r.minX, y: r.midY)]
    }
    func installObservers() {
        if historyKeyMonitor == nil {
            // App menus/WKWebView can consume key equivalents before PDFView
            // receives them. Intercept only while this canvas owns focus;
            // native text editors, other panes and windows keep their shortcuts.
            historyKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
                let handled = MainActor.assumeIsolated {
                    if event.type == .flagsChanged {
                        if let self, let window = self.window, window.isKeyWindow, event.window === window {
                            self.updateCommandModifier(event.modifierFlags); self.updateHoveredCursor()
                        }
                        return false
                    }
                    guard let self, let window = self.window, window.isKeyWindow,
                          event.window === window, window.firstResponder === self,
                          !self.isHiddenOrHasHiddenAncestor,
                          let redo = self.historyShortcut(event), let editor = self.editor else { return false }
                    redo ? editor.redo() : editor.undo()
                    return true
                }
                return handled ? nil : event
            }
        }
        drawingOverlay.canvas = self; drawingOverlay.frame = bounds; drawingOverlay.autoresizingMask = [.width, .height]
        drawingOverlay.wantsLayer = true; addSubview(drawingOverlay, positioned: .above, relativeTo: nil)
        wantsLayer = true; interactionLayer.fillColor = NSColor.clear.cgColor; interactionLayer.strokeColor = NSColor.systemBlue.cgColor; interactionLayer.lineWidth = 1.5
        interactionLayer.zPosition = 10000; layer?.addSublayer(interactionLayer)
        for name in [Notification.Name.PDFViewPageChanged, .PDFViewScaleChanged, NSView.boundsDidChangeNotification] {
            let observed: Any? = name == NSView.boundsDidChangeNotification ? documentView?.enclosingScrollView?.contentView : self
            documentView?.enclosingScrollView?.contentView.postsBoundsChangedNotifications = true
            observers.append(NotificationCenter.default.addObserver(forName: name, object: observed, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self, let editor = self.editor else { return }
                    if let page = self.currentPage, let doc = self.document, editor.currentPage != doc.index(for: page) {
                        self.finishTextEditing(); editor.selection = []; editor.menuVisible = false; editor.currentPage = doc.index(for: page)
                    }
                    editor.zoom = Int((self.scaleFactor * 100).rounded())
                    if notification.name == .PDFViewScaleChanged { self.finishTextEditing(); self.refreshAnnotations() }
                    else { self.updateInteractionOverlay() }
                }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, notification.object as? NSWindow === self.window else { return }
                self.commandStart = nil; self.updateCommandModifier([])
            }
        })
    }
    func removeObservers() {
        observers.forEach(NotificationCenter.default.removeObserver); observers = []
        if let historyKeyMonitor { NSEvent.removeMonitor(historyKeyMonitor); self.historyKeyMonitor = nil }
        commandStart = nil; commandHeld = false
    }
    func visibleInsertion() -> (Int, CGRect) {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        guard let document, let page = page(for: center, nearest: true) ?? currentPage else { return (0, .zero) }
        let visible = convert(bounds, to: page).intersection(page.bounds(for: .cropBox))
        return (document.index(for: page), visible.isNull || visible.isEmpty ? page.bounds(for: .cropBox) : visible)
    }
    func refreshAnnotations(pageOnly: Bool = false) {
        if drawingOverlay.superview == nil {
            drawingOverlay.canvas = self; drawingOverlay.frame = bounds; drawingOverlay.autoresizingMask = [.width, .height]; addSubview(drawingOverlay, positioned: .above, relativeTo: nil)
        }
        drawingOverlay.frame = bounds; drawingOverlay.needsDisplay = true
        needsDisplay = true; updateInteractionOverlay()
    }
    func renderedEditsImage() -> NSBitmapImageRep? {
        guard let bitmap = drawingOverlay.bitmapImageRepForCachingDisplay(in: drawingOverlay.bounds) else { return nil }
        drawingOverlay.cacheDisplay(in: drawingOverlay.bounds, to: bitmap); return bitmap
    }
    func selectionBounds(in objects: [MacPDFObject]? = nil) -> CGRect? {
        guard let editor else { return nil }
        let picked = (objects ?? editor.objects).filter { editor.selection.contains($0.id) && $0.kind != .connector }
        guard !picked.isEmpty else { return nil }
        return picked.reduce(CGRect.null) { rect, object in
            if object.kind == .ink { return rect.union(object.bounds) }
            return MacPDFObjectRenderer.corners(object).reduce(rect) { $0.union(CGRect(origin: $1, size: CGSize(width: 0.01, height: 0.01))) }
        }
    }
    func updateInteractionOverlay() {
        guard let editor else { return }
        drawingOverlay.frame = bounds; drawingOverlay.needsDisplay = true
        if let textView, let id = editingTextID, let object = editor.objects.first(where: { $0.id == id }), let page = document?.page(at: object.page) { textView.frame = convert(object.bounds, from: page) }
        let path = CGMutablePath()
        if !commandHeld, editor.tool == .eraser, editor.optionsTool == .eraser || lastMousePoint != nil {
            let p = lastMousePoint ?? CGPoint(x: bounds.midX, y: bounds.midY), size = editor.eraserSize
            path.addEllipse(in: CGRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size))
        }
        if activeTool == .lasso, !moving, start != nil, let page = dragPage, let first = samples.first {
            path.move(to: convert(first.cgPoint, from: page)); samples.dropFirst().forEach { path.addLine(to: convert($0.cgPoint, from: page)) }
        }
        if !editor.isTextEditing, let rect = selectionBounds(), let page = document?.page(at: editor.selected?.page ?? editor.currentPage) {
            path.addRect(convert(rect, from: page).standardized.insetBy(dx: -3, dy: -3))
            for handle in Self.handles(rect) { let p = convert(handle, from: page); path.addRect(CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)) }
            let rotate = convert(CGPoint(x: rect.midX, y: rect.maxY + 24 / max(scaleFactor, 0.1)), from: page)
            path.addEllipse(in: CGRect(x: rotate.x - 6, y: rotate.y - 6, width: 12, height: 12))
            let remove = convert(CGPoint(x: rect.minX - 18 / max(scaleFactor, 0.1), y: rect.maxY + 18 / max(scaleFactor, 0.1)), from: page)
            path.addEllipse(in: CGRect(x: remove.x - 7, y: remove.y - 7, width: 14, height: 14))
            path.move(to: CGPoint(x: remove.x - 3, y: remove.y - 3)); path.addLine(to: CGPoint(x: remove.x + 3, y: remove.y + 3))
            path.move(to: CGPoint(x: remove.x - 3, y: remove.y + 3)); path.addLine(to: CGPoint(x: remove.x + 3, y: remove.y - 3))
        }
        CATransaction.begin(); CATransaction.setDisableActions(true); interactionLayer.frame = bounds; interactionLayer.path = path; CATransaction.commit()
        updateConnectionOverlay()
        if let object = editor.selected, let page = document?.page(at: object.page) {
            let objectBounds = object.kind == .connector ? (MacPDFObjectRenderer.connectorPath(object, objects: editor.objects)?.boundingBoxOfPath ?? object.bounds) : object.bounds
            let rect = convert(selectionBounds() ?? objectBounds, from: page).standardized
            let swiftRect = isFlipped ? rect : CGRect(x: rect.minX, y: bounds.height - rect.maxY, width: rect.width, height: rect.height)
            if editor.selectionViewRect != swiftRect { DispatchQueue.main.async { [weak editor] in if editor?.selectionViewRect != swiftRect { editor?.selectionViewRect = swiftRect } } }
        }
    }
    override func mouseMoved(with event: NSEvent) {
        updateCommandModifier(event.modifierFlags); updateHoveredCursor(at: event.locationInWindow)
        guard editor?.tool == .eraser else { return }
        lastMousePoint = convert(event.locationInWindow, from: nil); updateInteractionOverlay()
    }
    private func location(_ event: NSEvent) -> (PDFPage, CGPoint)? {
        let point = convert(event.locationInWindow, from: nil)
        guard let page = page(for: point, nearest: false) else { return nil }
        return (page, convert(point, to: page))
    }
    private func hit(_ point: CGPoint, page: Int) -> MacPDFObject? {
        guard let editor else { return nil }
        return editor.pageObjects(page).reversed().first { object in
            if object.kind == .connector, let path = MacPDFObjectRenderer.connectorPath(object, objects: editor.objects) { return path.copy(strokingWithWidth: max(10 / scaleFactor, object.style.width + 6), lineCap: .round, lineJoin: .round, miterLimit: 10).contains(point) }
            if object.kind == .ink {
                let path = CGMutablePath(); if let first = object.points.first { path.move(to: first.cgPoint); object.points.dropFirst().forEach { path.addLine(to: $0.cgPoint) } }
                return path.copy(strokingWithWidth: max(10 / scaleFactor, object.style.width + 6), lineCap: .round, lineJoin: .round, miterLimit: 10).contains(point)
            }
            let x = point.x - object.bounds.midX, y = point.y - object.bounds.midY
            let p = CGPoint(x: object.bounds.midX + x * cos(-object.rotation) - y * sin(-object.rotation), y: object.bounds.midY + x * sin(-object.rotation) + y * cos(-object.rotation))
            return object.bounds.insetBy(dx: -4 / scaleFactor, dy: -4 / scaleFactor).contains(p)
        }
    }
    static let connectionAnchors = [CGPoint(x: 0, y: 0.5), CGPoint(x: 1, y: 0.5), CGPoint(x: 0.5, y: 1), CGPoint(x: 0.5, y: 0)]
    private func isConnectable(_ object: MacPDFObject) -> Bool { [.shape, .text, .image].contains(object.kind) && !object.isTransient }
    var connectionHandles: [ConnectionHandle] {
        guard let editor, editor.connectorEnabled, !editor.isTextEditing, editor.selection.count == 1,
              let object = editor.selected, isConnectable(object), let page = document?.page(at: object.page) else { return [] }
        let center = convert(CGPoint(x: object.bounds.midX, y: object.bounds.midY), from: page)
        return Self.connectionAnchors.map { anchor in
            let p = convert(MacPDFObjectRenderer.anchor(object, MacPDFPoint(anchor)), from: page)
            let length = max(0.001, hypot(p.x - center.x, p.y - center.y))
            let direction = CGVector(dx: (p.x - center.x) / length, dy: (p.y - center.y) / length)
            return ConnectionHandle(anchor: MacPDFPoint(anchor), center: CGPoint(x: p.x + direction.dx * 40, y: p.y + direction.dy * 40), direction: direction)
        }
    }
    private func updateConnectionOverlay() {
        let ports = CGMutablePath(), glyphs = CGMutablePath(), preview = CGMutablePath(), targetPath = CGMutablePath()
        for handle in connectionHandles {
            let p = handle.center, d = handle.direction
            ports.addEllipse(in: CGRect(x: p.x - 11, y: p.y - 11, width: 22, height: 22))
            let tip = CGPoint(x: p.x + d.dx * 6, y: p.y + d.dy * 6)
            glyphs.move(to: CGPoint(x: p.x - d.dx * 5, y: p.y - d.dy * 5)); glyphs.addLine(to: tip)
            glyphs.move(to: CGPoint(x: tip.x - d.dx * 5 - d.dy * 4, y: tip.y - d.dy * 5 + d.dx * 4))
            glyphs.addLine(to: tip); glyphs.addLine(to: CGPoint(x: tip.x - d.dx * 5 + d.dy * 4, y: tip.y - d.dy * 5 - d.dx * 4))
        }
        if let drag = connectionDrag, let editor, let source = editor.objects.first(where: { $0.id == drag.source }), let page = document?.page(at: drag.page) {
            let a = MacPDFObjectRenderer.anchor(source, drag.anchor), b = drag.end
            let path = MacPDFObjectRenderer.connectionPath(from: a, to: b, route: drag.style.connectorRoute)
            // PDF-to-view conversion includes zoom and page rotation.
            let origin = convert(CGPoint.zero, from: page), x = convert(CGPoint(x: 1, y: 0), from: page), y = convert(CGPoint(x: 0, y: 1), from: page)
            var transform = CGAffineTransform(a: x.x - origin.x, b: x.y - origin.y, c: y.x - origin.x, d: y.y - origin.y, tx: origin.x, ty: origin.y)
            if let converted = path.copy(using: &transform) { preview.addPath(converted) }
            let end = convert(b, from: page)
            let previous = drag.style.connectorRoute == "straight" ? a : CGPoint(x: (a.x + b.x) / 2, y: b.y)
            let prior = convert(previous, from: page), angle = atan2(end.y - prior.y, end.x - prior.x)
            preview.move(to: CGPoint(x: end.x - 10 * cos(angle - 0.45), y: end.y - 10 * sin(angle - 0.45)))
            preview.addLine(to: end); preview.addLine(to: CGPoint(x: end.x - 10 * cos(angle + 0.45), y: end.y - 10 * sin(angle + 0.45)))
            if let target = editor.objects.first(where: { $0.id == drag.target }) {
                let corners = MacPDFObjectRenderer.corners(target).map { convert($0, from: page) }
                if let first = corners.first { targetPath.move(to: first); corners.dropFirst().forEach { targetPath.addLine(to: $0) }; targetPath.closeSubpath() }
            }
        }
        connectionPortsPath = ports; connectionGlyphsPath = glyphs
        connectionPreviewPath = preview; connectionTargetPath = targetPath
        drawingOverlay.needsDisplay = true
    }
    // Draw through the same native overlay as editable objects, above PDFKit's
    // page layers, so the handles/hover feedback remain visible at every zoom.
    func drawConnectionOverlay(in context: CGContext) {
        context.saveGState(); defer { context.restoreGState() }
        context.setStrokeColor(NSColor.systemBlue.cgColor); context.setLineWidth(2); context.setLineJoin(.round); context.setLineCap(.round)
        if let path = connectionTargetPath, !path.isEmpty {
            context.saveGState()
            context.setFillColor(NSColor.systemBlue.withAlphaComponent(0.15).cgColor)
            context.setShadow(offset: .zero, blur: 6, color: NSColor.systemBlue.withAlphaComponent(0.65).cgColor)
            context.addPath(path); context.drawPath(using: .fillStroke); context.restoreGState()
        }
        if let path = connectionPreviewPath { context.addPath(path); context.strokePath() }
        if let path = connectionPortsPath { context.setFillColor(NSColor.white.cgColor); context.addPath(path); context.drawPath(using: .fillStroke) }
        if let path = connectionGlyphsPath { context.addPath(path); context.strokePath() }
        if let p = connectorRouteHandle, let color = editor?.selected?.style.stroke.color {
            let circle = CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12)
            context.setLineWidth(2); context.setStrokeColor(NSColor.white.cgColor)
            context.setFillColor(color.withAlphaComponent(1).cgColor)
            context.fillEllipse(in: circle); context.strokeEllipse(in: circle)
        }
    }
    private func updateRouteDrag(_ event: NSEvent) {
        guard let drag = routeDrag, let editor, let page = document?.page(at: drag.page),
              let index = editor.objects.firstIndex(where: { $0.id == drag.id }),
              let (a, b) = MacPDFObjectRenderer.endpoints(editor.objects[index], objects: editor.objects) else { return }
        let mouse = convert(convert(event.locationInWindow, from: nil), to: page), box = page.bounds(for: .cropBox)
        let point = CGPoint(x: min(box.maxX, max(box.minX, drag.controlOrigin.x + mouse.x - drag.mouseOrigin.x)),
                            y: min(box.maxY, max(box.minY, drag.controlOrigin.y + mouse.y - drag.mouseOrigin.y)))
        editor.objects[index].connectorOffset = MacPDFPoint(CGPoint(x: point.x - (a.x + b.x) / 2, y: point.y - (a.y + b.y) / 2))
        refreshAnnotations()
    }
    private func updateConnectionDrag(_ event: NSEvent) {
        guard var drag = connectionDrag, let editor, let page = document?.page(at: drag.page) else { return }
        let viewPoint = convert(event.locationInWindow, from: nil), point = convert(viewPoint, to: page)
        drag.end = point; drag.target = nil
        if bounds.contains(viewPoint), self.page(for: viewPoint, nearest: false) === page,
           let target = editor.pageObjects(drag.page).reversed().first(where: { $0.id != drag.source && isConnectable($0) && objectContains($0, point: point) }) {
            let anchor = Self.connectionAnchors.min { lhs, rhs in
                let a = MacPDFObjectRenderer.anchor(target, MacPDFPoint(lhs)), b = MacPDFObjectRenderer.anchor(target, MacPDFPoint(rhs))
                return hypot(a.x - point.x, a.y - point.y) < hypot(b.x - point.x, b.y - point.y)
            }!
            drag.target = target.id; drag.targetAnchor = MacPDFPoint(anchor)
            drag.end = MacPDFObjectRenderer.anchor(target, drag.targetAnchor)
        }
        connectionDrag = drag; updateConnectionOverlay()
    }
    private func objectContains(_ object: MacPDFObject, point: CGPoint) -> Bool {
        let dx = point.x - object.bounds.midX, dy = point.y - object.bounds.midY
        let local = CGPoint(x: object.bounds.midX + dx * cos(-object.rotation) - dy * sin(-object.rotation), y: object.bounds.midY + dx * sin(-object.rotation) + dy * cos(-object.rotation))
        return object.bounds.contains(local)
    }
    func cancelGesture() {
        if let drag = routeDrag, let editor, let original = drag.before.first(where: { $0.id == drag.id }), let index = editor.objects.firstIndex(where: { $0.id == drag.id }) { editor.objects[index] = original }
        routeDrag = nil; draft = nil; start = nil; dragPage = nil; samples = []; moving = false; rotating = false; resizeHandle = nil; connectionDrag = nil; panStart = nil; panOrigin = nil; commandStart = nil; refreshAnnotations()
    }
    func clearNeonDraft() {
        guard draft?.kind == .ink, draft?.isTransient == true else { return }
        draft = nil; start = nil; dragPage = nil; samples = []; beforeDrag = []
        refreshAnnotations()
    }
    override func mouseDown(with event: NSEvent) {
        guard let editor else { super.mouseDown(with: event); return }
        updateCommandModifier(event.modifierFlags)
        if commandHeld {
            finishTextEditing(); window?.makeFirstResponder(self); cancelGesture()
            commandStart = (event.locationInWindow.x, scaleFactor); editingCursor.set()
            return
        }
        finishTextEditing(); window?.makeFirstResponder(self); activeTool = editor.tool; editor.menuVisible = false
        activeNeonType = editor.neonType
        let viewPoint = convert(event.locationInWindow, from: nil)
        if !event.modifierFlags.contains(.option), let handle = connectorRouteHandle,
           hypot(handle.x - viewPoint.x, handle.y - viewPoint.y) <= 12,
           let object = editor.selected, let control = MacPDFObjectRenderer.connectorControlPoint(object, objects: editor.objects), let page = document?.page(at: object.page) {
            routeDrag = RouteDrag(id: object.id, page: object.page, mouseOrigin: convert(viewPoint, to: page), controlOrigin: control, before: editor.objects)
            return
        }
        if !event.modifierFlags.contains(.option), let source = editor.selected,
           let handle = connectionHandles.first(where: { hypot($0.center.x - viewPoint.x, $0.center.y - viewPoint.y) <= 13 }) {
            connectionDrag = ConnectionDrag(source: source.id, page: source.page, anchor: handle.anchor, style: editor.connectionStyle, end: MacPDFObjectRenderer.anchor(source, handle.anchor))
            updateConnectionOverlay(); return
        }
        let pickedLocation = location(event)
        let connectionPick = editor.connectorEnabled && pickedLocation.map { page, point in hit(point, page: document?.index(for: page) ?? -1) != nil } == true
        if (editor.tool == .view && !connectionPick) || event.modifierFlags.contains(.option) {
            panStart = convert(event.locationInWindow, from: nil); panOrigin = documentView?.enclosingScrollView?.contentView.bounds.origin; NSCursor.closedHand.set(); return
        }
        guard let (page, point) = location(event), let document else { editor.selection = []; return }
        editor.currentPage = document.index(for: page); start = point; dragPage = page; beforeDrag = editor.objects
        resizeHandle = nil; rotating = false; moving = false; samples = [MacPDFPoint(point, pressure: pressure(event))]
        if editor.connectorEnabled || [.select, .text, .image, .shape, .lasso].contains(activeTool), let rect = selectionBounds(), editor.selected?.page == editor.currentPage {
            let scale = max(scaleFactor, 0.1), remove = CGPoint(x: rect.minX - 18 / max(scaleFactor, 0.1), y: rect.maxY + 18 / max(scaleFactor, 0.1))
            if hypot(remove.x - point.x, remove.y - point.y) < 10 / scale { editor.deleteSelected(); start = nil; return }
            rotating = hypot(rect.midX - point.x, rect.maxY + 24 / scale - point.y) < 10 / scale
            resizeHandle = Self.handles(rect).firstIndex { hypot($0.x - point.x, $0.y - point.y) < 10 / scale }
            if rotating || resizeHandle != nil || (editor.selection.count > 1 && rect.contains(point)) { moving = true; return }
        }
        if activeTool == .lasso && !connectionPick { editor.selection = []; updateInteractionOverlay(); return }
        if connectionPick || [.select, .text, .image, .shape].contains(activeTool) {
            if let picked = hit(point, page: editor.currentPage) {
                if event.modifierFlags.contains(.shift) { if editor.selection.contains(picked.id) { editor.selection.remove(picked.id) } else { editor.selection.insert(picked.id) } }
                else if !editor.selection.contains(picked.id) { editor.selection = [picked.id] }
                moving = true
                if event.clickCount == 2, picked.kind == .text { editor.selectObjects([picked.id], showMenu: false); beginTextEditing(picked); start = nil }
                if event.clickCount == 2, let data = picked.attachmentPDF { editor.onOpenAttachment?(data, picked.attachmentName ?? "첨부 PDF"); start = nil }
            } else { editor.selection = [] }
            refreshAnnotations(); return
        }
        if activeTool == .eraser { erase(at: point, page: editor.currentPage) }
        else if [.pen, .highlighter, .neon].contains(activeTool) { editor.selection = []; updateInkDraft(editor, page: editor.currentPage) }
    }
    override func mouseDragged(with event: NSEvent) {
        if let (x, scale) = commandStart {
            updateCommandModifier(event.modifierFlags)
            // Keep ownership until mouse-up, even if Command is released, so
            // a zoom gesture can never fall through into ink/shape editing.
            guard commandHeld else { editingCursor.set(); return }
            autoScales = false
            scaleFactor = min(10, max(0.1, scale * CGFloat(pow(2, Double((event.locationInWindow.x - x) / 240)))))
            editingCursor.set(); return
        }
        if routeDrag != nil { updateRouteDrag(event); return }
        if connectionDrag != nil { updateConnectionDrag(event); return }
        if let origin = panOrigin, let initial = panStart, let scroll = documentView?.enclosingScrollView {
            let p = convert(event.locationInWindow, from: nil)
            let proposed = CGPoint(x: origin.x - (p.x - initial.x), y: origin.y - (p.y - initial.y) * (scroll.contentView.isFlipped == isFlipped ? 1 : -1))
            scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(CGRect(origin: proposed, size: scroll.contentView.bounds.size)).origin); scroll.reflectScrolledClipView(scroll.contentView); updateInteractionOverlay(); return
        }
        guard let editor, let start, let page = dragPage else { return }
        lastMousePoint = convert(event.locationInWindow, from: nil)
        let point = convert(convert(event.locationInWindow, from: nil), to: page); editor.menuVisible = false
        if moving { transformSelection(to: point, from: start); refreshAnnotations(pageOnly: true); return }
        if activeTool == .neon, activeNeonType != .line {
            samples = [samples.first ?? MacPDFPoint(start), MacPDFPoint(point, pressure: pressure(event))]
        } else if [.pen, .highlighter, .neon].contains(activeTool), let previous = samples.last {
            let steps = max(1, min(2048, Int(ceil(hypot(point.x - previous.x, point.y - previous.y) / 3))))
            for step in 1...steps { let t = Double(step) / Double(steps); samples.append(MacPDFPoint(CGPoint(x: previous.x + (point.x - previous.x) * t, y: previous.y + (point.y - previous.y) * t), pressure: previous.pressure + (pressure(event) - previous.pressure) * t)) }
        } else { samples.append(MacPDFPoint(point, pressure: pressure(event))) }
        switch activeTool {
        case .pen, .highlighter, .neon: updateInkDraft(editor, page: editor.currentPage)
        case .shape: draft = MacPDFObject(page: editor.currentPage, kind: .shape, bounds: CGRect(x: start.x, y: start.y, width: point.x - start.x, height: point.y - start.y).standardized, style: editor.style, shape: editor.shape); refreshAnnotations(pageOnly: true)
        case .eraser: erase(at: point, page: editor.currentPage)
        case .lasso: updateInteractionOverlay()
        default: break
        }
    }
    private func transformSelection(to point: CGPoint, from start: CGPoint) {
        guard let editor, let rect = selectionBounds(in: beforeDrag) else { return }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        var sx = 1.0, sy = 1.0, angle = 0.0, delta = CGPoint(x: point.x - start.x, y: point.y - start.y)
        if rotating { angle = atan2(point.y - center.y, point.x - center.x) - atan2(start.y - center.y, start.x - center.x); delta = .zero }
        else if let handle = resizeHandle {
            let fixed = Self.handles(rect)[(handle + 4) % 8], initial = Self.handles(rect)[handle]
            sx = [1, 5].contains(handle) ? 1 : max(0.08, (point.x - fixed.x) / (initial.x - fixed.x))
            sy = [3, 7].contains(handle) ? 1 : max(0.08, (point.y - fixed.y) / (initial.y - fixed.y))
            delta = CGPoint(x: fixed.x + (center.x - fixed.x) * sx - center.x, y: fixed.y + (center.y - fixed.y) * sy - center.y)
        }
        func transformed(_ p: CGPoint) -> CGPoint {
            let x = (p.x - center.x) * sx, y = (p.y - center.y) * sy
            return CGPoint(x: center.x + x * cos(angle) - y * sin(angle) + delta.x, y: center.y + x * sin(angle) + y * cos(angle) + delta.y)
        }
        for i in editor.objects.indices where editor.selection.contains(editor.objects[i].id) {
            guard let original = beforeDrag.first(where: { $0.id == editor.objects[i].id }), original.kind != .connector else { continue }
            let p = transformed(CGPoint(x: original.bounds.midX, y: original.bounds.midY)); editor.objects[i] = original
            editor.objects[i].bounds = CGRect(x: p.x - original.bounds.width * sx / 2, y: p.y - original.bounds.height * sy / 2, width: original.bounds.width * sx, height: original.bounds.height * sy)
            editor.objects[i].points = original.points.map { MacPDFPoint(transformed($0.cgPoint), pressure: $0.pressure) }
            if original.kind == .ink { editor.objects[i].style.width *= min(sx, sy) } else { editor.objects[i].rotation += angle }
            if original.kind == .text, editor.selection.count > 1, resizeHandle != nil {
                let factor = min(sx, sy); editor.objects[i].style.fontSize = original.style.fontSize * factor
                let text = scaledText(MacPDFTextFormatting.attributed(original), scale: factor)
                editor.objects[i].textRTF = text.rtf(from: NSRange(location: 0, length: text.length), documentAttributes: [:])
            }
        }
    }
    override func mouseUp(with event: NSEvent) {
        if commandStart != nil {
            commandStart = nil; updateCommandModifier(event.modifierFlags); editingCursor.set(); return
        }
        if let drag = routeDrag, let editor {
            // A click without a drag must not create a bend/undo entry.
            let original = drag.before.first(where: { $0.id == drag.id })
            let edited = editor.objects.first(where: { $0.id == drag.id })
            if original != edited { updateRouteDrag(event); editor.commitObjects(from: drag.before) }
            routeDrag = nil; editor.menuVisible = true; refreshAnnotations(); return
        }
        if connectionDrag != nil {
            updateConnectionDrag(event)
            if let drag = connectionDrag, let editor, editor.connectorEnabled,
               let target = drag.target, let page = document?.page(at: drag.page),
               editor.objects.contains(where: { $0.id == drag.source && $0.page == drag.page }) {
                var object = MacPDFObject(page: drag.page, kind: .connector, bounds: page.bounds(for: .cropBox), style: drag.style, sourceID: drag.source, targetID: target)
                object.sourceAnchor = drag.anchor; object.targetAnchor = drag.targetAnchor
                editor.add(object); editor.selectObjects([object.id], showMenu: true)
            }
            connectionDrag = nil; refreshAnnotations(); return
        }
        if panStart != nil { panStart = nil; panOrigin = nil; updateCommandModifier(event.modifierFlags); editingCursor.set(); return }
        guard let editor, start != nil else { return }
        if let draft, [.pen, .highlighter, .neon, .shape].contains(activeTool) {
            self.draft = nil
            if draft.kind == .ink || (draft.bounds.width > 4 && draft.bounds.height > 4) {
                editor.add(draft)
                if draft.kind == .shape { editor.selectObjects([draft.id], showMenu: true) } else { editor.selection = [] }
            }
        }
        if activeTool == .lasso, !moving {
            let path = CGMutablePath(); if let first = samples.first { path.move(to: first.cgPoint); samples.dropFirst().forEach { path.addLine(to: $0.cgPoint) }; path.closeSubpath() }
            editor.selection = Set(editor.pageObjects(editor.currentPage).filter { object in
                guard !object.isTransient, object.kind != .connector else { return false }
                if object.kind == .ink { return object.points.contains { path.contains($0.cgPoint) } }
                return path.contains(CGPoint(x: object.bounds.midX, y: object.bounds.midY)) || MacPDFObjectRenderer.corners(object).contains { path.contains($0) }
            }.map(\.id)); editor.menuVisible = !editor.selection.isEmpty
        }
        if moving || activeTool == .eraser { editor.commitObjects(from: beforeDrag) }
        if moving, !editor.selection.isEmpty {
            if activeTool == .lasso { editor.menuVisible = true } else { editor.selectObjects(editor.selection, showMenu: true) }
        }
        draft = nil; start = nil; dragPage = nil; samples = []; moving = false; rotating = false; resizeHandle = nil; refreshAnnotations()
    }
    private func pressure(_ event: NSEvent) -> Double { event.pressure > 0 ? Double(event.pressure) : 1 }
    private func updateInkDraft(_ editor: MacPDFEditorState, page: Int) {
        var style = editor.style
        if activeTool == .highlighter { style.width = max(12, style.width); style.stroke.a = 0.28; style.pressure = false }
        var points = samples
        if activeTool == .neon, activeNeonType == .box, let first = samples.first, let last = samples.last {
            let rect = CGRect(x: first.x, y: first.y, width: last.x - first.x, height: last.y - first.y).standardized
            points = (Self.corners(rect) + [CGPoint(x: rect.minX, y: rect.minY)]).map { MacPDFPoint($0) }
        }
        let padding = activeTool == .neon ? max(style.width * 6, activeNeonType == .arrow ? 12 : 0) : style.width
        let box = points.reduce(CGRect.null) { $0.union(CGRect(origin: $1.cgPoint, size: CGSize(width: 0.1, height: 0.1))) }.insetBy(dx: -padding, dy: -padding)
        draft = MacPDFObject(page: page, kind: .ink, bounds: box, style: style, points: points, isTransient: activeTool == .neon, neonType: activeTool == .neon ? activeNeonType : nil); refreshAnnotations(pageOnly: true)
    }
    private func erase(at point: CGPoint, page: Int) {
        guard let editor else { return }
        let radius = editor.eraserSize / max(scaleFactor, 0.1) / 2
        var result: [MacPDFObject] = [], removed: Set<UUID> = []
        for object in editor.objects {
            guard object.page == page else { result.append(object); continue }
            if object.kind == .ink {
                var fragments: [[MacPDFPoint]] = [], fragment: [MacPDFPoint] = [], touched = false
                for sample in object.points {
                    if hypot(sample.x - point.x, sample.y - point.y) <= radius + object.style.width / 2 { touched = true; if !fragment.isEmpty { fragments.append(fragment); fragment = [] } }
                    else { fragment.append(sample) }
                }
                if !fragment.isEmpty { fragments.append(fragment) }
                if touched { for points in fragments { var copy = object; copy.id = UUID(); copy.points = points; copy.bounds = points.reduce(CGRect.null) { $0.union(CGRect(origin: $1.cgPoint, size: CGSize(width: 1, height: 1))) }; result.append(copy) } }
                else { result.append(object) }
            } else if hit(point, page: page)?.id == object.id { removed.insert(object.id) }
            else { result.append(object) }
        }
        editor.objects = result.filter { !removed.contains($0.id) && $0.sourceID.map(removed.contains) != true && $0.targetID.map(removed.contains) != true }; refreshAnnotations(pageOnly: true)
    }
    func beginTextEditing(_ object: MacPDFObject) {
        guard let page = document?.page(at: object.page) else { return }
        finishTextEditing(); editingTextID = object.id; textBeforeEditing = editor?.objects ?? []; editingTextScale = max(scaleFactor, 0.1)
        let view = NSTextView(frame: convert(object.bounds, from: page)); view.isRichText = true; view.isEditable = true; view.isSelectable = true; view.allowsUndo = true
        view.drawsBackground = true; view.backgroundColor = object.style.fill.color; view.textContainerInset = CGSize(width: 4, height: 4)
        view.wantsLayer = true; view.layer?.borderWidth = object.style.width * editingTextScale; view.layer?.borderColor = object.style.textBorder?.color.cgColor
        view.textStorage?.setAttributedString(scaledText(MacPDFTextFormatting.attributed(object), scale: editingTextScale))
        view.delegate = self; addSubview(view); textView = view; editor?.isTextEditing = true; editor?.menuVisible = false
        refreshAnnotations(); window?.makeFirstResponder(view); view.selectAll(nil)
    }
    func finishTextEditing() {
        guard let id = editingTextID, let view = textView, let editor else { return }
        let normalized = scaledText(view.attributedString(), scale: 1 / editingTextScale)
        let rtf = normalized.rtf(from: NSRange(location: 0, length: normalized.length), documentAttributes: [:])
        editingTextID = nil; textView = nil; view.delegate = nil; view.removeFromSuperview(); editor.isTextEditing = false
        if let index = editor.objects.firstIndex(where: { $0.id == id }) { editor.objects[index].text = normalized.string; editor.objects[index].textRTF = rtf }
        editor.commitObjects(from: textBeforeEditing); textBeforeEditing = []; refreshAnnotations()
    }
    private func scaledText(_ text: NSAttributedString, scale: CGFloat) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: text)
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, range, _ in if let font = value as? NSFont { result.addAttribute(.font, value: NSFontManager.shared.convert(font, toSize: font.pointSize * scale), range: range) } }
        return result
    }
    func restoreTextFocus() { if let textView { window?.makeFirstResponder(textView) } }
    func applyTextFormat(field: String, style: MacPDFStyle) {
        guard let view = textView else { return }
        let selected = view.selectedRange(), text = view.attributedString()
        if field == "fill" { view.backgroundColor = style.fill.color }
        if field == "textBorder" || field == "width" { view.layer?.borderWidth = style.width * editingTextScale; view.layer?.borderColor = style.textBorder?.color.cgColor }
        if selected.length > 0 { replaceEditorText(MacPDFTextFormatting.apply(field: field, style: style, to: text, range: selected, scale: editingTextScale), selection: selected) }
        else {
            let sample = NSAttributedString(string: " ", attributes: view.typingAttributes)
            view.typingAttributes = MacPDFTextFormatting.apply(field: field, style: style, to: sample, range: NSRange(location: 0, length: 1), scale: editingTextScale).attributes(at: 0, effectiveRange: nil)
        }
        if let id = editingTextID, let editor, let index = editor.objects.firstIndex(where: { $0.id == id }) { editor.objects[index].style = style }
        restoreTextFocus()
    }
    func textViewDidChangeSelection(_ notification: Notification) {
        guard let view = textView, notification.object as AnyObject? === view, let editor else { return }
        let range = view.selectedRange(), text = view.attributedString()
        let attributes = range.location < text.length ? text.attributes(at: range.location, effectiveRange: nil) : view.typingAttributes
        var style = editor.style
        if let font = attributes[.font] as? NSFont {
            style.fontName = font.fontName; style.fontSize = font.pointSize / editingTextScale
            let traits = NSFontManager.shared.traits(of: font); style.bold = traits.contains(.boldFontMask); style.italic = traits.contains(.italicFontMask)
        }
        if let color = attributes[.foregroundColor] as? NSColor { style.stroke = .init(color) }
        style.underline = (attributes[.underlineStyle] as? NSNumber)?.intValue != nil && (attributes[.underlineStyle] as? NSNumber)?.intValue != 0
        style.strike = (attributes[.strikethroughStyle] as? NSNumber)?.intValue != nil && (attributes[.strikethroughStyle] as? NSNumber)?.intValue != 0
        editor.style = style
    }
    private func replaceEditorText(_ text: NSAttributedString, selection: NSRange) {
        guard let view = textView else { return }
        let before = NSAttributedString(attributedString: view.attributedString()), priorSelection = view.selectedRange()
        view.undoManager?.registerUndo(withTarget: self) { target in MainActor.assumeIsolated { target.replaceEditorText(before, selection: priorSelection) } }
        view.textStorage?.setAttributedString(text); view.setSelectedRange(selection); view.didChangeText()
    }
    func textUndo(redo: Bool) { if redo { textView?.undoManager?.redo() } else { textView?.undoManager?.undo() }; restoreTextFocus() }
    func showFontPicker() {
        guard let view = textView else { return }
        NSFontManager.shared.target = self
        let range = view.selectedRange(), text = view.attributedString()
        let font = range.location < text.length ? text.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont : view.typingAttributes[.font] as? NSFont
        NSFontManager.shared.setSelectedFont(font ?? .systemFont(ofSize: 18 * editingTextScale), isMultiple: false); NSFontManager.shared.orderFrontFontPanel(self)
    }
    @objc func changeFont(_ sender: Any?) {
        guard let view = textView, let editor else { return }
        let sample = (view.typingAttributes[.font] as? NSFont) ?? .systemFont(ofSize: editor.style.fontSize * editingTextScale)
        let font = NSFontManager.shared.convert(sample)
        var style = editor.style; style.fontName = font.fontName; style.fontSize = font.pointSize / editingTextScale
        editor.setStyle(style, field: "fontName"); editor.setStyle(style, field: "fontSize")
    }
    func toggleTextLink() {
        guard let editor, let object = editor.selected, object.kind == .text else { return }
        if object.link != nil { if let index = editor.objects.firstIndex(where: { $0.id == object.id }) { editor.objects[index].link = nil }; return }
        let range = textView?.selectedRange() ?? NSRange(location: 0, length: 0), text = textView?.string ?? object.text
        let candidate = range.length > 0 && NSMaxRange(range) <= (text as NSString).length ? (text as NSString).substring(with: range) : text
        guard let url = URL(string: candidate.trimmingCharacters(in: .whitespacesAndNewlines)), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { editor.error = "연결할 http 또는 https URL 문구를 선택해 주세요."; return }
        if let index = editor.objects.firstIndex(where: { $0.id == object.id }) { editor.objects[index].link = url.absoluteString }
        var style = editor.style; style.stroke = .init(.systemBlue); style.underline = true
        editor.setStyle(style, field: "stroke"); editor.setStyle(style, field: "underline")
    }
    override func scrollWheel(with event: NSEvent) { documentView?.enclosingScrollView?.scrollWheel(with: event); updateInteractionOverlay() }
    override func magnify(with event: NSEvent) { finishTextEditing(); autoScales = false; scaleFactor = min(10, max(0.1, scaleFactor * (1 + event.magnification))); updateInteractionOverlay() }
    private func historyShortcut(_ event: NSEvent) -> Bool? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command), !flags.contains(.control), !flags.contains(.option) else { return nil }
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        // Korean input sources can report "ㅋ" instead of "z" even for ⌘Z.
        // Keep character-based equivalents for alternate Latin layouts, and
        // use the physical Z key only when the input source emits non-ASCII.
        let nonLatinZ = event.keyCode == 6 && key.unicodeScalars.contains { !$0.isASCII }
        guard key == "z" || nonLatinZ else { return nil }
        return flags.contains(.shift)
    }
    override func keyDown(with event: NSEvent) {
        guard let editor else { super.keyDown(with: event); return }
        if routeDrag != nil, event.keyCode == 53 { cancelGesture(); return }
        if let redo = historyShortcut(event) { redo ? editor.redo() : editor.undo(); return }
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if event.modifierFlags.contains(.command) {
            switch key {
            case "c": editor.copySelected()
            case "x": editor.copySelected(); editor.deleteSelected()
            case "v": editor.paste()
            case "d": editor.duplicateSelected()
            case "a": editor.selection = Set(editor.pageObjects(editor.currentPage).filter { !$0.isTransient }.map(\.id)); editor.menuVisible = true; refreshAnnotations()
            default: super.keyDown(with: event)
            }; return
        }
        if event.keyCode == 51 || event.keyCode == 117 { editor.deleteSelected(); return }
        if event.keyCode == 53 {
            cancelGesture(); editor.selection = []; editor.menuVisible = false; editor.optionsTool = nil; editor.tool = .view
            finishTextEditing(); refreshAnnotations()
            if let exit = onExitPaneExpansion { DispatchQueue.main.async(execute: exit) }
            return
        }
        super.keyDown(with: event)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, let redo = historyShortcut(event), let editor {
            redo ? editor.redo() : editor.undo(); return true
        }
        guard window?.firstResponder === self, event.modifierFlags.contains(.command), let key = event.charactersIgnoringModifiers?.lowercased(), ["z", "c", "x", "v", "d", "a"].contains(key) else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event); return true
    }
    override func copy(_ sender: Any?) { if let editor, !editor.selection.isEmpty { editor.copySelected() } else { super.copy(sender) } }
}
