//
//  PortalPDFCloudServices.swift
//  NF
//
//  Created by Codex on 8/24/26.
//

import Foundation
import WebKit

enum PortalPDFCloudProvider: String, CaseIterable, Identifiable {
    case iCloud
    case googleDrive

    var id: String { rawValue }

    var title: String {
        switch self {
        case .iCloud: "iCloud Drive"
        case .googleDrive: "Google Drive"
        }
    }

    var systemImageName: String {
        switch self {
        case .iCloud: "icloud"
        case .googleDrive: "externaldrive.badge.icloud"
        }
    }
}

struct PortalICloudPDFDocument: Identifiable, Hashable, Sendable {
    let id: String
    let fileName: String
    let fileURL: URL
    let modifiedAt: Date
    let fileSize: Int64
    let isDownloaded: Bool
    let isUploaded: Bool
    let localDocumentID: String?
}

enum PortalICloudAvailability: Equatable, Sendable {
    case checking
    case available
    case accountUnavailable
    case containerUnavailable

    var message: String {
        switch self {
        case .checking: "iCloud 연결을 확인하고 있습니다."
        case .available: "이 Apple 계정의 iCloud Drive와 연결되었습니다."
        case .accountUnavailable: "설정에서 iCloud Drive에 로그인해 주세요."
        case .containerUnavailable: "iCloud 컨테이너를 사용할 수 없습니다. 앱 서명을 확인해 주세요."
        }
    }
}

enum PortalPDFCloudError: LocalizedError {
    case iCloudAccountUnavailable
    case iCloudContainerUnavailable
    case iCloudDownloadTimedOut
    case portalSessionUnavailable
    case invalidServerResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .iCloudAccountUnavailable:
            "iCloud Drive 계정을 사용할 수 없습니다. 기기 설정을 확인해 주세요."
        case .iCloudContainerUnavailable:
            "NF iCloud 문서 컨테이너를 열지 못했습니다."
        case .iCloudDownloadTimedOut:
            "iCloud 문서를 내려받지 못했습니다. 네트워크 연결을 확인해 주세요."
        case .portalSessionUnavailable:
            "NF 로그인 세션을 찾지 못했습니다. 포털에 다시 로그인해 주세요."
        case .invalidServerResponse:
            "Google Drive 저장 결과를 확인하지 못했습니다."
        case .server(let message):
            message
        }
    }
}

final class PortalPDFICloudRepository {
    nonisolated static let containerIdentifier = "iCloud.co.kr.NF"

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func availability() async -> PortalICloudAvailability {
        guard fileManager.ubiquityIdentityToken != nil else {
            return .accountUnavailable
        }
        let resolvedContainerURL = await containerURL()
        return resolvedContainerURL == nil ? .containerUnavailable : .available
    }

