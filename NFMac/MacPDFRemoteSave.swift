import CryptoKit
import Foundation

/// Replace only the existing portal attachment; never create a separate Drive file.
@MainActor
final class MacPDFRemoteSave {
    private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
    private struct Result: Decodable {
        let ok: Bool?
        let error: String?
        let file: File?
        struct File: Decodable { let id: String; let size: Int }
    }
    static let shared = MacPDFRemoteSave()
    private let session: URLSession
    private let cookieProvider: (URL) async -> String?

    init(session: URLSession? = nil, cookieProvider: @escaping (URL) async -> String? = { await MacPDFGoogleDrive.cookieHeader(for: $0) }) {
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.urlCache = nil
            self.session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        }
        self.cookieProvider = cookieProvider
    }

    static func endpoint(for source: URL) throws -> URL {
        let parts = source.path.split(separator: "/")
        guard source.scheme == "https", MacPortalConfig.isPortalURL(source), source.port == nil || source.port == 443,
              source.user == nil, source.password == nil, parts.count == 4,
              parts[0] == "api", parts[1] == "artifacts", parts[2] == "files",
              parts[3].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }),
              var components = URLComponents(url: source, resolvingAgainstBaseURL: false) else {
            throw failure("기존 포털 첨부 PDF만 서버에 저장할 수 있습니다. 외부·로컬 PDF는 PDF 다운로드를 사용해 주세요.")
        }
        components.query = nil; components.fragment = nil
        guard let endpoint = components.url else { throw failure("첨부 파일 저장 주소가 올바르지 않습니다.") }
        return endpoint
    }

    func save(source: URL, data: Data) async throws {
        guard data.starts(with: Data("%PDF-".utf8)), data.count <= 25 * 1024 * 1024 else {
            throw Self.failure("유효한 25MB 이하 편집 PDF만 서버에 저장할 수 있습니다.")
        }
        let endpoint = try Self.endpoint(for: source)
        guard let cookie = await cookieProvider(endpoint), !cookie.isEmpty else {
            throw Self.failure("포털 로그인이 만료되었습니다. 다시 로그인한 뒤 저장해 주세요.")
        }
        var upload = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData)
        upload.httpMethod = "PATCH"
        upload.setValue("application/pdf", forHTTPHeaderField: "Content-Type")
        upload.setValue("application/json", forHTTPHeaderField: "Accept")
        upload.setValue(cookie, forHTTPHeaderField: "Cookie")
        let (body, response) = try await session.upload(for: upload, from: data)
        try Self.validate(body: body, response: response, endpoint: endpoint, size: data.count)

        // Confirm the bytes other OSes will receive, bypassing any previous cached URL.
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "nf_pdf_revision", value: UUID().uuidString)]
        var verify = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData)
        verify.setValue(cookie, forHTTPHeaderField: "Cookie")
        verify.setValue("no-cache, no-store", forHTTPHeaderField: "Cache-Control")
        let (stored, readResponse) = try await session.data(for: verify)
        guard let http = readResponse as? HTTPURLResponse, http.statusCode == 200,
              http.url?.host == endpoint.host, http.url?.path == endpoint.path,
              SHA256.hash(data: stored) == SHA256.hash(data: data) else {
            throw Self.failure("서버에 전송했지만 편집본을 다시 확인하지 못했습니다. 로컬 편집은 유지됩니다. 로그인·연결 상태를 확인하고 다시 저장해 주세요.")
        }
    }

    static func validate(body: Data, response: URLResponse, endpoint: URL, size: Int) throws {
        let result = try? JSONDecoder().decode(Result.self, from: body)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              http.url?.scheme == endpoint.scheme, http.url?.host == endpoint.host, http.url?.path == endpoint.path,
              http.mimeType == "application/json", result?.ok == true,
              result?.file?.id == endpoint.lastPathComponent, result?.file?.size == size else {
            throw failure(result?.error ?? "서버 저장 완료를 확인하지 못했습니다. 로그인·파일 수정 권한을 확인해 주세요. 로컬 편집은 유지됩니다.")
        }
    }
    private static func failure(_ message: String) -> NSError {
        NSError(domain: "NF.PDF.RemoteSave", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
