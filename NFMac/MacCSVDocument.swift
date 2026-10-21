import CoreFoundation
import Foundation

nonisolated struct MacCSVDocument: Sendable {
    let id = UUID()
    let rows: [[String]]
    let columnCount: Int
    let encodingName: String
    let delimiter: Unicode.Scalar

    static func matches(fileName: String, sourceURL: URL, mimeType: String) -> Bool {
        if (fileName as NSString).pathExtension.lowercased() == "csv" || sourceURL.pathExtension.lowercased() == "csv" { return true }
        let mime = mimeType.split(separator: ";", maxSplits: 1).first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return ["text/csv", "application/csv", "text/comma-separated-values"].contains(mime)
    }

    static func parse(_ data: Data, encodingName: String? = nil) throws -> Self {
        guard data.count <= 25 * 1024 * 1024 else { throw PreviewError.limit }
        let (decoded, name) = try decode(data, declaredEncoding: encodingName)
        guard !decoded.contains("\0") else { throw PreviewError.encoding }
        var text = decoded[...]
        var explicitDelimiter: Unicode.Scalar?
        do {
            let end = text.unicodeScalars.firstIndex(where: { $0 == "\n" || $0 == "\r" }) ?? text.endIndex
            let first = text[..<end]
            if first.count == 5, first.lowercased().hasPrefix("sep="), let last = first.unicodeScalars.last, [",", ";", "\t"].contains(last) {
                explicitDelimiter = last
                text = end == text.endIndex ? text[end...] : text[text.index(after: end)...]
            }
        }
        let delimiter = explicitDelimiter ?? detectDelimiter(text)
        enum State { case start, plain, quoted, closed }
        var state = State.start
        var rows: [[String]] = [], row: [String] = [], field = ""
        var skipLF = false, cells = 0, columnCount = 0, scanned = 0
        func appendField() throws {
            guard row.count < 512, cells < 2_000_000 else { throw PreviewError.limit }
            row.append(field); field = ""; cells += 1; state = .start
        }
        func appendRow() throws {
            try appendField()
            guard rows.count < 100_000 else { throw PreviewError.limit }
            columnCount = max(columnCount, row.count); rows.append(row); row = []
        }
        for c in text.unicodeScalars {
            scanned += 1
            if scanned.isMultiple(of: 4096) { try Task.checkCancellation() }
            if skipLF { skipLF = false; if c == "\n" { continue } }
            if state == .quoted {
                if c == "\"" { state = .closed } else { field.unicodeScalars.append(c) }
            } else if state == .closed, c == "\"" {
                field.append("\""); state = .quoted
            } else if c == delimiter {
                try appendField()
            } else if c == "\r" || c == "\n" {
                try appendRow(); skipLF = c == "\r"
            } else if state == .closed {
                guard c == " " || c == "\t" else { throw PreviewError.quotes }
            } else if c == "\"" {
                guard state == .start else { throw PreviewError.quotes }
                state = .quoted
            } else {
                field.unicodeScalars.append(c); state = .plain
            }
        }
        try Task.checkCancellation()
        guard state != .quoted else { throw PreviewError.quotes }
        if !row.isEmpty || !field.isEmpty || state != .start { try appendRow() }
        return Self(rows: rows, columnCount: columnCount, encodingName: name, delimiter: delimiter)
    }

    func copiedRows(_ indices: IndexSet) -> String {
        indices.filter { rows.indices.contains($0) }.map { index in
            (0..<columnCount).map { column in
                let value = column < rows[index].count ? rows[index][column] : ""
                return value.contains(where: { "\t\r\n\"".contains($0) })
                    ? "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : value
            }.joined(separator: "\t")
        }.joined(separator: "\n")
    }

    static func columnTitle(_ index: Int) -> String {
        var number = index + 1, name = ""
        while number > 0 { number -= 1; name = String(Unicode.Scalar(65 + number % 26)!) + name; number /= 26 }
        return name
    }

    private static func decode(_ data: Data, declaredEncoding: String?) throws -> (String, String) {
        let bom: (Data, String.Encoding, String)? = data.starts(with: [0xEF, 0xBB, 0xBF]) ? (data.dropFirst(3), .utf8, "UTF-8")
            : data.starts(with: [0xFF, 0xFE]) ? (data.dropFirst(2), .utf16LittleEndian, "UTF-16LE")
            : data.starts(with: [0xFE, 0xFF]) ? (data.dropFirst(2), .utf16BigEndian, "UTF-16BE") : nil
        if let (bytes, encoding, name) = bom {
            guard let text = String(data: bytes, encoding: encoding) else { throw PreviewError.encoding }
            return (text, name)
        }
        let korean = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosKorean.rawValue)))
        let declared = declaredEncoding?.lowercased().replacingOccurrences(of: "_", with: "-")
        let encoding: String.Encoding?
        switch declared {
        case "utf-8", "utf8": encoding = .utf8
        case "utf-16", "utf-16le": encoding = .utf16LittleEndian
        case "utf-16be": encoding = .utf16BigEndian
        case "cp949", "windows-949", "euc-kr", "ks-c-5601-1987": encoding = korean
        default: encoding = nil
        }
        if let encoding {
            guard let text = String(data: data, encoding: encoding) else { throw PreviewError.encoding }
            return (text, declaredEncoding ?? "")
        }
        if let text = String(data: data, encoding: .utf8) { return (text, "UTF-8") }
        if let text = String(data: data, encoding: korean) { return (text, "CP949/EUC-KR") }
        throw PreviewError.encoding
    }

    private static func detectDelimiter(_ text: Substring) -> Unicode.Scalar {
        let candidates: [Unicode.Scalar] = [",", "\t", ";"]
        var samples: [[Int]] = [], counts = [0, 0, 0], quoted = false, skipLF = false
        for c in text.unicodeScalars.prefix(16_384) {
            if c == "\"" { quoted.toggle() }
            guard !quoted else { continue }
            if skipLF { skipLF = false; if c == "\n" { continue } }
            if c == "\n" || c == "\r" {
                samples.append(counts); counts = [0, 0, 0]; skipLF = c == "\r"
                if samples.count == 12 { break }
            } else if let index = candidates.firstIndex(of: c) { counts[index] += 1 }
        }
        if counts.contains(where: { $0 > 0 }) { samples.append(counts) }
        var best = 0, bestFrequency = 0, bestSeparators = 0
        for index in candidates.indices {
            let frequencies = Dictionary(grouping: samples.map { $0[index] }.filter { $0 > 0 }, by: { $0 }).mapValues(\.count)
            for (separators, frequency) in frequencies {
                if frequency > bestFrequency || (frequency == bestFrequency && separators > bestSeparators) {
                    best = index; bestFrequency = frequency; bestSeparators = separators
                }
            }
        }
        return candidates[best]
    }

    enum PreviewError: LocalizedError {
        case encoding, quotes, limit
        var errorDescription: String? {
            switch self {
            case .encoding: return "CSV 문자 인코딩을 읽을 수 없습니다. UTF-8·UTF-16·CP949 파일인지 확인하거나 기본 앱에서 열어 주세요."
            case .quotes: return "CSV 따옴표 형식이 올바르지 않습니다. 기본 앱에서 열거나 원본 파일을 저장해 주세요."
            case .limit: return "CSV 미리보기 범위(25MB·10만 행·512열·200만 셀)를 초과했습니다. 기본 앱에서 열거나 원본 파일을 저장해 주세요."
            }
        }
    }
}
