import AppKit
import SwiftUI
import WebKit

struct MacPortalSearchResult: Decodable, Identifiable {
    let id: String
    let title: String
    let kind: String
    var href: String?
    var parentTitle: String?
    var openInCurrentPane: Bool?
    var document: MacLocalPDFDocument?

    enum CodingKeys: String, CodingKey { case id, title, kind, href, parentTitle, openInCurrentPane }

    var label: String {
        switch kind {
        case "detail": "상세 제목"
        case "menu", "library": "메뉴"
        case "pdf": "PDF"
        default: "문서"
        }
    }

    var symbol: String {
        switch kind {
        case "detail": "textformat"
        case "menu", "library": "list.bullet"
        case "pdf": "doc.richtext"
        default: "doc.text"
        }
    }
}

struct MacPortalGlobalSearch: View {
    let webView: WKWebView?
    let repository: MacPDFLocalStorageRepository
    var includesLibrary: Bool
    @Binding var query: String
    let onOpen: (MacPortalSearchResult) async throws -> Void
    let onClose: () -> Void

    @FocusState private var focused: Bool
    @State private var webResults: [MacPortalSearchResult] = []
    @State private var pdfs: [MacLocalPDFDocument] = []
    @State private var completedQuery = ""
    @State private var selection = 0
    @State private var busy = false
    @State private var loadError = ""
    @State private var openError = ""

