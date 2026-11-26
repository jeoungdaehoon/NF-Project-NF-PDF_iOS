import AppKit
import Combine
import PDFKit
import SwiftUI
#if canImport(NF_macOS)
@testable import NF_macOS
#endif

/// Check the production canvas over an isolated stand-in for the portal body.
@main struct LiveDetailPDFSurfaceRegression {
    @MainActor static func main() throws {
        try testZoomQueue()
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
        var layoutUpdates = 0
        let observation = surface.$frame.dropFirst().sink { _ in layoutUpdates += 1 }
        guard let fixedFrame = surface.viewport else { throw failure("Live viewport missing.") }
        surface.update(.init(x: fixedFrame.x, y: fixedFrame.y, width: fixedFrame.width, height: fixedFrame.height,
                             scrollX: 42, scrollY: 96, scale: 1.5, zoom: 1.5, pageZoom: 1, contentWidth: 900, contentHeight: 750))
        guard layoutUpdates == 0, surface.zoomPercent.value == 150,
              surface.pagePoint(CGPoint(x: 108, y: 54), in: .zero, flipped: true) == CGPoint(x: 100, y: -100) else {
            throw failure("Zoom must update the overlay coordinates and percentage without re-laying out the editor.")
        }
        observation.cancel()
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

    static func testZoomQueue() throws {
        var queue = LiveDetailPDF.NativeZoomQueue()
        guard queue.enqueue(1.1) == 1.1 else { throw failure("The initial zoom must submit immediately.") }
        for step in 120...190 {
            guard queue.enqueue(Double(step) / 100) == nil else {
                throw failure("A zoom request bypassed the in-flight request.")
            }
        }
        guard queue.requested == 1.9, queue.complete() == 1.9, queue.complete() == nil, queue.requested == nil else {
            throw failure("Only the latest queued scale should be sent.")
        }
        guard queue.enqueue(0) == 0.1, queue.enqueue(2) == nil, queue.enqueue(0.1) == nil,
              queue.complete() == nil, queue.enqueue(.infinity) == nil else {
            throw failure("Returning to the in-flight scale should discard the outdated target.")
        }
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "LiveDetailPDFSurfaceRegression", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
