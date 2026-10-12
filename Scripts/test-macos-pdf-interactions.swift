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
        gesture([view.convert(CGPoint(x: a.bounds.midX, y: a.bounds.midY), from: page)])
        gesture([view.convert(CGPoint(x: b.bounds.midX, y: b.bounds.midY), from: page)])
        try check(state.selected?.kind == .connector && state.menuVisible, "two native object clicks create connector and its bubble")
        var connectorStyle = state.style; connectorStyle.dashed = true; state.setStyle(connectorStyle, field: "dashed")
        try check(state.selected?.style.dashed == true, "connector style changes apply immediately")
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
