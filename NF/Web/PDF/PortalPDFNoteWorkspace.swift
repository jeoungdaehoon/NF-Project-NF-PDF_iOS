import Combine
import PDFKit
import SwiftUI
import WebKit

@MainActor
final class PDFNoteWorkspaceState: ObservableObject {
    enum Mode { case popup, slide, split, note }
    struct Anchor: Identifiable {
        let id: String
        let note: String
        let page: PDFPage
        let bounds: CGRect
    }
    struct Target {
        let page: PDFPage
        let bounds: CGRect
        var objectID: String? = nil
    }
    struct Session: Identifiable {
        let id: String
        let note: String
        var mode: Mode = .popup
        var collapsed = false
    }
    static let path = "/pdf-free-note"
    let origin: URL
    var sourceURL: URL?
    var localSourceID: String?
    weak var canvas: PDFView?
    var selectedArea: (() -> Target?)?
    var changeDocument: ((PDFPage, @escaping () -> Void) -> Void)?
    @Published var sessions: [Session] = []
    @Published var selectingArea = false
    @Published var destination: URL?
    @Published var error: String?
    private var pendingArea: Target?
    private weak var activeDocument: PDFDocument?
    private var browsers: [String: WKWebView] = [:]
    private lazy var linkDelegate = PDFNoteLinkDelegate(workspace: self)

    init(origin: URL) { self.origin = origin }

    func activate(_ document: PDFDocument, source: URL?, localID: String?, note: String?) {
        if let activeDocument, activeDocument !== document {
            sessions.removeAll()
            browsers.removeAll()
            cancelPicker()
            selectingArea = false
        }
        activeDocument = document
        sourceURL = source
        localSourceID = localID
        reopen(note)
    }

    func attach(_ view: PDFView) {
        canvas = view
        view.delegate = linkDelegate
    }

