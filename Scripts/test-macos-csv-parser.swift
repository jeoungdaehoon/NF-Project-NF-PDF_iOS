import Foundation

@main struct CSVParserRegression {
    static func main() throws {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
            guard value() else { throw NSError(domain: "CSVParser", code: checks, userInfo: [NSLocalizedDescriptionKey: message]) }
            checks += 1; print("PASS \(checks): \(message)")
        }
        func parse(_ text: String) throws -> MacCSVDocument { try MacCSVDocument.parse(Data(text.utf8)) }
        func rejects(_ data: Data) throws -> Bool {
            do { _ = try MacCSVDocument.parse(data); return false }
            catch is MacCSVDocument.PreviewError { return true }
        }
        let basic = try parse("이름,설명,금액\r\n홍길동,\"쉼표, 줄바꿈\r\n따옴표 \"\"포함\"\"\",00123\r\n")
        try check(basic.rows == [["이름", "설명", "금액"], ["홍길동", "쉼표, 줄바꿈\r\n따옴표 \"포함\"", "00123"]], "Korean, quoted comma, multiline CRLF and escaped quotes retained")
        try check(basic.columnCount == 3 && basic.encodingName == "UTF-8", "row/column and encoding metadata")
        let trailing = try parse("a,b,\n1,,\n")
        try check(trailing.rows == [["a", "b", ""], ["1", "", ""]], "empty and trailing fields preserved without an extra phantom row")
        let empty = try parse("")
        try check(empty.rows.isEmpty && empty.columnCount == 0, "empty file is a completed empty preview")
        let quotedEmpty = try parse("\"\"")
        try check(quotedEmpty.rows == [[""]], "quoted empty cell is a real row")
        let blank = try parse("\n\na,b\n")
        try check(blank.rows == [[""], [""], ["a", "b"]], "blank rows and ragged rows preserved")
        let unicode = try parse("항목,값\n이모지,🧑🏽‍💻\n조합,한글")
        try check(unicode.rows[1][1] == "🧑🏽‍💻" && unicode.rows[2][1] == "한글", "Unicode scalars preserved, including combined emoji")
        let semicolon = try parse("sep=;\r\n이름;값\r\n가;\"나;다\"\r\n")
        try check(semicolon.delimiter == ";" && semicolon.rows == [["이름", "값"], ["가", "나;다"]], "Excel sep directive with CRLF is not mistaken for a data row")
        let directiveOnly = try parse("sep=;")
        try check(directiveOnly.rows.isEmpty && directiveOnly.delimiter == ";", "delimiter directive without data finishes as empty")
        let detected = try parse("name;value\nAlice;10\nBob;20")
        try check(detected.delimiter == ";" && detected.columnCount == 2, "semicolon delimiter auto-detected")
        let tab = try parse("name\tvalue\nAlice\t\"tabs\tinside\"")
        try check(tab.delimiter == "\t" && tab.rows[1][1] == "tabs\tinside", "tab-delimited export with quoted tabs")
        let utf8 = try MacCSVDocument.parse(Data([0xEF, 0xBB, 0xBF]) + Data("이름,값".utf8))
        try check(utf8.rows[0][0] == "이름", "UTF-8 BOM stripped from first field")
        let le = try MacCSVDocument.parse(Data([0xFF, 0xFE]) + "이름,값\r\n홍길동,100".data(using: .utf16LittleEndian)!)
        try check(le.rows[1] == ["홍길동", "100"] && le.encodingName == "UTF-16LE", "Excel UTF-16 little-endian BOM")
        let be = try MacCSVDocument.parse(Data([0xFE, 0xFF]) + "이름,값".data(using: .utf16BigEndian)!)
        try check(be.rows[0] == ["이름", "값"] && be.encodingName == "UTF-16BE", "UTF-16 big-endian BOM")
        let korean = Data([0xBE, 0xC8, 0xB3, 0xE7, 0x2C, 0x31, 0x32, 0x33])
        let cp949 = try MacCSVDocument.parse(korean)
        try check(cp949.rows == [["안녕", "123"]], "CP949/EUC-KR Korean fallback")
        let declared = try MacCSVDocument.parse(korean, encodingName: "euc-kr")
        try check(declared.rows == cp949.rows, "HTTP declared Korean charset")
        let literal = try parse("0001,=SUM(A1),<script>alert(1)</script>")
        try check(literal.rows[0] == ["0001", "=SUM(A1)", "<script>alert(1)</script>"], "numbers, formulas and markup stay literal; no conversion or evaluation")
        let copied = basic.copiedRows(IndexSet(integer: 1))
        try check(copied == "홍길동\t\"쉼표, 줄바꿈\r\n따옴표 \"\"포함\"\"\"\t00123", "row copy keeps multiline values quoted for spreadsheet paste")
        let ragged = try parse("a,b,c\nx")
        try check(ragged.copiedRows(IndexSet(integer: 1)) == "x\t\t", "row copy pads absent cells consistently")
        try check(MacCSVDocument.columnTitle(0) == "A" && MacCSVDocument.columnTitle(25) == "Z" && MacCSVDocument.columnTitle(26) == "AA" && MacCSVDocument.columnTitle(511) == "SR", "column labels scale past Z")
        let badQuote = try rejects(Data("a,\"unterminated".utf8))
        try check(badQuote, "unterminated quoted cells report an explicit error")
        let badTail = try rejects(Data("a,\"b\"invalid".utf8))
        try check(badTail, "invalid characters after closing quote rejected")
        let binary = try rejects(Data([0, 1, 2]))
        try check(binary, "binary/NUL input does not become a misleading text preview")
        let columns = try rejects(Data(Array(repeating: "x", count: 513).joined(separator: ",").utf8))
        try check(columns, "column limit is explicit, not silently truncated")
        let rows = try rejects(Data(String(repeating: "x\n", count: 100_001).utf8))
        try check(rows, "row limit is explicit, not silently truncated")
        let bytes = try rejects(Data(repeating: 65, count: 25 * 1024 * 1024 + 1))
        try check(bytes, "byte limit enforced before decoding")
        let source = URL(string: "https://test/api/artifacts/files/id")!
        try check(MacCSVDocument.matches(fileName: "test.CSV", sourceURL: source, mimeType: "application/vnd.ms-excel"), "Excel-labelled CSV attachment recognized by filename")
        try check(MacCSVDocument.matches(fileName: "id", sourceURL: source, mimeType: "text/csv; charset=utf-8"), "extensionless CSV MIME recognized")
        try check(!MacCSVDocument.matches(fileName: "data.xlsx", sourceURL: source, mimeType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"), "XLSX not parsed as delimited text")
        print("PASS: \(checks) CSV parser checks")
    }
}
