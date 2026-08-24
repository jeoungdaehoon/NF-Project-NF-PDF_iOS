//
// PortalPDFPageEditPersistenceTests.swift
// NFTests
//

import PDFKit
import Testing
import UIKit
@testable import NF

@MainActor
struct PortalPDFPageEditPersistenceTests {
    @Test func overlayRendersPageEditModelWithoutPDFAnnotations() throws {
        let pdfDocument = try #require(PDFDocument(data: makeOnePagePDFData()))
        let page = try #require(pdfDocument.page(at: 0))
        let ink = PDFAnnotation(
            bounds: CGRect(x: 24, y: 32, width: 100, height: 50),
            forType: .ink,
            withProperties: nil
        )
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 4, y: 6))
        path.addLine(to: CGPoint(x: 92, y: 42))
        ink.add(path)
        page.addAnnotation(ink)
        page.addAnnotation(PortalPDFShapeAnnotation(
            shapeType: .circle,
            bounds: CGRect(x: 140, y: 90, width: 64, height: 64),
            lineWidth: 2
        ))
        page.addAnnotation(PortalPDFTextAnnotation(
            text: "직접 렌더링",
            bounds: CGRect(x: 50, y: 180, width: 180, height: 48)
        ))
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            UIColor.systemPink.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        page.addAnnotation(PortalPDFImageAnnotation(
            image: image,
            bounds: CGRect(x: 250, y: 230, width: 72, height: 72)
        ))
        let editPage = try #require(PortalPDFPageEditDocument.capture(from: pdfDocument).page(at: 0))

        page.annotations.forEach { page.removeAnnotation($0) }
        #expect(page.annotations.isEmpty)
        let pdfView = PDFView(frame: CGRect(x: 0, y: 0, width: 612, height: 792))
        pdfView.document = pdfDocument
        pdfView.layoutDocumentView()
        let overlay = PortalPDFInkOverlayView(frame: pdfView.bounds)
        overlay.configure(page: page, pdfView: pdfView, pageEditData: editPage)
        overlay.layoutIfNeeded()

        #expect(overlay.renderedInkStrokeCount == 1)
        #expect(overlay.renderedImageCount == 1)
        #expect(overlay.renderedPageEditObjectLayerCount == 2)
        #expect(page.annotations.isEmpty)
    }

    @Test func pageEditsRoundTripOutsideThePDFAndRestoreInteractionProxies() throws {
        let pdfDocument = try #require(PDFDocument(data: makeOnePagePDFData()))
        let page = try #require(pdfDocument.page(at: 0))

        let ink = PDFAnnotation(
            bounds: CGRect(x: 24, y: 32, width: 140, height: 60),
            forType: .ink,
            withProperties: nil
        )
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 8, y: 12))
        path.addCurve(
            to: CGPoint(x: 124, y: 36),
            controlPoint1: CGPoint(x: 42, y: 50),
            controlPoint2: CGPoint(x: 88, y: 4)
        )
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        ink.add(path)
        ink.color = .systemBlue
        let border = PDFBorder()
        border.lineWidth = 3
        ink.border = border
        page.addAnnotation(ink)

        page.addAnnotation(PortalPDFShapeAnnotation(
            shapeType: .roundedRectangle,
            bounds: CGRect(x: 180, y: 80, width: 100, height: 64),
            lineWidth: 2,
            lineColor: .systemOrange,
            fillColor: UIColor.systemOrange.withAlphaComponent(0.2)
        ))
        page.addAnnotation(PortalPDFTextAnnotation(
            text: "NF 별도 편집 데이터",
            bounds: CGRect(x: 40, y: 170, width: 220, height: 54),
            borderColor: .systemGray,
            fillColor: .white,
            textColor: .black
        ))

        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            UIColor.systemGreen.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        page.addAnnotation(PortalPDFImageAnnotation(
            image: image,
            bounds: CGRect(x: 300, y: 210, width: 80, height: 80)
        ))

        let edits = PortalPDFPageEditDocument.capture(from: pdfDocument)
        let savedPage = try #require(edits.page(at: 0))
        #expect(savedPage.objects.count == 4)
        #expect(Set(savedPage.objects.map(\.kind)) == [.ink, .shape, .text, .image])

        let cleanPDFData = try #require(pdfDocument.portalBaseDataRepresentation())
        let cleanPDF = try #require(PDFDocument(data: cleanPDFData))
        #expect(cleanPDF.page(at: 0)?.annotations.isEmpty == true)
        #expect(page.annotations.count == 4)
        #expect(page.annotations.allSatisfy { !$0.shouldDisplay && !$0.shouldPrint })

        let testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NFExportEdits-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: testDirectory) }
        let repository = PortalPDFPageEditRepository(directoryURL: testDirectory)
        try repository.save(edits, identifier: "cloud-export")
        let flattenedData = try #require(repository.flattenedPDFData(
            basePDFData: cleanPDFData,
            identifier: "cloud-export"
        ))
        let flattenedPage = try #require(PDFDocument(data: flattenedData)?.page(at: 0))
        #expect(nonWhitePixelCount(in: flattenedPage) > 1_000)

        edits.installInteractionProxies(in: cleanPDF)
        let restoredPage = try #require(cleanPDF.page(at: 0))
        #expect(restoredPage.annotations.count == 4)
        #expect(restoredPage.annotations.allSatisfy { !$0.shouldDisplay && !$0.shouldPrint })
        let restoredEdits = PortalPDFPageEditDocument.capture(from: cleanPDF)
        #expect(Set(try #require(restoredEdits.page(at: 0)).objects.map(\.kind)) == [.ink, .shape, .text, .image])
    }

    @Test func editRepositorySavesCopiesAndRemovesVersionedSidecar() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("NFPageEdits-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: directory) }
        let repository = PortalPDFPageEditRepository(
            fileManager: fileManager,
            directoryURL: directory
        )
        let document = PortalPDFPageEditDocument(
            pages: [.init(pageIndex: 2, objects: [])]
        )

        try repository.save(document, identifier: "source-document")
        let sourceURL = repository.fileURL(for: "source-document")
        #expect(sourceURL.pathExtension == "nfedit")
        #expect(fileManager.fileExists(atPath: sourceURL.path))
        #expect(repository.load(identifier: "source-document")?.formatVersion == 1)

        try repository.copy(from: "source-document", to: "copied-document")
        #expect(repository.load(identifier: "copied-document")?.pages.first?.pageIndex == 2)

        try repository.remove(identifier: "source-document")
        #expect(repository.load(identifier: "source-document") == nil)
        #expect(repository.load(identifier: "copied-document") != nil)

        try repository.removeAll()
        #expect(!fileManager.fileExists(atPath: directory.path))
    }

    private func makeOnePagePDFData() -> Data {
        let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        return UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            context.beginPage()
            UIColor.white.setFill()
            context.cgContext.fill(bounds)
        }
    }

    private func nonWhitePixelCount(in page: PDFPage) -> Int {
        let size = CGSize(width: 306, height: 396)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { rendererContext in
            UIColor.white.setFill()
            rendererContext.fill(CGRect(origin: .zero, size: size))
            let context = rendererContext.cgContext
            let pageBounds = page.bounds(for: .mediaBox)
            context.saveGState()
            context.scaleBy(x: size.width / pageBounds.width, y: size.height / pageBounds.height)
            context.translateBy(x: 0, y: pageBounds.height)
            context.scaleBy(x: 1, y: -1)
            page.draw(with: .mediaBox, to: context)
            context.restoreGState()
        }
        guard let cgImage = image.cgImage else { return 0 }
        let width = cgImage.width
        let height = cgImage.height
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 0 }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return stride(from: 0, to: pixels.count, by: 4).reduce(into: 0) { count, offset in
            if pixels[offset] < 245 || pixels[offset + 1] < 245 || pixels[offset + 2] < 245 {
                count += 1
            }
        }
    }
}
