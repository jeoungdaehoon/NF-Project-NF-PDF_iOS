import CryptoKit
import Foundation
import WebKit

/// Keeps the portal's existing editor mounted while the WebView hosts the annotation layer.
@MainActor
final class LiveDetailPDF: NSObject, WKScriptMessageHandlerWithReply {
    static let bridgeName = "NFAppleLiveDetailPDF"
    private static let maximumBytes = 12 * 1024 * 1024

    private struct Session {
        let token: String
        let origin: URL
        let file: URL
        var revision: String
    }

    private var pending: Task<Void, Never>?
    private var session: Session?
    private weak var nativeWebView: WKWebView?

    struct NativeViewport: Decodable, Equatable {
        let x, y, width, height: Double
        let scrollX, scrollY, scale, zoom, pageZoom: Double
        let contentWidth, contentHeight: Double
    }

    var openNativeEditor: ((URL, Data) throws -> Void)?
    var updateNativeViewport: ((NativeViewport) -> Void)?
    var reportNativeError: ((String) -> Void)?
    var prepareNativeClose: (() async -> Bool)?
    var closeNativeEditor: (() -> Void)?

    func nativeCommand(_ command: String, x: Double = 0, y: Double = 0) {
        guard let session, let webView = nativeWebView else { return }
        webView.callAsyncJavaScript(
            "return await window.__nfAppleLiveDetailPDF?.nativeCommand(token, command, x, y);",
            arguments: ["token": session.token, "command": command, "x": x, "y": y],
            in: nil, in: .page, completionHandler: nil
        )
    }

