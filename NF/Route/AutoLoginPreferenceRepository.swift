//
//  AutoLoginPreferenceRepository.swift
//  NF
//
//  Created by hanwha on 8/3/26.
//

import Foundation
import CryptoKit
import PDFKit

/**
 자동 로그인 설정과 Portal 세션 존재 여부를 로컬 단말에 저장하는 Repository 입니다. ( J.D.H )
 - Version: 1.0.0
 - Date: 2026.08.03
 - SeeAlso: ``PortalRouteViewModel``, ``PortalWebView``

 [Note]
 - Google Access Token, ID Token과 같은 민감한 인증 원문은 UserDefaults에 저장하지 않습니다.
 - 자동 로그인 여부는 단순 설정 값으로 저장하고, 실제 인증 세션은 WKWebView의 기본 CookieStore가 보관합니다.
 - 세션 존재 여부는 앱 재실행 시 Dashboard 진입을 시도할지 판단하기 위한 비민감 상태 값입니다.
 */
final class AutoLoginPreferenceRepository {
    /// 자동 로그인 설정과 세션 상태를 저장하는 UserDefaults 입니다.
    private let userDefaults: UserDefaults

    /**
     Repository를 생성합니다.
     - Version: 1.0.0
     - Date: 2026.08.03
     - Parameters:
        - userDefaults: 설정 값을 저장할 UserDefaults 입니다.
     */
    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    /**
     자동 로그인 설정 값을 조회합니다.
     - Version: 1.0.0
     - Date: 2026.08.03
     - Returns: 자동 로그인 사용 여부 입니다.
     */
    func isAutoLoginEnabled() -> Bool {
        userDefaults.bool(forKey: Self.autoLoginEnabledKey)
    }

    /**
     자동 로그인 설정 값을 저장합니다.
     - Version: 1.0.0
     - Date: 2026.08.03
     - Parameters:
        - enabled: 저장할 자동 로그인 사용 여부 입니다.
     */
    func setAutoLoginEnabled(_ enabled: Bool) {
        userDefaults.set(enabled, forKey: Self.autoLoginEnabledKey)
    }

    /**
     PDF 파일 로컬 저장 설정 값을 조회합니다.
     - Version: 1.0.0
     - Date: 2026.08.08
     - Returns: PDF 파일 로컬 저장 사용 여부 입니다.
     */
    func isPDFLocalStorageEnabled() -> Bool {
        userDefaults.bool(forKey: Self.pdfLocalStorageEnabledKey)
    }

    /**
     PDF 파일 로컬 저장 설정 값을 저장합니다.
     - Version: 1.0.0
     - Date: 2026.08.08
     - Parameters:
        - enabled: 저장할 PDF 파일 로컬 저장 사용 여부 입니다.
     */
    func setPDFLocalStorageEnabled(_ enabled: Bool) {
        userDefaults.set(enabled, forKey: Self.pdfLocalStorageEnabledKey)
    }

    /**
     자동 로그인에 사용할 Portal 세션이 저장되어 있는지 조회합니다.
     - Version: 1.0.0
     - Date: 2026.08.03
     - Returns: 마지막 로그인 성공 세션의 존재 여부 입니다.

     [Note]
     - 실제 Cookie 값은 저장하지 않고 WKWebView 기본 CookieStore에 맡깁니다.
     - 이 값은 앱 시작 시 불필요한 Login 화면을 건너뛸지 결정하는 힌트로만 사용합니다.
     */
    func hasStoredPortalSession() -> Bool {
        userDefaults.bool(forKey: Self.portalSessionAvailableKey)
    }

    /**
     Portal 세션이 생성되었음을 저장합니다.
     - Version: 1.0.0
     - Date: 2026.08.03
     */
    func markPortalSessionAvailable() {
        userDefaults.set(true, forKey: Self.portalSessionAvailableKey)
    }

    /**
     Portal 세션 상태를 삭제합니다.
     - Version: 1.0.0
     - Date: 2026.08.03

     [Note]
     - WebView Cookie 삭제는 ``AuthSessionRepository.clearWebViewSession``에서 별도로 처리합니다.
     */
    func clearPortalSession() {
        userDefaults.removeObject(forKey: Self.portalSessionAvailableKey)
    }

