import AppKit
import PDFKit
import SwiftUI
@testable import NF_macOS

@main struct PDFExternalLinkRegression {
    @MainActor static func main() async throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let origin = URL(string: "https://example.org")!
        let videoID = "M7lc1UVf-VE"
        let addresses = [
            "https://www.youtube.com/watch?v=\(videoID)&t=25",
            "https://youtu.be/\(videoID)/?si=share",
            "https://m.youtube.com/shorts/\(videoID)",
            "https://www.youtube.com/live/\(videoID)"
        ]
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else { throw NSError(domain: "PDFExternalLinkRegression", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
            print("PASS: \(message)")
        }
        for address in addresses {
            let link = PDFExternalLink(address)
            try check(link?.isYouTube == true && link?.url.absoluteString == address, "YouTube route preserves its original URL: \(address)")
        }
        let shorts = PDFExternalLink(addresses[2])!
        let shortSize = shorts.popupSize(width: 550, height: 650, header: 37)
        let landscapeSize = PDFExternalLink(addresses[0])!.popupSize(width: 550, height: 650, header: 37)
        try check(shortSize.width < shortSize.height && landscapeSize.width > landscapeSize.height, "shorts and landscape videos use distinct popup proportions")
        try check(PDFExternalLink("https://youtube.com.example.org/watch?v=\(videoID)")?.kind == .page
                  && PDFExternalLink("https://example.org/sample.MP4?download=0")?.kind == .video,
                  "web host and direct video detection match Android")
        try check(["http://example.org", "https://user@example.org", "javascript:alert(1)", "https://example.org:65536",
                   "https://example.org/a b"].allSatisfy { PDFExternalLink($0) == nil }, "invalid and non-HTTPS input is rejected")
        try check(shorts.playerHTML(origin: origin)?.contains("/embed/\(videoID)?enablejsapi=1") == true, "YouTube uses the inline iframe player")

        let archive = FileManager.default.temporaryDirectory.appendingPathComponent("nf-pdf-link-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: archive) }
        let data = NSMutableData()
        var pageBounds = CGRect(x: 0, y: 0, width: 900, height: 750)
        let drawing = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &pageBounds, nil)!
        drawing.beginPDFPage(nil)
        drawing.setFillColor(NSColor.systemPurple.cgColor)
        drawing.fill(pageBounds)
        drawing.endPDFPage()
        drawing.closePDF()
        let document = PDFDocument(data: data as Data)!
        let editor = MacPDFEditorState(document: document, identifier: "external", fileName: "fixture.pdf", directory: archive)
        let notes = PDFNoteWorkspaceState(origin: origin)
        let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 950, height: 640),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: PDFNoteWorkspace(state: notes, enabled: true) {
            MacPDFCanvas(state: editor, freeNotes: notes)
        })
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        notes.activate(document, source: nil, localID: "external", note: nil, popupLayoutDirectory: archive)
        try await Task.sleep(for: .milliseconds(240))
        guard let canvas = editor.canvas, let page = document.page(at: 0) else { throw CocoaError(.fileReadUnknown) }
        let viewport = canvas.bounds
        let pageFrame = canvas.convert(pageBounds, from: page).intersection(viewport)
        let webPoint = CGPoint(x: pageFrame.midX - 100, y: pageFrame.midY)
        let webAddress = "https://example.com/?test=one&next=two#anchor"
        notes.selectWebLinkTool()
        try check(notes.webLinkTool && notes.placeDocument(at: webPoint) && notes.pendingArea?.isWebLink == true,
                  "the link tool places its marker and opens the address entry")
        notes.selectExternalLink(PDFExternalLink(webAddress)!)
        guard let web = notes.anchors(on: page).first, let openedWeb = notes.sessions.first else { throw CocoaError(.fileReadUnknown) }
        try check(web.markerStyle.icon == "link" && openedWeb.externalLink?.url.absoluteString == webAddress && !notes.documentTool,
                  "the full web URL is embedded in the shared NF marker")
        notes.mode(.split, for: web.id)
        try check(notes.sessions.first?.mode == .split, "web links can use split view")
        await notes.close(web.id, animated: false)
        notes.openMarker(web)
        try check(notes.sessions.first?.mode == .split, "reopening a web marker restores its view mode")
        await notes.close(web.id, animated: false)

        notes.selectWebLinkTool()
        try check(notes.placeDocument(at: CGPoint(x: pageFrame.midX + 100, y: pageFrame.midY)), "a second marker can be placed")
        notes.selectExternalLink(shorts)
        guard let video = notes.anchors(on: page).first(where: { $0.externalLink?.isYouTube == true }) else { throw CocoaError(.fileReadUnknown) }
        try check(video.markerStyle.icon == "play.rectangle" && notes.sessions.first?.externalLink == shorts, "a YouTube marker opens the player card")
        notes.mode(.split, for: video.id)
        try check(notes.sessions.first?.mode == .popup, "YouTube stays in video popup mode")
        let exported = editor.exportPDF().flatMap(PDFDocument.init(data:))
        let exportedLinks = exported?.page(at: 0)?.annotations.compactMap(PDFDocumentMarkerAppearance.linkURL) ?? []
        try check(exportedLinks.count == 2 && exportedLinks.allSatisfy { $0.path == "/pdf-free-note" },
                  "PDF export keeps both Android-compatible annotations")
        if let exportedPage = exported?.page(at: 0) {
            let links = notes.anchors(on: exportedPage).compactMap(\.externalLink)
            try check(links.contains(shorts) && links.contains(PDFExternalLink(webAddress)!), "both URLs survive PDF export and reload")
        }
        await notes.close(video.id, animated: false)
        try await Task.sleep(for: .milliseconds(160))
        guard let image = notes.screenShare.capture() else { throw CocoaError(.fileReadUnknown) }
        try check(image.size == notes.screenShare.anchor?.bounds.size && image.size.width > 1 && image.size.height > 1,
                  "screen sharing captures only the visible PDFView region")
        guard let bitmap = image.representations.first as? NSBitmapImageRep else { throw CocoaError(.fileReadUnknown) }
        let purple = (1..<10).contains { x in
            (1..<10).contains { y in
                guard let color = bitmap.colorAt(x: x * bitmap.pixelsWide / 10, y: y * bitmap.pixelsHigh / 10)?.usingColorSpace(.sRGB) else { return false }
                return color.blueComponent > color.greenComponent + 0.18 && color.redComponent > color.greenComponent + 0.1
            }
        }
        try check(purple, "the shared screen image includes the actual PDF page pixels")
    }
}
