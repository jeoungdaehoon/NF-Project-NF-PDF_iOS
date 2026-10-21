import AppKit
import Combine
import PDFKit
import SwiftUI

/// View-only, cancellable search. Never inserts PDF annotations or edit history.
@MainActor
final class MacPDFFindState: ObservableObject {
    struct Match {
        let page: Int
        let selection: PDFSelection?
        let objectID: UUID?
    }
    @Published private(set) var isPresented = false
    @Published private(set) var query = ""
    @Published private(set) var isSearching = false
    @Published private(set) var matches: [Match] = []
    @Published private(set) var currentIndex = -1
    @Published private(set) var isLimited = false
    @Published private(set) var hasSearchableText = true
    @Published private(set) var focusRequest = 0
    weak var field: NSSearchField?
    private weak var editor: MacPDFEditorState?
    private var task: Task<Void, Never>?
    private var generation = 0
    private var searchSelection: PDFSelection?
    static let resultLimit = 5_000

    init(editor: MacPDFEditorState) { self.editor = editor }
    deinit { task?.cancel() }

    var status: String {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "" }
        if isSearching { return "검색 중…" }
        if matches.isEmpty { return hasSearchableText ? "검색 결과 없음" : "텍스트 없음" }
        let count = "\(matches.count)\(isLimited ? "+" : "")"
        return currentIndex >= 0 ? "\(currentIndex + 1)/\(count)" : "\(count)개"
    }
    var currentObject: MacPDFObject? {
        guard isPresented, matches.indices.contains(currentIndex), let id = matches[currentIndex].objectID else { return nil }
        return editor?.objects.first { $0.id == id }
    }
    func present() {
        editor?.canvas?.finishTextEditing()
        if !isPresented { isPresented = true; schedule() }
        focusRequest &+= 1
    }
    func updateQuery(_ value: String, composing: Bool = false) {
        query = value
        schedule(composing: composing)
    }
    func refresh() { if isPresented { schedule(navigate: false) } }
    func dismiss(restoreFocus: Bool = true) {
        generation &+= 1; task?.cancel(); task = nil
        isPresented = false; isSearching = false; matches = []; currentIndex = -1; isLimited = false
        clearHighlights()
        if restoreFocus, let canvas = editor?.canvas { canvas.window?.makeFirstResponder(canvas) }
    }
    private func clearHighlights() {
        guard let canvas = editor?.canvas else { return }
        canvas.highlightedSelections = nil
        if let searchSelection, canvas.currentSelection === searchSelection { canvas.clearSelection() }
        searchSelection = nil
        canvas.updateInteractionOverlay()
    }
    private func schedule(composing: Bool = false, navigate: Bool = true) {
        generation &+= 1; let version = generation
        task?.cancel(); task = nil
        matches = []; currentIndex = -1; isLimited = false; clearHighlights()
        let needle = query
        guard isPresented, !needle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !composing, let editor else {
            isSearching = false; return
        }
        isSearching = true
        // PDFKit's page/selection objects stay on the main actor. Yield between
        // pages and batches instead of concurrently reading the displayed PDF.
        task = Task { [weak self, weak editor] in
            do { try await Task.sleep(for: .milliseconds(160)) } catch { return }
            guard let self, let editor, !Task.isCancelled, self.generation == version else { return }
            let document = editor.document
            var found: [Match] = [], hasText = false, limited = false
            for pageIndex in 0..<document.pageCount {
                guard !Task.isCancelled, self.generation == version, editor.document === document else { return }
                guard let page = document.page(at: pageIndex) else { continue }
                let text = (page.string ?? "") as NSString
                hasText = hasText || text.length > 0
                var offset = 0
                while offset < text.length {
                    let range = text.range(of: needle, options: .caseInsensitive, range: NSRange(location: offset, length: text.length - offset))
                    guard range.location != NSNotFound, range.length > 0 else { break }
                    if let selection = page.selection(for: range) { found.append(Match(page: pageIndex, selection: selection, objectID: nil)) }
                    offset = NSMaxRange(range)
                    if found.count >= Self.resultLimit { limited = true; break }
                    if found.count.isMultiple(of: 100) { await Task.yield(); if Task.isCancelled || self.generation != version { return } }
                }
                if limited { break }
                for object in editor.pageObjects(pageIndex) where !object.isTransient && !object.text.isEmpty {
                    hasText = true
                    let text = object.text as NSString
                    var offset = 0
                    while offset < text.length {
                        let range = text.range(of: needle, options: .caseInsensitive, range: NSRange(location: offset, length: text.length - offset))
                        guard range.location != NSNotFound, range.length > 0 else { break }
                        found.append(Match(page: pageIndex, selection: nil, objectID: object.id))
                        offset = NSMaxRange(range)
                        if found.count >= Self.resultLimit { limited = true; break }
                        if found.count.isMultiple(of: 100) { await Task.yield(); if Task.isCancelled || self.generation != version { return } }
                    }
                    if limited { break }
                }
                if limited { break }
                await Task.yield()
            }
            guard !Task.isCancelled, self.generation == version, editor.document === document, self.isPresented else { return }
            self.matches = found; self.isLimited = limited; self.hasSearchableText = hasText; self.isSearching = false
            if navigate, let index = found.firstIndex(where: { $0.page >= editor.currentPage }) ?? (found.isEmpty ? nil : 0) { self.activate(index) }
            else { self.highlight() }
        }
    }
    func advance(backwards: Bool = false) {
        guard !isSearching, !matches.isEmpty else { return }
        let next = currentIndex < 0 ? (backwards ? matches.count - 1 : 0) : (currentIndex + (backwards ? -1 : 1) + matches.count) % matches.count
        activate(next)
    }
    private func activate(_ index: Int) {
        guard matches.indices.contains(index), let editor, let canvas = editor.canvas else { return }
        canvas.finishTextEditing()
        currentIndex = index
        editor.selection = []; editor.menuVisible = false
        let match = matches[index]
        if let selection = match.selection {
            canvas.setCurrentSelection(selection, animate: false)
            searchSelection = canvas.currentSelection
            canvas.go(to: selection)
        } else if let object = currentObject, let page = editor.document.page(at: object.page) {
            canvas.clearSelection(); searchSelection = nil
            canvas.go(to: object.bounds.insetBy(dx: -16, dy: -16), on: page)
        }
        highlight()
    }
    private func highlight() {
        editor?.canvas?.highlightedSelections = matches.enumerated().compactMap { index, match in
            guard let selection = match.selection?.copy() as? PDFSelection else { return nil }
            selection.color = (index == currentIndex ? NSColor.systemOrange : .systemYellow).withAlphaComponent(0.45)
            return selection
        }
        editor?.canvas?.updateInteractionOverlay()
    }
    /// Only the PDF canvas, its inline text editor or THIS search field owns
    /// these shortcuts. Never steal Find from the other split WKWebView.
    func handleKey(_ event: NSEvent, canvas: MacPDFEditingView) -> Bool {
        guard let window = canvas.window, event.window === window, window.isKeyWindow,
              !canvas.isHiddenOrHasHiddenAncestor else { return false }
        let responder = window.firstResponder
        let canvasFocused = (responder as? NSView).map { $0 === canvas || $0.isDescendant(of: canvas) } ?? false
        let fieldFocused = field?.currentEditor() != nil && responder === field?.currentEditor()
        guard canvasFocused || fieldFocused else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let nonLatin = key.unicodeScalars.contains { !$0.isASCII }
        if flags.contains(.command), !flags.contains(.control), !flags.contains(.option) {
            if key == "f" || nonLatin && event.keyCode == 3 { present(); return true }
            if isPresented, key == "g" || nonLatin && event.keyCode == 5 { advance(backwards: flags.contains(.shift)); return true }
        }
        if isPresented, event.keyCode == 53 { dismiss(); return true }
        return false
    }
}

