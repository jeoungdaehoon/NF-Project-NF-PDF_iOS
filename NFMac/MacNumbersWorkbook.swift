import AppKit
import Carbon
import CryptoKit
import UniformTypeIdentifiers

struct MacNumbersCell: Hashable {
    let sheet: Int
    let table: Int
    let row: Int
    let column: Int

    var address: String { MacCSVDocument.columnTitle(column) + String(row + 1) }
}

struct MacNumbersTable {
    let name: String
    let rowCount: Int
    let columnCount: Int
    let headerRows: Int
    let locked: Bool
    let values: [Int: String]

    func value(row: Int, column: Int) -> String {
        values[row * columnCount + column] ?? ""
    }
}

struct MacNumbersSheet {
    let name: String
    let tables: [MacNumbersTable]
}

struct MacNumbersContents {
    let sheets: [MacNumbersSheet]

    func matches(_ query: String) -> [MacNumbersCell] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return sheets.enumerated().flatMap { sheet, item in
            item.tables.enumerated().flatMap { table, grid in
                grid.values.compactMap { index, value in
                    value.localizedCaseInsensitiveContains(query) ? index : nil
                }.sorted().map { index in
                    MacNumbersCell(sheet: sheet, table: table, row: index / grid.columnCount, column: index % grid.columnCount)
                }
            }
        }
    }
}

/// Numbers reads and writes an isolated copy. Publish the new bytes only after
/// Numbers has saved and the updated sheet contents have been read successfully.
@MainActor
struct MacNumbersWorkbook {
    static let bundleID = "com.apple.iWork.Numbers"
    let original: MacAttachmentQuickLookFile
    let localURL: URL

    init(original: MacAttachmentQuickLookFile, source: URL, data: Data) {
        self.original = original
        var digest = SHA256()
        digest.update(data: Data(source.absoluteString.utf8))
        digest.update(data: data)
        let key = digest.finalize().map { String(format: "%02x", $0) }.joined()
        localURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NF/NumbersEdits", isDirectory: true)
            .appendingPathComponent(key, isDirectory: true)
            .appendingPathComponent(original.url.lastPathComponent)
    }

    var hasLocalEdits: Bool { FileManager.default.fileExists(atPath: localURL.path) }
    private var currentURL: URL { hasLocalEdits ? localURL : original.url }

    func read() throws -> MacNumbersContents {
        try withCopy { url in try Self.decode(Self.run("readWorkbook", url: url)) }
    }

    func readCell(_ cell: MacNumbersCell) throws -> String {
        try withCopy { url in
            try Self.run("readCell", url: url, cell: cell).stringValue ?? ""
        }
    }

