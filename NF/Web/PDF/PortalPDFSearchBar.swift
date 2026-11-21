import PDFKit
import SwiftUI

/// Search selections are display-only and are never added to the PDF or its undo history.
struct PortalPDFSearchBar: View {
    let document: PDFDocument
    let canvas: () -> PDFView?
    let onClose: () -> Void
    @Environment(\.portalAppTheme) private var theme
    @FocusState private var focused: Bool
    @State private var query = ""
    @State private var matches: [PDFSelection] = []
    @State private var selected = 0
    @State private var searching = false
    private let limit = 5_000

    private var term: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        HStack(spacing: 8) {
            TextField("PDF 문구 검색", text: $query)
                .focused($focused)
                .submitLabel(.search)
                .onSubmit { move(1) }
                .onKeyPress(.escape) { onClose(); return .handled }
                .accessibilityIdentifier("pdf.find.query")
            if !term.isEmpty {
                Text(searching ? "검색 중…" : matches.isEmpty ? "0건" : "\(selected + 1)/\(matches.count)\(matches.count == limit ? "+" : "")")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(theme.mutedColor)
                    .accessibilityLabel(searching ? "검색 중" : "검색 결과 \(matches.count)개")
            }
            Button { move(-1) } label: { Image(systemName: "chevron.up") }
                .accessibilityLabel("이전 검색 결과")
                .disabled(matches.isEmpty)
            Button { move(1) } label: { Image(systemName: "chevron.down") }
                .accessibilityLabel("다음 검색 결과")
                .disabled(matches.isEmpty)
            Button(action: onClose) { Image(systemName: "xmark") }
                .accessibilityLabel("PDF 문구 검색 닫기")
        }
        .padding(12)
        .foregroundStyle(theme.foregroundColor)
        .background(theme.surfaceColor, in: RoundedRectangle(cornerRadius: 10))
        .shadow(radius: 4)
        .onAppear { focused = true }
        .task(id: term) { await search(term) }
        .onDisappear { canvas()?.highlightedSelections = nil }
    }

    @MainActor private func search(_ needle: String) async {
        matches = []
        selected = 0
        canvas()?.highlightedSelections = nil
        searching = !needle.isEmpty
        guard !needle.isEmpty else { return }
        do { try await Task.sleep(for: .milliseconds(180)) } catch { return }

        var found: [PDFSelection] = []
        for index in 0..<document.pageCount {
            guard !Task.isCancelled else { return }
            guard let page = document.page(at: index) else { continue }
            let text = (page.string ?? "") as NSString
            var offset = 0
            while offset < text.length && found.count < limit {
                let range = text.range(of: needle, options: .caseInsensitive,
                                       range: NSRange(location: offset, length: text.length - offset))
                guard range.location != NSNotFound, range.length > 0 else { break }
                if let selection = page.selection(for: range) { found.append(selection) }
                offset = NSMaxRange(range)
            }
            if found.count == limit { break }
            await Task.yield()
        }
        guard !Task.isCancelled else { return }
        matches = found
        searching = false
        if !matches.isEmpty { showSelection() }
    }

    private func move(_ delta: Int) {
        guard !matches.isEmpty else { return }
        selected = (selected + delta + matches.count) % matches.count
        showSelection()
    }

    private func showSelection() {
        guard let viewer = canvas(), viewer.document === document, matches.indices.contains(selected) else { return }
        viewer.highlightedSelections = matches.enumerated().map { index, selection in
            selection.color = index == selected ? .systemOrange : .systemYellow.withAlphaComponent(0.38)
            return selection
        }
        viewer.go(to: matches[selected])
    }
}
