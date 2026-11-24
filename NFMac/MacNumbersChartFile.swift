import Combine
import Foundation
import SwiftUI
import WebKit

enum MacNumbersChartFile {
    private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private struct Result: Decodable {
        let path: String?
        let name: String?
        let error: String?
    }

    static func sourceID(_ url: URL) -> String? {
        let parts = url.path.split(separator: "/")
        guard url.scheme == "https", MacPortalConfig.isPortalURL(url), url.port == nil || url.port == 443,
              url.user == nil, url.password == nil, parts.count == 4,
              parts.prefix(3).elementsEqual(["api", "artifacts", "files"]),
              parts[3].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        return String(parts[3])
    }

    static func editorURL(path: String, source: URL) -> URL? {
        guard let id = sourceID(source), path == "/charts/files/" + id else { return nil }
        return URL(string: MacPortalConfig.origin + path + "?embedded=1")
    }

    static func create(source: URL, cookie: String?, contents: MacNumbersContents) async throws -> (URL, String) {
        guard let id = sourceID(source), let endpoint = URL(string: MacPortalConfig.origin + "/api/artifacts/files/" + id + "/chart"),
              let cookie, !cookie.isEmpty else { throw failure("포털에 로그인한 뒤 Numbers 첨부를 다시 열어 주세요.") }
        let sheets = try contents.chartImportSheets()
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 100)
        request.httpMethod = "POST"
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue(MacPortalConfig.origin, forHTTPHeaderField: "Origin")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["sheets": sheets])
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        let session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        let result = try? JSONDecoder().decode(Result.self, from: data)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let path = result?.path, let url = editorURL(path: path, source: source), let name = result?.name else {
            throw failure(result?.error ?? "Drive에 NF 차트 파일을 만들지 못했습니다.")
        }
        return (url, name)
    }

    fileprivate static func failure(_ message: String) -> NSError {
        NSError(domain: "NF.NumbersChart", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

final class MacNumbersChartWebSession: ObservableObject {
    weak var webView: WKWebView?

    func save() async -> Bool {
        guard let webView else { return true }
        return (try? await webView.callAsyncJavaScript(
            "return typeof window.__nfChartSave !== 'function' || await window.__nfChartSave();",
            arguments: [:], in: nil, contentWorld: .page
        ) as? Bool) == true
    }
}

struct MacNumbersChartWebView: NSViewRepresentable {
    let url: URL
    let session: MacNumbersChartWebSession

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        session.webView = webView
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}
}

private extension MacNumbersContents {
    func chartImportSheets() throws -> [[String: Any]] {
        guard !sheets.isEmpty else { throw MacNumbersChartFile.failure("가져올 Numbers 시트가 없습니다.") }
        var output: [[String: Any]] = []
        var totalCells = 0
        var totalBytes = 0
        for sheet in sheets {
            if sheet.tables.isEmpty {
                output.append(["name": sheet.name, "rows": [[""]], "headerRows": 0])
                totalCells += 1
                continue
            }
            for table in sheet.tables {
                let lastRow = table.values.keys.map { $0 / table.columnCount }.max() ?? 0
                let lastColumn = table.values.keys.map { $0 % table.columnCount }.max() ?? 0
                guard lastRow < 500, lastColumn < 50 else { throw Self.importLimit }
                totalCells += (lastRow + 1) * (lastColumn + 1)
                guard totalCells <= 10_000 else { throw Self.importLimit }
                let rows = try (0...lastRow).map { row in
                    try (0...lastColumn).map { column in
                        let value = table.value(row: row, column: column)
                        totalBytes += value.utf8.count
                        guard value.utf16.count <= 20_000, totalBytes <= 5 * 1024 * 1024 else {
                            throw MacNumbersChartFile.failure("셀당 20,000자, 전체 5MB까지 불러올 수 있습니다.")
                        }
                        return value
                    }
                }
                let name = sheet.tables.count == 1 ? sheet.name : "\(sheet.name) · \(table.name)"
                output.append(["name": name, "rows": rows, "headerRows": table.headerRows])
            }
        }
        guard output.count <= 30, totalCells <= 10_000 else { throw Self.importLimit }
        return output
    }

    private static var importLimit: NSError {
        MacNumbersChartFile.failure("최대 30개 시트, 시트당 500행·50열, 전체 10,000셀까지 불러올 수 있습니다.")
    }
}
