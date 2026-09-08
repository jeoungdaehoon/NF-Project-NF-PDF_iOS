import Foundation
import PDFKit

/// 생성 작업이 끝난 PDFDocument의 소유권을 UI로 넘깁니다. 전달 후 작업자는 접근하지 않습니다.
nonisolated struct PortalPreparedPDF: @unchecked Sendable {
    let document: PDFDocument
    nonisolated init(document: PDFDocument) { self.document = document }
}

enum PortalPDFOpeningWorker {
    nonisolated static func read(fileURL: URL) async -> PortalPreparedPDF? {
        await Task.detached(priority: .userInitiated) {
            // 메모리 매핑하지 않아 파일의 지연 읽기가 첫 화면 표시로 미뤄지지 않게 합니다.
            guard let data = try? Data(contentsOf: fileURL) else { return nil }
            return prepare(data)
        }.value
    }

    nonisolated static func decode(data: Data) async -> PortalPreparedPDF? {
        await Task.detached(priority: .userInitiated) { prepare(data) }.value
    }

    nonisolated private static func prepare(_ data: Data) -> PortalPreparedPDF? {
        guard let document = PDFDocument(data: data), document.pageCount > 0 else { return nil }
        return PortalPreparedPDF(document: document)
    }
}
