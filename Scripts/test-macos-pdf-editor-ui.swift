import AppKit
import PDFKit
import SwiftUI

/// Isolated native SwiftUI/PDFKit layout smoke test; no real app data/network.
@main
struct PDFEditorLayoutProof {
    @MainActor static func main() throws {
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("nf-pdf-ui-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let pdf = PDFDocument(), page = PDFPage(); page.setBounds(CGRect(x: 0, y: 0, width: 600, height: 800), for: .mediaBox); pdf.insert(page, at: 0)
        let state = MacPDFEditorState(document: pdf, identifier: "ui-fixture", fileName: "편집 예시.pdf", directory: temporary)
        state.add(MacPDFObject(page: 0, kind: .shape, bounds: CGRect(x: 70, y: 520, width: 150, height: 80), shape: .roundedRectangle))
        state.add(MacPDFObject(page: 0, kind: .text, bounds: CGRect(x: 330, y: 520, width: 200, height: 90), text: "화면 흐름 설명"))
        let ids = state.objects.map(\.id)
        state.add(MacPDFObject(page: 0, kind: .connector, bounds: page.bounds(for: .mediaBox), sourceID: ids[0], targetID: ids[1]))
        state.selection = []; state.tool = .shape
        let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 1100, height: 760), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: MacPDFEditorView(state: state)); window.contentView = host; window.orderFront(nil)
        for (width, name) in [(1100.0, "wide"), (550.0, "narrow"), (550.0, "baked")] {
            if name == "baked", let data = state.exportPDF(), let baked = PDFDocument(data: data) { state.document = baked; state.objects = []; state.canvas?.document = baked }
            window.setContentSize(CGSize(width: width, height: 760)); host.frame = CGRect(x: 0, y: 0, width: width, height: 760)
            host.layoutSubtreeIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            guard let canvas = state.canvas, canvas.bounds.width >= width - 2, canvas.bounds.height > 500, canvas.scaleFactor > 0.5 else { throw NSError(domain: "PDFUI", code: 1, userInfo: [NSLocalizedDescriptionKey: "PDF viewport/initial fit is incorrect: \(String(describing: state.canvas?.frame)) scale=\(state.canvas?.scaleFactor ?? 0), fit=\(state.canvas?.scaleFactorForSizeToFit ?? 0), crop=\(page.bounds(for: .cropBox)), media=\(page.bounds(for: .mediaBox)), docView=\(String(describing: state.canvas?.documentView?.frame))"]) }
            print("PDF viewport \(canvas.bounds.size), scale \(canvas.scaleFactor)")
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.fileWriteUnknown) }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
            try png.write(to: URL(fileURLWithPath: "/private/tmp/nf-macos-pdf-editor-\(name).png"))
        }
        window.close(); print("PASS: native PDF editor layout at 1100px and 550px")
    }
}
