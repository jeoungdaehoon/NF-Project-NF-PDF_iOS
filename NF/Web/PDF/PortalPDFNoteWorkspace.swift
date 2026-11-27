import Combine
import PDFKit
import SwiftUI
import WebKit

@MainActor
final class PDFNoteWorkspaceState: ObservableObject {
    enum Mode {
        case popup, slide, split, note

        var showsLinkedMarker: Bool { self == .slide || self == .split }
    }
    struct Anchor: Identifiable {
        let id: String
        let note: String
        let page: PDFPage
        let bounds: CGRect
        var isDocumentMarker = false
        var markerStyle = PDFDocumentMarkerStyle()
    }
    struct Target {
        let page: PDFPage
        let bounds: CGRect
        var objectID: String? = nil
        var isDocumentMarker = false
        var markerStyle = PDFDocumentMarkerStyle()
    }
    struct Session: Identifiable {
        let id: String
        let note: String
        var mode: Mode = .popup
        var collapsed = false
        var pdfScaleBeforeNoteOnly: CGFloat?
        var target: URL?
    }
    static let path = "/pdf-free-note"
    let origin: URL
    var sourceURL: URL?
    var localSourceID: String?
    weak var canvas: PDFView?
    var changeDocument: ((PDFPage, @escaping () -> Void) -> Void)?
    @Published var sessions: [Session] = []
    @Published var documentTool = false {
        didSet {
            if !documentTool {
                showsDocumentOptions = false
                editingMarkerID = nil
            }
        }
    }
    @Published var destination: URL?
    @Published var error: String?
    @Published private(set) var pendingArea: Target?
    @Published private(set) var placements: [String: PDFNotePlacement] = [:]
    private weak var activeDocument: PDFDocument?
    @Published var showsDocumentOptions = false
    @Published var documentMarkerStyle = PDFDocumentMarkerStyle.load() {
        didSet { if documentMarkerStyle != oldValue { documentMarkerStyle.save() } }
    }
    @Published private(set) var recentDocumentIcons = PDFDocumentMarkerStyle.recentIcons()
    @Published private(set) var closingPopups: Set<String> = []
    @Published var editingMarkerID: String?
    @Published private(set) var markerRevision = 0
    private var focusedMarkerID: String?
    private var closeRequests: Set<String> = []
    private var popupLayoutDirectory: URL?
    private var browsers: [String: WKWebView] = [:]
    private lazy var linkDelegate = PDFNoteLinkDelegate(workspace: self)
    let viewportChanges = PassthroughSubject<Void, Never>()
    private var viewportChangePending = false
    private var viewportNotifications: AnyCancellable?
    #if os(iOS)
    private weak var scrollView: UIScrollView?
    private var scrollObservation: NSKeyValueObservation?
    #endif

    init(origin: URL) { self.origin = origin }

    func activate(_ document: PDFDocument, source: URL?, localID: String?, note: String?, popupLayoutDirectory: URL? = nil) {
        if let activeDocument, activeDocument !== document {
            sessions.removeAll()
            browsers.removeAll()
            placements.removeAll()
            cancelPicker()
            documentTool = false
            closingPopups.removeAll()
            editingMarkerID = nil
            focusedMarkerID = nil
        }
        activeDocument = document
        sourceURL = source
        localSourceID = localID
        self.popupLayoutDirectory = popupLayoutDirectory
        reopen(note)
    }

