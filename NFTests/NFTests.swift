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

    @Test func strokeSmoothingStabilizesMultiplePointsAtBothEnds() {
        let points = [
            CGPoint(x: 0, y: 16),
            CGPoint(x: 0, y: 8),
            CGPoint(x: 0, y: 0),
            CGPoint(x: 10, y: 0),
            CGPoint(x: 20, y: 0),
            CGPoint(x: 30, y: 0),
            CGPoint(x: 40, y: 0),
            CGPoint(x: 50, y: 0),
            CGPoint(x: 50, y: 8),
            CGPoint(x: 50, y: 16),
        ]

        let stabilized = points.terminalFlickStabilized(strength: 1)

        #expect(abs(stabilized[0].y) < abs(points[0].y) * 0.35)
        #expect(abs(stabilized[1].y) < abs(points[1].y) * 0.75)
        #expect(abs(stabilized[8].y) < abs(points[8].y) * 0.75)
        #expect(abs(stabilized[9].y) < abs(points[9].y) * 0.35)
        #expect(stabilized[4] == points[4])
        #expect(stabilized[5] == points[5])
    }

    @Test func strokeSmoothingStrengthControlsCorrectionAmount() {
        let points = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 10, y: 0),
            CGPoint(x: 20, y: 0),
            CGPoint(x: 30, y: 0),
            CGPoint(x: 40, y: 0),
            CGPoint(x: 50, y: 0),
            CGPoint(x: 50, y: 7),
            CGPoint(x: 50, y: 14),
        ]

        let disabled = points.terminalFlickStabilized(strength: 0)
        let medium = points.terminalFlickStabilized(strength: 0.5)
        let strong = points.terminalFlickStabilized(strength: 1)

        #expect(disabled == points)
        #expect(abs(strong.last?.y ?? 0) < abs(medium.last?.y ?? 0))
        #expect(abs(medium.last?.y ?? 0) < abs(points.last?.y ?? 0))
    }

    @Test func strokeSmoothingSoftensStraightStrokeEndpointsWithoutMovingItsCenter() {
        let points = (0..<12).map { CGPoint(x: CGFloat($0) * 8, y: 4) }

        let stabilized = points.terminalFlickStabilized(strength: 1)

        #expect(stabilized.first?.x ?? 0 > points.first?.x ?? 0)
        #expect(stabilized.last?.x ?? 0 < points.last?.x ?? 0)
        #expect(stabilized[5] == points[5])
        #expect(stabilized.allSatisfy { abs($0.y - 4) < 0.001 })
    }

    @Test func strokeSmoothingAffectsShortHandwritingAtFullStrength() {
        let points = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 8, y: 4),
            CGPoint(x: 16, y: 2),
            CGPoint(x: 24, y: 10),
            CGPoint(x: 30, y: 18),
        ]

        let disabled = points.terminalFlickStabilized(strength: 0)
        let medium = points.terminalFlickStabilized(strength: 0.5)
        let strong = points.terminalFlickStabilized(strength: 1)

        #expect(disabled == points)
        let mediumStartMovement = hypot(
            medium.first!.x - points.first!.x,
            medium.first!.y - points.first!.y
        )
        let strongStartMovement = hypot(
            strong.first!.x - points.first!.x,
            strong.first!.y - points.first!.y
        )
        let mediumEndMovement = hypot(
            medium.last!.x - points.last!.x,
            medium.last!.y - points.last!.y
        )
        let strongEndMovement = hypot(
            strong.last!.x - points.last!.x,
            strong.last!.y - points.last!.y
        )
        #expect(strongStartMovement > mediumStartMovement)
        #expect(strongEndMovement > mediumEndMovement)
        #expect(strong[2] == points[2])
    }

    @Test func fullStrokeSmoothingNearlyRemovesTerminalOvershoot() {
        let points = (0..<12).map { CGPoint(x: CGFloat($0) * 8, y: 4) }

        let medium = points.terminalFlickStabilized(strength: 0.5)
        let high = points.terminalFlickStabilized(strength: 0.8)
        let full = points.terminalFlickStabilized(strength: 1)

        let endAnchor = points[8]
        let originalTailLength = hypot(
            points.last!.x - endAnchor.x,
            points.last!.y - endAnchor.y
        )
        let fullTailLength = hypot(
            full.last!.x - endAnchor.x,
            full.last!.y - endAnchor.y
        )
        let mediumMovement = hypot(
            medium.last!.x - points.last!.x,
            medium.last!.y - points.last!.y
        )
        let highMovement = hypot(
            high.last!.x - points.last!.x,
            high.last!.y - points.last!.y
        )
        let fullMovement = hypot(
            full.last!.x - points.last!.x,
            full.last!.y - points.last!.y
        )

        #expect(fullTailLength / originalTailLength < 0.08)
        #expect(mediumMovement < highMovement)
        #expect(highMovement < fullMovement)
        #expect(full[5] == points[5])
    }

    @Test func strokeSmoothingOverdriveContinuesIncreasingThroughTwoHundredPercent() {
        let points = (0..<24).map { CGPoint(x: CGFloat($0) * 8, y: 4) }

        let full = points.terminalFlickStabilized(strength: 1)
        let oneHundredFifty = points.terminalFlickStabilized(strength: 1.5)
        let twoHundred = points.terminalFlickStabilized(strength: 2)
        let aboveMaximum = points.terminalFlickStabilized(strength: 3)

        let fullMovement = abs(full.last!.x - points.last!.x)
        let oneHundredFiftyMovement = abs(oneHundredFifty.last!.x - points.last!.x)
        let twoHundredMovement = abs(twoHundred.last!.x - points.last!.x)

        #expect(fullMovement < oneHundredFiftyMovement)
        #expect(oneHundredFiftyMovement < twoHundredMovement)
        #expect(aboveMaximum == twoHundred)
        #expect(twoHundred[11] == points[11])
        #expect(twoHundred[12] == points[12])
        #expect(twoHundred.prefix(8).allSatisfy { $0 == points[8] })
        #expect(twoHundred.suffix(8).allSatisfy { $0 == points[15] })
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
        let smoothedPoints = points.weightedMovingAverage(radius: 2)
        let path = try #require(PortalPDFPressureInkAnnotation.makeStrokePath(
            points: points,
            pressures: pressures,
            baseLineWidth: 8
        ))

        for index in 0..<(smoothedPoints.count - 1) {
            let start = smoothedPoints[index]
            let end = smoothedPoints[index + 1]
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

    private func onePagePDFData() -> Data {
        let pageBounds = CGRect(x: 0, y: 0, width: 595, height: 842)
        return UIGraphicsPDFRenderer(bounds: pageBounds).pdfData { context in
            context.beginPage()
            "NF".draw(at: CGPoint(x: 32, y: 32), withAttributes: nil)
        }
    }

}
