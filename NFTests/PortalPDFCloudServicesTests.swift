//
//  PortalPDFCloudServicesTests.swift
//  NFTests
//
//  Created by Codex on 8/24/26.
//

import Foundation
import Testing
@testable import NF

struct PortalPDFCloudServicesTests {
    @Test
    func iCloudFileNameRoundTripPreservesDocumentIdentityAndName() {
        let documentID = "2dd86c39-c113-4ac2-9df4-d1bdb464fa85"
        let cloudName = PortalPDFICloudRepository.cloudFileName(
            localDocumentID: documentID,
            fileName: "회의/자료.pdf"
        )
        let parsed = PortalPDFICloudRepository.displayInformation(for: cloudName)

        #expect(parsed.localDocumentID == documentID)
        #expect(parsed.fileName == "회의-자료.pdf")
    }

    @Test
    func unknownICloudFileNameRemainsImportable() {
        let parsed = PortalPDFICloudRepository.displayInformation(for: "외부 문서.pdf")

        #expect(parsed.localDocumentID == nil)
        #expect(parsed.fileName == "외부 문서.pdf")
    }

    @Test
    func googleDriveMultipartBodyContainsPortalContextAndPDF() throws {
        let pdfData = Data("%PDF-1.7 test".utf8)
        let body = PortalPDFGoogleDriveService.multipartBody(
            boundary: "nf-test-boundary",
            fields: [
                "context": "general:native-pdf-library",
                "tabName": "PDF 문서"
            ],
            fileName: "테스트.pdf",
            fileData: pdfData
        )
        let bodyText = try #require(String(data: body, encoding: .utf8))

        #expect(bodyText.contains("name=\"context\""))
        #expect(bodyText.contains("general:native-pdf-library"))
        #expect(bodyText.contains("filename=\"테스트.pdf\""))
        #expect(bodyText.contains("Content-Type: application/pdf"))
        #expect(bodyText.contains("%PDF-1.7 test"))
        #expect(bodyText.hasSuffix("--nf-test-boundary--\r\n"))
    }

    @Test
    @MainActor
    func googleDriveLinkStoreUpdatesTheSameLocalDocument() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storageURL = directoryURL.appendingPathComponent("links.json")
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let store = PortalPDFGoogleDriveLinkStore(storageURL: storageURL)
        let initialLink = PortalPDFGoogleDriveLink(
            localDocumentID: "local-1",
            portalFileID: "portal-1",
            driveFileID: "drive-1",
            fileName: "초안.pdf",
            remoteURL: URL(string: "https://example.com/file/1")!,
            syncedAt: Date(timeIntervalSince1970: 1)
        )
        let updatedLink = PortalPDFGoogleDriveLink(
            localDocumentID: "local-1",
            portalFileID: "portal-1",
            driveFileID: "drive-1",
            fileName: "최종.pdf",
            remoteURL: URL(string: "https://example.com/file/1")!,
            syncedAt: Date(timeIntervalSince1970: 2)
        )

        try store.save(initialLink)
        try store.save(updatedLink)

        #expect(store.links() == [updatedLink])
    }
}