    func openLink(_ url: URL, in view: PDFView) -> Bool {
        guard url.scheme == origin.scheme, url.host == origin.host, url.port == origin.port, url.path == Self.path,
              let note = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "note" })?.value else { return false }
        let nearby = view.visiblePages.flatMap(anchors(on:))
        let anchor = nearby.first { $0.id == url.fragment } ?? nearby.first { $0.note == note }
        if let anchor { open(id: anchor.id, note: anchor.note) }
        else { reopen(note) }
        return true
    }

    nonisolated static func ownedLink(_ annotation: PDFAnnotation) -> URL? {
        guard let url = annotation.url ?? (annotation.action as? PDFActionURL)?.url,
              url.scheme == "https", url.path == "/pdf-free-note",
              let fragment = url.fragment, UUID(uuidString: fragment) != nil else { return nil }
        return url
    }

    static func attachmentInvocation(_ url: URL) -> (url: URL, note: String?) {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let fragment = parts.fragment, fragment.hasPrefix("nf-pdf-note=") else { return (url, nil) }
        let note = String(fragment.dropFirst("nf-pdf-note=".count))
        parts.fragment = nil
        return (parts.url ?? url, note.range(of: "^[a-zA-Z0-9_-]{1,120}$", options: .regularExpression) == nil ? nil : note)
    }

    static func libraryInvocation(_ url: URL) -> (id: String, note: String)? {
        guard url.scheme == "nf-pdf-note", url.host == "library" else { return nil }
        let paths = url.pathComponents.dropFirst()
        guard paths.count == 2, let id = paths.first, let note = paths.last,
              [id, note].allSatisfy({ $0.range(of: "^[a-zA-Z0-9_-]{1,120}$", options: .regularExpression) != nil }) else { return nil }
        return (id, note)
    }

    func noteURL(_ note: String? = nil, embedded: Bool = false) -> URL? {
        guard let url = URL(string: Self.path, relativeTo: origin)?.absoluteURL,
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        if let note { parts.queryItems = [.init(name: "note", value: note)] }
        if embedded { parts.queryItems?.append(.init(name: "embed", value: "1")) }
        if embedded, let sourceURL, sourceURL.host == origin.host, sourceURL.scheme == origin.scheme,
           sourceURL.path.range(of: "^/api/artifacts/files/[a-zA-Z0-9_-]{1,120}$", options: .regularExpression) != nil {
            parts.queryItems?.append(.init(name: "source", value: sourceURL.path))
        } else if embedded, let localSourceID,
                  localSourceID.range(of: "^[a-zA-Z0-9_-]{1,120}$", options: .regularExpression) != nil {
            parts.queryItems?.append(.init(name: "source", value: "local:" + localSourceID))
        }
        return parts.url
    }

    func beginLink() {
        if let area = selectedArea?() { chooseNote(area) }
        else { selectingArea.toggle() }
    }

    func capture(_ frame: CGRect) {
        selectingArea = false
        guard let canvas else { return }
        let rect = !canvas.isFlippedForNoteWorkspace
            ? CGRect(x: frame.minX, y: canvas.bounds.height - frame.maxY, width: frame.width, height: frame.height)
            : frame
        guard let page = canvas.page(for: CGPoint(x: rect.midX, y: rect.midY), nearest: false) else { return }
        let bounds = canvas.convert(rect, to: page).standardized.intersection(page.bounds(for: .cropBox))
        guard !bounds.isNull, !bounds.isEmpty else { return }
        chooseNote(Target(page: page, bounds: bounds))
    }

    private func chooseNote(_ area: Target) {
        pendingArea = area
        destination = noteURL()
    }

    func select(_ note: String) {
        guard note.range(of: "^[a-zA-Z0-9_-]{1,120}$", options: .regularExpression) != nil,
              let area = pendingArea, area.page.document === canvas?.document,
              let url = noteURL(note),
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let id = UUID().uuidString
        parts.fragment = id
        let annotation = PDFAnnotation(bounds: area.bounds, forType: .link, withProperties: nil)
        annotation.url = parts.url
        if let objectID = area.objectID { annotation.contents = "nf-note-object:" + objectID }
        let border = PDFBorder()
        border.lineWidth = 0
        annotation.border = border
        changeDocument?(area.page) { area.page.addAnnotation(annotation) }
        destination = nil
        pendingArea = nil
        open(id: id, note: note)
    }

    func cancelPicker() {
        destination = nil
        pendingArea = nil
    }

    @discardableResult
    static func refreshObjectLinks(on page: PDFPage, bounds: (UUID) -> CGRect?) -> Bool {
        let prefix = "nf-note-object:"
        var changed = false
        for annotation in page.annotations {
            guard ownedLink(annotation) != nil,
                  let contents = annotation.contents, contents.hasPrefix(prefix),
                  let id = UUID(uuidString: String(contents.dropFirst(prefix.count))),
                  let frame = bounds(id), frame != annotation.bounds else { continue }
            annotation.bounds = frame
            changed = true
        }
        return changed
    }

    static func rekeyLinks(on page: PDFPage, remap: [UUID: UUID] = [:]) {
        for annotation in page.annotations {
            guard let url = ownedLink(annotation),
                  var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { continue }
            let id = UUID().uuidString
            parts.fragment = id
            annotation.url = parts.url
            if let contents = annotation.contents, contents.hasPrefix("nf-note-object:"),
               let previous = UUID(uuidString: String(contents.dropFirst("nf-note-object:".count))),
               let mapped = remap[previous] {
                annotation.contents = "nf-note-object:" + mapped.uuidString
            }
        }
    }

    func anchors(on page: PDFPage) -> [Anchor] {
        page.annotations.enumerated().compactMap { index, annotation in
            guard let url = annotation.url ?? (annotation.action as? PDFActionURL)?.url,
                  url.scheme == origin.scheme, url.host == origin.host, url.path == Self.path,
                  let note = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "note" })?.value else { return nil }
            let id = Self.ownedLink(annotation)?.fragment ?? "\(ObjectIdentifier(page))-\(index)"
            return Anchor(id: id, note: note, page: page, bounds: annotation.bounds)
        }
    }

    func visibleAnchors() -> [(Anchor, CGRect)] {
        guard let canvas else { return [] }
        return canvas.visiblePages.flatMap { page in
            anchors(on: page).map { anchor in
                let frame = canvas.convert(anchor.bounds, from: page).standardized
                let y = canvas.isFlippedForNoteWorkspace ? frame.minY : canvas.bounds.height - frame.maxY
                return (anchor, CGRect(x: frame.minX, y: y, width: frame.width, height: frame.height))
            }
        }
    }

    func open(id: String, note: String) {
        if let index = sessions.firstIndex(where: { $0.id == id }) {
            sessions[index].collapsed = false
            return
        }
        if let existing = sessions.first(where: { $0.note == note }) {
            sessions.removeAll { $0.id == existing.id }
            browsers[id] = browsers.removeValue(forKey: existing.id)
        }
        sessions.append(Session(id: id, note: note))
    }

    func collapse(_ id: String) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].mode = .popup
        sessions[index].collapsed = true
    }

    func mode(_ mode: Mode, for id: String) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        for other in sessions.indices where other != index && sessions[other].mode != .popup {
            sessions[other].mode = .popup
        }
        sessions[index].mode = mode
    }

    func autoSlide(_ id: String?) {
        guard let id, sessions.last?.id == id, sessions.last?.collapsed == false,
              sessions.allSatisfy({ $0.mode == .popup }) else { return }
        mode(.slide, for: id)
    }

    func reveal(_ id: String) {
        guard let document = canvas?.document else { return }
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index),
                  let anchor = anchors(on: page).first(where: { $0.id == id }) else { continue }
            canvas?.go(to: anchor.bounds, on: page)
            return
        }
    }

    func reopen(_ note: String?) {
        guard let note else { return }
        guard let document = canvas?.document else {
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                if self?.canvas?.document != nil { self?.reopen(note) }
            }
            return
        }
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index), let anchor = anchors(on: page).first(where: { $0.note == note }) else { continue }
            open(id: anchor.id, note: note)
            canvas?.go(to: anchor.bounds, on: page)
            return
        }
        error = "이 PDF에서 연결된 자유노트 위치를 찾을 수 없습니다."
    }

    func flush() async -> Bool {
        do {
            for browser in browsers.values {
                _ = try await browser.callAsyncJavaScript(
                    "if (window.nfFlushPdfFreeNote) await window.nfFlushPdfFreeNote();",
                    arguments: [:], in: nil, contentWorld: .page
                )
            }
            return true
        } catch {
            self.error = "자유노트를 저장하지 못했습니다. 내용을 확인한 뒤 다시 시도해 주세요."
            return false
        }
    }

    func close(_ id: String, animated: Bool) async {
        do {
            if let browser = browsers[id] {
                _ = try await browser.callAsyncJavaScript(
                    "if (window.nfFlushPdfFreeNote) await window.nfFlushPdfFreeNote();",
                    arguments: [:], in: nil, contentWorld: .page
                )
            }
            withAnimation(animated ? .spring(response: 0.42, dampingFraction: 0.84) : nil) {
                sessions.removeAll { $0.id == id }
            }
            browsers.removeValue(forKey: id)
        } catch {
            self.error = "자유노트를 저장하지 못했습니다. 내용을 확인한 뒤 다시 시도해 주세요."
        }
    }

    func browser(_ session: Session) -> WKWebView {
        if let browser = browsers[session.id] { return browser }
        let browser = WKWebView(frame: .zero)
        if let url = noteURL(session.note, embedded: true) { browser.load(URLRequest(url: url)) }
        browsers[session.id] = browser
        return browser
    }
}

