import AppKit
import PDFKit
import SwiftUI

/// Exercise toolbar actions in the same embedded host as the portal viewer.
/// Run in the isolated bundle prepared by test-macos-pdf-tool-popover.sh.
@main struct PDFToolPopoverRegression {
    @MainActor static func main() {
        do { try run() }
        catch {
            FileHandle.standardError.write(Data("FAIL: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    @MainActor static func run() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.finishLaunching(); app.activate(ignoringOtherApps: true)
        defer { if let domain = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: domain) } }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nf-tool-popover-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let pdf = PDFDocument(), page = PDFPage()
        page.setBounds(CGRect(x: 0, y: 0, width: 900, height: 1200), for: .mediaBox)
        pdf.insert(page, at: 0)
        let state = MacPDFEditorState(document: pdf, identifier: "popover", fileName: "도구 팝업 검증.pdf", directory: directory)
        state.paletteDetached = false; state.alwaysShowPalette = false
        state.paletteLocked = false; state.optionsTool = nil
        state.toolbarScale = 1; state.verticalToolbar = false; state.toolbarOffset = .zero
        let window = NSWindow(contentRect: CGRect(x: 200, y: 100, width: 1100, height: 780), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.title = "NF PDF 도구 팝업 회귀 테스트"
        window.isReleasedWhenClosed = false
        let presentation = MacPDFViewerWindowState()
        let host = NSHostingView(rootView: MacPDFMovableViewer(presentation: presentation,
            content: MacPDFEditorView(state: state, onTogglePaneExpanded: {})))
        window.contentView = host; window.makeKeyAndOrderFront(nil); pump(0.5)
        defer { state.optionsTool = nil; window.close() }
        guard let canvas = state.canvas else { throw CocoaError(.fileReadUnknown) }
        let originalObjects = state.objects, originalUndoCount = state.undoCount
        var checks = 0
        for vertical in [false, true] {
            for width in [1100.0, 550.0] {
                state.verticalToolbar = vertical; state.toolbarScale = width == 550 ? 1.5 : 0.8191959635416667
                state.toolbarOffset = CGSize(width: 0, height: -10000)
                window.setContentSize(CGSize(width: width, height: 780)); pump(0.15)
                try check(abs(canvas.bounds.width - width) < 2, "PDF viewport did not resize to \(width)")
                for tool in MacPDFTool.allCases {
                    let button = try findButton("pdf.tool.\(tool.rawValue)", in: host)
                    try press(button)
                    if state.optionsTool == nil { try press(findButton("pdf.toolOptions.toggle", in: host)) }
                    pump(0.2)
                    try check(state.optionsTool == state.tool, "Options did not open after selecting \(tool)")
                    try check(tool == .connector ? state.connectorEnabled : state.tool == tool, "Tool selection failed: \(tool)")
                    try check(app.windows.allSatisfy { !$0.isVisible || $0 === window }, "Tool \(tool) created an extra window")
                    let close = try findButton("pdf.toolOptions.close", in: host)
                    let closeCenter = close.convert(CGPoint(x: close.bounds.midX, y: close.bounds.midY), to: canvas)
                    try check(canvas.bounds.contains(closeCenter), "Settings are outside the PDF canvas: \(closeCenter)")
                    try press(close)
                    try check(state.optionsTool == nil, "Close did not dismiss the panel")
                    if tool == .connector { try press(button) }
                    try check(state.canvas === canvas && state.objects == originalObjects && state.undoCount == originalUndoCount,
                              "Tool selection replaced the canvas or affected document edits")
                    checks += 1
                    print("PASS: \(tool.rawValue), vertical=\(vertical), width=\(width)"); fflush(stdout)
                }
            }
        }
        state.verticalToolbar = false; state.toolbarScale = 1; state.toolbarOffset = .zero
        window.setContentSize(CGSize(width: 1100, height: 780)); pump(0.2)
        try press(findButton("pdf.tool.shape", in: host))
        try press(findButton("pdf.add.shape.rectangle", in: host))
        try check(state.objects.count == originalObjects.count + 1 && state.selected?.kind == .shape && state.optionsTool == nil,
                  "Rectangle insertion did not work from the in-view settings")
        try press(findButton("pdf.tool.text", in: host))
        try press(findButton("pdf.add.text", in: host))
        try check(state.objects.count == originalObjects.count + 2 && state.selected?.kind == .text && canvas.activeTextView != nil,
                  "Text insertion did not open the inline editor")
        try check(app.windows.allSatisfy { !$0.isVisible || $0 === window }, "Insertion opened a separate window")
        print("PASS: \(checks) embedded tool panel checks and shape/text insertion")
    }
    @MainActor static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "PDFToolPanel", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    @MainActor static func findButton(_ id: String, in host: NSView) throws -> NSButton {
        guard let button = descendants(host).compactMap({ $0 as? NSButton }).first(where: { $0.identifier?.rawValue == id }) else {
            throw NSError(domain: "PDFToolPanel", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing button \(id)"])
        }
        return button
    }
    @MainActor static func press(_ button: NSButton) throws {
        button.scrollToVisible(button.bounds); pump(0.04)
        guard let window = button.window else { throw CocoaError(.coderValueNotFound) }
        let location = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: Date.timeIntervalSinceReferenceDate, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
            NSApp.postEvent(event, atStart: false)
        }
        pump(0.12)
    }
    @MainActor static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
    @MainActor static func pump(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        repeat {
            while let event = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) { NSApp.sendEvent(event) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        } while Date() < end
    }
}
