//
//  PortalPDFAnnotationRenderingTests.swift
//  NFTests
//
//  PDFKit 커스텀 Annotation이 페이지 좌표계에서 실제로 렌더링되는지 검증합니다.
//

import PDFKit
import UIKit
import XCTest
@testable import NF

@MainActor
final class PortalPDFAnnotationRenderingTests: XCTestCase {
    private let pageSize = CGSize(width: 320, height: 480)

    func testZoomPercentageReportingCoalesces1000PercentRoundTrip() async throws {
        let coordinator = PortalPDFKitView.Coordinator()
        let document = PDFDocument()
        document.insert(try makeBlankPage(), at: 0)
        let pdfView = PDFView(frame: CGRect(origin: .zero, size: pageSize))
        pdfView.autoScales = false
        pdfView.minScaleFactor = 0.1
        pdfView.maxScaleFactor = 10
        pdfView.document = document

        var reportedPercentages: [Int] = []
        coordinator.updateZoomPercentageChangedHandler { percentage in
            reportedPercentages.append(percentage)
        }

        for percentage in stride(from: 100, through: 1_000, by: 5) {
            pdfView.scaleFactor = CGFloat(percentage) / 100
            coordinator.reportZoomPercentage(in: pdfView)
        }
        for percentage in stride(from: 1_000, through: 100, by: -5) {
            pdfView.scaleFactor = CGFloat(percentage) / 100
            coordinator.reportZoomPercentage(in: pdfView)
        }

        try await Task.sleep(for: .milliseconds(80))

        XCTAssertEqual(reportedPercentages, [100])
    }

    func testHistoryPolicyReducesSnapshotsForAnnotationDensePages() {
        XCTAssertEqual(PortalPDFHistoryPolicy.maximumUndoCount(maximumPageEditUnitCount: 10), 20)
        XCTAssertEqual(PortalPDFHistoryPolicy.maximumUndoCount(maximumPageEditUnitCount: 30), 12)
        XCTAssertEqual(PortalPDFHistoryPolicy.maximumUndoCount(maximumPageEditUnitCount: 85), 6)

        let groupedInk = PDFAnnotation(
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            forType: .ink,
            withProperties: nil
        )
        for index in 0..<85 {
            let path = UIBezierPath()
            path.move(to: CGPoint(x: CGFloat(index), y: 0))
            path.addLine(to: CGPoint(x: CGFloat(index), y: 10))
            groupedInk.add(path)
        }
        XCTAssertEqual(PortalPDFHistoryPolicy.editUnitCount(for: [groupedInk]), 85)
        XCTAssertEqual(
            PortalPDFHistoryPolicy.maximumUndoCount(
                maximumPageEditUnitCount: PortalPDFHistoryPolicy.editUnitCount(for: [groupedInk])
            ),
            6
        )
    }

    func testInkOverlayPreservesPathsWhileNativeRenderingIsSuppressed() throws {
        let page = try makeBlankPage()
        let annotation = PDFAnnotation(
            bounds: CGRect(x: 40, y: 80, width: 220, height: 260),
            forType: .ink,
            withProperties: nil
        )
        annotation.color = .systemBlue
        let border = PDFBorder()
        border.lineWidth = 2.4
        annotation.border = border
        for offset in [CGFloat(0), 40] {
            let path = UIBezierPath()
            path.lineCapStyle = .round
            path.move(to: CGPoint(x: 10 + offset, y: 20))
            path.addLine(to: CGPoint(x: 150 + offset, y: 220))
            annotation.add(path)
        }
        page.addAnnotation(annotation)
        let document = PDFDocument()
        document.insert(page, at: 0)

        let pdfView = PDFView(frame: CGRect(origin: .zero, size: pageSize))
        pdfView.document = document
        pdfView.layoutDocumentView()
        PortalPDFInkDisplaySuppression.suppress(in: document)
        defer { PortalPDFInkDisplaySuppression.restore(in: document) }
        XCTAssertFalse(annotation.shouldDisplay)

        let overlay = PortalPDFInkOverlayView(frame: CGRect(origin: .zero, size: pageSize))
        overlay.configure(page: page, pdfView: pdfView)
        overlay.layoutIfNeeded()
        XCTAssertEqual(overlay.renderedInkStrokeCount, 2)
        XCTAssertFalse(overlay.renderedInkBounds.isNull)
        XCTAssertTrue(overlay.renderedInkBounds.intersects(overlay.bounds))

        let savedData = try XCTUnwrap(document.portalEditableDataRepresentation())
        XCTAssertFalse(annotation.shouldDisplay, "직렬화 후 화면용 PDFKit 억제 상태는 다시 적용되어야 합니다.")
        let reloadedPage = try XCTUnwrap(PDFDocument(data: savedData)?.page(at: 0))
        let reloadedInk = try XCTUnwrap(reloadedPage.annotations.first(where: \.isPortalInkAnnotation))
        XCTAssertTrue(reloadedInk.shouldDisplay, "저장 파일의 Ink 표시 플래그는 원래 상태를 유지해야 합니다.")
        XCTAssertEqual(reloadedInk.paths?.count, 2)
    }

    func testEditableImageOverlayReusesSourcePixelsAt1000Percent() throws {
        let page = try makeBlankPage()
        let image = verticallyMarkedImage()
        let annotation = PortalPDFImageAnnotation(
            image: image,
            bounds: CGRect(x: 70, y: 150, width: 180, height: 120)
        )
        annotation.isPortalSelected = true
        page.addAnnotation(annotation)
        let document = PDFDocument()
        document.insert(page, at: 0)

        let pdfView = PDFView(frame: CGRect(origin: .zero, size: pageSize))
        pdfView.autoScales = false
        pdfView.minScaleFactor = 0.1
        pdfView.maxScaleFactor = 10
        pdfView.document = document
        pdfView.scaleFactor = 10
        pdfView.layoutDocumentView()
        pdfView.layoutIfNeeded()

        PortalPDFInkDisplaySuppression.suppress(in: document)
        defer { PortalPDFInkDisplaySuppression.restore(in: document) }
        XCTAssertFalse(annotation.shouldDisplay)
        XCTAssertEqual(annotation.bounds, .zero)

        let overlay = PortalPDFInkOverlayView(frame: CGRect(origin: .zero, size: pageSize))
        overlay.configure(page: page, pdfView: pdfView)
        overlay.layoutIfNeeded()

        XCTAssertEqual(overlay.renderedImageCount, 1)
        XCTAssertEqual(overlay.renderedImagePixelSizes, [CGSize(width: 48, height: 32)])
        XCTAssertGreaterThan(overlay.renderedImageSelectionLayerCount, 0)

        let savedData = try XCTUnwrap(document.portalEditableDataRepresentation())
        XCTAssertFalse(annotation.shouldDisplay, "직렬화 뒤 화면용 이미지 억제 상태가 다시 적용되어야 합니다.")
        XCTAssertEqual(annotation.bounds, .zero, "직렬화 뒤에도 PDFKit 이미지 렌더링 영역은 비워져야 합니다.")
        let reloadedPage = try XCTUnwrap(PDFDocument(data: savedData)?.page(at: 0))
        let reloadedImage = try XCTUnwrap(reloadedPage.annotations.first {
            $0.contents?.hasPrefix(PortalPDFImageAnnotation.metadataPrefix) == true
        })
        XCTAssertTrue(reloadedImage.shouldDisplay, "저장 파일의 이미지 표시 플래그는 원래 상태를 유지해야 합니다.")
        XCTAssertGreaterThan(reloadedImage.bounds.width, 0)
        XCTAssertGreaterThan(reloadedImage.bounds.height, 0)
    }

