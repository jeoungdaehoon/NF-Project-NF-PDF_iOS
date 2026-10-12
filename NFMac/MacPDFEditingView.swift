import AppKit
import PDFKit
import SwiftUI

struct MacPDFCanvas: NSViewRepresentable {
    @ObservedObject var state: MacPDFEditorState
    var isContainerResizing = false
    func makeNSView(context: Context) -> MacPDFEditingView {
        let view = MacPDFEditingView(); view.editor = state; state.canvas = view
        view.document = state.document; view.minScaleFactor = 0.1; view.maxScaleFactor = 10
        view.displayMode = .singlePageContinuous; view.displaysPageBreaks = true; view.autoScales = true
        view.installObservers(); view.refreshAnnotations(); return view
    }
    func updateNSView(_ view: MacPDFEditingView, context: Context) {
        if view.document !== state.document { view.finishTextEditing(); view.document = state.document; view.refreshAnnotations() }
        if isContainerResizing { view.autoScales = false }
        state.configureView(); view.updateInteractionOverlay()
    }
    static func dismantleNSView(_ view: MacPDFEditingView, coordinator: ()) { view.finishTextEditing(); view.removeObservers() }
}

/// Route the PDF surface through one editor. Native text inputs and SwiftUI
/// overlays retain their own hit testing; PDFKit's private views do not consume
/// editing gestures before our tool handlers see them.
final class MacPDFEditingView: PDFView, NSTextViewDelegate {
    weak var editor: MacPDFEditorState?
    private var observers: [NSObjectProtocol] = []
    private var start: CGPoint?, dragPage: PDFPage?
    private var beforeDrag: [MacPDFObject] = [], samples: [MacPDFPoint] = []
    private var draft: MacPDFObject?, resizeHandle: Int?, connectorSource: UUID?
    private var rotating = false, moving = false, activeTool = MacPDFTool.view
    private var panStart: CGPoint?, panOrigin: CGPoint?, commandStart: (CGFloat, CGFloat)?
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
        if let textView {
            let local = textView.convert(point, from: superview)
            if textView.bounds.contains(local) { return textView }
        }
        return self
    }
    override func updateTrackingAreas() {
        if let mouseTracking { removeTrackingArea(mouseTracking) }
        mouseTracking = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(mouseTracking!); super.updateTrackingAreas()
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: editor?.tool == .view ? .openHand : .crosshair) }
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
    }
    func removeObservers() { observers.forEach(NotificationCenter.default.removeObserver); observers = [] }
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
        if editor.tool == .eraser, editor.optionsTool == .eraser || lastMousePoint != nil {
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
        if let object = editor.selected, let page = document?.page(at: object.page) {
            let objectBounds = object.kind == .connector ? (MacPDFObjectRenderer.connectorPath(object, objects: editor.objects)?.boundingBoxOfPath ?? object.bounds) : object.bounds
            let rect = convert(selectionBounds() ?? objectBounds, from: page).standardized
            let swiftRect = isFlipped ? rect : CGRect(x: rect.minX, y: bounds.height - rect.maxY, width: rect.width, height: rect.height)
            if editor.selectionViewRect != swiftRect { DispatchQueue.main.async { [weak editor] in if editor?.selectionViewRect != swiftRect { editor?.selectionViewRect = swiftRect } } }
        }
    }
    override func mouseMoved(with event: NSEvent) {
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
    func cancelGesture() { draft = nil; start = nil; dragPage = nil; samples = []; moving = false; rotating = false; resizeHandle = nil; connectorSource = nil; panStart = nil; panOrigin = nil; refreshAnnotations() }
    override func mouseDown(with event: NSEvent) {
        guard let editor else { super.mouseDown(with: event); return }
        if event.modifierFlags.contains(.command), editor.tool == .view { commandStart = (event.locationInWindow.x, scaleFactor); return }
        finishTextEditing(); window?.makeFirstResponder(self); activeTool = editor.tool; editor.menuVisible = false
        if editor.tool == .view || event.modifierFlags.contains(.option) {
            panStart = convert(event.locationInWindow, from: nil); panOrigin = documentView?.enclosingScrollView?.contentView.bounds.origin; NSCursor.closedHand.set(); return
        }
        guard let (page, point) = location(event), let document else { editor.selection = []; return }
        editor.currentPage = document.index(for: page); start = point; dragPage = page; beforeDrag = editor.objects
        resizeHandle = nil; rotating = false; moving = false; samples = [MacPDFPoint(point, pressure: pressure(event))]
        if [.select, .text, .image, .shape, .lasso, .connector].contains(activeTool), let rect = selectionBounds(), editor.selected?.page == editor.currentPage {
            let scale = max(scaleFactor, 0.1), remove = CGPoint(x: rect.minX - 18 / max(scaleFactor, 0.1), y: rect.maxY + 18 / max(scaleFactor, 0.1))
            if hypot(remove.x - point.x, remove.y - point.y) < 10 / scale { editor.deleteSelected(); start = nil; return }
            rotating = hypot(rect.midX - point.x, rect.maxY + 24 / scale - point.y) < 10 / scale
            resizeHandle = Self.handles(rect).firstIndex { hypot($0.x - point.x, $0.y - point.y) < 10 / scale }
            if rotating || resizeHandle != nil || (editor.selection.count > 1 && rect.contains(point)) { moving = true; return }
        }
        if activeTool == .lasso { editor.selection = []; updateInteractionOverlay(); return }
        if activeTool == .connector {
            if let picked = hit(point, page: editor.currentPage), picked.kind == .connector { editor.selectObjects([picked.id], showMenu: true); start = nil; return }
            guard let picked = hit(point, page: editor.currentPage), [.shape, .text, .image].contains(picked.kind) else { connectorSource = nil; start = nil; return }
            if let source = connectorSource, source != picked.id, let first = editor.objects.first(where: { $0.id == source && $0.page == picked.page }) {
                let right = first.bounds.midX <= picked.bounds.midX
                var object = MacPDFObject(page: picked.page, kind: .connector, bounds: page.bounds(for: .cropBox), style: editor.style, sourceID: source, targetID: picked.id)
                object.sourceAnchor = MacPDFPoint(CGPoint(x: right ? 1 : 0, y: 0.5)); object.targetAnchor = MacPDFPoint(CGPoint(x: right ? 0 : 1, y: 0.5))
                editor.add(object); connectorSource = nil; editor.menuVisible = true
            } else { connectorSource = picked.id; editor.selection = [picked.id]; refreshAnnotations() }
            start = nil; return
        }
        if [.select, .text, .image, .shape].contains(activeTool) {
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
        if let (x, scale) = commandStart { autoScales = false; scaleFactor = min(10, max(0.1, scale * CGFloat(pow(2, Double((event.locationInWindow.x - x) / 240))))); return }
        if let origin = panOrigin, let initial = panStart, let scroll = documentView?.enclosingScrollView {
            let p = convert(event.locationInWindow, from: nil)
            let proposed = CGPoint(x: origin.x - (p.x - initial.x), y: origin.y - (p.y - initial.y) * (scroll.contentView.isFlipped == isFlipped ? 1 : -1))
            scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(CGRect(origin: proposed, size: scroll.contentView.bounds.size)).origin); scroll.reflectScrolledClipView(scroll.contentView); updateInteractionOverlay(); return
        }
        guard let editor, let start, let page = dragPage else { return }
        lastMousePoint = convert(event.locationInWindow, from: nil)
        let point = convert(convert(event.locationInWindow, from: nil), to: page); editor.menuVisible = false
        if moving { transformSelection(to: point, from: start); refreshAnnotations(pageOnly: true); return }
        if [.pen, .highlighter, .neon].contains(activeTool), let previous = samples.last {
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
        if commandStart != nil { commandStart = nil; return }
        if panStart != nil { panStart = nil; panOrigin = nil; NSCursor.openHand.set(); return }
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
        let padding = style.width * (activeTool == .neon ? 6 : 1)
        let box = samples.reduce(CGRect.null) { $0.union(CGRect(origin: $1.cgPoint, size: CGSize(width: 0.1, height: 0.1))) }.insetBy(dx: -padding, dy: -padding)
        draft = MacPDFObject(page: page, kind: .ink, bounds: box, style: style, points: samples, isTransient: activeTool == .neon); refreshAnnotations(pageOnly: true)
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
    override func keyDown(with event: NSEvent) {
        guard let editor else { super.keyDown(with: event); return }
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if event.modifierFlags.contains(.command) {
            switch key {
            case "z": event.modifierFlags.contains(.shift) ? editor.redo() : editor.undo()
            case "c": editor.copySelected()
            case "x": editor.copySelected(); editor.deleteSelected()
            case "v": editor.paste()
            case "d": editor.duplicateSelected()
            case "a": editor.selection = Set(editor.pageObjects(editor.currentPage).filter { !$0.isTransient }.map(\.id)); editor.menuVisible = true; refreshAnnotations()
            default: super.keyDown(with: event)
            }; return
        }
        if event.keyCode == 51 || event.keyCode == 117 { editor.deleteSelected(); return }
        if event.keyCode == 53 { cancelGesture(); editor.selection = []; editor.menuVisible = false; editor.optionsTool = nil; editor.tool = .view; finishTextEditing(); refreshAnnotations(); return }
        super.keyDown(with: event)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.modifierFlags.contains(.command), let key = event.charactersIgnoringModifiers?.lowercased(), ["z", "c", "x", "v", "d", "a"].contains(key) else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event); return true
    }
    override func copy(_ sender: Any?) { if let editor, !editor.selection.isEmpty { editor.copySelected() } else { super.copy(sender) } }
}
