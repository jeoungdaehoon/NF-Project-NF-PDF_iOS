import AppKit
import PDFKit
import QuickLookUI
import SwiftUI
#if canImport(NF_macOS)
@testable import NF_macOS
#endif

private final class SpreadsheetProtocol: URLProtocol {
    nonisolated(unsafe) static var data = Data()
    nonisolated(unsafe) static var name = "preview.csv"
    nonisolated(unsafe) static var mime = "text/csv; charset=utf-8"
    nonisolated(unsafe) static var cookies: [String] = []
    nonisolated(unsafe) static var methods: [String] = []
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "spreadsheet-preview.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.cookies.append(request.value(forHTTPHeaderField: "Cookie") ?? "")
        Self.methods.append(request.httpMethod ?? "GET")
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [
            "Content-Type": Self.mime, "Content-Disposition": "inline; filename=\(Self.name)",
        ])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@MainActor private final class SpreadsheetFixture: ObservableObject {
    @Published var request = MacPDFRemoteRequest(url: URL(string: "https://spreadsheet-preview.test/api/artifacts/files/csv")!, cookieHeader: "fixture-auth=valid")
    func open(_ id: String) { request = MacPDFRemoteRequest(url: URL(string: "https://spreadsheet-preview.test/api/artifacts/files/\(id)")!, cookieHeader: "fixture-auth=valid") }
}
private struct SpreadsheetHost: View {
    @ObservedObject var state: SpreadsheetFixture
    var body: some View {
        GeometryReader { geometry in
            let pane = CGRect(x: geometry.size.width / 2, y: 0, width: geometry.size.width / 2, height: geometry.size.height)
            ZStack {
                Color.black
                MacResizableRemotePDFPanel(request: state.request, storesLocally: false, onClose: {}, paneBounds: pane, containerBounds: pane)
            }
        }
    }
}

