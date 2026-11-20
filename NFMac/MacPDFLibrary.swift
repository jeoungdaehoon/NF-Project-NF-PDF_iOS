import AppKit
import Combine
import CryptoKit
import Foundation
import PDFKit
import PhotosUI
import QuickLookUI
import SwiftUI
import UniformTypeIdentifiers

struct MacPDFRemoteRequest: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let cookieHeader: String?
    var localDocument: MacLocalPDFDocument? = nil
    var initialFreeNote: String? = nil
}

enum MacPDFSlidePanelLayout {
    static let animation = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.52)
    static let resizeHandleWidth: CGFloat = 10
    static let tabBarHeight: CGFloat = 32

    /// HSplitView's measured pane rect can start below AppKit's title-bar safe
    /// area, while the overlay ignores that safe area. Only its horizontal
    /// bounds belong to this coordinate space; both panes fill the workspace.
    static func containerFrame(paneBounds: CGRect?, availableSize: CGSize) -> CGRect {
        let workspace = CGRect(origin: .zero, size: availableSize)
        guard let paneBounds else { return workspace }
        guard !paneBounds.isEmpty, !workspace.isEmpty else { return .zero }
        let horizontalPane = CGRect(x: paneBounds.minX, y: 0, width: paneBounds.width, height: workspace.height)
        let bounds = workspace.intersection(horizontalPane)
        return bounds.isNull ? .zero : bounds
    }

    static func frame(preferredWidth: CGFloat?, availableSize: CGSize, expandedPane: CGRect? = nil) -> CGRect {
        if let expandedPane {
            let content = CGRect(x: 0, y: tabBarHeight, width: max(0, availableSize.width), height: max(0, availableSize.height - tabBarHeight))
            let bounds = content.intersection(expandedPane)
            if !bounds.isNull, !bounds.isEmpty { return bounds }
        }
        let panelWidth = width(preferredWidth: preferredWidth, for: availableSize.width)
        return CGRect(x: availableSize.width - panelWidth, y: tabBarHeight, width: panelWidth, height: max(0, availableSize.height - tabBarHeight))
    }

    static func width(preferredWidth: CGFloat?, for availableWidth: CGFloat) -> CGFloat {
        guard availableWidth.isFinite, availableWidth > 0 else { return 0 }
        let minimum = min(480, availableWidth)
        let maximum = max(minimum, availableWidth * 0.9)
        let defaultWidth = max(minimum, availableWidth * 0.5)
        return min(maximum, max(minimum, preferredWidth ?? defaultWidth))
    }
}

struct MacLocalPDFDocument: Identifiable, Hashable {
    let id: String
    let fileName: String
    let localFileURL: URL
    let modifiedAt: Date
    let fileSize: Int64
    let isFavorite: Bool
    let deletedAt: Date?
    var folderID: String?
    var lastOpenedAt: Date?

    var isDeleted: Bool { deletedAt != nil }
}

/** iOS의 NF/PDFCache 메타데이터 형식과 동일한 macOS 로컬 PDF 저장소입니다. */
final class MacPDFLocalStorageRepository {
    static let didChangeNotification = Notification.Name("nf.portal.pdf.localStorage.didChange")

    private struct Metadata: Codable {
        let id: String
        var fileName: String
        var sourceURLString: String?
        let createdAt: Date
        var modifiedAt: Date
        var isFavorite: Bool
        var deletedAt: Date?
        var folderID: String?
        var lastOpenedAt: Date?
    }
    struct Folder: Codable, Identifiable { let id: String; var name: String; var parentID: String? }

    private let fileManager: FileManager
    private let directoryURL: URL

    init(fileManager: FileManager = .default, directoryURL: URL? = nil) {
        self.fileManager = fileManager
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        self.directoryURL = directoryURL
            ?? applicationSupport.appendingPathComponent("NF/PDFCache", isDirectory: true)
    }

    func documents() -> [MacLocalPDFDocument] {
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return urls
            .filter { $0.pathExtension.lowercased() == "json" && !$0.lastPathComponent.hasPrefix("folder-") }
            .compactMap { metadataURL -> MacLocalPDFDocument? in
                guard let data = try? Data(contentsOf: metadataURL),
                      let metadata = try? JSONDecoder().decode(Metadata.self, from: data) else { return nil }
                return localDocument(from: metadata)
            }
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    func libraryItemCount() -> Int {
        let activeDocuments = documents().filter { !$0.isDeleted }.count
        let folderCount = (try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ))?.filter { $0.lastPathComponent.hasPrefix("folder-") && $0.pathExtension == "json" }.count ?? 0
        return activeDocuments + folderCount
    }

    @discardableResult
    func createDocument(data: Data, fileName: String, sourceURL: URL? = nil) throws -> MacLocalPDFDocument {
        guard let pdf = PDFDocument(data: data), pdf.pageCount > 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let identifier = UUID().uuidString.lowercased()
        let now = Date()
        let metadata = Metadata(
            id: identifier,
            fileName: normalizedPDFFileName(fileName),
            sourceURLString: sourceURL?.absoluteString,
            createdAt: now,
            modifiedAt: now,
            isFavorite: false,
            deletedAt: nil,
            folderID: nil
        )
        try write(data: data, metadata: metadata)
        notifyChange()
        return localDocument(from: metadata)!
    }