    func documents() async throws -> [PortalICloudPDFDocument] {
        guard fileManager.ubiquityIdentityToken != nil else {
            throw PortalPDFCloudError.iCloudAccountUnavailable
        }
        guard let directoryURL = await documentsDirectoryURL() else {
            throw PortalPDFCloudError.iCloudContainerUnavailable
        }

        return try await Task.detached(priority: .userInitiated) {
            let manager = FileManager.default
            try manager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let keys: Set<URLResourceKey> = [
                .contentModificationDateKey,
                .fileSizeKey,
                .ubiquitousItemDownloadingStatusKey,
                .ubiquitousItemIsUploadedKey
            ]
            let urls = try manager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            )
            return urls
                .filter { $0.pathExtension.lowercased() == "pdf" }
                .map { url in
                    let values = try? url.resourceValues(forKeys: keys)
                    let parsedName = Self.displayInformation(for: url.lastPathComponent)
                    return PortalICloudPDFDocument(
                        id: url.lastPathComponent,
                        fileName: parsedName.fileName,
                        fileURL: url,
                        modifiedAt: values?.contentModificationDate ?? .distantPast,
                        fileSize: Int64(values?.fileSize ?? 0),
                        isDownloaded: values?.ubiquitousItemDownloadingStatus == .current,
                        isUploaded: values?.ubiquitousItemIsUploaded ?? false,
                        localDocumentID: parsedName.localDocumentID
                    )
                }
                .sorted { $0.modifiedAt > $1.modifiedAt }
        }.value
    }

    @discardableResult
    func upload(_ document: PortalLocalPDFDocument) async throws -> PortalICloudPDFDocument {
        guard fileManager.ubiquityIdentityToken != nil else {
            throw PortalPDFCloudError.iCloudAccountUnavailable
        }
        guard let directoryURL = await documentsDirectoryURL() else {
            throw PortalPDFCloudError.iCloudContainerUnavailable
        }
        let localURL = document.localFileURL
        let destinationURL = directoryURL.appendingPathComponent(
            Self.cloudFileName(localDocumentID: document.id, fileName: document.fileName)
        )

        try await Task.detached(priority: .userInitiated) {
            let manager = FileManager.default
            try manager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let data = try Data(contentsOf: localURL, options: [.mappedIfSafe])
            try data.write(to: destinationURL, options: [.atomic])
        }.value

        guard let uploaded = try await documents().first(where: { $0.fileURL == destinationURL }) else {
            throw PortalPDFCloudError.iCloudContainerUnavailable
        }
        return uploaded
    }

    func data(for document: PortalICloudPDFDocument) async throws -> Data {
        try? fileManager.startDownloadingUbiquitousItem(at: document.fileURL)
        for _ in 0..<60 {
            if let data = try? Data(contentsOf: document.fileURL, options: [.mappedIfSafe]), !data.isEmpty {
                return data
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw PortalPDFCloudError.iCloudDownloadTimedOut
    }

    func delete(_ document: PortalICloudPDFDocument) async throws {
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.removeItem(at: document.fileURL)
        }.value
    }

    private func containerURL() async -> URL? {
        await Task.detached(priority: .utility) {
            FileManager.default.url(forUbiquityContainerIdentifier: Self.containerIdentifier)
        }.value
    }

    private func documentsDirectoryURL() async -> URL? {
        guard let containerURL = await containerURL() else { return nil }
        return containerURL
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("NF PDF", isDirectory: true)
    }

    nonisolated static func cloudFileName(localDocumentID: String, fileName: String) -> String {
        let cleanName = fileName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedName = cleanName.lowercased().hasSuffix(".pdf") ? cleanName : "\(cleanName).pdf"
        return "\(localDocumentID)__nf__\(normalizedName)"
    }

    nonisolated static func displayInformation(for cloudFileName: String) -> (localDocumentID: String?, fileName: String) {
        let separator = "__nf__"
        guard let range = cloudFileName.range(of: separator) else {
            return (nil, cloudFileName)
        }
        let localDocumentID = String(cloudFileName[..<range.lowerBound])
        let fileName = String(cloudFileName[range.upperBound...])
        guard !localDocumentID.isEmpty, !fileName.isEmpty else {
            return (nil, cloudFileName)
        }
        return (localDocumentID, fileName)
    }
}

struct PortalPDFGoogleDriveLink: Codable, Identifiable, Hashable, Sendable {
    var id: String { localDocumentID }
    let localDocumentID: String
    let portalFileID: String
    let driveFileID: String
    let fileName: String
    let remoteURL: URL
    let syncedAt: Date
}

final class PortalPDFGoogleDriveLinkStore {
    private let fileManager: FileManager
    private let storageURL: URL

    init(fileManager: FileManager = .default, storageURL: URL? = nil) {
        self.fileManager = fileManager
        let supportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        self.storageURL = storageURL
            ?? supportURL.appendingPathComponent("NF/PDFCloud/google-drive-links.json")
    }

    func links() -> [PortalPDFGoogleDriveLink] {
        guard let data = try? Data(contentsOf: storageURL) else { return [] }
        return (try? JSONDecoder().decode([PortalPDFGoogleDriveLink].self, from: data)) ?? []
    }

    func link(for localDocumentID: String) -> PortalPDFGoogleDriveLink? {
        links().first { $0.localDocumentID == localDocumentID }
    }

