import AppKit
import PDFKit
import SwiftUI
#if canImport(NF_macOS)
@testable import NF_macOS
#endif

/// Check the production canvas over an isolated stand-in for the portal body.
@main struct LiveDetailPDFSurfaceRegression {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nf-live-pdf-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let surface = MacPDFLiveSurface()
        try surface.open(directory: directory, legacy: Data())
        let source = Color(red: 0.9, green: 0.18, blue: 0.12)
        let host = NSHostingView(rootView: source.overlay(alignment: .topLeading) { MacPDFLiveEditor(surface: surface) })
        let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 720, height: 420),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }

        for size in [CGSize(width: 720, height: 420), CGSize(width: 500, height: 340)] {
            surface.update(.init(x: 0, y: 0, width: size.width, height: size.height, scrollX: 0, scrollY: 0,
                                 scale: 1, zoom: 1, pageZoom: 1, contentWidth: size.width, contentHeight: size.height))
            window.setContentSize(size)
            RunLoop.current.run(until: Date().addingTimeInterval(0.35))
            host.layoutSubtreeIfNeeded()
            guard let canvas = surface.editor?.canvas, canvas.bounds.width >= size.width - 1,
                  canvas.subviews.compactMap({ $0 as? NSScrollView }).allSatisfy(\.isHidden),
                  canvas.subviews.contains(where: { $0 is MacPDFDrawingOverlay && !$0.isHidden }),
                  let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                throw failure("Live PDF canvas or drawing layer is missing.")
            }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            guard let color = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB),
                  color.redComponent > 0.7, color.greenComponent < 0.45, color.blueComponent < 0.4 else {
                throw failure("The live PDF canvas obscures the portal body.")
            }
        }
        let attachment = MacPDFEditingView(frame: CGRect(x: 0, y: 0, width: 500, height: 340))
        let attachmentPDF = PDFDocument()
        attachmentPDF.insert(PDFPage(), at: 0)
        attachment.document = attachmentPDF
        attachment.layoutSubtreeIfNeeded()
        guard attachment.subviews.contains(where: { $0 is NSScrollView && !$0.isHidden }) else {
            throw failure("The attachment PDF canvas lost its scroll view.")
        }
        print("PASS: live PDF canvas shows the portal body after resize and attachment PDFs retain PDFKit scrolling")
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "LiveDetailPDFSurfaceRegression", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
