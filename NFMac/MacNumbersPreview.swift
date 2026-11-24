import AppKit
import SwiftUI

struct MacNumbersPreview: View {
    let workbook: MacNumbersWorkbook
    let findRequest: Int
    var chartSource: URL? = nil
    var cookieHeader: String? = nil
    var onChartCreated: (URL, String) -> Void = { _, _ in }
    @State private var contents: MacNumbersContents?
    @State private var loadError: String?
    @State private var editError: String?
    @State private var sheetIndex = 0
    @State private var tableIndex = 0
    @State private var edit: MacNumbersCellEdit?
    @State private var isCreatingChart = false
    @State private var confirmsChartCreation = false
    @State private var findOpen = false
    @State private var query = ""
    @State private var matches: [MacNumbersCell] = []
    @State private var matchIndex = -1
    @State private var revealedCell: MacNumbersCell?
    @State private var revealSequence = 0
    @FocusState private var findFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if findOpen { findBar }
            if let editError {
                Text(editError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .accessibilityIdentifier("numbers.edit.error")
            }
            if let contents {
                editor(contents)
                    .allowsHitTesting(!isCreatingChart)
            } else if let loadError {
                HStack {
                    Text(loadError).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("다시 시도") {
                        self.loadError = nil
                        Task { await load() }
                    }
                }
                .padding(8)
                Divider()
                MacAttachmentQuickLookView(file: workbook.original)
            } else {
                ProgressView("Numbers 시트를 불러오는 중…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { if contents == nil && loadError == nil { await load() } }
        .onChange(of: findRequest) { _, _ in presentFind() }
        .onDisappear { _ = finishEdit() }
        .alert("NF 차트로 만들기", isPresented: $confirmsChartCreation) {
            Button("취소", role: .cancel) {}
            Button("만들기") { if let chartSource { createChart(source: chartSource) } }
        } message: {
            Text("Numbers 원본과 같은 Google Drive 폴더에 .nfchart 파일을 만듭니다. 원본은 보관되며, 이후 이 첨부를 선택하면 새 NF 차트가 열립니다.")
        }
    }

    private var findBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Numbers 문구 검색", text: $query)
                        .textFieldStyle(.plain)
                        .focused($findFocused)
                        .onSubmit { advance(backwards: false) }
                        .onKeyPress(keys: [.return]) { press in
                            guard press.modifiers.contains(.shift) else { return .ignored }
                            advance(backwards: true)
                            return .handled
                        }
                        .onExitCommand(perform: closeFind)
                        .accessibilityIdentifier("numbers.find.query")
                }
                .padding(.horizontal, 6)
                .frame(minWidth: 100, maxWidth: 300, minHeight: 24)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(findStatus).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .accessibilityIdentifier("numbers.find.status")
                }
                Spacer(minLength: 0)
                MacPDFActionButton(title: "", symbol: "chevron.up", identifier: "numbers.find.previous", accessibilityTitle: "이전 검색 결과") {
                    advance(backwards: true)
                }
                .frame(width: 22, height: 22).disabled(matches.isEmpty)
                MacPDFActionButton(title: "", symbol: "chevron.down", identifier: "numbers.find.next", accessibilityTitle: "다음 검색 결과") {
                    advance(backwards: false)
                }
                .frame(width: 22, height: 22).disabled(matches.isEmpty)
                MacPDFActionButton(title: "닫기", identifier: "numbers.find.close", accessibilityTitle: "Numbers 검색 닫기", action: closeFind)
                    .frame(width: 32, height: 22)
            }
            .padding(.horizontal, 10)
            .frame(height: 38)
            .background(Color(nsColor: .windowBackgroundColor))
            Divider()
        }
        .onChange(of: query) { _, _ in
            guard finishEdit() else { return }
            updateMatches(revealFirst: true)
        }
    }

    private var findStatus: String {
        if loadError != nil { return "시트를 읽을 수 없음" }
        if contents == nil { return "시트 불러오는 중…" }
        return matches.isEmpty ? "검색 결과 없음" : "\(matchIndex + 1)/\(matches.count)"
    }

    private func editor(_ contents: MacNumbersContents) -> some View {
        VStack(spacing: 0) {
            sheetBar(contents.sheets)
            Divider()
            if contents.sheets.indices.contains(sheetIndex) {
                sheet(contents.sheets[sheetIndex])
            } else {
                ContentUnavailableView("시트가 없습니다.", systemImage: "tablecells")
            }
        }
    }

    private func sheetBar(_ sheets: [MacNumbersSheet]) -> some View {
        HStack(spacing: 6) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                        ForEach(sheets.indices, id: \.self) { index in
                            Button {
                                selectSheet(index)
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
                }
                .onChange(of: sheetIndex) { _, index in proxy.scrollTo(index) }
            }
            if workbook.hasLocalEdits {
                MacPDFActionButton(title: "", symbol: "square.and.arrow.down", identifier: "numbers.export", accessibilityTitle: "Numbers 편집본 저장") {
                    guard finishEdit() else { return }
                    do { try workbook.exportCopy() } catch { editError = error.localizedDescription }
                }
                .frame(width: 24, height: 24)
                .help("이 Mac에 저장된 Numbers 편집본 내보내기")
            }
            if chartSource.flatMap({ MacNumbersChartFile.sourceID($0) }) != nil {
                Button(isCreatingChart ? "차트 만드는 중…" : "NF 차트로 만들기") {
                    confirmsChartCreation = true
                }
                .disabled(isCreatingChart)
                .accessibilityIdentifier("numbers.createChart")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
    }

    private func sheet(_ sheet: MacNumbersSheet) -> some View {
        VStack(spacing: 0) {
            if sheet.tables.count > 1 {
                Picker("표", selection: Binding(
                    get: { tableIndex },
                    set: {
                        guard finishEdit() else { return }
                        tableIndex = $0
                        revealedCell = nil
                    }
                )) {
                    ForEach(sheet.tables.indices, id: \.self) { index in
                        Text(sheet.tables[index].name).tag(index)
                    }
                }
                .frame(maxWidth: 320)
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                Divider()
            }
            if sheet.tables.indices.contains(tableIndex) {
                MacNumbersGrid(
                    table: sheet.tables[tableIndex],
                    revealedCell: revealedCell,
                    revealSequence: revealSequence,
                    edit: edit,
                    onBeginEdit: beginEdit,
                    onFinishEdit: finishEdit,
                    onCancelEdit: cancelEdit,
                    onFind: presentFind,
                    onFindNext: advance
                )
                .id(MacNumbersCell(sheet: sheetIndex, table: tableIndex, row: 0, column: 0))
            } else {
                ContentUnavailableView("이 시트에 표가 없습니다.", systemImage: "tablecells")
            }
        }
    }

    private func load() async {
        await Task.yield()
        guard !Task.isCancelled else { return }
        do {
            contents = try workbook.read()
            updateMatches(revealFirst: true)
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func createChart(source: URL) {
        guard !isCreatingChart, finishEdit(), let contents else { return }
        isCreatingChart = true
        editError = nil
        Task {
            defer { isCreatingChart = false }
            do {
                let (url, name) = try await MacNumbersChartFile.create(source: source, cookie: cookieHeader, contents: contents)
                onChartCreated(url, name)
            } catch {
                editError = error.localizedDescription
            }
        }
    }

    private func selectSheet(_ index: Int) {
        guard index != sheetIndex, finishEdit() else { return }
        sheetIndex = index
        tableIndex = 0
        revealedCell = nil
    }

    private func beginEdit(row: Int, column: Int) -> MacNumbersCellEdit? {
        guard finishEdit(), let contents, contents.sheets.indices.contains(sheetIndex),
              contents.sheets[sheetIndex].tables.indices.contains(tableIndex) else { return nil }
        guard !contents.sheets[sheetIndex].tables[tableIndex].locked else {
            editError = "잠긴 표의 셀은 편집할 수 없습니다."
            return nil
        }
        let cell = MacNumbersCell(sheet: sheetIndex, table: tableIndex, row: row, column: column)
        do {
            let draft = MacNumbersCellEdit(cell: cell, original: try workbook.readCell(cell))
            edit = draft
            editError = nil
            return draft
        } catch {
            editError = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    private func finishEdit() -> Bool {
        guard let edit else { return true }
        do {
            if edit.value != edit.original {
                contents = try workbook.edit(edit.cell, from: edit.original, to: edit.value)
                updateMatches(revealFirst: false)
            }
            cancelEdit()
            return true
        } catch {
            editError = error.localizedDescription
            return false
        }
    }

    private func cancelEdit() {
        edit = nil
        editError = nil
    }

    private func presentFind() {
        guard finishEdit() else { return }
        findOpen = true
        findFocused = true
        updateMatches(revealFirst: true)
    }

    private func closeFind() {
        findFocused = false
        findOpen = false
        query = ""
        updateMatches(revealFirst: false)
    }

    private func updateMatches(revealFirst: Bool) {
        let current = matches.indices.contains(matchIndex) ? matches[matchIndex] : nil
        matches = contents?.matches(query) ?? []
        matchIndex = matches.isEmpty ? -1 : (revealFirst ? 0 : current.flatMap { matches.firstIndex(of: $0) } ?? 0)
        if revealFirst, let first = matches.first {
            reveal(first)
        } else if revealFirst || !findOpen {
            revealedCell = nil
        }
    }

    private func advance(backwards: Bool) {
        guard finishEdit() else { return }
        guard findOpen else { presentFind(); return }
        guard !matches.isEmpty else { return }
        matchIndex = (matchIndex + (backwards ? -1 : 1) + matches.count) % matches.count
        reveal(matches[matchIndex])
    }

    private func reveal(_ cell: MacNumbersCell) {
        sheetIndex = cell.sheet
        tableIndex = cell.table
        revealedCell = cell
        revealSequence &+= 1
    }
}
