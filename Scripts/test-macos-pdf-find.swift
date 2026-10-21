import AppKit
import PDFKit
import SwiftUI
import WebKit
#if canImport(NF_macOS)
@testable import NF_macOS
#endif

@MainActor private final class Fixture: ObservableObject {
    let editor: MacPDFEditorState
    @Published var expanded = false
    var toggles = 0
    init(editor: MacPDFEditorState) { self.editor = editor }
}
private final class FindWebView: WKWebView {
    var findCount = 0
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "f" { findCount += 1; return true }
        return super.performKeyEquivalent(with: event)
    }
}
private struct WebFixture: NSViewRepresentable {
    func makeNSView(context: Context) -> FindWebView {
        let web = FindWebView(); web.loadHTMLString("<textarea>다른 분할 영역</textarea>", baseURL: nil); return web
    }
    func updateNSView(_ view: FindWebView, context: Context) {}
}
private struct FindFixture: View {
    @ObservedObject var fixture: Fixture
    var body: some View {
        HStack(spacing: 0) {
            WebFixture().frame(width: fixture.expanded ? 180 : 260)
            MacPDFEditorView(state: fixture.editor, isPaneExpanded: fixture.expanded, onTogglePaneExpanded: {
                fixture.toggles += 1; fixture.expanded.toggle()
            })
        }
    }
}