    @discardableResult
    func intercept(_ action: WKNavigationAction, webView: WKWebView, origin: URL) -> Bool {
        guard action.sourceFrame.isMainFrame, let source = action.sourceFrame.request.url, let pageURL = webView.url,
              Self.isSameOrigin(source, origin), Self.isSameOrigin(pageURL, origin),
              let url = action.request.url, DetailPDFWorkspace.matches(url, origin: origin),
              URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(
                .init(name: "download", value: "0")
              ) == true else { return false }

        let parts = url.pathComponents
        guard parts.count == 6, parts[1] == "api", parts[2] == "detail-pdf",
              parts[4].range(of: #"^[a-zA-Z0-9_-]{1,120}$"#, options: .regularExpression) != nil else { return false }
        let noteID = parts[3] == "note" && pageURL.path == "/custom/" + parts[4] ? parts[4] : nil

        pending?.cancel()
        pending = Task { [weak self, weak webView] in
            guard let self, let webView else { return }
            do {
                let account = try await webView.callAsyncJavaScript("""
                    const response = await fetch('/api/auth/session', { cache: 'no-store', redirect: 'error' });
                    if (!response.ok) return null;
                    return (await response.json()).user?.id ?? null;
                    """, arguments: [:], in: nil, contentWorld: .page)
                try Task.checkCancellation()
                guard let account = account as? String, !account.isEmpty, webView.url == pageURL else {
                    throw URLError(.userAuthenticationRequired)
                }
                try await open(webView: webView, origin: origin, pageURL: pageURL, document: url.path, noteID: noteID, account: account)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, webView.url == pageURL else { return }
                _ = try? await webView.callAsyncJavaScript(
                    "alert(message);", arguments: ["message": "PDFView를 열지 못했습니다. 문서와 로그인 상태를 확인해 주세요."],
                    in: nil, contentWorld: .page
                )
            }
        }
        return true
    }

    func reset() {
        pending?.cancel()
        pending = nil
        session = nil
        nativeWebView = nil
        closeNativeEditor?()
    }

    private func open(webView: WKWebView, origin: URL, pageURL: URL, document: String, noteID: String?, account: String) async throws {
        guard let resource = Bundle.main.url(forResource: "apple-live-detail-pdf", withExtension: "js") else {
            throw CocoaError(.fileNoSuchFile)
        }
        // A switch within the same WebView must finish saving the previous annotations first.
        let closed = try await webView.callAsyncJavaScript(
            "return window.__nfAppleLiveDetailPDF ? await window.__nfAppleLiveDetailPDF.close(false) : true;",
            arguments: [:], in: nil, contentWorld: .page
        )
        try Task.checkCancellation()
        guard closed as? Bool == true, webView.url == pageURL else { return }

        let directory = URL.applicationSupportDirectory.appendingPathComponent("NF/LiveDetailPDF", isDirectory: true)
        let key = Self.digest(Data("\(origin.absoluteString)\n\(account)\n\(document)".utf8))
        let file = directory.appendingPathComponent(key).appendingPathExtension("json")
        let saved = try Self.savedData(at: file)
        let token = UUID().uuidString
        let revision = Self.digest(saved)
        session = Session(token: token, origin: origin, file: file, revision: revision)
        nativeWebView = openNativeEditor == nil ? nil : webView
        do {
            let script = try String(contentsOf: resource, encoding: .utf8)
            try openNativeEditor?(file.deletingPathExtension().appendingPathExtension("native"), saved)
            let opened = try await webView.callAsyncJavaScript(
                "return (\(script))(token, noteID, previous, useNativeEditor, pageZoom);",
                arguments: ["token": token, "noteID": noteID.map { $0 as Any } ?? NSNull(),
                            "previous": String(decoding: saved, as: UTF8.self),
                            "useNativeEditor": openNativeEditor != nil, "pageZoom": webView.pageZoom],
                in: nil, contentWorld: .page
            )
            guard opened as? Bool == true else { throw CocoaError(.fileReadUnknown) }
        } catch {
            if session?.token == token {
                session = nil
                nativeWebView = nil
                closeNativeEditor?()
            }
            throw error
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard message.frameInfo.isMainFrame, let frameURL = message.frameInfo.request.url,
              let currentURL = message.webView?.url, let body = message.body as? [String: Any], var current = session,
              Self.isSameOrigin(frameURL, current.origin), Self.isSameOrigin(currentURL, current.origin),
              body["token"] as? String == current.token else {
            replyHandler(nil, "PDFView 세션이 종료되었습니다.")
            return
        }
        if body["closed"] as? Bool == true {
            session = nil
            nativeWebView = nil
            closeNativeEditor?()
            replyHandler(true, nil)
            return
        }
        if nativeWebView === message.webView, body["prepareNativeClose"] as? Bool == true {
            Task { @MainActor in replyHandler(await prepareNativeClose?() ?? true, nil) }
            return
        }
        if nativeWebView === message.webView, let error = body["nativeError"] as? String, !error.isEmpty {
            reportNativeError?(String(error.prefix(240)))
            replyHandler(true, nil)
            return
        }
        if nativeWebView === message.webView, let raw = body["viewport"] as? String {
            guard raw.utf8.count < 2048,
                  let viewport = try? JSONDecoder().decode(NativeViewport.self, from: Data(raw.utf8)),
                  (0.05...25).contains(viewport.scale), (0.25...5).contains(viewport.pageZoom),
                  (0.1...10).contains(viewport.zoom),
                  [viewport.x, viewport.y, viewport.width, viewport.height, viewport.scrollX, viewport.scrollY,
                   viewport.contentWidth, viewport.contentHeight].allSatisfy({ abs($0) < 10_000_000 }),
                  viewport.width > 0, viewport.height > 0, viewport.contentWidth > 0, viewport.contentHeight > 0 else {
                replyHandler(nil, "상세페이지 영역을 확인하지 못했습니다.")
                return
            }
            updateNativeViewport?(viewport)
            replyHandler(true, nil)
            return
        }
        if let title = body["createNote"] as? String {
            let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, title.utf16.count <= 40 else {
                replyHandler(nil, "새 문서 제목은 40자 이내로 입력해 주세요.")
                return
            }
            Task { @MainActor in
                do {
                    let url = try await PDFPageCreation().create(title, origin: current.origin)
                    guard let href = PDFPageLink.href(for: url, origin: current.origin) else {
                        throw URLError(.badServerResponse)
                    }
                    replyHandler(href, nil)
                } catch {
                    replyHandler(nil, error.localizedDescription)
                }
            }
            return
        }
        guard let raw = body["annotations"] as? String, raw.utf8.count <= Self.maximumBytes,
              let data = raw.data(using: .utf8) else {
            replyHandler(nil, "주석 저장 용량을 초과했습니다.")
            return
        }
        do {
            let value = try JSONSerialization.jsonObject(with: data)
            guard value is [Any] || (value as? [String: Any])?["annotations"] is [Any] else {
                replyHandler(nil, "주석 형식이 올바르지 않습니다.")
                return
            }
            let previousRevision = Self.digest(try Self.savedData(at: current.file))
            let digest = Self.digest(data)
            if digest != previousRevision {
                guard current.revision == previousRevision else {
                    replyHandler(nil, "다른 창에서 이 문서의 주석을 수정했습니다.")
                    return
                }
                var directory = current.file.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try? directory.setResourceValues(values)
                try data.write(to: current.file, options: .atomic)
            }
            current.revision = digest
            session = current
            replyHandler(true, nil)
        } catch {
            replyHandler(nil, "주석을 기기에 저장하지 못했습니다.")
        }
    }

    private static func savedData(at url: URL) throws -> Data {
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= maximumBytes else { throw CocoaError(.fileReadTooLarge) }
            return data
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return Data()
        }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isSameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme == rhs.scheme && lhs.host == rhs.host && lhs.port == rhs.port &&
            lhs.user == nil && lhs.password == nil
    }
}