    func testStandardInkCompactorGroupsConsecutiveMatchingStrokes() throws {
        let annotations = (0..<12).map { index -> PDFAnnotation in
            let bounds = CGRect(x: CGFloat(index) * 20, y: 40, width: 12, height: 12)
            let annotation = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
            annotation.color = .systemBlue
            let border = PDFBorder()
            border.lineWidth = 2
            annotation.border = border
            let path = UIBezierPath()
            path.lineCapStyle = .round
            path.move(to: CGPoint(x: 1, y: 6))
            path.addLine(to: CGPoint(x: 11, y: 6))
            annotation.add(path)
            return annotation
        }

        let compacted = PortalPDFStandardInkCompactor.compactedAnnotations(
            from: annotations,
            minimumRunLength: 12
        )

        XCTAssertEqual(compacted.count, 1)
        XCTAssertEqual(compacted.reduce(0) { $0 + ($1.paths?.count ?? 0) }, 12)
        XCTAssertTrue(compacted.allSatisfy {
            ($0.paths?.count ?? 0) <= PortalPDFStandardInkCompactor.maximumPathsPerAnnotation
        })
        let firstGrouped = try XCTUnwrap(compacted.first)
        let lastGrouped = try XCTUnwrap(compacted.last)
        let lastPath = try XCTUnwrap(lastGrouped.paths?.last)
        XCTAssertEqual(lastGrouped.bounds.minX + lastPath.currentPoint.x, 231, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(firstGrouped.border).lineWidth, 2, accuracy: 0.001)
        XCTAssertTrue(firstGrouped.color.isEqual(UIColor.systemBlue))

        let page = try makeBlankPage()
        compacted.forEach { page.addAnnotation($0) }
        let rendered = render(page)
        let firstStrokePixel = try rgba(in: rendered, atPDFPoint: CGPoint(x: 6, y: 46))
        let lastStrokePixel = try rgba(in: rendered, atPDFPoint: CGPoint(x: 226, y: 46))
        XCTAssertGreaterThan(firstStrokePixel.blue, firstStrokePixel.red)
        XCTAssertGreaterThan(lastStrokePixel.blue, lastStrokePixel.red)
        XCTAssertEqual(PortalPDFHistoryPolicy.editUnitCount(for: compacted), 12)

        let secondPass = PortalPDFStandardInkCompactor.compactedAnnotations(from: compacted)
        XCTAssertEqual(secondPass.count, compacted.count)
        XCTAssertTrue(zip(compacted, secondPass).allSatisfy { pair in pair.0 === pair.1 })
    }

    func testSavedInkIsSplitOnlyAtVectorPathLimit() {
        let oversized = PDFAnnotation(
            bounds: CGRect(x: 140, y: 424, width: 1_665, height: 2_083),
            forType: .ink,
            withProperties: nil
        )
        oversized.color = .systemBlue
        let border = PDFBorder()
        border.lineWidth = 2.4
        oversized.border = border
        for index in 0..<260 {
            let column = CGFloat(index % 8)
            let row = CGFloat(index / 8)
            let path = UIBezierPath()
            path.move(to: CGPoint(x: column * 190, y: row * 135))
            path.addLine(to: CGPoint(x: column * 190 + 60, y: row * 135 + 40))
            oversized.add(path)
        }

        let split = PortalPDFStandardInkCompactor.compactedAnnotations(from: [oversized])

        XCTAssertGreaterThan(split.count, 1)
        XCTAssertEqual(split.count, 3)
        XCTAssertEqual(split.reduce(0) { $0 + ($1.paths?.count ?? 0) }, 260)
        XCTAssertTrue(split.allSatisfy {
            ($0.paths?.count ?? 0) <= PortalPDFStandardInkCompactor.maximumPathsPerAnnotation
        })
    }

    func testStandardInkCompactorPreservesNonInkZOrderBoundary() {
        let firstInk = makeInkAnnotationForCompactionTest(x: 0)
        let stamp = PDFAnnotation(
            bounds: CGRect(x: 10, y: 10, width: 20, height: 20),
            forType: .stamp,
            withProperties: nil
        )
        let secondInk = makeInkAnnotationForCompactionTest(x: 40)

        let compacted = PortalPDFStandardInkCompactor.compactedAnnotations(
            from: [firstInk, stamp, secondInk],
            minimumRunLength: 2
        )

        XCTAssertEqual(compacted.count, 3)
        XCTAssertTrue(compacted[0] === firstInk)
        XCTAssertTrue(compacted[1] === stamp)
        XCTAssertTrue(compacted[2] === secondInk)
    }

    func testImageInsertionKeepsAverageScreenSizeAcrossZoomLevels() {
        let imageSize = CGSize(width: 1_200, height: 800)
        let viewportSize = CGSize(width: 1_024, height: 1_366)
        let pageBounds = CGRect(x: 0, y: 0, width: 900, height: 1_200)
        let center = CGPoint(x: 450, y: 600)
        let normalBounds = PortalPDFImageInsertionLayout.bounds(
            imageSize: imageSize,
            viewportSize: viewportSize,
            scaleFactor: 1,
            pageBounds: pageBounds,
            center: center
        )
        let zoomedBounds = PortalPDFImageInsertionLayout.bounds(
            imageSize: imageSize,
            viewportSize: viewportSize,
            scaleFactor: 2,
            pageBounds: pageBounds,
            center: center
        )

        XCTAssertEqual(normalBounds.midX, center.x, accuracy: 0.001)
        XCTAssertEqual(normalBounds.midY, center.y, accuracy: 0.001)
        XCTAssertEqual(zoomedBounds.midX, center.x, accuracy: 0.001)
        XCTAssertEqual(zoomedBounds.midY, center.y, accuracy: 0.001)
        XCTAssertEqual(normalBounds.width, zoomedBounds.width * 2, accuracy: 0.001)
        XCTAssertEqual(normalBounds.height, zoomedBounds.height * 2, accuracy: 0.001)
        XCTAssertEqual(normalBounds.width / normalBounds.height, 1.5, accuracy: 0.001)
    }

