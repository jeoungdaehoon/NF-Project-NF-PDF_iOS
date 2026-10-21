import AppKit
import PDFKit
import SwiftUI
#if canImport(NF_macOS)
@testable import NF_macOS
#endif

private final class GapPDFProtocol: URLProtocol {
    nonisolated(unsafe) static var data = Data()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "pdf-top-gap.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/pdf"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private struct PaneFrames: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
@MainActor private final class GapFixture: ObservableObject {
    @Published var split = true
    @Published var destination = 1
    @Published var leftWidth: CGFloat = 650
    @Published var frames: [Int: CGRect] = [:]
    var closeCount = 0
}
private struct TabProbe: NSViewRepresentable {
    let pane: Int
    func makeNSView(context: Context) -> NSView {
        let view = NSView(); view.identifier = NSUserInterfaceItemIdentifier("fixture.tab.\(pane)")
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
}
private struct GapWorkspace: View {
    @ObservedObject var state: GapFixture
    let request: MacPDFRemoteRequest
    let directory: URL
    var body: some View {
        HSplitView {
            pane(0).frame(minWidth: 480, maxWidth: state.split ? state.leftWidth : .infinity)
            if state.split { pane(1).frame(minWidth: 480) }
        }
        .coordinateSpace(name: "gap.workspace")
        .ignoresSafeArea(.container, edges: .top)
        .onPreferenceChange(PaneFrames.self) { state.frames = $0 }
        .overlay(alignment: .trailing) {
            MacResizableRemotePDFPanel(request: request, storesLocally: false, onClose: { state.closeCount += 1 },
                                      paneBounds: state.split ? state.frames[state.destination] : nil,
                                      editorDirectory: directory,
                                      containerBounds: state.split ? (state.frames[state.destination] ?? .zero) : nil)
        }
    }
    private func pane(_ index: Int) -> some View {
        VStack(spacing: 0) {
            Color.black.frame(height: 32).overlay(TabProbe(pane: index))
            Color(nsColor: index == 0 ? .darkGray : .gray)
        }
        .ignoresSafeArea(.container, edges: .top)
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: PaneFrames.self, value: [index: proxy.frame(in: .named("gap.workspace"))])
            }
        }
    }
}

/// Real HSplitView + fullSizeContentView safe area + production PDF panel.
/// Never reads a user document or contacts a server. Unlike the earlier pane
/// fixture, measured pane origins are not hard-coded to zero.
@main struct PDFTopGapRegression {
    @MainActor static func main() throws {
        let app = NSApplication.shared; app.setActivationPolicy(.regular); app.finishLaunching()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nf-pdf-gap-\(UUID().uuidString)")
        let document = PDFDocument(), page = PDFPage()
        page.setBounds(CGRect(x: 0, y: 0, width: 600, height: 800), for: .mediaBox)
        document.insert(page, at: 0); GapPDFProtocol.data = document.dataRepresentation()!
        URLProtocol.registerClass(GapPDFProtocol.self)
        defer { URLProtocol.unregisterClass(GapPDFProtocol.self); try? FileManager.default.removeItem(at: directory) }
        let state = GapFixture()
        let request = MacPDFRemoteRequest(url: URL(string: "https://pdf-top-gap.test/fixture.pdf")!, cookieHeader: nil)
        let window = NSWindow(contentRect: CGRect(x: 40, y: 100, width: 1500, height: 850),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        let host = NSHostingView(rootView: GapWorkspace(state: state, request: request, directory: directory)); host.sizingOptions = []
        window.contentView = host; window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true); pump(1.2)
        defer { window.close() }
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else { throw NSError(domain: "PDFTopGap", code: checks, userInfo: [NSLocalizedDescriptionKey: message]) }
            checks += 1; print("PASS \(checks): \(message)"); fflush(stdout)
        }
        guard let canvas = descendants(host).compactMap({ $0 as? MacPDFEditingView }).first, let editor = canvas.editor else {
            throw NSError(domain: "PDFTopGap", code: 100, userInfo: [NSLocalizedDescriptionKey: "Fixture PDF did not load"])
        }
        func viewerFrame() -> CGRect? {
            descendants(host).first {
                let name = String(describing: type(of: $0))
                return name.contains("NSHostingView") && name.contains("MacRemotePDFPreviewView")
            }.map { $0.convert($0.bounds, to: host) }
        }
        func tabBottom() -> CGFloat? {
            descendants(host).first { $0.identifier?.rawValue == "fixture.tab.\(state.split ? state.destination : 0)" }
                .map { $0.convert($0.bounds, to: host).maxY }
        }
        func aligned() -> Bool {
            guard let frame = viewerFrame(), let bottom = tabBottom() else { return false }
            return abs(frame.minY - bottom) < 1 && abs(frame.maxY - host.bounds.maxY) < 1
        }
        func insidePane() -> Bool {
            guard let frame = viewerFrame(), let pane = state.frames[state.destination] else { return false }
            return frame.minX >= pane.minX - 1 && frame.maxX <= pane.maxX + 1
        }
        func toggleExpand() throws {
            guard let button = descendants(host).compactMap({ $0 as? NSButton }).first(where: { $0.accessibilityIdentifier() == "pdf.expandPane" }) else {
                throw NSError(domain: "PDFTopGap", code: 101, userInfo: [NSLocalizedDescriptionKey: "Missing pane expansion button"])
            }
            button.performClick(nil); pump(0.4)
        }
        try check(host.safeAreaInsets.top > 0 && (state.frames[1]?.minY ?? 0) > 0, "real HSplitView reproduces a nonzero AppKit titlebar safe-area pane origin")
        try check(aligned(), "right slide starts immediately below the actual tab bar and reaches the window bottom")
        try check(insidePane(), "right slide stays inside its selected page")
        editor.add(MacPDFObject(page: 0, kind: .text, bounds: CGRect(x: 70, y: 250, width: 200, height: 50), text: "편집 유지"))
        let ids = editor.objects.map(\.id), undo = editor.undoCount
        try toggleExpand()
        try check(aligned() && insidePane(), "expanded right PDF has no top gap and never overlaps the left page")
        try check(abs((viewerFrame()?.width ?? 0) - (state.frames[1]?.width ?? 1)) < 1, "expanded PDF fills the full selected pane width")
        state.leftWidth = 800; pump(0.4)
        try check(aligned() && insidePane(), "resizing the split divider preserves top and bottom alignment")
        state.destination = 0; pump(0.4)
        try check(aligned() && insidePane(), "left-pinned expanded PDF has the same gap-free alignment")
        try toggleExpand()
        try check(aligned() && insidePane(), "restoring the left slide size does not add another safe-area inset")
        window.setContentSize(CGSize(width: 1650, height: 950)); pump(0.4)
        try check(aligned() && insidePane(), "window resizing recalculates the full-height viewport")
        state.split = false; pump(0.4)
        try check(aligned(), "closing split keeps the single-page PDF directly below the tab bar")
        state.destination = 1; state.split = true; pump(0.4)
        try check(aligned() && insidePane(), "reopening split restores the right slide without a top gap")
        try check(canvas.editor === editor && editor.objects.map(\.id) == ids && editor.undoCount == undo && state.closeCount == 0,
                  "all layout transitions preserve the same PDF canvas, edits and undo history")
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/private/tmp/nf-pdf-top-gap-fixed.png"))
        }
        try check(MacPDFSlidePanelLayout.containerFrame(paneBounds: .zero, availableSize: host.bounds.size) == .zero,
                  "unmeasured pane remains hidden instead of opening in the wrong page")
        print("PASS: \(checks) real split-window top-gap checks")
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
