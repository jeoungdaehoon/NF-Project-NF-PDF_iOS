//
//  PortalAttachmentPreviewItem.swift
//  NF
//
//  Created by Codex on 7/30/26.
//

import Foundation

/**
 Portal 첨부 파일 내부 미리보기 화면에 전달할 데이터 모델입니다. ( J.D.H )
 - Version: 1.0.0
 - Date: 2026.07.30
 - SeeAlso: ``PortalPDFPreviewView``, ``PortalWebView``
 */
struct PortalAttachmentPreviewItem: Identifiable, Hashable {
    /// SwiftUI sheet(item:)이 동일 URL 재선택도 새 표시 요청으로 인식할 수 있도록 생성 시점마다 부여되는 식별자입니다.
    let id = UUID()
    /// PDFView 내부 미리보기에 사용할 첨부 파일 URL 입니다.
    let url: URL
    /// WKWebView 인증 세션이 필요한 첨부 API 요청에 같이 전달할 Cookie Header 값입니다.
    let cookieHeader: String?
    /// 미리보기 화면 상단에 표시할 파일명 또는 URL 기반 제목입니다.
    var title: String
    /// 네이티브 문서 라이브러리에서 다시 연 로컬 PDF 식별자입니다.
    let localDocumentID: String?
    /// 네이티브 문서 라이브러리가 직접 읽을 로컬 PDF URL입니다.
    let localFileURL: URL?

    /// 만료되는 서명 Query를 제외해 같은 문서의 히스토리 식별자를 안정적으로 유지합니다.
    var historyIdentifier: String {
        localDocumentID ?? historyURL.absoluteString
    }

    /// 인증 토큰이 포함될 수 있는 Query와 Fragment를 저장 기록에서 제거한 URL입니다.
    var historyURL: URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        components.query = nil
        components.fragment = nil
        return components.url ?? url
    }

    /**
     Portal 첨부 파일 미리보기 모델을 생성합니다.
     - Version: 1.0.0
     - Date: 2026.07.30
     - Parameters:
        - url: PDFView 내부 미리보기에 사용할 첨부 파일 URL 입니다.
        - cookieHeader: WKWebView 인증 Cookie Header 값입니다.
     */
    init(url: URL, cookieHeader: String?) {
        self.url = url
        self.cookieHeader = cookieHeader?.isEmpty == false ? cookieHeader : nil
        self.title = url.lastPathComponent.isEmpty ? "첨부 파일" : url.lastPathComponent
        self.localDocumentID = nil
        self.localFileURL = nil
    }

    /** 네이티브 PDF 문서 라이브러리의 로컬 파일을 편집 화면에 전달합니다. */
    init(localDocument: PortalLocalPDFDocument) {
        self.url = localDocument.sourceURL ?? localDocument.localFileURL
        self.cookieHeader = nil
        self.title = localDocument.fileName
        self.localDocumentID = localDocument.id
        self.localFileURL = localDocument.localFileURL
    }

    /** 저장된 PDF 열람 기록을 현재 인증 세션과 결합해 다시 열 수 있는 항목으로 복원합니다. */
    init(historyRecord: PortalPDFDocumentHistoryRecord, cookieHeader: String?) {
        self.url = historyRecord.url
        self.cookieHeader = historyRecord.localFileURL == nil ? cookieHeader : nil
        self.title = historyRecord.title
        self.localDocumentID = historyRecord.localDocumentID
        self.localFileURL = historyRecord.localFileURL
    }
}

/// PDFView 상단 탭에 표시할 문서 열람 기록입니다. 인증 Cookie는 보안상 저장하지 않습니다.
struct PortalPDFDocumentHistoryRecord: Codable, Identifiable, Hashable {
    let id: String
    let urlString: String
    var title: String
    let localDocumentID: String?
    let localFilePath: String?
    let lastViewedAt: Date

    init(item: PortalAttachmentPreviewItem, lastViewedAt: Date = Date()) {
        self.id = item.historyIdentifier
        self.urlString = item.historyURL.absoluteString
        self.title = item.title.removingPercentEncoding ?? item.title
        self.localDocumentID = item.localDocumentID
        self.localFilePath = item.localFileURL?.path
        self.lastViewedAt = lastViewedAt
    }

    var url: URL {
        URL(string: urlString) ?? localFileURL ?? URL(fileURLWithPath: "/")
    }

    var localFileURL: URL? {
        localFilePath.map { URL(fileURLWithPath: $0) }
    }
}

/// 최근 열어본 PDF 목록을 유지하며 현재 문서를 항상 첫 번째 탭으로 정렬합니다.
enum PortalPDFDocumentHistoryStore {
    static let storageKey = "nf.pdf.document.history.v1"

    static func load(userDefaults: UserDefaults = .standard) -> [PortalPDFDocumentHistoryRecord] {
        guard let data = userDefaults.data(forKey: storageKey),
              let records = try? JSONDecoder().decode([PortalPDFDocumentHistoryRecord].self, from: data) else {
            return []
        }
        return records.filter { record in
            guard let localFileURL = record.localFileURL else { return true }
            return FileManager.default.fileExists(atPath: localFileURL.path)
        }
    }

    @discardableResult
    static func record(
        _ item: PortalAttachmentPreviewItem,
        userDefaults: UserDefaults = .standard
    ) -> [PortalPDFDocumentHistoryRecord] {
        let currentRecord = PortalPDFDocumentHistoryRecord(item: item)
        var records = load(userDefaults: userDefaults)
        records.removeAll { $0.id == currentRecord.id }
        records.insert(currentRecord, at: 0)
        save(records, userDefaults: userDefaults)
        return records
    }

    static func save(
        _ records: [PortalPDFDocumentHistoryRecord],
        userDefaults: UserDefaults = .standard
    ) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        userDefaults.set(data, forKey: storageKey)
    }

    /// PDF 타이틀바에서 변경한 표시 이름을 해당 문서의 열람 기록에도 즉시 반영합니다.
    @discardableResult
    static func rename(
        id: String,
        title: String,
        userDefaults: UserDefaults = .standard
    ) -> [PortalPDFDocumentHistoryRecord] {
        let normalizedTitle = title
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else { return load(userDefaults: userDefaults) }
        var records = load(userDefaults: userDefaults)
        guard let recordIndex = records.firstIndex(where: { $0.id == id }) else { return records }
        records[recordIndex].title = normalizedTitle
        save(records, userDefaults: userDefaults)
        return records
    }

    /// 휴지통으로 이동한 로컬 문서가 상단 최근 문서 탭에 남지 않도록 기록에서 제거합니다.
    @discardableResult
    static func remove(
        id: String,
        userDefaults: UserDefaults = .standard
    ) -> [PortalPDFDocumentHistoryRecord] {
        var records = load(userDefaults: userDefaults)
        records.removeAll { $0.id == id }
        save(records, userDefaults: userDefaults)
        return records
    }
}