    /** 계정 탈퇴 시 온보딩 완료 여부를 제외한 계정·PDF 편집 관련 설정을 모두 삭제합니다. */
    func clearAccountPreferences() {
        userDefaults.removeObject(forKey: Self.autoLoginEnabledKey)
        userDefaults.removeObject(forKey: Self.pdfLocalStorageEnabledKey)
        userDefaults.removeObject(forKey: Self.portalSessionAvailableKey)
        for key in userDefaults.dictionaryRepresentation().keys where key.hasPrefix("nf.pdf.") {
            userDefaults.removeObject(forKey: key)
        }
    }

    /// 자동 로그인 사용 여부 저장 Key 입니다.
    private static let autoLoginEnabledKey = "nf.portal.autoLogin.enabled"
    /// PDF 파일 로컬 저장 사용 여부 저장 Key 입니다.
    static let pdfLocalStorageEnabledKey = "nf.portal.pdf.localStorage.enabled"
    /// Portal 인증 세션 존재 여부 저장 Key 입니다.
    private static let portalSessionAvailableKey = "nf.portal.session.available"
}

/**
 PDF 첨부 파일의 로컬 캐시를 관리하는 Repository 입니다. ( J.D.H )

 [Note]
 - 캐시는 사용자 설정이 켜진 경우에만 호출해야 합니다.
 - URL query가 매번 바뀌는 서명 URL이어도 같은 첨부 경로를 재사용할 수 있도록
   host/path와 파일명을 기준으로 캐시 키를 만듭니다.
 - 로컬 파일에는 PDF 본문만 저장하고 인증 Cookie는 저장하지 않습니다.
 */
struct PortalLocalPDFDocument: Identifiable, Hashable {
    let id: String
    let fileName: String
    let sourceURL: URL?
    let localFileURL: URL
    let createdAt: Date
    let modifiedAt: Date
    let fileSize: Int64
    let isFavorite: Bool
    let deletedAt: Date?
    let folderID: String?

    var isDeleted: Bool { deletedAt != nil }
}

/** 로컬 PDF 문서를 묶어 관리하는 사용자 생성 폴더입니다. */
struct PortalLocalPDFFolder: Identifiable, Hashable {
    let id: String
    let name: String
    let createdAt: Date
    let modifiedAt: Date
}

final class PortalPDFLocalStorageRepository {
    /// 로컬 PDF 파일·메타데이터가 바뀌었음을 앱과 WebView에 알리는 Notification 입니다.
    static let didChangeNotification = Notification.Name("nf.portal.pdf.localStorage.didChange")
    /// 웹 휴지통과 동일하게 삭제 문서를 7일 동안 보관합니다.
    static let trashRetentionInterval: TimeInterval = 7 * 24 * 60 * 60

    private let fileManager: FileManager
    private let cacheDirectoryURL: URL

    private struct Metadata: Codable {
        let id: String
        var fileName: String
        var sourceURLString: String?
        let createdAt: Date
        var modifiedAt: Date
        var isFavorite: Bool
        var deletedAt: Date?
        var folderID: String?
    }

    private struct FolderMetadata: Codable {
        let id: String
        var name: String
        let createdAt: Date
        var modifiedAt: Date
    }

    init(fileManager: FileManager = .default, cacheDirectoryURL: URL? = nil) {
        self.fileManager = fileManager
        let applicationSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        self.cacheDirectoryURL = cacheDirectoryURL
            ?? applicationSupportURL.appendingPathComponent("NF/PDFCache", isDirectory: true)
    }

    /** 캐시된 PDF 데이터를 조회합니다. */
    func data(for item: PortalAttachmentPreviewItem) -> Data? {
        let fileURL = item.localFileURL ?? cacheFileURL(for: item)
        return try? Data(contentsOf: fileURL, options: [.mappedIfSafe])
    }