    func attach(_ view: PDFView) {
        canvas = view
        view.delegate = linkDelegate
        let center = NotificationCenter.default
        viewportNotifications = center.publisher(for: .PDFViewScaleChanged, object: view)
            .merge(with: center.publisher(for: .PDFViewPageChanged, object: view),
                   center.publisher(for: .PDFViewDocumentChanged, object: view))
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.viewportChanged() }
            }
        #if os(iOS)
        let tap = UITapGestureRecognizer(target: linkDelegate, action: #selector(PDFNoteLinkDelegate.placeDocument(_:)))
        tap.delegate = linkDelegate
        view.addGestureRecognizer(tap)
        #endif
    }

    #if os(iOS)
    func observeScrollView(_ view: UIScrollView?) {
        guard view !== scrollView else { return }
        scrollView = view
        scrollObservation = view?.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.viewportChanged() }
        }
        viewportChanged()
    }
    #endif

    func viewportChanged() {
        guard !viewportChangePending else { return }
        viewportChangePending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.viewportChangePending = false
            self.viewportChanges.send()
        }
    }

    func openLink(_ url: URL, in view: PDFView) -> Bool {
        guard url.scheme == origin.scheme, url.host == origin.host, url.port == origin.port, url.path == Self.path,
              let note = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "note" })?.value else { return false }
        let nearby = view.visiblePages.flatMap(anchors(on:))
        let anchor = nearby.first { $0.id == url.fragment } ?? nearby.first { $0.note == note }
        if let anchor { openMarker(anchor) }
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

    @discardableResult
    func placeDocument(at point: CGPoint) -> Bool {
        guard documentTool, destination == nil, let canvas,
              let page = canvas.page(for: point, nearest: false) else { return false }
        // Canvas events can reach PDFKit while the document tool is active.
        // An existing marker at the click location takes priority over placement.
        if openDocumentMarker(at: point) { return true }
        let rect = CGRect(x: point.x - 10, y: point.y - 10, width: 20, height: 20)
        let bounds = canvas.convert(rect, to: page).standardized
        guard !bounds.isEmpty, !bounds.isNull else { return false }
        var target = Target(page: page, bounds: bounds, isDocumentMarker: true)
        target.markerStyle = documentMarkerStyle
        showsDocumentOptions = false
        chooseNote(target)
        return true
    }

    func documentMarker(at point: CGPoint) -> Anchor? {
        guard let canvas, let page = canvas.page(for: point, nearest: false) else { return nil }
        return anchors(on: page).reversed().first { anchor in
            guard anchor.isDocumentMarker else { return false }
            let frame = canvas.convert(anchor.bounds, from: page).standardized
            let radius = max(24, min(frame.width, frame.height)) / 2
            return abs(point.x - frame.midX) <= radius && abs(point.y - frame.midY) <= radius
        }
    }

    @discardableResult
    func openDocumentMarker(at point: CGPoint) -> Bool {
        guard let marker = documentMarker(at: point) else { return false }
        openMarker(marker)
        return true
    }

    func canEditMarker(_ id: String) -> Bool {
        documentTool && !sessions.contains { $0.id == id && !$0.collapsed }
    }

    private func chooseNote(_ area: Target) {
        pendingArea = area
        destination = noteURL()
    }

    func chooseDocumentIcon(_ icon: String) {
        guard PDFDocumentIcon.byID[icon] != nil else { return }
        var style = configuredMarkerStyle
        style.icon = icon
        configuredMarkerStyle = style
        recentDocumentIcons = PDFDocumentMarkerStyle.rememberIcon(icon)
    }

    var configuredMarkerStyle: PDFDocumentMarkerStyle {
        get {
            guard let id = configuredMarkerID, let (_, annotation) = markerAnnotation(id),
                  let url = Self.ownedLink(annotation),
                  let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return documentMarkerStyle }
            return PDFDocumentMarkerStyle(query: query)
        }
        set {
            guard let id = configuredMarkerID else { documentMarkerStyle = newValue; return }
            guard let (page, annotation) = markerAnnotation(id), let url = Self.ownedLink(annotation),
                  var parts = URLComponents(url: url, resolvingAgainstBaseURL: false), newValue != configuredMarkerStyle else { return }
            parts.queryItems = (parts.queryItems ?? []).filter { !PDFDocumentMarkerStyle.queryNames.contains($0.name) } + newValue.queryItems
            guard let updated = parts.url else { return }
            changeDocument?(page) { annotation.url = updated }
            markerRevision &+= 1
        }
    }

    private var configuredMarkerID: String? {
        if let editingMarkerID { return editingMarkerID }
        if let focusedMarkerID, sessions.contains(where: { $0.id == focusedMarkerID && !$0.collapsed }) { return focusedMarkerID }
        return sessions.last(where: { !$0.collapsed })?.id
    }

    private func markerAnnotation(_ id: String) -> (PDFPage, PDFAnnotation)? {
        guard let document = canvas?.document else { return nil }
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index),
                  let annotation = page.annotations.first(where: { Self.ownedLink($0)?.fragment == id }) else { continue }
            return (page, annotation)
        }
        return nil
    }

    func markerStyle(for id: String) -> PDFDocumentMarkerStyle {
        guard let (_, annotation) = markerAnnotation(id), let link = Self.ownedLink(annotation),
              let query = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems else {
            return PDFDocumentMarkerStyle()
        }
        return PDFDocumentMarkerStyle(query: query)
    }

    func moveDocumentMarker(_ id: String, to frame: CGRect) {
        guard let canvas, let (page, annotation) = markerAnnotation(id),
              anchors(on: page).contains(where: { $0.id == id && $0.isDocumentMarker }) else { return }
        let rect = canvas.isFlippedForNoteWorkspace ? frame : frame.offsetBy(dx: 0, dy: canvas.bounds.height - frame.maxY - frame.minY)
        let bounds = canvas.convert(rect, to: page).standardized.intersection(page.bounds(for: canvas.displayBox))
        guard !bounds.isNull, !bounds.isEmpty, bounds != annotation.bounds else { return }
        changeDocument?(page) { annotation.bounds = bounds }
        markerRevision &+= 1
    }

    func markerPageFrame(_ anchor: Anchor) -> CGRect {
        viewFrame(anchor.page.bounds(for: canvas?.displayBox ?? .cropBox), on: anchor.page)
    }

    func selectPortalPage(_ url: URL) {
        guard let href = PDFPageLink.href(for: url, origin: origin) else { return }
        connect(PDFPageLink.tabID(url) ?? UUID().uuidString, pageHref: href)
    }

    func portalPage(for session: Session) -> URL? {
        session.target ?? PDFPageLink.url(for: "/custom/" + session.note, origin: origin)
    }

    private func restorePortalPage(_ id: String, from link: URL?) {
        guard let index = sessions.firstIndex(where: { $0.id == id }),
              let link, let href = URLComponents(url: link, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "page" })?.value else { return }
        sessions[index].target = PDFPageLink.url(for: href, origin: origin)
    }

    private func connect(_ note: String, pageHref: String?) {
        guard note.range(of: "^[a-zA-Z0-9_-]{1,120}$", options: .regularExpression) != nil,
              let area = pendingArea, area.page.document === canvas?.document,
              let url = noteURL(note),
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let id = UUID().uuidString
        parts.fragment = id
        if area.isDocumentMarker {
            parts.queryItems?.append(.init(name: "marker", value: "1"))
        }
        parts.queryItems?.append(contentsOf: area.markerStyle.queryItems)
        if let pageHref { parts.queryItems?.append(.init(name: "page", value: pageHref)) }
        let annotation = PDFAnnotation(bounds: area.bounds, forType: .link, withProperties: nil)
        annotation.url = parts.url
        if area.isDocumentMarker { annotation.contents = "nf-note-marker" }
        else if let objectID = area.objectID { annotation.contents = "nf-note-object:" + objectID }
        let border = PDFBorder()
        border.lineWidth = 0
        annotation.border = border
        changeDocument?(area.page) { area.page.addAnnotation(annotation) }
        if area.isDocumentMarker, area.page.annotations.contains(annotation) {
            recentDocumentIcons = PDFDocumentMarkerStyle.rememberIcon(area.markerStyle.icon)
        }
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
                  let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
                  let note = query.first(where: { $0.name == "note" })?.value else { return nil }
            let id = Self.ownedLink(annotation)?.fragment ?? "\(ObjectIdentifier(page))-\(index)"
            var anchor = Anchor(id: id, note: note, page: page, bounds: annotation.bounds,
                                isDocumentMarker: annotation.contents == "nf-note-marker" ||
                                    query.contains { $0.name == "marker" && $0.value == "1" })
            anchor.markerStyle = PDFDocumentMarkerStyle(query: query)
            return anchor
        }
    }

    func viewFrame(_ bounds: CGRect, on page: PDFPage) -> CGRect {
        guard let canvas else { return .zero }
        let frame = canvas.convert(bounds, from: page).standardized
        let y = canvas.isFlippedForNoteWorkspace ? frame.minY : canvas.bounds.height - frame.maxY
        return CGRect(x: frame.minX, y: y, width: frame.width, height: frame.height)
    }

    var displayScale: CGFloat { max(canvas?.scaleFactor ?? 1, 0.01) }

    func visibleAnchors() -> [(Anchor, CGRect)] {
        (canvas?.visiblePages ?? []).flatMap { page in
            anchors(on: page).map { ($0, viewFrame($0.bounds, on: page)) }
        }
    }

    func placePopup(_ frame: CGRect, for id: String, beside anchor: CGRect, scale: CGFloat, contentScale: CGFloat? = nil) {
        let preservedScale = contentScale ?? placements[id]?.contentScale(at: scale) ?? 1
        placements[id] = PDFNotePlacement(frame: frame, anchor: anchor, scale: scale, contentScale: preservedScale)
    }

    func savePopupPlacement(_ id: String) {
        guard let file = popupLayoutFile(id), let placement = placements[id] else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try PropertyListEncoder().encode(placement).write(to: file, options: .atomic)
        } catch {
            self.error = "문서 팝업 배치를 저장하지 못했습니다."
        }
    }

    private func popupLayoutFile(_ id: String) -> URL? {
        guard let marker = UUID(uuidString: id) else { return nil }
        return popupLayoutDirectory?.appendingPathComponent(marker.uuidString).appendingPathExtension("plist")
    }

    func unlink(_ id: String, animated: Bool = true) async {
        guard let document = canvas?.document, let session = sessions.first(where: { $0.id == id }) else { return }
        await close(id, animated: animated)
        guard !sessions.contains(where: { $0.id == id }), canvas?.document === document else { return }
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index),
                  let anchor = anchors(on: page).first(where: { $0.id == id && $0.note == session.note }),
                  let annotation = page.annotations.enumerated().first(where: { index, annotation in
                      pageLinkIdentifier(annotation, on: page, index: index) == anchor.id && annotation.bounds == anchor.bounds
                  })?.element else { continue }
            changeDocument?(page) { page.removeAnnotation(annotation) }
            placements.removeValue(forKey: id)
            return
        }
    }

    private func pageLinkIdentifier(_ annotation: PDFAnnotation, on page: PDFPage, index: Int) -> String {
        Self.ownedLink(annotation)?.fragment ?? "\(ObjectIdentifier(page))-\(index)"
    }

    func open(id: String, note: String) {
        if closeRequests.contains(id) { return }
        editingMarkerID = nil
        focusedMarkerID = id
        showsDocumentOptions = false
        if let index = sessions.firstIndex(where: { $0.id == id }) {
            sessions[index].collapsed = false
            return
        }
        if let existing = sessions.first(where: { $0.note == note }) {
            sessions.removeAll { $0.id == existing.id }
            browsers[id] = browsers.removeValue(forKey: existing.id)
        }
        if placements[id] == nil, let file = popupLayoutFile(id), let data = try? Data(contentsOf: file),
           let placement = try? PropertyListDecoder().decode(PDFNotePlacement.self, from: data), placement.isValid {
            placements[id] = placement
        }
        sessions.append(Session(id: id, note: note))
        if let document = canvas?.document {
            for index in 0..<document.pageCount {
                guard let link = document.page(at: index)?.annotations.compactMap(Self.ownedLink).first(where: { $0.fragment == id }) else { continue }
                restorePortalPage(id, from: link)
                break
            }
        }
    }

    func openMarker(_ anchor: Anchor) {
        let dockedMode = sessions.last { $0.mode.showsLinkedMarker }?.mode
        if destination != nil { cancelPicker() }
        open(id: anchor.id, note: anchor.note)
        if let dockedMode { mode(dockedMode, for: anchor.id) }
    }

    func collapse(_ id: String) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].mode = .popup
        sessions[index].collapsed = true
    }

    func mode(_ mode: Mode, for id: String) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        if mode == .note && sessions[index].mode != .note {
            sessions[index].pdfScaleBeforeNoteOnly = canvas?.scaleFactor
        }
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

    func reveal(_ id: String, restoringScale: Bool = false, onlyIfOffscreen: Bool = false) {
        guard let canvas, let document = canvas.document else { return }
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index),
                  let anchor = anchors(on: page).first(where: { $0.id == id }) else { continue }
            if onlyIfOffscreen && canvas.bounds.contains(canvas.convert(anchor.bounds, from: page).standardized) { return }
            if restoringScale, let session = sessions.firstIndex(where: { $0.id == id }),
               let scale = sessions[session].pdfScaleBeforeNoteOnly, scale.isFinite, scale > 0 {
                canvas.autoScales = false
                canvas.scaleFactor = scale
                sessions[session].pdfScaleBeforeNoteOnly = nil
            }
            canvas.go(to: anchor.bounds, on: page)
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
        guard let session = sessions.first(where: { $0.id == id }), closeRequests.insert(id).inserted else { return }
        let closingDocument = activeDocument
        defer { closeRequests.remove(id) }
        do {
            if let browser = browsers[id] {
                _ = try await browser.callAsyncJavaScript(
                    "if (window.nfFlushPdfFreeNote) await window.nfFlushPdfFreeNote();",
                    arguments: [:], in: nil, contentWorld: .page
                )
            }
            guard activeDocument === closingDocument else { return }
            if animated, session.mode == .popup, sessions.contains(where: { $0.id == id }) {
                withAnimation(.easeInOut(duration: 0.28)) { _ = closingPopups.insert(id) }
                try? await Task.sleep(for: .milliseconds(280))
                guard activeDocument === closingDocument else { return }
                withAnimation(nil) {
                    sessions.removeAll { $0.id == id }
                    closingPopups.remove(id)
                }
                browsers.removeValue(forKey: id)
                return
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

#if os(iOS)
extension PDFNoteLinkDelegate: @preconcurrency UIGestureRecognizerDelegate {
    @objc func placeDocument(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, let view = gesture.view, let workspace else { return }
        let point = gesture.location(in: view)
        if !workspace.openDocumentMarker(at: point) { workspace.placeDocument(at: point) }
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let workspace, let view = gestureRecognizer.view, workspace.destination == nil else { return false }
        return workspace.documentTool || workspace.documentMarker(at: gestureRecognizer.location(in: view)) != nil
    }
}
#endif

private extension PDFView {
    var isFlippedForNoteWorkspace: Bool {
        #if os(macOS)
        return isFlipped
        #else
        return true
        #endif
    }
}

struct PDFNotePlacement: Codable {
    private let bounds: CGRect
    private let contentScaleRatio: CGFloat

    init(frame: CGRect, anchor: CGRect, scale: CGFloat, contentScale: CGFloat = 1) {
        bounds = CGRect(x: (frame.minX - anchor.midX) / scale, y: (frame.minY - anchor.midY) / scale,
                        width: frame.width / scale, height: frame.height / scale)
        contentScaleRatio = contentScale / scale
    }

    func contentScale(at scale: CGFloat) -> CGFloat { contentScaleRatio * scale }

    func screenFrame(anchor: CGRect, scale: CGFloat) -> CGRect {
        CGRect(x: anchor.midX + bounds.minX * scale, y: anchor.midY + bounds.minY * scale,
               width: bounds.width * scale, height: bounds.height * scale)
    }

    var isValid: Bool {
        [bounds.origin.x, bounds.origin.y, bounds.size.width, bounds.size.height, contentScaleRatio].allSatisfy(\.isFinite) &&
            bounds.size.width > 0 && bounds.size.height > 0 && contentScaleRatio > 0
    }

    static func zoomedFrame(_ rect: CGRect, by translation: CGSize) -> CGRect {
        let distance = abs(translation.width) >= abs(translation.height) ? translation.width : -translation.height
        let factor = exp(distance / 180)
        let minimum = 88 / min(rect.width, rect.height)
        let maximum = 2400 / max(rect.width, rect.height)
        let scale = min(maximum, max(minimum, factor))
        let width = rect.width * scale, height = rect.height * scale
        return CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
    }
}

struct PDFNoteWorkspace<Editor: View>: View {
    @ObservedObject var state: PDFNoteWorkspaceState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var fraction: CGFloat = 0.52
    @State private var splitDrag: CGFloat?
    @State private var viewportRevision = 0
    #if os(iOS)
    @State private var keyboardVisible = false
    #endif
    let enabled: Bool
    @ViewBuilder var editor: Editor

    var body: some View {
        let _ = viewportRevision
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
                    layer(size: size, pdfWidth: pdfWidth, full: full)
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
                if state.destination != nil {
                    let width = min(380, max(1, size.width - 24))
                    let height = min(440, max(1, size.height - 24))
                    let anchor = state.pendingArea.map { state.viewFrame($0.bounds, on: $0.page) }
                    let picker = CGRect(x: (anchor?.midX ?? size.width / 2) - width / 2,
                                        y: anchor.map { $0.midY > size.height / 2 ? $0.minY - height - 10 : $0.maxY + 10 }
                                            ?? (size.height - height) / 2,
                                        width: width, height: height)
                        .clamped(to: CGRect(origin: .zero, size: size).insetBy(dx: 8, dy: 8))
                    PDFPageLinkPicker(origin: state.origin, onSelect: state.selectPortalPage, onClose: state.cancelPicker)
                    .frame(width: width, height: height)
                    .background(.background)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(.secondary.opacity(0.35)) }
                    .shadow(radius: 18)
                    .position(x: picker.midX, y: picker.midY)
                }
            }
            .coordinateSpace(name: "PDFNoteWorkspace")
            .clipped()
        }
        .onReceive(state.viewportChanges) { viewportRevision &+= 1 }
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardVisible = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardVisible = false }
        #endif
        .alert("자유노트", isPresented: Binding(get: { state.error != nil }, set: { if !$0 { state.error = nil } })) {
            Button("확인") { state.error = nil }
        } message: { Text(state.error ?? "") }
    }

    private func splitFraction(_ x: CGFloat, width: CGFloat) -> CGFloat {
        let minimum = min(0.4, 160 / max(width, 1))
        return min(1 - minimum, max(minimum, x / max(width, 1)))
    }

    private func boxes(size: CGSize, anchors: [String: CGRect], documentMarkers: Set<String>,
                       full: PDFNoteWorkspaceState.Session?, pdfWidth: CGFloat) -> [String: CGRect] {
        if let full {
            let width = min(420, size.width - min(64, size.width / 3))
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
        let topMargin = min(24, max(0, workspace.height - height))
        let popupArea = CGRect(x: workspace.minX, y: workspace.minY + topMargin,
                               width: workspace.width, height: workspace.height - topMargin)
        var result: [String: CGRect] = [:]
        for session in state.sessions where !session.collapsed {
            guard let anchor = anchors[session.id] else { continue }
            if let placement = state.placements[session.id] {
                let frame = placement.screenFrame(anchor: anchor, scale: state.displayScale)
                #if os(iOS)
                if keyboardVisible {
                    let top = min(28, max(0, size.height - 1))
                    let height = min(frame.height, max(1, size.height - top))
                    let y = min(max(top, frame.minY), max(top, size.height - height))
                    result[session.id] = CGRect(x: frame.minX, y: y, width: frame.width, height: height)
                    continue
                }
                #endif
                if workspace.intersects(frame) {
                    result[session.id] = frame
                    continue
                }
                if workspace.intersects(anchor) {
                    let x = min(max(popupArea.minX, frame.minX), max(popupArea.minX, popupArea.maxX - frame.width))
                    let y = min(max(popupArea.minY, frame.minY), max(popupArea.minY, popupArea.maxY - frame.height))
                    result[session.id] = CGRect(origin: CGPoint(x: x, y: y), size: frame.size)
                }
                continue
            }
            guard workspace.intersects(anchor) else { continue }
            let right = CGRect(x: anchor.maxX + 14, y: anchor.midY - height / 2, width: width, height: height)
            let left = CGRect(x: anchor.minX - width - 14, y: right.minY, width: width, height: height)
            let below = CGRect(x: anchor.midX - width / 2, y: anchor.maxY + 14, width: width, height: height)
            let above = CGRect(x: below.minX, y: anchor.minY - height - 14, width: width, height: height)
            let candidates = [right, left, below, above].map { $0.clamped(to: popupArea) }
            if let frame = candidates.first(where: { candidate in
                !candidate.intersects(anchor) && !result.values.contains(where: { $0.insetBy(dx: -6, dy: -6).intersects(candidate) })
            }) { result[session.id] = frame }
            else if documentMarkers.contains(session.id) {
                let spaceAbove = anchor.minY - popupArea.minY - 12
                let spaceBelow = popupArea.maxY - anchor.maxY - 12
                let fitsAbove = spaceAbove > spaceBelow
                let fittedHeight = min(height, max(min(150, height), max(spaceAbove, spaceBelow)))
                result[session.id] = CGRect(x: anchor.midX - width / 2,
                    y: fitsAbove ? anchor.minY - fittedHeight - 12 : anchor.maxY + 12,
                    width: width, height: fittedHeight).clamped(to: popupArea)
            }
        }
        return result
    }

    private func layer(size: CGSize, pdfWidth: CGFloat, full: PDFNoteWorkspaceState.Session?) -> some View {
        let anchors = state.visibleAnchors()
        let positions = Dictionary(anchors.map { ($0.0.id, $0.1) }, uniquingKeysWith: { first, _ in first })
        let styles = Dictionary(anchors.map { ($0.0.id, $0.0.markerStyle) }, uniquingKeysWith: { first, _ in first })
        let documentMarkers = Set(anchors.compactMap { $0.0.isDocumentMarker ? $0.0.id : nil })
        let frames = boxes(size: size, anchors: positions, documentMarkers: documentMarkers, full: full, pdfWidth: pdfWidth)
        let newest = state.sessions.last.flatMap { $0.collapsed ? nil : $0.id }
        let fallback = newest.flatMap { full == nil && positions[$0] != nil && frames[$0] == nil && state.placements[$0] == nil ? $0 : nil }
        let docked = full.flatMap { $0.mode.showsLinkedMarker ? $0 : nil }
        let visiblePDFWidth = min(pdfWidth, docked.flatMap { frames[$0.id]?.minX } ?? pdfWidth)
        return ZStack(alignment: .topLeading) {
            if full == nil || docked != nil {
                if state.editingMarkerID != nil {
                    Color.clear.frame(width: visiblePDFWidth, height: size.height)
                        .contentShape(Rectangle()).onTapGesture { state.editingMarkerID = nil }
                }
                ForEach(anchors, id: \.0.id) { anchor, frame in
                    if CGRect(x: 0, y: 0, width: visiblePDFWidth, height: size.height).intersects(frame) {
                        let active = docked?.id == anchor.id
                        if anchor.isDocumentMarker {
                            PDFDocumentMarkerControl(state: state, anchor: anchor, frame: frame,
                                active: active,
                                canEdit: state.canEditMarker(anchor.id))
                        } else {
                            standardMarkerButton(anchor, frame: frame, active: active)
                                .position(markerCenter(frame, documentMarker: false, pdfWidth: visiblePDFWidth, height: size.height))
                        }
                    }
                }
            }
            if full == nil {
                ForEach(state.sessions) { session in
                    if let anchor = positions[session.id], let frame = frames[session.id] {
                        let style = styles[session.id] ?? PDFDocumentMarkerStyle()
                        Path { path in
                            let start = CGPoint(x: documentMarkers.contains(session.id) ? anchor.midX : anchor.maxX, y: anchor.midY)
                            let end = CGPoint(x: min(frame.maxX, max(frame.minX, start.x)), y: min(frame.maxY, max(frame.minY, start.y)))
                            path.move(to: start)
                            path.addLine(to: CGPoint(x: end.x, y: start.y))
                            path.addLine(to: end)
                        }.stroke(style.lineColor, lineWidth: style.lineWidth * state.displayScale).allowsHitTesting(false)
                    }
                }
            }
            if let pending = state.pendingArea, pending.isDocumentMarker {
                let frame = state.viewFrame(pending.bounds, on: pending.page)
                PDFDocumentMarkerView(style: pending.markerStyle, size: max(14, min(frame.width, frame.height)))
                    .position(x: frame.midX, y: frame.midY)
                    .allowsHitTesting(false)
            }
            ForEach(state.sessions) { session in
                let frame = frames[session.id] ?? CGRect(x: -1, y: -1, width: 1, height: 1)
                let center = CGPoint(x: frame.midX, y: frame.midY)
                let visualScale = session.mode == .popup ? state.placements[session.id]?.contentScale(at: state.displayScale) ?? 1 : 1
                let shrinking = state.closingPopups.contains(session.id)
                let marker = positions[session.id].map { anchor in
                    markerCenter(anchor, documentMarker: documentMarkers.contains(session.id), pdfWidth: pdfWidth, height: size.height)
                }
                PDFNoteCard(state: state, session: session, frame: frame, visualScale: visualScale,
                            clippedBottom: max(0, frame.maxY - size.height),
                            activeLinkStyle: docked?.id == session.id ? styles[session.id] ?? state.markerStyle(for: session.id) : nil) { next, contentScale in
                    if let anchor = positions[session.id] {
                        state.placePopup(next, for: session.id, beside: anchor, scale: state.displayScale, contentScale: contentScale)
                    }
                }
                    .frame(width: frame.width, height: frame.height)
                    .scaleEffect(shrinking ? 0.045 : 1)
                    .position(shrinking ? marker ?? center : center)
                    .opacity(frames[session.id] == nil || shrinking ? 0 : 1)
                    .allowsHitTesting(frames[session.id] != nil && !shrinking)
                    .transition(reduceMotion ? .identity : .move(edge: .trailing).combined(with: .opacity))
                    .task(id: frames[session.id] != nil && session.mode == .popup) {
                        guard session.mode == .popup, state.placements[session.id] == nil,
                              let frame = frames[session.id], let anchor = positions[session.id] else { return }
                        state.placePopup(frame, for: session.id, beside: anchor, scale: state.displayScale)
                    }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .task(id: fallback) {
            withAnimation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.84)) {
                state.autoSlide(fallback)
            }
        }
    }

    private func markerCenter(_ frame: CGRect, documentMarker: Bool, pdfWidth: CGFloat, height: CGFloat) -> CGPoint {
        CGPoint(x: min(pdfWidth - 16, max(16, documentMarker ? frame.midX : frame.maxX)),
                y: min(height - 16, max(16, frame.midY)))
    }

    private func standardMarkerButton(_ anchor: PDFNoteWorkspaceState.Anchor, frame: CGRect, active: Bool) -> some View {
        Button { state.openMarker(anchor) } label: {
            Image(systemName: "doc.text")
                .font(.system(size: anchor.isDocumentMarker ? max(8, frame.height * 0.7) : 12, weight: .semibold))
                .frame(width: anchor.isDocumentMarker ? max(14, frame.width) : 25,
                       height: anchor.isDocumentMarker ? max(14, frame.height) : 25)
        }
        .buttonStyle(.borderedProminent)
        .pdfActiveDocumentMarker(active)
        .accessibilityLabel("연결된 문서 열기")
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

private extension View {
    func pdfActiveDocumentMarker(_ active: Bool = true) -> some View {
        overlay {
            if active {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(.background, lineWidth: 5)
                    .overlay { RoundedRectangle(cornerRadius: 7).stroke(Color.accentColor, lineWidth: 2) }
                    .padding(-2)
                    .allowsHitTesting(false)
            }
        }
    }
}

private struct PDFDocumentMarkerControl: View {
    @ObservedObject var state: PDFNoteWorkspaceState
    let anchor: PDFNoteWorkspaceState.Anchor
    let frame: CGRect
    let active: Bool
    let canEdit: Bool
    @State private var preview: CGRect?
    @State private var startingFrame: CGRect?
    @State private var movingAfterHold = false
    @State private var directMove = false

    private var editing: Bool { canEdit && state.editingMarkerID == anchor.id }
    private let corners: [UnitPoint] = [.topLeading, .topTrailing, .bottomLeading, .bottomTrailing]
    private let cornerNames = ["왼쪽 위", "오른쪽 위", "왼쪽 아래", "오른쪽 아래"]

    var body: some View {
        let displayed = preview ?? frame
        let iconSize = max(1, min(displayed.width, displayed.height))
        ZStack(alignment: .topLeading) {
            markerControl(iconSize: iconSize)
                .accessibilityLabel("연결된 문서 열기")
                .accessibilityAddTraits(active ? .isSelected : [])
                .position(x: displayed.midX, y: displayed.midY)
            if editing {
                resizeHandles(displayed)
            }
        }
        .onChange(of: editing) { _, isEditing in
            if !isEditing {
                preview = nil
                startingFrame = nil
                movingAfterHold = false
                directMove = false
            }
        }
    }

    private func markerFace(_ iconSize: CGFloat) -> some View {
        PDFDocumentMarkerView(style: anchor.markerStyle, size: iconSize)
            .pdfActiveDocumentMarker(active)
            .frame(width: max(24, iconSize), height: max(24, iconSize))
            .contentShape(Rectangle())
    }

    @ViewBuilder
    private func markerControl(iconSize: CGFloat) -> some View {
        if canEdit {
            markerFace(iconSize)
                .gesture(holdToMove.exclusively(before: TapGesture().onEnded { state.openMarker(anchor) }))
                .simultaneousGesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("PDFNoteWorkspace"))
                    .onChanged { value in
                        guard editing, canEdit, !movingAfterHold else { return }
                        directMove = true
                        update(value.translation)
                    }.onEnded { _ in
                        guard directMove else { return }
                        directMove = false
                        finish()
                    })
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { state.openMarker(anchor) }
                .accessibilityAction(named: Text("문서 아이콘 편집")) {
                    state.editingMarkerID = anchor.id
                }
        } else {
            Button { state.openMarker(anchor) } label: { markerFace(iconSize) }
                .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func resizeHandles(_ displayed: CGRect) -> some View {
        Rectangle().strokeBorder(.tint, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            .frame(width: displayed.width, height: displayed.height)
            .position(x: displayed.midX, y: displayed.midY)
            .allowsHitTesting(false)
        ForEach(corners.indices, id: \.self) { index in
            let corner = corners[index]
            let handleSize: CGFloat = 22
            let outwardX = (corner.x == 0 ? -1 : 1) * (handleSize / 2 - min(6, displayed.width / 4))
            let outwardY = (corner.y == 0 ? -1 : 1) * (handleSize / 2 - min(6, displayed.height / 4))
            Circle().fill(.background).overlay { Circle().strokeBorder(.tint) }
                .frame(width: 7, height: 7)
                .offset(x: -outwardX, y: -outwardY)
                .frame(width: handleSize, height: handleSize)
                .contentShape(Rectangle())
                .position(x: displayed.minX + displayed.width * corner.x + outwardX,
                          y: displayed.minY + displayed.height * corner.y + outwardY)
                .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("PDFNoteWorkspace"))
                    .onChanged { update($0.translation, corner: corner) }
                    .onEnded { _ in finish() })
                .accessibilityLabel("문서 아이콘 크기 조절 \(cornerNames[index])")
        }
    }

    private var holdToMove: some Gesture {
        LongPressGesture(minimumDuration: 0.45, maximumDistance: 12)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named("PDFNoteWorkspace")))
            .onChanged { phase in
                guard canEdit else { return }
                switch phase {
                case .first(true):
                    movingAfterHold = true
                    state.editingMarkerID = anchor.id
                case .second(true, let drag):
                    movingAfterHold = true
                    state.editingMarkerID = anchor.id
                    if let drag { update(drag.translation) }
                default: break
                }
            }
            .onEnded { _ in
                guard movingAfterHold else { return }
                movingAfterHold = false
                finish()
            }
    }

    private func update(_ delta: CGSize, corner: UnitPoint? = nil) {
        let page = state.markerPageFrame(anchor)
        guard !page.isEmpty else { return }
        let initial = startingFrame ?? frame
        startingFrame = initial
        guard let corner else {
            preview = initial.offsetBy(dx: delta.width, dy: delta.height).clamped(to: page)
            return
        }
        let xSign: CGFloat = corner.x == 0 ? -1 : 1
        let ySign: CGFloat = corner.y == 0 ? -1 : 1
        let fixedX = xSign < 0 ? initial.maxX : initial.minX
        let fixedY = ySign < 0 ? initial.maxY : initial.minY
        let availableX = xSign < 0 ? fixedX - page.minX : page.maxX - fixedX
        let availableY = ySign < 0 ? fixedY - page.minY : page.maxY - fixedY
        let maximum = max(1, min(availableX, availableY))
        let dx = delta.width * xSign
        let dy = delta.height * ySign
        let extent = min(maximum, max(min(14, maximum), min(initial.width, initial.height) + (abs(dx) >= abs(dy) ? dx : dy)))
        preview = CGRect(x: fixedX + (xSign < 0 ? -extent : 0),
                         y: fixedY + (ySign < 0 ? -extent : 0), width: extent, height: extent)
    }

    private func finish() {
        if let preview { state.moveDocumentMarker(anchor.id, to: preview) }
        preview = nil
        startingFrame = nil
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
    let frame: CGRect
    let visualScale: CGFloat
    let clippedBottom: CGFloat
    let activeLinkStyle: PDFDocumentMarkerStyle?
    let onFrameChange: (CGRect, CGFloat?) -> Void
    @State private var actions = false
    @State private var resizing = false
    @State private var dragStart: CGRect?
    @State private var dragStartScale: CGFloat = 1
    @GestureState private var dragIndicator: PDFNoteDragIndicator?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var popup: Bool { session.mode == .popup }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                HStack(spacing: 7) {
                    if let activeLinkStyle {
                        PDFDocumentMarkerView(style: activeLinkStyle, size: 19)
                            .pdfActiveDocumentMarker()
                        Text("문서").accessibilityLabel("현재 연결된 문서")
                    } else {
                        Label("문서", systemImage: "doc.text")
                    }
                }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onLongPressGesture { if popup { actions = true } }
                if popup {
                    Button { change(.slide) } label: {
                        Image(systemName: "rectangle.righthalf.inset.filled")
                    }
                    .help("오른쪽 슬라이드 보기")
                    .accessibilityLabel("오른쪽 슬라이드 보기")
                    .accessibilityIdentifier("pdf.document.popup.slide")
                } else {
                    pdfViewToggle
                }
                if !popup { moreButton }
                if popup {
                    Button { actions = false; resizing.toggle() } label: {
                        Image(systemName: resizing ? "checkmark" : "square.dashed")
                    }
                    .help(resizing ? "크기 편집 완료" : "크기 편집")
                    .accessibilityLabel(resizing ? "크기 편집 완료" : "크기 편집")
                    .accessibilityIdentifier("pdf.document.popup.resize")
                }
                Button { Task { await state.close(session.id, animated: !reduceMotion) } } label: { Image(systemName: "xmark") }
                    .accessibilityLabel("연결 문서 닫기")
            }
            .padding(9)
            Divider()
            documentBrowser
        }
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: popup ? 14 : 0))
        .overlay {
            RoundedRectangle(cornerRadius: popup ? 14 : 0)
                .strokeBorder(.secondary.opacity(0.35))
                .allowsHitTesting(false)
        }
        .shadow(radius: popup ? 12 : 0)
        .overlay(alignment: .top) {
            if popup { dragBar.offset(y: -24) }
        }
        .overlay {
            if popup && resizing { resizeHandles }
        }
        .onChange(of: session.mode) { _, _ in resizing = false; actions = false }
    }

    private var documentBrowser: some View {
        let embedded = state.noteURL(session.note, embedded: true)
        let primary = session.target ?? embedded
        let fallback = session.target == nil ? state.portalPage(for: session) : nil
        let binding = embedded.flatMap { PDFPageLink.attachmentBinding(in: $0) }

        return PDFNoteBrowser(origin: state.origin, url: primary, browser: state.browser(session), fallback: fallback,
                              volumePopup: popup, pageScale: visualScale, clippedBottom: clippedBottom,
                              attachmentBinding: binding) { command, _ in
            if command == "split" { change(.split) }
            if command == "close" { Task { await state.close(session.id, animated: !reduceMotion) } }
        }
    }

    private var pdfViewToggle: some View {
        let hidden = session.mode == .note
        let title = hidden ? "PDFView 켜기" : "PDFView 끄기"
        let symbol = hidden ? "rectangle.split.2x1" : "eye.slash"
        return Button { change(hidden ? .split : .note) } label: {
            if frame.width >= 280 {
                Label(title, systemImage: symbol)
            } else {
                Image(systemName: symbol)
            }
        }
        .help(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier("pdf.document.togglePDFView")
    }

    private var dragBar: some View {
        HStack(spacing: 4) {
            zoomControlIcon
                .frame(width: 24, height: 23)
                .contentShape(Rectangle())
                .gesture(adjust(scaleContent: true, indicator: .zoom, PDFNotePlacement.zoomedFrame))
                .accessibilityLabel("문서 팝업 확대·축소")
            Capsule()
                .fill(.secondary)
                .frame(width: 48, height: 4)
                .frame(height: 23)
                .contentShape(Rectangle())
                .gesture(adjust(indicator: .move) { $0.offsetBy(dx: $1.width, dy: $1.height) })
                .accessibilityLabel("문서 팝업 이동")
            moreButton.frame(width: 24, height: 23)
        }
        .padding(.horizontal, 3)
        .background(.background, in: Capsule())
        .overlay { Capsule().strokeBorder(.secondary.opacity(0.26)).allowsHitTesting(false) }
    }

    @ViewBuilder
    private var zoomControlIcon: some View {
        PDFNoteDragGlyph(indicator: dragIndicator)
            .stroke(.primary, style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
            .frame(width: 14, height: 14)

    }

    private var moreButton: some View {
        Button { actions.toggle() } label: {
            Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold))
                .frame(width: 24, height: 23)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("문서 팝업 더보기")
        .popover(isPresented: $actions) {
            VStack(alignment: .leading, spacing: 3) {
                if !popup {
                    menuRow("팝업 모드", icon: "rectangle.inset.filled") {
                        change(.popup)
                    }
                }
                menuRow("오른쪽 슬라이드 화면 모드", icon: "rectangle.righthalf.inset.filled") { change(.slide) }
                menuRow("좌우 분할 전체화면 모드", icon: "rectangle.split.2x1") { change(.split) }
                if session.mode == .note {
                    menuRow("PDFView 켜기", icon: "rectangle.split.2x1") { change(.split) }
                } else {
                    menuRow("PDFView 끄기", icon: "eye.slash") { change(.note) }
                }
                menuRow("접기", icon: "minus") { state.collapse(session.id) }
                Divider()
                menuRow("문서 연결 삭제", icon: "link.badge.minus", role: .destructive) {
                    Task { await state.unlink(session.id, animated: !reduceMotion) }
                }
            }
            .padding(8)
            .frame(minWidth: 190)
            #if os(iOS)
            .presentationCompactAdaptation(.popover)
            #endif
        }
    }

    private func menuRow(_ title: String, icon: String, role: ButtonRole? = nil, operation: @escaping () -> Void) -> some View {
        Button(role: role) {
            actions = false
            operation()
        } label: {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var resizeHandles: some View {
        GeometryReader { geometry in
            let size = geometry.size
            Rectangle()
                .strokeBorder(.tint, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .allowsHitTesting(false)
            ForEach(0..<4) { corner in
                let left = corner.isMultiple(of: 2)
                let top = corner < 2
                Rectangle()
                    .fill(.background)
                    .overlay { Rectangle().strokeBorder(.tint, lineWidth: 1.5) }
                    .frame(width: 8, height: 8)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
                    .gesture(adjust { rect, delta in
                        let x = left ? min(rect.minX + delta.width, rect.maxX - 88) : rect.minX
                        let y = top ? min(rect.minY + delta.height, rect.maxY - 88) : rect.minY
                        let right = left ? rect.maxX : max(rect.maxX + delta.width, x + 88)
                        let bottom = top ? rect.maxY : max(rect.maxY + delta.height, y + 88)
                        return CGRect(x: x, y: y, width: right - x, height: bottom - y)
                    })
                    .position(x: left ? 0 : size.width, y: top ? 0 : size.height)
                    .accessibilityLabel("문서 팝업 크기 조절")
            }
        }
    }

    private func adjust(scaleContent: Bool = false, indicator: PDFNoteDragIndicator.Kind? = nil,
                        _ transform: @escaping (CGRect, CGSize) -> CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("PDFNoteWorkspace"))
            .updating($dragIndicator) { value, current, _ in
                if let indicator {
                    current = PDFNoteDragIndicator(kind: indicator, translation: value.translation, previous: current)
                }
            }
            .onChanged { value in
                if dragStart == nil { dragStart = frame; dragStartScale = visualScale }
                if let dragStart {
                    let next = transform(dragStart, value.translation)
                    let contentScale = scaleContent ? dragStartScale * next.width / dragStart.width : nil
                    onFrameChange(next, contentScale)
                }
            }
            .onEnded { _ in
                if dragStart != nil { state.savePopupPlacement(session.id) }
                dragStart = nil
            }
    }

    private func change(_ mode: PDFNoteWorkspaceState.Mode) {
        let returningToPDF = session.mode == .note && mode != .note
        withAnimation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.84), completionCriteria: .logicallyComplete) {
            actions = false
            state.mode(mode, for: session.id)
        } completion: {
            guard state.sessions.contains(where: { $0.id == session.id && $0.mode == mode }) else { return }
            if returningToPDF {
                state.reveal(session.id, restoringScale: true)
            } else if mode.showsLinkedMarker {
                state.reveal(session.id, onlyIfOffscreen: true)
            }
        }
    }
}

