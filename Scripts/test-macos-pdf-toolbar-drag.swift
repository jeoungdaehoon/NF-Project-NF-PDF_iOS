import AppKit
import PDFKit
import SwiftUI

/// Real window-space drag events; inspect native handle frames throughout each
/// run-loop turn, not only saved offsets. Uses temporary PDFs, no user data.
@main struct PDFToolbarDragRegression {
    @MainActor static func main() throws {
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nf-pdf-toolbar-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let pdf = PDFDocument(), page = PDFPage()
        page.setBounds(CGRect(x: 0, y: 0, width: 900, height: 1200), for: .mediaBox); pdf.insert(page, at: 0)
        let state = MacPDFEditorState(document: pdf, identifier: "toolbar", fileName: "fixture.pdf", sourceURL: URL(string: "https://unused.test/fixture.pdf"), directory: directory)
        state.paletteLocked = false; state.paletteDetached = false; state.alwaysShowPalette = false
        state.optionsTool = nil; state.toolbarOffset = .zero; state.toolbarScale = 1; state.verticalToolbar = false
        state.add(MacPDFObject(page: 0, kind: .shape, bounds: CGRect(x: 100, y: 200, width: 80, height: 60)))
        let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 1150, height: 850), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: MacPDFEditorView(state: state)); host.sizingOptions = []
        // Offscreen/non-activating: user focus changes must not cancel a test
        // drag midway through its synthetic event sequence.
        window.contentView = host; window.orderFront(nil); pump(0.6)
        defer { window.close() }
        guard let canvas = state.canvas else { throw CocoaError(.fileReadUnknown) }
        let objects = state.objects, undoCount = state.undoCount
        var checks = 0, recording = false, frames: [CGPoint] = []
        func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
            guard value() else {
                if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/private/tmp/nf-pdf-toolbar-drag-failed.png"))
                }
                throw NSError(domain: "PDFToolbarDrag", code: checks, userInfo: [NSLocalizedDescriptionKey: message])
            }
            checks += 1; print("PASS \(checks): \(message)"); fflush(stdout)
        }
        func handle() -> MacPDFToolbarDragHandle.HandleView {
            descendants(host).compactMap { $0 as? MacPDFToolbarDragHandle.HandleView }.first!
        }
        func center() -> CGPoint {
            let view = handle(); return view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        }
        func settle(_ seconds: TimeInterval = 0.035) {
            pump(seconds) { if recording { frames.append(center()) } }
        }
        func mouse(_ type: NSEvent.EventType, at point: CGPoint) {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: Date.timeIntervalSinceReferenceDate, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0.6)!
            app.postEvent(event, atStart: false); settle()
        }
        func same(_ lhs: CGPoint, _ rhs: CGPoint) -> Bool { abs(lhs.x - rhs.x) < 1.1 && abs(lhs.y - rhs.y) < 1.1 }
        func toolbarFrame() -> CGRect {
            let view = handle(), scale = CGFloat(state.toolbarScale)
            // AppKit can give an NSImageView intrinsic bounds taller than its
            // SwiftUI 30pt slot. Its center, not intrinsic minY, is the anchor.
            let center = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: canvas)
            let top = canvas.isFlipped ? center.y : canvas.bounds.height - center.y
            let fit = MacPDFToolbarLayout.availableSize(in: canvas.bounds.size, scale: scale)
            let size = state.verticalToolbar
                ? CGSize(width: 58, height: min(400, max(30, fit.height - 16)) + 16)
                : CGSize(width: min(720, max(32, fit.width - 16)) + 16, height: 52)
            return CGRect(x: center.x - (state.verticalToolbar ? 29 : 24) * scale, y: top - (state.verticalToolbar ? 23 : 26) * scale,
                          width: size.width * scale, height: size.height * scale)
        }
        for vertical in [false, true] {
            for scale in [0.7, 1.0, 1.5] {
                state.verticalToolbar = vertical; state.toolbarScale = scale; state.toolbarOffset = .zero; settle(0.15)
                let name = "\(vertical ? "vertical" : "horizontal") \(scale)x"
                let originalHandle = handle(), start = center(), saved = state.toolbarOffset
                frames = []; recording = true
                mouse(.leftMouseDown, at: start)
                var previous = start
                for step in 1...4 {
                    let pointer = CGPoint(x: start.x + CGFloat(step * 15), y: start.y + CGFloat(step * 25))
                    mouse(.leftMouseDragged, at: pointer)
                    let current = center()
                    try check(current.y > previous.y + 1, "\(name): drag advances without reversing to the previous position (start=\(start), previous=\(previous), current=\(current), key=\(window.isKeyWindow), hit=\(String(describing: host.hitTest(host.convert(start, from: nil)))), offset=\(state.toolbarOffset))")
                    previous = current
                    let still = center(); settle(0.06)
                    try check(same(center(), still), "\(name): holding the mouse still does not bounce/flicker")
                    try check(state.toolbarOffset == saved && handle() === originalHandle, "\(name): live drag neither publishes saved position nor recreates the handle")
                }
                let beforeRelease = center()
                mouse(.leftMouseUp, at: CGPoint(x: start.x + 60, y: start.y + 100)); settle(0.08)
                recording = false
                try check(same(center(), beforeRelease), "\(name): release commits once without snapping or double translation")
                try check(zip(frames, frames.dropFirst()).allSatisfy { $1.y >= $0.y - 1 }, "\(name): all sampled rendering frames stay monotonic during drag/release")
                let finalCenter = center()
                mouse(.leftMouseDown, at: finalCenter)
                mouse(.leftMouseDragged, at: CGPoint(x: finalCenter.x, y: finalCenter.y + 10000))
                mouse(.leftMouseUp, at: CGPoint(x: finalCenter.x, y: finalCenter.y + 10000))
                let topFrame = toolbarFrame()
                print("TOP \(name): \(topFrame), canvas: \(canvas.bounds.size), saved: \(state.toolbarOffset), handle: \(handle().convert(handle().bounds, to: canvas)), bounds: \(handle().bounds)"); fflush(stdout)
                try check(abs(topFrame.minY - MacPDFToolbarLayout.topInset) < 2, "\(name): toolbar reaches directly below the viewer header (\(topFrame), offset \(state.toolbarOffset))")
                if scale == 1, let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/private/tmp/nf-pdf-toolbar-\(vertical ? "vertical" : "horizontal")-top.png"))
                }
                let topCenter = center()
                mouse(.leftMouseDown, at: topCenter)
                mouse(.leftMouseDragged, at: CGPoint(x: topCenter.x, y: topCenter.y - 10000))
                mouse(.leftMouseUp, at: CGPoint(x: topCenter.x, y: topCenter.y - 10000))
                try check(abs(toolbarFrame().maxY - (canvas.bounds.height - MacPDFToolbarLayout.bottomInset)) < 2, "\(name): lower bound uses scaled toolbar height")
                try check(state.objects == objects && state.undoCount == undoCount && state.canvas === canvas, "\(name): moving toolbar preserves PDF canvas, edits and history")
                try check(abs(UserDefaults.standard.double(forKey: "nf.mac.pdf.toolbarY") - state.toolbarOffset.height) < 0.1, "\(name): only final normalized position is persisted")
            }
        }
        state.verticalToolbar = false; state.toolbarScale = 1; state.toolbarOffset = CGSize(width: -50000, height: -50000); settle(0.15)
        let boundedStart = center()
        mouse(.leftMouseDown, at: boundedStart)
        mouse(.leftMouseDragged, at: CGPoint(x: boundedStart.x + 30, y: boundedStart.y - 25))
        mouse(.leftMouseUp, at: CGPoint(x: boundedStart.x + 30, y: boundedStart.y - 25))
        try check(same(center(), CGPoint(x: boundedStart.x + 30, y: boundedStart.y - 25)), "old out-of-bounds saved offsets do not trap or jump the next drag")
        state.paletteLocked = true; settle(0.05)
        let lockedCenter = center(), lockedOffset = state.toolbarOffset
        mouse(.leftMouseDown, at: lockedCenter)
        mouse(.leftMouseDragged, at: CGPoint(x: lockedCenter.x + 50, y: lockedCenter.y + 40))
        mouse(.leftMouseUp, at: CGPoint(x: lockedCenter.x + 50, y: lockedCenter.y + 40))
        try check(same(center(), lockedCenter) && state.toolbarOffset == lockedOffset, "locked toolbar ignores all drag events")
        state.paletteLocked = false
        for vertical in [false, true] {
            state.verticalToolbar = vertical; state.toolbarScale = 1.5
            window.setContentSize(CGSize(width: 550, height: 620)); settle(0.2)
            let start = center(); mouse(.leftMouseDown, at: start)
            mouse(.leftMouseDragged, at: CGPoint(x: start.x + 10000, y: start.y + 10000))
            mouse(.leftMouseUp, at: CGPoint(x: start.x + 10000, y: start.y + 10000))
            let frame = toolbarFrame()
            try check(frame.minX >= 6 && frame.maxX <= canvas.bounds.width - 6 && abs(frame.minY - 4) < 2,
                      "\(vertical ? "vertical" : "horizontal"): 1.5x toolbar fits a narrow split pane and still reaches the top (\(frame), \(canvas.bounds.size))")
        }
        print("PASS: \(checks) toolbar drag/layout checks")
    }
    @MainActor static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
    @MainActor static func pump(_ seconds: TimeInterval, tick: (() -> Void)? = nil) {
        let end = Date().addingTimeInterval(seconds)
        repeat {
            while let event = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) { NSApp.sendEvent(event); tick?() }
            RunLoop.current.run(until: Date().addingTimeInterval(0.005)); tick?()
        } while Date() < end
    }
}
