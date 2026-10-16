import AppKit
import PDFKit
import SwiftUI

/// Exercises the real NSWindow dispatch and SwiftUI accessibility actions, not
/// direct calls to mouseDown/mouseDragged. No user documents/network/Photos.
@main struct PDFInteractionRegression {
    @MainActor static func main() throws {
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nf-pdf-interactions-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw NSError(domain: "PDFInteractions", code: count, userInfo: [NSLocalizedDescriptionKey: message]) }
            count += 1; print("PASS \(count): \(message)"); fflush(stdout)
        }
        func settle() { RunLoop.current.run(until: Date().addingTimeInterval(0.12)) }
        func attribute(_ object: NSObject, _ name: String) -> Any? {
            let selector = NSSelectorFromString(name)
            guard object.responds(to: selector) else { return nil }
            return object.perform(selector)?.takeUnretainedValue()
        }
        func find(_ object: NSObject, _ identifier: String, depth: Int = 0) -> NSObject? {
            if depth > 30 { return nil }
            if attribute(object, "accessibilityIdentifier") as? String == identifier { return object }
            var children = attribute(object, "accessibilityChildren") as? [NSObject] ?? []
            if let view = object as? NSView { children += view.subviews }
            for child in children { if let found = find(child, identifier, depth: depth + 1) { return found } }
            return nil
        }
        func press(_ identifier: String) throws {
            let object = app.windows.compactMap { window in window.contentView.flatMap { find($0, identifier) } }.first
            guard let object, object.responds(to: NSSelectorFromString("accessibilityPerformPress")) else {
                for window in app.windows { if let host = window.contentView {
                    print("AX ROOT \(type(of: host)): \(String(describing: attribute(host, "accessibilityChildren")))")
                    if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) { host.cacheDisplay(in: host.bounds, to: rep); if let data = rep.representation(using: .png, properties: [:]) { try? data.write(to: URL(fileURLWithPath: "/private/tmp/nf-pdf-parity-ui-audit.png")) } }
                } }
                fflush(stdout)
                throw NSError(domain: "PDFUI", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing actual UI action: \(identifier)"])
            }
            if let button = object as? NSButton {
                try check(button.isEnabled, "native button enabled \(identifier)")
                button.performClick(nil); settle(); return
            }
            typealias Press = @convention(c) (AnyObject, Selector) -> Bool
            let selector = NSSelectorFromString("accessibilityPerformPress")
            let action = unsafeBitCast(object.method(for: selector), to: Press.self)
            try check(action(object, selector), "actual SwiftUI button \(identifier)"); settle()
        }
        let pdf = PDFDocument(), page = PDFPage(); page.setBounds(CGRect(x: 0, y: 0, width: 600, height: 1600), for: .mediaBox); pdf.insert(page, at: 0)
        let state = MacPDFEditorState(document: pdf, identifier: "ui", fileName: "fixture.pdf", directory: root)
        state.connectionStyle = MacPDFStyle()
        let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 1100, height: 780), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: MacPDFEditorView(state: state)); window.contentView = host; window.orderFront(nil); host.layoutSubtreeIfNeeded(); settle()
        guard let view = state.canvas else { throw CocoaError(.fileReadUnknown) }
        view.autoScales = false; view.scaleFactor = 1; settle()
        // Clear setup events before dispatching the test's intentional gestures.
        while app.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) != nil {}
        func gesture(_ points: [CGPoint], clicks: Int = 1) {
            guard let first = points.first, let last = points.last else { return }
            var pairs: [(NSEvent.EventType, CGPoint)] = [(.leftMouseDown, first)]
            if points.count > 1 { pairs += points.dropFirst().map { (.leftMouseDragged, $0) } }
            pairs.append((.leftMouseUp, last))
            for (i, pair) in pairs.enumerated() {
                let event = NSEvent.mouseEvent(with: pair.0, location: view.convert(pair.1, to: nil), modifierFlags: [], timestamp: Date.timeIntervalSinceReferenceDate + Double(i) * 0.01, windowNumber: window.windowNumber, context: nil, eventNumber: i + 1, clickCount: clicks, pressure: 0.6)!
                app.postEvent(event, atStart: false)
            }
            while let event = app.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) { app.sendEvent(event) }
            settle()
        }
        try check(view.hitTest(CGPoint(x: view.frame.midX, y: view.frame.midY)) === view, "PDF editing surface owns hit testing")
        try press("pdf.tool.pen")
        let p = CGPoint(x: view.bounds.midX - 80, y: view.bounds.midY)
        gesture([p, CGPoint(x: p.x + 100, y: p.y + 15)])
        try check(state.objects.count == 1 && state.objects[0].kind == .ink, "NSWindow dispatched pen drag creates ink")
        try press("pdf.tool.pen"); try check(state.optionsTool == .pen, "same-tool press opens options")
        state.optionsTool = nil; settle()
        try press("pdf.tool.neon")
        gesture([CGPoint(x: p.x, y: p.y + 70), CGPoint(x: p.x + 100, y: p.y + 75)])
        try check(state.objects.contains { $0.isTransient }, "NSWindow dispatched neon creates transient glowing ink")
        try press("pdf.tool.shape"); try press("pdf.add.shape.rectangle")
        try check(state.selected?.kind == .shape && state.menuVisible, "actual shape add button opens object menu")
        let blank = CGPoint(x: view.bounds.maxX - 25, y: view.bounds.midY)
        gesture([blank]); try check(state.selection.isEmpty && !state.menuVisible, "click outside bubble reaches PDF and dismisses selection")
        let shapeObject = state.objects.first { $0.kind == .shape }!
        gesture([view.convert(CGPoint(x: shapeObject.bounds.midX, y: shapeObject.bounds.midY), from: page)])
        try check(state.selection == [shapeObject.id] && state.menuVisible, "native object reselect opens bubble")
        try press("pdf.object.duplicate"); try check(state.objects.filter { $0.kind == .shape }.count == 2, "bubble duplicate action creates a shape copy")
        try press("pdf.object.delete"); try check(state.objects.filter { $0.kind == .shape }.count == 1, "bubble delete preserves original")
        try press("pdf.tool.text"); try press("pdf.add.text")
        try check(state.selected?.kind == .text && !state.isTextEditing && state.menuVisible, "text add selects without entering input")
        try press("pdf.object.edit"); try check(state.isTextEditing && window.firstResponder is NSTextView, "bubble edit activates native text editor")
        guard let text = view.activeTextView else { throw CocoaError(.fileReadUnknown) }
        text.string = "한글 ABC"; text.setSelectedRange(NSRange(location: 0, length: 2))
        let before = text.attributedString().attribute(.foregroundColor, at: 4, effectiveRange: nil) as? NSColor
        var style = state.style; style.stroke = .init(.systemRed); state.setStyle(style, field: "stroke")
        try check((text.attributedString().attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)?.usingColorSpace(.deviceRGB)?.redComponent ?? 0 > 0.7, "selected Korean characters receive color")
        try check((text.attributedString().attribute(.foregroundColor, at: 4, effectiveRange: nil) as? NSColor) == before, "unselected text retains prior formatting")
        try press("pdf.text.bold"); try check(text.selectedRange() == NSRange(location: 0, length: 2) && window.firstResponder === text, "format button preserves selection and restores input focus")
        view.textUndo(redo: false); view.textUndo(redo: true)
        try press("pdf.text.done"); try check(!state.isTextEditing && state.selected?.text == "한글 ABC", "text done commits Korean text and rich formatting")
        try press("pdf.object.edit"); try check(view.activeTextView?.string == "한글 ABC", "reselect and edit retain text")
        view.finishTextEditing(); state.selection = []; state.menuVisible = false
        // Adding at a long page viewport must not put images at the full-page center.
        let image = NSImage(size: CGSize(width: 200, height: 100)); image.lockFocus(); NSColor.red.setFill(); NSBezierPath(rect: CGRect(x: 0, y: 0, width: 200, height: 100)).fill(); image.unlockFocus()
        let placement = view.visibleInsertion(); state.insertImage(image); settle()
        let inserted = state.selected!
        try check(placement.1.contains(CGPoint(x: inserted.bounds.midX, y: inserted.bounds.midY)), "image inserted within actual visible PDF region")
        try check(abs(inserted.bounds.midY - page.bounds(for: .mediaBox).midY) > 100, "image is not forced to full-page center")
        let imageBounds = inserted.bounds
        try press("pdf.object.rotate"); try check(state.selected?.bounds == imageBounds && state.selected?.rotation == 0, "image rotation changes content, not selection box")
        try press("pdf.object.flip"); try check(state.selected?.flipped == true, "image bubble flip connected")
        try press("pdf.object.resetSize"); try check(state.selected?.bounds.width != 240, "image reset uses viewport not fixed 240 points")
        // Freehand lasso followed by group movement through real window dispatch.
        state.selection = []; state.menuVisible = false; state.tool = .lasso; state.optionsTool = nil; settle()
        let visible = view.visibleInsertion().1
        let a = MacPDFObject(page: 0, kind: .shape, bounds: CGRect(x: visible.midX - 100, y: visible.midY - 70, width: 30, height: 30))
        let b = MacPDFObject(page: 0, kind: .shape, bounds: CGRect(x: visible.midX - 50, y: visible.midY - 70, width: 30, height: 30))
        state.add(a); state.add(b); state.selection = []; state.menuVisible = false; view.refreshAnnotations(); settle()
        let lassoRect = a.bounds.union(b.bounds).insetBy(dx: -15, dy: -15)
        let corners = MacPDFEditingView.corners(lassoRect).map { view.convert($0, from: page) }
        gesture(corners + [corners[0]])
        try check(state.selection.contains(a.id) && state.selection.contains(b.id) && state.tool == .lasso, "lasso selects both shapes and stays in lasso mode")
        state.menuVisible = false; settle()
        let center = view.convert(CGPoint(x: lassoRect.midX, y: lassoRect.midY), from: page)
        gesture([center, CGPoint(x: center.x + 35, y: center.y)])
        try check(abs(state.objects.first { $0.id == a.id }!.bounds.minX - a.bounds.minX - 35) < 1, "selected group moves together")
        state.undo(); try check(state.objects.first { $0.id == a.id }!.bounds == a.bounds, "group movement is one undo operation")
        state.selection = [a.id, b.id]; state.menuVisible = false; state.tool = .lasso; view.refreshAnnotations(); settle()
        let group = a.bounds.union(b.bounds), corner = view.convert(CGPoint(x: group.maxX, y: group.maxY), from: page)
        gesture([corner, CGPoint(x: corner.x + 25, y: corner.y + (view.isFlipped ? -25 : 25))])
        try check(state.objects.first { $0.id == a.id }!.bounds.width > a.bounds.width, "lasso group resize handle scales selected objects")
        state.undo(); state.selection = [a.id, b.id]; state.menuVisible = false; view.refreshAnnotations(); settle()
        let rotate = view.convert(CGPoint(x: group.midX, y: group.maxY + 24 / view.scaleFactor), from: page)
        let destination = view.convert(CGPoint(x: group.midX + 60, y: group.midY), from: page)
        gesture([rotate, destination]); try check(abs(state.objects.first { $0.id == a.id }!.rotation) > 0.2, "lasso group rotation handle rotates objects")
        state.undo()
        try press("pdf.tool.connector"); state.optionsTool = nil; settle()
        try check(state.connectorEnabled && state.tool == .lasso, "connector toggle does not replace the active drawing tool")
        try press("pdf.tool.select"); settle()
        try check(state.connectorEnabled && state.tool == .select, "selecting another tool keeps connector mode enabled")
        let source = MacPDFObject(page: 0, kind: .shape, bounds: CGRect(x: visible.midX - 180, y: visible.midY + 60, width: 90, height: 70))
        let target = MacPDFObject(page: 0, kind: .text, bounds: CGRect(x: visible.midX + 100, y: visible.midY + 60, width: 90, height: 70), text: "Target")
        state.add(source); state.add(target); state.selection = []; state.menuVisible = false; settle()
        gesture([view.convert(CGPoint(x: source.bounds.midX, y: source.bounds.midY), from: page)])
        try check(state.selection == [source.id] && view.connectionHandles.count == 4, "selected object displays four outward arrow handles")
        func overlayColor(at point: CGPoint) -> NSColor? {
            guard let bitmap = view.renderedEditsImage() else { return nil }
            let sx = CGFloat(bitmap.pixelsWide) / view.bounds.width, sy = CGFloat(bitmap.pixelsHigh) / view.bounds.height
            return bitmap.colorAt(x: Int(point.x * sx), y: Int((view.isFlipped ? point.y : view.bounds.height - point.y) * sy))?.usingColorSpace(.deviceRGB)
        }
        let paintedHandle = overlayColor(at: view.connectionHandles[0].center)
        try check(paintedHandle != nil && paintedHandle!.blueComponent > paintedHandle!.redComponent + 0.1, "connector arrows are visibly painted, not only hit-test regions")
        gesture([view.convert(CGPoint(x: target.bounds.midX, y: target.bounds.midY), from: page)])
        try check(!state.objects.contains { $0.kind == .connector }, "clicking two objects no longer creates a connection")
        gesture([view.convert(CGPoint(x: source.bounds.midX, y: source.bounds.midY), from: page)])
        state.menuVisible = false; settle()
        func dispatch(_ type: NSEvent.EventType, _ point: CGPoint) {
            let event = NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: Date.timeIntervalSinceReferenceDate,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0.6)!
            app.postEvent(event, atStart: false)
            while let next = app.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) { app.sendEvent(next) }
            settle()
        }
        let sourcePort = view.connectionHandles.first { $0.anchor.x == 1 }!
        let targetPoint = view.convert(CGPoint(x: target.bounds.minX + 4, y: target.bounds.midY), from: page)
        let connectionUndo = state.undoCount
        dispatch(.leftMouseDown, sourcePort.center)
        dispatch(.leftMouseDragged, targetPoint)
        try check(view.hasConnectionPreview && view.connectionTargetID == target.id, "drag shows a live arrow and highlights its target")
        let highlighted = overlayColor(at: view.convert(CGPoint(x: target.bounds.minX + 10, y: target.bounds.minY + 10), from: page))
        try check(highlighted != nil && highlighted!.alphaComponent > 0.05 && highlighted!.blueComponent > highlighted!.redComponent, "target activation is visibly painted")
        try check(!state.objects.contains { $0.kind == .connector } && state.undoCount == connectionUndo, "drag preview does not create or save a connection before release")
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) { host.cacheDisplay(in: host.bounds, to: bitmap); try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/private/tmp/nf-pdf-connector-drag.png")) }
        dispatch(.leftMouseUp, targetPoint)
        try check(state.selected?.kind == .connector && state.menuVisible && !view.hasConnectionPreview && view.connectionTargetID == nil, "release creates connection and clears transient target highlight")
        let connected = state.selected!
        try check(connected.sourceID == source.id && connected.targetID == target.id && connected.sourceAnchor.x == 1 && connected.targetAnchor.x == 0 && connected.style.arrow,
            "connection attaches to the dragged source edge and nearest target edge")
        try check(state.undoCount == connectionUndo + 1, "one completed drag is one undo operation")
        state.undo(); try check(!state.objects.contains { $0.id == connected.id }, "undo removes completed connection")
        state.redo(); try check(state.objects.contains { $0 == connected }, "redo restores the same anchors and connection")
        state.selectObjects([source.id], showMenu: false); settle()
        let blankDrop = view.convert(CGPoint(x: visible.midX, y: visible.midY - 250), from: page)
        let objectsBeforeCancel = state.objects, undoBeforeCancel = state.undoCount
        let bottomPort = view.connectionHandles.first { $0.anchor.y == 0 }!
        dispatch(.leftMouseDown, bottomPort.center); dispatch(.leftMouseDragged, targetPoint)
        dispatch(.leftMouseDragged, blankDrop)
        try check(view.hasConnectionPreview && view.connectionTargetID == nil, "leaving target clears its activation highlight")
        dispatch(.leftMouseUp, blankDrop)
        try check(state.objects == objectsBeforeCancel && state.undoCount == undoBeforeCancel && !view.hasConnectionPreview, "dropping on empty space cancels without an undo entry")
        let leftPort = view.connectionHandles.first { $0.anchor.x == 0 }!
        gesture([leftPort.center, view.convert(CGPoint(x: source.bounds.midX, y: source.bounds.midY), from: page)])
        try check(state.objects == objectsBeforeCancel, "dropping back onto source never creates a self-connection")
        for anchor in MacPDFEditingView.connectionAnchors {
            state.selectObjects([source.id], showMenu: false); settle()
            let handle = view.connectionHandles.first { $0.anchor.cgPoint == anchor }!
            gesture([handle.center, targetPoint])
            try check(state.selected?.kind == .connector && state.selected?.sourceAnchor.cgPoint == anchor, "drag-to-connect works from edge \(anchor)")
            state.undo()
        }
        state.selectObjects([source.id], showMenu: false); settle()
        let sourceStyleBefore = state.selected!.style
        var nextConnectionStyle = state.connectionStyle; nextConnectionStyle.connectorRoute = "elbow"
        state.setConnectionStyle(nextConnectionStyle, field: "connectorRoute")
        try check(state.selected!.style == sourceStyleBefore && state.connectionStyle.connectorRoute == "elbow", "connector settings do not change the selected source item")
        let topPort = view.connectionHandles.first { $0.anchor.y == 1 }!
        gesture([topPort.center, targetPoint])
        try check(state.selected?.kind == .connector && state.selected?.style.connectorRoute == "elbow", "new connection uses independent connector styling")
        state.undo()
        state.selectObjects([target.id], showMenu: false); settle()
        try check(view.connectionHandles.count == 4, "text items also expose four connector handles")
        state.selectObjects([inserted.id], showMenu: false); settle()
        try check(view.connectionHandles.count == 4, "image items also expose four connector handles")
        state.selectObjects([connected.id], showMenu: true); settle()
        var connectorStyle = state.style; connectorStyle.dashed = true; state.setStyle(connectorStyle, field: "dashed")
        try check(state.selected?.style.dashed == true, "connector style changes apply immediately")
        state.menuVisible = false; settle()
        let routeOrigin = MacPDFObjectRenderer.connectorControlPoint(state.selected!, objects: state.objects)!
        let routeHandle = view.connectorRouteHandle!
        let gripColor = overlayColor(at: routeHandle)
        try check(gripColor != nil && gripColor!.blueComponent > gripColor!.redComponent, "selected dashed connector paints its circular middle grip")
        let beforeBend = state.selected!, beforeBendObjects = state.objects, beforeBendUndo = state.undoCount
        gesture([routeHandle])
        try check(state.objects == beforeBendObjects && state.undoCount == beforeBendUndo, "clicking middle grip without moving does not change the route")
        state.menuVisible = false; settle()
        let bendPoint = CGPoint(x: routeOrigin.x + 35, y: routeOrigin.y + 45)
        let bendViewPoint = view.convert(bendPoint, from: page)
        dispatch(.leftMouseDown, view.connectorRouteHandle!)
        dispatch(.leftMouseDragged, bendViewPoint)
        try check(state.undoCount == beforeBendUndo && state.selected?.connectorOffset != nil, "middle grip previews route change without adding undo entries during drag")
        dispatch(.leftMouseUp, bendViewPoint)
        let bent = state.selected!
        try check(abs(bent.connectorOffset!.x - 35) < 0.5 && abs(bent.connectorOffset!.y - 45) < 0.5 && state.undoCount == beforeBendUndo + 1, "middle grip moves route in both axes as one undo operation")
        try check(bent.sourceID == beforeBend.sourceID && bent.targetID == beforeBend.targetID && bent.sourceAnchor == beforeBend.sourceAnchor && bent.targetAnchor == beforeBend.targetAnchor && bent.style.dashed,
            "route adjustment preserves attached endpoints and dashed style")
        state.undo(); try check(state.objects.first { $0.id == connected.id }?.connectorOffset == nil, "undo restores original route")
        state.redo(); state.selectObjects([connected.id], showMenu: false); settle()
        try check(state.selected?.connectorOffset == bent.connectorOffset, "redo restores adjusted route")
        for delta in [CGPoint(x: -20, y: 0), CGPoint(x: 20, y: 0), CGPoint(x: 0, y: 20), CGPoint(x: 0, y: -20)] {
            state.menuVisible = false; settle()
            let oldPoint = MacPDFObjectRenderer.connectorControlPoint(state.selected!, objects: state.objects)!
            let targetPoint = CGPoint(x: oldPoint.x + delta.x, y: oldPoint.y + delta.y)
            gesture([view.connectorRouteHandle!, view.convert(targetPoint, from: page)])
            let changed = MacPDFObjectRenderer.connectorControlPoint(state.selected!, objects: state.objects)!
            try check(hypot(changed.x - targetPoint.x, changed.y - targetPoint.y) < 0.5, "middle grip adjusts route in direction \(delta)")
        }
        state.menuVisible = false; settle()
        let beforeCancelRoute = state.selected!, beforeCancelUndo = state.undoCount
        dispatch(.leftMouseDown, view.connectorRouteHandle!)
        dispatch(.leftMouseDragged, view.convert(CGPoint(x: bendPoint.x + 40, y: bendPoint.y + 40), from: page))
        try check(state.selected != beforeCancelRoute && state.undoCount == beforeCancelUndo, "route drag is active before Escape cancellation")
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: Date.timeIntervalSinceReferenceDate, windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        // This off-screen, prohibited-activation fixture has no key window for
        // NSApplication keyboard routing. Dispatch through its actual NSWindow.
        window.makeFirstResponder(view); window.sendEvent(escape); settle()
        try check(state.selected == beforeCancelRoute && state.undoCount == beforeCancelUndo, "Escape cancels middle-route drag without changing selection or history")
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) { host.cacheDisplay(in: host.bounds, to: bitmap); try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/private/tmp/nf-pdf-connector-middle-grip.png")) }
        try press("pdf.tool.connector")
        try check(!state.connectorEnabled && view.connectionHandles.isEmpty, "pressing connector toggle again disables handles")
        try press("pdf.tool.highlighter"); state.optionsTool = nil; settle()
        let markerStart = CGPoint(x: view.bounds.midX + 100, y: view.bounds.midY + 120)
        gesture([markerStart, CGPoint(x: markerStart.x + 100, y: markerStart.y)])
        try check(state.objects.last?.kind == .ink && state.objects.last!.style.stroke.a < 0.4, "native highlighter draws transparent ink")
        try press("pdf.tool.eraser"); state.eraserSize = 40; state.optionsTool = nil; settle()
        let inkBeforeErase = state.objects.filter { $0.kind == .ink }.count
        gesture([CGPoint(x: markerStart.x + 50, y: markerStart.y)])
        try check(state.objects.filter { $0.kind == .ink }.count > inkBeforeErase, "native eraser splits highlighter stroke")
        state.undo()
        if let bitmap = view.renderedEditsImage(), let png = bitmap.representation(using: .png, properties: [:]) { try png.write(to: URL(fileURLWithPath: "/private/tmp/nf-pdf-parity-overlay-proof.png")) }
        state.selectObjects([state.objects.first { $0.kind == .text }!.id], showMenu: true); settle()
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) { host.cacheDisplay(in: host.bounds, to: bitmap); if let png = bitmap.representation(using: .png, properties: [:]) { try png.write(to: URL(fileURLWithPath: "/private/tmp/nf-pdf-parity-bubble-proof.png")) } }
        try press("pdf.tool.view")
        let clip = view.documentView!.enclosingScrollView!.contentView
        clip.scroll(to: CGPoint(x: clip.bounds.minX, y: 300)); view.documentView!.enclosingScrollView!.reflectScrolledClipView(clip); settle()
        let beforePan = clip.bounds.origin
        gesture([CGPoint(x: view.bounds.midX, y: view.bounds.midY), CGPoint(x: view.bounds.midX, y: view.bounds.midY - 80)])
        try check(clip.bounds.origin != beforePan, "hand tool drag scrolls PDF viewport")
        for width in [1100.0, 550.0, 320.0] {
            window.setContentSize(CGSize(width: width, height: 780)); host.layoutSubtreeIfNeeded(); settle()
            let menu = MacPDFMenuLayout.frame(object: CGRect(x: width - 15, y: 2, width: 100, height: 60), viewport: CGSize(width: width, height: 400), preferredWidth: 560)
            try check(menu.minX >= 0 && menu.maxX <= width && menu.minY >= 0 && menu.maxY <= 400, "bubble stays inside \(Int(width))px viewport")
        }
        state.persist(); let restored = MacPDFEditorState(document: pdf, identifier: "ui", fileName: "fixture.pdf", directory: root)
        try check(restored.objects.filter { !$0.isTransient } == state.objects.filter { !$0.isTransient }, "edited objects and formatting survive reopening")
        try check(PDFDocument(data: state.exportPDF()!)?.string?.contains("한글 ABC") == true, "export preserves real Korean text")
        window.close(); print("PASS: \(count) actual macOS PDF interaction checks")
    }
}
