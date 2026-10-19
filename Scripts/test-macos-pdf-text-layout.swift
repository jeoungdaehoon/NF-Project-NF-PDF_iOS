import AppKit
import CoreText
import PDFKit

@main struct TextLayoutRegression {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nf-text-layout-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else { throw NSError(domain: "TextLayout", code: count, userInfo: [NSLocalizedDescriptionKey: message]) }; count += 1
        }
        func visible(_ object: MacPDFObject) -> Int {
            let text = MacPDFTextFormatting.attributed(object)
            let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(text), CFRange(location: 0, length: 0), CGPath(rect: MacPDFTextLayout.contentRect(object.bounds, style: object.style), transform: nil), nil)
            return CTFrameGetVisibleStringRange(frame).length
        }
        let longText = "10월19일 오전\n9시 회의에서\n변경 사항 확인\n처리 내용 추가\n마지막 문구"
        for scale in [0.5, 1.0, 3.0] {
            let pdf = PDFDocument(), page = PDFPage(); page.setBounds(CGRect(x: 0, y: 0, width: 600, height: 800), for: .mediaBox); pdf.insert(page, at: 0)
            let directory = root.appendingPathComponent("scale-\(scale)")
            let state = MacPDFEditorState(document: pdf, identifier: "text-\(scale)", fileName: "fixture.pdf", directory: directory)
            let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 800, height: 900), styleMask: [.borderless], backing: .buffered, defer: false); window.isReleasedWhenClosed = false
            let canvas = MacPDFEditingView(frame: CGRect(x: 0, y: 0, width: 800, height: 900)); window.contentView = canvas
            canvas.editor = state; state.canvas = canvas; canvas.document = pdf; canvas.autoScales = false; canvas.scaleFactor = scale; window.orderFront(nil)
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            var object = MacPDFObject(page: 0, kind: .text, bounds: CGRect(x: 200, y: 400, width: 80, height: 24), text: "문구")
            object.style.fontSize = 8; object.style.stroke = .init(.black); object.style.textBorder = .init(.systemRed); object.style.width = 1
            let source = MacPDFObject(page: 0, kind: .shape, bounds: CGRect(x: 30, y: 400, width: 50, height: 50))
            let connector = MacPDFObject(page: 0, kind: .connector, bounds: page.bounds(for: .mediaBox), sourceID: source.id, targetID: object.id)
            state.objects = [source, object, connector]; state.selectObjects([object.id], showMenu: false)
            canvas.beginTextEditing(object)
            let input = canvas.activeTextView!
            input.undoManager?.removeAllActions(); input.breakUndoCoalescing()
            input.insertText(longText, replacementRange: NSRange(location: 0, length: (input.string as NSString).length)); input.breakUndoCoalescing()
            let grown = state.objects.first { $0.id == object.id }!, caret = input.selectedRange(), inputFrame = input.frame
            try check(grown.bounds.height > object.bounds.height && grown.bounds.maxY == object.bounds.maxY, "\(scale)x input grows downward while preserving top edge")
            for _ in 0..<4 { canvas.updateInteractionOverlay() }
            try check(input.frame == inputFrame && input.selectedRange() == caret, "overlay updates cannot collapse frame or move caret")
            try check(abs(input.frame.height - grown.bounds.height * scale) < 0.01 && input.textContainer?.lineFragmentPadding == 0, "input and model use the same scaled frame and horizontal padding")
            try check(state.undoCount == 0, "typing resize remains preview-only until edit completion")
            try check(MacPDFObjectRenderer.endpoints(connector, objects: state.objects)!.1.y != MacPDFObjectRenderer.endpoints(connector, objects: [source, object, connector])!.1.y, "attached connector follows growing text bounds")
            canvas.textUndo(redo: false)
            try check(input.string == object.text && state.objects.first { $0.id == object.id }!.bounds == object.bounds, "native text undo restores original content and box size")
            canvas.textUndo(redo: true)
            try check(input.string == longText && state.objects.first { $0.id == object.id }!.bounds == grown.bounds, "native redo restores expanded size")
            input.setSelectedRange(NSRange(location: 0, length: (input.string as NSString).length))
            var style = state.style; style.fontSize = 24; state.setStyle(style, field: "fontSize")
            try check(state.objects.first { $0.id == object.id }!.bounds.height > grown.bounds.height, "font enlargement refits the box")
            style = state.style; style.textBorder = .init(.systemRed); state.setStyle(style, field: "textBorder")
            style = state.style; style.width = 3; state.setStyle(style, field: "width")
            style = state.style; style.dashed = true; state.setStyle(style, field: "dashed")
            style = state.style; style.textCornerRadius = 12; state.setStyle(style, field: "textCornerRadius")
            try check((input as? MacPDFTextInput)?.boxStyle.dashed == true && (input as? MacPDFTextInput)?.boxStyle.textCornerRadius == 12 && (input as? MacPDFTextInput)?.boxStyle.width == 3, "active input immediately reflects dash, width and radius")
            try check(window.firstResponder === input && input.isEditable, "box controls preserve native text focus and editability")
            canvas.finishTextEditing()
            let saved = state.objects.first { $0.id == object.id }!, text = MacPDFTextFormatting.attributed(saved)
            try check(saved.text == longText && visible(saved) == text.length, "all typed characters fit the committed PDF text frame")
            try check(saved.style.dashed && saved.style.textCornerRadius == 12 && saved.style.width == 3, "box formatting is stored on the text object")
            try check(state.undoCount == 1, "content, formatting and resized bounds commit as one document undo")
            let data = state.exportPDF()!, exported = PDFDocument(data: data)!
            try check(exported.string?.filter { !$0.isWhitespace }.contains("마지막문구") == true, "exported PDF includes the previously clipped last line across visual wrapping")
            let original = state.objects
            state.undo(); try check(state.objects.first { $0.id == object.id } == object, "document undo restores original text, bounds and box formatting")
            state.redo(); try check(state.objects == original, "document redo restores text and decoration together")
            state.persist()
            let reopened = MacPDFEditorState(document: pdf, identifier: "text-\(scale)", fileName: "fixture.pdf", directory: directory)
            try check(reopened.objects == original && visible(reopened.objects.first { $0.id == object.id }!) == text.length, "expanded bounds and rounded dashed box survive reopening")
            window.close()
        }
        var style = MacPDFStyle(); style.stroke = .init(.black); style.textBorder = .init(.systemRed); style.width = 3
        var encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(style)) as! [String: Any]; encoded.removeValue(forKey: "textCornerRadius")
        let old = try JSONDecoder().decode(MacPDFStyle.self, from: JSONSerialization.data(withJSONObject: encoded))
        try check(old.textCornerRadius == nil, "previous style archives without radius remain decodable")
        func pixels(_ style: MacPDFStyle) -> (Data, NSBitmapImageRep) {
            let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 320, pixelsHigh: 180, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            let context = NSGraphicsContext(bitmapImageRep: image)!.cgContext; context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
            let object = MacPDFObject(page: 0, kind: .text, bounds: CGRect(x: 30, y: 30, width: 260, height: 120), style: style, text: "라운드 · 점선 · 두께")
            MacPDFObjectRenderer.draw(object, objects: [object], context: context)
            return (Data(bytes: image.bitmapData!, count: image.bytesPerRow * image.pixelsHigh), image)
        }
        let solid = pixels(style).0
        style.dashed = true; let dashed = pixels(style).0
        style.textCornerRadius = 20; let rounded = pixels(style)
        try check(solid != dashed && dashed != rounded.0, "dashed pattern and rounded corners visibly change renderer output")
        try rounded.1.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/private/tmp/nf-pdf-text-rounded-dashed.png"))
        print("PASS: \(count) text autosize, zoom, undo, border, radius, persistence and PDF export checks")
    }
}
