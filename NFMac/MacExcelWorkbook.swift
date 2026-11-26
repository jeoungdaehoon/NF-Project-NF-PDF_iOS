import Foundation
import zlib

/// Read worksheet values from the downloaded OOXML attachment. Search never launches Excel
/// or expands archive paths onto disk.
nonisolated enum MacExcelWorkbook {
    enum ReadError: LocalizedError {
        case format
        case limit

        var errorDescription: String? {
            switch self {
            case .format: "이 Excel 파일의 시트 내용을 읽을 수 없습니다."
            case .limit: "이 Excel 파일은 검색 미리보기에서 지원하는 크기를 초과합니다."
            }
        }
    }

    static func read(_ url: URL) throws -> MacNumbersContents {
        var archive = try MacExcelArchive(Data(contentsOf: url, options: .mappedIfSafe))
        let workbook = try xml(archive.read("xl/workbook.xml")).rootElement()
        let relationshipFile = try xml(archive.read("xl/_rels/workbook.xml.rels")).rootElement()
        var sheets: [String: String] = [:]
        var stringPath: String?
        for relation in children(relationshipFile, "Relationship") {
            guard attribute(relation, "TargetMode") != "External",
                  let id = attribute(relation, "Id"),
                  let target = attribute(relation, "Target"),
                  let path = partPath(target),
                  let type = attribute(relation, "Type") else { continue }
            if type.hasSuffix("/worksheet") { sheets[id] = path }
            if type.hasSuffix("/sharedStrings") { stringPath = path }
        }
        let strings: [String]
        if let stringPath {
            let root = try xml(archive.read(stringPath)).rootElement()
            strings = children(root, "si").map(cellText)
        } else {
            strings = []
        }
        let worksheets = children(child(workbook, "sheets"), "sheet")
        guard worksheets.count <= 512 else { throw ReadError.limit }
        var cellsRemaining = 500_000
        let result = try worksheets.compactMap { sheet -> MacNumbersSheet? in
            try Task.checkCancellation()
            guard let id = sheet.attributes?.first(where: { $0.localName == "id" })?.stringValue,
                  let path = sheets[id], let name = attribute(sheet, "name") else { return nil }
            let root = try xml(archive.read(path)).rootElement()
            let table = try readTable(child(root, "sheetData"), name: name, strings: strings, cellsRemaining: &cellsRemaining)
            return MacNumbersSheet(name: name, tables: [table])
        }
        guard !result.isEmpty else { throw ReadError.format }
        return MacNumbersContents(sheets: result)
    }

    private static func readTable(_ data: XMLElement?, name: String, strings: [String], cellsRemaining: inout Int) throws -> MacNumbersTable {
        let columnLimit = 512
        var entries: [(row: Int, column: Int, value: String)] = []
        var rowCount = 0, columnCount = 1, nextRow = 0
        for row in children(data, "row") {
            try Task.checkCancellation()
            let rowIndex = attribute(row, "r").flatMap(Int.init).map { max(1, $0) - 1 } ?? nextRow
            guard (0..<1_048_576).contains(rowIndex) else { throw ReadError.format }
            nextRow = rowIndex + 1
            var nextColumn = 0
            for cell in children(row, "c") {
                let column = attribute(cell, "r").flatMap(columnIndex) ?? nextColumn
                guard (0..<16_384).contains(column) else { throw ReadError.format }
                nextColumn = column + 1
                let value = try displayValue(cell, strings: strings)
                if value.isEmpty { continue }
                guard rowIndex < 100_000, column < columnLimit, cellsRemaining > 0 else { throw ReadError.limit }
                cellsRemaining -= 1
                entries.append((rowIndex, column, value))
                rowCount = max(rowCount, rowIndex + 1)
                columnCount = max(columnCount, column + 1)
            }
        }
        var values: [Int: String] = [:]
        values.reserveCapacity(entries.count)
        for entry in entries { values[entry.row * columnCount + entry.column] = entry.value }
        return MacNumbersTable(name: name, rowCount: rowCount, columnCount: columnCount, headerRows: 0, locked: true, values: values)
    }

    private static func displayValue(_ cell: XMLElement, strings: [String]) throws -> String {
        let value = child(cell, "v")?.stringValue ?? ""
        switch attribute(cell, "t") {
        case "s":
            guard let index = Int(value), strings.indices.contains(index) else { throw ReadError.format }
            return strings[index]
        case "inlineStr":
            return cellText(child(cell, "is"))
        case "b":
            return value == "1" ? "TRUE" : value == "0" ? "FALSE" : value
        default:
            if value.isEmpty, let formula = child(cell, "f")?.stringValue, !formula.isEmpty {
                return "=" + formula
            }
            return value
        }
    }

    private static func columnIndex(_ address: String) -> Int? {
        var column = 0
        for byte in address.utf8.prefix(while: { (65...90).contains($0) }) {
            column = column * 26 + Int(byte - 64)
            guard column <= 16_384 else { return nil }
        }
        return column == 0 ? nil : column - 1
    }

    private static func partPath(_ target: String) -> String? {
        guard let decoded = target.removingPercentEncoding, !decoded.contains("\\"), !decoded.contains(":") else { return nil }
        var parts = decoded.hasPrefix("/") ? [] : ["xl"]
        for part in decoded.split(separator: "/") {
            if part == ".." {
                guard !parts.isEmpty else { return nil }
                parts.removeLast()
            } else if part != "." {
                parts.append(String(part))
            }
        }
        return parts.joined(separator: "/")
    }

    private static func xml(_ data: Data) throws -> XMLDocument {
        try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])
    }
    private static func attribute(_ element: XMLElement, _ name: String) -> String? {
        element.attribute(forName: name)?.stringValue
    }
    private static func children(_ element: XMLElement?, _ name: String) -> [XMLElement] {
        (element?.children ?? []).compactMap { $0.localName == name ? $0 as? XMLElement : nil }
    }
    private static func child(_ element: XMLElement?, _ name: String) -> XMLElement? {
        element?.children?.first { $0.localName == name } as? XMLElement
    }
    private static func cellText(_ element: XMLElement?) -> String {
        if let text = child(element, "t")?.stringValue { return text }
        return children(element, "r").compactMap { child($0, "t")?.stringValue }.joined()
    }
}

