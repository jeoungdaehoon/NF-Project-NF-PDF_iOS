import QuickLook
import SwiftUI
import WebKit

struct PortalNumbersChartLink: Equatable {
    let url: URL
    let name: String
}

enum PortalNumbersAttachment {
    private struct Conversion: Decodable {
        let path: String?
        let name: String?
        let error: String?
    }

    static func sourceID(_ url: URL) -> String? {
        guard url.scheme == "https", url.host == PortalConfig.portalHost,
              url.port == nil || url.port == 443, url.user == nil, url.password == nil,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.queryItems?.contains(where: { $0.name == "original" && $0.value == "1" }) != true,
              parts.percentEncodedPath.range(of: "^/api/artifacts/files/[A-Za-z0-9_-]{1,120}$", options: .regularExpression) != nil
        else { return nil }
        return url.lastPathComponent
    }

    static func chart(path: String, name: String?, sourceID: String) -> PortalNumbersChartLink? {
        guard path == "/charts/files/" + sourceID,
              let url = URL(string: PortalConfig.portalOrigin + path + "?embedded=1") else { return nil }
        return PortalNumbersChartLink(url: url, name: name ?? "NF 차트")
    }

    static func isNumbers(_ response: HTTPURLResponse) -> Bool {
        let type = response.mimeType?.lowercased()
        return response.value(forHTTPHeaderField: "X-NF-Numbers-Source") == "1"
            || response.suggestedFilename?.lowercased().hasSuffix(".numbers") == true
            || type == "application/vnd.apple.numbers" || type == "application/x-iwork-numbers-sffnumbers"
    }

    private static func request(_ item: PortalAttachmentPreviewItem, suffix: String, method: String = "GET") throws -> URLRequest {
        guard let id = sourceID(item.url), let url = URL(string: PortalConfig.portalOrigin + "/api/artifacts/files/" + id + suffix)
        else { throw failure("Numbers 첨부 주소를 확인할 수 없습니다.") }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 120)
        request.httpMethod = method
        if let cookie = item.cookieHeader { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        return request
    }

    static func original(_ item: PortalAttachmentPreviewItem) async throws -> PortalNumbersTemporaryFile {
        let request = try request(item, suffix: "?original=1")
        let (download, response) = try await URLSession.shared.download(for: request, delegate: NoRedirect())
        defer { try? FileManager.default.removeItem(at: download) }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, isNumbers(http) else {
            throw failure("Numbers 원본을 불러오지 못했습니다.")
        }
        return try PortalNumbersTemporaryFile(name: http.suggestedFilename ?? "Numbers 원본", extension: "numbers") { target in
            try FileManager.default.moveItem(at: download, to: target)
        }
    }

    static func create(_ item: PortalAttachmentPreviewItem) async throws -> PortalNumbersChartLink {
        var request = try request(item, suffix: "/chart", method: "POST")
        request.setValue(PortalConfig.portalOrigin, forHTTPHeaderField: "Origin")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"autoConvert":true}"#.utf8)
        let (data, response) = try await URLSession.shared.data(for: request, delegate: NoRedirect())
        let payload = try? JSONDecoder().decode(Conversion.self, from: data)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let id = sourceID(item.url), let path = payload?.path,
              let chart = chart(path: path, name: payload?.name, sourceID: id) else {
            throw failure(payload?.error ?? "NF 차트를 만들지 못했습니다.")
        }
        return chart
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "NF.Numbers", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private final class NoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
        nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}

final class PortalNumbersTemporaryFile: Identifiable {
    let url: URL
    private let directory: URL

    init(name: String, extension fileExtension: String, write: (URL) throws -> Void) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let safe = name.components(separatedBy: CharacterSet(charactersIn: "/:\0"))
            .joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        let filename = safe.isEmpty ? "첨부 파일" : safe
        url = directory.appendingPathComponent((filename as NSString).pathExtension.lowercased() == fileExtension
            ? filename : filename + "." + fileExtension)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try write(url)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}

private enum PortalNumbersExportFormat: String, CaseIterable {
    case pdf, csv, xlsx
    var title: String { rawValue.uppercased() }
}

private struct PortalNumbersChartWebView: UIViewRepresentable {
    let url: URL
    let session: PortalChartWebSession

    func makeUIView(context: Context) -> WKWebView { session.view(for: url) }

    func updateUIView(_ view: WKWebView, context: Context) {}
}

struct PortalNumbersAttachmentView: View {
    let item: PortalAttachmentPreviewItem
    let onClose: () -> Void
    @Environment(\.portalAppTheme) private var theme
    @StateObject private var session = PortalChartWebSession()
    @State private var chart: PortalNumbersChartLink?
    @State private var original: PortalNumbersTemporaryFile?
    @State private var exported: PortalNumbersTemporaryFile?
    @State private var status: String?
    @State private var error: String?
    @State private var isShowingOriginal: Bool
    @State private var operation: Task<Void, Never>?
    @State private var confirmsConversion = false

