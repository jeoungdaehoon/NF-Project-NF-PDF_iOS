import AppKit
import PDFKit
import SwiftUI
#if canImport(NF_macOS)
@testable import NF_macOS
#endif

private final class PreviewProtocol: URLProtocol {
    nonisolated(unsafe) static var pdf = Data()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "pane-preview.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/pdf", "Content-Disposition": "inline; filename=pane-test.pdf"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.pdf); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@MainActor private final class Fixture: ObservableObject {
    @Published var pane: CGRect? = CGRect(x: 900, y: 0, width: 700, height: 850)
    @Published var container: CGRect?
    var closeCount = 0
}
private struct PaneFixture: View {
    @ObservedObject var state: Fixture
    let request: MacPDFRemoteRequest
    let directory: URL
    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                Color.gray.opacity(0.15).frame(width: state.pane?.minX ?? 900)
                    .overlay(Text("반대쪽 화면 유지").padding(.top, 70), alignment: .top)
                Color.gray.opacity(0.25)
            }
            MacResizableRemotePDFPanel(request: request, storesLocally: false, onClose: { state.closeCount += 1 },
                paneBounds: state.pane, editorDirectory: directory, containerBounds: state.container)
        }.ignoresSafeArea()
    }
}


/// Actual PDF slide and real window-coordinate pointer events. No user PDFs.
@main struct PDFSlideResizeRegression {
    @MainActor static func main() throws {
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nf-pdf-resize-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory); URLProtocol.unregisterClass(PreviewProtocol.self) }
        let pdf = PDFDocument(), page = PDFPage()
        page.setBounds(CGRect(x: 0, y: 0, width: 600, height: 800), for: .mediaBox); pdf.insert(page, at: 0)
        PreviewProtocol.pdf = pdf.dataRepresentation()!; URLProtocol.registerClass(PreviewProtocol.self)
        let state = Fixture(); state.pane = nil
        let request = MacPDFRemoteRequest(url: URL(string: "https://pane-preview.test/resize.pdf")!, cookieHeader: nil)
        let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 1600, height: 850), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: PaneFixture(state: state, request: request, directory: directory)); host.sizingOptions = []
        window.contentView = host; window.orderFront(nil); pump(1.0)
        defer { window.close() }
        guard let canvas = descendants(host).compactMap({ $0 as? MacPDFEditingView }).first, let editor = canvas.editor else { throw CocoaError(.fileReadUnknown) }
        editor.add(MacPDFObject(page: 0, kind: .text, bounds: CGRect(x: 50, y: 100, width: 200, height: 50), text: "너비 조절 중 유지"))
        let objects = editor.objects, undoCount = editor.undoCount
        var checks = 0, frames: [CGFloat] = [], recording = false
        func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
            guard value() else { throw NSError(domain: "PDFSlideResize", code: checks, userInfo: [NSLocalizedDescriptionKey: message]) }
            checks += 1; print("PASS \(checks): \(message)"); fflush(stdout)
        }
        func panel() -> CGRect {
            var view: NSView? = canvas
            while let current = view {
                let frame = current.convert(current.bounds, to: host)
                if abs(frame.height - (host.bounds.height - MacPDFSlidePanelLayout.tabBarHeight)) < 1 { return frame }
                view = current.superview
            }
            return .zero
        }
        func settle(_ seconds: TimeInterval = 0.04) {
            pump(seconds) { if recording { frames.append(panel().width) } }
        }
        func mouse(_ type: NSEvent.EventType, _ point: CGPoint) {
            let event = NSEvent.mouseEvent(with: type, location: host.convert(point, to: nil), modifierFlags: [], timestamp: Date.timeIntervalSinceReferenceDate, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0.6)!
            app.postEvent(event, atStart: false); settle()
        }
        for pinned in [false, true] {
            if pinned { state.pane = CGRect(x: 800, y: 0, width: 800, height: 850); state.container = state.pane; settle(0.15) }
            let availableWidth: CGFloat = pinned ? 800 : 1600
            for delta: CGFloat in (pinned ? [20, -20] : [-20, 20]) {
                let initial = panel()
                try check(initial.width > 0, "find actual \(pinned ? "pinned" : "normal") PDF slide bounds")
                let start = CGPoint(x: initial.minX + 5, y: initial.midY)
                frames = []; recording = true
                mouse(.leftMouseDown, start)
                var previous = initial.width
                for step in 1...5 {
                    let point = CGPoint(x: start.x + delta * CGFloat(step), y: start.y)
                    mouse(.leftMouseDragged, point)
                    let expected = MacPDFSlidePanelLayout.width(preferredWidth: initial.width - delta * CGFloat(step), for: availableWidth)
                    try check(abs(panel().width - expected) < 1.1, "step \(step): boundary follows pointer 1:1, expected \(expected), got \(panel().width)")
                    try check(delta < 0 ? panel().width >= previous - 1 : panel().width <= previous + 1, "width never reverses during a directional drag")
                    let held = panel().width; mouse(.leftMouseDragged, point); settle(0.08)
                    try check(abs(panel().width - held) < 1.1, "holding the same pointer location does not bounce (held \(held), actual \(panel().width))")
                    previous = panel().width
                }
                let beforeRelease = panel().width
                mouse(.leftMouseUp, CGPoint(x: start.x + delta * 5, y: start.y)); settle(0.1)
                recording = false
                try check(abs(panel().width - beforeRelease) < 1.1, "release does not snap or apply drag twice")
                try check(zip(frames, frames.dropFirst()).allSatisfy { delta < 0 ? $1 >= $0 - 1 : $1 <= $0 + 1 }, "all sampled rendering frames stay monotonic")
                try check(canvas.editor === editor && editor.objects == objects && editor.undoCount == undoCount, "resize preserves PDF canvas, text edits and undo history")
            }
        }
        try check(state.closeCount == 0, "resizing never closes the attachment")
        print("PASS: \(checks) PDF slide resize checks")
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
