import AppKit
import SwiftUI

struct MacExcelSearchPreview: View {
    let file: MacAttachmentQuickLookFile
    let findRequest: Int

    @State private var isSearching = false
    @State private var workbook: MacNumbersContents?
    @State private var loadError: String?
    @State private var sheetIndex = 0
    @State private var query = ""
    @State private var resolvedQuery = ""
    @State private var matches: [MacNumbersCell] = []
    @State private var matchIndex = 0
    @State private var revealedCell: MacNumbersCell?
    @State private var revealSequence = 0
    @FocusState private var searchFocused: Bool

    var body: some View {
        Group {
            if isSearching {
                VStack(spacing: 0) {
                    if let workbook { sheetBar(workbook.sheets) }
                    searchBar
                    if let workbook {
                        let table = workbook.sheets[sheetIndex].tables[0]
                        if table.rowCount == 0 {
                            ContentUnavailableView("빈 시트입니다", systemImage: "tablecells")
                        } else {
                            MacNumbersGrid(
                                table: table, revealedCell: revealedCell, revealSequence: revealSequence,
                                edit: nil, onBeginEdit: { _, _ in nil }, onFinishEdit: { true }, onCancelEdit: {},
                                onFind: openSearch, onFindNext: advance, accessibilityID: "excel.find.grid"
                            )
                            .id(sheetIndex)
                        }
                    } else if let loadError {
                        ContentUnavailableView("Excel 검색을 열 수 없습니다", systemImage: "magnifyingglass", description: Text(loadError))
                    } else {
                        ProgressView("Excel 시트를 읽는 중…")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .task { if workbook == nil { await loadWorkbook() } }
                .task(id: query) { await updateMatches() }
            } else {
                MacAttachmentQuickLookView(file: file)
            }
        }
        .onChange(of: findRequest) { _, _ in openSearch() }
    }

    private func sheetBar(_ sheets: [MacNumbersSheet]) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    ForEach(sheets.indices, id: \.self) { index in
                        Button {
                            sheetIndex = index
                            revealedCell = nil
                        } label: {
                            Text(sheets[index].name)
                                .lineLimit(1)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(index == sheetIndex ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 5))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(index == sheetIndex ? .isSelected : [])
                        .id(index)
                    }
                }
                .padding(.horizontal, 8)
            }
            .frame(height: 34)
            .onChange(of: sheetIndex) { _, index in proxy.scrollTo(index) }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("전체 시트에서 셀 검색", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { advance(backwards: false) }
                    .onKeyPress(keys: [.return]) { press in
                        guard press.modifiers.contains(.shift) else { return .ignored }
                        advance(backwards: true)
                        return .handled
                    }
                    .accessibilityIdentifier("excel.find.query")
            }
            .padding(.horizontal, 8)
            .frame(minWidth: 100, maxWidth: 300, minHeight: 24)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
            if !searchTerm.isEmpty, workbook != nil {
                Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .accessibilityIdentifier("excel.find.status")
            }
            Spacer(minLength: 0)
            MacPDFActionButton(title: "", symbol: "chevron.up", identifier: "excel.find.previous", accessibilityTitle: "이전 검색 결과") {
                advance(backwards: true)
            }
            .frame(width: 22, height: 22).disabled(!hasResults)
            MacPDFActionButton(title: "", symbol: "chevron.down", identifier: "excel.find.next", accessibilityTitle: "다음 검색 결과") {
                advance(backwards: false)
            }
            .frame(width: 22, height: 22).disabled(!hasResults)
            MacPDFActionButton(title: "", symbol: "xmark", identifier: "excel.find.close", accessibilityTitle: "Excel 검색 닫기") {
                isSearching = false
            }
            .frame(width: 22, height: 22)
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .overlay(alignment: .bottom) { Divider() }
        .onAppear { searchFocused = true }
    }

    private var searchTerm: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var hasResults: Bool { resolvedQuery == searchTerm && !matches.isEmpty }

    private var status: String {
        guard resolvedQuery == searchTerm else { return "검색 중…" }
        guard hasResults else { return "검색 결과 없음" }
        let cell = matches[matchIndex]
        let sheet = workbook?.sheets[cell.sheet].name ?? ""
        return "\(matchIndex + 1)/\(matches.count) · \(sheet)!\(cell.address)"
    }

    private func openSearch() {
        isSearching = true
        searchFocused = true
    }

    private func loadWorkbook() async {
        loadError = nil
        let url = file.url
        let worker = Task.detached(priority: .userInitiated) { try MacExcelWorkbook.read(url) }
        do {
            let source = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            try Task.checkCancellation()
            workbook = source
            await updateMatches()
        } catch {
            if !Task.isCancelled { loadError = error.localizedDescription }
        }
    }

    private func updateMatches() async {
        let term = searchTerm
        if term.isEmpty {
            resolvedQuery = ""
            matches = []
            revealedCell = nil
            return
        }
        guard let workbook else { return }
        do {
            try await Task.sleep(for: .milliseconds(120))
            let worker = Task.detached(priority: .userInitiated) { workbook.matches(term) }
            let results = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            try Task.checkCancellation()
            guard searchTerm == term else { return }
            resolvedQuery = term
            matches = results
            matchIndex = 0
            revealMatch()
        } catch { /* A new query or closing the search supersedes this task. */ }
    }

    private func advance(backwards: Bool) {
        guard hasResults else { return }
        matchIndex = (matchIndex + (backwards ? -1 : 1) + matches.count) % matches.count
        revealMatch()
    }

    private func revealMatch() {
        revealedCell = matches.indices.contains(matchIndex) ? matches[matchIndex] : nil
        if let revealedCell {
            sheetIndex = revealedCell.sheet
            revealSequence &+= 1
        }
    }
}
