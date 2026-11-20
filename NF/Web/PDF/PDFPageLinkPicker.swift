import SwiftUI
import WebKit

enum PDFPageLink {
    static func matchesOrigin(_ url: URL, _ origin: URL) -> Bool {
        url.scheme == origin.scheme && url.host == origin.host && url.port == origin.port &&
            url.user == nil && url.password == nil
    }

    static func href(for url: URL, origin: URL) -> String? {
        guard matchesOrigin(url, origin),
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: true),
              ["/custom/", "/linked-document/"].contains(where: { prefix in
                  parts.path.range(of: "^" + prefix + "[a-zA-Z0-9_-]{1,120}$", options: .regularExpression) != nil
              }) || parts.path == "/projects" else { return nil }
        var path = parts.percentEncodedPath
        if let query = parts.percentEncodedQuery { path += "?" + query }
        if let fragment = parts.percentEncodedFragment { path += "#" + fragment }
        return path
    }

    static func url(for href: String, origin: URL) -> URL? {
        guard href.hasPrefix("/"), let url = URL(string: href, relativeTo: origin)?.absoluteURL,
              self.href(for: url, origin: origin) != nil else { return nil }
        return url
    }

    static func tabID(_ url: URL) -> String? {
        url.path.hasPrefix("/custom/") && url.query == nil && url.fragment == nil ? url.lastPathComponent : nil
    }

    static func attachmentBinding(in embedded: URL) -> PDFNoteAttachmentBinding? {
        let items = URLComponents(url: embedded, resolvingAgainstBaseURL: false)?.queryItems
        guard let note = items?.first(where: { $0.name == "note" })?.value,
              note.range(of: "^[a-zA-Z0-9_-]{1,120}$", options: .regularExpression) != nil,
              let source = items?.first(where: { $0.name == "source" })?.value,
              source.range(of: "^(?:local:|/api/artifacts/files/)[a-zA-Z0-9_-]{1,120}$", options: .regularExpression) != nil else { return nil }
        return PDFNoteAttachmentBinding(note: note, source: source)
    }

    static let registerAttachmentScript = """
    if (location.pathname === '/custom/' + note && document.getElementById('portal-main')) {
      try { localStorage.setItem('nf-pdf-note-attachment:' + note, source); } catch {}
    }
    """

    static let documentOnlyScript = """
    (() => {
      if (!document.getElementById('portal-main')) return false;
      window.nfFlushPdfFreeNote ??= () => window.__nfDisplayPrepare?.();
      if (!document.getElementById('nf-pdf-document-style')) {
        const style = document.createElement('style');
        style.id = 'nf-pdf-document-style';
        style.textContent = `
          #portal-common-tabs, [data-resolution-workspace] > aside, .portal-titlebar,
          .mobile-navigation-overlay, [data-pdf-note-source-toggle] { display: none !important; }
          [data-resolution-workspace] { display: block !important; }
          #portal-main { max-width: none !important; padding: 16px !important; }
          html[data-pdf-volume-popup="true"] #portal-main { padding-inline: clamp(34px, 12vw, 60px) clamp(16px, 7vw, 40px) !important; }
        `;
        document.head.appendChild(style);
      }
      return true;
    })()
    """
}

struct PDFPageResult: Decodable, Identifiable {
    let id: String
    let href: String
    let title: String
    let parentTitle: String?
}

struct PDFPageLinkPicker: View {
    private enum Scope: String, CaseIterable {
        case all, page, document, calendar

        var title: String {
            switch self {
            case .all: "전체"
            case .page: "상세페이지"
            case .document: "문서"
            case .calendar: "달력"
            }
        }
    }

    let origin: URL
    let onSelect: (URL) -> Void
    let onClose: () -> Void
    @FocusState private var focused: Bool
    @State private var query = ""
    @State private var scope: Scope = .all
    @State private var results: [PDFPageResult] = []
    @State private var selection = 0
    @State private var searching = true
    @State private var creating = false
    @State private var attempt = 0
    @State private var searchError: String?
    @State private var createError: String?
    @State private var createTask: Task<Void, Never>?
    @State private var unconfirmedTitle: String?

    private var canCreate: Bool { !term.isEmpty && term.utf16.count <= 40 && unconfirmedTitle != term }