    @discardableResult
    func saveRemote(data: Data, fileName: String, sourceURL: URL) throws -> MacLocalPDFDocument {
        guard let pdf = PDFDocument(data: data), pdf.pageCount > 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let normalizedName = normalizedPDFFileName(fileName)
        let source = [sourceURL.host ?? "", sourceURL.path, normalizedName].joined(separator: "\n")
        let identifier = SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
        let existing = metadata(for: identifier)
        let now = Date()
        let metadata = Metadata(
            id: identifier,
            fileName: normalizedName,
            sourceURLString: sourceURL.absoluteString,
            createdAt: existing?.createdAt ?? now,
            modifiedAt: now,
            isFavorite: existing?.isFavorite ?? false,
            deletedAt: nil,
            folderID: existing?.folderID
        )
        try write(data: data, metadata: metadata)
        notifyChange()
        return localDocument(from: metadata)!
    }

    func toggleFavorite(_ document: MacLocalPDFDocument) throws {
        guard var metadata = metadata(for: document.id) else { throw CocoaError(.fileNoSuchFile) }
        metadata.isFavorite.toggle()
        metadata.modifiedAt = Date()
        try save(metadata)
        notifyChange()
    }

    func moveToTrash(_ document: MacLocalPDFDocument) throws {
        guard var metadata = metadata(for: document.id) else { throw CocoaError(.fileNoSuchFile) }
        metadata.deletedAt = Date()
        try save(metadata)
        notifyChange()
    }

    func restore(_ document: MacLocalPDFDocument) throws {
        guard var metadata = metadata(for: document.id) else { throw CocoaError(.fileNoSuchFile) }
        metadata.deletedAt = nil
        metadata.modifiedAt = Date()
        try save(metadata)
        notifyChange()
    }

    func permanentlyDelete(_ document: MacLocalPDFDocument) throws {
        for url in [pdfURL(for: document.id), metadataURL(for: document.id)]
            where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        let digest = SHA256.hash(data: Data(document.id.utf8)).map { String(format: "%02x", $0) }.joined()
        let edits = directoryURL.deletingLastPathComponent().appendingPathComponent("PDFEdits/mac-\(digest)", isDirectory: true)
        if fileManager.fileExists(atPath: edits.path) { try fileManager.removeItem(at: edits) }
        MacPDFGoogleDrive.unlink(document.id)
        notifyChange()
    }

    func updateData(_ document: MacLocalPDFDocument, data: Data) throws {
        guard PDFDocument(data: data) != nil, var metadata = metadata(for: document.id) else { throw CocoaError(.fileReadCorruptFile) }
        metadata.modifiedAt = Date(); try write(data: data, metadata: metadata); notifyChange()
    }
    func rename(_ document: MacLocalPDFDocument, name: String) throws {
        guard var metadata = metadata(for: document.id) else { throw CocoaError(.fileNoSuchFile) }
        metadata.fileName = normalizedPDFFileName(name); metadata.modifiedAt = Date(); try save(metadata); notifyChange()
    }
    func recordOpen(_ document: MacLocalPDFDocument) throws {
        guard var metadata = metadata(for: document.id) else { throw CocoaError(.fileNoSuchFile) }
        metadata.lastOpenedAt = Date(); try save(metadata)
    }
    @discardableResult
    func duplicate(_ document: MacLocalPDFDocument) throws -> MacLocalPDFDocument {
        let copied = try createDocument(data: Data(contentsOf: document.localFileURL), fileName: "\((document.fileName as NSString).deletingPathExtension) 복제.pdf")
        let editsRoot = directoryURL.deletingLastPathComponent().appendingPathComponent("PDFEdits", isDirectory: true)
        func path(_ id: String) -> URL { editsRoot.appendingPathComponent("mac-" + SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined(), isDirectory: true) }
        if fileManager.fileExists(atPath: path(document.id).path) { try fileManager.copyItem(at: path(document.id), to: path(copied.id)) }
        try move(copied, folderID: document.folderID); return copied
    }
    func folders() -> [Folder] {
        ((try? fileManager.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("folder-") && $0.pathExtension == "json" }
            .compactMap { url in (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Folder.self, from: $0) } }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    func createFolder(_ name: String, parentID: String? = nil) throws {
        let folder = Folder(id: UUID().uuidString.lowercased(), name: name, parentID: parentID)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try JSONEncoder().encode(folder).write(to: directoryURL.appendingPathComponent("folder-\(folder.id).json"), options: .atomic); notifyChange()
    }
    func move(_ document: MacLocalPDFDocument, folderID: String?) throws {
        guard var metadata = metadata(for: document.id) else { throw CocoaError(.fileNoSuchFile) }
        if let folderID, !folders().contains(where: { $0.id == folderID }) { throw CocoaError(.fileNoSuchFile) }
        metadata.folderID = folderID; try save(metadata); notifyChange()
    }
    func purgeExpiredTrash(now: Date = Date()) throws {
        for document in documents() { if let deleted = document.deletedAt, now.timeIntervalSince(deleted) >= 7 * 24 * 60 * 60 { try permanentlyDelete(document) } }
    }

    private func write(data: Data, metadata: Metadata) throws {
        try data.write(to: pdfURL(for: metadata.id), options: [.atomic])
        try save(metadata)
    }

    private func save(_ metadata: Metadata) throws {
        try JSONEncoder().encode(metadata).write(to: metadataURL(for: metadata.id), options: [.atomic])
    }

    private func metadata(for identifier: String) -> Metadata? {
        guard let data = try? Data(contentsOf: metadataURL(for: identifier)) else { return nil }
        return try? JSONDecoder().decode(Metadata.self, from: data)
    }

    private func localDocument(from metadata: Metadata) -> MacLocalPDFDocument? {
        let fileURL = pdfURL(for: metadata.id)
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        let size = (try? fileManager.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        return MacLocalPDFDocument(
            id: metadata.id,
            fileName: metadata.fileName,
            localFileURL: fileURL,
            modifiedAt: metadata.modifiedAt,
            fileSize: size,
            isFavorite: metadata.isFavorite,
            deletedAt: metadata.deletedAt,
            folderID: metadata.folderID,
            lastOpenedAt: metadata.lastOpenedAt
        )
    }

    private func pdfURL(for identifier: String) -> URL {
        directoryURL.appendingPathComponent(identifier).appendingPathExtension("pdf")
    }

    private func metadataURL(for identifier: String) -> URL {
        directoryURL.appendingPathComponent(identifier).appendingPathExtension("json")
    }

    private func normalizedPDFFileName(_ value: String) -> String {
        let cleaned = value.removingPercentEncoding?
            .components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fallback = cleaned.isEmpty ? "PDF 문서" : cleaned
        return fallback.lowercased().hasSuffix(".pdf") ? fallback : "\(fallback).pdf"
    }

    private func notifyChange() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }
}

private enum MacPDFLibrarySection: String, CaseIterable, Identifiable {
    case all
    case favorites
    case recent
    case trash

    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "전체"
        case .favorites: "즐겨찾기"
        case .recent: "최근 문서"
        case .trash: "휴지통"
        }
    }
}