    func edit(_ cell: MacNumbersCell, from previous: String, to value: String) throws -> MacNumbersContents {
        try withCopy { url in
            let result = try Self.run("editWorkbook", url: url, cell: cell, text: [previous, value])
            let contents = try Self.decode(result)
            let bytes = try Data(contentsOf: url)
            try FileManager.default.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: localURL, options: .atomic)
            return contents
        }
    }

    func exportCopy() throws {
        let panel = NSSavePanel()
        panel.title = "Numbers 편집본 저장"
        panel.nameFieldStringValue = localURL.lastPathComponent
        if let type = UTType(filenameExtension: "numbers") { panel.allowedContentTypes = [type] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try Data(contentsOf: currentURL).write(to: url, options: .atomic)
    }

    private func withCopy<T>(_ perform: (URL) throws -> T) throws -> T {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) != nil else {
            throw Self.failure("셀을 편집하고 검색하려면 이 Mac에 Numbers 앱이 설치되어 있어야 합니다.")
        }
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: directory) }
        let url = directory.appendingPathComponent(original.url.lastPathComponent)
        try manager.copyItem(at: currentURL, to: url)
        return try perform(url)
    }

    private static func run(
        _ handler: String,
        url: URL,
        cell: MacNumbersCell? = nil,
        text: [String] = []
    ) throws -> NSAppleEventDescriptor {
        guard let script = NSAppleScript(source: source) else { throw failure("Numbers 연결을 준비하지 못했습니다.") }
        let args = NSAppleEventDescriptor.list()
        args.insert(NSAppleEventDescriptor(fileURL: url), at: 1)
        if let cell {
            args.insert(NSAppleEventDescriptor(int32: Int32(cell.sheet + 1)), at: 2)
            args.insert(NSAppleEventDescriptor(int32: Int32(cell.table + 1)), at: 3)
            args.insert(NSAppleEventDescriptor(string: cell.address), at: 4)
        }
        for value in text {
            args.insert(NSAppleEventDescriptor(string: value), at: args.numberOfItems + 1)
        }
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kASAppleScriptSuite),
            eventID: AEEventID(kASSubroutineEvent),
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(NSAppleEventDescriptor(string: handler.lowercased()), forKeyword: AEKeyword(keyASSubroutineName))
        event.setParam(args, forKeyword: AEKeyword(keyDirectObject))
        var error: NSDictionary?
        let result = script.executeAppleEvent(event, error: &error)
        if let error {
            if (error[NSAppleScript.errorNumber] as? Int) == -1743 {
                throw failure("시스템 설정 → 개인정보 보호 및 보안 → 자동화에서 NF의 Numbers 접근을 허용해 주세요.")
            }
            throw failure(error[NSAppleScript.errorMessage] as? String ?? "Numbers 문서를 처리하지 못했습니다.")
        }
        return result
    }

    private static func decode(_ result: NSAppleEventDescriptor) throws -> MacNumbersContents {
        let sheets = try items(result).map { sheet in
            let fields = try items(sheet)
            guard fields.count == 2, let name = fields[0].stringValue else { throw invalidWorkbook() }
            let tables = try items(fields[1]).map { table in
                let fields = try items(table)
                guard fields.count == 6, let name = fields[0].stringValue else { throw invalidWorkbook() }
                let rows = Int(fields[1].int32Value)
                let columns = Int(fields[2].int32Value)
                let cells = try items(fields[5])
                guard rows >= 0, columns > 0, cells.count == rows * columns else { throw invalidWorkbook() }
                var values: [Int: String] = [:]
                for (index, cell) in cells.enumerated() where cell.descriptorType != DescType(cMissingValue) {
                    if let value = cell.stringValue, !value.isEmpty { values[index] = value }
                }
                return MacNumbersTable(
                    name: name, rowCount: rows, columnCount: columns,
                    headerRows: Int(fields[3].int32Value), locked: fields[4].booleanValue, values: values
                )
            }
            return MacNumbersSheet(name: name, tables: tables)
        }
        return MacNumbersContents(sheets: sheets)
    }

    private static func items(_ list: NSAppleEventDescriptor) throws -> [NSAppleEventDescriptor] {
        guard list.descriptorType == DescType(typeAEList) else { throw invalidWorkbook() }
        return try (0..<list.numberOfItems).map { index in
            guard let item = list.atIndex(index + 1) else { throw invalidWorkbook() }
            return item
        }
    }

    private static func invalidWorkbook() -> NSError { failure("Numbers에서 시트의 셀 데이터를 읽지 못했습니다.") }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "NF.Numbers", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    // Arguments are passed as Apple event descriptors. File paths and cell
    // contents never become AppleScript source.
    private static let source = """
    on readWorkbook(targetFile)
        return my processWorkbook(targetFile, "read", 0, 0, "", "", "")
    end readWorkbook

    on readCell(targetFile, sheetIndex, tableIndex, cellAddressArg)
        return my processWorkbook(targetFile, "cell", sheetIndex, tableIndex, cellAddressArg, "", "")
    end readCell

    on editWorkbook(targetFile, sheetIndex, tableIndex, cellAddressArg, previousText, newText)
        return my processWorkbook(targetFile, "edit", sheetIndex, tableIndex, cellAddressArg, previousText, newText)
    end editWorkbook

    on processWorkbook(targetFile, operation, sheetIndex, tableIndex, cellAddressArg, previousText, newText)
        tell application id "com.apple.iWork.Numbers"
            with timeout of 20 seconds
                set book to open targetFile
                try
                    if operation is "read" then
                        set resultValue to my snapshot(book)
                    else
                        set targetTable to table tableIndex of sheet sheetIndex of book
                        set targetCell to cell cellAddressArg of targetTable
                        set cellInput to my editableText(targetCell)
                        if operation is "cell" then
                            set resultValue to cellInput
                        else
                            if locked of targetTable then error "잠긴 표의 셀은 편집할 수 없습니다."
                            considering case
                                if cellInput is not previousText then error "셀이 변경되었습니다. 문서를 다시 열고 편집해 주세요."
                            end considering
                            set value of targetCell to newText
                            save book
                            set resultValue to my snapshot(book)
                        end if
                    end if
                    close book saving no
                    return resultValue
                on error problem number code
                    try
                        close book saving no
                    end try
                    error problem number code
                end try
            end timeout
        end tell
    end processWorkbook

    on editableText(targetCell)
        tell application id "com.apple.iWork.Numbers"
            set cellFormula to formula of targetCell
            if cellFormula is not missing value then return cellFormula
            set cellValue to value of targetCell
            if cellValue is missing value then return ""
            return cellValue as text
        end tell
    end editableText

    on snapshot(book)
        tell application id "com.apple.iWork.Numbers"
            set allSheets to {}
            repeat with currentSheet in (get every sheet of book)
                set allTables to {}
                repeat with currentTable in (get every table of currentSheet)
                    set cellValues to formatted value of every cell of currentTable
                    set end of allTables to {name of currentTable, row count of currentTable, column count of currentTable, header row count of currentTable, locked of currentTable, cellValues}
                end repeat
                set end of allSheets to {name of currentSheet, allTables}
            end repeat
            return allSheets
        end tell
    end snapshot
    """
}