    init(item: PortalAttachmentPreviewItem, chart: PortalNumbersChartLink?, onClose: @escaping () -> Void) {
        self.item = item
        self.onClose = onClose
        _chart = State(initialValue: chart)
        _isShowingOriginal = State(initialValue: chart == nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: close) {
                    Image(systemName: isShowingOriginal && chart != nil ? "chevron.left" : "xmark")
                        .frame(width: 40, height: 42)
                }
                .accessibilityLabel(isShowingOriginal && chart != nil ? "NF 차트로 돌아가기" : "닫기")
                .disabled(operation != nil)
                Spacer(minLength: 4)
                Text(isShowingOriginal ? original?.url.lastPathComponent ?? item.title : chart?.name ?? item.title)
                    .font(.headline).lineLimit(1)
                Spacer(minLength: 4)
                Menu {
                    if let chart, !isShowingOriginal {
                        Button("Numbers 원본 파일 보기", systemImage: "doc.richtext") { showOriginal() }
                        ForEach(PortalNumbersExportFormat.allCases, id: \.self) { format in
                            Button("\(format.title) 내보내기", systemImage: "square.and.arrow.down") {
                                run("\(format.title) 파일을 만드는 중…") {
                                    let file = try await session.export(format.rawValue, from: chart.url)
                                    exported = try PortalNumbersTemporaryFile(name: file.name, extension: format.rawValue) {
                                        try file.data.write(to: $0, options: .atomic)
                                    }
                                }
                            }
                        }
                    } else if chart != nil {
                        Button("NF 차트로 돌아가기", systemImage: "chevron.left") { isShowingOriginal = false }
                    } else {
                        Button("NF 차트로 만들기", systemImage: "tablecells") {
                            confirmsConversion = true
                        }
                        if original == nil {
                            Button("Numbers 원본 다시 불러오기", systemImage: "arrow.clockwise") { showOriginal() }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 44, height: 42)
                }
                .accessibilityLabel("NF 차트 더보기")
                .disabled(operation != nil)
            }
            .background(theme.surfaceColor)
            Divider()
            ZStack(alignment: .top) {
                if let chart {
                    PortalNumbersChartWebView(url: chart.url, session: session)
                        .id(chart.url)
                        .opacity(isShowingOriginal ? 0 : 1)
                        .allowsHitTesting(!isShowingOriginal)
                        .accessibilityHidden(isShowingOriginal)
                }
                if isShowingOriginal, let original {
                    PortalNumbersQuickLook(file: original)
                }
                if let status {
                    ProgressView(status)
                        .padding(12)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                        .padding(.top, 8)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { if chart == nil { showOriginal() } }
        .onDisappear { operation?.cancel() }
        .alert("Numbers 첨부", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("확인", role: .cancel) {}
        } message: { Text(error ?? "") }
        .confirmationDialog("NF 차트로 만들기", isPresented: $confirmsConversion, titleVisibility: .visible) {
            Button("만들기") {
                run("Numbers를 NF 차트로 변환하는 중…") {
                    chart = try await PortalNumbersAttachment.create(item)
                    isShowingOriginal = false
                }
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("Numbers 원본을 보관하고 같은 Google Drive 폴더에 NF 차트를 만듭니다.")
        }
        .sheet(item: $exported) { PortalPDFActivityView(fileURL: $0.url) }
    }

    private func close() {
        if isShowingOriginal, chart != nil {
            isShowingOriginal = false
        } else if let chart {
            run("차트를 저장하는 중…") {
                guard await session.save(from: chart.url) else {
                    throw PortalNumbersAttachment.failure("차트 변경사항을 저장하지 못했습니다.")
                }
                onClose()
            }
        } else { onClose() }
    }

    private func showOriginal() {
        run("Numbers 원본을 불러오는 중…") {
            if original == nil { original = try await PortalNumbersAttachment.original(item) }
            isShowingOriginal = true
        }
    }

    private func run(_ label: String, action: @escaping @MainActor () async throws -> Void) {
        guard operation == nil else { return }
        status = label
        operation = Task { @MainActor in
            defer { operation = nil; status = nil }
            do { try await action() }
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}

private struct PortalNumbersQuickLook: UIViewControllerRepresentable {
    let file: PortalNumbersTemporaryFile

    func makeCoordinator() -> Coordinator { Coordinator(file: file) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let preview = QLPreviewController()
        preview.dataSource = context.coordinator
        preview.delegate = context.coordinator
        return preview
    }
    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}

    final class Coordinator: NSObject, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
        let file: PortalNumbersTemporaryFile
        init(file: PortalNumbersTemporaryFile) { self.file = file }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { file.url as NSURL }
        func previewController(_ controller: QLPreviewController, editingModeFor previewItem: QLPreviewItem) -> QLPreviewItemEditingMode { .disabled }
    }
}