    private var term: String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((trimmed.hasPrefix("#") ? trimmed.dropFirst() : trimmed[...])
            .trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "number").font(.callout.weight(.semibold))
                    .frame(width: 28, height: 28)
                    .background(.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 4) {
                    Text("페이지 연결").font(.callout.weight(.semibold))
                    TextField("페이지·문서 검색", text: $query)
                        .textFieldStyle(.plain).focused($focused)
                        .accessibilityIdentifier("pdf.pageLink.query")
                        .onSubmit { if !searching { chooseSelection() } }
                        .onKeyPress(.downArrow) { moveSelection(1); return .handled }
                        .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Menu(scope.title) {
                    ForEach(Scope.allCases, id: \.self) { option in
                        Button { scope = option; focused = true } label: {
                            if scope == option { Label(option.title, systemImage: "checkmark") }
                            else { Text(option.title) }
                        }
                    }
                }.fixedSize().accessibilityLabel("페이지 연결 검색 타입")
                Button(action: onClose) { Image(systemName: "xmark").frame(width: 22, height: 24) }
                    .buttonStyle(.plain).accessibilityLabel("페이지 검색 닫기")
            }.padding(12)
            Divider()
            Group {
                if searching {
                    ProgressView("검색 중…").controlSize(.small).padding(16)
                } else if let searchError {
                    VStack(spacing: 8) {
                        Text(searchError).font(.callout)
                        Button("다시 검색") { attempt += 1 }
                    }.padding(16)
                } else if results.isEmpty {
                    Text("일치하는 항목이 없습니다.").font(.callout).foregroundStyle(.secondary).padding(16)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 2) {
                                ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                                    Button { choose(result) } label: {
                                        row(result.title, detail: result.parentTitle,
                                            icon: result.id.hasPrefix("calendar:") ? "calendar" : "doc.text",
                                            selected: index == selection)
                                    }.buttonStyle(.plain).id(index)
                                }
                            }.padding(6)
                        }
                        .onChange(of: selection) { _, value in if results.indices.contains(value) { proxy.scrollTo(value) } }
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            Button(action: create) {
                row(creating ? "문서 생성 중…" : "새 문서 생성", detail: term.isEmpty ? nil : term,
                    icon: "plus", selected: selection == results.count && !searching && !term.isEmpty)
            }
            .buttonStyle(.plain).disabled(!canCreate)
            .padding(6)
            if let createError {
                Text(createError).font(.caption).foregroundStyle(.red).padding(.horizontal, 12).padding(.bottom, 6)
            } else if term.utf16.count > 40 {
                Text("새 문서 제목은 40자 이내로 입력해 주세요.").font(.caption).foregroundStyle(.secondary)
                    .padding(.bottom, 6)
            }
            Divider()
            #if os(macOS)
            Text("↑↓ 선택 · Enter 연결 · Esc 닫기")
                .font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(8)
            #endif
        }
        .disabled(creating)
        .onAppear { focused = true }
        .onDisappear { createTask?.cancel() }
        #if os(macOS)
        .onExitCommand { if !creating { onClose() } }
        #endif
        .task(id: "\(scope.rawValue):\(attempt):\(term)") { await loadResults() }
    }

    private func row(_ title: String, detail: String?, icon: String, selected: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium)).lineLimit(1)
                if let detail, !detail.isEmpty { Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).frame(minHeight: 36)
        .background(selected ? Color.primary.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }

    private func moveSelection(_ step: Int) {
        let count = results.count + (canCreate ? 1 : 0)
        if count > 0 { selection = (selection + step + count) % count }
    }

    private func chooseSelection() {
        if results.indices.contains(selection) { choose(results[selection]) }
        else if canCreate { create() }
    }

    private func choose(_ result: PDFPageResult) {
        if let url = PDFPageLink.url(for: result.href, origin: origin) { onSelect(url) }
    }

    private func loadResults() async {
        let query = term, scope = scope.rawValue
        results = []; selection = 0; searching = true; searchError = nil; createError = nil
        do {
            try await Task.sleep(for: .milliseconds(120))
            let results = try await PDFPageSearch.search(query, scope: scope, origin: origin)
            try Task.checkCancellation()
            self.results = results
        } catch {
            guard !Task.isCancelled else { return }
            searchError = error.localizedDescription
        }
        if !Task.isCancelled { searching = false }
    }

    private func create() {
        let title = term
        guard canCreate, !creating else { return }
        creating = true; createError = nil
        createTask = Task {
            defer { creating = false; focused = true }
            do {
                let creation = PDFPageCreation()
                let page = try await creation.create(title, origin: origin)
                try Task.checkCancellation()
                onSelect(page)
            } catch where !Task.isCancelled {
                if case PDFPageLinkError.createUnconfirmed = error { unconfirmedTitle = title }
                createError = error.localizedDescription
            } catch {}
        }
    }
}

