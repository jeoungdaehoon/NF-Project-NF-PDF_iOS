import Foundation
import UIKit
import PDFKit

/// Shared by the app and its Share Extension. Originals are retained in the App Group.
enum IncomingDocuments {
    nonisolated static let sessionDidChange = Notification.Name("NFSharedDocumentsSessionDidChange")
    nonisolated static let group = "group.co.kr.NF.documents"
    nonisolated static let origin = URL(string: "https://notefree-1076199489932.asia-northeast3.run.app")!
    nonisolated static let supported = Set(["pdf", "ppt", "pptx", "png", "jpg", "jpeg", "webp", "heic", "heif", "txt", "md", "markdown"])
    nonisolated struct Entry: Codable, Identifiable {
        let id: String
        let name: String
        let sourceName: String
        var imported = false
        var receivedAt: Date? = Date()
        var directory: URL { get throws { try root().appendingPathComponent(id, isDirectory: true) } }
        var pdfURL: URL { get throws { try directory.appendingPathComponent("converted.pdf") } }
        var sourceURL: URL { get throws { try directory.appendingPathComponent(sourceName) } }
        var librarySourceURL: URL { URL(string: "nf-share://\(id)")! }
    }
    nonisolated enum Failure: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
    }
    nonisolated static func root() throws -> URL {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            throw Failure.message("공유 문서 저장소를 열지 못했습니다. NF 앱을 업데이트한 뒤 다시 시도해 주세요.")
        }
        let root = container.appendingPathComponent("SharedDocuments", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    nonisolated static func pending() -> [Entry] {
        guard let root = try? root() else { return [] }
        return ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            .compactMap { try? Data(contentsOf: $0.appendingPathComponent("entry.json")) }
            .compactMap { try? JSONDecoder().decode(Entry.self, from: $0) }
            .filter { !$0.imported }.sorted { ($0.receivedAt ?? .distantPast) < ($1.receivedAt ?? .distantPast) }
    }
    nonisolated static func save(_ entry: Entry) throws {
        try JSONEncoder().encode(entry).write(to: try entry.directory.appendingPathComponent("entry.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    nonisolated static func enqueue(_ url: URL, suggestedName: String? = nil) throws -> Entry {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let raw = (suggestedName ?? url.lastPathComponent) as NSString
        var name = raw.lastPathComponent.components(separatedBy: .controlCharacters).joined(separator: "_")
        if name.isEmpty { name = "문서.\(url.pathExtension)" }
        var ext = (name as NSString).pathExtension.lowercased()
        if !supported.contains(ext), supported.contains(url.pathExtension.lowercased()) { ext = url.pathExtension.lowercased(); name += ".\(ext)" }
        guard supported.contains(ext) else { throw Failure.message("PDF, PPT/PPTX, 이미지, Markdown, TXT 파일을 지원합니다.") }
        guard let input = InputStream(url: url) else { throw Failure.message("공유 파일을 읽지 못했습니다.") }
        input.open(); defer { input.close() }
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = input.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw input.streamError ?? CocoaError(.fileReadUnknown) }
            if count == 0 { break }
            guard bytes.count + count <= 25 * 1024 * 1024 else { throw Failure.message("공유 문서는 25MB까지 지원합니다.") }
            bytes.append(buffer, count: count)
        }
        guard !bytes.isEmpty else { throw Failure.message("빈 파일은 가져올 수 없습니다.") }
        let entry = Entry(id: UUID().uuidString.lowercased(), name: String(name.prefix(180)), sourceName: "source.\(ext)")
        let dir = try entry.directory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            try bytes.write(to: try entry.sourceURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            try save(entry)
            return entry
        } catch { try? FileManager.default.removeItem(at: dir); throw error }
    }
    nonisolated static func pdfName(_ name: String) -> String { (name as NSString).deletingPathExtension + ".pdf" }
    nonisolated static func removeOriginal(for sourceURL: URL?) {
        guard let sourceURL, sourceURL.scheme == "nf-share", let id = sourceURL.host, UUID(uuidString: id) != nil,
              let directory = try? root().appendingPathComponent(id, isDirectory: true) else { return }
        try? FileManager.default.removeItem(at: directory)
    }
    nonisolated static func removeAll() {
        if let directory = try? root() { try? FileManager.default.removeItem(at: directory) }
        syncCookies([])
    }
    static func prepare(_ entry: Entry) async throws -> Data {
        let pdfURL = try entry.pdfURL
        if let cached = try? Data(contentsOf: pdfURL), validPDF(cached) { return cached }
        let source = try entry.sourceURL, data = try Data(contentsOf: source)
        let pdf: Data
        if source.pathExtension == "pdf" { pdf = data }
        else if let image = UIImage(data: data) {
            let size = image.size
            guard size.width > 0, size.height > 0 else { throw Failure.message("이미지를 읽지 못했습니다.") }
            let scale = min(1, 14400 / max(size.width, size.height))
            let bounds = CGRect(origin: .zero, size: CGSize(width: size.width * scale, height: size.height * scale))
            pdf = UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in context.beginPage(); image.draw(in: bounds) }
        } else { pdf = try await convert(data, name: entry.name) }
        guard validPDF(pdf) else { throw Failure.message("유효한 PDF로 변환하지 못했습니다. 원본은 보관했습니다.") }
        try pdf.write(to: pdfURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return pdf
    }
    static func validPDF(_ data: Data) -> Bool {
        data.starts(with: Data("%PDF-".utf8)) && (PDFDocument(data: data)?.pageCount ?? 0) > 0
    }
    nonisolated static func syncCookies(_ cookies: [HTTPCookie]) {
        let store = HTTPCookieStorage.sharedCookieStorage(forGroupContainerIdentifier: group)
        let previous = store.cookies ?? []
        for cookie in previous { store.deleteCookie(cookie) }
        let portalCookies = cookies.filter { $0.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")) == origin.host }
        portalCookies.forEach(store.setCookie)
        let before = previous.filter { $0.name.contains("session-token") }.map { $0.value }.sorted()
        let after = portalCookies.filter { $0.name.contains("session-token") }.map { $0.value }.sorted()
        if before != after, !after.isEmpty { DispatchQueue.main.async { NotificationCenter.default.post(name: sessionDidChange, object: nil) } }
    }
    static func convert(_ data: Data, name: String) async throws -> Data {
        let cookies = HTTPCookieStorage.sharedCookieStorage(forGroupContainerIdentifier: group).cookies(for: origin) ?? []
        guard cookies.contains(where: { $0.name.contains("session-token") }) else { throw Failure.message("PPT·텍스트 변환은 NF 로그인이 필요합니다. 본 앱에서 로그인한 뒤 다시 시도해 주세요. 원본은 보관했습니다.") }
        let boundary = "NF-\(UUID().uuidString)"
        var request = URLRequest(url: origin.appendingPathComponent("api/documents/convert"), timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue(HTTPCookie.requestHeaderFields(with: cookies)["Cookie"], forHTTPHeaderField: "Cookie")
        request.setValue("application/pdf", forHTTPHeaderField: "Accept")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let safe = name.replacingOccurrences(of: "\"", with: "_").components(separatedBy: .newlines).joined(separator: "_")
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(safe)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8)
        body.append(data); body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        let session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (result, response) = try await session.upload(for: request, from: body)
        guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true else {
            let error = (try? JSONSerialization.jsonObject(with: result)) as? [String: Any]
            throw Failure.message(error?["error"] as? String ?? "PDF 변환에 실패했습니다. 로그인과 연결 상태를 확인해 주세요. 원본은 보관했습니다.")
        }
        guard result.count <= 100 * 1024 * 1024 else { throw Failure.message("변환된 PDF가 너무 큽니다.") }
        return result
    }
    private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
}