struct MacPDFLibraryView: View {
    @Environment(\.dismiss) private var dismiss
    var repository = MacPDFLocalStorageRepository()
    var editorDirectory: URL?
    var onRequestClose: (() -> Void)?
    var onSelectDocument: ((MacLocalPDFDocument) -> Void)?
    @State private var section: MacPDFLibrarySection = .all
    @State private var searchText = ""
    @State private var documents: [MacLocalPDFDocument] = []
    @StateObject private var documentWindow = MacPDFDocumentWindowController()
    @State private var isImporterPresented = false
    @State private var errorMessage: String?
    @State private var folders: [MacPDFLocalStorageRepository.Folder] = []
    @State private var folderID = "all"
    @State private var isPhotosPresented = false
    @State private var photos: [PhotosPickerItem] = []
    @State private var deletion: MacLocalPDFDocument?
    @State private var showBoard = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    documentWindow.close()
                    if let onRequestClose { onRequestClose() } else { dismiss() }
                } label: {
                    Image(systemName: "xmark").frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("닫기")
                .accessibilityIdentifier("pdf.library.close")
                Text("PDF 문서함").font(.headline)
                Spacer()
                Button("Drive", systemImage: "icloud") { isImporterPresented = true }
                    .buttonStyle(.borderless)
            }
            .padding(12)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Menu {
                        Button("파일 가져오기", systemImage: "folder") { isImporterPresented = true }
                        Button("사진 → PDF", systemImage: "photo.on.rectangle") { isPhotosPresented = true }
                        Button("URL 가져오기", systemImage: "link", action: importLink)
                        Divider()
                        Button("새 폴더", systemImage: "folder.badge.plus") {
                            if let name = prompt("새 폴더", initial: "") {
                                perform { try repository.createFolder(name, parentID: ["all", "root"].contains(folderID) ? nil : folderID) }
                            }
                        }
                        Button("문서 연결 보드", systemImage: "point.3.connected.trianglepath.dotted") { showBoard = true }
                    } label: {
                        Label("가져오기", systemImage: "folder")
                    }
                    .fixedSize()
                    Button("새 PDF", systemImage: "plus", action: createBlank)
                        .buttonStyle(.borderedProminent)
                }
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("문서 이름·폴더 검색", text: $searchText).textFieldStyle(.plain)
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain)
                            .accessibilityLabel("검색어 지우기")
                    }
                }
                .padding(8)
                .background(MacPDFPanelSurface(radius: 7))
                HStack(spacing: 10) {
                    ForEach(MacPDFLibrarySection.allCases) { item in
                        Button {
                            section = item
                        } label: {
                            VStack(spacing: 5) {
                                Text(item.title)
                                Rectangle().fill(section == item ? Color.accentColor : .clear).frame(height: 2)
                            }
                            .fixedSize(horizontal: true, vertical: false)
                            .foregroundStyle(section == item ? Color.accentColor : Color.secondary)
                            .padding(.horizontal, 4)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(section == item ? .isSelected : [])
                    }
                    Spacer()
                    Picker("폴더", selection: $folderID) {
                        Text("모든 폴더").tag("all"); Text("최상위").tag("root")
                        ForEach(folders) { Text($0.name).tag($0.id) }
                    }
                    .frame(maxWidth: 190)
                }
            }
            .padding(12)
            Divider()

            if visibleDocuments.isEmpty {
                ContentUnavailableView(
                    section == .trash ? "휴지통이 비어 있습니다" : "저장된 PDF가 없습니다",
                    systemImage: section == .trash ? "trash" : "doc.richtext",
                    description: Text("PDF 가져오기를 누르거나 포털의 PDF 파일을 열어 저장할 수 있습니다.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(visibleDocuments) { document in
                    Button {
                        openDocument(document)
                    } label: {
                        HStack(spacing: 12) {
                            MacPDFLibraryThumbnail(fileURL: document.localFileURL, modifiedAt: document.modifiedAt)
                                .frame(width: 36, height: 48)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(document.fileName).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                                Text("\(document.modifiedAt.formatted(date: .abbreviated, time: .shortened)) · \(ByteCountFormatter.string(fromByteCount: document.fileSize, countStyle: .file))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if document.isFavorite { Image(systemName: "star.fill").foregroundStyle(.yellow) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("pdf.library.open.\(document.id)")
                    .contextMenu {
                        if document.isDeleted {
                            Button("복원") { perform { try repository.restore(document) } }
                            Button("영구 삭제", role: .destructive) { deletion = document }
                        } else {
                            Button("이름 변경") { if let name = prompt("PDF 이름 변경", initial: document.fileName) { perform { try repository.rename(document, name: name) } } }
                            Button("복제") { perform { _ = try repository.duplicate(document) } }
                            Menu("폴더로 이동") {
                                Button("최상위") { perform { try repository.move(document, folderID: nil) } }
                                ForEach(folders) { folder in Button(folder.name) { perform { try repository.move(document, folderID: folder.id) } } }
                            }
                            Button(document.isFavorite ? "즐겨찾기 해제" : "즐겨찾기") {
                                perform { try repository.toggleFavorite(document) }
                            }
                            Button("휴지통으로 이동", role: .destructive) {
                                perform { try repository.moveToTrash(document) }
                            }
                        }
                    }
                }
            }
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.pdf, .image],
            allowsMultipleSelection: true
        ) { result in
            do {
                for url in try result.get() {
                    let accessing = url.startAccessingSecurityScopedResource()
                    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                    let source = try Data(contentsOf: url, options: [.mappedIfSafe])
                    let data: Data
                    if PDFDocument(data: source) != nil { data = source }
                    else if let image = NSImage(data: source), let page = PDFPage(image: image) { let pdf = PDFDocument(); pdf.insert(page, at: 0); guard let rendered = pdf.dataRepresentation() else { throw CocoaError(.fileReadCorruptFile) }; data = rendered }
                    else { throw CocoaError(.fileReadCorruptFile) }
                    _ = try repository.createDocument(
                        data: data,
                        fileName: url.lastPathComponent
                    )
                }
                reload()
            } catch {
                errorMessage = "PDF 파일을 가져오지 못했습니다."
            }
        }
        .onDisappear { documentWindow.close() }
        .onExitCommand { documentWindow.close(); dismiss() }
        .alert("문서 처리 실패", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("확인", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "PDF 문서를 처리하지 못했습니다.")
        }
        .onAppear { do { try repository.purgeExpiredTrash() } catch { errorMessage = "휴지통 정리 실패: \(error.localizedDescription)" }; reload() }
        .sheet(isPresented: $showBoard) { MacPDFBoardView().frame(minWidth: 1000, minHeight: 700) }
        .photosPicker(isPresented: $isPhotosPresented, selection: $photos, maxSelectionCount: 40, matching: .images)
        .onChange(of: photos) { _, items in Task { await createPhotosPDF(items) } }
        .confirmationDialog("\(deletion?.fileName ?? "문서")와 편집 데이터를 영구 삭제할까요? 복구할 수 없습니다.", isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } })) {
            Button("영구 삭제", role: .destructive) { if let document = deletion { perform { try repository.permanentlyDelete(document) } }; deletion = nil }
        }
        .onReceive(NotificationCenter.default.publisher(for: MacPDFLocalStorageRepository.didChangeNotification)) { _ in reload() }
    }

    private var visibleDocuments: [MacLocalPDFDocument] {
        documents.filter { document in
            let sectionMatches = switch section {
            case .all: !document.isDeleted
            case .favorites: !document.isDeleted && document.isFavorite
            case .recent: !document.isDeleted && document.lastOpenedAt != nil
            case .trash: document.isDeleted
            }
            let folderMatches = folderID == "all" || (folderID == "root" ? document.folderID == nil : document.folderID == folderID)
            let folder = folders.first { $0.id == document.folderID }?.name ?? "내 문서"
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            return sectionMatches && folderMatches && (query.isEmpty ||
                document.fileName.localizedCaseInsensitiveContains(query) || folder.localizedCaseInsensitiveContains(query))
        }.sorted { section == .recent ? ($0.lastOpenedAt ?? .distantPast) > ($1.lastOpenedAt ?? .distantPast) : $0.modifiedAt > $1.modifiedAt }
    }

    private func reload() { documents = repository.documents(); folders = repository.folders() }
    private func openDocument(_ document: MacLocalPDFDocument) {
        if let onSelectDocument { onSelectDocument(document) }
        else { documentWindow.open(document, repository: repository, editorDirectory: editorDirectory) }
    }
    private func prompt(_ title: String, initial: String) -> String? {
        let alert = NSAlert(); alert.messageText = title; alert.addButton(withTitle: "확인"); alert.addButton(withTitle: "취소")
        let field = NSTextField(string: initial); field.frame = CGRect(x: 0, y: 0, width: 340, height: 24); alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines); return value.isEmpty ? nil : value
    }
    private func createBlank() {
        perform { let pdf = PDFDocument(), page = PDFPage(); page.setBounds(CGRect(x: 0, y: 0, width: 595, height: 842), for: .mediaBox); pdf.insert(page, at: 0); guard let data = pdf.dataRepresentation() else { throw CocoaError(.fileWriteUnknown) }; openDocument(try repository.createDocument(data: data, fileName: "새 PDF.pdf")) }
    }
    private func createPhotosPDF(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        do {
            let pdf = PDFDocument()
            for item in items { if let data = try await item.loadTransferable(type: Data.self), let image = NSImage(data: data), let page = PDFPage(image: image) { pdf.insert(page, at: pdf.pageCount) } }
            guard pdf.pageCount > 0, let data = pdf.dataRepresentation() else { throw CocoaError(.fileReadCorruptFile) }
            openDocument(try repository.createDocument(data: data, fileName: "사진 PDF.pdf")); photos = []; reload()
        } catch { errorMessage = error.localizedDescription }
    }
    private func importLink() {
        guard let value = prompt("PDF 다운로드 URL", initial: "https://"), let url = URL(string: value), url.scheme == "https", url.host != nil else { return }
        Task {
            do {
                var request = URLRequest(url: url)
                if MacPortalConfig.isPortalURL(url), let cookie = await MacPDFGoogleDrive.cookieHeader(for: url) { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
                openDocument(try repository.createDocument(data: data, fileName: response.suggestedFilename ?? "다운로드.pdf", sourceURL: url)); reload()
            } catch { errorMessage = "PDF 다운로드 실패: \(error.localizedDescription)" }
        }
    }

    private func perform(_ operation: () throws -> Void) {
        do {
            try operation()
            reload()
        } catch {
            errorMessage = "PDF 문서 정보를 변경하지 못했습니다."
        }
    }
}

