import AppKit
import PDFKit
import SwiftUI
import WebKit

private struct PortalFixture: View {
    let state: MacPDFEditorState
    var body: some View {
        HStack(spacing: 0) {
            BrowserFixture().frame(width: 260)
            MacPDFEditorView(state: state)
        }
    }
}
private struct BrowserFixture: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView {
        let web = WKWebView()
        web.loadHTMLString("<textarea>PDF 옆 웹 입력</textarea>", baseURL: nil)
        return web
    }
    func updateNSView(_ view: WKWebView, context: Context) {}
}

/// Delivers shortcuts through NSApplication and its Edit menu, with a sibling
/// WKWebView. Unlike the old test, never forces canvas focus before each key.
@main struct PDFShortcutRegression {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular); app.finishLaunching()
        let menu = NSMenu(), editItem = NSMenuItem(), edit = NSMenu(title: "Edit")
        menu.addItem(editItem); editItem.submenu = edit
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        redo.keyEquivalentModifierMask = [.command, .shift]; app.mainMenu = menu
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nf-pdf-shortcuts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let pdf = PDFDocument(), page = PDFPage()
        page.setBounds(CGRect(x: 0, y: 0, width: 600, height: 800), for: .mediaBox); pdf.insert(page, at: 0)
        let state = MacPDFEditorState(document: pdf, identifier: "shortcuts", fileName: "fixture.pdf", sourceURL: URL(string: "https://unused.test/fixture.pdf"), directory: root)
        let window = NSWindow(contentRect: CGRect(x: 30, y: 50, width: 1250, height: 800), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: PortalFixture(state: state)); window.contentView = host
        window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true); pump(0.8)
        defer { window.close() }
        guard let canvas = state.canvas else { throw CocoaError(.fileReadUnknown) }
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
            guard value() else { throw NSError(domain: "PDFShortcut", code: checks, userInfo: [NSLocalizedDescriptionKey: message]) }
            checks += 1; print("PASS \(checks): \(message)"); fflush(stdout)
        }
        func key(_ characters: String, redo: Bool = false, modifiers: NSEvent.ModifierFlags = .command) {
            let flags: NSEvent.ModifierFlags = redo ? modifiers.union(.shift) : modifiers
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: Date.timeIntervalSinceReferenceDate, windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 6)!
            app.postEvent(event, atStart: false); pump(0.15)
        }
        func stroke(_ y: CGFloat) {
            let points: [(NSEvent.EventType, CGPoint)] = [(.leftMouseDown, CGPoint(x: 180, y: y)), (.leftMouseDragged, CGPoint(x: 280, y: y + 20)), (.leftMouseUp, CGPoint(x: 280, y: y + 20))]
            for (index, pair) in points.enumerated() {
                let event = NSEvent.mouseEvent(with: pair.0, location: canvas.convert(pair.1, to: nil), modifierFlags: [], timestamp: Date.timeIntervalSinceReferenceDate, windowNumber: window.windowNumber, context: nil, eventNumber: index, clickCount: 1, pressure: 0.6)!
                app.postEvent(event, atStart: false)
            }
            pump(0.15)
        }
        state.selectTool(.pen); stroke(220)
        let permanent = state.objects
        state.selectTool(.neon); state.neonType = .line; stroke(300); stroke(350)
        let neon = state.objects.filter(\.isTransient)
        try check(neon.count == 2 && window.firstResponder === canvas, "real drawing focuses PDF canvas and creates two neon strokes")
        key("z")
        try check(state.objects.filter(\.isTransient) == Array(neon.prefix(1)), "NSApplication/Edit menu Cmd+Z reaches PDF next to WKWebView")
        key("Z", redo: true)
        try check(state.objects.filter(\.isTransient) == neon, "NSApplication/Edit menu Shift+Cmd+Z restores neon")
        key("ㅋ")
        try check(state.objects.filter(\.isTransient) == Array(neon.prefix(1)), "Korean input-source physical Cmd+Z undoes neon")
        key("ㅋ", redo: true)
        try check(state.objects.filter(\.isTransient) == neon, "Korean input-source Shift+Cmd+Z restores neon")
        key("ㅋ", modifiers: [.command, .option])
        key("ㅋ", modifiers: [.command, .control])
        try check(state.objects.filter(\.isTransient) == neon, "Option/Control command combinations do not trigger PDF history")
        let picker = descendants(host).compactMap { $0 as? NSSegmentedControl }.first { $0.accessibilityIdentifier() == "pdf.neon.type" }!
        picker.selectedSegment = 1
        if let action = picker.action { _ = app.sendAction(action, to: picker.target, from: picker) }; pump(0.1)
        try check(window.firstResponder === canvas && state.neonType == .box, "type picker preserves canvas keyboard focus")
        key("ㅋ"); key("ㅋ", redo: true)
        try check(state.objects.filter(\.isTransient) == neon, "Korean shortcuts still work immediately after changing neon type")
        try check(state.objects.filter { !$0.isTransient } == permanent, "keyboard shortcuts preserve permanent PDF edits")
        let browser = descendants(host).compactMap { $0 as? WKWebView }.first!
        window.makeFirstResponder(browser); pump(0.1)
        try check(window.firstResponder !== canvas, "sibling web pane can own keyboard focus")
        let beforeBrowserKeys = state.objects
        key("ㅋ"); key("ㅋ", redo: true)
        try check(state.objects == beforeBrowserKeys, "web-pane shortcuts never undo or redo PDF neon")
        state.selectTool(.text); state.addVisibleObject(.text)
        canvas.beginTextEditing(state.selected!); pump(0.1)
        redo.keyEquivalent = "z"
        let textView = canvas.activeTextView!
        textView.undoManager?.removeAllActions()
        let originalText = textView.string
        textView.insertText(" test", replacementRange: NSRange(location: (originalText as NSString).length, length: 0))
        let editedText = textView.string
        // This bare NSApplication has no SwiftUI scene UndoRedoCommands. Bind
        // its test Edit menu to the native field editor's undo manager.
        edit.items[0].target = textView.undoManager; edit.items[0].action = #selector(UndoManager.undo)
        redo.target = textView.undoManager; redo.action = #selector(UndoManager.redo)
        let documentHistory = state.undoCount
        key("z")
        try check(textView.string == originalText && state.undoCount == documentHistory && window.firstResponder === textView, "native text input keeps its own undo without invoking PDF object undo")
        canvas.textUndo(redo: true)
        try check(textView.string == editedText, "native text input keeps its own redo: expected \(editedText), got \(textView.string), canRedo=\(textView.undoManager?.canRedo ?? false)")
        canvas.finishTextEditing()
        state.selectTool(.neon); state.clearNeon()
        key("ㅋ"); key("ㅋ", redo: true)
        try check(!state.objects.contains { $0.isTransient }, "cleared neon cannot be resurrected through application shortcuts")
        print("PASS: \(checks) application-level PDF shortcut checks")
    }
    @MainActor static func pump(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        repeat {
            while let event = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) { NSApp.sendEvent(event) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        } while Date() < end
    }
    @MainActor static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
}