/// XLSX stores XML parts as stored or deflated ZIP members. Read only the indexed
/// members we need, with a cumulative bound on uncompressed data.
private nonisolated struct MacExcelArchive {
    private typealias ReadError = MacExcelWorkbook.ReadError
    private struct Entry {
        let method: UInt16
        let offset: Int
        let compressedSize: Int
        let size: Int
    }
    private let bytes: Data
    private let entries: [String: Entry]
    private var remaining = 64 * 1024 * 1024

    init(_ bytes: Data) throws {
        guard bytes.count >= 22 else { throw ReadError.format }
        guard bytes.count <= 100 * 1024 * 1024 else { throw ReadError.limit }
        self.bytes = bytes
        let end = stride(from: bytes.count - 22, through: max(0, bytes.count - 65_557), by: -1).first { index in
            bytes.zipUInt32(index) == 0x06054B50 && index + 22 + Int(bytes.zipUInt16(index + 20)) == bytes.count
        }
        guard let end, bytes.zipUInt16(end + 4) == 0, bytes.zipUInt16(end + 6) == 0,
              bytes.zipUInt16(end + 8) == bytes.zipUInt16(end + 10) else { throw ReadError.format }
        let count = Int(bytes.zipUInt16(end + 10))
        var index = Int(bytes.zipUInt32(end + 16))
        let limit = index + Int(bytes.zipUInt32(end + 12))
        guard count < 65_535, limit <= end else { throw ReadError.format }
        var entries: [String: Entry] = [:]
        for _ in 0..<count {
            guard index + 46 <= limit, bytes.zipUInt32(index) == 0x02014B50 else { throw ReadError.format }
            let nameEnd = index + 46 + Int(bytes.zipUInt16(index + 28))
            let next = nameEnd + Int(bytes.zipUInt16(index + 30)) + Int(bytes.zipUInt16(index + 32))
            guard next <= limit else { throw ReadError.format }
            if let name = String(bytes: bytes[(index + 46)..<nameEnd], encoding: .utf8) {
                entries[name] = Entry(method: bytes.zipUInt16(index + 10), offset: Int(bytes.zipUInt32(index + 42)),
                                      compressedSize: Int(bytes.zipUInt32(index + 20)), size: Int(bytes.zipUInt32(index + 24)))
            }
            index = next
        }
        self.entries = entries
    }

    mutating func read(_ path: String) throws -> Data {
        try Task.checkCancellation()
        guard let entry = entries[path], entry.offset + 30 <= bytes.count,
              bytes.zipUInt32(entry.offset) == 0x04034B50, bytes.zipUInt16(entry.offset + 6) & 1 == 0 else {
            throw ReadError.format
        }
        guard entry.size <= remaining else { throw ReadError.limit }
        remaining -= entry.size
        let start = entry.offset + 30 + Int(bytes.zipUInt16(entry.offset + 26)) + Int(bytes.zipUInt16(entry.offset + 28))
        guard start + entry.compressedSize <= bytes.count else { throw ReadError.format }
        if entry.method == 0 {
            guard entry.compressedSize == entry.size else { throw ReadError.format }
            return bytes.subdata(in: start..<(start + entry.size))
        }
        guard entry.method == 8, entry.size > 0, entry.compressedSize > 0 else { throw ReadError.format }
        var output = Data(count: entry.size)
        var stream = z_stream()
        guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw ReadError.format
        }
        defer { inflateEnd(&stream) }
        let status = bytes.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { destination in
                stream.next_in = UnsafeMutablePointer(mutating: source.bindMemory(to: UInt8.self).baseAddress?.advanced(by: start))
                stream.avail_in = UInt32(entry.compressedSize)
                stream.next_out = destination.bindMemory(to: UInt8.self).baseAddress
                stream.avail_out = UInt32(entry.size)
                return inflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END, stream.total_out == entry.size else { throw ReadError.format }
        return output
    }
}

private extension Data {
    nonisolated func zipUInt16(_ index: Int) -> UInt16 {
        withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: index, as: UInt16.self)) }
    }
    nonisolated func zipUInt32(_ index: Int) -> UInt32 {
        withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: index, as: UInt32.self)) }
    }
}