struct MacPDFFindButton: View {
    @ObservedObject var find: MacPDFFindState
    var body: some View {
        MacPDFActionButton(title: "", symbol: "magnifyingglass", identifier: "pdf.find", accessibilityTitle: "PDF 문구 검색 ⌘F") { find.present() }
            .frame(width: 22, height: 22).help("PDF 문구 검색 ⌘F")
    }
}

struct MacPDFFindBar: View {
    @ObservedObject var find: MacPDFFindState
    var body: some View {
        if find.isPresented {
            HStack(spacing: 8) {
                MacPDFFindField(find: find).frame(minWidth: 100, maxWidth: 300, minHeight: 24)
                if find.isSearching { ProgressView().controlSize(.small).frame(width: 16) }
                Text(find.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .accessibilityIdentifier("pdf.find.status")
                    .help(find.status == "텍스트 없음" ? "이미지·스캔 PDF는 텍스트 인식(OCR) 후 검색할 수 있습니다." : find.status)
                Spacer(minLength: 0)
                MacPDFActionButton(title: "", symbol: "chevron.up", identifier: "pdf.find.previous", accessibilityTitle: "이전 검색 결과 ⇧Return") { find.advance(backwards: true) }
                    .frame(width: 22, height: 22).disabled(find.isSearching || find.matches.isEmpty)
                MacPDFActionButton(title: "", symbol: "chevron.down", identifier: "pdf.find.next", accessibilityTitle: "다음 검색 결과 Return") { find.advance() }
                    .frame(width: 22, height: 22).disabled(find.isSearching || find.matches.isEmpty)
                MacPDFActionButton(title: "닫기", identifier: "pdf.find.close", accessibilityTitle: "PDF 검색 닫기 Escape") { find.dismiss() }
                    .frame(width: 32, height: 22)
            }
            .padding(.horizontal, 10).frame(height: 38)
            .background(Color(nsColor: .windowBackgroundColor))
            Divider()
        }
    }
}

private struct MacPDFFindField: NSViewRepresentable {
    @ObservedObject var find: MacPDFFindState
    func makeCoordinator() -> Coordinator { Coordinator(find: find) }
    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField(); field.placeholderString = "PDF 문구 검색"
        field.sendsSearchStringImmediately = true; field.sendsWholeSearchString = false
        field.delegate = context.coordinator; field.target = context.coordinator; field.action = #selector(Coordinator.changed(_:))
        field.identifier = NSUserInterfaceItemIdentifier("pdf.find.query"); field.setAccessibilityIdentifier("pdf.find.query"); field.setAccessibilityLabel("PDF 문구 검색")
        find.field = field
        return field
    }
    func updateNSView(_ field: NSSearchField, context: Context) {
        find.field = field
        if field.stringValue != find.query, (field.currentEditor() as? NSTextView)?.hasMarkedText() != true { field.stringValue = find.query }
        guard context.coordinator.focusRequest != find.focusRequest else { return }
        context.coordinator.focusRequest = find.focusRequest
        DispatchQueue.main.async { [weak field, weak find] in
            guard let field, let find, find.isPresented, let window = field.window else { return }
            window.makeFirstResponder(field); field.selectText(nil)
        }
    }
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        let find: MacPDFFindState
        var focusRequest = -1
        init(find: MacPDFFindState) { self.find = find }
        func controlTextDidChange(_ notification: Notification) { if let field = notification.object as? NSSearchField { changed(field) } }
        @objc func changed(_ field: NSSearchField) {
            find.updateQuery(field.stringValue, composing: (field.currentEditor() as? NSTextView)?.hasMarkedText() == true)
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) { find.advance(backwards: NSApp.currentEvent?.modifierFlags.contains(.shift) == true); return true }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) { find.dismiss(); return true }
            return false
        }
    }
}