struct PDFNoteDragIndicator {
    enum Kind { case zoom, move }
    let kind: Kind
    let translation: CGSize
    let heading: CGSize

    init(kind: Kind, translation: CGSize, previous: Self? = nil) {
        self.kind = kind
        self.translation = translation
        let last = previous?.translation ?? .zero
        let step = CGSize(width: translation.width - last.width, height: translation.height - last.height)
        heading = step == .zero ? previous?.heading ?? .zero : step
    }
}

private struct PDFNoteBrowser: View {
    let origin: URL
    let url: URL?
    let browser: WKWebView?
    var fallback: URL? = nil
    var volumePopup = false
    var pageScale: CGFloat = 1
    var clippedBottom: CGFloat = 0
    var attachmentBinding: PDFNoteAttachmentBinding? = nil
    let action: (String, String?) -> Void
    @State private var unavailable = false

    var body: some View {
        ZStack {
            PDFNoteWebContent(origin: origin, url: url, browser: browser, fallback: fallback, volumePopup: volumePopup,
                              pageScale: pageScale, clippedBottom: clippedBottom,
                              attachmentBinding: attachmentBinding, action: action) {
                unavailable = true
            }
            .opacity(unavailable ? 0 : 1)
            .allowsHitTesting(!unavailable)
            if unavailable {
                VStack(spacing: 12) {
                    Text("문서 화면을 열 수 없습니다.").multilineTextAlignment(.center)
                    Button("닫기") { action("close", nil) }
                }.padding(12)
            }
        }
    }
}