/// Loads real attachment views with fixture HTTP, never uploads or changes user documents.
@main struct SpreadsheetPreviewRegression {
    @MainActor static func main() throws {
        guard CommandLine.arguments.count > 1 else { throw CocoaError(.fileNoSuchFile) }
        let xlsxURL = URL(fileURLWithPath: CommandLine.arguments[1]), xlsx = try Data(contentsOf: xlsxURL)
        let csv = Data("이름,설명,금액\r\n홍길동,\"쉼표, 줄바꿈\r\n따옴표 \"\"포함\"\"\",00123\r\n".utf8)
        SpreadsheetProtocol.data = csv
        URLProtocol.registerClass(SpreadsheetProtocol.self)
        defer { URLProtocol.unregisterClass(SpreadsheetProtocol.self) }
        let app = NSApplication.shared; app.setActivationPolicy(.regular); app.finishLaunching()
        let state = SpreadsheetFixture()
        let window = NSWindow(contentRect: CGRect(x: 20, y: 100, width: 1400, height: 850), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: SpreadsheetHost(state: state)); host.sizingOptions = []
        window.contentView = host; window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true); pump(1)
        defer { window.close() }
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
            guard value() else {
                if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/private/tmp/nf-spreadsheet-preview-failed.png"))
                }
                throw NSError(domain: "SpreadsheetPreview", code: checks, userInfo: [NSLocalizedDescriptionKey: message])
            }
            checks += 1; print("PASS \(checks): \(message)"); fflush(stdout)
        }
        func table() -> MacCSVTableView? { descendants(host).compactMap { $0 as? MacCSVTableView }.first }
        let source = state.request.url
        try check(MacAttachmentQuickLookKind.handlesNavigation(URL(string: "https://test/table.CSV")!), "direct CSV navigation opens attachment preview")
        try check(MacAttachmentQuickLookKind.handlesNavigation(URL(string: "https://test/table.XLSX")!), "direct XLSX navigation opens attachment preview")
        try check(MacAttachmentQuickLookKind.detect(fileName: "data.XLSX", sourceURL: source, mimeType: "application/octet-stream") == .excel, "XLSX filename recognized")
        let excelMIME = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        try check(MacAttachmentQuickLookKind.detect(fileName: "id", sourceURL: source, mimeType: excelMIME) == .excel, "XLSX MIME recognized without filename extension")
        let response = HTTPURLResponse(url: source, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": excelMIME])!
        try check(MacAttachmentQuickLookKind.handlesResponse(response), "extensionless XLSX response opens preview")
        let csvResponse = HTTPURLResponse(url: source, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/csv"])!
        try check(MacAttachmentQuickLookKind.handlesResponse(csvResponse), "extensionless CSV response opens preview")
        guard let grid = table() else { throw NSError(domain: "SpreadsheetPreview", code: 100, userInfo: [NSLocalizedDescriptionKey: "CSV table did not load"]) }
        try check(grid.numberOfRows == 2 && grid.numberOfColumns == 4, "real HTTP CSV loads as native data rows plus row-number column")
        try check(grid.tableColumns.map(\.title) == ["행", "A", "B", "C"], "first CSV row remains data, not an assumed header")
        try check(grid.csvDocument?.rows[1] == ["홍길동", "쉼표, 줄바꿈\r\n따옴표 \"포함\"", "00123"], "native table retains complete decoded cell values")
        let cell = grid.view(atColumn: 2, row: 1, makeIfNecessary: true) as? NSTextField
        try check(cell?.isEditable == false && cell?.toolTip?.contains("따옴표 \"포함\"") == true, "CSV cells are read-only with full multiline value in tooltip")
        try check(!descendants(host).contains(where: { $0 is MacPDFEditingView || $0 is QLPreviewView }), "CSV avoids PDF editor and Office/Quick Look parsing")
        try check(grid.frame.width > 400 && grid.enclosingScrollView?.hasHorizontalScroller == true, "wide CSV has a real scrollable table")
        try snapshot(host, path: "/private/tmp/nf-csv-slide-preview.png")
        grid.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        let clipboard = NSPasteboard.general
        let saved = (clipboard.pasteboardItems ?? []).map { item in Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }) }
        window.makeFirstResponder(grid)
        let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8)!
        let copied = window.performKeyEquivalent(with: key)
        let copiedText = clipboard.string(forType: .string)
        clipboard.clearContents()
        clipboard.writeObjects(saved.map { values in let item = NSPasteboardItem(); values.forEach { item.setData($0.value, forType: $0.key) }; return item })
        try check(copied && copiedText == grid.csvDocument?.copiedRows(IndexSet(integer: 1)), "Cmd+C copies selected CSV row with full values")
        let before = grid.enclosingScrollView!.convert(grid.enclosingScrollView!.bounds, to: host)
        try check(before.minX >= 700, "CSV slide is confined to the selected right pane")
        try press(host, "attachment.viewer.quickLook.expandPane"); pump(0.4)
        let expanded = grid.enclosingScrollView!.convert(grid.enclosingScrollView!.bounds, to: host)
        try check(table() === grid && expanded.minX >= 700 && expanded.width > before.width + 100, "pane expansion reuses table and only fills selected pane")
        try check(grid.selectedRowIndexes == IndexSet(integer: 1), "expansion preserves row selection")
        window.setContentSize(CGSize(width: 1600, height: 900)); pump(0.4)
        try check(table() === grid && grid.enclosingScrollView!.convert(grid.enclosingScrollView!.bounds, to: host).minX >= 800, "window resize preserves table and pane boundary")

        SpreadsheetProtocol.data = xlsx; SpreadsheetProtocol.name = "preview.xlsx"; SpreadsheetProtocol.mime = excelMIME
        state.open("xlsx"); pump(4)
        let preview = descendants(host).compactMap { $0 as? QLPreviewView }.first
        try check(preview != nil && table() == nil, "same slide switches from CSV to real XLSX Quick Look preview")
        let previewURL = (preview?.previewItem as? NSURL).map { $0 as URL }
        try check(previewURL?.pathExtension == "xlsx", "XLSX preview gets typed temporary file")
        let bytes = try previewURL.map { try Data(contentsOf: $0) }
        try check(bytes == xlsx, "XLSX is previewed unmodified without PDF conversion")
        try check(!descendants(host).contains(where: { $0 is MacPDFEditingView }), "XLSX cannot accidentally save PDF bytes over the workbook")
        try snapshot(host, path: "/private/tmp/nf-xlsx-slide-preview.png")
        SpreadsheetProtocol.data = Data("a,\"unfinished".utf8); SpreadsheetProtocol.name = "invalid.csv"; SpreadsheetProtocol.mime = "text/csv"
        state.open("invalid"); pump(0.6)
        try check(table() == nil && !descendants(host).contains(where: { $0 is QLPreviewView }), "invalid CSV never leaves the previous workbook or table visible")
        // Standalone embedded SwiftUI hosts do not expose ContentUnavailableView's
        // virtual AX identifiers reliably. Inspect both completed states visually.
        try snapshot(host, path: "/private/tmp/nf-invalid-csv-slide-preview.png")
        SpreadsheetProtocol.data = Data(); SpreadsheetProtocol.name = "empty.csv"
        state.open("empty"); pump(0.5)
        try check(table() == nil, "empty CSV finishes with an empty state rather than a zero-column grid")
        try snapshot(host, path: "/private/tmp/nf-empty-csv-slide-preview.png")
        try check(SpreadsheetProtocol.cookies.allSatisfy { $0 == "fixture-auth=valid" }, "authenticated attachment cookies retained for every format")
        try check(SpreadsheetProtocol.methods.allSatisfy { $0 == "GET" }, "read-only preview never uploads or replaces a file")
        let after = try Data(contentsOf: xlsxURL)
        try check(after == xlsx, "original XLSX fixture unchanged")
        print("PASS: \(checks) spreadsheet attachment preview checks")
    }
    @MainActor static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    @MainActor static func snapshot(_ view: NSView, path: String) throws {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CocoaError(.fileReadUnknown) }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
    @MainActor static func attribute(_ object: NSObject, _ name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        return object.responds(to: selector) ? object.perform(selector)?.takeUnretainedValue() : nil
    }
    @MainActor static func find(_ object: NSObject, _ id: String) -> NSObject? {
        var visited = Set<ObjectIdentifier>()
        func walk(_ object: NSObject, depth: Int) -> NSObject? {
            guard depth < 40, visited.insert(ObjectIdentifier(object)).inserted else { return nil }
            if attribute(object, "accessibilityIdentifier") as? String == id { return object }
            var children = attribute(object, "accessibilityChildren") as? [NSObject] ?? []
            if let view = object as? NSView { children += view.subviews }
            for child in children { if let item = walk(child, depth: depth + 1) { return item } }
            return nil
        }
        return walk(object, depth: 0)
    }
    @MainActor static func press(_ host: NSView, _ id: String) throws {
        if let button = descendants(host).compactMap({ $0 as? NSButton }).first(where: { $0.identifier?.rawValue == id }) {
            button.performClick(nil); return
        }
        guard let item = find(host, id) else { throw CocoaError(.fileReadUnknown) }
        if let button = item as? NSButton { button.performClick(nil); return }
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard item.responds(to: selector) else { throw CocoaError(.fileReadUnknown) }
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        guard unsafeBitCast(item.method(for: selector), to: Press.self)(item, selector) else { throw CocoaError(.fileReadUnknown) }
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
