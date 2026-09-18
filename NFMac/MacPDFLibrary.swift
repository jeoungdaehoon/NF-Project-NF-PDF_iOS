import AppKit
import CryptoKit
import Foundation
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct MacPDFRemoteRequest: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let cookieHeader: String?
}

enum MacPDFSlidePanelLayout {
    static let animation = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.52)
    static let resizeHandleWidth: CGFloat = 10

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
    }

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
        notifyChange()
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
            deletedAt: metadata.deletedAt
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
    case trash

    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "전체"
        case .favorites: "즐겨찾기"
        case .trash: "휴지통"
        }
    }
}

struct MacPDFLibraryView: View {
    @Environment(\.dismiss) private var dismiss
    private let repository = MacPDFLocalStorageRepository()
    @State private var section: MacPDFLibrarySection = .all
    @State private var searchText = ""
    @State private var documents: [MacLocalPDFDocument] = []
    @State private var selectedDocument: MacLocalPDFDocument?
    @State private var isImporterPresented = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("닫기", action: dismiss.callAsFunction)
                Spacer()
                Text("문서")
                    .font(.headline)
                Spacer()
                Button {
                    isImporterPresented = true
                } label: {
                    Label("PDF 가져오기", systemImage: "plus")
                }
            }
            .padding(14)

            Divider()

            HStack(spacing: 14) {
                Picker("문서 분류", selection: $section) {
                    ForEach(MacPDFLibrarySection.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)

                TextField("PDF 파일명 검색", text: $searchText)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(14)

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
                        selectedDocument = document
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "doc.richtext")
                                .font(.title2)
                                .foregroundStyle(.red)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(document.fileName).font(.headline).lineLimit(1)
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
                    .contextMenu {
                        if document.isDeleted {
                            Button("복원") { perform { try repository.restore(document) } }
                            Button("영구 삭제", role: .destructive) { perform { try repository.permanentlyDelete(document) } }
                        } else {
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
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: true
        ) { result in
            do {
                for url in try result.get() {
                    let accessing = url.startAccessingSecurityScopedResource()
                    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                    _ = try repository.createDocument(
                        data: Data(contentsOf: url, options: [.mappedIfSafe]),
                        fileName: url.lastPathComponent
                    )
                }
                reload()
            } catch {
                errorMessage = "PDF 파일을 가져오지 못했습니다."
            }
        }
        .sheet(item: $selectedDocument, onDismiss: reload) { document in
            MacPDFDocumentView(document: document)
                .frame(minWidth: 820, minHeight: 620)
        }
        .alert("문서 처리 실패", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("확인", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "PDF 문서를 처리하지 못했습니다.")
        }
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: MacPDFLocalStorageRepository.didChangeNotification)) { _ in reload() }
    }

    private var visibleDocuments: [MacLocalPDFDocument] {
        documents.filter { document in
            let sectionMatches = switch section {
            case .all: !document.isDeleted
            case .favorites: !document.isDeleted && document.isFavorite
            case .trash: document.isDeleted
            }
            return sectionMatches && (searchText.isEmpty || document.fileName.localizedCaseInsensitiveContains(searchText))
        }
    }

    private func reload() { documents = repository.documents() }

    private func perform(_ operation: () throws -> Void) {
        do {
            try operation()
            reload()
        } catch {
            errorMessage = "PDF 문서 정보를 변경하지 못했습니다."
        }
    }
}

private struct MacPDFDocumentView: View {
    @Environment(\.dismiss) private var dismiss
    let document: MacLocalPDFDocument

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("닫기", action: dismiss.callAsFunction)
                Spacer()
                Text(document.fileName).font(.headline).lineLimit(1)
                Spacer()
                Button("Finder에서 보기") { NSWorkspace.shared.activateFileViewerSelecting([document.localFileURL]) }
            }
            .padding(12)
            Divider()
            MacPDFKitView(document: PDFDocument(url: document.localFileURL))
        }
    }
}

struct MacRemotePDFPreviewView: View {
    let request: MacPDFRemoteRequest
    let storesLocally: Bool
    let isContainerResizing: Bool
    let onClose: () -> Void
    private let repository = MacPDFLocalStorageRepository()
    @State private var pdfDocument: PDFDocument?
    @State private var image: NSImage?
    @State private var markdown: String?
    @StateObject private var markdownPreviewController = MacMarkdownPreviewController()
    @State private var attachmentData: Data?
    @State private var attachmentIsMovie = false
    @State private var title = "첨부 파일"
    @State private var errorMessage: String?
    @State private var didStoreLocally = false
    @State private var markdownSearchQuery = ""
    @State private var isMoreMenuPresented = false
    @State private var pendingMoreMenuAction: MoreMenuAction?

    private enum MoreMenuAction { case sharePDF, openOriginal, saveOriginal }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button(action: onClose) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("뒤로")
                .accessibilityLabel("첨부 미리보기 닫기")
                Spacer()
                Text(title).font(.headline).lineLimit(1)
                Spacer()
                if didStoreLocally {
                    Label("로컬 저장됨", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
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
                .popover(isPresented: $isMoreMenuPresented, arrowEdge: .top) {
                    VStack(spacing: 0) {
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
            .padding(.horizontal, 14)
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
            Group {
                if let pdfDocument {
                    MacPDFKitView(
                        document: pdfDocument,
                        isContainerResizing: isContainerResizing
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
                } else if attachmentData != nil {
                    ContentUnavailableView(
                        "첨부 파일을 불러왔습니다",
                        systemImage: attachmentIsMovie ? "film" : "doc",
                        description: Text("기본 앱에서 열거나 Mac에 저장할 수 있습니다.")
                    )
                } else if let errorMessage {
                    ContentUnavailableView("첨부 파일을 열 수 없습니다", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
                } else {
                    ProgressView("첨부 파일을 불러오는 중…")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { await load() }
    }

    private func runPendingMoreMenuAction() {
        guard let action = pendingMoreMenuAction else { return }
        pendingMoreMenuAction = nil
        switch action {
        case .sharePDF: markdownPreviewController.sharePDF(fileName: title)
        case .openOriginal: openInDefaultApplication()
        case .saveOriginal: saveAttachment()
        }
    }

    private func load() async {
        do {
            var urlRequest = URLRequest(url: request.url)
            if let cookieHeader = request.cookieHeader {
                urlRequest.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            }
            let (data, response) = try await URLSession.shared.data(for: urlRequest)
            if let response = response as? HTTPURLResponse,
               !(200..<300).contains(response.statusCode) {
                throw URLError(.badServerResponse)
            }
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
            if isPDF, let document = PDFDocument(data: data), document.pageCount > 0 {
                pdfDocument = document
                if storesLocally {
                    _ = try repository.saveRemote(data: data, fileName: title, sourceURL: request.url)
                    didStoreLocally = true
                }
            } else if mimeType.hasPrefix("image/") || NSImage(data: data) != nil {
                image = NSImage(data: data)
            } else if isMarkdown {
                markdown = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .utf16)
            }
        } catch {
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
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .frame(width: 16, height: 16)
                Text(title)
                Spacer(minLength: 0)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .frame(minHeight: 26)
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
