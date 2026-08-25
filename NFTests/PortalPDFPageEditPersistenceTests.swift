//
// PortalPDFPageEditPersistenceTests.swift
// NFTests
//

import ImageIO
import PDFKit
import Testing
import UIKit
import UniformTypeIdentifiers
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

    @Test func overlayPreservesInsertionOrderAcrossInkAndImageLayers() throws {
        let pdfDocument = try #require(PDFDocument(data: makeOnePagePDFData()))
        let page = try #require(pdfDocument.page(at: 0))
        addInk(to: page, index: 0)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).image { context in
            UIColor.systemYellow.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        page.addAnnotation(PortalPDFImageAnnotation(
            image: image,
            bounds: CGRect(x: 24, y: 24, width: 120, height: 120)
        ))
        addInk(to: page, index: 1)

        let editPage = try #require(PortalPDFPageEditDocument.capture(from: pdfDocument).page(at: 0))
        #expect(editPage.objects.map(\.kind) == [.ink, .image, .ink])

        let pdfView = PDFView(frame: CGRect(x: 0, y: 0, width: 612, height: 792))
        pdfView.document = pdfDocument
        pdfView.layoutDocumentView()
        let overlay = PortalPDFInkOverlayView(frame: pdfView.bounds)
        overlay.configure(page: page, pdfView: pdfView, pageEditData: editPage)
        overlay.layoutIfNeeded()

        #expect(overlay.renderedContentLayerKindsInBackToFrontOrder == ["ink", "image", "ink"])
    }

    @Test func selectedTextShowsResizeHandlesAndRerendersForZoom() throws {
        let pdfDocument = try #require(PDFDocument(data: makeOnePagePDFData()))
        let page = try #require(pdfDocument.page(at: 0))
        let text = PortalPDFTextAnnotation(
            text: "선명한 텍스트",
            bounds: CGRect(x: 60, y: 180, width: 220, height: 56)
        )
        text.setAttributedText(NSAttributedString(
            string: text.text,
            attributes: [.font: UIFont.systemFont(ofSize: 18)]
        ))
        text.isPortalTextSelected = true
        text.updateEditingDisplayScaleFactor(1)
        page.addAnnotation(text)
        let editPage = try #require(PortalPDFPageEditDocument.capture(from: pdfDocument).page(at: 0))

        let pdfView = PDFView(frame: CGRect(x: 0, y: 0, width: 612, height: 792))
        pdfView.autoScales = false
        pdfView.minScaleFactor = 0.1
        pdfView.maxScaleFactor = 10
        pdfView.document = pdfDocument
        pdfView.scaleFactor = 1
        pdfView.layoutDocumentView()
        let overlay = PortalPDFInkOverlayView(frame: pdfView.bounds)
        overlay.configure(page: page, pdfView: pdfView, pageEditData: editPage)
        overlay.layoutIfNeeded()

        #expect(overlay.renderedTextResizeHandleCount == 8)
        #expect(overlay.renderedTextFontNames.allSatisfy { !$0.contains("TimesNewRoman") })
        let initialScale = try #require(overlay.renderedTextContentsScales.first)
        #expect(initialScale == 13 + overlay.traitCollection.displayScale)

        pdfView.scaleFactor = 4
        pdfView.layoutDocumentView()
        pdfView.layoutIfNeeded()
        overlay.refreshTextRenderingScale()

        let zoomedScale = try #require(overlay.renderedTextContentsScales.first)
        #expect(zoomedScale == initialScale)

        text.editingBounds = CGRect(x: 80, y: 160, width: 260, height: 72)
        overlay.updateTextAnnotationPresentation(text)
        #expect(overlay.renderedPageEditObjectLayerCount == 1)
        #expect(overlay.renderedTextResizeHandleCount == 8)
    }

    @Test func lassoSelectsAndMovesInkImageShapeAndTextAsOneLiveGroup() throws {
        let pdfDocument = try #require(PDFDocument(data: makeOnePagePDFData()))
        let page = try #require(pdfDocument.page(at: 0))

        let ink = PDFAnnotation(
            bounds: CGRect(x: 80, y: 100, width: 70, height: 24),
            forType: .ink,
            withProperties: nil
        )
        let inkPath = UIBezierPath()
        inkPath.move(to: CGPoint(x: 2, y: 4))
        inkPath.addLine(to: CGPoint(x: 66, y: 20))
        ink.add(inkPath)
        page.addAnnotation(ink)

        let image = PortalPDFImageAnnotation(
            image: solidImage(color: .systemYellow),
            bounds: CGRect(x: 105, y: 120, width: 48, height: 48)
        )
        page.addAnnotation(image)
        let shape = PortalPDFShapeAnnotation(
            shapeType: .rectangle,
            bounds: CGRect(x: 155, y: 125, width: 54, height: 46),
            lineWidth: 2
        )
        page.addAnnotation(shape)
        let text = PortalPDFTextAnnotation(
            text: "올가미 텍스트",
            bounds: CGRect(x: 215, y: 130, width: 130, height: 48)
        )
        page.addAnnotation(text)

        let editPage = try #require(PortalPDFPageEditDocument.capture(from: pdfDocument).page(at: 0))
        let pdfView = PDFView(frame: CGRect(x: 0, y: 0, width: 612, height: 792))
        pdfView.document = pdfDocument
        pdfView.layoutDocumentView()
        let overlay = PortalPDFInkOverlayView(frame: pdfView.bounds)
        overlay.configure(page: page, pdfView: pdfView, pageEditData: editPage)
        overlay.layoutIfNeeded()

        let coordinator = PortalPDFKitView.Coordinator()
        coordinator.pdfView = pdfView
        coordinator.pageOverlayViews[ObjectIdentifier(page)] = overlay
        coordinator.activeLassoPage = page
        coordinator.activeLassoPoints = [
            CGPoint(x: 60, y: 80),
            CGPoint(x: 370, y: 80),
            CGPoint(x: 370, y: 210),
            CGPoint(x: 60, y: 210),
        ]
        coordinator.completeLassoSelection(on: page, in: pdfView)

        #expect(coordinator.selectedLassoAnnotations.count == 4)
        #expect(coordinator.selectedLassoAnnotations.contains { $0.isPortalInkAnnotation })
        #expect(coordinator.selectedLassoAnnotations.contains { $0 is PortalPDFImageAnnotation })
        #expect(coordinator.selectedLassoAnnotations.contains { $0 is PortalPDFShapeAnnotation })
        #expect(coordinator.selectedLassoAnnotations.contains { $0 is PortalPDFTextAnnotation })

        let selectedIDs = coordinator.selectedLassoAnnotations.map(\.portalPageEditObjectID)
        let positionsBefore = Dictionary(uniqueKeysWithValues: selectedIDs.map {
            ($0, overlay.renderedLayerPositions(for: $0))
        })
        let originalTextBounds = text.editingBounds
        let delta = CGPoint(x: 26, y: 18)
        let appliedDelta = coordinator.moveLassoSelection(by: delta, on: page)

        #expect(appliedDelta == delta)
        #expect(text.editingBounds == originalTextBounds.offsetBy(dx: delta.x, dy: delta.y))
        for objectID in selectedIDs {
            let before = try #require(positionsBefore[objectID])
            let after = overlay.renderedLayerPositions(for: objectID)
            #expect(!before.isEmpty)
            #expect(after.count == before.count)
            #expect(zip(before, after).allSatisfy { $0.0 != $0.1 })
        }

        coordinator.refreshPersistentAnnotationOverlay(on: page)
        coordinator.clearLassoSelection()
        let persistedText = try #require(
            coordinator.pageEditDocument.page(at: 0)?.objects.first(where: { $0.kind == .text })?.text
        )
        #expect(persistedText.bounds == text.editingBounds)
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
        #expect(try Data(contentsOf: sourceURL).starts(with: Data("bplist00".utf8)))
        #expect(repository.load(identifier: "source-document")?.formatVersion == 1)

        try repository.copy(from: "source-document", to: "copied-document")
        #expect(repository.load(identifier: "copied-document")?.pages.first?.pageIndex == 2)

        try repository.remove(identifier: "source-document")
        #expect(repository.load(identifier: "source-document") == nil)
        #expect(repository.load(identifier: "copied-document") != nil)

        try repository.removeAll()
        #expect(!fileManager.fileExists(atPath: directory.path))
    }

    @Test func overlayAppendsOneInkWithoutRebuildingExistingImagesAndStrokes() async throws {
        let pdfDocument = try #require(PDFDocument(data: makeOnePagePDFData()))
        let page = try #require(pdfDocument.page(at: 0))
        for index in 0..<180 {
            addInk(to: page, index: index)
        }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24)).image { context in
            UIColor.systemIndigo.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
        }
        for index in 0..<12 {
            page.addAnnotation(PortalPDFImageAnnotation(
                image: image,
                bounds: CGRect(x: CGFloat(30 + index * 12), y: 360, width: 54, height: 54)
            ))
        }

        var edits = PortalPDFPageEditDocument.capture(from: pdfDocument)
        let initialPage = try #require(edits.page(at: 0))
        let pdfView = PDFView(frame: CGRect(x: 0, y: 0, width: 612, height: 792))
        pdfView.document = pdfDocument
        pdfView.layoutDocumentView()
        let overlay = PortalPDFInkOverlayView(frame: pdfView.bounds)
        overlay.configure(page: page, pdfView: pdfView, pageEditData: initialPage)
        let initialGeneration = overlay.pageEditRenderGeneration

        let appendedInk = addInk(to: page, index: 181)
        let didAppend = edits.append(
            annotation: appendedInk,
            at: page.annotations.count - 1,
            to: 0
        )
        #expect(didAppend)
        let updatedPage = try #require(edits.page(at: 0))
        var hiddenWhileRasterizing = false
        await withCheckedContinuation { continuation in
            overlay.updatePageEditData(
                updatedPage,
                appendedStrokeRasterReady: {
                    continuation.resume()
                }
            )
            hiddenWhileRasterizing = overlay.hiddenCompletedStrokeLayerCount == 1
        }

        #expect(overlay.pageEditRenderGeneration == initialGeneration)
        #expect(overlay.renderedInkStrokeCount == 181)
        #expect(overlay.renderedImageCount == 12)
        #expect(overlay.completedStrokeLayersUseBoundedRasterCache)
        #expect(overlay.completedStrokeRasterImageCount == 1)
        #expect(hiddenWhileRasterizing)
        #expect(overlay.hiddenCompletedStrokeLayerCount == 0)
    }

    @Test func overlayBoundsChangesTransformContainersWithoutRebuildingObjects() throws {
        let pdfDocument = try #require(PDFDocument(data: makeOnePagePDFData()))
        let page = try #require(pdfDocument.page(at: 0))
        for index in 0..<120 {
            addInk(to: page, index: index)
        }
        let editPage = try #require(PortalPDFPageEditDocument.capture(from: pdfDocument).page(at: 0))
        let pdfView = PDFView(frame: CGRect(x: 0, y: 0, width: 612, height: 792))
        pdfView.document = pdfDocument
        pdfView.layoutDocumentView()
        let overlay = PortalPDFInkOverlayView(frame: pdfView.bounds)
        overlay.configure(page: page, pdfView: pdfView, pageEditData: editPage)
        let initialGeneration = overlay.pageEditRenderGeneration

        for scale in [1.1, 1.4, 0.9, 1.8, 1.0] {
            overlay.frame.size = CGSize(width: 612 * scale, height: 792 * scale)
            overlay.setNeedsLayout()
            overlay.layoutIfNeeded()
        }

        #expect(overlay.pageEditRenderGeneration == initialGeneration)
        #expect(overlay.renderedInkStrokeCount == 120)
    }

    @Test func completedInkRasterCacheUsesFileManagerZoomPlusOverscale() throws {
        let pdfDocument = try #require(PDFDocument(data: makeOnePagePDFData()))
        let page = try #require(pdfDocument.page(at: 0))
        addInk(to: page, index: 0)
        let editPage = try #require(PortalPDFPageEditDocument.capture(from: pdfDocument).page(at: 0))
        let pdfView = PDFView(frame: CGRect(x: 0, y: 0, width: 612, height: 792))
        pdfView.autoScales = false
        pdfView.minScaleFactor = 0.1
        pdfView.maxScaleFactor = 10
        pdfView.document = pdfDocument
        pdfView.scaleFactor = 10
        pdfView.layoutDocumentView()
        let overlay = PortalPDFInkOverlayView(frame: pdfView.bounds)
        overlay.configure(page: page, pdfView: pdfView, pageEditData: editPage)

        let highZoomRasterScale = pdfView.scaleFactor + 5
        #expect(overlay.completedStrokeRasterizationScales.allSatisfy {
            abs($0 - highZoomRasterScale) < 0.001
        })

        pdfView.scaleFactor = 2
        overlay.refreshCompletedStrokeRasterizationScale()
        let updatedRasterScale = pdfView.scaleFactor + 5
        #expect(overlay.completedStrokeRasterizationScales.allSatisfy {
            abs($0 - updatedRasterScale) < 0.001
        })
    }

    @Test func selectedImagePresentationUpdatesWithoutRebuildingDensePage() throws {
        let pdfDocument = try #require(PDFDocument(data: makeOnePagePDFData()))
        let page = try #require(pdfDocument.page(at: 0))
        for index in 0..<160 {
            addInk(to: page, index: index)
        }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        }
        let imageAnnotation = PortalPDFImageAnnotation(
            image: image,
            bounds: CGRect(x: 180, y: 240, width: 90, height: 90)
        )
        imageAnnotation.isPortalSelected = true
        page.addAnnotation(imageAnnotation)
        let editPage = try #require(PortalPDFPageEditDocument.capture(from: pdfDocument).page(at: 0))
        let pdfView = PDFView(frame: CGRect(x: 0, y: 0, width: 612, height: 792))
        pdfView.document = pdfDocument
        pdfView.layoutDocumentView()
        let overlay = PortalPDFInkOverlayView(frame: pdfView.bounds)
        overlay.configure(page: page, pdfView: pdfView, pageEditData: editPage)
        let initialGeneration = overlay.pageEditRenderGeneration

        for offset in stride(from: CGFloat(0), through: 120, by: 6) {
            imageAnnotation.editingBounds = CGRect(
                x: 180 + offset,
                y: 240 - offset / 2,
                width: 90 + offset / 4,
                height: 90 + offset / 4
            )
            imageAnnotation.rotationAngle = offset / 200
            overlay.updateImageAnnotationPresentation(imageAnnotation)
        }

        #expect(overlay.pageEditRenderGeneration == initialGeneration)
        #expect(overlay.renderedInkStrokeCount == 160)
        #expect(overlay.renderedImageCount == 1)
    }

    @Test func animatedGIFSourceDataRoundTripsThroughPageEditSidecar() throws {
        let pdfDocument = try #require(PDFDocument(data: makeOnePagePDFData()))
        let page = try #require(pdfDocument.page(at: 0))
        let poster = UIGraphicsImageRenderer(size: CGSize(width: 12, height: 12)).image { context in
            UIColor.systemPurple.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 12, height: 12))
        }
        let gifData = Data("GIF89a-NF-two-frame-source".utf8)
        page.addAnnotation(PortalPDFImageAnnotation(
            image: poster,
            persistedImageData: try #require(poster.pngData()),
            bounds: CGRect(x: 80, y: 100, width: 96, height: 96),
            animatedGIFData: gifData
        ))

        let edits = PortalPDFPageEditDocument.capture(from: pdfDocument)
        let capturedImage = try #require(edits.page(at: 0)?.objects.first?.image)
        #expect(capturedImage.animatedGIFData == gifData)

        let testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NFGIFEdits-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: testDirectory) }
        let repository = PortalPDFPageEditRepository(directoryURL: testDirectory)
        try repository.save(edits, identifier: "animated-gif")
        let restored = try #require(repository.load(identifier: "animated-gif"))
        #expect(restored.page(at: 0)?.objects.first?.image?.animatedGIFData == gifData)
    }

    @Test func animatedGIFUsesOnePersistentImageLayerWithContentsAnimation() async throws {
        let pdfDocument = try #require(PDFDocument(data: makeOnePagePDFData()))
        let page = try #require(pdfDocument.page(at: 0))
        let red = solidImage(color: .systemRed)
        let blue = solidImage(color: .systemBlue)
        let gifData = try #require(makeAnimatedGIFData(images: [red, blue]))
        page.addAnnotation(PortalPDFImageAnnotation(
            image: red,
            persistedImageData: try #require(red.pngData()),
            bounds: CGRect(x: 90, y: 120, width: 100, height: 100),
            animatedGIFData: gifData
        ))
        let editPage = try #require(PortalPDFPageEditDocument.capture(from: pdfDocument).page(at: 0))
        let pdfView = PDFView(frame: CGRect(x: 0, y: 0, width: 612, height: 792))
        pdfView.document = pdfDocument
        pdfView.layoutDocumentView()
        let overlay = PortalPDFInkOverlayView(frame: pdfView.bounds)
        overlay.configure(page: page, pdfView: pdfView, pageEditData: editPage)

        for _ in 0..<50 where overlay.renderedAnimatedImageCount == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(overlay.renderedImageCount == 1)
        #expect(overlay.renderedAnimatedImageCount == 1)
    }

    @discardableResult
    private func addInk(to page: PDFPage, index: Int) -> PDFAnnotation {
        let y = CGFloat(30 + (index % 300))
        let annotation = PDFAnnotation(
            bounds: CGRect(x: 20, y: y, width: 180, height: 16),
            forType: .ink,
            withProperties: nil
        )
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 2, y: 3))
        path.addLine(to: CGPoint(x: 176, y: 12))
        annotation.add(path)
        let border = PDFBorder()
        border.lineWidth = 2
        annotation.border = border
        page.addAnnotation(annotation)
        return annotation
    }

    private func makeOnePagePDFData() -> Data {
        let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        return UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            context.beginPage()
            UIColor.white.setFill()
            context.cgContext.fill(bounds)
        }
    }

    private func solidImage(color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 12, height: 12)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 12, height: 12))
        }
    }

    private func makeAnimatedGIFData(images: [UIImage]) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.gif.identifier as CFString,
            images.count,
            nil
        ) else { return nil }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ] as CFDictionary)
        for image in images {
            guard let cgImage = image.cgImage else { continue }
            CGImageDestinationAddImage(destination, cgImage, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.05]
            ] as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
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
