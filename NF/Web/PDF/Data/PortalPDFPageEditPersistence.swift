//
// PortalPDFPageEditPersistence.swift
// NF
//
// FileManager 방식의 페이지별 편집 데이터와 PDFView 오버레이 렌더링 모델입니다.
//

import CryptoKit
import Foundation
import PDFKit
import UIKit

/// PDF 본문과 분리해 저장하는 NF 페이지 편집 문서입니다.
/// PDF Annotation은 화면 렌더링용 정본이 아니며, 기존 제스처 코드와의 호환 프록시로만 사용합니다.
@MainActor
struct PortalPDFPageEditDocument: Codable {
    static let currentFormatVersion = 1

    var formatVersion: Int = currentFormatVersion
    var updatedAt: Date = Date()
    var pages: [Page] = []

    struct Page: Codable, Identifiable {
        let pageIndex: Int
        var objects: [Object]

        var id: Int { pageIndex }
    }

    struct Object: Codable, Identifiable {
        enum Kind: String, Codable {
            case ink
            case pressureInk
            case image
            case shape
            case text
        }

        let id: UUID
        let kind: Kind
        let displayIndex: Int
        var ink: Ink?
        var image: PortalPDFImageAnnotation.Metadata?
        var shape: PortalPDFShapeAnnotation.Metadata?
        var text: PortalPDFTextAnnotation.Metadata?
    }

    struct Ink: Codable, Equatable {
        var paths: [BezierPath]
        var pressureFragments: [PressureFragment]
        var colorRGBA: [Double]
        var lineWidth: Double
        var lineCapRawValue: Int32
        var lineJoinRawValue: Int32
    }

    struct PressureFragment: Codable, Equatable {
        var points: [Point]
        var pressures: [Double]
    }

    struct Point: Codable, Equatable {
        var x: Double
        var y: Double

        init(_ point: CGPoint) {
            x = point.x
            y = point.y
        }

        var cgPoint: CGPoint {
            CGPoint(x: x, y: y)
        }
    }

    struct BezierPath: Codable, Equatable {
        struct Element: Codable, Equatable {
            enum Kind: String, Codable {
                case move
                case line
                case quadCurve
                case curve
                case close
            }

            var kind: Kind
            var points: [Point]
        }

        var elements: [Element]

        init(cgPath: CGPath) {
            var captured: [Element] = []
            cgPath.applyWithBlock { elementPointer in
                let element = elementPointer.pointee
                switch element.type {
                case .moveToPoint:
                    captured.append(Element(kind: .move, points: [Point(element.points[0])]))
                case .addLineToPoint:
                    captured.append(Element(kind: .line, points: [Point(element.points[0])]))
                case .addQuadCurveToPoint:
                    captured.append(Element(
                        kind: .quadCurve,
                        points: [Point(element.points[0]), Point(element.points[1])]
                    ))
                case .addCurveToPoint:
                    captured.append(Element(
                        kind: .curve,
                        points: [
                            Point(element.points[0]),
                            Point(element.points[1]),
                            Point(element.points[2]),
                        ]
                    ))
                case .closeSubpath:
                    captured.append(Element(kind: .close, points: []))
                @unknown default:
                    break
                }
            }
            elements = captured
        }

        var uiBezierPath: UIBezierPath {
            let path = UIBezierPath()
            for element in elements {
                switch element.kind {
                case .move:
                    if let point = element.points.first?.cgPoint { path.move(to: point) }
                case .line:
                    if let point = element.points.first?.cgPoint { path.addLine(to: point) }
                case .quadCurve:
                    guard element.points.count == 2 else { continue }
                    path.addQuadCurve(
                        to: element.points[1].cgPoint,
                        controlPoint: element.points[0].cgPoint
                    )
                case .curve:
                    guard element.points.count == 3 else { continue }
                    path.addCurve(
                        to: element.points[2].cgPoint,
                        controlPoint1: element.points[0].cgPoint,
                        controlPoint2: element.points[1].cgPoint
                    )
                case .close:
                    path.close()
                }
            }
            return path
        }
    }

    var hasEditableObjects: Bool {
        pages.contains { !$0.objects.isEmpty }
    }

    func page(at index: Int) -> Page? {
        pages.first { $0.pageIndex == index }
    }

    /// 변경된 한 페이지만 다시 캡처해 문서 전체 Annotation 순회를 피합니다.
    mutating func updatePage(at pageIndex: Int, from document: PDFDocument) {
        guard let page = document.page(at: pageIndex) else { return }
        let objects = page.annotations.enumerated().compactMap { displayIndex, annotation in
            Self.object(from: annotation, displayIndex: displayIndex)
        }
        pages.removeAll { $0.pageIndex == pageIndex }
        if !objects.isEmpty {
            pages.append(Page(pageIndex: pageIndex, objects: objects))
            pages.sort { $0.pageIndex < $1.pageIndex }
        }
        updatedAt = Date()
    }

