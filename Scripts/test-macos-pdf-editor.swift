import AppKit
import PDFKit

/// Compile with the production model/renderer/canvas. Uses only temporary data;
/// never reads user documents, clipboard, authentication or remote services.
@main
struct MacPDFEditorRegression {
    @MainActor static func main() throws {
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nf-pdf-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
            guard value() else { throw NSError(domain: "MacPDFTest", code: checks, userInfo: [NSLocalizedDescriptionKey: message]) }; checks += 1
        }
        let pdf = PDFDocument(), page = PDFPage()
        page.setBounds(CGRect(x: 0, y: 0, width: 600, height: 800), for: .mediaBox); pdf.insert(page, at: 0)
        let state = MacPDFEditorState(document: pdf, identifier: "fixture", fileName: "fixture.pdf", directory: root.appendingPathComponent("editor"))
        let shape = MacPDFObject(page: 0, kind: .shape, bounds: CGRect(x: 50, y: 200, width: 100, height: 80), shape: .diamond)
        state.add(shape)
        let text = MacPDFObject(page: 0, kind: .text, bounds: CGRect(x: 300, y: 200, width: 240, height: 90), text: "PDF editor regression")
        state.add(text)
        let connector = MacPDFObject(page: 0, kind: .connector, bounds: page.bounds(for: .mediaBox), sourceID: shape.id, targetID: text.id)
        state.add(connector)
        try check(state.objects.count == 3 && state.undoCount == 3, "objects/undo registration")
        let original = MacPDFObjectRenderer.endpoints(connector, objects: state.objects)!
        state.selection = [shape.id]; state.updateSelected { $0.bounds.origin.x += 80 }
        let moved = MacPDFObjectRenderer.endpoints(connector, objects: state.objects)!
        try check(moved.0.x == original.0.x + 80 && moved.1 == original.1, "connector must follow moved source only")
        state.undo(); try check(MacPDFObjectRenderer.endpoints(connector, objects: state.objects)!.0 == original.0, "undo moves connector back")
        state.redo(); try check(MacPDFObjectRenderer.endpoints(connector, objects: state.objects)!.0 == moved.0, "redo restores connector")
        state.selection = [shape.id, text.id, connector.id]; state.duplicateSelected()
        let copied = state.objects.filter { state.selection.contains($0.id) }
        try check(copied.count == 3 && Set(copied.map(\.id)).isDisjoint(with: [shape.id, text.id, connector.id]), "duplicate IDs")
        let copiedConnector = copied.first { $0.kind == .connector }!
        try check(copied.contains { $0.id == copiedConnector.sourceID } && copied.contains { $0.id == copiedConnector.targetID }, "duplicate connector stays within copies")
        state.deleteSelected(); try check(state.objects.count == 3, "delete copies without originals")
        state.selection = [shape.id]; state.deleteSelected(); try check(state.objects.count == 1 && state.objects[0].id == text.id, "deleting source removes its connectors")
        state.undo(); try check(state.objects.count == 3, "undo restores source and connectors")
        state.toggleFavorite(); state.pageOperation("duplicate")
        try check(state.pageCount == 2 && state.pageObjects(1).count == 3 && state.favorites == [0], "page duplication copies objects and preserves favorites")
        let pageConnector = state.pageObjects(1).first { $0.kind == .connector }!
        try check(state.pageObjects(1).contains { $0.id == pageConnector.sourceID }, "page duplication remaps connection IDs")
        state.movePage(from: 1, to: 0); try check(state.currentPage == 0 && state.favorites == [1], "page move remaps favorites")
        state.pageOperation("delete"); try check(state.pageCount == 1 && state.pageObjects(0).count == 3 && state.favorites == [0], "page delete remaps objects and favorites")
        state.undo(); try check(state.pageCount == 2 && state.pageObjects(0).count == 3, "page structure undo")
        state.redo(); try check(state.pageCount == 1 && state.pageObjects(0).count == 3, "page structure redo")
        state.persist()
        let reopened = MacPDFEditorState(document: pdf, identifier: "fixture", fileName: "fixture.pdf", directory: root.appendingPathComponent("editor"))
        try check(reopened.objects == state.objects && reopened.favorites == state.favorites && reopened.pageCount == state.pageCount, "archive roundtrip")
        let transient = MacPDFObject(page: 0, kind: .ink, bounds: CGRect(x: 10, y: 10, width: 50, height: 50), points: [MacPDFPoint(CGPoint(x: 10, y: 10)), MacPDFPoint(CGPoint(x: 50, y: 50))], isTransient: true)
        state.add(transient); state.persist()
        let reopenedAgain = MacPDFEditorState(document: pdf, identifier: "fixture", fileName: "fixture.pdf", directory: root.appendingPathComponent("editor"))
        try check(!reopenedAgain.objects.contains { $0.isTransient }, "neon must not persist")
        let export = state.exportPDF()!, exported = PDFDocument(data: export)!
        try check(exported.pageCount == 1 && exported.page(at: 0)!.bounds(for: .mediaBox).size == CGSize(width: 600, height: 800), "PDF export size/page count")
        try check(exported.string?.contains("PDF editor regression") == true, "PDF export contains real text")
        try check(state.document.pageCount == 1 && state.objects.contains { $0.isTransient }, "export does not mutate live edits")
        for shapeType in MacPDFShape.allCases { try check(!MacPDFObjectRenderer.shapePath(shapeType, bounds: shape.bounds).isEmpty, "shape path \(shapeType)") }
        // Render all object types/styles, including empty/single-point ink.
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 600, pixelsHigh: 800, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!.cgContext
        for shapeType in MacPDFShape.allCases { var object = shape; object.shape = shapeType; MacPDFObjectRenderer.draw(object, objects: state.objects, context: context) }
        for route in ["straight", "elbow", "curve"] { var object = connector; object.style.connectorRoute = route; object.style.dashed = true; MacPDFObjectRenderer.draw(object, objects: state.objects, context: context) }
        for points in [[], [MacPDFPoint(CGPoint(x: 20, y: 20))], transient.points] { var object = transient; object.points = points; MacPDFObjectRenderer.draw(object, objects: [], context: context); object.style.pressure = true; MacPDFObjectRenderer.draw(object, objects: [], context: context) }
        try check(bitmap.representation(using: .png, properties: [:]) != nil, "all drawing paths complete")
        let remoteDirectory = root.appendingPathComponent("remote")
        let remote = MacPDFEditorState(document: PDFDocument(data: export)!, identifier: "remote", fileName: "remote.pdf", sourceURL: URL(string: "https://example.test/test.pdf"), sourceData: Data([1]), directory: remoteDirectory)
        remote.add(shape)
        let newRevision = MacPDFEditorState(document: PDFDocument(data: export)!, identifier: "remote", fileName: "remote.pdf", sourceURL: URL(string: "https://example.test/test.pdf"), sourceData: Data([2]), directory: remoteDirectory)
        try check(newRevision.objects.isEmpty, "new server revision must not load stale local objects")
        newRevision.persist()
        let previousRevision = MacPDFEditorState(document: PDFDocument(data: export)!, identifier: "remote", fileName: "remote.pdf", sourceURL: URL(string: "https://example.test/test.pdf"), sourceData: Data([1]), directory: remoteDirectory)
        try check(previousRevision.objects.count == 1, "server revision change preserves previous edit archive")
        let badDirectory = root.appendingPathComponent("bad-archive")
        try FileManager.default.createDirectory(at: badDirectory, withIntermediateDirectories: true)
        let corruptData = Data("corrupt existing edits".utf8), corruptURL = badDirectory.appendingPathComponent("edits.plist")
        try corruptData.write(to: corruptURL)
        let unreadable = MacPDFEditorState(document: PDFDocument(data: export)!, identifier: "bad", fileName: "bad.pdf", directory: badDirectory)
        unreadable.add(shape)
        try check(unreadable.error != nil && !unreadable.persist(), "unreadable archive blocks overwrite")
        let preservedData = try Data(contentsOf: corruptURL)
        try check(preservedData == corruptData, "corrupt archive remains recoverable")
        // Real AppKit mouse/text events in an isolated offscreen PDFView.
        let inputPDF = PDFDocument(), inputPage = PDFPage()
        inputPage.setBounds(CGRect(x: 0, y: 0, width: 600, height: 800), for: .mediaBox); inputPDF.insert(inputPage, at: 0)
        let input = MacPDFEditorState(document: inputPDF, identifier: "input", fileName: "input.pdf", directory: root.appendingPathComponent("input"))
        let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 800, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = MacPDFEditingView(frame: CGRect(x: 0, y: 0, width: 800, height: 900)); view.editor = input; input.canvas = view; view.document = inputPDF; view.scaleFactor = 1
        window.contentView = view; window.orderFront(nil); view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        func mouse(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            let location = view.convert(view.convert(point, from: inputPage), to: nil)
            return NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: Date.timeIntervalSinceReferenceDate, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0.5)!
        }
        input.tool = .pen
        view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 100, y: 100))); view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 200, y: 100))); view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 200, y: 100)))
        try check(input.objects.count == 1 && input.objects[0].points.count > 10, "native pen drag samples continuous stroke")
        input.tool = .eraser; input.eraserSize = 24
        view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 150, y: 100))); view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 150, y: 100)))
        try check(input.objects.count == 2, "native eraser splits a stroke")
        input.undo(); try check(input.objects.count == 1, "eraser is one undo operation")
        input.tool = .shape
        view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 100, y: 250))); view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 210, y: 330))); view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 210, y: 330)))
        try check(input.objects.last?.kind == .shape && abs(input.objects.last!.bounds.width - 110) < 1, "native shape drag uses page coordinates")
        input.tool = .text
        input.addVisibleObject(.text)
        view.beginTextEditing(input.selected!)
        try check(window.firstResponder is NSTextView, "text tool activates native text editor")
        (window.firstResponder as? NSTextView)?.string = "한글 입력 확인"
        view.finishTextEditing(); try check(input.objects.last?.text == "한글 입력 확인" && input.objects.last?.textRTF != nil, "native Korean text commit saves text and formatting")
        input.setZoom(200)
        if let textObject = input.objects.last { view.beginTextEditing(textObject); let font = (window.firstResponder as? NSTextView)?.font; try check(abs((font?.pointSize ?? 0) - textObject.style.fontSize * 2) < 0.1, "text editor font follows zoom"); view.finishTextEditing() }
        input.setZoom(100); view.layoutSubtreeIfNeeded()
        let nativeRep = view.renderedEditsImage()!
        var coloredPixels = 0
        for y in stride(from: 0, to: nativeRep.pixelsHigh, by: 4) { for x in stride(from: 0, to: nativeRep.pixelsWide, by: 4) {
            if let color = nativeRep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.blueComponent > color.redComponent + 0.2 { coloredPixels += 1 }
        } }
        try check(coloredPixels > 10, "native editing overlay draws actual editable objects, not just exported graphics")
        // iOS metadata migration: editable annotations become Mac objects; bad
        // metadata must stay in the original PDF instead of being removed.
        struct IOSText: Encodable {
            let id = UUID(), text = "iOS 한글 주석", bounds = CGRect(x: 30, y: 100, width: 200, height: 60), fontName = "Helvetica", fontSize = 18.0
            let textColorRGBA = [0.0, 0.0, 1.0, 1.0], fillColorRGBA = [0.0, 0.0, 0.0, 0.0], borderColorRGBA = [1.0, 0.0, 0.0, 1.0]
            let isBold = true, isItalic = false, isUnderlined = true, isStruckThrough = false, alignmentRawValue = 2
            let linkURL = "https://example.test", attributedTextRTF: Data? = nil
        }
        struct IOSShape: Encodable { let shapeType = "rectangle", bounds = CGRect(x: 100, y: 300, width: 100, height: 90), lineWidth = 2.0, lineColorRGBA = [1.0, 0.0, 0.0, 1.0], fillColorRGBA = [0.0, 1.0, 0.0, 0.2], rotationAngle = 0.5 }
        let iosDocument = PDFDocument(), iosPage = PDFPage(); iosPage.setBounds(CGRect(x: 0, y: 0, width: 600, height: 800), for: .mediaBox); iosDocument.insert(iosPage, at: 0)
        func annotation(_ contents: String) { let a = PDFAnnotation(bounds: CGRect(x: 0, y: 0, width: 20, height: 20), forType: .stamp, withProperties: nil); a.contents = contents; iosPage.addAnnotation(a) }
        annotation("NF_EDITABLE_TEXT_V1:" + (try JSONEncoder().encode(IOSText())).base64EncodedString())
        annotation("NF_EDITABLE_SHAPE_V1:" + (try JSONEncoder().encode(IOSShape())).base64EncodedString())
        annotation("NF_EDITABLE_TEXT_V1:invalid")
        var compact = Data()
        func append<T: FixedWidthInteger>(_ value: T) { var little = value.littleEndian; withUnsafeBytes(of: &little) { compact.append(contentsOf: $0) } }
        append(UInt8(1)); append(UInt8(1)); append(UInt16(1)); append(Float32(2).bitPattern)
        for component in [UInt16(0), 0, 65535, 65535] { append(component) }
        append(UInt32(2)); append(Int32(10000)); append(Int32(20000)); append(UInt16(32767)); append(Int32(5000)); append(Int32(5000)); append(UInt16(65535))
        annotation("NF_PRESSURE_INK_V3:" + compact.base64EncodedString())
        let migrated = MacPDFEditorState(document: iosDocument, identifier: "ios", fileName: "ios.pdf", directory: root.appendingPathComponent("ios"))
        try check(migrated.objects.count == 3 && iosPage.annotations.count == 1, "iOS text/shape/compact ink migrate while invalid metadata remains")
        try check(migrated.objects.first { $0.kind == .text }?.style.bold == true && migrated.objects.first { $0.kind == .text }?.link == "https://example.test", "iOS text style and link preserved")
        try check(migrated.objects.first { $0.kind == .ink }?.points.last?.cgPoint == CGPoint(x: 150, y: 250), "iOS V3 compact delta coordinates decode correctly")
        migrated.persist()
        let migratedReopened = MacPDFEditorState(document: iosDocument, identifier: "ios", fileName: "ios.pdf", directory: root.appendingPathComponent("ios"))
        try check(migratedReopened.objects == migrated.objects && migratedReopened.objects.count == 3, "iOS migration saves editable objects without duplicate annotations")
        if let png = nativeRep.representation(using: .png, properties: [:]) { try png.write(to: URL(fileURLWithPath: "/private/tmp/nf-macos-pdf-native-annotations.png")) }
        window.close()
        // Save a rendered proof for visual inspection without capturing user UI.
        if let proof = input.exportPDF(), let rendered = PDFDocument(data: proof)?.page(at: 0)?.thumbnail(of: CGSize(width: 600, height: 800), for: .mediaBox),
           let tiff = rendered.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: "/private/tmp/nf-macos-pdf-editor-proof.png"))
        }
        try export.write(to: root.appendingPathComponent("export.pdf"))
        print("PASS: \(checks) macOS PDF editor checks (persistence, undo/redo, pages, connectors, shapes, PDF export)")
    }
}
