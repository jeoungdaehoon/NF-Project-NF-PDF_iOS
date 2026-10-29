import CryptoKit
import Foundation
import PDFKit
import UIKit
import ObjectiveC

/// Android and iOS exchange PDF-point coordinates, never UIKit archives.
/// Android writes standard embedded files; PDFKit writes an invisible metadata annotation.
@MainActor
enum PortalPDFPortableWorkspace {
    private static var sourceAssociation: UInt8 = 0
    static let marker = "NF_PORTABLE_PDF_V1:"
    private static let sourceMarker = "NF_ORIGINAL_PDF_V1"
    private static let pageMarker = "NF_SOURCE_PAGE_V1:"
    private static let sourceKey = PDFAnnotationKey(rawValue: "NFSource")
    private static let workspaceKey = PDFAnnotationKey(rawValue: "NFWorkspace")
    private static let maxBytes = 100 * 1024 * 1024

    static func restore(data: Data) -> PDFDocument? {
        guard data.count <= maxBytes, let flat = PDFDocument(data: data) else { return nil }
        let attachments = embeddedFiles(data)
        var json = attachments["nf-workspace.json"]
        var source = attachments["nf-source.pdf"]
        if let metadata = flat.page(at: 0)?.annotations.first(where: { $0.contents?.hasPrefix(marker) == true }) {
            json = metadata.contents.map { Data($0.dropFirst(marker.count).utf8) }
            source = (metadata.value(forAnnotationKey: sourceKey) as? String).flatMap { Data(base64Encoded: $0) }
        }
        guard let json, json.count <= 32 * 1024 * 1024, let source, source.count <= maxBytes,
              let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              root["format"] as? String == "notefree-pdf-workspace", root["version"] as? Int == 1,
              root["sourceSha256"] as? String == digest(source),
              let pages = root["pages"] as? [[String: Any]], !pages.isEmpty, pages.count <= 5000,
              let original = PDFDocument(data: source) else { return nil }
        let document = PDFDocument()
        var edits = PortalPDFPageEditDocument()
        var count = 0
        for (index, saved) in pages.enumerated() {
            let width = number(saved, "width"), height = number(saved, "height")
            guard width > 0, height > 0, width < 100_000, height < 100_000 else { return nil }
            let page: PDFPage
            if let sourceIndex = saved["sourcePage"] as? Int {
                guard sourceIndex >= 0, let copied = original.page(at: sourceIndex)?.copy() as? PDFPage else { return nil }
                page = copied
            } else {
                let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: width, height: height))
                let blank = renderer.pdfData { $0.beginPage() }
                guard let copied = PDFDocument(data: blank)?.page(at: 0) else { return nil }
                page = copied
            }
            page.annotations.filter { $0.contents?.hasPrefix(marker) == true || $0.contents == sourceMarker || $0.contents?.hasPrefix(pageMarker) == true }.forEach(page.removeAnnotation)
            let tag = PDFAnnotation(bounds: .zero, forType: .text, withProperties: nil)
            tag.contents = pageMarker + String(saved["sourcePage"] as? Int ?? -1)
            tag.setValue(saved["id"] as? String ?? UUID().uuidString, forAnnotationKey: .name)
            tag.shouldDisplay = false; tag.shouldPrint = false; page.addAnnotation(tag)
            document.insert(page, at: index)
            let objects = saved["objects"] as? [[String: Any]] ?? []
            count += objects.count; guard count <= 100_000 else { return nil }
            let converted = objects.enumerated().compactMap { object($0.element, displayIndex: $0.offset, page: page) }
            guard converted.count == objects.count else { return nil }
            edits.pages.append(.init(pageIndex: index, objects: converted))
        }
        let stored = PDFAnnotation(bounds: .zero, forType: .text, withProperties: nil)
        stored.contents = sourceMarker; stored.shouldDisplay = false; stored.shouldPrint = false
        stored.setValue(source.base64EncodedString(), forAnnotationKey: sourceKey)
        stored.setValue(String(decoding: json, as: UTF8.self), forAnnotationKey: workspaceKey)
        document.page(at: 0)?.addAnnotation(stored)
        objc_setAssociatedObject(document,&sourceAssociation,stored,.OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        edits.installInteractionProxies(in: document)
        return document
    }

    static func export(document: PDFDocument, title: String = "PDF", cloudDocumentID: String? = nil, cloudVersion: String? = nil) -> Data? {
        prepareForPersistence(document)
        guard let flatData = document.portalFlattenedDataRepresentation(), let flat = PDFDocument(data: flatData), let first = flat.page(at: 0) else { return nil }
        let stored = (0..<document.pageCount).compactMap { document.page(at: $0) }.flatMap(\.annotations).first { $0.contents == sourceMarker }
        let source = (stored?.value(forAnnotationKey: sourceKey) as? String).flatMap { Data(base64Encoded: $0) } ?? document.portalBaseDataRepresentation()
        guard let source, source.count <= maxBytes else { return nil }
        let previous = (stored?.value(forAnnotationKey: workspaceKey) as? String).flatMap { $0.data(using: .utf8) }.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let oldPages = previous?["pages"] as? [[String: Any]] ?? []
        var oldObjects: [String: [String: Any]] = [:]
        for page in oldPages { for object in page["objects"] as? [[String: Any]] ?? [] { if let id = object["id"] as? String { oldObjects[id.lowercased()] = object } } }
        let captured = PortalPDFPageEditDocument.capture(from: document)
        var seen = Set<String>()
        var seenObjects = Set<String>()
        let pages: [[String: Any]] = (0..<document.pageCount).compactMap { index in
            guard let page = document.page(at: index) else { return nil }
            let tag = page.annotations.first { $0.contents?.hasPrefix(pageMarker) == true }
            let tagged = tag?.contents.flatMap { Int($0.dropFirst(pageMarker.count)) }
            var id = (tag?.value(forAnnotationKey: .name) as? String) ?? UUID().uuidString
            if !seen.insert(id).inserted { id = UUID().uuidString; seen.insert(id) }
            let bounds = page.bounds(for: .cropBox); let rotated = page.rotation % 180 != 0
            let objects = captured.page(at: index)?.objects.compactMap { native -> [String: Any]? in
                guard var value = portable(native, page: page, previous: oldObjects[native.id.uuidString.lowercased()]) else { return nil }
                if !seenObjects.insert(native.id.uuidString).inserted { value["id"] = UUID().uuidString }
                return value
            } ?? []
            return ["id": id, "sourcePage": tagged.map { $0 >= 0 ? $0 as Any : NSNull() } ?? (stored == nil ? index as Any : NSNull()), "width": rotated ? bounds.height : bounds.width, "height": rotated ? bounds.width : bounds.height, "favorite": oldPages.first { $0["id"] as? String == id }?["favorite"] as? Bool ?? false, "objects": objects]
        }
        var root: [String: Any] = ["format": "notefree-pdf-workspace", "version": 1, "id": previous?["id"] as? String ?? UUID().uuidString, "title": title, "sourceSha256": digest(source), "revision": UUID().uuidString, "pages": pages]
        root["cloudDocumentID"] = cloudDocumentID ?? previous?["cloudDocumentID"]
        root["cloudVersion"] = cloudVersion ?? previous?["cloudVersion"]
        guard let json = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]), json.count <= 32 * 1024 * 1024 else { return nil }
        let metadata = PDFAnnotation(bounds: .zero, forType: .text, withProperties: nil)
        metadata.contents = marker + String(decoding: json, as: UTF8.self)
        metadata.setValue(source.base64EncodedString(), forAnnotationKey: sourceKey)
        metadata.shouldDisplay = false; metadata.shouldPrint = false; first.addAnnotation(metadata)
        return flat.dataRepresentation()
    }

    /// A document-level reference keeps the immutable source alive when its first page is deleted.
    static func prepareForPersistence(_ document: PDFDocument) {
        guard let first=document.page(at:0) else {return}
        let stored=(0..<document.pageCount).compactMap {document.page(at:$0)}.flatMap(\.annotations).first {$0.contents==sourceMarker}
            ?? objc_getAssociatedObject(document,&sourceAssociation) as? PDFAnnotation
        guard let stored else {return}
        objc_setAssociatedObject(document,&sourceAssociation,stored,.OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        if stored.page !== first {stored.page?.removeAnnotation(stored);first.addAnnotation(stored)}
    }

    static func cloudReference(data: Data) -> (id: String, version: String)? {
        var json = embeddedFiles(data)["nf-workspace.json"]
        if let document = PDFDocument(data: data) {
            for i in 0..<document.pageCount {
                for annotation in document.page(at: i)?.annotations ?? [] {
                    if annotation.contents?.hasPrefix(marker) == true { json = annotation.contents.map { Data($0.dropFirst(marker.count).utf8) } }
                    if annotation.contents == sourceMarker, let stored = annotation.value(forAnnotationKey: workspaceKey) as? String { json = Data(stored.utf8) }
                }
            }
        }
        guard let json, let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let id = root["cloudDocumentID"] as? String, let version = root["cloudVersion"] as? String,
              id.range(of: "^[a-zA-Z0-9_-]{1,80}$", options: .regularExpression) != nil,
              UUID(uuidString: version) != nil else { return nil }
        return (id, version)
    }

    private static func object(_ value: [String: Any], displayIndex: Int, page: PDFPage) -> PortalPDFPageEditDocument.Object? {
        guard let id = (value["id"] as? String).flatMap(UUID.init(uuidString:)), let kind = value["kind"] as? String,
              let b = value["bounds"] as? [String: Any] else { return nil }
        let top = CGRect(x: number(b,"x"), y: number(b,"y"), width: number(b,"width"), height: number(b,"height"))
        guard top.width > 0, top.height > 0 else { return nil }
        let bounds = top.applying(screenToPDF(page)).standardized
        let color = rgba(value["color"] as? Int ?? -16777216), fill = rgba(value["fillColor"] as? Int ?? 0)
        switch kind {
        case "ink", "highlighter", "neon":
            guard let points = value["points"] as? [[Double]], points.count <= 200_000 else { return nil }
            let transformed = points.filter { $0.count >= 2 }.map { CGPoint(x: $0[0], y: $0[1]).applying(screenToPDF(page)) }
            guard transformed.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
            let pressure = value["pressureEnabled"] as? Bool ?? false
            var actualColor = color; if kind == "highlighter" { actualColor[3] = min(actualColor[3], 0.35) }
            let breaks = (value["strokeBreaks"] as? [Int] ?? []).filter { $0 > 0 && $0 < transformed.count }.sorted()
            let cuts = [0] + breaks + [transformed.count]
            var paths: [PortalPDFPageEditDocument.BezierPath] = []
            var fragments: [PortalPDFPageEditDocument.PressureFragment] = []
            for i in 0..<(cuts.count-1) {
                let range = cuts[i]..<cuts[i+1]
                let path = UIBezierPath()
                for (offset, point) in transformed[range].enumerated() { if offset == 0 { path.move(to:point) } else { path.addLine(to:point) } }
                paths.append(.init(cgPath:path.cgPath))
                fragments.append(.init(points:transformed[range].map(PortalPDFPageEditDocument.Point.init),pressures:points[range].map { $0.count > 2 ? $0[2] : 1 }))
            }
            let ink = PortalPDFPageEditDocument.Ink(paths: pressure ? [] : paths, pressureFragments: pressure ? fragments : [], colorRGBA: actualColor, lineWidth: number(value,"lineWidth",2), lineCapRawValue: (value["roundCap"] as? Bool ?? true) ? CGLineCap.round.rawValue : CGLineCap.butt.rawValue, lineJoinRawValue: CGLineJoin.round.rawValue)
            return .init(id: id, kind: pressure ? .pressureInk : .ink, displayIndex: displayIndex, ink: ink)
        case "image":
            guard let encoded = value["imageData"] as? String, let data = Data(base64Encoded: encoded), data.count <= 20 * 1024 * 1024 else { return nil }
            return .init(id: id, kind: .image, displayIndex: displayIndex, image: .init(imageData: data, bounds: bounds, rotationAngle: -number(value,"rotation") * .pi/180, isHorizontallyFlipped: value["flipped"] as? Bool ?? false, animatedGIFData: value["imageMimeType"] as? String == "image/gif" ? data : nil))
        case "shape":
            let name = nativeShape(value["shape"] as? String ?? "rectangle")
            return .init(id: id, kind: .shape, displayIndex: displayIndex, shape: .init(shapeType: name, bounds: bounds, lineWidth: number(value,"lineWidth",2), lineColorRGBA: color, fillColorRGBA: fill, rotationAngle: -number(value,"rotation") * .pi/180))
        case "text":
            let alignment = value["alignment"] as? String ?? "left"
            let nativeAlignment: NSTextAlignment = alignment == "center" ? .center : alignment == "right" ? .right : .left
            let rtf = (value["iosRTF"] as? String).flatMap { Data(base64Encoded: $0) } ?? richTextData(value)
            let metadata = PortalPDFTextAnnotation.Metadata(id: id, text: value["text"] as? String ?? "", bounds: bounds,
                fontName: value["fontFamily"] as? String ?? "Helvetica", fontSize: number(value,"fontSize",16),
                textColorRGBA: color, fillColorRGBA: fill, borderColorRGBA: [0,0,0,0],
                isBold: value["bold"] as? Bool ?? false, isItalic: value["italic"] as? Bool ?? false,
                isUnderlined: value["underline"] as? Bool ?? false, isStruckThrough: value["strikeThrough"] as? Bool ?? false,
                alignmentRawValue: nativeAlignment.rawValue, linkURL: value["link"] as? String, attributedTextRTF: rtf)
            return .init(id: id, kind: .text, displayIndex: displayIndex, text: metadata)
        default: return nil
        }
    }

    private static func portable(_ object: PortalPDFPageEditDocument.Object, page: PDFPage, previous: [String: Any]?) -> [String: Any]? {
        var o: [String: Any] = previous ?? [:]
        o["id"] = object.id.uuidString; o["rotation"] = 0; o["fontSize"] = 16; o["lineWidth"] = 2
        o["shape"] = "rectangle"; o["color"] = -16777216; o["fillColor"] = 0
        let transform = screenToPDF(page).inverted()
        func setBounds(_ bounds: CGRect) { let b = bounds.applying(transform).standardized; o["bounds"] = ["x": b.minX, "y": b.minY, "width": max(0.1,b.width), "height": max(0.1,b.height)] }
        if let ink = object.ink {
            o["kind"] = previous?["kind"] as? String ?? "ink"; o["color"] = argb(ink.colorRGBA); o["lineWidth"] = ink.lineWidth
            o["roundCap"] = ink.lineCapRawValue == CGLineCap.round.rawValue; o["pressureEnabled"] = !ink.pressureFragments.isEmpty
            var points: [[Double]] = []
            var strokeBreaks: [Int] = []
            for fragment in ink.pressureFragments { if !points.isEmpty {strokeBreaks.append(points.count)};for (i,p) in fragment.points.enumerated() { let q = p.cgPoint.applying(transform); points.append([q.x,q.y,fragment.pressures.indices.contains(i) ? fragment.pressures[i] : 1]) } }
            if points.isEmpty { for path in ink.paths {if !points.isEmpty {strokeBreaks.append(points.count)}; points += sampled(path).map { let q = $0.applying(transform); return [q.x,q.y,1] } } }
            guard !points.isEmpty else { return nil };o["points"] = points;o["strokeBreaks"] = strokeBreaks
            let xs = points.map { $0[0] }, ys = points.map { $0[1] }; o["bounds"] = ["x": xs.min()!, "y": ys.min()!, "width": max(0.1,xs.max()!-xs.min()!), "height": max(0.1,ys.max()!-ys.min()!)]
        } else if let image = object.image {
            o["kind"] = "image"; setBounds(image.bounds); o["imageData"] = (image.animatedGIFData ?? image.imageData).base64EncodedString();o["imageMimeType"] = image.animatedGIFData == nil ? "image/png" : "image/gif"
            if o["originalImageData"] == nil { o["originalImageData"] = image.imageData.base64EncodedString() };o["rotation"] = -image.rotationAngle * 180 / .pi;o["flipped"] = image.isHorizontallyFlipped
        } else if let shape = object.shape {
            o["kind"] = "shape";setBounds(shape.bounds);o["shape"] = portableShape(shape.shapeType);o["lineWidth"] = shape.lineWidth;o["color"] = argb(shape.lineColorRGBA);o["fillColor"] = argb(shape.fillColorRGBA);o["rotation"] = -shape.rotationAngle*180 / .pi
        } else if let text = object.text {
            o["kind"] = "text";setBounds(text.bounds);o["text"] = text.text;o["fontFamily"] = text.fontName;o["fontSize"] = text.fontSize;o["color"] = argb(text.textColorRGBA);o["fillColor"] = argb(text.fillColorRGBA)
            o["bold"] = text.isBold;o["italic"] = text.isItalic;o["underline"] = text.isUnderlined;o["strikeThrough"] = text.isStruckThrough;o["link"] = text.linkURL;o["iosRTF"] = text.attributedTextRTF?.base64EncodedString()
            o["textRuns"] = portableRuns(text)
            o["alignment"] = text.alignmentRawValue == NSTextAlignment.center.rawValue ? "center" : text.alignmentRawValue == NSTextAlignment.right.rawValue ? "right" : "left"
        } else { return nil }
        return o
    }
    private static func richTextData(_ value: [String: Any]) -> Data? {
        guard let text = value["text"] as? String, let runs = value["textRuns"] as? [[String: Any]], !runs.isEmpty else { return nil }
        let attributed = NSMutableAttributedString(string: text)
        for run in runs {
            guard let start = run["start"] as? Int, let end = run["end"] as? Int, start >= 0, end > start, end <= attributed.length else { continue }
            let size = number(run,"fontSize",16)
            var font = UIFont(name: run["fontFamily"] as? String ?? "Helvetica", size: size) ?? UIFont.systemFont(ofSize: size)
            var traits = font.fontDescriptor.symbolicTraits
            if run["bold"] as? Bool == true { traits.insert(.traitBold) }
            if run["italic"] as? Bool == true { traits.insert(.traitItalic) }
            if let descriptor = font.fontDescriptor.withSymbolicTraits(traits) { font = UIFont(descriptor: descriptor, size: size) }
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.portalColor(rgba: rgba(run["color"] as? Int ?? -16777216)) ?? .black]
            attributes[.underlineStyle] = run["underline"] as? Bool == true ? NSUnderlineStyle.single.rawValue : 0
            attributes[.strikethroughStyle] = run["strikeThrough"] as? Bool == true ? NSUnderlineStyle.single.rawValue : 0
            if let link = run["link"] as? String, let url = URL(string: link), ["http","https"].contains(url.scheme ?? "") { attributes[.link] = url }
            attributed.addAttributes(attributes, range: NSRange(location: start, length: end-start))
        }
        return try? attributed.data(from: NSRange(location:0,length:attributed.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }
    private static func portableRuns(_ text: PortalPDFTextAnnotation.Metadata) -> [[String: Any]] {
        guard let data = text.attributedTextRTF, let rich = try? NSAttributedString(data:data,options:[.documentType:NSAttributedString.DocumentType.rtf],documentAttributes:nil) else { return [] }
        var runs: [[String:Any]] = []
        rich.enumerateAttributes(in:NSRange(location:0,length:rich.length)) { attrs,range,_ in
            guard range.length > 0 else { return }
            let font = attrs[.font] as? UIFont ?? UIFont.systemFont(ofSize:text.fontSize)
            let color = attrs[.foregroundColor] as? UIColor ?? UIColor.portalColor(rgba:text.textColorRGBA) ?? .black
            var r: [String:Any] = ["start":range.location,"end":range.location+range.length,"fontFamily":font.familyName,"fontSize":font.pointSize,"color":argb(color.portalRGBA),"bold":font.fontDescriptor.symbolicTraits.contains(.traitBold),"italic":font.fontDescriptor.symbolicTraits.contains(.traitItalic),"underline":(attrs[.underlineStyle] as? Int ?? 0) != 0,"strikeThrough":(attrs[.strikethroughStyle] as? Int ?? 0) != 0]
            if let link = attrs[.link] { r["link"] = String(describing:link) };runs.append(r)
        }
        return runs
    }

    private static func sampled(_ path: PortalPDFPageEditDocument.BezierPath) -> [CGPoint] {
        var result: [CGPoint] = []; var current = CGPoint.zero; var start = CGPoint.zero
        for element in path.elements {
            let p = element.points.map(\.cgPoint)
            switch element.kind {
            case .move: if let next = p.first { current = next;start = next;result.append(next) }
            case .line: if let next = p.first { result.append(next);current = next }
            case .quadCurve:
                if p.count == 2 { let a = current;for i in 1...16 { let t = Double(i)/16, u = 1-t;result.append(CGPoint(x:u*u*a.x+2*u*t*p[0].x+t*t*p[1].x,y:u*u*a.y+2*u*t*p[0].y+t*t*p[1].y)) };current = p[1] }
            case .curve:
                if p.count == 3 { let a = current;for i in 1...24 { let t = Double(i)/24, u = 1-t;result.append(CGPoint(x:u*u*u*a.x+3*u*u*t*p[0].x+3*u*t*t*p[1].x+t*t*t*p[2].x,y:u*u*u*a.y+3*u*u*t*p[0].y+3*u*t*t*p[1].y+t*t*t*p[2].y)) };current = p[2] }
            case .close:result.append(start);current = start
            }
        };return result
    }
    private static func screenToPDF(_ page: PDFPage) -> CGAffineTransform {
        let b = page.bounds(for: .cropBox)
        switch (page.rotation % 360 + 360) % 360 {
        case 90:return CGAffineTransform(a:0,b:1,c:1,d:0,tx:b.minX,ty:b.minY)
        case 180:return CGAffineTransform(a:-1,b:0,c:0,d:1,tx:b.maxX,ty:b.minY)
        case 270:return CGAffineTransform(a:0,b:-1,c:-1,d:0,tx:b.maxX,ty:b.maxY)
        default:return CGAffineTransform(a:1,b:0,c:0,d:-1,tx:b.minX,ty:b.maxY)
        }
    }
    private static func number(_ o:[String:Any],_ key:String,_ fallback:Double=0)->Double { let n=(o[key] as? NSNumber)?.doubleValue ?? fallback;return n.isFinite && abs(n)<=1_000_000 ? n : fallback }
    private static func rgba(_ value:Int)->[Double] {let bits=UInt32(truncatingIfNeeded:value);return [Double((bits>>16)&255)/255,Double((bits>>8)&255)/255,Double(bits&255)/255,Double((bits>>24)&255)/255]}
    private static func argb(_ c:[Double])->Int {guard c.count==4 else{return -16777216};let bytes=c.map {UInt32((max(0,min(1,$0))*255).rounded())};return Int(Int32(bitPattern:(bytes[3]<<24)|(bytes[0]<<16)|(bytes[1]<<8)|bytes[2]))}
    private static func digest(_ data:Data)->String {SHA256.hash(data:data).map {String(format:"%02x",$0)}.joined()}
    private static func nativeShape(_ s:String)->String {["rounded_rectangle":"roundedRectangle","arrow":"rightArrow","speech_bubble":"speechBubble","diagonal_arrow":"diagonalArrow"][s] ?? s}
    private static func portableShape(_ s:String)->String {["roundedRectangle":"rounded_rectangle","rightArrow":"arrow","speechBubble":"speech_bubble","diagonalArrow":"diagonal_arrow"][s] ?? s}
    private static func embeddedFiles(_ data:Data)->[String:Data] {
        guard let provider=CGDataProvider(data:data as CFData),let pdf=CGPDFDocument(provider) else{return [:]}
        return withExtendedLifetime(pdf) {
        guard let catalog=pdf.catalog else {return [:]}
        var names:CGPDFDictionaryRef?;var tree:CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(catalog,"Names",&names),let names,CGPDFDictionaryGetDictionary(names,"EmbeddedFiles",&tree),let tree else{return [:]}
        var result:[String:Data]=[:]
        func visit(_ node:CGPDFDictionaryRef,_ depth:Int) {
            guard depth<8 else{return};var list:CGPDFArrayRef?
            if CGPDFDictionaryGetArray(node,"Names",&list),let list {
                var i=0;while i+1<CGPDFArrayGetCount(list) {
                    var name:CGPDFStringRef?;var spec:CGPDFDictionaryRef?;var ef:CGPDFDictionaryRef?;var stream:CGPDFStreamRef?
                    if CGPDFArrayGetString(list,i,&name),let name,let label=CGPDFStringCopyTextString(name) as String?,["nf-source.pdf","nf-workspace.json"].contains(label),CGPDFArrayGetDictionary(list,i+1,&spec),let spec,CGPDFDictionaryGetDictionary(spec,"EF",&ef),let ef,CGPDFDictionaryGetStream(ef,"F",&stream),let stream {
                        var format=CGPDFDataFormat.raw
                        if let raw=CGPDFStreamCopyData(stream,&format),CFDataGetLength(raw)<=maxBytes {result[label]=raw as Data}
                    };i+=2
                }
            }
            var kids:CGPDFArrayRef?;if CGPDFDictionaryGetArray(node,"Kids",&kids),let kids {for i in 0..<min(100,CGPDFArrayGetCount(kids)) {var child:CGPDFDictionaryRef?;if CGPDFArrayGetDictionary(kids,i,&child),let child{visit(child,depth+1)}}}
        };visit(tree,0);return result
        }
    }
}
