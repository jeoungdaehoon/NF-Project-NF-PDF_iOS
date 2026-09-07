//
//  NFTests.swift
//  NFTests
//
//  Created by hanwha on 7/29/26.
//

import Testing
import PDFKit
import UIKit
@testable import NF

struct NFTests {

    @Test func example() async throws {
        // Write your test here and use APIs like `#expect(...)` to check expected conditions.
    }

    @MainActor
    @Test func portalSoftGrayThemePayloadMapsToNativePalette() throws {
        let theme = try #require(PortalAppTheme(messageBody: [
            "presetID": "soft-gray",
            "backgroundColor": "#bdbdbd",
            "surfaceColor": "#c7c7c7",
            "sidebarBackgroundColor": "#c4c4c4",
            "foregroundColor": "#181818",
            "mutedColor": "rgb(59, 59, 59)",
            "borderColor": "#a4a4a4",
            "accentColor": "rgba(63, 96, 149, 1)",
            "colorScheme": "light"
        ]))

        #expect(theme.presetID == "soft-gray")
        #expect(theme.background.red == 189.0 / 255.0)
        #expect(theme.surface.red == 199.0 / 255.0)
        #expect(theme.sidebarBackground?.red == 196.0 / 255.0)
        #expect(theme.foreground.red == 24.0 / 255.0)
        #expect(theme.muted.red == 59.0 / 255.0)
        #expect(theme.border.red == 164.0 / 255.0)
        #expect(theme.accent.blue == 149.0 / 255.0)
        #expect(!theme.usesDarkInterface)
    }

    @MainActor
    @Test func portalThemePayloadFallsBackForInvalidOptionalColors() throws {
        let theme = try #require(PortalAppTheme(messageBody: [
            "presetID": "default",
            "backgroundColor": "#191919",
            "surfaceColor": "invalid",
            "colorScheme": "dark"
        ]))

        #expect(theme.surface == PortalAppTheme.default.surface)
        #expect(theme.usesDarkInterface)
    }

    @Test func localPDFDocumentCanBeCreatedAndMovedIntoFolder() throws {
        let fileManager = FileManager.default
        let testDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("NFTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: testDirectory) }

        let repository = PortalPDFLocalStorageRepository(
            fileManager: fileManager,
            cacheDirectoryURL: testDirectory
        )
        let folder = try repository.createFolder(name: "계약 문서")
        let document = try repository.createDocument(
            data: onePagePDFData(),
            fileName: "테스트 문서"
        )

        #expect(repository.folders().map(\.id) == [folder.id])
        #expect(document.fileName == "테스트 문서.pdf")
        #expect(document.folderID == nil)

        try repository.moveDocument(documentID: document.id, toFolderID: folder.id)

        let reloadedRepository = PortalPDFLocalStorageRepository(
            fileManager: fileManager,
            cacheDirectoryURL: testDirectory
        )
        let movedDocument = try #require(reloadedRepository.documents().first)
        #expect(movedDocument.id == document.id)
        #expect(movedDocument.folderID == folder.id)
        #expect(fileManager.fileExists(atPath: movedDocument.localFileURL.path))
    }

    @Test func pdfViewportPersistsAcrossStoreRecreation() throws {
        let suiteName = "NFTests.PDFViewport.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let expected = PortalPDFViewportStore.Record(
            scaleFactor: 2.75,
            contentOffsetX: 184,
            contentOffsetY: 936,
            pageIndex: nil,
            pagePointX: nil,
            pagePointY: nil
        )

        PortalPDFViewportStore.save(expected, for: "local-document-id", userDefaults: userDefaults)

        let restored = try #require(
            PortalPDFViewportStore.load(for: "local-document-id", userDefaults: userDefaults)
        )
        #expect(restored.scaleFactor == expected.scaleFactor)
        #expect(restored.contentOffsetX == expected.contentOffsetX)
        #expect(restored.contentOffsetY == expected.contentOffsetY)
    }

    @Test func editedLocalPDFSurvivesRepositoryRecreation() throws {
        let fileManager = FileManager.default
        let testDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("NFTests-EditedPDF-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: testDirectory) }
        let repository = PortalPDFLocalStorageRepository(
            fileManager: fileManager,
            cacheDirectoryURL: testDirectory
        )
        let localDocument = try repository.createDocument(
            data: onePagePDFData(),
            fileName: "강제 종료 복원 테스트"
        )
        let pdfDocument = try #require(PDFDocument(url: localDocument.localFileURL))
        let page = try #require(pdfDocument.page(at: 0))
        let ink = PDFAnnotation(
            bounds: CGRect(x: 32, y: 48, width: 120, height: 40),
            forType: .ink,
            withProperties: nil
        )
        let path = UIBezierPath()
        path.move(to: .zero)
        path.addLine(to: CGPoint(x: 100, y: 24))
        ink.add(path)
        page.addAnnotation(ink)
        let editedData = try #require(pdfDocument.portalEditableDataRepresentation())
        try repository.save(editedData, for: PortalAttachmentPreviewItem(localDocument: localDocument))

        let relaunchedRepository = PortalPDFLocalStorageRepository(
            fileManager: fileManager,
            cacheDirectoryURL: testDirectory
        )
        let relaunchedDocument = try #require(relaunchedRepository.documents().first)
        let reopenedPDF = try #require(PDFDocument(url: relaunchedDocument.localFileURL))

        #expect(reopenedPDF.page(at: 0)?.annotations.count == 1)
    }

    @Test func accountDeletionRemovesAllLocalPDFDocumentsAndFolders() throws {
        let fileManager = FileManager.default
        let testDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("NFTests-AccountDeletion-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: testDirectory) }
        let repository = PortalPDFLocalStorageRepository(
            fileManager: fileManager,
            cacheDirectoryURL: testDirectory
        )
        _ = try repository.createFolder(name: "삭제할 폴더")
        _ = try repository.createDocument(data: onePagePDFData(), fileName: "삭제할 문서")

        try repository.removeAllLocalData()

        #expect(!fileManager.fileExists(atPath: testDirectory.path))
        #expect(repository.documents().isEmpty)
        #expect(repository.folders().isEmpty)
    }

    @Test func accountDeletionClearsAccountPreferencesButKeepsOnboarding() throws {
        let suiteName = "NFTests.AccountDeletion.Preferences.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let repository = AutoLoginPreferenceRepository(userDefaults: userDefaults)
        repository.setAutoLoginEnabled(true)
        repository.setPDFLocalStorageEnabled(true)
        repository.markPortalSessionAvailable()
        userDefaults.set(true, forKey: "nf.portal.onboarding.completed")
        userDefaults.set(Data([0x01]), forKey: "nf.pdf.viewport.records.v1")

        repository.clearAccountPreferences()

        #expect(!repository.isAutoLoginEnabled())
        #expect(!repository.isPDFLocalStorageEnabled())
        #expect(!repository.hasStoredPortalSession())
        #expect(userDefaults.data(forKey: "nf.pdf.viewport.records.v1") == nil)
        #expect(userDefaults.bool(forKey: "nf.portal.onboarding.completed"))
    }

    @Test func pencilPathKeepsRawStartAndEndWithoutLineCorrection() throws {
        let points = [
            CGPoint(x: 3, y: 7),
            CGPoint(x: 14, y: 8),
            CGPoint(x: 25, y: 4),
            CGPoint(x: 36, y: 12),
        ]
        let path = try #require(PortalPDFPencilPathBuilder.path(points: points))
        var elementTypes: [CGPathElementType] = []
        path.cgPath.applyWithBlock { elementPointer in
            elementTypes.append(elementPointer.pointee.type)
        }

        #expect(path.cgPath.collectedPoints.first == points.first)
        #expect(path.cgPath.collectedPoints.last == points.last)
        #expect(elementTypes.contains(.addCurveToPoint))
    }

    @Test func pressureStrokeKeepsCenterlineFilledThroughTightTurns() throws {
        let points = [
            CGPoint(x: 10, y: 20),
            CGPoint(x: 22, y: 8),
            CGPoint(x: 34, y: 20),
            CGPoint(x: 22, y: 32),
            CGPoint(x: 14, y: 22),
            CGPoint(x: 30, y: 14),
            CGPoint(x: 42, y: 26),
            CGPoint(x: 34, y: 38),
        ]
        let pressures: [CGFloat] = [0.18, 0.9, 0.24, 0.82, 0.2, 0.88, 0.3, 0.76]
        let path = try #require(PortalPDFPressureInkAnnotation.makeStrokePath(
            points: points,
            pressures: pressures,
            baseLineWidth: 8
        ))

        for index in 0..<(points.count - 1) {
            let start = points[index]
            let end = points[index + 1]
            for step in 0...12 {
                let progress = CGFloat(step) / 12
                let centerPoint = CGPoint(
                    x: start.x + (end.x - start.x) * progress,
                    y: start.y + (end.y - start.y) * progress
                )
                #expect(path.cgPath.contains(centerPoint, using: .winding, transform: .identity))
            }
        }
    }

    @Test func pressureCenterlineReducesJitterWithoutMovingEndpoints() {
        let points = (0..<100).map { CGPoint(x: CGFloat($0), y: $0.isMultiple(of: 2) ? 0.2 : -0.2) }
        let smoothed = PortalPDFVariableWidthStroke.smoothedCenterline(points: points, baseLineWidth: 4)
        #expect(smoothed.first == points.first)
        #expect(smoothed.last == points.last)
        let rawJitter = points[3..<97].reduce(CGFloat.zero) { $0 + abs($1.y) }
        let renderedJitter = smoothed[3..<97].reduce(CGFloat.zero) { $0 + abs($1.y) }
        #expect(renderedJitter < rawJitter * 0.25)
        for index in points.indices {
            #expect(hypot(smoothed[index].x - points[index].x, smoothed[index].y - points[index].y) <= 4 * 0.18 + 0.0001)
        }
        let scaled = PortalPDFVariableWidthStroke.smoothedCenterline(
            points: points.map { CGPoint(x: $0.x * 10, y: $0.y * 10) }, baseLineWidth: 40
        )
        for index in points.indices {
            #expect(abs(scaled[index].y - smoothed[index].y * 10) < 0.0001)
        }
    }

    @Test func pressureStrokeUsesSmoothTangentConnections() throws {
        // Unequal radii used to leave a scalloped gap between perpendicular
        // connectors and circular joins. Check both sides and both directions.
        for angle in [CGFloat(0), .pi / 3, .pi / 2] {
            let transform = CGAffineTransform(rotationAngle: angle)
            for pressures: [CGFloat] in [[0, 1], [1, 0]] {
                let path = try #require(PortalPDFPressureInkAnnotation.makeStrokePath(
                    points: [CGPoint.zero, CGPoint(x: 20, y: 0)].map { $0.applying(transform) },
                    pressures: pressures,
                    baseLineWidth: 10
                ))
                for side: CGFloat in [-1, 1] {
                    #expect(path.contains(CGPoint(x: 10, y: side * 6.4).applying(transform)))
                    #expect(!path.contains(CGPoint(x: 10, y: side * 7).applying(transform)))
                }
            }
        }
    }

    @Test func pressureStrokeHandlesContainedAndCoincidentSamples() throws {
        for end in [CGPoint.zero, CGPoint(x: 1, y: 0)] {
            let path = try #require(PortalPDFPressureInkAnnotation.makeStrokePath(
                points: [.zero, end], pressures: [0, 1], baseLineWidth: 10
            ))
            #expect(path.bounds == CGRect(x: end.x - 10, y: -10, width: 20, height: 20))
            #expect(path.contains(.zero))
        }
    }

    @Test func pressureStrokePreservesRawTerminalCoordinatesAndWidths() throws {
        let points = [
            CGPoint(x: 4, y: 7),
            CGPoint(x: 18, y: 42),
            CGPoint(x: 36, y: 3),
            CGPoint(x: 54, y: 38),
            CGPoint(x: 72, y: 9),
        ]
        let pressures: [CGFloat] = [0.12, 0.92, 0.24, 0.86, 0.18]
        let baseLineWidth: CGFloat = 9
        let path = try #require(PortalPDFPressureInkAnnotation.makeStrokePath(
            points: points,
            pressures: pressures,
            baseLineWidth: baseLineWidth
        ))
        let widths = PortalPDFVariableWidthStroke.continuousLineWidths(
            pressures: pressures.weightedMovingAverage(radius: 4),
            baseLineWidth: baseLineWidth
        )

        #expect(path.cgPath.contains(points.first!, using: .winding, transform: .identity))
        #expect(path.cgPath.contains(points.last!, using: .winding, transform: .identity))
        #expect(widths.first == PortalPDFVariableWidthStroke.lineWidth(
            for: pressures.first!,
            baseLineWidth: baseLineWidth
        ))
        #expect(widths.last == PortalPDFVariableWidthStroke.lineWidth(
            for: pressures.last!,
            baseLineWidth: baseLineWidth
        ))
    }

    private func onePagePDFData() -> Data {
        let pageBounds = CGRect(x: 0, y: 0, width: 595, height: 842)
        return UIGraphicsPDFRenderer(bounds: pageBounds).pdfData { context in
            context.beginPage()
            "NF".draw(at: CGPoint(x: 32, y: 32), withAttributes: nil)
        }
    }

}