/// Uses real PDF text, native search-field input and NSApplication key delivery.
/// No network, real user files, clipboard writes or real fullscreen Space.
@main struct PDFFindRegression {
    @MainActor static func main() throws {
        let app = NSApplication.shared; app.setActivationPolicy(.regular); app.finishLaunching()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nf-pdf-find-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = try makePDF()
        let editor = MacPDFEditorState(document: document, identifier: "find-fixture", fileName: "find-fixture.pdf", directory: directory)
        editor.add(MacPDFObject(page: 1, kind: .text, bounds: CGRect(x: 60, y: 300, width: 200, height: 60), text: "추가 메모 계약"))
        editor.add(MacPDFObject(page: 2, kind: .shape, bounds: CGRect(x: 60, y: 300, width: 200, height: 70), shape: .speechBubble, text: "말풍선 계약"))
        let fixture = Fixture(editor: editor)
        let window = NSWindow(contentRect: CGRect(x: 80, y: 100, width: 1240, height: 850), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: FindFixture(fixture: fixture)); host.sizingOptions = []
        window.contentView = host; window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true); pump(0.8)
        defer { editor.find.dismiss(restoreFocus: false); window.close() }
        guard let canvas = descendants(host).compactMap({ $0 as? MacPDFEditingView }).first else { throw CocoaError(.coderInvalidValue) }
        let find = editor.find
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
            guard value() else {
                if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/private/tmp/nf-pdf-find-failed.png"))
                }
                print("FIND DEBUG query=\(find.query) status=\(find.status) index=\(find.currentIndex) key=\(window.isKeyWindow) active=\(app.isActive) focusRequest=\(find.focusRequest) responder=\(String(describing: window.firstResponder)) fieldEditor=\(String(describing: find.field?.currentEditor()))"); fflush(stdout)
                throw NSError(domain: "PDFFind", code: checks, userInfo: [NSLocalizedDescriptionKey: message])
            }
            checks += 1; print("PASS \(checks): \(message)"); fflush(stdout)
        }
        func button(_ identifier: String) -> NSButton? { descendants(host).compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == identifier } }
        func press(_ identifier: String) throws { guard let button = button(identifier) else { throw CocoaError(.coderInvalidValue) }; button.performClick(nil); pump(0.2) }
        func key(_ text: String, code: UInt16, flags: NSEvent.ModifierFlags = .command) {
            app.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil); pump(0.08)
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
                app.postEvent(event, atStart: false)
            }
            pump(0.25)
        }
        func input(_ text: String) throws {
            guard let field = find.field, let textView = field.currentEditor() as? NSTextView else { throw CocoaError(.coderInvalidValue) }
            textView.insertText(text, replacementRange: NSRange(location: 0, length: (textView.string as NSString).length))
            NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: field)
            pump(0.5)
        }
        let originalObjects = editor.objects, undo = editor.undoCount
        let annotations = (0..<document.pageCount).map { document.page(at: $0)!.annotations.count }
        try check(button("pdf.find") != nil && button("pdf.expandPane") != nil, "PDF toolbar exposes search and pane expansion shortcuts")
        if let search = button("pdf.find"), let expand = button("pdf.expandPane") {
            let a = search.convert(search.bounds, to: nil), b = expand.convert(expand.bounds, to: nil)
            try check(a.maxX < b.minX && (0...18).contains(b.minX - a.maxX) && abs(a.midY - b.midY) < 2, "search sits immediately left of the right-pinned expand icon")
        }
        try check(!find.isPresented && find.field == nil, "search bar is hidden until explicitly requested")
        window.makeFirstResponder(canvas); key("f", code: 3)
        try check(find.isPresented && find.field?.currentEditor() === window.firstResponder, "application-level Cmd+F opens PDF search and focuses its native field")
        try input("계약")
        try check(find.query == "계약" && find.matches.count == 4 && !find.isSearching, "Korean query searches original PDF text plus added text and callouts")
        try check(find.matches.compactMap(\.selection).allSatisfy { $0.string == "계약" }, "PDF search ranges select the exact matching Korean text")
        try check(canvas.highlightedSelections?.count == 2, "native PDF matches receive view-only highlights")
        if let selection = find.matches[find.currentIndex].selection, let page = selection.pages.first {
            try check(canvas.convert(selection.bounds(for: page), from: page).intersects(canvas.bounds), "native search scrolls the actual matched text into the visible viewport")
        } else { try check(false, "initial native PDF result is available") }
        try check(find.field?.currentEditor() === window.firstResponder, "jumping to the first result does not steal typing focus")
        let first = find.currentIndex
        try press("pdf.find.next")
        try check(find.currentIndex == (first + 1) % 4, "next button advances the active match")
        try press("pdf.find.previous")
        try check(find.currentIndex == first, "previous button returns to the previous match")
        for _ in 0..<4 { find.advance() }
        try check(find.currentIndex == first, "result navigation wraps at the end of the document")
        let beforeReturn = find.currentIndex
        key("\r", code: 36, flags: [])
        try check(find.currentIndex == (beforeReturn + 1) % 4, "Return navigates to the next result without rerunning the query")
        key("\r", code: 36, flags: .shift)
        try check(find.currentIndex == beforeReturn, "Shift+Return navigates to the previous result")
        key("g", code: 5)
        try check(find.currentIndex == (beforeReturn + 1) % 4, "Cmd+G moves to the next PDF result")
        key("g", code: 5, flags: [.command, .shift])
        try check(find.currentIndex == beforeReturn, "Shift+Cmd+G moves to the previous PDF result")
        try check(editor.objects == originalObjects && editor.undoCount == undo && editor.tool != .select,
                  "search never changes PDF objects, edit history or the active editing tool")
        try check((0..<document.pageCount).map { document.page(at: $0)!.annotations.count } == annotations,
                  "search highlights are not saved as PDF annotations")
        try press("pdf.expandPane")
        try check(fixture.expanded && fixture.toggles == 1 && editor.canvas === canvas && find.query == "계약" && find.matches.count == 4,
                  "expand icon keeps its original action and preserves the same canvas/search session")
        try press("pdf.expandPane")
        try check(!fixture.expanded && fixture.toggles == 2 && find.isPresented, "collapse restores the layout without closing search")
        window.setContentSize(CGSize(width: 780, height: 720)); pump(0.3)
        try check(button("pdf.find")?.isHiddenOrHasHiddenAncestor == false && (find.field?.bounds.width ?? 0) >= 100, "search remains usable in a narrow resized viewer")
        window.setContentSize(CGSize(width: 1240, height: 850)); pump(0.2)
        find.present(); pump(0.2); try input("ALPHA")
        try check(find.matches.count == 2 && find.matches.compactMap(\.selection).allSatisfy { $0.string?.lowercased() == "alpha" }, "search is case-insensitive for Latin text")
        try input("문서에 없는 문구")
        try check(find.matches.isEmpty && find.status == "검색 결과 없음" && button("pdf.find.next")?.isEnabled == false, "no-result state disables result navigation")
        try input("")
        try check(find.matches.isEmpty && canvas.highlightedSelections?.isEmpty != false && find.status.isEmpty, "clearing the query removes search results and highlights")
        find.updateQuery("계약"); find.updateQuery("ALPHA"); find.updateQuery("조회"); pump(0.5)
        try check(find.matches.count == 1 && find.matches.first?.selection?.string == "조회", "rapid query changes discard cancelled searches")
        find.updateQuery("계", composing: true); pump(0.3)
        try check(!find.isSearching && find.matches.isEmpty, "in-progress Korean IME composition does not launch a stale search")
        find.updateQuery("계약"); pump(0.5)
        let objectIndex = find.matches.firstIndex { $0.objectID != nil }!
        while find.currentIndex != objectIndex { find.advance() }
        try check(find.currentObject?.text.contains("계약") == true && canvas.currentPage === document.page(at: find.currentObject!.page), "added-text matches navigate to the editable object's page")
        if let object = find.currentObject, let page = document.page(at: object.page) {
            try check(canvas.convert(object.bounds, from: page).intersects(canvas.bounds), "added-text result is visible after navigation")
        }
        let textObject = editor.objects.first { $0.kind == .text }!
        editor.selection = [textObject.id]; editor.updateSelected { $0.text = "수정 후 다른 문구" }; pump(0.5)
        try check(find.matches.count == 3 && find.matches.allSatisfy { $0.objectID != textObject.id }, "editing text while search is open refreshes and removes stale matches")
        editor.undo(); pump(0.5)
        try check(find.matches.count == 4, "undo restores searchable text and refreshes results")
        window.makeFirstResponder(find.field); key("\u{1b}", code: 53, flags: [])
        try check(!find.isPresented && !fixture.expanded && window.firstResponder === canvas && canvas.highlightedSelections?.isEmpty != false,
                  "Escape closes only search, clears highlights and restores PDF keyboard focus")
        let browser = descendants(host).compactMap { $0 as? FindWebView }.first!
        window.makeFirstResponder(browser); key("f", code: 3)
        try check(!find.isPresented && browser.findCount > 0, "Cmd+F in the other split web page is not intercepted by PDF search")
        window.makeFirstResponder(canvas); key("ㄹ", code: 3)
        try check(find.isPresented && find.field?.currentEditor() === window.firstResponder, "physical Cmd+F works with a Korean input source")
        try press("pdf.find.close"); try press("pdf.find")
        try check(find.isPresented && find.query == "계약", "search button reopens and retains the previous query")
        try input("계약"); key("\u{1b}", code: 53, flags: [])
        editor.selection = [textObject.id]; canvas.beginTextEditing(editor.selected!); pump(0.1)
        let liveText = canvas.activeTextView!
        liveText.insertText(" 편집", replacementRange: NSRange(location: (liveText.string as NSString).length, length: 0))
        key("f", code: 3)
        try check(find.isPresented && canvas.activeTextView == nil && editor.objects.first(where: { $0.id == textObject.id })?.text.hasSuffix(" 편집") == true,
                  "Cmd+F from an inline annotation text editor commits its input before focusing search")
        try input("ALPHA")
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/private/tmp/nf-pdf-find-ui.png"))
        }
        find.updateQuery("대기 중"); find.dismiss(); pump(0.3)
        try check(!find.isSearching && find.matches.isEmpty && !find.isPresented, "closing a pending search cancels it without repainting stale results")
        let blank = PDFDocument(); blank.insert(PDFPage(), at: 0)
        let blankState = MacPDFEditorState(document: blank, identifier: "blank-find", fileName: "image.pdf", directory: directory.appendingPathComponent("blank"))
        blankState.find.present(); blankState.find.updateQuery("계약"); pump(0.4)
        try check(blankState.find.status == "텍스트 없음", "image-only/empty PDF reports that there is no searchable text")
        blankState.find.dismiss(restoreFocus: false)
        print("PASS: \(checks) PDF search checks")
    }
    @MainActor static func makePDF() throws -> PDFDocument {
        let data = NSMutableData()
        var bounds = CGRect(x: 0, y: 0, width: 600, height: 700)
        let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &bounds, nil)!
        for text in ["계약 조회 Alpha alpha", "두번째 계약 안내", "종료 문서"] {
            context.beginPDFPage(nil); NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            text.draw(at: CGPoint(x: 60, y: 600), withAttributes: [.font: NSFont.systemFont(ofSize: 21), .foregroundColor: NSColor.black])
            NSGraphicsContext.restoreGraphicsState(); context.endPDFPage()
        }
        context.closePDF()
        guard let document = PDFDocument(data: data as Data) else { throw CocoaError(.coderInvalidValue) }
        return document
    }
    @MainActor static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
    @MainActor static func pump(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        repeat { autoreleasepool {
            while let event = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) { NSApp.sendEvent(event) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        } } while Date() < end
    }
}
