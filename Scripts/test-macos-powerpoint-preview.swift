import AppKit
import Foundation
import PDFKit
import QuickLookUI
import SwiftUI

private final class PowerPointProtocol: URLProtocol {
    nonisolated(unsafe) static var data = Data()
    nonisolated(unsafe) static var receivedCookie = ""
    nonisolated(unsafe) static var fileName = "preview.pptx"
    nonisolated(unsafe) static var mimeType = "application/vnd.openxmlformats-officedocument.presentationml.presentation"
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "powerpoint-preview.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.receivedCookie = request.value(forHTTPHeaderField: "Cookie") ?? ""
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [
            "Content-Type": Self.mimeType,
            "Content-Disposition": "inline; filename=\(Self.fileName)",
        ])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Pass a real, non-sensitive PPTX fixture as the first argument.
/// No server writes or user's application/cache files are touched.
@main struct PowerPointPreviewRegression {
    @MainActor static func main() throws {
        var checks = 0
        func check(_ passed: @autoclosure () -> Bool, _ message: String) throws {
            guard passed() else { throw NSError(domain: "PowerPointPreview", code: checks, userInfo: [NSLocalizedDescriptionKey: message]) }
            checks += 1; print("PASS \(checks): \(message)"); fflush(stdout)
        }
        let source = URL(string: "https://powerpoint-preview.test/api/artifacts/files/id")!
        let ppt = MacAttachmentQuickLookKind.powerPoint(fileExtension: "ppt")
        let pptx = MacAttachmentQuickLookKind.powerPoint(fileExtension: "pptx")
        try check(MacAttachmentQuickLookKind.detect(fileName: "발표.PPTX", sourceURL: source, mimeType: "application/octet-stream") == pptx, "case-insensitive PPTX filename")
        try check(MacAttachmentQuickLookKind.detect(fileName: "발표.ppt", sourceURL: source, mimeType: "") == ppt, "legacy PPT filename")
        try check(MacAttachmentQuickLookKind.detect(fileName: "id", sourceURL: source, mimeType: "application/vnd.ms-powerpoint; charset=binary") == ppt, "legacy PPT MIME with parameters")
        try check(MacAttachmentQuickLookKind.detect(fileName: "id", sourceURL: source, mimeType: "application/vnd.openxmlformats-officedocument.presentationml.presentation") == pptx, "PPTX MIME without filename extension")
        try check(MacAttachmentQuickLookKind.detect(fileName: "id", sourceURL: URL(string: "https://test/slide.PPTX?download=1")!, mimeType: "") == pptx, "source URL extension fallback")
        try check(MacAttachmentQuickLookKind.detect(fileName: "sheet.numbers", sourceURL: source, mimeType: "") == .numbers, "Numbers preview retained")
        try check(MacAttachmentQuickLookKind.detect(fileName: "doc.pdf", sourceURL: source, mimeType: "application/pdf") == nil, "PDF remains in PDF editor")
        try check(MacAttachmentQuickLookKind.detect(fileName: "archive.zip", sourceURL: source, mimeType: "application/zip") == nil, "unrelated attachments remain unchanged")
        try check(MacAttachmentQuickLookKind.handlesNavigation(URL(string: "https://test/deck.PPTX")!), "direct PPTX links intercepted")
        try check(!MacAttachmentQuickLookKind.handlesNavigation(source), "generic API URL handled by existing attachment path")
        let response = HTTPURLResponse(url: source, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/vnd.ms-powerpoint"])!
        try check(MacAttachmentQuickLookKind.handlesResponse(response), "extensionless PowerPoint HTTP response intercepted")

        var file: MacAttachmentQuickLookFile? = try MacAttachmentQuickLookFile(data: Data("test".utf8), fileName: "../unsafe/name", kind: pptx)
        let url = file!.url, parent = url.deletingLastPathComponent()
        try check(url.lastPathComponent == "..-unsafe-name.pptx", "safe preview filename and extension")
        let copied = try Data(contentsOf: url)
        try check(copied == Data("test".utf8), "temporary copy preserves original bytes")
        weak var weakFile = file
        file = nil
        try check(weakFile == nil && !FileManager.default.fileExists(atPath: parent.path), "temporary session directory cleaned up")

        guard CommandLine.arguments.count > 1 else { print("PASS: \(checks) checks; real PPTX UI test requires a fixture argument"); return }
        let fixtureURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let original = try Data(contentsOf: fixtureURL)
        PowerPointProtocol.data = original
        let ext = fixtureURL.pathExtension.lowercased()
        PowerPointProtocol.fileName = "preview.\(ext)"
        if ext == "ppt" { PowerPointProtocol.mimeType = "application/vnd.ms-powerpoint" }
        URLProtocol.registerClass(PowerPointProtocol.self)
        defer { URLProtocol.unregisterClass(PowerPointProtocol.self) }
        let app = NSApplication.shared; app.setActivationPolicy(.regular); app.finishLaunching()
        let window = NSWindow(contentRect: CGRect(x: 50, y: 100, width: 1000, height: 740), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: MacRemotePDFPreviewView(
            request: MacPDFRemoteRequest(url: source, cookieHeader: "fixture-auth=valid"), storesLocally: false,
            isContainerResizing: false, onClose: {}, onTogglePaneExpanded: {}
        ))
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        pump(4)
        func previews() -> [QLPreviewView] { descendants(host).compactMap { $0 as? QLPreviewView } }
        try check(previews().count == 1, "actual attachment load mounts embedded Quick Look")
        try check(!descendants(host).contains(where: { $0 is MacPDFEditingView }), "PowerPoint does not enter PDF editor/save path")
        try check(PowerPointProtocol.receivedCookie == "fixture-auth=valid", "authenticated attachment request retained")
        let preview = previews()[0]
        let loadedURL = (preview.previewItem as? NSURL).map { $0 as URL }
        try check(loadedURL?.pathExtension == ext, "Quick Look receives a typed local \(ext) URL")
        let loadedBytes = try loadedURL.map { try Data(contentsOf: $0) }
        try check(loadedBytes == original, "preview receives original PowerPoint, not converted PDF")
        window.setContentSize(CGSize(width: 1280, height: 850)); pump(1)
        try check(previews().first === preview && preview.bounds.width > 1000, "resize keeps same preview and fills enlarged slide")
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/private/tmp/nf-powerpoint-preview-\(ext).png"))
        }
        let after = try Data(contentsOf: fixtureURL)
        try check(after == original, "original fixture unchanged")
        window.close(); pump(0.2)
        print("PASS: \(checks) PowerPoint preview checks")
    }

    @MainActor static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
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
