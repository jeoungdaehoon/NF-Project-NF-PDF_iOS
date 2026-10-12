import Foundation
import WebKit

@MainActor
enum MacPDFGoogleDrive {
    struct Link: Codable { var portalFileID: String; var driveFileID: String?; var name: String }
    private struct Response: Decodable {
        var ok: Bool
        var file: File?
        struct File: Decodable { var id: String; var driveFileId: String?; var name: String }
    }
    static func cookieHeader(for url: URL) async -> String? {
        let cookies: [HTTPCookie] = await withCheckedContinuation { continuation in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
        let host = url.host?.lowercased() ?? ""
        let matching = cookies.filter {
            let domain = $0.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
            return (host == domain || host.hasSuffix(".\(domain)")) && url.path.hasPrefix($0.path) && (!$0.isSecure || url.scheme == "https") && ($0.expiresDate == nil || $0.expiresDate! > Date())
        }
        return matching.isEmpty ? nil : HTTPCookie.requestHeaderFields(with: matching)["Cookie"]
    }
    static func sync(identifier: String, fileName: String, data: Data) async throws {
        guard data.count <= 25 * 1024 * 1024 else { throw NSError(domain: "NFDrive", code: 413, userInfo: [NSLocalizedDescriptionKey: "Drive 업로드는 25MB 이하 PDF만 지원합니다. 큰 문서는 PDF 다운로드로 보관해 주세요."]) }
        let key = "nf.mac.pdf.drive.\(identifier)"
        let existing = UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(Link.self, from: $0) }
        let endpoint = URL(string: MacPortalConfig.origin + (existing.map { "/api/artifacts/files/\($0.portalFileID)" } ?? "/api/artifacts/upload"))!
        guard let cookie = await cookieHeader(for: endpoint) else { throw NSError(domain: "NFDrive", code: 401, userInfo: [NSLocalizedDescriptionKey: "포털에 로그인한 뒤 다시 시도해 주세요."]) }
        var request = URLRequest(url: endpoint); request.setValue(cookie, forHTTPHeaderField: "Cookie"); request.setValue("application/json", forHTTPHeaderField: "Accept")
        let body: Data
        if existing != nil { request.httpMethod = "PATCH"; request.setValue("application/pdf", forHTTPHeaderField: "Content-Type"); body = data }
        else {
            let boundary = "nf-mac-\(UUID().uuidString)"; request.httpMethod = "POST"; request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            var payload = Data()
            func append(_ text: String) { payload.append(Data(text.utf8)) }
            for (name, value) in [("context", "general:native-pdf-library"), ("tabName", "PDF 문서")] { append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n") }
            let safeName = fileName.replacingOccurrences(of: "\"", with: "-").components(separatedBy: .newlines).joined(separator: " ")
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"\r\nContent-Type: application/pdf\r\n\r\n"); payload.append(data); append("\r\n--\(boundary)--\r\n"); body = payload
        }
        let (responseData, response) = try await URLSession.shared.upload(for: request, from: body)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "NFDrive", code: (response as? HTTPURLResponse)?.statusCode ?? -1, userInfo: [NSLocalizedDescriptionKey: "Google Drive 저장에 실패했습니다. 로그인·파일 권한을 확인해 주세요."])
        }
        if let existing { UserDefaults.standard.set(try JSONEncoder().encode(existing), forKey: key) }
        else {
            let result = try JSONDecoder().decode(Response.self, from: responseData)
            guard result.ok, let file = result.file else { throw NSError(domain: "NFDrive", code: -2, userInfo: [NSLocalizedDescriptionKey: "포털 업로드 결과를 확인하지 못했습니다."]) }
            UserDefaults.standard.set(try JSONEncoder().encode(Link(portalFileID: file.id, driveFileID: file.driveFileId, name: file.name)), forKey: key)
            guard file.driveFileId != nil else { throw NSError(domain: "NFDrive", code: -2, userInfo: [NSLocalizedDescriptionKey: "포털 업로드는 처리되었지만 Drive 연결을 확인하지 못했습니다. 연결 정보를 보관했으므로 재시도 시 같은 파일을 갱신합니다."]) }
        }
    }
    static func unlink(_ identifier: String) { UserDefaults.standard.removeObject(forKey: "nf.mac.pdf.drive.\(identifier)") }
}

extension MacPDFEditorState {
    func syncToGoogleDrive() async {
        guard !isSaving, let data = exportPDF() else { return }
        isSaving = true; status = "Google Drive 저장 중…"; defer { isSaving = false }
        do { try await MacPDFGoogleDrive.sync(identifier: identifier, fileName: fileName, data: data); status = "Google Drive 저장 완료" }
        catch { self.error = error.localizedDescription; status = "Drive 저장 실패" }
    }
    func unlinkGoogleDrive() { MacPDFGoogleDrive.unlink(identifier); status = "Drive 연결 해제됨 (원격 파일 유지)" }
}