    /** PDF 데이터를 로컬 캐시에 원자적으로 저장합니다. */
    func save(
        _ data: Data,
        for item: PortalAttachmentPreviewItem,
        notifyObservers: Bool = true
    ) throws {
        try fileManager.createDirectory(at: cacheDirectoryURL, withIntermediateDirectories: true)
        let identifier = item.localDocumentID ?? cacheIdentifier(for: item)
        var fileURL = item.localFileURL ?? pdfFileURL(for: identifier)
        try data.write(to: fileURL, options: [.atomic])
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? fileURL.setResourceValues(resourceValues)

        let now = Date()
        let existingMetadata = metadata(for: identifier)
        let sourceURL = item.url.isFileURL ? existingMetadata?.sourceURLString : item.url.absoluteString
        let metadata = Metadata(
            id: identifier,
            fileName: item.title.removingPercentEncoding ?? item.title,
            sourceURLString: sourceURL,
            createdAt: existingMetadata?.createdAt ?? now,
            modifiedAt: now,
            isFavorite: existingMetadata?.isFavorite ?? false,
            deletedAt: nil,
            folderID: existingMetadata?.folderID
        )
        try save(metadata)
        if notifyObservers {
            notifyChange()
        }
    }

    /** 로컬 PDF 문서를 최근 수정 순으로 조회합니다. */
    func documents() -> [PortalLocalPDFDocument] {
        try? fileManager.createDirectory(at: cacheDirectoryURL, withIntermediateDirectories: true)
        migrateUntrackedPDFs(in: cacheDirectoryURL)
        purgeExpiredTrash(in: cacheDirectoryURL)
        guard let urls = try? fileManager.contentsOfDirectory(
            at: cacheDirectoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return urls
            .filter { $0.pathExtension.lowercased() == "json" }
            .compactMap { metadataURL -> PortalLocalPDFDocument? in
                guard let data = try? Data(contentsOf: metadataURL),
                      let metadata = try? JSONDecoder().decode(Metadata.self, from: data) else { return nil }
                let fileURL = pdfFileURL(for: metadata.id)
                guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
                let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path)
                let fileSize = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
                return PortalLocalPDFDocument(
                    id: metadata.id,
                    fileName: metadata.fileName,
                    sourceURL: metadata.sourceURLString.flatMap(URL.init(string:)),
                    localFileURL: fileURL,
                    createdAt: metadata.createdAt,
                    modifiedAt: metadata.modifiedAt,
                    fileSize: fileSize,
                    isFavorite: metadata.isFavorite,
                    deletedAt: metadata.deletedAt,
                    folderID: metadata.folderID
                )
            }
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    /** 새 PDF 데이터를 로컬 문서 라이브러리에 저장하고 생성된 문서를 반환합니다. */
    func createDocument(
        data: Data,
        fileName: String,
        sourceURL: URL? = nil,
        folderID: String? = nil
    ) throws -> PortalLocalPDFDocument {
        guard let pdfDocument = PDFDocument(data: data), pdfDocument.pageCount > 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let normalizedFileName = normalizedPDFFileName(fileName)
        guard !normalizedFileName.isEmpty else { throw CocoaError(.fileWriteInvalidFileName) }
        try fileManager.createDirectory(at: cacheDirectoryURL, withIntermediateDirectories: true)
        let identifier = UUID().uuidString.lowercased()
        var fileURL = pdfFileURL(for: identifier)
        try data.write(to: fileURL, options: [.atomic])
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? fileURL.setResourceValues(resourceValues)
        let now = Date()
        let metadata = Metadata(
            id: identifier,
            fileName: normalizedFileName,
            sourceURLString: sourceURL?.absoluteString,
            createdAt: now,
            modifiedAt: now,
            isFavorite: false,
            deletedAt: nil,
            folderID: folderID
        )
        try save(metadata)
        notifyChange()
        return localDocument(from: metadata, fileURL: fileURL)
    }

    /** 사용자 생성 폴더를 최근 생성 순으로 조회합니다. */
    func folders() -> [PortalLocalPDFFolder] {
        try? fileManager.createDirectory(at: cacheDirectoryURL, withIntermediateDirectories: true)
        guard let urls = try? fileManager.contentsOfDirectory(
            at: cacheDirectoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return urls
            .filter { $0.lastPathComponent.hasPrefix("folder-") && $0.pathExtension == "json" }
            .compactMap { url -> PortalLocalPDFFolder? in
                guard let data = try? Data(contentsOf: url),
                      let metadata = try? JSONDecoder().decode(FolderMetadata.self, from: data) else { return nil }
                return PortalLocalPDFFolder(
                    id: metadata.id,
                    name: metadata.name,
                    createdAt: metadata.createdAt,
                    modifiedAt: metadata.modifiedAt
                )
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /** 새 폴더를 생성합니다. */
    func createFolder(name: String) throws -> PortalLocalPDFFolder {
        let normalizedName = normalizedDisplayName(name)
        guard !normalizedName.isEmpty else { throw CocoaError(.fileWriteInvalidFileName) }
        try fileManager.createDirectory(at: cacheDirectoryURL, withIntermediateDirectories: true)
        let now = Date()
        let metadata = FolderMetadata(
            id: UUID().uuidString.lowercased(),
            name: normalizedName,
            createdAt: now,
            modifiedAt: now
        )
        let data = try JSONEncoder().encode(metadata)
        try data.write(to: folderMetadataFileURL(for: metadata.id), options: [.atomic])
        notifyChange()
        return PortalLocalPDFFolder(id: metadata.id, name: metadata.name, createdAt: now, modifiedAt: now)
    }

    /** 문서를 지정한 폴더로 이동합니다. `nil`이면 루트 목록으로 이동합니다. */
    func moveDocument(documentID: String, toFolderID folderID: String?) throws {
        if let folderID,
           !fileManager.fileExists(atPath: folderMetadataFileURL(for: folderID).path) {
            throw CocoaError(.fileNoSuchFile)
        }
        guard var metadata = metadata(for: documentID) else { throw CocoaError(.fileNoSuchFile) }
        metadata.folderID = folderID
        metadata.modifiedAt = Date()
        try save(metadata)
        notifyChange()
    }

    /** 문서의 즐겨찾기 상태를 전환합니다. */
    func toggleFavorite(documentID: String) throws {
        guard var metadata = metadata(for: documentID) else { throw CocoaError(.fileNoSuchFile) }
        metadata.isFavorite.toggle()
        metadata.modifiedAt = Date()
        try save(metadata)
        notifyChange()
    }

    /** 문서 목록과 PDF 편집 화면에 표시할 파일명을 변경합니다. */
    func rename(documentID: String, fileName: String) throws {
        let normalizedName = normalizedPDFFileName(fileName)
        guard !normalizedName.isEmpty else { throw CocoaError(.fileWriteInvalidFileName) }
        guard var metadata = metadata(for: documentID) else { throw CocoaError(.fileNoSuchFile) }
        metadata.fileName = normalizedName
        metadata.modifiedAt = Date()
        try save(metadata)
        notifyChange()
    }

    /** 문서를 휴지통으로 이동합니다. */
    func moveToTrash(documentID: String) throws {
        guard var metadata = metadata(for: documentID) else { throw CocoaError(.fileNoSuchFile) }
        metadata.deletedAt = Date()
        try save(metadata)
        notifyChange()
    }

    /** 휴지통 문서를 다시 전체 문서로 복원합니다. */
    func restore(documentID: String) throws {
        guard var metadata = metadata(for: documentID) else { throw CocoaError(.fileNoSuchFile) }
        metadata.deletedAt = nil
        metadata.modifiedAt = Date()
        try save(metadata)
        notifyChange()
    }

    /** 휴지통 문서와 메타데이터를 즉시 완전 삭제합니다. */
    func permanentlyDelete(documentID: String) throws {
        let pdfURL = pdfFileURL(for: documentID)
        let metadataURL = metadataFileURL(for: documentID)
        if fileManager.fileExists(atPath: pdfURL.path) {
            try fileManager.removeItem(at: pdfURL)
        }
        if fileManager.fileExists(atPath: metadataURL.path) {
            try fileManager.removeItem(at: metadataURL)
        }
        try? PortalPDFPageEditRepository().remove(identifier: documentID)
        notifyChange()
    }

    /** 계정 탈퇴 시 로컬 PDF, 휴지통 문서, 폴더와 메타데이터를 한 번에 삭제합니다. */
    func removeAllLocalData() throws {
        if fileManager.fileExists(atPath: cacheDirectoryURL.path) {
            try fileManager.removeItem(at: cacheDirectoryURL)
        }
        try? PortalPDFPageEditRepository().removeAll()
        notifyChange()
    }

    private func cacheFileURL(for item: PortalAttachmentPreviewItem) -> URL {
        cacheDirectoryURL
            .appendingPathComponent(item.localDocumentID ?? cacheIdentifier(for: item))
            .appendingPathExtension("pdf")
    }

    private func cacheIdentifier(for item: PortalAttachmentPreviewItem) -> String {
        let source = [
            item.url.host ?? "",
            item.url.path,
            item.title
        ].joined(separator: "\n")
        return SHA256.hash(data: Data(source.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func pdfFileURL(for identifier: String) -> URL {
        cacheDirectoryURL
            .appendingPathComponent(identifier)
            .appendingPathExtension("pdf")
    }

    private func metadataFileURL(for identifier: String) -> URL {
        cacheDirectoryURL
            .appendingPathComponent(identifier)
            .appendingPathExtension("json")
    }

    private func folderMetadataFileURL(for identifier: String) -> URL {
        cacheDirectoryURL
            .appendingPathComponent("folder-\(identifier)")
            .appendingPathExtension("json")
    }

    private func metadata(for identifier: String) -> Metadata? {
        guard let data = try? Data(contentsOf: metadataFileURL(for: identifier)) else { return nil }
        return try? JSONDecoder().decode(Metadata.self, from: data)
    }

    private func save(_ metadata: Metadata) throws {
        let data = try JSONEncoder().encode(metadata)
        try data.write(to: metadataFileURL(for: metadata.id), options: [.atomic])
    }

    private func localDocument(from metadata: Metadata, fileURL: URL) -> PortalLocalPDFDocument {
        let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path)
        let fileSize = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        return PortalLocalPDFDocument(
            id: metadata.id,
            fileName: metadata.fileName,
            sourceURL: metadata.sourceURLString.flatMap(URL.init(string:)),
            localFileURL: fileURL,
            createdAt: metadata.createdAt,
            modifiedAt: metadata.modifiedAt,
            fileSize: fileSize,
            isFavorite: metadata.isFavorite,
            deletedAt: metadata.deletedAt,
            folderID: metadata.folderID
        )
    }

    private func normalizedDisplayName(_ value: String) -> String {
        value
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedPDFFileName(_ value: String) -> String {
        let name = normalizedDisplayName(value)
        guard !name.isEmpty else { return "" }
        return name.lowercased().hasSuffix(".pdf") ? name : "\(name).pdf"
    }

    /** 이전 버전에서 PDF 파일만 저장한 캐시를 문서 라이브러리에 자동 등록합니다. */
    private func migrateUntrackedPDFs(in directoryURL: URL) {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for pdfURL in urls where pdfURL.pathExtension.lowercased() == "pdf" {
            let identifier = pdfURL.deletingPathExtension().lastPathComponent
            guard metadata(for: identifier) == nil else { continue }
            let resourceValues = try? pdfURL.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
            let embeddedTitle = (PDFDocument(url: pdfURL)?.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let fallbackTitle = "저장된 PDF \(identifier.prefix(6))"
            let metadata = Metadata(
                id: identifier,
                fileName: embeddedTitle?.isEmpty == false ? embeddedTitle! : fallbackTitle,
                sourceURLString: nil,
                createdAt: resourceValues?.creationDate ?? Date(),
                modifiedAt: resourceValues?.contentModificationDate ?? Date(),
                isFavorite: false,
                deletedAt: nil,
                folderID: nil
            )
            try? save(metadata)
        }
    }

    /** 삭제 후 7일이 지난 로컬 문서를 웹 휴지통 정책과 동일하게 자동 정리합니다. */
    private func purgeExpiredTrash(in directoryURL: URL) {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        let expirationDate = Date().addingTimeInterval(-Self.trashRetentionInterval)
        for metadataURL in urls where metadataURL.pathExtension.lowercased() == "json" {
            guard let data = try? Data(contentsOf: metadataURL),
                  let metadata = try? JSONDecoder().decode(Metadata.self, from: data),
                  let deletedAt = metadata.deletedAt,
                  deletedAt <= expirationDate else { continue }
            try? fileManager.removeItem(at: pdfFileURL(for: metadata.id))
            try? fileManager.removeItem(at: metadataURL)
        }
    }

    private func notifyChange() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }
}
