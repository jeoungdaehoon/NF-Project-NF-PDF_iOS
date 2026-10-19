import AppKit
import PDFKit
import SwiftUI

/// Application-dispatched modifier/mouse events in a temporary PDF editor.
/// No user documents, accounts, clipboard or network are accessed.
@main struct PDFCommandZoomRegression {
    @MainActor static func main() throws {
        let app = NSApplication.shared; app.setActivationPolicy(.regular); app.finishLaunching()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nf-pdf-command-zoom-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let pdf = PDFDocument(), page = PDFPage()
        page.setBounds(CGRect(x: 0, y: 0, width: 900, height: 1200), for: .mediaBox); pdf.insert(page, at: 0)
        let state = MacPDFEditorState(document: pdf, identifier: "command-zoom", fileName: "fixture.pdf", sourceURL: URL(string: "https://unused.test/fixture.pdf"), directory: root)
        let shape = MacPDFObject(page: 0, kind: .shape, bounds: CGRect(x: 200, y: 400, width: 100, height: 80))
        state.add(shape)
        let window = NSWindow(contentRect: CGRect(x: 30, y: 70, width: 1150, height: 820), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: MacPDFEditorView(state: state)); window.contentView = host
        window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true); pump(0.6)
        defer { window.close() }
        guard let canvas = state.canvas else { throw CocoaError(.fileReadUnknown) }
        canvas.autoScales = false; canvas.scaleFactor = 1; pump(0.1)
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
            guard value() else { throw NSError(domain: "PDFCommandZoom", code: checks, userInfo: [NSLocalizedDescriptionKey: message]) }
            checks += 1; print("PASS \(checks): \(message)"); fflush(stdout)
        }
        func flags(_ modifiers: NSEvent.ModifierFlags) {
            let event = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: modifiers, timestamp: Date.timeIntervalSinceReferenceDate, windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 55)!
            app.postEvent(event, atStart: false); pump(0.02)
        }
        func mouse(_ type: NSEvent.EventType, _ point: CGPoint, _ modifiers: NSEvent.ModifierFlags = .command) {
            let event = NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: modifiers, timestamp: Date.timeIntervalSinceReferenceDate, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0.6)!
            app.postEvent(event, atStart: false); pump(0.025)
        }
        let p = CGPoint(x: 350, y: 350)
        let originalObjects = state.objects, history = (state.undoCount, state.redoCount)
        for tool in [MacPDFTool.view, .select, .pen, .highlighter, .neon, .eraser, .lasso, .shape, .text, .image] {
            flags([]); state.selectTool(tool); state.optionsTool = nil
            state.selection = [shape.id]; state.menuVisible = false
            canvas.autoScales = false; canvas.scaleFactor = 1; pump(0.04)
            flags(.command)
            try check(canvas.editingCursor === NSCursor.openHand, "\(tool.rawValue): Command press immediately selects hand cursor")
            mouse(.leftMouseDown, p)
            try check(canvas.editingCursor === NSCursor.closedHand && canvas.drawingDraft == nil, "\(tool.rawValue): zoom drag owns the pointer without an editing draft (cursor=\(canvas.editingCursor), focused=\(window.firstResponder === canvas))")
            mouse(.leftMouseDragged, CGPoint(x: p.x + 120, y: p.y))
            try check(abs(canvas.scaleFactor - sqrt(2)) < 0.01, "\(tool.rawValue): right drag zooms in")
            mouse(.leftMouseDragged, CGPoint(x: p.x - 120, y: p.y))
            try check(abs(canvas.scaleFactor - 1 / sqrt(2)) < 0.01, "\(tool.rawValue): left drag zooms out")
            mouse(.leftMouseUp, CGPoint(x: p.x - 120, y: p.y))
            try check(canvas.editingCursor === NSCursor.openHand, "\(tool.rawValue): held Command keeps the hand cursor after mouse-up")
            flags([])
            try check(canvas.editingCursor === (tool == .view ? NSCursor.openHand : NSCursor.crosshair) && state.tool == tool, "\(tool.rawValue): releasing Command restores the original tool/cursor")
            try check(state.objects == originalObjects && state.selection == [shape.id] && state.undoCount == history.0 && state.redoCount == history.1, "\(tool.rawValue): zoom never draws, erases, moves objects or changes edit history")
        }
        state.selectTool(.pen); state.optionsTool = nil; canvas.scaleFactor = 1; pump(0.05)
        flags(.command); mouse(.leftMouseDown, p)
        mouse(.leftMouseDragged, CGPoint(x: p.x, y: p.y + 120))
        try check(abs(canvas.scaleFactor - 1) < 0.01, "vertical-only Command drag does not zoom")
        mouse(.leftMouseDragged, CGPoint(x: p.x + 100, y: p.y))
        let beforeRelease = canvas.scaleFactor
        flags([]); mouse(.leftMouseDragged, CGPoint(x: p.x + 180, y: p.y), [])
        mouse(.leftMouseUp, CGPoint(x: p.x + 180, y: p.y), [])
        try check(canvas.scaleFactor == beforeRelease && state.objects == originalObjects && canvas.drawingDraft == nil, "releasing Command mid-drag stops zoom without leaking into pen editing")
        flags(.command); mouse(.leftMouseDown, p)
        mouse(.leftMouseDragged, CGPoint(x: p.x + 10000, y: p.y))
        try check(canvas.scaleFactor == 10, "Command zoom clamps to maximum 1000 percent")
        mouse(.leftMouseDragged, CGPoint(x: p.x - 10000, y: p.y))
        try check(canvas.scaleFactor == 0.1, "Command zoom clamps to minimum 10 percent")
        mouse(.leftMouseUp, p); flags([])
        canvas.scaleFactor = 1; pump(0.05)
        state.selectTool(.neon); state.optionsTool = nil; state.neonType = .line
        mouse(.leftMouseDown, p, []); mouse(.leftMouseDragged, CGPoint(x: p.x + 60, y: p.y + 15), []); mouse(.leftMouseUp, CGPoint(x: p.x + 60, y: p.y + 15), [])
        try check(state.objects.filter(\.isTransient).count == 1, "original neon tool draws normally after Command zoom")
        let undo = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: Date.timeIntervalSinceReferenceDate, windowNumber: window.windowNumber, context: nil, characters: "ㅋ", charactersIgnoringModifiers: "ㅋ", isARepeat: false, keyCode: 6)!
        app.postEvent(undo, atStart: false); pump(0.05)
        try check(state.objects == originalObjects, "Korean Command-Z still undoes neon after temporary zoom")
        flags(.command)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        try check(canvas.editingCursor === NSCursor.crosshair, "losing window focus clears the temporary Command cursor")
        print("PASS: \(checks) Command-drag zoom checks")
    }
    @MainActor static func pump(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        repeat {
            while let event = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) { NSApp.sendEvent(event) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        } while Date() < end
    }
}