    private var term: String { String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)) }
    private var results: [MacPortalSearchResult] {
        guard !term.isEmpty else { return [] }
        let words = term.split(whereSeparator: \.isWhitespace)
        func matches(_ title: String) -> Bool { words.allSatisfy { title.localizedStandardContains(String($0)) } }
        let library = includesLibrary && matches("파일 리스트 PDF 문서함")
            ? [MacPortalSearchResult(id: "pdf-library", title: "파일 리스트", kind: "library")] : []
        let local = pdfs.filter { matches($0.fileName) }.prefix(30).map {
            MacPortalSearchResult(id: "pdf:" + $0.id, title: $0.fileName, kind: "pdf", document: $0)
        }
        let portal = completedQuery == term ? webResults : []
        return (portal + library + local).sorted {
            func score(_ result: MacPortalSearchResult) -> Int {
                if result.title.localizedCaseInsensitiveCompare(term) == .orderedSame { return 0 }
                return result.title.range(of: term, options: [.caseInsensitive, .anchored]) != nil ? 1 : 2
            }
            return score($0) < score($1)
        }
    }

    var body: some View {
        let items = results
        let active = min(selection, max(0, items.count - 1))
        ZStack {
            Color.black.opacity(0.36).contentShape(Rectangle()).onTapGesture { if !busy { onClose() } }
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("문서, 상세 제목, 메뉴, PDF 검색", text: $query)
                        .textFieldStyle(.plain).font(.system(size: 17)).focused($focused)
                        .accessibilityLabel("전체 검색")
                        .onSubmit { if items.indices.contains(active) { choose(items[active]) } }
                        .onKeyPress(.downArrow) { move(1, active: active, count: items.count); return .handled }
                        .onKeyPress(.upArrow) { move(-1, active: active, count: items.count); return .handled }
                    Button(action: onClose) { Image(systemName: "xmark").frame(width: 26, height: 26) }
                        .buttonStyle(.plain).accessibilityLabel("전체 검색 닫기").disabled(busy)
                }.padding(14)
                Divider()
                if !items.isEmpty {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 2) {
                                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                    Button { choose(item) } label: {
                                        HStack(spacing: 10) {
                                            Image(systemName: item.symbol).frame(width: 17)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(item.title).lineLimit(1)
                                                if let context = item.parentTitle, !context.isEmpty {
                                                    Text(context).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                                }
                                            }
                                            Spacer()
                                            Text(item.label).font(.caption).foregroundStyle(.secondary)
                                        }
                                        .padding(.horizontal, 10).frame(minHeight: 36)
                                        .background(index == active ? Color.primary.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 6))
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain).disabled(busy).id(item.id)
                                }
                            }.padding(6)
                        }
                        .frame(height: min(360, CGFloat(items.count) * 44 + 12))
                        .onChange(of: active) { _, index in if items.indices.contains(index) { proxy.scrollTo(items[index].id) } }
                    }
                }
                if !openError.isEmpty || !loadError.isEmpty || term.isEmpty || completedQuery != term || items.isEmpty {
                    Text(!openError.isEmpty ? openError : !loadError.isEmpty ? loadError : term.isEmpty ? "검색어를 입력하세요." : completedQuery != term ? "검색 중…" : "검색 결과가 없습니다.")
                        .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }
            }
            .frame(maxWidth: 640)
            .background(MacPDFPanelSurface(radius: 12)).shadow(radius: 20, y: 10)
            .padding(24)
            .accessibilityIdentifier("workspace.globalSearch")
        }
        .onAppear { pdfs = repository.documents().filter { !$0.isDeleted }; focused = true }
        .onReceive(NotificationCenter.default.publisher(for: MacPDFLocalStorageRepository.didChangeNotification)) { _ in
            pdfs = repository.documents().filter { !$0.isDeleted }
        }
        .onChange(of: query) { _, _ in selection = 0; openError = ""; loadError = "" }
        .onExitCommand { if !busy { onClose() } }
        .task(id: term) { await lookup(term) }
    }

    private func move(_ step: Int, active: Int, count: Int) {
        guard count > 0 else { return }
        selection = (active + step + count) % count
    }

    private func lookup(_ query: String) async {
        guard !query.isEmpty else { webResults = []; completedQuery = ""; return }
        do {
            try await Task.sleep(for: .milliseconds(140))
            guard let webView, let url = webView.url, url.scheme == "https", MacPortalConfig.isPortalURL(url) else {
                throw CocoaError(.fileReadNoPermission)
            }
            let value = try await webView.callAsyncJavaScript(
                "if (typeof window.__nfGlobalSearch !== 'function') throw new Error('Search unavailable'); return await window.__nfGlobalSearch(query);",
                arguments: ["query": query], in: nil, contentWorld: .page
            )
            try Task.checkCancellation()
            guard let records = value as? [[String: Any]] else { throw CocoaError(.coderInvalidValue) }
            let data = try JSONSerialization.data(withJSONObject: records)
            webResults = try JSONDecoder().decode([MacPortalSearchResult].self, from: data)
            completedQuery = query
        } catch {
            guard !Task.isCancelled else { return }
            webResults = []; completedQuery = query
            loadError = "포털 검색을 불러오지 못했습니다."
        }
    }

    private func choose(_ item: MacPortalSearchResult) {
        guard !busy else { return }
        busy = true; openError = ""
        Task {
            defer { busy = false }
            do { try await onOpen(item); onClose() }
            catch { openError = error.localizedDescription }
        }
    }
}

/// A split workspace has two WebKit responders. The owning window handles the
/// shortcut before either pane or the PDF editor can consume it.
struct MacPortalSearchShortcut: NSViewRepresentable {
    let open: () -> Void
    let dismiss: () -> Bool

    func makeNSView(context: Context) -> MonitorView { MonitorView() }
    func updateNSView(_ view: MonitorView, context: Context) { view.open = open; view.dismiss = dismiss }
    static func dismantleNSView(_ view: MonitorView, coordinator: ()) { view.stop() }

    final class MonitorView: NSView {
        var open: (() -> Void)?
        var dismiss: (() -> Bool)?
        private var monitor: Any?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                if event.keyCode == 53, self.dismiss?() == true { return nil }
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                guard flags.contains(.command) || flags.contains(.control),
                      !flags.contains(.shift), !flags.contains(.option),
                      event.keyCode == 40 || event.charactersIgnoringModifiers?.lowercased() == "k" else { return event }
                self.open?()
                return nil
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        }
    }
}