@MainActor
private final class PDFNoteLinkDelegate: NSObject, @preconcurrency PDFViewDelegate {
    weak var workspace: PDFNoteWorkspaceState?
    init(workspace: PDFNoteWorkspaceState) { self.workspace = workspace }

    func pdfViewWillClick(onLink sender: PDFView, with url: URL) {
        if workspace?.openLink(url, in: sender) == true { return }
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }
}

private extension PDFView {
    var isFlippedForNoteWorkspace: Bool {
        #if os(macOS)
        return isFlipped
        #else
        return true
        #endif
    }
}

struct PDFNoteWorkspace<Editor: View>: View {
    @ObservedObject var state: PDFNoteWorkspaceState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var fraction: CGFloat = 0.52
    @State private var splitDrag: CGFloat?
    @State private var area: CGRect?
    let enabled: Bool
    @ViewBuilder var editor: Editor

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let full = state.sessions.last { $0.mode != .popup }
            let split = full?.mode == .split
            let noteOnly = full?.mode == .note
            let pdfWidth = split ? size.width * fraction : size.width
            ZStack(alignment: .topLeading) {
                editor.frame(width: pdfWidth, height: size.height)
                    .opacity(noteOnly ? 0 : 1)
                    .allowsHitTesting(!noteOnly)
                if enabled {
                    TimelineView(.periodic(from: .now, by: 0.12)) { _ in
                        layer(size: size, pdfWidth: pdfWidth, full: full)
                    }
                    if !noteOnly {
                        Button { state.beginLink() } label: {
                            Label("자유노트 연결", systemImage: "link.badge.plus")
                        }
                        .buttonStyle(.borderedProminent)
                        .padding(12)
                        .padding(.bottom, 44)
                        .frame(width: pdfWidth, height: size.height, alignment: .bottomTrailing)
                    }
                }
                if split {
                    let line = size.width * (splitDrag ?? fraction)
                    Rectangle().fill(.secondary).frame(width: 1, height: size.height)
                        .position(x: line, y: size.height / 2).allowsHitTesting(false)
                    Color.clear.frame(width: 20, height: size.height)
                        .contentShape(Rectangle())
                        .position(x: line, y: size.height / 2)
                        .gesture(DragGesture(coordinateSpace: .named("PDFNoteWorkspace"))
                            .onChanged { splitDrag = splitFraction($0.location.x, width: size.width) }
                            .onEnded { value in fraction = splitFraction(value.location.x, width: size.width); splitDrag = nil })
                        .accessibilityLabel("좌우 분할 너비 조절")
                        .accessibilityAdjustableAction { direction in
                            let next = fraction + (direction == .increment ? 0.05 : -0.05)
                            fraction = splitFraction(next * size.width, width: size.width)
                        }
                }
                if state.selectingArea { areaSelector(size: CGSize(width: pdfWidth, height: size.height)) }
                if let destination = state.destination {
                    let width = min(380, max(1, size.width - 24))
                    let height = min(440, max(1, size.height - 24))
                    PDFNoteBrowser(origin: state.origin, url: destination, browser: nil) { command, argument in
                        if command == "select", let argument { state.select(argument) }
                        if command == "close" { state.cancelPicker() }
                    }
                    .frame(width: width, height: height)
                    .background(.background)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(.secondary.opacity(0.35)) }
                    .shadow(radius: 18)
                    .position(x: size.width / 2, y: size.height / 2)
                }
            }
            .coordinateSpace(name: "PDFNoteWorkspace")
            .clipped()
        }
        .alert("자유노트", isPresented: Binding(get: { state.error != nil }, set: { if !$0 { state.error = nil } })) {
            Button("확인") { state.error = nil }
        } message: { Text(state.error ?? "") }
    }

    private func splitFraction(_ x: CGFloat, width: CGFloat) -> CGFloat {
        let minimum = min(0.4, 160 / max(width, 1))
        return min(1 - minimum, max(minimum, x / max(width, 1)))
    }

    private func areaSelector(size: CGSize) -> some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.12)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    area = CGRect(x: min(value.startLocation.x, value.location.x), y: min(value.startLocation.y, value.location.y),
                                  width: abs(value.translation.width), height: abs(value.translation.height))
                }.onEnded { value in
                    let region = area ?? .zero
                    area = nil
                    state.capture(region.width >= 8 && region.height >= 8 ? region
                        : CGRect(x: value.location.x - 21, y: value.location.y - 14, width: 42, height: 28))
                })
            if let area { Rectangle().stroke(.tint, style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
                .frame(width: area.width, height: area.height).position(x: area.midX, y: area.midY).allowsHitTesting(false) }
            HStack {
                Text("PDF에서 연결할 영역을 드래그하세요")
                Button("취소") { area = nil; state.selectingArea = false }
            }
            .padding(10).background(.regularMaterial, in: Capsule()).padding(10)
        }
        .frame(width: size.width, height: size.height)
    }

    private func boxes(size: CGSize, anchors: [String: CGRect], full: PDFNoteWorkspaceState.Session?, pdfWidth: CGFloat) -> [String: CGRect] {
        if let full {
            let width = min(420, size.width * 0.92)
            let box = switch full.mode {
            case .note: CGRect(origin: .zero, size: size)
            case .split: CGRect(x: pdfWidth + 1, y: 0, width: max(1, size.width - pdfWidth - 1), height: size.height)
            default: CGRect(x: size.width - width, y: 0, width: width, height: size.height)
            }
            return [full.id: box]
        }
        let width = min(350, max(1, size.width - 20))
        let height = min(330, max(1, size.height * 0.72))
        let workspace = CGRect(origin: .zero, size: size).insetBy(dx: 8, dy: 8)
        var result: [String: CGRect] = [:]
        for session in state.sessions where !session.collapsed {
            guard let anchor = anchors[session.id], workspace.intersects(anchor) else { continue }
            let right = CGRect(x: anchor.maxX + 14, y: anchor.midY - height / 2, width: width, height: height)
            let left = CGRect(x: anchor.minX - width - 14, y: right.minY, width: width, height: height)
            let below = CGRect(x: anchor.midX - width / 2, y: anchor.maxY + 14, width: width, height: height)
            let above = CGRect(x: below.minX, y: anchor.minY - height - 14, width: width, height: height)
            let candidates = [right, left, below, above].map { $0.clamped(to: workspace) }
            if let frame = candidates.first(where: { candidate in
                !candidate.intersects(anchor) && !result.values.contains(where: { $0.insetBy(dx: -6, dy: -6).intersects(candidate) })
            }) { result[session.id] = frame }
        }
        return result
    }

    private func layer(size: CGSize, pdfWidth: CGFloat, full: PDFNoteWorkspaceState.Session?) -> some View {
        let anchors = state.visibleAnchors()
        let positions = Dictionary(anchors.map { ($0.0.id, $0.1) }, uniquingKeysWith: { first, _ in first })
        let frames = boxes(size: size, anchors: positions, full: full, pdfWidth: pdfWidth)
        let newest = state.sessions.last.flatMap { $0.collapsed ? nil : $0.id }
        let fallback = newest.flatMap { full == nil && positions[$0] != nil && frames[$0] == nil ? $0 : nil }
        return ZStack(alignment: .topLeading) {
            if full == nil {
                ForEach(anchors, id: \.0.id) { anchor, frame in
                    if CGRect(x: 0, y: 0, width: pdfWidth, height: size.height).intersects(frame) {
                        Button { state.open(id: anchor.id, note: anchor.note) } label: {
                            Image(systemName: "link").font(.system(size: 12, weight: .semibold))
                                .frame(width: 25, height: 25)
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityLabel("연결된 자유노트 열기")
                        .position(x: min(pdfWidth - 16, max(16, frame.maxX)),
                                  y: min(size.height - 16, max(16, frame.midY)))
                    }
                }
                ForEach(state.sessions) { session in
                    if let anchor = positions[session.id], let frame = frames[session.id] {
                        Path { path in
                            let start = CGPoint(x: anchor.midX, y: anchor.midY)
                            let end = CGPoint(x: min(frame.maxX, max(frame.minX, start.x)), y: min(frame.maxY, max(frame.minY, start.y)))
                            path.move(to: start)
                            path.addLine(to: CGPoint(x: end.x, y: start.y))
                            path.addLine(to: end)
                        }.stroke(.tint, lineWidth: 1.5).allowsHitTesting(false)
                    }
                }
            }
            ForEach(state.sessions) { session in
                let frame = frames[session.id] ?? CGRect(x: -1, y: -1, width: 1, height: 1)
                PDFNoteCard(state: state, session: session)
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
                    .opacity(frames[session.id] == nil ? 0 : 1)
                    .allowsHitTesting(frames[session.id] != nil)
                    .transition(reduceMotion ? .identity : .move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .task(id: fallback) {
            withAnimation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.84)) {
                state.autoSlide(fallback)
            }
        }
    }
}

private extension CGRect {
    func clamped(to viewport: CGRect) -> CGRect {
        CGRect(x: min(max(minX, viewport.minX), max(viewport.minX, viewport.maxX - width)),
               y: min(max(minY, viewport.minY), max(viewport.minY, viewport.maxY - height)),
               width: width, height: height)
    }
}

private struct PDFNoteCard: View {
    @ObservedObject var state: PDFNoteWorkspaceState
    let session: PDFNoteWorkspaceState.Session
    @State private var actions = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("자유노트", systemImage: "note.text").font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
                Button { actions.toggle() } label: { Image(systemName: "ellipsis") }
                    .accessibilityLabel("자유노트 표시 방식")
                Button { Task { await state.close(session.id, animated: !reduceMotion) } } label: { Image(systemName: "xmark") }
                    .accessibilityLabel("자유노트 닫기")
            }
            .padding(9)
            .contentShape(Rectangle())
            .onLongPressGesture { actions.toggle() }
            if actions {
                ScrollView(.horizontal) {
                    HStack(spacing: 12) {
                        Button("박스") { change(.popup) }
                        Button("오른쪽 슬라이드") { change(.slide) }
                        Button("전체화면") { change(.split) }
                        Button("접기") { actions = false; state.collapse(session.id) }
                        Button(session.mode == .note ? "PDFView 켜기" : "PDFView 끄기") {
                            if session.mode == .note { state.reveal(session.id); change(.popup) }
                            else { change(.note) }
                        }
                    }.padding(8)
                }.font(.caption)
            }
            Divider()
            PDFNoteBrowser(origin: state.origin, url: nil, browser: state.browser(session)) { command, _ in
                if command == "split" { change(.split) }
                if command == "close" { Task { await state.close(session.id, animated: !reduceMotion) } }
            }
        }
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: session.mode == .popup ? 14 : 0))
        .overlay { RoundedRectangle(cornerRadius: session.mode == .popup ? 14 : 0).strokeBorder(.secondary.opacity(0.35)) }
        .shadow(radius: session.mode == .popup ? 12 : 0)
    }

    private func change(_ mode: PDFNoteWorkspaceState.Mode) {
        withAnimation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.84)) {
            actions = false
            state.mode(mode, for: session.id)
        }
    }
}

