import AppKit
import PDFKit

/// Regression fixtures for bottom-entry/right-entry connectors reported by user.
/// All data is synthetic and kept in a unique temporary directory.
@main
struct ConnectorBoundaryRegression {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nf-connector-boundaries-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else { throw NSError(domain: "ConnectorBoundary", code: count, userInfo: [NSLocalizedDescriptionKey: message]) }; count += 1
        }
        func bitmap() -> (NSBitmapImageRep, CGContext) {
            let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 720, pixelsHigh: 600, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            let context = NSGraphicsContext(bitmapImageRep: image)!.cgContext
            context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: 720, height: 600))
            return (image, context)
        }
        let anchors = MacPDFEditingView.connectionAnchors.map { MacPDFPoint($0) }
        var source = MacPDFObject(page: 0, kind: .shape, bounds: CGRect(x: 440, y: 440, width: 170, height: 65))
        var target = MacPDFObject(page: 0, kind: .shape, bounds: CGRect(x: 70, y: 220, width: 170, height: 120))
        source.style.stroke = .init(.black); target.style.stroke = .init(.black)
        func connection(_ source: MacPDFObject, _ target: MacPDFObject, _ from: MacPDFPoint, _ to: MacPDFPoint, guide: CGPoint? = nil, width: Double = 1.5, route: String = "elbow") -> MacPDFObject {
            var connector = MacPDFObject(page: 0, kind: .connector, bounds: CGRect(x: 0, y: 0, width: 720, height: 600), sourceID: source.id, targetID: target.id)
            connector.sourceAnchor = from; connector.targetAnchor = to; connector.style = .connectorDefault
            connector.style.stroke = .init(.systemRed); connector.style.width = width; connector.style.connectorRoute = route
            if let guide {
                let (a, b) = MacPDFObjectRenderer.endpoints(connector, objects: [source, target])!
                connector.connectorOffset = MacPDFPoint(CGPoint(x: guide.x - (a.x + b.x) / 2, y: guide.y - (a.y + b.y) / 2))
            }
            return connector
        }
        let bottom = connection(source, target, anchors[3], anchors[1], guide: CGPoint(x: 525, y: 140))
        let side = connection(source, target, anchors[3], anchors[1], guide: CGPoint(x: 450, y: 280))
        let bottomGeometry = MacPDFConnectorGeometry.make(bottom, objects: [source, target])!
        let sideGeometry = MacPDFConnectorGeometry.make(side, objects: [source, target])!
        try check(bottomGeometry.targetAnchor == anchors[3] && bottomGeometry.tip.y < target.bounds.minY, "below-box route lands below target, not along right border")
        try check(bottomGeometry.previous.y < bottomGeometry.tip.y && abs(bottomGeometry.previous.x - bottomGeometry.tip.x) < 0.001, "bottom-entry arrow points upward into bottom face")
        try check(sideGeometry.targetAnchor == anchors[1] && sideGeometry.tip.x > target.bounds.maxX, "side route lands outside right border")
        try check(sideGeometry.previous.x > sideGeometry.tip.x && abs(sideGeometry.previous.y - sideGeometry.tip.y) < 0.001, "right-entry arrow points left at target right face")
        for geometry in [bottomGeometry, sideGeometry] {
            for index in 1..<geometry.points.count - 1 {
                let a = geometry.points[index - 1], b = geometry.points[index], c = geometry.points[index + 1]
                try check((b.x - a.x) * (c.x - b.x) + (b.y - a.y) * (c.y - b.y) >= -0.001, "middle grip and port stubs never double back into dangling tails")
            }
        }
        for rotation in [0.0, 0.45, Double.pi / 2] {
            source.rotation = rotation; target.rotation = -rotation
            for route in ["straight", "elbow", "curve"] {
                for from in anchors {
                    for to in anchors {
                        for width in [1.5, 6.0, 12.0] {
                            let connector = connection(source, target, from, to, width: width, route: route)
                            let objects = [source, target, connector], geometry = MacPDFConnectorGeometry.make(connector, objects: objects)!
                            let sourceEdge = MacPDFObjectRenderer.anchor(source, geometry.sourceAnchor)
                            let targetEdge = MacPDFObjectRenderer.anchor(target, geometry.targetAnchor)
                            try check(hypot(geometry.tip.x - targetEdge.x, geometry.tip.y - targetEdge.y) > target.style.width * 0.5, "\(route) width \(width) arrow clears target border at rotation \(rotation)")
                            try check(hypot(geometry.points[0].x - sourceEdge.x, geometry.points[0].y - sourceEdge.y) > source.style.width * 0.5, "source departure clears border")
                            for index in 1..<geometry.points.count {
                                for object in [source, target] {
                                    let a = MacPDFConnectorGeometry.local(geometry.points[index - 1], object: object), b = MacPDFConnectorGeometry.local(geometry.points[index], object: object)
                                    try check(!MacPDFConnectorGeometry.crosses(a, b, rect: object.bounds), "route segments avoid connected box interiors")
                                }
                            }
                            let normal = MacPDFConnectorGeometry.normal(target, geometry.targetAnchor)
                            let delta = CGPoint(x: geometry.tip.x - geometry.previous.x, y: geometry.tip.y - geometry.previous.y)
                            try check(delta.x * normal.dx + delta.y * normal.dy < 0 && abs(delta.x * normal.dy - delta.y * normal.dx) < 0.001, "final arrow is perpendicular and faces target")
                            let head = MacPDFObjectRenderer.connectionArrowhead(tip: geometry.tip, previous: geometry.previous, width: width)!
                            for corner in [CGPoint(x: head.boundingBox.minX, y: head.boundingBox.minY), CGPoint(x: head.boundingBox.maxX, y: head.boundingBox.maxY)] {
                                try check(!target.bounds.contains(MacPDFConnectorGeometry.local(corner, object: target)), "arrowhead stays outside target")
                            }
                        }
                    }
                }
            }
        }
        source.rotation = 0; target.rotation = 0
        let nearGuide = CGPoint(x: 20, y: target.bounds.midY + 1)
        let near = connection(source, target, anchors[3], anchors[0], guide: nearGuide, width: 3)
        let nearGeometry = MacPDFConnectorGeometry.make(near, objects: [source, target])!
        try check(abs(nearGeometry.controlPoint.y - nearGeometry.tip.y) < 0.001, "near-horizontal guide snaps to the target row rather than adding a one-point stair step")
        try check(!nearGeometry.points.contains { abs($0.y - nearGuide.y) < 0.001 }, "tiny parallel offset is removed from actual rendered vertices")
        let loop = connection(source, target, anchors[3], anchors[2], guide: CGPoint(x: source.bounds.midX, y: source.bounds.maxY - 1), width: 3)
        let loopGeometry = MacPDFConnectorGeometry.make(loop, objects: [source, target])!
        try check(loopGeometry.sourceAnchor == anchors[0] && loopGeometry.bendCount <= 1, "source switches bottom to left instead of wrapping the label box")
        try check(loopGeometry.points.allSatisfy { $0.x < source.bounds.maxX }, "automatic source route does not circle the far side of its box")
        try check(loopGeometry.path().copy(strokingWithWidth: 1, lineCap: .butt, lineJoin: .miter, miterLimit: 10).contains(loopGeometry.controlPoint), "grip stays on simplified line rather than floating inside the old source box")
        for (name, connector) in [("snap", near), ("source-auto", loop)] {
            let (proof, context) = bitmap()
            for object in [source, target, connector] { MacPDFObjectRenderer.draw(object, objects: [source, target, connector], context: context) }
            try proof.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/private/tmp/nf-pdf-connector-\(name).png"))
        }
        for guide in [CGPoint(x: 525, y: 140), CGPoint(x: 450, y: 280), CGPoint(x: 450, y: 390), CGPoint(x: 155, y: 280)] {
            let connector = connection(source, target, anchors[3], anchors[1], guide: guide)
            let objects = [source, target, connector], geometry = MacPDFConnectorGeometry.make(connector, objects: objects)!
            if !source.bounds.contains(guide) && !target.bounds.contains(guide) {
                try check(geometry.path().copy(strokingWithWidth: 1, lineCap: .butt, lineJoin: .miter, miterLimit: 10).contains(geometry.controlPoint), "resolved middle grip stays on connector route")
            }
            let (image, context) = bitmap()
            MacPDFObjectRenderer.draw(connector, objects: objects, context: context)
            var coloredInside = 0
            for object in [source, target] {
                let r = object.bounds.insetBy(dx: -0.5, dy: -0.5)
                for x in Int(r.minX)...Int(r.maxX) { for y in Int(r.minY)...Int(r.maxY) {
                    let color = image.colorAt(x: x, y: 599 - y)!.usingColorSpace(.deviceRGB)!
                    if color.redComponent > 0.6 && color.greenComponent < 0.6 && color.blueComponent < 0.6 { coloredInside += 1 }
                } }
            }
            try check(coloredInside == 0, "grip positions never paint over box border/interior")
        }
        let document = PDFDocument(), page = PDFPage(); page.setBounds(CGRect(x: 0, y: 0, width: 720, height: 600), for: .mediaBox); document.insert(page, at: 0)
        let state = MacPDFEditorState(document: document, identifier: "boundaries", fileName: "boundaries.pdf", directory: root)
        state.objects = [bottom, source, target] // Connector behind opaque objects must still show its head.
        let original = state.objects
        let data = state.exportPDF()!, restoredPDF = PDFDocument(data: data)!
        let (proof, proofContext) = bitmap(); restoredPDF.page(at: 0)!.draw(with: .mediaBox, to: proofContext)
        let center = CGPoint(x: bottomGeometry.tip.x, y: bottomGeometry.tip.y - 4)
        let color = proof.colorAt(x: Int(center.x), y: 599 - Int(center.y))!.usingColorSpace(.deviceRGB)!
        try check(color.redComponent > 0.6 && color.greenComponent < 0.6, "export keeps bottom arrow visible regardless of box z-order")
        try check(state.objects == original, "rendering/export does not rewrite stored anchors or route offsets")
        state.persist()
        let reopened = MacPDFEditorState(document: document, identifier: "boundaries", fileName: "boundaries.pdf", directory: root)
        try check(reopened.objects == original, "old anchor/offset archive remains editable without destructive migration")
        try proof.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/private/tmp/nf-pdf-connector-bottom-entry.png"))
        state.objects = [source, target, side]
        let (sideProof, sideContext) = bitmap(); PDFDocument(data: state.exportPDF()!)!.page(at: 0)!.draw(with: .mediaBox, to: sideContext)
        try sideProof.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/private/tmp/nf-pdf-connector-right-entry.png"))
        print("PASS: \(count) connector boundary, direction, rotation, grip and exported-PDF checks")
    }
}