struct MacPDFDocumentView: View {
    let document: MacLocalPDFDocument
    var onOpen: (MacLocalPDFDocument) -> Void = { _ in }
    var onClose: () -> Void
    @ObservedObject var fullscreen: MacPDFViewerWindowState
    @State private var pdf: PDFDocument?
    @State private var didLoadPDF = false
    @State private var history: [MacLocalPDFDocument] = []
    var repository = MacPDFLocalStorageRepository()
    var editorDirectory: URL?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if fullscreen.isFullscreen {
                    Button { fullscreen.exit() } label: { Image(systemName: "arrow.down.right.and.arrow.up.left") }
                        .help("전체화면 종료").accessibilityLabel("PDF 전체화면 종료")
                        .disabled(fullscreen.isTransitioning)
                } else { Button("닫기", action: onClose) }
                Spacer()
                Text(document.fileName).font(.system(size: 14, weight: .medium)).lineLimit(1)
                Spacer()
                if !fullscreen.isFullscreen {
                    Button { fullscreen.toggle() } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }
                    .help("전체화면 보기").accessibilityLabel("PDF 전체화면 보기")
                    .disabled(fullscreen.isTransitioning)
                }
                Button("Finder에서 보기") { NSWorkspace.shared.activateFileViewerSelecting([document.localFileURL]) }
            }
            .padding(12)
            Divider()
            if history.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack { ForEach(history.prefix(10)) { item in
                        Button(item.fileName) { onOpen(item) }.buttonStyle(.borderless)
                            .padding(6).background(item.id == document.id ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 5))
                    } }.padding(6)
                }
            }
            Group {
                if let pdf {
                    MacPDFWorkspace(document: pdf, identifier: document.id, fileName: document.fileName, isFullscreen: fullscreen.isFullscreen, onToggleFullscreen: { fullscreen.toggle() }, editorDirectory: editorDirectory?.appendingPathComponent(document.id), onSave: { data in try repository.updateData(document, data: data) })
                        .id(document.id)
                } else if didLoadPDF { ContentUnavailableView("PDF 파일을 열 수 없습니다", systemImage: "exclamationmark.triangle", description: Text("파일이 손상되었거나 삭제되었습니다. 원본 파일을 다시 가져와 주세요.")) }
                else { ProgressView("PDF를 불러오는 중…") }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: document.id) { didLoadPDF = false; pdf = PDFDocument(url: document.localFileURL); if pdf != nil { try? repository.recordOpen(document) }; didLoadPDF = true; history = repository.documents().filter { !$0.isDeleted && $0.lastOpenedAt != nil }.sorted { ($0.lastOpenedAt ?? .distantPast) > ($1.lastOpenedAt ?? .distantPast) } }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .ignoresSafeArea(.container, edges: .top)
        .onExitCommand { if fullscreen.isFullscreen { fullscreen.exit() } else { onClose() } }
    }
}