private struct PDFNoteBrowser {
    let origin: URL
    let url: URL?
    let browser: WKWebView?
    let action: (String, String?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func prepare(_ coordinator: Coordinator) -> WKWebView {
        let view = browser ?? WKWebView(frame: .zero)
        view.navigationDelegate = coordinator
        if let url { view.load(URLRequest(url: url)) }
        return view
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: PDFNoteBrowser
        init(_ parent: PDFNoteBrowser) { self.parent = parent }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { decisionHandler(.cancel); return }
            if url.scheme == "nf-pdf-note", let command = url.host {
                decisionHandler(.cancel)
                if action.sourceFrame.isMainFrame {
                    let args = url.pathComponents.dropFirst()
                    parent.action(command, args.first)
                }
                return
            }
            decisionHandler(url.scheme == parent.origin.scheme && url.host == parent.origin.host
                && url.port == parent.origin.port ? .allow : .cancel)
        }
    }
}

#if os(macOS)
extension PDFNoteBrowser: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { prepare(context.coordinator) }
    func updateNSView(_ view: WKWebView, context: Context) { context.coordinator.parent = self }
}
#else
extension PDFNoteBrowser: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { prepare(context.coordinator) }
    func updateUIView(_ view: WKWebView, context: Context) { context.coordinator.parent = self }
}
#endif
