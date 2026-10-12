import AppKit
import PDFKit
import SwiftUI

@MainActor final class LibraryFixtureState: ObservableObject {
    @Published var isPresented = true
}
struct LibraryFixture: View {
    @ObservedObject var state: LibraryFixtureState
    let repository: MacPDFLocalStorageRepository
    let editorDirectory: URL
    var body: some View {
        Color.clear.sheet(isPresented: $state.isPresented) {
            MacPDFLibraryView(repository: repository, editorDirectory: editorDirectory)
                .frame(minWidth: 820, minHeight: 620)
        }
    }
}

/// Regression for the REAL list -> valid PDF -> repository notification ->
/// window close -> SwiftUI sheet teardown path, not a direct coordinator call.
@main struct PDFLibraryWindowRegression {
    @MainActor static var rowIDs: [String] = []
    @MainActor static func main() throws {
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        app.finishLaunching(); app.activate(ignoringOtherApps: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nf-library-regression-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = MacPDFLocalStorageRepository(directoryURL: root.appendingPathComponent("cache"))
        let pdf = PDFDocument(), page = PDFPage()
        page.setBounds(CGRect(x: 0, y: 0, width: 600, height: 800), for: .mediaBox); pdf.insert(page, at: 0)
        let data = pdf.dataRepresentation()!
        let first = try repository.createDocument(data: data, fileName: "목록 테스트 A.pdf")
        let second = try repository.createDocument(data: data, fileName: "목록 테스트 B.pdf")
        rowIDs = repository.documents().map(\.id)
        let state = LibraryFixtureState()
        let window = MacPDFViewerWindowState.makeWindow(title: "목록 선택 회귀 테스트")
        let host = NSHostingView(rootView: LibraryFixture(state: state, repository: repository, editorDirectory: root.appendingPathComponent("edits")))
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        pump(1)
        for index in 0..<6 {
            let document = index.isMultiple(of: 2) ? first : second
            try press("pdf.library.open.\(document.id)")
            pump(0.8)
            let viewers = app.windows.filter { $0.isVisible && $0.title == document.fileName }
            guard viewers.count == 1, let viewer = viewers.first, viewer.sheetParent == nil,
                  let content = viewer.contentView, findView(content, type: MacPDFEditingView.self) != nil else {
                throw NSError(domain: "LibraryRegression", code: 1, userInfo: [NSLocalizedDescriptionKey: "Real library selection did not open valid PDF: \(document.fileName), windows=\(app.windows.map(\.title))"])
            }
            for _ in 0..<5 { NotificationCenter.default.post(name: MacPDFLocalStorageRepository.didChangeNotification, object: nil); pump(0.05) }
            guard viewer.isVisible else { throw NSError(domain: "LibraryRegression", code: 2) }
            viewer.setContentSize(CGSize(width: 1200, height: 820)); pump(0.1)
            viewer.performClose(nil); pump(0.3)
            guard !viewer.isVisible else { throw NSError(domain: "LibraryRegression", code: 3) }
            print("PASS: actual library select/load/refresh/resize/close cycle \(index + 1)"); fflush(stdout)
        }
        try press("pdf.library.open.\(first.id)"); pump(0.7)
        window.makeKeyAndOrderFront(nil); window.attachedSheet?.makeKeyAndOrderFront(nil); pump(0.1)
        try press("pdf.library.close"); pump(1)
        guard !app.windows.contains(where: { $0.isVisible && $0.title == first.fileName }) else { throw NSError(domain: "LibraryRegression", code: 4) }
        state.isPresented = true; pump(0.5)
        try press("pdf.library.open.\(second.id)"); pump(0.7)
        guard app.windows.contains(where: { $0.isVisible && $0.title == second.fileName }) else { throw NSError(domain: "LibraryRegression", code: 5) }
        window.makeKeyAndOrderFront(nil); window.attachedSheet?.makeKeyAndOrderFront(nil); pump(0.1)
        try press("pdf.library.close"); pump(0.5); window.close(); pump(0.2)
        print("PASS: real library sheet teardown and reopen, no user cache modified")
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
    @MainActor static func attribute(_ object: NSObject, _ name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        return object.responds(to: selector) ? object.perform(selector)?.takeUnretainedValue() : nil
    }
    @MainActor static func find(_ object: NSObject, identifier: String, depth: Int = 0) -> NSObject? {
        guard depth < 35 else { return nil }
        if attribute(object, "accessibilityIdentifier") as? String == identifier { return object }
        var children = attribute(object, "accessibilityChildren") as? [NSObject] ?? []
        if let view = object as? NSView { children += view.subviews }
        for child in children { if let found = find(child, identifier: identifier, depth: depth + 1) { return found } }
        return nil
    }
    @MainActor static func press(_ identifier: String) throws {
        let control = NSApp.windows.filter(\.isVisible).compactMap { $0.contentView }.compactMap { find($0, identifier: identifier) }.first
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard let control, control.responds(to: selector) else {
            // SwiftUI List on macOS 15 exposes rows without the button identifier.
            // Dispatch an actual click to the fixture's visually verified row position.
            let id = identifier.replacingOccurrences(of: "pdf.library.open.", with: "")
            if identifier == "pdf.library.close", let sheet = NSApp.windows.first(where: { $0.isVisible && $0.sheetParent != nil }), let content = sheet.contentView {
                click(CGPoint(x: 30, y: content.isFlipped ? 24 : content.bounds.height - 24), in: content, window: sheet)
                return
            }
            if let row = rowIDs.firstIndex(of: id), let sheet = NSApp.windows.first(where: { $0.isVisible && $0.sheetParent != nil }), let content = sheet.contentView {
                let top = 132 + CGFloat(row) * 42
                let point = CGPoint(x: 180, y: content.isFlipped ? top : content.bounds.height - top)
                click(point, in: content, window: sheet); return
            }
            for window in NSApp.windows { print("WINDOW \(window.title), visible=\(window.isVisible), size=\(window.frame.size), sheet=\(window.sheetParent != nil)")
                if let host = window.contentView, let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/private/tmp/nf-library-regression-\(window.sheetParent == nil ? "root" : "sheet").png"))
                }
            }; fflush(stdout)
            throw NSError(domain: "LibraryRegression", code: 6, userInfo: [NSLocalizedDescriptionKey: "Missing list button \(identifier)"])
        }
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        let action = unsafeBitCast(control.method(for: selector), to: Press.self)
        guard action(control, selector) else { throw NSError(domain: "LibraryRegression", code: 7) }
    }
    @MainActor static func findView<T: NSView>(_ view: NSView, type: T.Type) -> T? {
        if let match = view as? T { return match }
        for child in view.subviews { if let result = findView(child, type: type) { return result } }
        return nil
    }
    @MainActor static func click(_ point: CGPoint, in content: NSView, window: NSWindow) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: content.convert(point, to: nil), modifierFlags: [], timestamp: Date.timeIntervalSinceReferenceDate,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0.5)!
            NSApp.postEvent(event, atStart: false)
        }
        pump(0.1)
    }
}