struct MacRemotePDFPreviewView: View {
    let request: MacPDFRemoteRequest
    let storesLocally: Bool
    let isContainerResizing: Bool
    let onClose: () -> Void
    var isFullscreen = false
    var onToggleFullscreen: (() -> Void)?
    var isPaneExpanded = false
    var onTogglePaneExpanded: (() -> Void)?
    var editorDirectory: URL?
    var repository = MacPDFLocalStorageRepository()
    @State private var isConvertedPowerPoint = false
    @State private var pdfDocument: PDFDocument?
    @State private var storedPDF: MacLocalPDFDocument?
    @State private var image: NSImage?
    @State private var markdown: String?
    @State private var quickLookFile: MacAttachmentQuickLookFile?
    @State private var csvDocument: MacCSVDocument?
    @State private var isParsingCSV = false
    @StateObject private var markdownPreviewController = MacMarkdownPreviewController()
    @State private var attachmentData: Data?
    @State private var attachmentIsMovie = false
    @State private var title = "첨부 파일"
    @State private var errorMessage: String?
    @State private var didStoreLocally = false
    @State private var markdownSearchQuery = ""
    @State private var isMoreMenuPresented = false
    @State private var pendingMoreMenuAction: MoreMenuAction?

    private enum MoreMenuAction { case sharePDF, openOriginal, saveOriginal, fullscreen }

