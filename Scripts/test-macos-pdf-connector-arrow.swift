import AppKit
import PDFKit

/// Synthetic fixtures only; does not open user files or persist user preferences.
@main
struct ConnectorArrowRegression {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nf-arrow-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else { throw NSError(domain: "ConnectorArrow", code: count, userInfo: [NSLocalizedDescriptionKey: message]) }; count += 1
        }
        func bitmap() -> (NSBitmapImageRep, CGContext) {
            let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 600, pixelsHigh: 480, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            let context = NSGraphicsContext(bitmapImageRep: image)!.cgContext
            context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: 600, height: 480))
            return (image, context)
        }
        let defaults = UserDefaults.standard
        let oldArguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(oldArguments, forName: UserDefaults.argumentDomain) }
        func fixture(_ saved: MacPDFStyle?) throws -> MacPDFEditorState {
            let options = saved.map { [MacPDFTool.connector.rawValue: $0] } ?? [:]
            defaults.setVolatileDomain(["nf.mac.pdf.toolOptions": try JSONEncoder().encode(options)], forName: UserDefaults.argumentDomain)
            let document = PDFDocument(), page = PDFPage(); page.setBounds(CGRect(x: 0, y: 0, width: 600, height: 480), for: .mediaBox); document.insert(page, at: 0)
            return MacPDFEditorState(document: document, identifier: UUID().uuidString, fileName: "arrows.pdf", directory: root.appendingPathComponent(UUID().uuidString))
        }
        let fresh = try fixture(nil), migrated = try fixture(MacPDFStyle())
        try check(fresh.connectionStyle.width == 1.5, "fresh connector uses thinner 1.5pt default")
        try check(migrated.connectionStyle.width == 1.5, "previous generic-width preference adopts thinner default")
        var custom = MacPDFStyle(); custom.width = 4; custom.stroke = .init(.systemRed); custom.arrow = false
        let customState = try fixture(custom)
        try check(customState.connectionStyle == custom, "custom width, color and no-arrow preference remain intact")
        let a = CGPoint(x: 80, y: 120)
        for route in ["straight", "elbow", "curve"] {
            for b in [CGPoint(x: 240, y: 120), CGPoint(x: 20, y: 120), CGPoint(x: 80, y: 240), CGPoint(x: 80, y: 20), CGPoint(x: 220, y: 220)] {
                for control in [nil, CGPoint(x: 160, y: 200), b] as [CGPoint?] {
                    let prior = MacPDFObjectRenderer.connectionArrowPrevious(from: a, to: b, route: route, control: control)
                    let dx = b.x - prior.x, dy = b.y - prior.y, distance = hypot(dx, dy)
                    try check(distance > 0.001, "\(route) ignores collapsed final segments")
                    for width in [1.5, 3.0, 12.0] {
                        let head = MacPDFObjectRenderer.connectionArrowhead(tip: b, previous: prior, width: width)!
                        let length = min(max(6, width * 5), distance * 0.8)
                        let center = CGPoint(x: b.x - dx / distance * length * 0.6, y: b.y - dy / distance * length * 0.6)
                        try check(head.contains(center), "\(route) filled triangular head has a solid interior")
                        try check(!head.contains(CGPoint(x: b.x + dx / distance, y: b.y + dy / distance)), "\(route) head ends at attached target")
                    }
                }
            }
        }
        try check(MacPDFObjectRenderer.connectionArrowhead(tip: a, previous: a, width: 1.5) == nil, "zero-length connection does not create arbitrary arrow")
        let state = try fixture(nil)
        let source = MacPDFObject(page: 0, kind: .shape, bounds: CGRect(x: 30, y: 180, width: 70, height: 60))
        let target = MacPDFObject(page: 0, kind: .shape, bounds: CGRect(x: 450, y: 300, width: 90, height: 60))
        var connector = MacPDFObject(page: 0, kind: .connector, bounds: state.document.page(at: 0)!.bounds(for: .mediaBox), sourceID: source.id, targetID: target.id)
        connector.style = .connectorDefault; connector.style.stroke = .init(.systemRed); connector.style.connectorRoute = "elbow"
        let objects = [source, target, connector]
        let (live, liveContext) = bitmap(), (committed, committedContext) = bitmap()
        MacPDFObjectRenderer.drawConnector(connector, objects: objects, context: liveContext)
        MacPDFObjectRenderer.draw(connector, objects: objects, context: committedContext)
        try check(Data(bytes: live.bitmapData!, count: live.bytesPerRow * live.pixelsHigh) == Data(bytes: committed.bitmapData!, count: committed.bytesPerRow * committed.pixelsHigh), "live preview and committed connector render identical pixels")
        state.objects = objects
        let exported = PDFDocument(data: state.exportPDF()!)!
        let (exportImage, exportContext) = bitmap()
        exported.page(at: 0)!.draw(with: .mediaBox, to: exportContext)
        // Quartz is y-up; bitmap pixel rows are indexed from the top.
        func red(_ image: NSBitmapImageRep, _ x: Int, _ y: Int) -> Bool {
            guard let color = image.colorAt(x: x, y: image.pixelsHigh - 1 - y)?.usingColorSpace(.deviceRGB) else { return false }
            return color.redComponent > 0.6 && color.greenComponent < 0.55 && color.blueComponent < 0.55
        }
        try check(red(committed, 442, 330), "arrowhead center is solid red, not a hollow V")
        try check(red(exportImage, 442, 330), "exported PDF retains solid triangular head")
        try check(!red(committed, 451, 330), "shaft does not extend beyond the arrow tip")
        connector.style.dashed = true
        let (dashed, dashedContext) = bitmap()
        MacPDFObjectRenderer.draw(connector, objects: objects, context: dashedContext)
        try check(red(dashed, 442, 330), "dashed shaft still has a solid arrowhead")
        let (proof, proofContext) = bitmap()
        for (index, route) in ["straight", "elbow", "curve"].enumerated() {
            var style = MacPDFStyle.connectorDefault; style.stroke = .init(index == 1 ? .systemRed : .systemBlue); style.connectorRoute = route
            proofContext.saveGState(); proofContext.scaleBy(x: 2, y: 2)
            MacPDFObjectRenderer.drawConnection(from: CGPoint(x: 25, y: 30 + index * 65), to: CGPoint(x: 270, y: 55 + index * 65), style: style, context: proofContext)
            proofContext.restoreGState()
        }
        try proof.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/private/tmp/nf-pdf-connector-arrow-proof.png"))
        print("PASS: \(count) connector default, filled-head, route, preview and exported-PDF checks")
    }
}