    private func makeInkAnnotationForCompactionTest(x: CGFloat) -> PDFAnnotation {
        let annotation = PDFAnnotation(
            bounds: CGRect(x: x, y: 0, width: 12, height: 12),
            forType: .ink,
            withProperties: nil
        )
        annotation.color = .black
        let border = PDFBorder()
        border.lineWidth = 2
        annotation.border = border
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 1, y: 6))
        path.addLine(to: CGPoint(x: 11, y: 6))
        annotation.add(path)
        return annotation
    }

    func testImageSelectionDashKeepsScreenRatioAcrossZoomLevels() {
        let annotation = PortalPDFImageAnnotation(
            image: UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { context in
                UIColor.systemBlue.setFill()
                context.cgContext.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
            },
            bounds: CGRect(x: 30, y: 40, width: 120, height: 120)
        )

        annotation.updateEditingDisplayScaleFactor(1)
        let normalLineWidth = annotation.displayedSelectionLineWidth
        let normalDashLengths = annotation.displayedSelectionDashLengths
        let normalPadding = annotation.displayedSelectionPadding
        annotation.updateEditingDisplayScaleFactor(2)

        XCTAssertEqual(annotation.displayedSelectionLineWidth * 2, normalLineWidth, accuracy: 0.001)
        XCTAssertEqual(annotation.displayedSelectionDashLengths[0] * 2, normalDashLengths[0], accuracy: 0.001)
        XCTAssertEqual(annotation.displayedSelectionDashLengths[1] * 2, normalDashLengths[1], accuracy: 0.001)
        XCTAssertEqual(annotation.displayedSelectionPadding * 2, normalPadding, accuracy: 0.001)
    }

    func testNearbyImageSelectionPrefersTouchedContentOverTopAnnotationBounds() {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { context in
            UIColor.systemBlue.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        }
        let firstImage = PortalPDFImageAnnotation(
            image: image,
            bounds: CGRect(x: 20, y: 80, width: 100, height: 100)
        )
        let laterNearbyImage = PortalPDFImageAnnotation(
            image: image,
            bounds: CGRect(x: 145, y: 80, width: 100, height: 100)
        )
        let pointInsideFirstImage = CGPoint(x: 115, y: 130)

        XCTAssertTrue(
            laterNearbyImage.bounds.contains(pointInsideFirstImage),
            "편집 아이콘용 확장 bounds가 가까운 이전 이미지 본문까지 겹치는 조건이어야 합니다."
        )
        let selected = PortalPDFEditableAnnotationHitTesting.topmostAnnotation(
            in: [firstImage, laterNearbyImage],
            at: pointInsideFirstImage,
            scaleFactor: 1
        )
        XCTAssertTrue(selected === firstImage)
    }

    func testDirectObjectSelectionFindsImageShapeAndTopmostText() {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { context in
            UIColor.systemBlue.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        }
        let imageAnnotation = PortalPDFImageAnnotation(
            image: image,
            bounds: CGRect(x: 20, y: 20, width: 80, height: 80)
        )
        let shapeAnnotation = PortalPDFShapeAnnotation(
            shapeType: .rectangle,
            bounds: CGRect(x: 120, y: 20, width: 80, height: 80),
            lineWidth: 2
        )
        let standaloneImageAnnotation = PortalPDFImageAnnotation(
            image: image,
            bounds: CGRect(x: 220, y: 20, width: 80, height: 80)
        )
        let textAnnotation = PortalPDFTextAnnotation(
            text: "선택",
            bounds: CGRect(x: 20, y: 20, width: 80, height: 80)
        )
        let annotations: [PDFAnnotation] = [
            imageAnnotation,
            shapeAnnotation,
            standaloneImageAnnotation,
            textAnnotation,
        ]

        let selectedOverlappingObject = PortalPDFEditableAnnotationHitTesting.topmostSelectableObject(
            in: annotations,
            at: CGPoint(x: 60, y: 60),
            scaleFactor: 1
        )
        let selectedShape = PortalPDFEditableAnnotationHitTesting.topmostSelectableObject(
            in: annotations,
            at: CGPoint(x: 160, y: 60),
            scaleFactor: 1
        )
        let selectedImage = PortalPDFEditableAnnotationHitTesting.topmostSelectableObject(
            in: annotations,
            at: CGPoint(x: 260, y: 60),
            scaleFactor: 1
        )

        XCTAssertTrue(selectedOverlappingObject === textAnnotation)
        XCTAssertTrue(selectedShape === shapeAnnotation)
        XCTAssertTrue(selectedImage === standaloneImageAnnotation)
    }

    func testImageEditingHandlesRemainHittableAfterScaleChange() {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { context in
            UIColor.systemBlue.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        }
        let annotation = PortalPDFImageAnnotation(
            image: image,
            bounds: CGRect(x: 80, y: 100, width: 160, height: 120)
        )

        annotation.updateEditingDisplayScaleFactor(2)
        XCTAssertTrue(annotation.isTransformHandleHit(annotation.transformHandleCenter, scaleFactor: 2))
        XCTAssertTrue(annotation.isDeleteHandleHit(annotation.deleteHandleCenter, scaleFactor: 2))
    }

    func testImageResizeHandlesExistOnlyAtFourSideCenters() {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { context in
            UIColor.systemBlue.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        }
        let annotation = PortalPDFImageAnnotation(
            image: image,
            bounds: CGRect(x: 80, y: 100, width: 160, height: 120)
        )
        annotation.rotationAngle = .pi / 6
        annotation.updateEditingDisplayScaleFactor(2)

        XCTAssertEqual(Set(annotation.unrotatedResizeHandleCenters.keys), Set([
            .topCenter,
            .middleLeft,
            .middleRight,
            .bottomCenter,
        ]))

        let center = annotation.editingBounds.center
        let cosine = cos(annotation.rotationAngle)
        let sine = sin(annotation.rotationAngle)
        for (expectedHandle, unrotatedPoint) in annotation.unrotatedResizeHandleCenters {
            let offset = CGPoint(x: unrotatedPoint.x - center.x, y: unrotatedPoint.y - center.y)
            let rotatedPoint = CGPoint(
                x: center.x + offset.x * cosine - offset.y * sine,
                y: center.y + offset.x * sine + offset.y * cosine
            )
            XCTAssertEqual(
                annotation.resizeHandle(at: rotatedPoint, scaleFactor: 2),
                expectedHandle
            )
        }
    }

    func testImageHistoryClonePreservesEditableStateIndependently() {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 16)).image { context in
            UIColor.systemBlue.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 24, height: 16))
        }
        let annotation = PortalPDFImageAnnotation(
            image: image,
            bounds: CGRect(x: 40, y: 70, width: 180, height: 120)
        )
        annotation.rotationAngle = .pi / 4
        annotation.isHorizontallyFlipped = true
        let clone = annotation.historyClone()

        XCTAssertFalse(clone === annotation)
        XCTAssertEqual(clone.editingBounds, annotation.editingBounds)
        XCTAssertEqual(clone.rotationAngle, annotation.rotationAngle, accuracy: 0.001)
        XCTAssertEqual(clone.isHorizontallyFlipped, annotation.isHorizontallyFlipped)

        clone.editingBounds = clone.editingBounds.offsetBy(dx: 20, dy: 10)
        XCTAssertNotEqual(clone.editingBounds, annotation.editingBounds)
    }

    func testInkAnnotationIsRecognizedWhenPDFKitOmitsSubtypeSlash() {
        let inkAnnotation = PDFAnnotation(
            bounds: CGRect(x: 10, y: 10, width: 40, height: 40),
            forType: .ink,
            withProperties: nil
        )
        let squareAnnotation = PDFAnnotation(
            bounds: CGRect(x: 10, y: 10, width: 40, height: 40),
            forType: .square,
            withProperties: nil
        )

        XCTAssertTrue(inkAnnotation.isPortalInkAnnotation, "Ink 주석은 펜 지우개 삭제 대상으로 인식되어야 합니다.")
        XCTAssertFalse(squareAnnotation.isPortalInkAnnotation, "박스 주석은 펜 지우개로 삭제되면 안 됩니다.")
    }

    func testPressureInkRemainsErasableAfterPDFRoundTrip() throws {
        let page = try makeBlankPage()
        let points = [
            CGPoint(x: 48, y: 120),
            CGPoint(x: 96, y: 146),
            CGPoint(x: 150, y: 138),
            CGPoint(x: 212, y: 172)
        ]
        let annotation = PortalPDFPressureInkAnnotation(
            points: points,
            pressures: [0.2, 0.45, 0.8, 0.55],
            baseLineWidth: 5,
            color: .systemBlue
        )
        page.addAnnotation(annotation)

        let document = PDFDocument()
        document.insert(page, at: 0)
        let data = try XCTUnwrap(document.dataRepresentation())
        let reloadedDocument = try XCTUnwrap(PDFDocument(data: data))
        let reloadedPage = try XCTUnwrap(reloadedDocument.page(at: 0))
        let reloadedAnnotation = try XCTUnwrap(reloadedPage.annotations.first)

        XCTAssertTrue(
            PortalPDFPressureInkAnnotation.isPressureInk(reloadedAnnotation),
            "저장 후 일반 Stamp로 다시 생성돼도 압력식 획 식별자가 유지되어야 합니다."
        )
        XCTAssertTrue(
            PortalPDFPressureInkAnnotation.containsStroke(
                in: reloadedAnnotation,
                point: points[1],
                extraRadius: 12
            ),
            "저장 후에도 실제 중심선 위치에서 지우개 충돌이 인식되어야 합니다."
        )
        XCTAssertFalse(
            PortalPDFPressureInkAnnotation.containsStroke(
                in: reloadedAnnotation,
                point: CGPoint(x: 290, y: 420),
                extraRadius: 12
            ),
            "압력식 획과 멀리 떨어진 위치는 지우개 대상으로 인식되면 안 됩니다."
        )

        reloadedAnnotation.shouldDisplay = false
        reloadedAnnotation.shouldPrint = false
        reloadedPage.removeAnnotation(reloadedAnnotation)
        XCTAssertTrue(reloadedPage.annotations.isEmpty, "선택한 압력식 획이 페이지에서 실제로 제거되어야 합니다.")
    }

    func testSinglePressureInkPDFSizeStaysNearStandardInk() throws {
        let blankData = makeVectorBlankPDFData()

        let inkDocument = try XCTUnwrap(PDFDocument(data: blankData))
        let inkPage = try XCTUnwrap(inkDocument.page(at: 0))
        let inkPath = UIBezierPath()
        inkPath.move(to: CGPoint(x: 90, y: 80))
        inkPath.addLine(to: CGPoint(x: 205, y: 340))
        let inkAnnotation = PDFAnnotation(
            bounds: inkPath.bounds.insetBy(dx: -10, dy: -10),
            forType: .ink,
            withProperties: nil
        )
        let localPath = inkPath.translatedBy(
            dx: -inkAnnotation.bounds.minX,
            dy: -inkAnnotation.bounds.minY
        )
        inkAnnotation.add(localPath)
        inkAnnotation.color = .systemBlue
        let inkBorder = PDFBorder()
        inkBorder.lineWidth = 3
        inkAnnotation.border = inkBorder
        inkPage.addAnnotation(inkAnnotation)
        let inkData = try XCTUnwrap(inkDocument.dataRepresentation())

        let pressureDocument = try XCTUnwrap(PDFDocument(data: blankData))
        let pressurePage = try XCTUnwrap(pressureDocument.page(at: 0))
        pressurePage.addAnnotation(PortalPDFPressureInkAnnotation(
            points: [CGPoint(x: 90, y: 80), CGPoint(x: 205, y: 340)],
            pressures: [0.5, 0.5],
            baseLineWidth: 3,
            color: .systemBlue
        ))
        let pressureData = try XCTUnwrap(pressureDocument.dataRepresentation())

        XCTAssertLessThanOrEqual(
            pressureData.count - inkData.count,
            512,
            "압력 펜 메타데이터는 PDFKit 표준 Ink의 고정 저장 비용보다 512B 이상 커지면 안 됩니다."
        )
        XCTAssertLessThan(
            pressureData.count - blankData.count,
            4_096,
            "단일 압력 획의 전체 PDF 증가량은 4KB 미만이어야 합니다."
        )
    }

    func testPressureInkEraserRemovesOnlyTouchedSectionAfterPDFRoundTrip() throws {
        let page = try makeBlankPage()
        let points = stride(from: CGFloat(40), through: 280, by: 20).map {
            CGPoint(x: $0, y: 180)
        }
        let annotation = PortalPDFPressureInkAnnotation(
            points: points,
            pressures: Array(repeating: 0.6, count: points.count),
            baseLineWidth: 6,
            color: .systemBlue
        )
        page.addAnnotation(annotation)

        let document = PDFDocument()
        document.insert(page, at: 0)
        let data = try XCTUnwrap(document.dataRepresentation())
        let reloadedDocument = try XCTUnwrap(PDFDocument(data: data))
        let reloadedPage = try XCTUnwrap(reloadedDocument.page(at: 0))
        let reloadedAnnotation = try XCTUnwrap(reloadedPage.annotations.first)
        let fragments = try XCTUnwrap(
            PortalPDFPressureInkAnnotation.fragmentsAfterErasing(
                reloadedAnnotation,
                around: CGPoint(x: 160, y: 180),
                eraserRadius: 14
            )
        )

        XCTAssertEqual(fragments.count, 2, "지우개가 획 중앙을 지나가면 앞·뒤 두 획으로 분리되어야 합니다.")
        XCTAssertLessThan(fragments[0].points.last?.x ?? .greatestFiniteMagnitude, 160)
        XCTAssertGreaterThan(fragments[1].points.first?.x ?? -CGFloat.greatestFiniteMagnitude, 160)
        XCTAssertEqual(
            fragments.flatMap(\.points).filter { abs($0.x - 160) < 1 }.count,
            0,
            "지우개 중심을 지난 구간은 남은 압력 획에 포함되면 안 됩니다."
        )
    }

    func testRepeatedPressureInkErasingKeepsSingleAnnotation() throws {
        let page = try makeBlankPage()
        let points = stride(from: CGFloat(24), through: 296, by: 4).map {
            CGPoint(x: $0, y: 180)
        }
        var annotation: PDFAnnotation = PortalPDFPressureInkAnnotation(
            points: points,
            pressures: Array(repeating: 0.65, count: points.count),
            baseLineWidth: 6,
            color: .systemBlue
        )
        page.addAnnotation(annotation)

        for eraseX in stride(from: CGFloat(70), through: 250, by: 30) {
            let fragments = try XCTUnwrap(
                PortalPDFPressureInkAnnotation.fragmentsAfterErasing(
                    annotation,
                    around: CGPoint(x: eraseX, y: 180),
                    eraserRadius: 5
                )
            )
            page.removeAnnotation(annotation)
            annotation = try XCTUnwrap(
                PortalPDFPressureInkAnnotation.groupedAnnotation(
                    fragments: fragments,
                    baseLineWidth: 6,
                    color: .systemBlue
                )
            )
            page.addAnnotation(annotation)
            XCTAssertEqual(
                page.annotations.count,
                1,
                "반복 삭제 후에도 한 원본 압력 획은 Annotation 하나로 유지되어야 합니다."
            )
        }

        let document = PDFDocument()
        document.insert(page, at: 0)
        let data = try XCTUnwrap(document.dataRepresentation())
        let reloadedDocument = try XCTUnwrap(PDFDocument(data: data))
        let reloadedAnnotations = try XCTUnwrap(reloadedDocument.page(at: 0)?.annotations)
        XCTAssertEqual(reloadedAnnotations.count, 1)
        let reloadedAnnotation = try XCTUnwrap(reloadedAnnotations.first)
        XCTAssertTrue(PortalPDFPressureInkAnnotation.isPressureInk(reloadedAnnotation))
        XCTAssertFalse(
            reloadedAnnotation is PortalPDFPressureInkAnnotation,
            "메모리 정규화 후에는 PDFKit이 캐시하기 쉬운 일반 Stamp Annotation이어야 합니다."
        )
    }

    func testLegacyPressureInkFragmentsCompactWhenDocumentRestores() throws {
        let page = try makeBlankPage()
        for index in 0..<40 {
            let startX = CGFloat(20 + index * 7)
            page.addAnnotation(PortalPDFPressureInkAnnotation(
                points: [
                    CGPoint(x: startX, y: 150),
                    CGPoint(x: startX + 5, y: 152)
                ],
                pressures: [0.6, 0.6],
                baseLineWidth: 5,
                color: .systemBlue
            ))
        }
        let document = PDFDocument()
        document.insert(page, at: 0)
        let data = try XCTUnwrap(document.dataRepresentation())
        let reloadedDocument = try XCTUnwrap(PDFDocument(data: data))

        XCTAssertEqual(reloadedDocument.page(at: 0)?.annotations.count, 40)
        reloadedDocument.restorePortalEditableAnnotations()
        let compactedAnnotations = try XCTUnwrap(reloadedDocument.page(at: 0)?.annotations)
        XCTAssertEqual(
            compactedAnnotations.count,
            1,
            "이전 버전에서 분리된 같은 스타일 압력 획은 재진입 시 하나로 압축되어야 합니다."
        )
        XCTAssertTrue(PortalPDFPressureInkAnnotation.isPressureInk(try XCTUnwrap(compactedAnnotations.first)))
    }

    func testPressureInkFragmentUpdateKeepsAnnotationIdentity() throws {
        let annotation = PortalPDFPressureInkAnnotation(
            points: [
                CGPoint(x: 30, y: 120),
                CGPoint(x: 100, y: 120),
                CGPoint(x: 170, y: 120)
            ],
            pressures: [0.6, 0.7, 0.8],
            baseLineWidth: 6,
            color: .systemBlue
        )
        let identity = ObjectIdentifier(annotation)
        let fragments = try XCTUnwrap(PortalPDFPressureInkAnnotation.fragmentsAfterErasing(
            annotation,
            around: CGPoint(x: 100, y: 120),
            eraserRadius: 12
        ))

        XCTAssertTrue(annotation.replaceStrokeFragments(fragments))
        XCTAssertEqual(ObjectIdentifier(annotation), identity)
        XCTAssertGreaterThan(annotation.strokeFragmentCount, 1)
        XCTAssertFalse(annotation.renderedPathBounds.isEmpty)
    }

    func testPressureInkIncrementalEraserReusesUntouchedPathsAndDefersMetadata() throws {
        let fragments = (0..<80).map { index in
            let y = CGFloat(40 + index * 6)
            let points = stride(from: CGFloat(30), through: 260, by: 10).map {
                CGPoint(x: $0, y: y)
            }
            return PortalPDFPressureInkAnnotation.StrokeFragment(
                points: points,
                pressures: Array(repeating: 0.65, count: points.count)
            )
        }
        let annotation = try XCTUnwrap(PortalPDFPressureInkAnnotation.groupedAnnotation(
            fragments: fragments,
            baseLineWidth: 6,
            color: .systemBlue
        ))
        let untouchedPath = try XCTUnwrap(annotation.strokePaths.first)
        let metadataBeforeErasing = annotation.contents

        let result = annotation.eraseStrokeFragments(
            around: [CGPoint(x: 145, y: 40 + 40 * 6)],
            eraserRadius: 8
        )

        guard case .updated = result else {
            return XCTFail("지우개와 겹친 한 획만 부분 갱신되어야 합니다.")
        }
        XCTAssertTrue(
            annotation.strokePaths.first === untouchedPath,
            "충돌하지 않은 압력 경로는 다시 만들지 않고 같은 객체를 재사용해야 합니다."
        )
        XCTAssertEqual(
            annotation.contents,
            metadataBeforeErasing,
            "드래그 중에는 전체 메타데이터 직렬화를 수행하지 않아야 합니다."
        )

        annotation.prepareForPersistence()
        XCTAssertNotEqual(annotation.contents, metadataBeforeErasing)
    }

    func testPressureInkIncrementalEraserSkipsDistantInput() throws {
        let annotation = PortalPDFPressureInkAnnotation(
            points: [CGPoint(x: 20, y: 80), CGPoint(x: 220, y: 80)],
            pressures: [0.6, 0.6],
            baseLineWidth: 6,
            color: .systemBlue
        )
        let pathBeforeErasing = try XCTUnwrap(annotation.strokePaths.first)

        let result = annotation.eraseStrokeFragments(
            around: [CGPoint(x: 400, y: 600)],
            eraserRadius: 12
        )

        guard case .unchanged = result else {
            return XCTFail("멀리 떨어진 입력은 압력 획 계산을 변경하면 안 됩니다.")
        }
        XCTAssertTrue(annotation.strokePaths.first === pathBeforeErasing)
    }

    func testPressureInkAnnotationUsesSameSinglePassPathAsLiveOverlay() throws {
        let points = [
            CGPoint(x: 36, y: 84),
            CGPoint(x: 58, y: 122),
            CGPoint(x: 92, y: 104),
            CGPoint(x: 126, y: 152),
            CGPoint(x: 168, y: 116),
            CGPoint(x: 216, y: 164)
        ]
        let pressures: [CGFloat] = [0.15, 0.28, 0.72, 0.46, 0.9, 0.34]
        let expectedPath = try XCTUnwrap(
            PortalPDFPressureInkAnnotation.makeStrokePath(
                points: points,
                pressures: pressures,
                baseLineWidth: 7
            )
        )
        let annotation = PortalPDFPressureInkAnnotation(
            points: points,
            pressures: pressures,
            baseLineWidth: 7,
            color: .systemBlue
        )
        let annotationPathBounds = annotation.renderedPathBounds

        XCTAssertEqual(annotationPathBounds.minX, expectedPath.bounds.minX, accuracy: 0.001)
        XCTAssertEqual(annotationPathBounds.minY, expectedPath.bounds.minY, accuracy: 0.001)
        XCTAssertEqual(annotationPathBounds.maxX, expectedPath.bounds.maxX, accuracy: 0.001)
        XCTAssertEqual(annotationPathBounds.maxY, expectedPath.bounds.maxY, accuracy: 0.001)
    }

    func testPressureInkStrongInputProducesClearlyThickerStroke() throws {
        let points = [CGPoint(x: 20, y: 50), CGPoint(x: 220, y: 50)]
        let lightPath = try XCTUnwrap(
            PortalPDFPressureInkAnnotation.makeStrokePath(
                points: points,
                pressures: [0.15, 0.15],
                baseLineWidth: 8
            )
        )
        let strongPath = try XCTUnwrap(
            PortalPDFPressureInkAnnotation.makeStrokePath(
                points: points,
                pressures: [0.85, 0.85],
                baseLineWidth: 8
            )
        )

        XCTAssertGreaterThan(
            strongPath.bounds.height / lightPath.bounds.height,
            2.5,
            "강한 Apple Pencil 압력은 약한 압력보다 충분히 두꺼운 획으로 표현되어야 합니다."
        )
    }

    func testEveryShapeAnnotationRendersWhenRotated() throws {
        let expectedBounds = CGRect(x: 54, y: 92, width: 128, height: 88)
        for shapeType in PortalPDFShapeType.allCases {
            let page = try makeBlankPage()
            let annotation = PortalPDFShapeAnnotation(
                shapeType: shapeType,
                bounds: expectedBounds,
                lineWidth: 3
            )
            page.addAnnotation(annotation)
            annotation.rotationAngle = .pi / 6
            let rendered = render(page)

            XCTAssertTrue(
                hasVisiblePixels(in: rendered, withinPDFRect: annotation.bounds),
                "\(shapeType.title) 도형이 회전된 뒤에도 잘리지 않고 렌더링되어야 합니다."
            )
        }
    }

    func testImageAnnotationRendersAtItsContentBounds() throws {
        let page = try makeBlankPage()
        let imageBounds = CGRect(x: 176, y: 214, width: 92, height: 64)
        page.addAnnotation(
            PortalPDFImageAnnotation(image: solidImage(color: .systemPink), bounds: imageBounds)
        )

        let rendered = render(page)
        let pixel = try rgba(
            in: rendered,
            atPDFPoint: CGPoint(x: imageBounds.midX, y: imageBounds.midY)
        )

        XCTAssertGreaterThan(pixel.red, 220, "첨부 이미지는 지정한 PDF 페이지 좌표에 표시되어야 합니다.")
        XCTAssertLessThan(pixel.green, 150, "첨부 이미지의 색상 정보가 렌더링되어야 합니다.")
    }

    func testImageAnnotationPreservesTopAndBottomPixelOrder() throws {
        let page = try makeBlankPage()
        let imageBounds = CGRect(x: 96, y: 180, width: 96, height: 64)
        page.addAnnotation(
            PortalPDFImageAnnotation(image: verticallyMarkedImage(), bounds: imageBounds)
        )

        let rendered = render(page)
        let topPixel = try rgba(
            in: rendered,
            atPDFPoint: CGPoint(x: imageBounds.midX, y: imageBounds.maxY - 12)
        )
        let bottomPixel = try rgba(
            in: rendered,
            atPDFPoint: CGPoint(x: imageBounds.midX, y: imageBounds.minY + 12)
        )

        XCTAssertGreaterThan(topPixel.red, topPixel.blue, "첨부 이미지 상단이 PDF 렌더링에서도 뒤집히지 않아야 합니다.")
        XCTAssertGreaterThan(bottomPixel.blue, bottomPixel.red, "첨부 이미지 하단이 PDF 렌더링에서도 뒤집히지 않아야 합니다.")
    }

    func testEditableImageAndShapeRestoreAfterPDFRoundTrip() throws {
        let page = try makeBlankPage()
        let imageBounds = CGRect(x: 42, y: 84, width: 108, height: 72)
        let imageAnnotation = PortalPDFImageAnnotation(
            image: solidImage(color: .systemPink),
            bounds: imageBounds
        )
        imageAnnotation.rotationAngle = .pi / 5
        imageAnnotation.isHorizontallyFlipped = true
        let shapeBounds = CGRect(x: 164, y: 228, width: 104, height: 76)
        let shapeAnnotation = PortalPDFShapeAnnotation(
            shapeType: .roundedRectangle,
            bounds: shapeBounds,
            lineWidth: 3,
            lineColor: .systemGreen,
            fillColor: .systemGreen.withAlphaComponent(0.2)
        )
        shapeAnnotation.rotationAngle = -.pi / 7
        page.addAnnotation(imageAnnotation)
        page.addAnnotation(shapeAnnotation)

        let document = PDFDocument()
        document.insert(page, at: 0)
        let data = try XCTUnwrap(document.portalEditableDataRepresentation())
        let reloadedDocument = try XCTUnwrap(PDFDocument(data: data))
        let serializedPage = try XCTUnwrap(reloadedDocument.page(at: 0))
        let serializedImagePixel = try rgba(
            in: render(serializedPage),
            atPDFPoint: CGPoint(x: imageBounds.midX, y: imageBounds.midY)
        )
        XCTAssertGreaterThan(
            serializedImagePixel.red,
            220,
            "앱 편집 객체로 복원하기 전 일반 PDF 뷰어에서도 저장된 이미지가 보여야 합니다."
        )
        reloadedDocument.restorePortalEditableAnnotations()
        let annotations = try XCTUnwrap(reloadedDocument.page(at: 0)?.annotations)
        let restoredImage = try XCTUnwrap(annotations.first { $0 is PortalPDFImageAnnotation } as? PortalPDFImageAnnotation)
        let restoredShape = try XCTUnwrap(annotations.first { $0 is PortalPDFShapeAnnotation } as? PortalPDFShapeAnnotation)

        XCTAssertEqual(restoredImage.editingBounds.origin.x, imageBounds.origin.x, accuracy: 0.01)
        XCTAssertEqual(restoredImage.editingBounds.size.width, imageBounds.size.width, accuracy: 0.01)
        XCTAssertEqual(restoredImage.rotationAngle, imageAnnotation.rotationAngle, accuracy: 0.001)
        XCTAssertTrue(restoredImage.isHorizontallyFlipped)
        XCTAssertEqual(restoredShape.editingBounds.origin.y, shapeBounds.origin.y, accuracy: 0.01)
        XCTAssertEqual(restoredShape.editingBounds.size.height, shapeBounds.size.height, accuracy: 0.01)
        XCTAssertEqual(restoredShape.rotationAngle, shapeAnnotation.rotationAngle, accuracy: 0.001)
    }

    func testLargeEditedPDFReopensWithinInteractiveThreshold() throws {
        let document = PDFDocument()
        for pageIndex in 0..<8 {
            let page = try makeBlankPage()
            for annotationIndex in 0..<100 {
                let x = CGFloat(16 + (annotationIndex % 10) * 28)
                let y = CGFloat(24 + (annotationIndex / 10) * 34)
                let path = UIBezierPath()
                path.move(to: .zero)
                path.addLine(to: CGPoint(x: 18, y: CGFloat((annotationIndex % 4) + 2)))
                let annotation = PDFAnnotation(
                    bounds: CGRect(x: x, y: y, width: 24, height: 12),
                    forType: .ink,
                    withProperties: nil
                )
                annotation.add(path)
                annotation.color = .systemBlue
                page.addAnnotation(annotation)
            }
            for shapeIndex in 0..<5 {
                page.addAnnotation(PortalPDFShapeAnnotation(
                    shapeType: PortalPDFShapeType.allCases[shapeIndex],
                    bounds: CGRect(x: 24 + shapeIndex * 48, y: 382, width: 38, height: 30),
                    lineWidth: 2
                ))
            }
            page.addAnnotation(PortalPDFImageAnnotation(
                image: solidImage(color: .systemPink),
                bounds: CGRect(x: 244, y: 416, width: 48, height: 32)
            ))
            document.insert(page, at: pageIndex)
        }
        let data = try XCTUnwrap(document.portalEditableDataRepresentation())
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("NF-LargeEditedPDF-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try data.write(to: fileURL, options: .atomic)

        let startedAt = CACurrentMediaTime()
        let storedData = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        let reloadedDocument = try XCTUnwrap(PDFDocument(data: storedData))
        reloadedDocument.restorePortalEditableAnnotations()
        let elapsed = CACurrentMediaTime() - startedAt

        XCTAssertEqual(reloadedDocument.pageCount, 8)
        let firstPageAnnotations = try XCTUnwrap(reloadedDocument.page(at: 0)?.annotations)
        let restoredInkAnnotations = firstPageAnnotations.filter(\.isPortalInkAnnotation)
        XCTAssertEqual(firstPageAnnotations.count - restoredInkAnnotations.count, 6)
        XCTAssertLessThan(restoredInkAnnotations.count, 100)
        XCTAssertTrue(restoredInkAnnotations.allSatisfy {
            ($0.paths?.count ?? 0) <= PortalPDFStandardInkCompactor.maximumPathsPerAnnotation
        })
        XCTAssertEqual(
            restoredInkAnnotations.reduce(0) { $0 + ($1.paths?.count ?? 0) },
            100,
            "주석 객체를 합쳐도 100개 원본 획 경로는 모두 유지되어야 합니다."
        )
        XCTAssertLessThan(
            elapsed,
            3,
            "800개 필기와 48개 커스텀 편집 정보가 있는 PDF는 3초 안에 파싱·복원되어야 합니다. 측정값: \(elapsed)초"
        )
        print("NF PDF reopen benchmark: \(elapsed) seconds, \(data.count) bytes")
    }

    func testRotatedImageAndExternalEditingControlsAreNotClipped() throws {
        let page = try makeBlankPage()
        let imageBounds = CGRect(x: 112, y: 196, width: 84, height: 56)
        let imageCenter = CGPoint(x: imageBounds.midX, y: imageBounds.midY)
        let annotation = PortalPDFImageAnnotation(image: solidImage(color: .systemPink), bounds: imageBounds)
        page.addAnnotation(annotation)
        annotation.isPortalSelected = true
        annotation.rotationAngle = .pi / 4

        let rendered = render(page)
        let contentCorner = rotated(
            CGPoint(x: imageBounds.maxX - 5, y: imageBounds.maxY - 5),
            around: imageCenter,
            by: annotation.rotationAngle
        )
        let handleCenter = rotated(
            CGPoint(x: imageBounds.maxX + 27, y: imageBounds.maxY + 27),
            around: imageCenter,
            by: annotation.rotationAngle
        )
        let handleFillPoint = rotated(
            CGPoint(x: imageBounds.maxX + 21, y: imageBounds.maxY + 28),
            around: imageCenter,
            by: annotation.rotationAngle
        )
        let deleteHandleCenter = rotated(
            CGPoint(x: imageBounds.minX - 27, y: imageBounds.maxY + 27),
            around: imageCenter,
            by: annotation.rotationAngle
        )
        let deleteHandleFillPoint = rotated(
            CGPoint(x: imageBounds.minX - 33, y: imageBounds.maxY + 27),
            around: imageCenter,
            by: annotation.rotationAngle
        )
        let imagePixel = try rgba(in: rendered, atPDFPoint: contentCorner)
        let handlePixel = try rgba(in: rendered, atPDFPoint: handleFillPoint)
        let deleteHandlePixel = try rgba(in: rendered, atPDFPoint: deleteHandleFillPoint)

        XCTAssertTrue(annotation.bounds.contains(contentCorner), "회전된 이미지 본문이 Annotation 안전 영역 안에 있어야 합니다.")
        XCTAssertTrue(annotation.bounds.contains(handleCenter), "오른쪽 조절 버튼이 Annotation 안전 영역 안에 있어야 합니다.")
        XCTAssertTrue(annotation.bounds.contains(deleteHandleCenter), "왼쪽 삭제 버튼이 Annotation 안전 영역 안에 있어야 합니다.")
        XCTAssertTrue(annotation.isDeleteHandleHit(deleteHandleCenter, scaleFactor: 1), "왼쪽 삭제 버튼을 선택할 수 있어야 합니다.")
        XCTAssertLessThan(imagePixel.green, 150, "회전된 이미지 모서리가 잘리지 않고 렌더링되어야 합니다.")
        XCTAssertGreaterThan(handlePixel.blue, handlePixel.red, "회전된 오른쪽 조절 버튼이 표시되어야 합니다.")
        XCTAssertGreaterThan(deleteHandlePixel.red, deleteHandlePixel.green, "회전된 왼쪽 삭제 버튼이 표시되어야 합니다.")
    }

    func testRotatedShapeAndExternalEditingControlsAreNotClipped() throws {
        let page = try makeBlankPage()
        let shapeBounds = CGRect(x: 112, y: 196, width: 84, height: 56)
        let shapeCenter = CGPoint(x: shapeBounds.midX, y: shapeBounds.midY)
        let annotation = PortalPDFShapeAnnotation(
            shapeType: .rectangle,
            bounds: shapeBounds,
            lineWidth: 3
        )
        page.addAnnotation(annotation)
        annotation.isPortalSelected = true
        annotation.rotationAngle = .pi / 4

        let rendered = render(page)
        let resizeHandleCenter = rotated(
            try XCTUnwrap(annotation.unrotatedResizeHandleCenters[.topRight]),
            around: shapeCenter,
            by: annotation.rotationAngle
        )
        let deleteHandleCenter = annotation.pageDeleteHandleCenter
        let deleteHandleFillPoint = rotated(
            CGPoint(
                x: annotation.unrotatedDeleteHandleCenter.x - 6,
                y: annotation.unrotatedDeleteHandleCenter.y
            ),
            around: shapeCenter,
            by: annotation.rotationAngle
        )
        let deleteHandlePixel = try rgba(in: rendered, atPDFPoint: deleteHandleFillPoint)

        XCTAssertTrue(annotation.bounds.contains(resizeHandleCenter), "도형 크기 조절점이 Annotation 안전 영역 안에 있어야 합니다.")
        XCTAssertTrue(annotation.bounds.contains(deleteHandleCenter), "도형 왼쪽 삭제 버튼이 Annotation 안전 영역 안에 있어야 합니다.")
        XCTAssertEqual(annotation.resizeHandle(at: resizeHandleCenter, scaleFactor: 1), .topRight)
        XCTAssertTrue(annotation.isDeleteHandleHit(deleteHandleCenter, scaleFactor: 1), "도형 왼쪽 삭제 버튼을 선택할 수 있어야 합니다.")
        XCTAssertGreaterThan(deleteHandlePixel.red, deleteHandlePixel.green, "도형 왼쪽 삭제 버튼이 표시되어야 합니다.")
    }

    private func makeBlankPage() throws -> PDFPage {
        guard let page = PDFPage(image: solidImage(color: .white, size: pageSize)) else {
            throw NSError(domain: "PortalPDFAnnotationRenderingTests", code: 1)
        }
        return page
    }

    private func makeVectorBlankPDFData() -> Data {
        let data = NSMutableData()
        let bounds = CGRect(origin: .zero, size: pageSize)
        UIGraphicsBeginPDFContextToData(data, bounds, nil)
        UIGraphicsBeginPDFPageWithInfo(bounds, nil)
        UIGraphicsEndPDFContext()
        return data as Data
    }

    private func solidImage(color: UIColor, size: CGSize = CGSize(width: 48, height: 32)) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { rendererContext in
            color.setFill()
            rendererContext.fill(CGRect(origin: .zero, size: size))
        }
    }

    private func verticallyMarkedImage() -> UIImage {
        let size = CGSize(width: 48, height: 32)
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { rendererContext in
            UIColor.systemRed.setFill()
            rendererContext.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height / 2))
            UIColor.systemBlue.setFill()
            rendererContext.fill(CGRect(x: 0, y: size.height / 2, width: size.width, height: size.height / 2))
        }
    }

    private func render(_ page: PDFPage) -> UIImage {
        let temporaryDocument: PDFDocument?
        if page.document == nil {
            let document = PDFDocument()
            document.insert(page, at: 0)
            temporaryDocument = document
        } else {
            temporaryDocument = nil
        }
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: pageSize, format: format).image { rendererContext in
            let context = rendererContext.cgContext
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: pageSize))
            context.saveGState()
            context.translateBy(x: 0, y: pageSize.height)
            context.scaleBy(x: 1, y: -1)
            page.draw(with: .mediaBox, to: context)
            context.restoreGState()
        }
        withExtendedLifetime(temporaryDocument) {}
        return rendered
    }

    private func rgba(in image: UIImage, atPDFPoint point: CGPoint) throws -> (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
        guard let cgImage = image.cgImage else {
            throw NSError(domain: "PortalPDFAnnotationRenderingTests", code: 2)
        }

        let width = cgImage.width
        let height = cgImage.height
        let x = min(max(Int(point.x), 0), width - 1)
        let y = min(max(Int(pageSize.height - point.y), 0), height - 1)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            throw NSError(domain: "PortalPDFAnnotationRenderingTests", code: 3)
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        let offset = (y * width + x) * 4
        return (pixels[offset], pixels[offset + 1], pixels[offset + 2], pixels[offset + 3])
    }

    private func hasVisiblePixels(in image: UIImage, withinPDFRect rect: CGRect) -> Bool {
        guard let cgImage = image.cgImage else { return false }
        let width = cgImage.width
        let height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            return false
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let xRange = max(Int(rect.minX), 0)..<min(Int(rect.maxX), width)
        let yRange = max(Int(pageSize.height - rect.maxY), 0)..<min(Int(pageSize.height - rect.minY), height)
        for y in yRange {
            for x in xRange {
                let offset = (y * width + x) * 4
                let isWhite = pixels[offset] > 248 && pixels[offset + 1] > 248 && pixels[offset + 2] > 248
                if !isWhite { return true }
            }
        }
        return false
    }

    private func rotated(_ point: CGPoint, around center: CGPoint, by angle: CGFloat) -> CGPoint {
        let cosine = cos(angle)
        let sine = sin(angle)
        let x = point.x - center.x
        let y = point.y - center.y
        return CGPoint(
            x: center.x + x * cosine - y * sine,
            y: center.y + x * sine + y * cosine
        )
    }
}
