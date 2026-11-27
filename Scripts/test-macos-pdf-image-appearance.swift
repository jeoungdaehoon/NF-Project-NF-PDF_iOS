import AppKit
import PDFKit
import SwiftUI
@testable import NF_macOS

@main struct PDFImageAppearanceRegression {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nf-image-style-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let bitmap = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        let bounds = CGRect(x: 40, y: 55, width: 60, height: 60)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        func raster(width: Int = 160, height: Int = 160, draw: (CGContext) -> Void) -> CGImage {
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: width * 4, space: colorSpace, bitmapInfo: bitmap)!
            draw(context)
            return context.makeImage()!
        }
        func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
            let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
                                    bytesPerRow: 4, space: colorSpace, bitmapInfo: bitmap)!
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: -x, y: -y, width: image.width, height: image.height))
            let ptr = context.data!.assumingMemoryBound(to: UInt8.self)
            return Array(UnsafeBufferPointer(start: ptr, count: 4))
        }
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else {
                throw NSError(domain: "PDFImageAppearance", code: checks + 1, userInfo: [NSLocalizedDescriptionKey: message])
            }
            checks += 1
            print("PASS \(checks): \(message)")
            fflush(stdout)
        }
        let original = raster(width: 60, height: 60) { context in
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 60, height: 60))
            context.setFillColor(NSColor(white: 0.96, alpha: 1).cgColor)
            context.fill(CGRect(x: 0, y: 20, width: 8, height: 20))
            context.setFillColor(NSColor.red.cgColor)
            context.fill(CGRect(x: 15, y: 15, width: 30, height: 30))
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(x: 25, y: 25, width: 10, height: 10))
        }
        let exact = PDFImageBackgroundRemoval.apply(.init(tolerance: 0), to: original)
        let removed = PDFImageBackgroundRemoval.apply(.init(), to: original)
        let partial = PDFImageBackgroundRemoval.apply(.init(strength: 50), to: original)
        try check(pixel(original, 3, 3)[3] == 255 && pixel(removed, 3, 3)[3] == 0, "remove only the rendered backdrop")
        try check(pixel(removed, 30, 30) == [255, 255, 255, 255] && pixel(removed, 20, 20)[0] > 245,
                  "retain white details enclosed by the subject and keep its colors")
        try check(pixel(exact, 4, 30)[3] == 255 && pixel(removed, 4, 30)[3] == 0, "tolerance includes near-white edges")
        try check(abs(Int(pixel(partial, 3, 3)[3]) - 128) <= 1, "strength supports a partially transparent backdrop")

        func styled(_ style: PDFImageAppearance) -> CGImage {
            raster { style.draw(original, in: bounds, flipped: false, attachmentName: nil, context: $0) }
        }
        var style = PDFImageAppearance()
        style.opacity = 50
        try check(abs(Int(pixel(styled(style), 50, 65)[3]) - 128) <= 1, "opacity applies to the image")
        style.opacity = 100
        style.border = .line
        style.borderWidth = 4
        style.borderColor = .init(.red)
        let outlined = styled(style)
        try check(pixel(outlined, 39, 70)[0] > 245 && pixel(outlined, 39, 70)[1] < 10
                  && pixel(outlined, 36, 70)[3] == 0, "line border uses its selected color and width")
        style.border = .frame
        try check(pixel(styled(style), 32, 70)[1] < 10 && pixel(styled(style), 34, 70)[3] == 255,
                  "picture frame adds an outer line and mat")
        let linePatterns = PDFImageAppearance.Line.allCases.map { line in
            raster(width: 100, height: 20) { context in
                line.stroke([CGPoint(x: 5, y: 10), CGPoint(x: 95, y: 10)], width: 4, color: .black, in: context)
            }.dataProvider!.data! as Data
        }
        try check(Set(linePatterns).count == PDFImageAppearance.Line.allCases.count, "all selectable line styles render distinctly")

        style = .init()
        style.shadow = .drop
        try check(pixel(styled(style), 101, 65)[3] > 0, "drop shadow renders outside the image")
        style.shadow = .none
        style.reflection = true
        let reflected = styled(style)
        let nearReflection = pixel(reflected, 55, 50)[3]
        let farReflection = pixel(reflected, 55, 38)[3]
        try check(nearReflection > farReflection && nearReflection > 0, "reflection fades below the image")
        style.showsTitle = true
        style.title = "Image title"
        let titled = styled(style)
        try check((119..<133).contains { y in (40..<100).contains { pixel(titled, $0, y)[3] > 0 } },
                  "title renders above the image")
        style.titlePosition = .bottom
        let titledBelow = styled(style)
        try check((39..<53).contains { y in (40..<100).contains { pixel(titledBelow, $0, y)[3] > 0 } },
                  "title can also be placed below the image")

        let base = NSMutableData()
        var pageBounds = CGRect(x: 0, y: 0, width: 160, height: 160)
        let pdfContext = CGContext(consumer: CGDataConsumer(data: base)!, mediaBox: &pageBounds, nil)!
        pdfContext.beginPDFPage(nil)
        pdfContext.setFillColor(NSColor.blue.cgColor)
        pdfContext.fill(pageBounds)
        pdfContext.endPDFPage()
        pdfContext.closePDF()
        let document = PDFDocument(data: base as Data)!
        let encodedImage = NSBitmapImageRep(cgImage: original).representation(using: .png, properties: [:])!
        let object = MacPDFObject(page: 0, kind: .image, bounds: bounds, imageData: encodedImage, originalImageData: encodedImage)
        let oldData = try PropertyListEncoder().encode(object)
        let legacy = try PropertyListDecoder().decode(MacPDFObject.self, from: oldData)
        try check(legacy == object && legacy.imageAppearance == nil, "older images decode without a style")
        let state = MacPDFEditorState(document: document, identifier: "image-appearance", fileName: "fixture.pdf", directory: directory)
        state.add(object)
        state.selectObjects([object.id], showMenu: true)
        style = .init()
        style.backgroundRemoval = .init()
        let undoCount = state.undoCount
        state.applyImageAppearance(style, to: object.id)
        try check(state.undoCount == undoCount + 1 && state.selected?.imageData == encodedImage, "apply one undoable edit while retaining the image bytes")
        state.undo()
        try check(state.objects.first?.id == object.id && state.objects.first?.imageAppearance == nil,
                  "undo restores the original image appearance")
        state.redo()
        try check(state.objects.first?.imageAppearance == style && state.persist(), "redo and save retain the edited style")
        let reopened = MacPDFEditorState(document: document, identifier: "image-appearance", fileName: "fixture.pdf", directory: directory)
        try check(reopened.objects.first?.imageAppearance == style, "reopening restores background settings")
        let exported = state.exportPDF()!
        let exportedPage = CGPDFDocument(CGDataProvider(data: exported as CFData)!)!.page(at: 1)!
        let exportedImage = raster { $0.drawPDFPage(exportedPage) }
        let backdrop = pixel(exportedImage, 45, 60)
        let foreground = pixel(exportedImage, 60, 75)
        try check(backdrop[2] > 245 && backdrop[0] < 10 && foreground[0] > 245 && foreground[2] < 10,
                  "PDF export shows through the revealed background and retains the subject")

        state.selectObjects([object.id], showMenu: true)
        state.applyImageAppearance(.init(), to: object.id)
        state.selectionViewRect = CGRect(x: 220, y: 180, width: 160, height: 110)
        let windowSize = CGSize(width: 700, height: 580)
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -10000, y: -10000), size: windowSize),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: MacPDFObjectMenu(state: state, canvasSize: windowSize, onImageAction: { _ in }))
        window.orderFront(nil)
        defer { window.close() }
        func settle() { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        func find(_ identifier: String) -> NSObject? {
            func search(_ candidate: NSObject, depth: Int) -> NSObject? {
                guard depth < 24 else { return nil }
                let identifierSelector = NSSelectorFromString("accessibilityIdentifier")
                if candidate.responds(to: identifierSelector),
                   candidate.perform(identifierSelector)?.takeUnretainedValue() as? String == identifier { return candidate }
                let childrenSelector = NSSelectorFromString("accessibilityChildren")
                var children = candidate.responds(to: childrenSelector)
                    ? candidate.perform(childrenSelector)?.takeUnretainedValue() as? [NSObject] ?? [] : []
                if let view = candidate as? NSView { children += view.subviews }
                return children.lazy.compactMap { search($0, depth: depth + 1) }.first
            }
            return app.windows.filter(\.isVisible).compactMap(\.contentView).lazy.compactMap { search($0, depth: 0) }.first
        }
        settle()
        let more = find("pdf.object.more") as? NSButton
        try check(more != nil, "the image selection shows its floating More button")
        more?.performClick(nil)
        settle()
        let background = find("pdf.object.remove-background") as? NSButton
        try check(find("pdf.object.image-appearance") != nil && background != nil, "the More menu exposes both image style and background removal")
        background?.performClick(nil)
        settle()
        let apply = find("pdf.image.appearance.apply") as? NSButton
        try check(apply != nil, "the background entry opens the settings panel with Apply")
        if let preview = apply?.window?.contentView, let image = preview.bitmapImageRepForCachingDisplay(in: preview.bounds) {
            preview.cacheDisplay(in: preview.bounds, to: image)
            let hasSubject = image.cgImage.map { captured in
                stride(from: 0, to: captured.height, by: 6).contains { y in
                    let color = pixel(captured, Int(Double(captured.width) * 0.47), y)
                    return color[0] > 204 && color[1] < 51 && color[2] < 51
                }
            } ?? false
            try check(hasSubject, "the settings panel previews the actual image over the transparency grid")
        } else {
            try check(false, "the settings panel could not be captured")
        }
        apply?.performClick(nil)
        try check(state.objects.first?.imageAppearance == style && state.objects.first?.imageData == encodedImage,
                  "applying the background preview saves the setting and retains the original bytes")
        print("PASS: \(checks) PDF image appearance checks")
    }
}
