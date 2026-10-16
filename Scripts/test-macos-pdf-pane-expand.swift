import AppKit
import PDFKit
import SwiftUI

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
                paneBounds: state.pane, editorDirectory: directory)
        }.ignoresSafeArea()
    }
}

/// Actual production popup actions and stable PDF/editor host, with mock HTTP.
@main struct PDFPaneExpansionRegression {
    @MainActor static func main() throws {
        let app = NSApplication.shared; app.setActivationPolicy(.regular); app.finishLaunching()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nf-pdf-pane-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory); URLProtocol.unregisterClass(PreviewProtocol.self) }
        let pdf = PDFDocument(), page = PDFPage()
        page.setBounds(CGRect(x: 0, y: 0, width: 600, height: 800), for: .mediaBox); pdf.insert(page, at: 0)
        PreviewProtocol.pdf = pdf.dataRepresentation()!; URLProtocol.registerClass(PreviewProtocol.self)
        let state = Fixture(), request = MacPDFRemoteRequest(url: URL(string: "https://pane-preview.test/pane-test.pdf")!, cookieHeader: nil)
        let window = NSWindow(contentRect: CGRect(x: 20, y: 100, width: 1600, height: 850), styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        let host = NSHostingView(rootView: PaneFixture(state: state, request: request, directory: directory)); host.sizingOptions = []
        window.contentView = host; window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true); pump(1.2)
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
            guard value() else {
                for (index, item) in app.windows.filter(\.isVisible).enumerated() {
                    print("FAILED WINDOW \(index): \(item.frame)")
                    if let view = item.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: bitmap)
                        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/private/tmp/nf-pdf-pane-failed-\(index).png"))
                    }
                }
                fflush(stdout)
                throw NSError(domain: "PDFPane", code: checks, userInfo: [NSLocalizedDescriptionKey: message])
            }
            checks += 1; print("PASS \(checks): \(message)"); fflush(stdout)
        }
        guard let canvas = descendants(host).compactMap({ $0 as? MacPDFEditingView }).first, let editor = canvas.editor else {
            throw NSError(domain: "PDFPane", code: 100, userInfo: [NSLocalizedDescriptionKey: "Mock PDF did not load"])
        }
        editor.add(MacPDFObject(page: 0, kind: .text, bounds: CGRect(x: 60, y: 250, width: 300, height: 70), text: "분할 보기 편집 유지"))
        let objectIDs = editor.objects.map(\.id), undoCount = editor.undoCount
        func hasFrame(_ expected: CGRect) -> Bool {
            var current: NSView? = canvas
            while let view = current {
                let frame = view.convert(view.bounds, to: host)
                if abs(frame.minX - expected.minX) < 1 && abs(frame.minY - expected.minY) < 1 && abs(frame.width - expected.width) < 1 && abs(frame.height - expected.height) < 1 { return true }
                current = view.superview
            }
            return false
        }
        let normal = MacPDFSlidePanelLayout.frame(preferredWidth: nil, availableSize: host.bounds.size)
        try check(hasFrame(normal), "initial viewer uses normal resizable slide bounds")
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/private/tmp/nf-pdf-pane-square.png"))
            let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
            let corner = bitmap.colorAt(x: Int((normal.minX + 2) * scale), y: Int((normal.minY + 2) * scale))?.usingColorSpace(.deviceRGB)
            let header = bitmap.colorAt(x: Int((normal.minX + 24) * scale), y: Int((normal.minY + 2) * scale))?.usingColorSpace(.deviceRGB)
            try check(corner != nil && header != nil && abs(corner!.redComponent - header!.redComponent) < 0.02 && abs(corner!.greenComponent - header!.greenComponent) < 0.02 && abs(corner!.blueComponent - header!.blueComponent) < 0.02,
                "top-left PDF viewer corner is square and fully filled, not rounded/cut out")
        }
        try check(find("pdf.expandPane") != nil && find("pdf.download") != nil, "PDF toolbar exposes split-pane shortcut and download")
        func shortcutIsPinnedRight() -> Bool {
            guard let shortcut = find("pdf.expandPane") as? NSButton else { return false }
            let frame = shortcut.convert(shortcut.bounds, to: nil), canvasFrame = canvas.convert(canvas.bounds, to: nil)
            let rightInset = canvasFrame.maxX - frame.maxX
            print("Toolbar shortcut right inset: \(rightInset), button: \(frame), canvas: \(canvasFrame)")
            return (8...18).contains(rightInset)
        }
        if let shortcut = find("pdf.expandPane") as? NSButton, let download = find("pdf.download") as? NSButton {
            let shortcutFrame = shortcut.convert(shortcut.bounds, to: nil), downloadFrame = download.convert(download.bounds, to: nil)
            try check(shortcutFrame.minX > downloadFrame.maxX && shortcutIsPinnedRight(), "split-pane icon is pinned to the far right of the PDF toolbar")
        } else { try check(false, "toolbar controls must be native accessible buttons") }
        try press("pdf.expandPane"); pump(0.4)
        try check(hasFrame(MacPDFSlidePanelLayout.frame(preferredWidth: nil, availableSize: host.bounds.size, expandedPane: state.pane)), "toolbar shortcut fills the source split pane directly")
        try press("pdf.expandPane"); pump(0.4)
        try check(hasFrame(normal) && state.closeCount == 0, "toolbar shortcut toggles back without closing the document")
        try press("attachment.viewer.more"); pump(0.2)
        try check(find("attachment.viewer.expandPane") != nil || popupHost(height: 116) != nil, "popup has separate pane and monitor fullscreen actions")
        try press("attachment.viewer.expandPane"); pump(0.5)
        let expanded = MacPDFSlidePanelLayout.frame(preferredWidth: nil, availableSize: host.bounds.size, expandedPane: state.pane)
        try check(hasFrame(expanded) && expanded.minX == 900 && expanded.minY == 32, "fills only the source right pane, below the tab bar")
        try check(!window.styleMask.contains(.fullScreen) && canvas.window === window && !app.windows.contains(where: { $0 !== window && $0.isVisible && $0.styleMask.contains(.fullScreen) }), "pane action keeps the PDF in the same normal window, never a monitor-fullscreen window")
        try check(canvas.editor === editor && editor.objects.map(\.id) == objectIDs && editor.undoCount == undoCount, "same PDF canvas, edits and undo history survive expansion")
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/private/tmp/nf-pdf-pane-expanded.png"))
        }
        state.pane = CGRect(x: 1050, y: 0, width: 550, height: host.bounds.height); pump(0.3)
        try check(hasFrame(MacPDFSlidePanelLayout.frame(preferredWidth: nil, availableSize: host.bounds.size, expandedPane: state.pane)), "expanded viewer follows resized split divider")
        try check(shortcutIsPinnedRight(), "pane shortcut remains pinned right in a narrow resized pane")
        try press("attachment.viewer.back"); pump(0.5)
        try check(hasFrame(normal) && state.closeCount == 0, "exit button restores original slide size without closing")
        try press("attachment.viewer.more"); pump(0.2); try press("attachment.viewer.expandPane"); pump(0.4)
        try check(hasFrame(MacPDFSlidePanelLayout.frame(preferredWidth: nil, availableSize: host.bounds.size, expandedPane: state.pane)), "viewer is expanded before keyboard exit")
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: Date.timeIntervalSinceReferenceDate,
            windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        window.makeKeyAndOrderFront(nil); pump(0.15); window.makeFirstResponder(canvas)
        app.postEvent(escape, atStart: false); pump(0.4)
        try check(hasFrame(normal) && state.closeCount == 0, "Escape exits pane expansion instead of closing PDF")
        state.pane = CGRect(x: 0, y: 0, width: 650, height: host.bounds.height); pump(0.2)
        try press("attachment.viewer.more"); pump(0.2); try press("attachment.viewer.expandPane"); pump(0.4)
        try check(hasFrame(CGRect(x: 0, y: 32, width: 650, height: host.bounds.height - 32)), "left source pane uses its own bounds, never the right pane")
        state.pane = nil; pump(0.4)
        try check(hasFrame(normal), "closing split restores normal slide without reloading PDF")
        try check(find("pdf.expandPane") == nil, "toolbar pane shortcut is hidden when no split pane exists")
        try press("attachment.viewer.more"); pump(0.2)
        try check(find("attachment.viewer.expandPane") == nil && popupHost(height: 90) != nil, "pane expansion action is absent outside split mode")
        window.sendEvent(escape); pump(0.2)
        try check(editor.objects.map(\.id) == objectIDs && canvas.editor === editor, "all transitions preserve current edits")
        window.close(); pump(0.1)
        print("PASS: \(checks) pane expansion checks")
    }
    @MainActor static func pump(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        repeat { autoreleasepool {
            while let event = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) { NSApp.sendEvent(event) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        } } while Date() < end
    }
    @MainActor static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
    @MainActor static func attribute(_ object: NSObject, _ name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        return object.responds(to: selector) ? object.perform(selector)?.takeUnretainedValue() : nil
    }
    @MainActor static func find(_ identifier: String) -> NSObject? {
        var visited = Set<ObjectIdentifier>()
        func walk(_ object: NSObject, _ depth: Int) -> NSObject? {
            guard depth < 40, visited.insert(ObjectIdentifier(object)).inserted else { return nil }
            if attribute(object, "accessibilityIdentifier") as? String == identifier { return object }
            var children = attribute(object, "accessibilityChildren") as? [NSObject] ?? []
            if let view = object as? NSView { children += view.subviews }
            for child in children { if let found = walk(child, depth + 1) { return found } }
            return nil
        }
        return NSApp.windows.filter(\.isVisible).compactMap(\.contentView).compactMap { walk($0, 0) }.first
    }
    @MainActor static func press(_ identifier: String) throws {
        // Prefer real clicks: cached AX elements can outlive dismissed popovers.
        if ["attachment.viewer.more", "attachment.viewer.back"].contains(identifier),
           let view = NSApp.windows.filter(\.isVisible).compactMap(\.contentView).flatMap({ descendants($0) })
            .first(where: { String(describing: type(of: $0)).contains("NSHostingView") && String(describing: type(of: $0)).contains("MacRemotePDFPreviewView") }) {
            click(CGPoint(x: identifier.hasSuffix("more") ? view.bounds.width - 29 : 29, y: view.isFlipped ? 24 : view.bounds.height - 24), in: view)
            return
        }
        if identifier == "attachment.viewer.expandPane", let view = popupHost(height: 116) {
            click(CGPoint(x: view.bounds.midX, y: view.isFlipped ? 19 : view.bounds.height - 19), in: view)
            return
        }
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard let control = find(identifier), control.responds(to: selector) else {
            for (index, window) in NSApp.windows.filter(\.isVisible).enumerated() {
                print("DEBUG window \(index) \(window.frame)")
                if let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/private/tmp/nf-pdf-pane-debug-\(index).png"))
                }
            }
            fflush(stdout)
            throw NSError(domain: "PDFPane", code: 101, userInfo: [NSLocalizedDescriptionKey: "Missing control: \(identifier)"])
        }
        if let button = control as? NSButton {
            guard button.isEnabled else { throw NSError(domain: "PDFPane", code: 103) }
            button.performClick(nil); return
        }
        typealias Action = @convention(c) (AnyObject, Selector) -> Bool
        let perform = unsafeBitCast(control.method(for: selector), to: Action.self)
        guard perform(control, selector) else { throw NSError(domain: "PDFPane", code: 102) }
    }
    @MainActor static func popupHost(height: CGFloat) -> NSView? {
        for window in NSApp.windows.sorted(by: { $0.windowNumber > $1.windowNumber }) where window.isVisible && window.frame.width < 300 {
            guard let content = window.contentView else { continue }
            for view in descendants(content) {
                if String(describing: type(of: view)).contains("NSHostingView"),
                   abs(view.bounds.width - 210) < 1, abs(view.bounds.height - height) < 1 { return view }
            }
        }
        return nil
    }
    @MainActor static func click(_ point: CGPoint, in view: NSView) {
        guard let window = view.window else { return }
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: Date.timeIntervalSinceReferenceDate,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0.5)!
            NSApp.postEvent(event, atStart: false)
        }
        pump(0.1)
    }
}