    /// 새 펜 획처럼 페이지 끝에 추가되는 객체는 기존 페이지 객체를 다시 변환하지 않고 붙입니다.
    @discardableResult
    mutating func append(
        annotation: PDFAnnotation,
        at displayIndex: Int,
        to pageIndex: Int
    ) -> Bool {
        guard let object = Self.object(from: annotation, displayIndex: displayIndex) else { return false }
        if let index = pages.firstIndex(where: { $0.pageIndex == pageIndex }) {
            pages[index].objects.append(object)
        } else {
            pages.append(Page(pageIndex: pageIndex, objects: [object]))
            pages.sort { $0.pageIndex < $1.pageIndex }
        }
        updatedAt = Date()
        return true
    }

    /// 현재 메모리의 호환 Annotation 프록시를 페이지별 편집 모델로 캡처합니다.
    static func capture(from document: PDFDocument) -> PortalPDFPageEditDocument {
        var capturedPages: [Page] = []
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            let objects = page.annotations.enumerated().compactMap { displayIndex, annotation in
                object(from: annotation, displayIndex: displayIndex)
            }
            if !objects.isEmpty {
                capturedPages.append(Page(pageIndex: pageIndex, objects: objects))
            }
        }
        return PortalPDFPageEditDocument(updatedAt: Date(), pages: capturedPages)
    }

    /// 저장된 편집 모델을 기존 Coordinator가 선택·이동할 수 있는 숨은 Annotation 프록시로 복원합니다.
    func installInteractionProxies(in document: PDFDocument) {
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            let originalAnnotations = page.annotations
            originalAnnotations
                .filter(Self.isManagedAnnotation)
                .forEach { page.removeAnnotation($0) }

            guard let savedPage = self.page(at: pageIndex) else { continue }
            for object in savedPage.objects.sorted(by: { $0.displayIndex < $1.displayIndex }) {
                guard let annotation = object.interactionProxy else { continue }
                Self.suppressDisplay(of: annotation)
                page.addAnnotation(annotation)
            }
        }
    }

    static func suppressManagedAnnotations(in document: PDFDocument) {
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            suppressManagedAnnotations(on: page)
        }
    }

    static func suppressManagedAnnotations(on page: PDFPage) {
        page.annotations
            .filter(isManagedAnnotation)
            .forEach(suppressDisplay)
    }

    static func isManagedAnnotation(_ annotation: PDFAnnotation) -> Bool {
        annotation is PortalPDFImageAnnotation
            || annotation is PortalPDFShapeAnnotation
            || annotation is PortalPDFTextAnnotation
            || PortalPDFPressureInkAnnotation.isPressureInk(annotation)
            || annotation.isPortalInkAnnotation
    }

    static func suppressDisplay(of annotation: PDFAnnotation) {
        annotation.shouldDisplay = false
        annotation.shouldPrint = false
    }

    private static func object(
        from annotation: PDFAnnotation,
        displayIndex: Int
    ) -> Object? {
        if PortalPDFPressureInkAnnotation.isPressureInk(annotation),
           let stored = PortalPDFPressureInkAnnotation.storedStrokes(in: annotation) {
            let fragments = stored.fragments.map { fragment in
                PressureFragment(
                    points: fragment.points.map(Point.init),
                    pressures: fragment.pressures.map(Double.init)
                )
            }
            return Object(
                id: annotation.portalStableEditID,
                kind: .pressureInk,
                displayIndex: displayIndex,
                ink: Ink(
                    paths: [],
                    pressureFragments: fragments,
                    colorRGBA: PortalPDFPressureInkAnnotation.storedColor(in: annotation).portalRGBA,
                    lineWidth: Double(stored.baseLineWidth),
                    lineCapRawValue: CGLineCap.round.rawValue,
                    lineJoinRawValue: CGLineJoin.round.rawValue
                )
            )
        }

        if let image = annotation as? PortalPDFImageAnnotation {
            return Object(
                id: annotation.portalStableEditID,
                kind: .image,
                displayIndex: displayIndex,
                image: PortalPDFImageAnnotation.Metadata(
                    imageData: image.persistedImageData,
                    bounds: image.imageBounds,
                    rotationAngle: Double(image.rotationAngle),
                    isHorizontallyFlipped: image.isHorizontallyFlipped,
                    animatedGIFData: image.animatedGIFData
                )
            )
        }

        if let shape = annotation as? PortalPDFShapeAnnotation {
            return Object(
                id: annotation.portalStableEditID,
                kind: .shape,
                displayIndex: displayIndex,
                shape: PortalPDFShapeAnnotation.Metadata(
                    shapeType: shape.shapeType.rawValue,
                    bounds: shape.shapeBounds,
                    lineWidth: Double(shape.portalLineWidth),
                    lineColorRGBA: shape.lineColor.portalRGBA,
                    fillColorRGBA: shape.fillColor.portalRGBA,
                    rotationAngle: Double(shape.rotationAngle)
                )
            )
        }

        if annotation is PortalPDFTextAnnotation,
           let metadata: PortalPDFTextAnnotation.Metadata = decodedMetadata(
               from: annotation.contents,
               prefix: PortalPDFTextAnnotation.metadataPrefix
           ) {
            return Object(
                id: metadata.id,
                kind: .text,
                displayIndex: displayIndex,
                text: metadata
            )
        }

        guard annotation.isPortalInkAnnotation,
              let paths = annotation.paths,
              !paths.isEmpty else { return nil }
        let pagePaths = paths.compactMap { path -> BezierPath? in
            var localToPage = CGAffineTransform(
                translationX: annotation.bounds.minX,
                y: annotation.bounds.minY
            )
            guard let pagePath = path.cgPath.copy(using: &localToPage) else { return nil }
            return BezierPath(cgPath: pagePath)
        }
        guard !pagePaths.isEmpty else { return nil }
        return Object(
            id: annotation.portalStableEditID,
            kind: .ink,
            displayIndex: displayIndex,
            ink: Ink(
                paths: pagePaths,
                pressureFragments: [],
                colorRGBA: annotation.color.portalRGBA,
                lineWidth: Double(annotation.border?.lineWidth ?? 1),
                lineCapRawValue: paths.first?.lineCapStyle.rawValue ?? CGLineCap.round.rawValue,
                lineJoinRawValue: paths.first?.lineJoinStyle.rawValue ?? CGLineJoin.round.rawValue
            )
        )
    }

    private static func decodedMetadata<T: Decodable>(
        from contents: String?,
        prefix: String
    ) -> T? {
        guard let contents,
              contents.hasPrefix(prefix),
              let data = Data(base64Encoded: String(contents.dropFirst(prefix.count))) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

private extension PortalPDFPageEditDocument.Object {
    var interactionProxy: PDFAnnotation? {
        switch kind {
        case .ink:
            guard let ink else { return nil }
            let annotation = PDFAnnotation(bounds: .zero, forType: .ink, withProperties: nil)
            let allBounds = ink.paths.reduce(CGRect.null) { bounds, path in
                bounds.union(path.uiBezierPath.bounds)
            }
            guard !allBounds.isNull else { return nil }
            annotation.bounds = allBounds
            annotation.color = UIColor.portalColor(rgba: ink.colorRGBA) ?? .black
            let border = PDFBorder()
            border.lineWidth = ink.lineWidth
            annotation.border = border
            for savedPath in ink.paths {
                let path = savedPath.uiBezierPath
                path.apply(CGAffineTransform(translationX: -allBounds.minX, y: -allBounds.minY))
                path.lineCapStyle = CGLineCap(rawValue: ink.lineCapRawValue) ?? .round
                path.lineJoinStyle = CGLineJoin(rawValue: ink.lineJoinRawValue) ?? .round
                annotation.add(path)
            }
            annotation.setValue(id.uuidString, forAnnotationKey: .name)
            return annotation
        case .pressureInk:
            guard let ink else { return nil }
            let fragments = ink.pressureFragments.compactMap { fragment -> PortalPDFPressureInkAnnotation.StrokeFragment? in
                let points = fragment.points.map(\.cgPoint)
                let pressures = fragment.pressures.map { CGFloat($0) }
                guard !points.isEmpty, points.count == pressures.count else { return nil }
                return PortalPDFPressureInkAnnotation.StrokeFragment(
                    points: points,
                    pressures: pressures
                )
            }
            guard let annotation = PortalPDFPressureInkAnnotation.groupedAnnotation(
                fragments: fragments,
                baseLineWidth: CGFloat(ink.lineWidth),
                color: UIColor.portalColor(rgba: ink.colorRGBA) ?? .black
            ) else { return nil }
            annotation.setValue(id.uuidString, forAnnotationKey: .name)
            return annotation
        case .image:
            guard let image,
                  let uiImage = UIImage(data: image.imageData) else { return nil }
            let annotation = PortalPDFImageAnnotation(
                image: uiImage,
                persistedImageData: image.imageData,
                bounds: image.bounds,
                animatedGIFData: image.animatedGIFData
            )
            annotation.rotationAngle = CGFloat(image.rotationAngle)
            annotation.isHorizontallyFlipped = image.isHorizontallyFlipped
            annotation.setValue(id.uuidString, forAnnotationKey: .name)
            annotation.prepareForPersistence()
            return annotation
        case .shape:
            guard let shape,
                  let shapeType = PortalPDFShapeType(rawValue: shape.shapeType) else { return nil }
            let annotation = PortalPDFShapeAnnotation(
                shapeType: shapeType,
                bounds: shape.bounds,
                lineWidth: CGFloat(shape.lineWidth),
                lineColor: UIColor.portalColor(rgba: shape.lineColorRGBA) ?? .systemOrange,
                fillColor: UIColor.portalColor(rgba: shape.fillColorRGBA) ?? .clear
            )
            annotation.rotationAngle = CGFloat(shape.rotationAngle)
            annotation.setValue(id.uuidString, forAnnotationKey: .name)
            return annotation
        case .text:
            guard let text else { return nil }
            return PortalPDFTextAnnotation(metadata: text)
        }
    }
}

private extension PDFAnnotation {
    var portalStableEditID: UUID {
        if let name = value(forAnnotationKey: .name) as? String,
           let id = UUID(uuidString: name) {
            return id
        }
        let id = UUID()
        setValue(id.uuidString, forAnnotationKey: .name)
        return id
    }
}

/// 페이지 편집 데이터를 PDF 파일과 다른 경로에 원자적으로 저장합니다.
final class PortalPDFPageEditRepository {
    private let fileManager: FileManager
    private let directoryURL: URL
    private let encoder: PropertyListEncoder
    private let decoder: PropertyListDecoder

    init(fileManager: FileManager = .default, directoryURL: URL? = nil) {
        self.fileManager = fileManager
        let applicationSupportURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        self.directoryURL = directoryURL
            ?? applicationSupportURL.appendingPathComponent("NF/PDFEdits", isDirectory: true)
        encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        decoder = PropertyListDecoder()
    }

    func load(identifier: String) -> PortalPDFPageEditDocument? {
        guard let data = try? Data(contentsOf: fileURL(for: identifier)) else { return nil }
        if let document = try? decoder.decode(PortalPDFPageEditDocument.self, from: data) {
            return document
        }
        // 초기 JSON `.nfedit` 파일은 한 번 읽어 다음 저장부터 binary plist로 전환합니다.
        return try? JSONDecoder().decode(PortalPDFPageEditDocument.self, from: data)
    }

    func save(_ document: PortalPDFPageEditDocument, identifier: String) throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let data = try encoder.encode(document)
        try data.write(to: fileURL(for: identifier), options: [.atomic])
    }

    func copy(from sourceIdentifier: String, to targetIdentifier: String) throws {
        guard let document = load(identifier: sourceIdentifier) else { return }
        try save(document, identifier: targetIdentifier)
    }

    func remove(identifier: String) throws {
        let url = fileURL(for: identifier)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    func removeAll() throws {
        guard fileManager.fileExists(atPath: directoryURL.path) else { return }
        try fileManager.removeItem(at: directoryURL)
    }

    func fileURL(for identifier: String) -> URL {
        let digest = SHA256.hash(data: Data(identifier.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return directoryURL
            .appendingPathComponent(digest)
            .appendingPathExtension("nfedit")
    }

    /// 로컬에는 PDF 본문과 편집 데이터를 분리해 두되, 외부 뷰어나 클라우드에는
    /// 두 데이터를 합성한 일반 PDF를 전달합니다.
    func flattenedPDFData(basePDFData: Data, identifier: String) -> Data? {
        guard let document = PDFDocument(data: basePDFData) else { return nil }
        if let pageEdits = load(identifier: identifier) {
            pageEdits.installInteractionProxies(in: document)
        }
        return document.portalFlattenedDataRepresentation() ?? document.dataRepresentation()
    }
}

extension PDFDocument {
    /// 앱 편집 객체를 제외한 PDF 본문만 직렬화합니다.
    /// 화면과 편집 상태는 `PortalPDFPageEditRepository`의 `.nfedit` 파일이 보관합니다.
    func portalBaseDataRepresentation() -> Data? {
        var pageAnnotations: [(page: PDFPage, annotations: [PDFAnnotation])] = []
        for pageIndex in 0..<pageCount {
            guard let page = page(at: pageIndex) else { continue }
            let annotations = page.annotations
            pageAnnotations.append((page, annotations))
            annotations.forEach { page.removeAnnotation($0) }
            annotations
                .filter { !PortalPDFPageEditDocument.isManagedAnnotation($0) }
                .forEach { page.addAnnotation($0) }
        }

        let data = dataRepresentation()

        for entry in pageAnnotations {
            entry.page.annotations.forEach { entry.page.removeAnnotation($0) }
            entry.annotations.forEach { entry.page.addAnnotation($0) }
        }
        PortalPDFPageEditDocument.suppressManagedAnnotations(in: self)
        return data
    }
}