struct PDFNoteAttachmentBinding {
    let note: String
    let source: String
}

private struct PDFNoteWebContent {
    let origin: URL
    let url: URL?
    let browser: WKWebView?
    let fallback: URL?
    let volumePopup: Bool
    let pageScale: CGFloat
    let clippedBottom: CGFloat
    let attachmentBinding: PDFNoteAttachmentBinding?
    let action: (String, String?) -> Void
    let onUnavailable: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func prepare(_ coordinator: Coordinator) -> WKWebView {
        let view = browser ?? WKWebView(frame: .zero)
        view.navigationDelegate = coordinator
        coordinator.applyPageScale(to: view)
        if let url, view.url == nil, !view.isLoading { view.load(URLRequest(url: url)) }
        return view
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: PDFNoteWebContent
        private var ready = false
        private var triedFallback = false
        init(_ parent: PDFNoteWebContent) { self.parent = parent }

        func update(_ content: PDFNoteWebContent, in webView: WKWebView) {
            let modeChanged = parent.volumePopup != content.volumePopup || parent.pageScale != content.pageScale
                || parent.clippedBottom != content.clippedBottom
            parent = content
            if modeChanged {
                applyPageScale(to: webView)
                publishMode(to: webView)
            }
        }

        func applyPageScale(to webView: WKWebView) {
            let scale = parent.volumePopup && parent.pageScale.isFinite ? min(10, max(0.1, parent.pageScale)) : 1
            if abs(webView.pageZoom - scale) > 0.001 { webView.pageZoom = scale }
        }

        private func publishMode(to webView: WKWebView) {
            guard let url = webView.url, matchesOrigin(url), matchesPage(url) else { return }
            let clipped = parent.clippedBottom.isFinite ? parent.clippedBottom / webView.pageZoom : 0
            webView.evaluateJavaScript("""
                (() => {
                    const root = document.documentElement;
                    root.dataset.pdfVolumePopup = '\(parent.volumePopup)';
                    root.dataset.nfPdfClippedBottom = '\(clipped)';
                    if (!document.getElementById('nf-pdf-native-viewport')) {
                        const style = document.createElement('style');
                        style.id = 'nf-pdf-native-viewport';
                        style.textContent = '[data-mobile-keyboard-bar="true"] { top: auto !important; bottom: var(--nf-pdf-assistant-bottom, 0px) !important; }';
                        document.head.appendChild(style);
                        const updateBottom = () => {
                            const visual = window.visualViewport;
                            const bottom = Math.max(Number(root.dataset.nfPdfClippedBottom) || 0,
                                visual ? window.innerHeight - visual.offsetTop - visual.height : 0);
                            root.style.setProperty('--nf-pdf-assistant-bottom', bottom + 'px');
                        };
                        window.addEventListener('resize', updateBottom);
                        window.visualViewport?.addEventListener('resize', updateBottom);
                        window.visualViewport?.addEventListener('scroll', updateBottom);
                    }
                    window.dispatchEvent(new Event('resize'));
                })()
                """, completionHandler: nil)
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { decisionHandler(.cancel); return }
            if url.scheme == "nf-pdf-note", let command = url.host {
                decisionHandler(.cancel)
                if action.sourceFrame.isMainFrame, let sender = action.sourceFrame.request.url,
                   matchesOrigin(sender), matchesPage(sender) {
                    let args = url.pathComponents.dropFirst()
                    parent.action(command, args.first)
                }
                return
            }
            let allowed = matchesOrigin(url) && matchesPage(url)
            decisionHandler(allowed ? .allow : .cancel)
            if !allowed && !ready && action.targetFrame?.isMainFrame == true { unavailable(in: webView) }
        }

        func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            let status = (response.response as? HTTPURLResponse)?.statusCode ?? 0
            guard !response.isForMainFrame || (200..<300).contains(status) &&
                    response.response.url.map({ matchesOrigin($0) && matchesPage($0) }) == true else {
                decisionHandler(.cancel)
                unavailable(in: webView)
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            publishMode(to: webView)
            #if os(iOS) && !targetEnvironment(macCatalyst)
            PortalHardwareKeyboard.shared.attach(webView)
            #elseif os(macOS)
            webView.evaluateJavaScript(MacPortalWebView.hideEditingAssistantBarScript, completionHandler: nil)
            #endif
            if let url = webView.url, url.path != PDFNoteWorkspaceState.path, matchesOrigin(url), matchesPage(url) {
                webView.evaluateJavaScript(PDFPageLink.documentOnlyScript) { [weak self, weak webView] value, _ in
                    guard let self, let webView else { return }
                    ready = value as? Bool == true
                    if ready, let binding = parent.attachmentBinding,
                       webView.url?.path == "/custom/" + binding.note {
                        webView.callAsyncJavaScript(PDFPageLink.registerAttachmentScript,
                                                    arguments: ["note": binding.note, "source": binding.source],
                                                    in: nil, in: .page, completionHandler: nil)
                    } else if !ready {
                        unavailable(in: webView)
                    }
                }
                return
            }
            webView.evaluateJavaScript("Boolean(document.querySelector('[data-pdf-free-note-workspace],.pdf-free-note-workspace'))") { [weak self] value, _ in
                guard let self else { return }
                ready = value as? Bool == true
                if !ready { self.unavailable(in: webView) }
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if (error as NSError).code != NSURLErrorCancelled { unavailable(in: webView) }
        }

        private func matchesPage(_ url: URL) -> Bool {
            url.path == (triedFallback ? parent.fallback : parent.url)?.path
        }

        private func unavailable(in webView: WKWebView) {
            if let fallback = parent.fallback, !triedFallback {
                triedFallback = true
                webView.load(URLRequest(url: fallback))
                return
            }
            parent.onUnavailable()
        }

        private func matchesOrigin(_ url: URL) -> Bool {
            url.scheme == parent.origin.scheme && url.host == parent.origin.host && url.port == parent.origin.port
        }
    }
}

#if os(macOS)
extension PDFNoteWebContent: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { prepare(context.coordinator) }
    func updateNSView(_ view: WKWebView, context: Context) { context.coordinator.update(self, in: view) }
}
#else
extension PDFNoteWebContent: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { prepare(context.coordinator) }
    func updateUIView(_ view: WKWebView, context: Context) { context.coordinator.update(self, in: view) }
}
#endif