    private var attachmentPreviewDescription: String? {
        if let csvDocument { return "CSV 미리보기 · 읽기 전용 · \(csvDocument.rows.count)행 \(csvDocument.columnCount)열 · \(csvDocument.encodingName)" }
        if let quickLookFile { return "\(quickLookFile.kind.title) 미리보기 · 읽기 전용" }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { exitOrClose() } label: {
                    Image(systemName: isFullscreen || isPaneExpanded ? "arrow.down.right.and.arrow.up.left" : "chevron.left")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(isFullscreen ? nil : KeyboardShortcut.cancelAction)
                .help(isFullscreen ? "모니터 전체화면 종료" : isPaneExpanded ? "분할 영역 전체보기 종료" : "뒤로")
                .accessibilityLabel(isFullscreen ? "PDF 전체화면 종료" : isPaneExpanded ? "분할 영역 전체보기 종료" : "첨부 미리보기 닫기")
                .accessibilityIdentifier("attachment.viewer.back")
                Spacer()
                Text(title).font(.headline).lineLimit(1)
                Spacer()
                if didStoreLocally || (request.localDocument != nil && storedPDF != nil) {
                    Label(request.localDocument == nil ? "Mac 복사본 보관됨" : "Mac에 저장됨", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .help(request.localDocument == nil
                            ? "Mac에 보관된 복사본입니다. 서버 반영 여부는 편집기의 저장 상태에서 확인하세요."
                            : "PDF 문서함에 보관된 파일입니다.")
                }
                Button {
                    isMoreMenuPresented.toggle()
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("더보기")
                .accessibilityLabel("첨부 파일 더보기")
                .accessibilityIdentifier("attachment.viewer.more")
                .popover(isPresented: $isMoreMenuPresented, arrowEdge: .top) {
                    VStack(spacing: 0) {
                        if onTogglePaneExpanded != nil, !isFullscreen {
                            MacAttachmentMenuRow(title: isPaneExpanded ? "분할 영역 전체보기 종료" : "분할 영역 전체보기", systemImage: "rectangle.split.2x1", isEnabled: true) {
                                isMoreMenuPresented = false
                                // Embedded hosting views can keep a dismissed popover's
                                // content alive, so do not depend on its onDisappear.
                                DispatchQueue.main.async { onTogglePaneExpanded?() }
                            }
                            .accessibilityIdentifier("attachment.viewer.expandPane")
                        }
                        if onToggleFullscreen != nil {
                            MacAttachmentMenuRow(title: isFullscreen ? "모니터 전체화면 종료" : "모니터 전체화면 보기", systemImage: isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", isEnabled: true) {
                                pendingMoreMenuAction = .fullscreen; isMoreMenuPresented = false
                            }
                            .accessibilityIdentifier("attachment.viewer.fullscreen")
                        }
                        if markdown != nil {
                            MacAttachmentMenuRow(
                                title: markdownPreviewController.isSharing ? "PDF 생성 중…" : "PDF 외부 공유하기",
                                systemImage: "square.and.arrow.up",
                                isEnabled: markdownPreviewController.isReady && !markdownPreviewController.isSharing
                            ) {
                                pendingMoreMenuAction = .sharePDF
                                isMoreMenuPresented = false
                            }
                        }
                        MacAttachmentMenuRow(title: "기본 앱에서 열기", systemImage: "arrow.up.right.square", isEnabled: attachmentData != nil) {
                            pendingMoreMenuAction = .openOriginal
                            isMoreMenuPresented = false
                        }
                        MacAttachmentMenuRow(title: "원본 파일 저장", systemImage: "square.and.arrow.down", isEnabled: attachmentData != nil) {
                            pendingMoreMenuAction = .saveOriginal
                            isMoreMenuPresented = false
                        }
                    }
                    .padding(6)
                    .frame(width: 210)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .onDisappear(perform: runPendingMoreMenuAction)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 48)
            Divider()
            if markdown != nil {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("문구 검색", text: $markdownSearchQuery)
                        .textFieldStyle(.plain)
                        .onSubmit { markdownPreviewController.find(markdownSearchQuery) }
                        .onChange(of: markdownSearchQuery) { _, query in
                            markdownPreviewController.find(query)
                        }
                        .onChange(of: markdownPreviewController.isReady) { _, ready in
                            if ready { markdownPreviewController.find(markdownSearchQuery) }
                        }
                    if markdownPreviewController.searchHasMatch == false, !markdownSearchQuery.isEmpty {
                        Text("결과 없음").font(.caption).foregroundStyle(.secondary)
                    }
                    Button {
                        markdownPreviewController.find(markdownSearchQuery, backwards: true)
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .help("이전 결과")
                    .disabled(markdownSearchQuery.isEmpty || !markdownPreviewController.isReady)
                    Button {
                        markdownPreviewController.find(markdownSearchQuery)
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .help("다음 결과")
                    .disabled(markdownSearchQuery.isEmpty || !markdownPreviewController.isReady)
                    Button {
                        markdownSearchQuery = ""
                        markdownPreviewController.find("")
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .help("검색 닫기")
                    .disabled(markdownSearchQuery.isEmpty)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .frame(height: 44)
                .background(Color(red: 0.11, green: 0.15, blue: 0.19))
            }
            if let attachmentPreviewDescription {
                HStack {
                    Label(attachmentPreviewDescription, systemImage: "doc.richtext")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(attachmentPreviewDescription)
                    Spacer()
                    if let onTogglePaneExpanded, !isFullscreen {
                        MacPDFActionButton(title: "", symbol: "rectangle.split.2x1",
                                           identifier: "attachment.viewer.quickLook.expandPane",
                                           accessibilityTitle: isPaneExpanded ? "분할 영역 전체보기 종료" : "분할 영역 전체보기",
                                           action: onTogglePaneExpanded)
                            .frame(width: 28, height: 24)
                    }
                }
                .padding(.horizontal, 16)
                .frame(height: 32)
                Divider()
            }
            Group {
                if let pdfDocument {
                    MacPDFWorkspace(
                        document: pdfDocument,
                        identifier: storedPDF?.id ?? "remote:\(request.url.host ?? "")\(request.url.path)",
                        fileName: title,
                        sourceURL: isConvertedPowerPoint || request.localDocument != nil ? nil : request.url,
                        initialFreeNote: request.initialFreeNote,
                        cookieHeader: request.cookieHeader,
                        sourceData: attachmentData,
                        isContainerResizing: isContainerResizing,
                        isFullscreen: isFullscreen,
                        onToggleFullscreen: onToggleFullscreen,
                        onExitPaneExpansion: isPaneExpanded && !isFullscreen ? onTogglePaneExpanded : nil,
                        isPaneExpanded: isPaneExpanded,
                        onTogglePaneExpanded: onTogglePaneExpanded,
                        editorDirectory: editorDirectory,
                        onSave: { data in
                            if (isConvertedPowerPoint || request.localDocument != nil), let storedPDF {
                                try repository.updateData(storedPDF, data: data)
                                return
                            }
                            try await MacPDFRemoteSave.shared.save(source: request.url, data: data)
                            // A local cache failure must not turn a confirmed server save into an upload failure.
                            if storesLocally { _ = try? repository.saveRemote(data: data, fileName: title, sourceURL: request.url) }
                        }
                    )
                } else if let image {
                    ScrollView([.horizontal, .vertical]) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .padding(20)
                    }
                } else if let markdown {
                    MacMarkdownPreviewView(markdown: markdown, controller: markdownPreviewController)
                } else if let quickLookFile {
                    MacAttachmentQuickLookView(file: quickLookFile)
                } else if let csvDocument {
                    if csvDocument.rows.isEmpty {
                        ContentUnavailableView("빈 CSV 문서입니다", systemImage: "tablecells", description: Text("원본 파일에 표시할 행이 없습니다."))
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("attachment.viewer.csv.empty")
                    } else {
                        MacCSVPreviewView(document: csvDocument)
                    }
                } else if let errorMessage {
                    ContentUnavailableView("첨부 파일을 열 수 없습니다", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("attachment.viewer.error")
                } else if isParsingCSV {
                    ProgressView("CSV 표를 불러오는 중…")
                } else if attachmentData != nil {
                    ContentUnavailableView(
                        "첨부 파일을 불러왔습니다",
                        systemImage: attachmentIsMovie ? "film" : "doc",
                        description: Text("기본 앱에서 열거나 Mac에 저장할 수 있습니다.")
                    )
                } else {
                    ProgressView("첨부 파일을 불러오는 중…")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: request.id) { await load() }
        .onExitCommand { exitOrClose() }
    }

    private func exitOrClose() {
        if isFullscreen { onToggleFullscreen?() }
        else if isPaneExpanded { onTogglePaneExpanded?() }
        else { onClose() }
    }

    private func runPendingMoreMenuAction() {
        guard let action = pendingMoreMenuAction else { return }
        pendingMoreMenuAction = nil
        switch action {
        case .sharePDF: markdownPreviewController.sharePDF(fileName: title)
        case .openOriginal: openInDefaultApplication()
        case .saveOriginal: saveAttachment()
        case .fullscreen: onToggleFullscreen?()
        }
    }

    private func load() async {
        isConvertedPowerPoint = false
        pdfDocument = nil; storedPDF = nil; image = nil; markdown = nil; quickLookFile = nil; csvDocument = nil; isParsingCSV = false
        attachmentData = nil; attachmentIsMovie = false; errorMessage = nil; didStoreLocally = false
        title = "첨부 파일"
        do {
            if let local = request.localDocument {
                title = local.fileName
                let data = try Data(contentsOf: local.localFileURL, options: .mappedIfSafe)
                guard let document = PDFDocument(data: data), document.pageCount > 0 else { throw CocoaError(.fileReadCorruptFile) }
                try Task.checkCancellation()
                storedPDF = local
                attachmentData = data
                pdfDocument = document
                try? repository.recordOpen(local)
                return
            }
            var previewURL = request.url
            if request.url.scheme == "https", request.url.host == MacPortalConfig.host, request.url.path.hasPrefix("/api/artifacts/files/"), var parts = URLComponents(url: request.url, resolvingAgainstBaseURL: false) {
                parts.queryItems = (parts.queryItems ?? []).filter { $0.name != "pdfPreview" } + [URLQueryItem(name: "pdfPreview", value: "1")]
                previewURL = parts.url ?? request.url
            }
            var urlRequest = URLRequest(url: previewURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 120)
            urlRequest.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            if let cookieHeader = request.cookieHeader {
                urlRequest.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            }
            let (data, response) = try await URLSession.shared.data(for: urlRequest)
            try Task.checkCancellation()
            if let response = response as? HTTPURLResponse,
               !(200..<300).contains(response.statusCode) {
                throw URLError(.badServerResponse)
            }
            isConvertedPowerPoint = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-NF-Converted-From") == "powerpoint"
            let responseName = response.suggestedFilename ?? request.url.lastPathComponent
            title = Self.safeFileName(responseName.isEmpty ? "첨부 파일" : responseName)
            attachmentData = data

            let mimeType = response.mimeType?.lowercased() ?? ""
            let fileExtension = (title as NSString).pathExtension.lowercased()
            let sourceExtension = request.url.pathExtension.lowercased()
            attachmentIsMovie = mimeType.hasPrefix("video/") || ["mov", "mp4", "m4v", "avi", "mkv"].contains(fileExtension)
            let isPDF = mimeType == "application/pdf" || fileExtension == "pdf" || data.starts(with: Data("%PDF".utf8))
            let isMarkdown = ["md", "markdown", "mdown"].contains(fileExtension)
                || ["md", "markdown", "mdown"].contains(sourceExtension)
                || ["text/markdown", "text/x-markdown"].contains(mimeType)
            let quickLookKind = MacAttachmentQuickLookKind.detect(fileName: title, sourceURL: request.url, mimeType: mimeType)
            if isPDF, let document = PDFDocument(data: data), document.pageCount > 0 {
                pdfDocument = document
                if isConvertedPowerPoint {
                    storedPDF = try repository.createDocument(data: data, fileName: title)
                    didStoreLocally = true
                } else if storesLocally {
                    storedPDF = try repository.saveRemote(data: data, fileName: title, sourceURL: request.url)
                    didStoreLocally = true
                }
            } else if mimeType.hasPrefix("image/") || NSImage(data: data) != nil {
                image = NSImage(data: data)
            } else if isMarkdown {
                markdown = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .utf16)
            } else if MacCSVDocument.matches(fileName: title, sourceURL: request.url, mimeType: mimeType) {
                isParsingCSV = true
                let encodingName = response.textEncodingName
                let parsing = Task.detached(priority: .userInitiated) { try MacCSVDocument.parse(data, encodingName: encodingName) }
                do {
                    let parsed = try await withTaskCancellationHandler {
                        try await parsing.value
                    } onCancel: { parsing.cancel() }
                    try Task.checkCancellation()
                    csvDocument = parsed
                } catch {
                    guard !Task.isCancelled else { return }
                    errorMessage = error.localizedDescription
                }
                isParsingCSV = false
            } else if let quickLookKind {
                do {
                    let file = try MacAttachmentQuickLookFile(data: data, fileName: title, kind: quickLookKind)
                    title = file.url.lastPathComponent
                    quickLookFile = file
                } catch {
                    errorMessage = "\(quickLookKind.title) 미리보기를 준비하지 못했습니다. 기본 앱에서 열거나 원본 파일을 저장해 주세요."
                }
            }
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = "네트워크 연결과 파일 형식을 확인해 주세요."
        }
    }

    private func saveAttachment() {
        guard let attachmentData else { return }
        let panel = NSSavePanel()
        panel.title = "첨부 파일 저장"
        panel.prompt = "저장"
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = title
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try attachmentData.write(to: url, options: .atomic)
            } catch {
                Self.showFileError("첨부 파일을 저장하지 못했습니다.", error: error)
            }
        }
    }

    private func openInDefaultApplication() {
        guard let attachmentData else { return }
        do {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("NF-AttachmentPreview", isDirectory: true)
                .appendingPathComponent(request.id.uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(Self.safeFileName(title))
            try attachmentData.write(to: url, options: .atomic)
            guard NSWorkspace.shared.open(url) else {
                throw CocoaError(.fileNoSuchFile)
            }
        } catch {
            Self.showFileError("첨부 파일을 기본 앱에서 열지 못했습니다.", error: error)
        }
    }

    private static func safeFileName(_ value: String) -> String {
        let cleaned = value
            .components(separatedBy: CharacterSet(charactersIn: "/:\0"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "첨부 파일" : cleaned
    }

    private static func showFileError(_ title: String, error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}

private struct MacAttachmentMenuRow: View {
    let title: String
    let systemImage: String
    let isEnabled: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .frame(width: 18, height: 18)
                Text(title)
                Spacer(minLength: 0)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(minHeight: 40)
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .background(isHovering && isEnabled ? Color.primary.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { isHovering = $0 }
    }
}

private struct MacPDFKitView: NSViewRepresentable {
    let document: PDFDocument?
    var isContainerResizing = false

    func makeNSView(context: Context) -> PDFView {
        let view = MacInteractivePDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.document = document
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document {
            view.document = document
            view.autoScales = true
        }
        (view as? MacInteractivePDFView)?.setContainerResizeInProgress(isContainerResizing)
    }
}

private final class MacInteractivePDFView: PDFView {
    private var commandDragStartX: CGFloat?
    private var commandDragStartScale: CGFloat?
    private var isContainerResizeInProgress = false

    func setContainerResizeInProgress(_ isResizing: Bool) {
        guard isResizing != isContainerResizeInProgress else { return }
        isContainerResizeInProgress = isResizing

        // PDFKit's automatic fit recalculates and rerenders every page for every
        // intermediate frame. Keep the current scale during a live panel resize;
        // the newly exposed area is rendered without repeatedly rescaling the PDF.
        if isResizing {
            autoScales = false
        }
    }

    override func mouseDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.contains(.command) else {
            super.mouseDown(with: event)
            return
        }

        commandDragStartX = event.locationInWindow.x
        commandDragStartScale = scaleFactor
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startX = commandDragStartX,
              let startScale = commandDragStartScale else {
            super.mouseDragged(with: event)
            return
        }

        let horizontalDistance = event.locationInWindow.x - startX
        guard abs(horizontalDistance) >= 1 else { return }

        autoScales = false
        let zoomMultiplier = CGFloat(pow(2, Double(horizontalDistance / 240)))
        let minimum = max(minScaleFactor, 0.1)
        let maximum = max(maxScaleFactor, minimum)
        scaleFactor = min(maximum, max(minimum, startScale * zoomMultiplier))
    }

    override func mouseUp(with event: NSEvent) {
        guard commandDragStartX != nil else {
            super.mouseUp(with: event)
            return
        }
        commandDragStartX = nil
        commandDragStartScale = nil
    }
}


private struct MacPDFLibraryThumbnail: View {
    let fileURL: URL
    let modifiedAt: Date
    @State private var preview: NSImage?

    var body: some View {
        Group {
            if let preview {
                Image(nsImage: preview).resizable().scaledToFit().accessibilityHidden(true)
            } else {
                Image(systemName: "doc.richtext").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MacPDFPanelSurface(radius: 4))
        .task(id: modifiedAt) {
            let url = fileURL
            preview = await Task.detached(priority: .utility) {
                PDFDocument(url: url)?.page(at: 0)?.thumbnail(of: CGSize(width: 72, height: 96), for: .cropBox)
            }.value
        }
    }
}