@MainActor
enum PDFPageSearch {
    private struct Response: Decodable { let data: [PDFPageResult] }

    private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
    }()

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

    static func search(_ query: String, scope: String, origin: URL) async throws -> [PDFPageResult] {
        let endpoint = origin.appendingPathComponent("api/project-data")
        guard let cookie = await cookieHeader(for: endpoint) else { throw PDFPageLinkError.login }
        var request = URLRequest(url: endpoint, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue(origin.absoluteString, forHTTPHeaderField: "Origin")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["kind": "pageMention", "scope": scope, "query": query])
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw PDFPageLinkError.search }
        if let status = (response as? HTTPURLResponse)?.statusCode,
           [302, 303, 307, 308, 401, 403].contains(status) { throw PDFPageLinkError.login }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let result = try? JSONDecoder().decode(Response.self, from: data) else { throw PDFPageLinkError.search }
        return result.data.filter { PDFPageLink.url(for: $0.href, origin: origin) != nil }
    }
}

private enum PDFPageLinkError: LocalizedError {
    case login, search, create, createUnconfirmed

    var errorDescription: String? {
        switch self {
        case .login: "포털 로그인 또는 문서 접근 권한을 확인해 주세요."
        case .search: "페이지 검색 결과를 불러오지 못했습니다."
        case .create: "새 문서 생성 화면을 열 수 없습니다. 내 작업공간과 생성 권한을 확인해 주세요."
        case .createUnconfirmed: "생성 결과를 확인하지 못했습니다. 제목을 검색해 문서가 생성되었는지 확인해 주세요."
        }
    }
}

/// Submit the existing portal's Free Note form with its live server action and session.
@MainActor
final class PDFPageCreation: NSObject, WKNavigationDelegate {
    private let webView = WKWebView(frame: .zero)
    private var responseError: PDFPageLinkError?
    private var formURL: URL?

    func create(_ title: String, origin: URL) async throws -> URL {
        let formURL = origin.appendingPathComponent("custom-tabs")
        self.formURL = formURL
        webView.navigationDelegate = self
        webView.load(URLRequest(url: formURL))
        defer { webView.stopLoading() }
        let deadline = ContinuousClock.now + .seconds(12)
        while webView.url != formURL || webView.isLoading {
            if let responseError { throw responseError }
            if webView.url?.path == "/login" { throw PDFPageLinkError.login }
            guard ContinuousClock.now < deadline else { throw PDFPageLinkError.create }
            try await Task.sleep(for: .milliseconds(100))
        }
        let submitted = try? await webView.callAsyncJavaScript("""
            const form = document.querySelector('form.custom-tab-create-form');
            const name = form?.querySelector('input[name="title"]');
            const type = form?.querySelector('input[name="layout"][value="FREE_NOTE"]');
            if (!name || !type || form.method.toLowerCase() !== 'post' ||
                new URL(form.getAttribute('action') || location.href, location.href).href !== location.href ||
                ![...form.elements].some(field => field.name?.startsWith('$ACTION_'))) return false;
            name.value = title;
            type.checked = true;
            setTimeout(() => HTMLFormElement.prototype.submit.call(form), 0);
            return true;
            """, arguments: ["title": title], in: nil, contentWorld: .page)
        guard submitted as? Bool == true else { throw PDFPageLinkError.create }
        let completion = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < completion {
            if let url = webView.url, PDFPageLink.matchesOrigin(url, origin),
               PDFPageLink.href(for: url, origin: origin) != nil,
               PDFPageLink.tabID(url) != nil, !webView.isLoading { return url }
            if responseError != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw PDFPageLinkError.createUnconfirmed
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url, let formURL,
              PDFPageLink.matchesOrigin(url, formURL) else { decisionHandler(.cancel); return }
        if url.path == "/login" { responseError = .login }
        let allowed = url == formURL || PDFPageLink.href(for: url, origin: formURL) != nil && PDFPageLink.tabID(url) != nil
        decisionHandler(allowed ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if response.isForMainFrame, let status = (response.response as? HTTPURLResponse)?.statusCode, status >= 400 {
            responseError = status == 401 || status == 403 ? .login : .create
            decisionHandler(.cancel)
        } else { decisionHandler(.allow) }
    }
}