    func save(_ link: PortalPDFGoogleDriveLink) throws {
        var currentLinks = links()
        currentLinks.removeAll { $0.localDocumentID == link.localDocumentID }
        currentLinks.append(link)
        try fileManager.createDirectory(
            at: storageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(currentLinks).write(to: storageURL, options: [.atomic])
    }

    func remove(localDocumentID: String) throws {
        let remainingLinks = links().filter { $0.localDocumentID != localDocumentID }
        try fileManager.createDirectory(
            at: storageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(remainingLinks).write(to: storageURL, options: [.atomic])
    }
}

@MainActor
final class PortalSessionCookieProvider {
    func cookieHeader(for url: URL) async -> String? {
        let cookies = await withCheckedContinuation { continuation in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
        guard let host = url.host?.lowercased() else { return nil }
        let matchedCookies = cookies.filter { cookie in
            let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
            return host == domain || host.hasSuffix(".\(domain)")
        }
        let header = matchedCookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        return header.isEmpty ? nil : header
    }
}

@MainActor
final class PortalPDFGoogleDriveService {
    private struct UploadResponse: Decodable {
        struct FileInfo: Decodable {
            let id: String
            let name: String
            let url: URL
            let driveFileId: String
        }

        let ok: Bool
        let file: FileInfo?
        let error: String?
    }

    private struct ServerErrorResponse: Decodable {
        let error: String?
    }

    private let cookieProvider: PortalSessionCookieProvider
    private let linkStore: PortalPDFGoogleDriveLinkStore

    init(
        cookieProvider: PortalSessionCookieProvider? = nil,
        linkStore: PortalPDFGoogleDriveLinkStore? = nil
    ) {
        self.cookieProvider = cookieProvider ?? PortalSessionCookieProvider()
        self.linkStore = linkStore ?? PortalPDFGoogleDriveLinkStore()
    }

    func sync(_ document: PortalLocalPDFDocument) async throws -> PortalPDFGoogleDriveLink {
        if let existingLink = linkStore.link(for: document.id) {
            return try await update(document, link: existingLink)
        }
        return try await upload(document)
    }

    func links() -> [PortalPDFGoogleDriveLink] {
        linkStore.links().sorted { $0.syncedAt > $1.syncedAt }
    }

    func unlink(localDocumentID: String) throws {
        try linkStore.remove(localDocumentID: localDocumentID)
    }

    private func upload(_ document: PortalLocalPDFDocument) async throws -> PortalPDFGoogleDriveLink {
        let endpoint = URL(string: "\(PortalConfig.portalOrigin)/api/artifacts/upload")!
        let cookieHeader = try await requiredCookieHeader(for: endpoint)
        let boundary = "nf-ios-\(UUID().uuidString)"
        let pdfData = try Data(contentsOf: document.localFileURL, options: [.mappedIfSafe])
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        let body = Self.multipartBody(
            boundary: boundary,
            fields: [
                "context": "general:native-pdf-library",
                "tabName": "PDF 문서"
            ],
            fileName: document.fileName,
            fileData: pdfData
        )
        let (data, response) = try await URLSession.shared.upload(for: request, from: body)
        try validate(response: response, data: data)
        guard let result = try? JSONDecoder().decode(UploadResponse.self, from: data),
              result.ok,
              let file = result.file else {
            throw PortalPDFCloudError.invalidServerResponse
        }
        let link = PortalPDFGoogleDriveLink(
            localDocumentID: document.id,
            portalFileID: file.id,
            driveFileID: file.driveFileId,
            fileName: file.name,
            remoteURL: file.url,
            syncedAt: Date()
        )
        try linkStore.save(link)
        return link
    }

    private func update(
        _ document: PortalLocalPDFDocument,
        link: PortalPDFGoogleDriveLink
    ) async throws -> PortalPDFGoogleDriveLink {
        let endpoint = URL(string: "\(PortalConfig.portalOrigin)/api/artifacts/files/\(link.portalFileID)")!
        let cookieHeader = try await requiredCookieHeader(for: endpoint)
        let pdfData = try Data(contentsOf: document.localFileURL, options: [.mappedIfSafe])
        var request = URLRequest(url: endpoint)
        request.httpMethod = "PATCH"
        request.setValue("application/pdf", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        let (data, response) = try await URLSession.shared.upload(for: request, from: pdfData)
        try validate(response: response, data: data)
        let updatedLink = PortalPDFGoogleDriveLink(
            localDocumentID: document.id,
            portalFileID: link.portalFileID,
            driveFileID: link.driveFileID,
            fileName: document.fileName,
            remoteURL: link.remoteURL,
            syncedAt: Date()
        )
        try linkStore.save(updatedLink)
        return updatedLink
    }

    private func requiredCookieHeader(for url: URL) async throws -> String {
        guard let cookieHeader = await cookieProvider.cookieHeader(for: url) else {
            throw PortalPDFCloudError.portalSessionUnavailable
        }
        return cookieHeader
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PortalPDFCloudError.invalidServerResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let responseError = try? JSONDecoder().decode(ServerErrorResponse.self, from: data)
            throw PortalPDFCloudError.server(
                responseError?.error ?? "Google Drive 저장에 실패했습니다. (\(httpResponse.statusCode))"
            )
        }
    }

    nonisolated static func multipartBody(
        boundary: String,
        fields: [String: String],
        fileName: String,
        fileData: Data
    ) -> Data {
        var body = Data()
        for (name, value) in fields.sorted(by: { $0.key < $1.key }) {
            body.appendUTF8("--\(boundary)\r\n")
            body.appendUTF8("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.appendUTF8("\(value)\r\n")
        }
        let safeFileName = fileName.replacingOccurrences(of: "\"", with: "'")
        body.appendUTF8("--\(boundary)\r\n")
        body.appendUTF8("Content-Disposition: form-data; name=\"file\"; filename=\"\(safeFileName)\"\r\n")
        body.appendUTF8("Content-Type: application/pdf\r\n\r\n")
        body.append(fileData)
        body.appendUTF8("\r\n--\(boundary)--\r\n")
        return body
    }
}

private extension Data {
    nonisolated mutating func appendUTF8(_ string: String) {
        append(Data(string.utf8))
    }
}
