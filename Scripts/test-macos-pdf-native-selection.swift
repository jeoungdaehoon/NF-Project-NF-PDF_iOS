import AppKit
import PDFKit
import SwiftUI
#if canImport(NF_macOS)
@testable import NF_macOS
#endif

private final class LinkRecorder: NSObject, PDFViewDelegate {
    var urls: [URL] = []
    func pdfViewWillClick(onLink sender: PDFView, with url: URL) { urls.append(url) }
}

/// Real NSApplication mouse / NSWindow key dispatch against a searchable two-page PDF.
/// External links are intercepted by a fixture delegate; no browser/network is opened.
@main struct PDFNativeSelectionRegression {
    @MainActor static func main() throws {
        let app = NSApplication.shared; app.setActivationPolicy(.regular); app.finishLaunching()
        let menu = NSMenu(), item = NSMenuItem(), edit = NSMenu(title: "Edit")
        menu.addItem(item); item.submenu = edit
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        app.mainMenu = menu
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nf-native-selection-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let pasteboard = NSPasteboard.general
        let savedClipboard = (pasteboard.pasteboardItems ?? []).map { item in Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }) }
        var ownedClipboardChange = pasteboard.changeCount
        defer {
            if pasteboard.changeCount == ownedClipboardChange {
                pasteboard.clearContents()
                let restored = savedClipboard.map { values in
                    let item = NSPasteboardItem(); values.forEach { item.setData($0.value, forType: $0.key) }; return item
                }
                pasteboard.writeObjects(restored)
            }
        }
        let doc = try makePDF()
        let state = MacPDFEditorState(document: doc, identifier: "native-selection", fileName: "fixture.pdf", directory: directory)
        let window = NSWindow(contentRect: CGRect(x: 70, y: 100, width: 900, height: 760), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let canvas = MacPDFEditingView(frame: CGRect(x: 0, y: 0, width: 900, height: 760))
        canvas.editor = state; state.canvas = canvas; canvas.document = doc
        canvas.displayMode = .singlePage; canvas.minScaleFactor = 0.1; canvas.maxScaleFactor = 10
        canvas.autoScales = false; canvas.scaleFactor = 1
        let links = LinkRecorder(); canvas.delegate = links
        window.contentView = canvas; window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true)
        canvas.installObservers(); pump(0.6); state.selectTool(.select)
        // A command-line launch can inherit the launching app's held modifiers.
        // Start this fixture's unmodified mouse tests with an explicit key release.
        canvas.flagsChanged(with: NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 55)!)
        defer { canvas.removeObservers(); window.close() }
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
            guard value() else {
                print("Selection: \(String(describing: canvas.currentSelection?.string)); page: \(doc.index(for: canvas.currentPage!)); responder: \(String(describing: window.firstResponder))"); fflush(stdout)
                throw NSError(domain: "PDFNativeSelection", code: checks, userInfo: [NSLocalizedDescriptionKey: message])
            }
            checks += 1; print("PASS \(checks): \(message)"); fflush(stdout)
        }
        func gesture(_ points: [CGPoint], clicks: Int = 1, flags: NSEvent.ModifierFlags = []) {
            window.makeKey()
            let events: [(NSEvent.EventType, CGPoint)] = [(.leftMouseDown, points.first!)]
                + points.dropFirst().map { (.leftMouseDragged, $0) } + [(.leftMouseUp, points.last!)]
            for (index, pair) in events.enumerated() {
                let event = NSEvent.mouseEvent(with: pair.0, location: canvas.convert(pair.1, to: nil), modifierFlags: flags,
                    timestamp: ProcessInfo.processInfo.systemUptime + Double(index) * 0.01, windowNumber: window.windowNumber,
                    context: nil, eventNumber: index, clickCount: clicks, pressure: 0.5)!
                app.postEvent(event, atStart: false)
            }
            pump(0.2)
        }
        func key(_ text: String) {
            window.makeKey()
            if text == "c" {
                pasteboard.clearContents(); pasteboard.setString("fixture clipboard sentinel", forType: .string)
                ownedClipboardChange = pasteboard.changeCount
            }
            let pressed = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: .command,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 55)!
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: text == "c" ? 8 : 0)!
            let up = NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: .command,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: text == "c" ? 8 : 0)!
            let released = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 55)!
            window.sendEvent(pressed)
            if !window.performKeyEquivalent(with: event) { window.sendEvent(event) }
            window.sendEvent(up); window.sendEvent(released); pump(0.15)
            ownedClipboardChange = pasteboard.changeCount
        }
        let page = doc.page(at: 0)!
        let source = doc.findString("PDF original text selection and copy", withOptions: []).first!
        let rect = source.bounds(for: page)
        let first = canvas.convert(CGPoint(x: rect.minX + 1, y: rect.midY), from: page)
        let last = canvas.convert(CGPoint(x: rect.maxX - 1, y: rect.midY), from: page)
        try check(canvas.routesNativePDFInteraction(at: first), "source text routes to native PDFKit")
        let target = canvas.hitTest(canvas.superview!.convert(first, from: canvas))
        try check(target === canvas, "canvas dispatcher owns first click before forwarding source gestures to PDFKit")
        gesture((0...12).map { i in CGPoint(x: first.x + (last.x - first.x) * CGFloat(i) / 12, y: first.y) })
        try check(canvas.currentSelection?.string?.contains("original text selection") == true, "real mouse drag selects PDF source text")
        try check(state.selection.isEmpty && state.objects.isEmpty && state.undoCount == 0, "native selection does not create document edits")
        key("c")
        try check(pasteboard.string(forType: .string)?.contains("original text selection") == true, "real Cmd+C copies original PDF text")
        canvas.clearSelection(); key("a")
        try check(canvas.currentSelection?.string?.contains("PDF original text") == true && state.selection.isEmpty, "Cmd+A selects PDF text, not editable objects")
        canvas.clearSelection()
        canvas.go(to: page); pump(0.1)
        let word = doc.findString("original", withOptions: []).first!.bounds(for: page)
        gesture([canvas.convert(CGPoint(x: word.midX, y: word.midY), from: page)], clicks: 2)
        try check(!(canvas.currentSelection?.string ?? "").isEmpty, "native double-click word selection works")

        let object = MacPDFObject(page: 0, kind: .shape, bounds: CGRect(x: 70, y: 330, width: 170, height: 65))
        state.add(object); state.tool = .select; canvas.refreshAnnotations(); pump(0.1)
        let objectPoint = canvas.convert(CGPoint(x: 140, y: 360), from: page)
        try check(!canvas.routesNativePDFInteraction(at: objectPoint), "added object retains editor hit testing")
        gesture([objectPoint, CGPoint(x: objectPoint.x + 30, y: objectPoint.y)])
        try check(state.objects.first?.bounds.minX == object.bounds.minX + 30, "added object still moves via real drag")
        try check(canvas.currentSelection == nil, "object interaction clears native text selection")
        state.tool = .select
        let objectCopy = state.objects
        key("c")
        try check(pasteboard.data(forType: NSPasteboard.PasteboardType("com.nf.pdf.objects")) != nil, "object Cmd+C keeps custom object clipboard")
        // Native source interaction must also clear stale selected objects/menus.
        gesture((0...12).map { i in CGPoint(x: first.x + (last.x - first.x) * CGFloat(i) / 12, y: first.y) })
        try check(state.selection.isEmpty && !state.menuVisible, "source text drag clears prior object selection/menu")
        try check(state.objects == objectCopy && canvas.currentSelection?.string?.contains("original text") == true, "source selection preserves added objects")
        key("c")
        try check(pasteboard.string(forType: .string)?.contains("original text") == true, "copy switches back from objects to native text")

        let linkPoint = canvas.convert(CGPoint(x: 160, y: 530), from: page)
        gesture([linkPoint])
        try check(links.urls == [URL(string: "https://example.invalid/pdf-link")!], "embedded URL link reaches PDFKit delegate without launching a browser")
        let internalPoint = canvas.convert(CGPoint(x: 160, y: 470), from: page)
        let internalAnnotation = page.annotation(at: CGPoint(x: 160, y: 470))
        let destination = (internalAnnotation?.action as? PDFActionGoTo)?.destination
        try check(destination?.page === doc.page(at: 1), "fixture internal link resolves a valid destination page")
        gesture([internalPoint])
        try check(canvas.currentPage === doc.page(at: 1), "internal PDF link navigates to destination page")
        canvas.go(to: page); pump(0.1)
        state.selectTool(.view)
        try check(!canvas.routesNativePDFInteraction(at: first), "hand mode retains its own panning")
        state.selectTool(.pen)
        try check(!canvas.routesNativePDFInteraction(at: first), "pen mode retains drawing ownership")
        state.selectTool(.select)
        canvas.clearSelection()
        gesture([first, last], flags: .option)
        try check(canvas.currentSelection == nil && state.objects == objectCopy, "Option-drag retains temporary pan without selecting text or changing objects")
        gesture([CGPoint(x: 400, y: 180), CGPoint(x: 500, y: 180)], flags: .command)
        try check(canvas.scaleFactor > 1 && state.objects == objectCopy, "Cmd-drag temporary zoom remains available in selection mode")
        print("PASS: \(checks) native PDF selection checks")
    }

    @MainActor static func makePDF() throws -> PDFDocument {
        let data = NSMutableData(); let consumer = CGDataConsumer(data: data)!
        var bounds = CGRect(x: 0, y: 0, width: 600, height: 700)
        let context = CGContext(consumer: consumer, mediaBox: &bounds, nil)!
        for page in 0..<2 {
            context.beginPDFPage(nil); NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont(name: "Helvetica", size: 21)!, .foregroundColor: NSColor.black]
            (page == 0 ? "PDF original text selection and copy" : "Second page text").draw(at: CGPoint(x: 60, y: 600), withAttributes: attrs)
            if page == 0 {
                "External PDF link".draw(at: CGPoint(x: 60, y: 520), withAttributes: attrs)
                "Internal page link".draw(at: CGPoint(x: 60, y: 460), withAttributes: attrs)
            }
            NSGraphicsContext.restoreGraphicsState(); context.endPDFPage()
        }
        context.closePDF()
        let doc = PDFDocument(data: data as Data)!
        let external = PDFAnnotation(bounds: CGRect(x: 60, y: 518, width: 220, height: 28), forType: .link, withProperties: nil)
        external.action = PDFActionURL(url: URL(string: "https://example.invalid/pdf-link")!)
        doc.page(at: 0)!.addAnnotation(external)
        let internalLink = PDFAnnotation(bounds: CGRect(x: 60, y: 458, width: 220, height: 28), forType: .link, withProperties: nil)
        internalLink.action = PDFActionGoTo(destination: PDFDestination(page: doc.page(at: 1)!, at: CGPoint(x: 0, y: 700)))
        doc.page(at: 0)!.addAnnotation(internalLink)
        // Exercise links parsed from an actual PDF file, including resolved page references.
        return PDFDocument(data: doc.dataRepresentation()!)!
    }
    @MainActor static func pump(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        repeat {
            autoreleasepool {
                while let event = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) { NSApp.sendEvent(event) }
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
        } while Date() < end
    }
}
