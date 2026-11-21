import CryptoKit
import Foundation
import PDFKit

/// A private native editing workspace for a PDF rendered from a portal detail page.
struct DetailPDFWorkspace {
    static let userAgentToken = "NFDetailPDF/1"
    static let returnTitle = "상세페이지로 돌아가기"
    static let retainedEditsMessage = "원본 페이지 구성이 바뀌었거나 PDF 본문을 편집했습니다. 기존 PDF 편집본을 표시합니다."

    private struct AccountSession: Decodable {
        struct User: Decodable { let id: String }
        let user: User
    }

    private struct Revision: Codable {
        let etag: String?
        let fileName: String
        let digest: String
    }

    let identifier: String
    let directory: URL
    let fileName: String
    let digest: String
    let data: Data

    static func matches(_ url: URL, origin: URL) -> Bool {
        url.scheme == "https" && url.host == origin.host && url.port == origin.port
            && url.user == nil && url.password == nil
            && url.path.hasPrefix("/api/detail-pdf/") && url.lastPathComponent == "detail.pdf"
    }

    static func open(url: URL, origin: URL, cookieHeader: String?) async throws -> DetailPDFWorkspace {
        guard matches(url, origin: origin), let cookieHeader, !cookieHeader.isEmpty else {
            throw URLError(.userAuthenticationRequired)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        func request(_ url: URL, etag: String? = nil) async throws -> (Data, HTTPURLResponse) {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 120)
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.url == url else { throw URLError(.badServerResponse) }
            return (data, http)
        }

        let (accountData, accountResponse) = try await request(origin.appendingPathComponent("api/auth/session"))
        guard accountResponse.statusCode == 200,
              let account = try? JSONDecoder().decode(AccountSession.self, from: accountData),
              !account.user.id.isEmpty else { throw URLError(.userAuthenticationRequired) }
        let identifier = hash(Data("\(account.user.id)\n\(origin.absoluteString)\(url.path)".utf8))
        var directory = URL.applicationSupportDirectory.appendingPathComponent("NF/DetailPDF/\(identifier)", isDirectory: true)
        let manifest = directory.appendingPathComponent("source.json")
        let cachedRevision = (try? Data(contentsOf: manifest)).flatMap { try? JSONDecoder().decode(Revision.self, from: $0) }
        let cached = cachedRevision.flatMap { revision in
            sourceFile(in: directory, digest: revision.digest).flatMap { try? Data(contentsOf: $0) }
        }
        let (download, response) = try await request(url, etag: cached == nil ? nil : cachedRevision?.etag)
        try Task.checkCancellation()
        if response.statusCode == 304, let cachedRevision, let cached {
            return DetailPDFWorkspace(identifier: identifier, directory: directory, fileName: cachedRevision.fileName, digest: cachedRevision.digest, data: cached)
        }
        guard response.statusCode == 200, response.mimeType == "application/pdf",
              let pdf = PDFDocument(data: download), pdf.pageCount > 0 else { throw URLError(.badServerResponse) }
        let digest = hash(download)
        let fileName = response.suggestedFilename ?? "상세페이지.pdf"
        let revision = Revision(etag: response.value(forHTTPHeaderField: "ETag"), fileName: fileName, digest: digest)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var properties = URLResourceValues()
        properties.isExcludedFromBackup = true
        try? directory.setResourceValues(properties)
        try download.write(to: directory.appendingPathComponent("source-\(digest).pdf"), options: .atomic)
        try JSONEncoder().encode(revision).write(to: manifest, options: .atomic)
        return DetailPDFWorkspace(identifier: identifier, directory: directory, fileName: fileName, digest: digest, data: download)
    }

    var editableFile: URL { directory.appendingPathComponent("editable.pdf") }

    /// Update the base only when edits can keep their original page coordinates.
    func prepareEditableFile(hasPageEdits: Bool) throws -> Bool {
        let marker = directory.appendingPathComponent("editable-source")
        if FileManager.default.fileExists(atPath: editableFile.path) {
            if let revision = try? String(contentsOf: marker, encoding: .utf8) {
                if revision == digest { return true }
                guard let edited = PDFDocument(url: editableFile),
                      canRefresh(edited: edited, previousDigest: revision, hasPageEdits: hasPageEdits) else { return false }
            } else {
                guard (try? Data(contentsOf: editableFile)) == data else { return false }
            }
        }
        try data.write(to: editableFile, options: .atomic)
        try Data(digest.utf8).write(to: marker, options: .atomic)
        return true
    }

    func canRefresh(edited: PDFDocument, previousDigest: String, hasPageEdits: Bool) -> Bool {
        guard let previousURL = Self.sourceFile(in: directory, digest: previousDigest),
              let previous = PDFDocument(url: previousURL), let next = PDFDocument(data: data) else { return false }
        return Self.canRefresh(previous: previous, edited: edited, next: next, hasPageEdits: hasPageEdits)
    }

    static func canRefresh(previous: PDFDocument, edited: PDFDocument, next: PDFDocument, hasPageEdits: Bool) -> Bool {
        guard previous.pageCount == edited.pageCount,
              !hasPageEdits || previous.pageCount == next.pageCount else { return false }
        for index in 0..<previous.pageCount {
            guard let original = previous.page(at: index), let current = edited.page(at: index),
                  samePageLayout(original, current), original.string == current.string,
                  original.annotations.count == current.annotations.count,
                  zip(original.annotations, current.annotations).allSatisfy({ original, edit in
                      original.type == edit.type && original.bounds == edit.bounds && original.contents == edit.contents
                          && (original.url ?? (original.action as? PDFActionURL)?.url) == (edit.url ?? (edit.action as? PDFActionURL)?.url)
                  }) else { return false }
            if hasPageEdits {
                guard let new = next.page(at: index), samePageLayout(original, new) else { return false }
            }
        }
        return true
    }

    private static func samePageLayout(_ lhs: PDFPage, _ rhs: PDFPage) -> Bool {
        lhs.rotation == rhs.rotation
            && lhs.bounds(for: .mediaBox) == rhs.bounds(for: .mediaBox)
            && lhs.bounds(for: .cropBox) == rhs.bounds(for: .cropBox)
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func sourceFile(in directory: URL, digest: String) -> URL? {
        guard digest.count == 64, digest.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        return directory.appendingPathComponent("source-\(digest).pdf")
    }
}
