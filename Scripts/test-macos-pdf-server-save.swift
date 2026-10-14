import AppKit
import PDFKit
import Foundation

private final class SaveProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, String, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, type, data) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": type])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

/// Uses production save code with mock HTTP and temporary documents only.
@main struct PDFServerSaveRegression {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nf-pdf-save-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else { throw NSError(domain: "PDFSaveTest", code: checks, userInfo: [NSLocalizedDescriptionKey: message]) }
            checks += 1; print("PASS \(checks): \(message)"); fflush(stdout)
        }
        func pdf() -> PDFDocument {
            let doc = PDFDocument(), page = PDFPage(); page.setBounds(CGRect(x: 0, y: 0, width: 600, height: 800), for: .mediaBox)
            doc.insert(page, at: 0); return doc
        }
        let source = URL(string: MacPortalConfig.origin + "/api/artifacts/files/test-file?download=1#viewer")!
        let endpoint = try MacPDFRemoteSave.endpoint(for: source)
        try check(endpoint.query == nil && endpoint.fragment == nil, "save targets the existing file, without download query")
        for value in ["https://example.test/api/artifacts/files/test", MacPortalConfig.origin + "/login", MacPortalConfig.origin + "/api/artifacts/upload", MacPortalConfig.origin + "/api/artifacts/files/a/b", MacPortalConfig.origin + "/api/artifacts/files/a%2fb"] {
            var rejected = false
            do { _ = try MacPDFRemoteSave.endpoint(for: URL(string: value)!) } catch { rejected = true }
            try check(rejected, "unsafe/non-attachment upload endpoint rejected: \(value)")
        }
        let marker = "FINAL EDIT SENT TO DRIVE"
        let state = MacPDFEditorState(document: pdf(), identifier: "remote", fileName: "fixture.pdf", sourceURL: source, directory: root.appendingPathComponent("remote"))
        state.add(MacPDFObject(page: 0, kind: .text, bounds: CGRect(x: 50, y: 200, width: 400, height: 80), text: marker))
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [SaveProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let saver = MacPDFRemoteSave(session: session, cookieProvider: { _ in "fresh-cookie" })
        var transferred = Data(), methods = [String](), verifiedURLs = [URL]()
        SaveProtocol.handler = { request in
            guard request.value(forHTTPHeaderField: "Cookie") == "fresh-cookie" else { throw URLError(.userAuthenticationRequired) }
            methods.append(request.httpMethod ?? "GET")
            if request.httpMethod == "PATCH" {
                return (200, "application/json", Data("{\"ok\":true,\"file\":{\"id\":\"test-file\",\"size\":\(transferred.count)}}".utf8))
            }
            verifiedURLs.append(request.url!)
            return (200, "application/pdf", transferred)
        }
        state.onSave = { data in transferred = data; try await saver.save(source: source, data: data) }
        await state.save()
        try check(state.error == nil && state.status == "첨부 서버 저장 확인 완료", "success appears only after server acknowledgement and readback")
        try check(PDFDocument(data: transferred)?.string?.contains(marker) == true, "uploaded bytes contain the final edited text")
        try check(methods == ["PATCH", "GET"], "replace then re-download, never create a new Drive file")
        try check(verifiedURLs.first?.query?.contains("nf_pdf_revision=") == true, "readback bypasses stale URL cache")
        let reopened = MacPDFEditorState(document: pdf(), identifier: "remote", fileName: "fixture.pdf", sourceURL: source, directory: root.appendingPathComponent("remote"))
        try check(reopened.objects.count == 1 && reopened.objects.first?.text == marker, "editable local objects survive flattened remote save")

        let cases: [(Int, String, String)] = [
            (200, "text/html", "<html>login</html>"),
            (200, "application/json", "{\"ok\":false,\"error\":\"no permission\"}"),
            (200, "application/json", "{\"ok\":true,\"file\":{\"id\":\"different-file\",\"size\":1}}"),
            (200, "application/json", "{\"ok\":true,\"file\":{\"id\":\"test-file\",\"size\":1}}"),
            (401, "application/json", "{\"error\":\"login expired\"}"),
            (423, "application/json", "{\"error\":\"page locked\"}"),
        ]
        for (status, mime, body) in cases {
            let response = HTTPURLResponse(url: endpoint, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": mime])!
            var rejected = false
            do { try MacPDFRemoteSave.validate(body: Data(body.utf8), response: response, endpoint: endpoint, size: transferred.count) } catch { rejected = true }
            try check(rejected, "reject false success / error response: \(status) \(body.prefix(40))")
        }
        SaveProtocol.handler = { request in
            if request.httpMethod == "PATCH" { return (200, "application/json", Data("{\"ok\":true,\"file\":{\"id\":\"test-file\",\"size\":\(transferred.count)}}".utf8)) }
            return (200, "application/pdf", Data("%PDF-original-stale".utf8))
        }
        await state.save()
        try check(state.status == "저장 실패" && state.error != nil, "stale readback cannot become saved status")
        try check(state.objects.first?.text == marker, "failed remote verification preserves local edit")
        let empty = MacPDFEditorState(document: PDFDocument(), identifier: "empty", fileName: "empty.pdf", sourceURL: source, directory: root.appendingPathComponent("empty"))
        var invoked = false; empty.onSave = { _ in invoked = true }
        await empty.save()
        try check(!invoked && empty.status == "저장 실패", "invalid edited PDF never falls back to uploading original")

        state.onSave = { _ in state.add(MacPDFObject(page: 0, kind: .text, bounds: CGRect(x: 50, y: 350, width: 300, height: 60), text: "edited during upload")) }
        await state.save()
        try check(state.status.hasSuffix("이후 편집은 미저장"), "edits made during upload remain marked unsaved")
        let local = MacPDFEditorState(document: pdf(), identifier: "local", fileName: "local.pdf", directory: root.appendingPathComponent("local"))
        local.add(MacPDFObject(page: 0, kind: .text, bounds: CGRect(x: 50, y: 200, width: 400, height: 80), text: marker))
        local.onSave = { data in try check(PDFDocument(data: data)?.string?.contains(marker) != true, "local file retains base plus separate editable archive") }
        await local.save()
        try check(local.status == "Mac에 저장 완료", "local save clearly identified, no server upload")
        print("PASS: \(checks) PDF server-save checks (no real network/user files)")
    }
}
